#!/usr/bin/env python3
"""Тесты RadarMap API: поднимаем настоящий сервер на случайном порту с временной
БД и ходим в него HTTP-клиентом stdlib. Запуск: python3 server/test_api.py
"""
import json
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

import api


def _call(port, method, path, payload=None, ip=None):
    """ip — имитация X-Forwarded-For: в проде его ставит nginx ($remote_addr),
    здесь мы сами играем роль nginx и подставляем «адрес клиента»."""
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if ip:
        headers["X-Forwarded-For"] = ip
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


class APITest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        api.DB_PATH = cls.tmp.name
        api.init_db()      # схема, миграции и индексы — один раз, как в проде
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        conn = sqlite3.connect(api.DB_PATH)
        for table in ("reports", "votes", "metrics", "camera_reports", "feedback",
                      "usage_stats"):
            conn.execute(f"DELETE FROM {table}")
        conn.commit()
        conn.close()
        with api._ip_lock:
            api._ip_counters.clear()
        with api._cleanup_lock:
            api._last_cleanup = 0.0

    # --- передвижные радары ---

    def test_report_and_merge_then_vote_keeps_confirmations(self):
        """Главный сценарий: merge-подтверждения должны переживать дизлайк."""
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for device in ("a", "b", "c"):  # три водителя подтверждают той же точкой
            status, body = _call(self.port, "POST", "/api/report",
                                 {"lat": 41.3101, "lon": 69.2501, "device": device})
            self.assertTrue(body["merged"], "300 м — должно слиться")
        status, body = _call(self.port, "POST", "/api/vote",
                             {"id": rid, "device": "hater", "value": -1})
        self.assertEqual(status, 200)
        self.assertEqual(body["up"], 3, "merge-подтверждения потерялись при пересчёте")
        self.assertTrue(body["active"], "3 подтверждения против 1 дизлайка — отметка жива")

    def test_three_dislikes_hide_unconfirmed(self):
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for i, device in enumerate(("h1", "h2", "h3")):
            status, body = _call(self.port, "POST", "/api/vote",
                                 {"id": rid, "device": device, "value": -1},
                                 ip=f"10.0.0.{i + 1}")
        self.assertFalse(body["active"], "3 дизлайка с разных адресов должны скрыть")

    def test_dislikes_from_one_ip_do_not_hide(self):
        """Три свежих UUID с ОДНОГО адреса — это один недовольный, а не кворум:
        раньше так снималась с карты любая чужая отметка."""
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for device in ("h1", "h2", "h3"):
            status, body = _call(self.port, "POST", "/api/vote",
                                 {"id": rid, "device": device, "value": -1},
                                 ip="10.9.9.9")
        self.assertTrue(body["active"], "ротация UUID с одного IP не должна скрывать")

    def test_vote_ip_daily_cap(self):
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for i in range(api.IP_DAILY_CAPS["vote"]):
            _call(self.port, "POST", "/api/vote",
                  {"id": rid, "device": f"v{i}", "value": 1}, ip="10.1.1.1")
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": rid, "device": "extra", "value": 1}, ip="10.1.1.1")
        self.assertEqual(status, 429, "кап голосов по IP не сработал")
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": rid, "device": "other", "value": 1}, ip="10.1.1.2")
        self.assertEqual(status, 200, "чужой IP не должен страдать от чужого капа")

    def test_report_types_ttl_and_no_cross_merge(self):
        """ДТП живёт час; пост рядом с радаром не сливается (разные сущности)."""
        import time as t
        now = t.time()
        _, accident = _call(self.port, "POST", "/api/report",
                            {"lat": 41.4, "lon": 69.4, "device": "a", "type": "accident"})
        conn = sqlite3.connect(api.DB_PATH)
        expires, rtype = conn.execute("SELECT expires, type FROM reports WHERE id = ?",
                                      (accident["id"],)).fetchone()
        conn.close()
        self.assertEqual(rtype, "accident")
        self.assertLess(expires - now, 3700, "ДТП должно жить ~час")
        status, post = _call(self.port, "POST", "/api/report",
                             {"lat": 41.4001, "lon": 69.4001, "device": "b", "type": "post"})
        self.assertFalse(post["merged"], "пост не должен сливаться с ДТП рядом")

    def test_report_bad_type(self):
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 41.4, "lon": 69.4, "device": "x", "type": "ufo"})
        self.assertEqual(status, 400)

    def test_report_out_of_bounds(self):
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 55.75, "lon": 37.61, "device": "moscow"})
        self.assertEqual(status, 400)

    def test_vote_rejects_huge_id(self):
        """1e100 раньше ронял SQLite OverflowError — теперь чистый 400."""
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": 10**100, "device": "x", "value": 1})
        self.assertEqual(status, 400)

    def test_report_rate_limit_120s(self):
        _call(self.port, "POST", "/api/report", {"lat": 41.31, "lon": 69.25, "device": "d"})
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 42.0, "lon": 70.0, "device": "d"})
        self.assertEqual(status, 429, "вторая отметка раньше 120 с")

    def test_mobile_purges_orphan_votes(self):
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("INSERT INTO votes(report_id, device, value, ts) VALUES(999, 'x', 1, 0)")
        conn.commit(); conn.close()
        _call(self.port, "GET", "/api/mobile")
        conn = sqlite3.connect(api.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM votes").fetchone()[0]
        conn.close()
        self.assertEqual(left, 0, "голоса-сироты должны чиститься")

    # --- жизненный цикл доверия ---

    def _expires(self, rid):
        conn = sqlite3.connect(api.DB_PATH)
        expires = conn.execute("SELECT expires FROM reports WHERE id = ?",
                               (rid,)).fetchone()[0]
        conn.close()
        return expires

    def _feed_report(self, rid):
        _, feed = _call(self.port, "GET", "/api/mobile")
        return next(r for r in feed["reports"] if r["id"] == rid)

    def test_new_report_lives_probation_not_full_ttl(self):
        """Неподтверждённая отметка живёт испытательный срок: фейк, которого
        никто не подтвердил, умирает сам — без модерации и кворума."""
        now = time.time()
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"},
                        ip="10.2.0.1")
        life = self._expires(body["id"]) - now
        self.assertAlmostEqual(life, api.PROBATION_TTLS["radar"], delta=30)
        self.assertFalse(self._feed_report(body["id"])["confirmed"])

    def test_same_ip_votes_do_not_confirm_or_extend(self):
        """Ротация UUID с одного адреса не превращает слух в факт: лайки со
        своего же IP не продлевают жизнь и не дают флаг confirmed."""
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"},
                        ip="10.2.1.1")
        rid = body["id"]
        before = self._expires(rid)
        for fake in ("rot1", "rot2", "rot3"):
            status, _ = _call(self.port, "POST", "/api/vote",
                              {"id": rid, "device": fake, "value": 1}, ip="10.2.1.1")
            self.assertEqual(status, 200)
        self.assertEqual(self._expires(rid), before,
                         "свой адрес продлил собственную отметку")
        self.assertFalse(self._feed_report(rid)["confirmed"])

    def test_independent_confirmation_grants_full_ttl(self):
        """Один голос с другого устройства И адреса — полный срок типа."""
        now = time.time()
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"},
                        ip="10.2.2.1")
        rid = body["id"]
        _call(self.port, "POST", "/api/vote",
              {"id": rid, "device": "stranger", "value": 1}, ip="10.2.2.2")
        self.assertGreaterEqual(self._expires(rid) - now,
                                api.REPORT_TTLS["radar"] - 30,
                                "подтверждённая точка должна получить полный срок")
        self.assertTrue(self._feed_report(rid)["confirmed"])

    def test_merge_same_ip_keeps_probation_other_ip_confirms(self):
        """Merge-подтверждение подчиняется тому же правилу независимости:
        пассажир на том же Wi-Fi голос даёт, а испытательный срок не снимает."""
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"},
                        ip="10.2.3.1")
        rid = body["id"]
        before = self._expires(rid)
        _, merged = _call(self.port, "POST", "/api/report",
                          {"lat": 41.3101, "lon": 69.2501, "device": "passenger"},
                          ip="10.2.3.1")
        self.assertTrue(merged["merged"])
        self.assertEqual(self._expires(rid), before,
                         "merge с того же адреса продлил отметку")
        _, merged = _call(self.port, "POST", "/api/report",
                          {"lat": 41.3102, "lon": 69.2502, "device": "driver2"},
                          ip="10.2.3.2")
        self.assertTrue(merged["merged"])
        self.assertTrue(self._feed_report(rid)["confirmed"],
                        "независимый merge должен подтверждать")
        self.assertGreater(self._expires(rid), before)

    def test_downvote_from_new_ip_cuts_life_once(self):
        """Дизлайк с нового адреса срезает 30 мин; повторы с того же адреса или
        устройства не режут второй раз — и три дизлайка с ДВУХ адресов точку
        не скрывают (кворум остаётся кворумом)."""
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"},
                        ip="10.2.4.1")
        rid = body["id"]
        start = self._expires(rid)
        _call(self.port, "POST", "/api/vote",
              {"id": rid, "device": "h1", "value": -1}, ip="10.2.4.2")
        self.assertAlmostEqual(self._expires(rid), start - api.DOWN_PENALTY, delta=5)
        # тот же адрес, другой UUID — не режет
        _call(self.port, "POST", "/api/vote",
              {"id": rid, "device": "h2", "value": -1}, ip="10.2.4.2")
        self.assertAlmostEqual(self._expires(rid), start - api.DOWN_PENALTY, delta=5)
        # то же устройство повторно — не режет
        _call(self.port, "POST", "/api/vote",
              {"id": rid, "device": "h1", "value": -1}, ip="10.2.4.2")
        self.assertAlmostEqual(self._expires(rid), start - api.DOWN_PENALTY, delta=5)
        # новый адрес — второй срез, но не скрытие (адресов два, кворум — три)
        _, last = _call(self.port, "POST", "/api/vote",
                        {"id": rid, "device": "h3", "value": -1}, ip="10.2.4.3")
        self.assertAlmostEqual(self._expires(rid), start - 2 * api.DOWN_PENALTY,
                               delta=5)
        self.assertTrue(last["active"], "два адреса — не кворум на скрытие")

    def test_amend_retypes_own_report_without_second_point(self):
        """Второй тап с другим типом — уточнение своей отметки, не вторая точка.
        Amend обязан стоять ДО лимита «120 с между отметками», иначе уточнение
        сразу после «Радар!» получало бы 429."""
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "d"},
                         ip="10.2.5.1")
        status, second = _call(self.port, "POST", "/api/report",
                               {"lat": 41.3101, "lon": 69.2501, "device": "d",
                                "type": "tripod"}, ip="10.2.5.1")
        self.assertEqual(status, 200)
        self.assertTrue(second.get("amended"), "уточнение типа не сработало")
        self.assertEqual(second["id"], first["id"])
        conn = sqlite3.connect(api.DB_PATH)
        count, rtype = conn.execute(
            "SELECT COUNT(*), MAX(type) FROM reports").fetchone()
        conn.close()
        self.assertEqual(count, 1, "amend родил вторую точку")
        self.assertEqual(rtype, "tripod")

    def test_amend_is_only_for_own_device(self):
        """Чужое устройство с другим типом рядом — новая сущность, не retype
        чужой отметки (иначе конкурент перекрашивал бы радары в ДТП)."""
        _call(self.port, "POST", "/api/report",
              {"lat": 41.31, "lon": 69.25, "device": "d1"}, ip="10.2.6.1")
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.3101, "lon": 69.2501, "device": "d2",
                         "type": "post"}, ip="10.2.6.2")
        self.assertNotIn("amended", body)
        self.assertFalse(body["merged"], "пост не должен сливаться с радаром")
        conn = sqlite3.connect(api.DB_PATH)
        count = conn.execute("SELECT COUNT(*) FROM reports").fetchone()[0]
        conn.close()
        self.assertEqual(count, 2)

    def test_per_ip_active_cap(self):
        """Один адрес не может держать на карте больше MAX_ACTIVE_PER_IP живых
        точек — суточный кап этому не мешал."""
        for i in range(api.MAX_ACTIVE_PER_IP):
            status, _ = _call(self.port, "POST", "/api/report",
                              {"lat": 41.0 + i * 0.01, "lon": 69.25,
                               "device": f"p{i}"}, ip="10.2.7.7")
            self.assertEqual(status, 200, f"точка {i} должна пройти")
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 42.5, "lon": 69.25, "device": "extra"},
                          ip="10.2.7.7")
        self.assertEqual(status, 429, "кап активных точек по адресу не сработал")
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 42.5, "lon": 69.25, "device": "other"},
                          ip="10.2.7.8")
        self.assertEqual(status, 200, "чужой адрес страдает от чужого капа")

    def test_vote_kind_pass_is_stored_garbage_is_not_fatal(self):
        """kind="pass" (голос после реального проезда) сохраняется для админки;
        мусор в поле не должен убивать сам голос."""
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"},
                        ip="10.2.8.1")
        rid = body["id"]
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": rid, "device": "v1", "value": 1, "kind": "pass"},
                          ip="10.2.8.2")
        self.assertEqual(status, 200)
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": rid, "device": "v2", "value": 1,
                           "kind": {"a": 1}}, ip="10.2.8.3")
        self.assertEqual(status, 200, "мусорный kind уронил голос")
        conn = sqlite3.connect(api.DB_PATH)
        kinds = dict(conn.execute(
            "SELECT device, kind FROM votes WHERE report_id = ?", (rid,)).fetchall())
        conn.close()
        self.assertEqual(kinds["v1"], "pass")
        self.assertEqual(kinds["v2"], "")

    # --- камеры и фидбек ---

    def test_camera_report_dedup_per_device(self):
        payload = {"camera_id": 7, "reason": "gone", "device": "d1"}
        _, first = _call(self.port, "POST", "/api/camera_report", payload)
        _, second = _call(self.port, "POST", "/api/camera_report", payload)
        self.assertNotIn("duplicate", first)
        self.assertTrue(second.get("duplicate"), "повтор с того же устройства")

    def test_camera_report_huge_db_version_is_400(self):
        """10**100 раньше ронял хендлер OverflowError'ом на INSERT."""
        status, _ = _call(self.port, "POST", "/api/camera_report",
                          {"camera_id": 7, "reason": "gone", "device": "d",
                           "db_version": 10**100})
        self.assertEqual(status, 400)

    def test_camera_report_nan_coords_stored_null(self):
        status, _ = _call(self.port, "POST", "/api/camera_report",
                          {"camera_id": 7, "reason": "gone", "device": "d",
                           "lat": float("nan"), "lon": 200.0})
        self.assertEqual(status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        lat, lon = conn.execute(
            "SELECT lat, lon FROM camera_reports").fetchone()
        conn.close()
        self.assertIsNone(lat, "NaN не должен долетать до БД")
        self.assertIsNone(lon, "координата вне Узбекистана не должна долетать до БД")

    def test_camera_report_bad_reason(self):
        status, _ = _call(self.port, "POST", "/api/camera_report",
                          {"camera_id": 7, "reason": "hacked", "device": "d"})
        self.assertEqual(status, 400)

    def test_feedback_strips_control_chars(self):
        _call(self.port, "POST", "/api/feedback",
              {"message": "привет\x1b[2Jмир", "device": "d"})
        conn = sqlite3.connect(api.DB_PATH)
        message = conn.execute("SELECT message FROM feedback").fetchone()[0]
        conn.close()
        self.assertNotIn("\x1b", message, "ANSI-escape в терминал модератора")

    def test_feedback_app_version_stripped_and_dict_message_rejected(self):
        _call(self.port, "POST", "/api/feedback",
              {"message": "ок", "device": "d", "app_version": "1.0[2J"})
        conn = sqlite3.connect(api.DB_PATH)
        version = conn.execute("SELECT app_version FROM feedback").fetchone()[0]
        conn.close()
        self.assertNotIn("", version, "ANSI в app_version идёт в терминал модератора")
        status, _ = _call(self.port, "POST", "/api/feedback",
                          {"message": {"a": 1}, "device": "d2"})
        self.assertEqual(status, 400, "словарь вместо строки сохранялся Python-repr'ом")

    def test_trailing_slash_and_query_are_same_endpoint(self):
        status, _ = _call(self.port, "GET", "/api/health/")
        self.assertEqual(status, 200)
        status, _ = _call(self.port, "GET", "/api/mobile?x=1")
        self.assertEqual(status, 200)

    def test_metrics_roundtrip_saved(self):
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "metric", "payload": {"cpu": 1}})
        self.assertEqual(status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        kind, payload = conn.execute("SELECT kind, payload FROM metrics").fetchone()
        conn.close()
        self.assertEqual(kind, "metric")
        self.assertEqual(json.loads(payload), {"cpu": 1})

    def test_metrics_rejects_oversize_payload(self):
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "metric", "payload": "x" * 250000})
        self.assertEqual(status, 400, "раньше payload молча резался в битый JSON")

    # --- обезличенная статистика ---

    def test_stat_roundtrip(self):
        status, _ = _call(self.port, "POST", "/api/stat", {
            "device": "d1", "day": "2026-08-06", "app": "1.0", "ios": "18.5",
            "model": "iPhone14,2", "location_auth": "always", "onboarded": True,
            "trips": 3, "km": 42.5, "alerts": 17, "passes": 9, "reports": 1,
            "screens": {"map": 5, "stats": 2}})
        self.assertEqual(status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT location_auth, trips, km, screens FROM usage_stats").fetchone()
        conn.close()
        self.assertEqual(row[0], "always")
        self.assertEqual(row[1], 3)
        self.assertAlmostEqual(row[2], 42.5)
        self.assertEqual(json.loads(row[3]), {"map": 5, "stats": 2})

    def test_stat_is_one_row_per_device_per_day(self):
        """Сеть могла оборвать подтверждение — повтор не должен раздувать
        «сколько у нас пользователей»."""
        payload = {"device": "d1", "day": "2026-08-06", "trips": 1}
        _call(self.port, "POST", "/api/stat", payload)
        _call(self.port, "POST", "/api/stat", {**payload, "trips": 2})
        conn = sqlite3.connect(api.DB_PATH)
        count, trips = conn.execute("SELECT COUNT(*), MAX(trips) FROM usage_stats").fetchone()
        conn.close()
        self.assertEqual(count, 1)
        self.assertEqual(trips, 2, "повтор перезаписывает, а не добавляет")

    def test_stat_rejects_bad_day_and_auth(self):
        for bad in ({"device": "d", "day": "вчера"},
                    {"device": "d", "day": "2026-08-06", "location_auth": "root"},
                    {"device": "", "day": "2026-08-06"}):
            status, _ = _call(self.port, "POST", "/api/stat", bad)
            self.assertEqual(status, 400, bad)

    def test_stat_sanitizes_absurd_counters(self):
        _call(self.port, "POST", "/api/stat", {
            "device": "d1", "day": "2026-08-06",
            "trips": -5, "alerts": 10**12, "km": 999999, "screens": "не словарь"})
        conn = sqlite3.connect(api.DB_PATH)
        trips, alerts, km, screens = conn.execute(
            "SELECT trips, alerts, km, screens FROM usage_stats").fetchone()
        conn.close()
        self.assertEqual((trips, alerts), (0, 0), "испорченные счётчики не должны искажать сводку")
        self.assertEqual(km, 0.0, "20 000 км за сутки — это не поездка")
        self.assertEqual(json.loads(screens), {})

    def test_stat_ip_cap(self):
        for i in range(api.IP_DAILY_CAPS["stat"]):
            _call(self.port, "POST", "/api/stat",
                  {"device": f"d{i}", "day": "2026-08-06"}, ip="10.7.7.7")
        status, _ = _call(self.port, "POST", "/api/stat",
                          {"device": "extra", "day": "2026-08-06"}, ip="10.7.7.7")
        self.assertEqual(status, 429, "ротация device не должна лить статистику без предела")

    # --- схема и нагрузка ---

    def test_real_ip_header_wins_over_forwarded_for(self):
        """Верить можно только заголовку, который ПЕРЕЗАПИСЫВАЕТ nginx.

        На проде он ставил X-Real-IP, а api.py читал X-Forwarded-For, которого
        nginx не трогал, — то есть его значение приходило от клиента. Проверено
        живым запросом: «X-Forwarded-For: 8.8.8.8» списывался с чужого лимита.
        Так обходились все суточные капы и подделывался кворум «разных
        адресов», по которому снимается отметка с карты.
        """
        url = f"http://127.0.0.1:{self.port}/api/report"
        body = json.dumps({"lat": 41.31, "lon": 69.25, "device": "spoofer"}).encode()
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Content-Type": "application/json",
            "X-Real-IP": "10.0.0.1",        # то, что поставил бы nginx
            "X-Forwarded-For": "8.8.8.8",   # то, что подсунул бы клиент
        })
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        ip = conn.execute("SELECT ip FROM reports").fetchone()[0]
        conn.close()
        self.assertEqual(ip, "10.0.0.1", "клиентский заголовок не должен побеждать")
        with api._ip_lock:
            keys = {key[2] for key in api._ip_counters}
        self.assertIn("10.0.0.1", keys)
        self.assertNotIn("8.8.8.8", keys, "кап списан с подделанного адреса")

    def test_wal_and_indexes_are_set_up(self):
        """WAL и индексы ставятся один раз в init_db, а не на каждый запрос."""
        conn = sqlite3.connect(api.DB_PATH)
        mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
        names = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index'")}
        conn.close()
        self.assertEqual(mode.lower(), "wal",
                         "без WAL писатель блокирует читателей и они получают 500")
        for index in ("idx_reports_live", "idx_camrep_camera", "idx_feedback_received",
                      "idx_metrics_device", "idx_votes_device"):
            self.assertIn(index, names, f"нет индекса {index} — полный скан на каждый кап")

    def test_db_connection_does_not_touch_schema(self):
        """db() обязан быть дешёвым: раньше он гонял всю миграцию на КАЖДЫЙ
        HTTP-запрос — шесть CREATE TABLE и четыре ALTER, все четыре в исключение."""
        conn = api.db()
        try:
            self.assertEqual(conn.execute("PRAGMA busy_timeout").fetchone()[0],
                             api.BUSY_TIMEOUT_MS,
                             "без busy_timeout параллельная запись даёт мгновенный 500")
        finally:
            conn.close()
        # схему db() не создаёт — проверяем на пустом файле
        empty = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        saved, api.DB_PATH = api.DB_PATH, empty.name
        try:
            conn = api.db()
            tables = conn.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'").fetchone()[0]
            conn.close()
        finally:
            api.DB_PATH = saved
        self.assertEqual(tables, 0, "db() не должен создавать схему")

    def test_camera_report_stores_ip(self):
        """Кворум на скрытие камеры считается по разным адресам, а не по
        device: UUID ротируется бесплатно, и «5 разных устройств» подделывалось
        одним телефоном. Снятая по фейку живая камера — это молчание там, где
        камера стоит, худший отказ системы."""
        _call(self.port, "POST", "/api/camera_report",
              {"camera_id": 7, "reason": "gone", "device": "d1"}, ip="10.5.5.5")
        conn = sqlite3.connect(api.DB_PATH)
        ip = conn.execute("SELECT ip FROM camera_reports").fetchone()[0]
        conn.close()
        self.assertEqual(ip, "10.5.5.5")

    def test_bounded_server_refuses_over_capacity(self):
        """Сверх потолка потоков — честный 503, а не бесконечная очередь."""
        class FakeSocket:
            def __init__(self): self.sent = b""; self.closed = False
            def sendall(self, data): self.sent += data
            def shutdown(self, how): pass
            def close(self): self.closed = True

        server = api.BoundedHTTPServer(("127.0.0.1", 0), api.Handler, max_workers=1)
        try:
            self.assertTrue(server._slots.acquire(blocking=False))  # занимаем единственный слот
            sock = FakeSocket()
            server.process_request(sock, ("10.0.0.1", 1234))
            self.assertIn(b"503", sock.sent)
            self.assertTrue(sock.closed, "соединение сверх потолка должно закрываться")
        finally:
            server.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
