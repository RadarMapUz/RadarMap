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


def _get_raw(port, path, etag=None):
    """GET с заголовками ответа: 304 без тела проверить через _call нельзя."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method="GET")
    if etag:
        req.add_header("If-None-Match", etag)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


class ServerTestBase(unittest.TestCase):
    """Настоящий сервер на случайном порту с временными базами."""
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        api.DB_PATH = cls.tmp.name
        api.init_db()      # схема, миграции и индексы — один раз, как в проде
        cls.traffic_tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        api.TRAFFIC_DB_PATH = cls.traffic_tmp.name
        api.init_traffic_db()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        conn = sqlite3.connect(api.DB_PATH)
        for table in ("reports", "votes", "metrics", "camera_reports", "feedback",
                      "usage_stats", "blocked", "cng"):
            conn.execute(f"DELETE FROM {table}")
        conn.commit()
        conn.close()
        conn = sqlite3.connect(api.TRAFFIC_DB_PATH)
        conn.execute("DELETE FROM traffic_pieces")
        conn.execute("DELETE FROM traffic_seen")
        conn.commit()
        conn.close()
        with api._ip_lock:
            api._ip_counters.clear()
        with api._cleanup_lock:
            api._last_cleanup = 0.0
        # Мемо ответа /api/mobile переживает удаление строк напрямую из базы:
        # версию оно бампает только на запись через API.
        with api._mobile_lock:
            api._mobile_cache = None
            api._road_cache = None


class APITest(ServerTestBase):
    # --- дешёвый опрос: ETag и 304 ---

    def test_unchanged_list_answers_304_without_body(self):
        """Ради этого всё и делалось: телефон в поездке спрашивает часто, а
        платит за ответ только когда есть новости."""
        _call(self.port, "POST", "/api/report",
              {"lat": 41.31, "lon": 69.25, "device": "me"})
        status, headers, body = _get_raw(self.port, "/api/mobile")
        self.assertEqual(status, 200)
        etag = headers.get("ETag")
        self.assertTrue(etag, "ответ обязан нести отпечаток")
        again, headers2, body2 = _get_raw(self.port, "/api/mobile", etag=etag)
        self.assertEqual(again, 304, "список не менялся, а сервер прислал тело")
        self.assertEqual(body2, b"")
        self.assertEqual(headers2.get("ETag"), etag)

    def test_new_report_changes_the_etag(self):
        _, _headers, _body = _get_raw(self.port, "/api/mobile")
        first = _headers.get("ETag")
        _call(self.port, "POST", "/api/report",
              {"lat": 41.31, "lon": 69.25, "device": "me"})
        status, headers, _ = _get_raw(self.port, "/api/mobile", etag=first)
        self.assertEqual(status, 200, "появилась отметка, а телефону сказали 304")
        self.assertNotEqual(headers.get("ETag"), first)

    def test_memo_does_not_hide_a_fresh_report(self):
        """Мемо живёт секунду, и без сброса версии отметка, поставленная сразу
        после чужого опроса, ждала бы эту секунду — ровно того водителя, что
        едет следом, она и касается."""
        _get_raw(self.port, "/api/mobile")
        _call(self.port, "POST", "/api/report",
              {"lat": 41.32, "lon": 69.26, "device": "me"})
        _, live = _call(self.port, "GET", "/api/mobile")
        self.assertEqual(len(live["reports"]), 1)

    def test_etag_does_not_drift_while_nothing_changes(self):
        """Отпечаток считается по содержимому, а не по времени сборки: иначе
        304 не случился бы никогда."""
        _call(self.port, "POST", "/api/report",
              {"lat": 41.31, "lon": 69.25, "device": "me"})
        _, first, _ = _get_raw(self.port, "/api/mobile")
        with api._mobile_lock:
            api._mobile_cache = None      # заставляем пересобрать тело заново
        _, second, _ = _get_raw(self.port, "/api/mobile")
        self.assertEqual(first.get("ETag"), second.get("ETag"))

    def test_cache_control_forbids_silent_reuse(self):
        _, headers, _ = _get_raw(self.port, "/api/mobile")
        self.assertEqual(headers.get("Cache-Control"), "no-cache",
                         "max-age дал бы телефону право не спрашивать вовсе")

    # --- передвижные радары ---

    # --- холодный старт: испытательный срок по плотности ---

    def test_new_report_gets_full_life_while_nobody_can_confirm(self):
        """Первые недели подтверждать некому: испытательный срок убивал бы
        честную отметку просто потому, что рядом нет второго водителя."""
        api._probation_cache = (0.0, None)
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "first", "type": "tripod"})
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute(
            "SELECT created, expires FROM reports WHERE id = ?", (made["id"],)).fetchone()
        conn.close()
        self.assertAlmostEqual(expires - created, api.REPORT_TTLS["tripod"], delta=5)

    def test_probation_switches_on_by_itself_once_density_appears(self):
        """Флаг, который однажды поставят и забудут, — не защита. Срок
        включается сам, как только отметки ставят достаточно разных людей."""
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        for index in range(api.PROBATION_MIN_DEVICES):
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, "
                         "active) VALUES(41.0, 69.0, ?, ?, ?, 'radar', 0)",
                         (now - 3600, now - 60, "driver-%d" % index))
        conn.commit()
        conn.close()
        api._probation_cache = (0.0, None)
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.5, "lon": 69.9, "device": "fresh", "type": "tripod"})
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute(
            "SELECT created, expires FROM reports WHERE id = ?", (made["id"],)).fetchone()
        conn.close()
        self.assertAlmostEqual(expires - created, api.PROBATION_TTLS["tripod"], delta=5)

    def test_old_activity_does_not_count_as_density(self):
        """Плотность — это «есть кому подтвердить СЕЙЧАС», а не «когда-то
        было оживлённо»."""
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        for index in range(api.PROBATION_MIN_DEVICES + 5):
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, "
                         "active) VALUES(41.0, 69.0, ?, ?, ?, 'radar', 0)",
                         (now - api.PROBATION_WINDOW - 86400, now - 86400, "old-%d" % index))
        conn.commit()
        conn.close()
        api._probation_cache = (0.0, None)
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.5, "lon": 69.9, "device": "fresh", "type": "tripod"})
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute(
            "SELECT created, expires FROM reports WHERE id = ?", (made["id"],)).fetchone()
        conn.close()
        self.assertAlmostEqual(expires - created, api.REPORT_TTLS["tripod"], delta=5)

    def test_manual_override_wins_over_density(self):
        """Волна фейков — единственный случай, когда владельцу нужно включить
        срок руками, не дожидаясь расчёта."""
        api._probation_cache = (0.0, None)
        original = api.PROBATION_MODE
        api.PROBATION_MODE = "on"
        try:
            _, made = _call(self.port, "POST", "/api/report",
                            {"lat": 41.31, "lon": 69.25, "device": "solo", "type": "tripod"})
            conn = sqlite3.connect(api.DB_PATH)
            created, expires = conn.execute(
                "SELECT created, expires FROM reports WHERE id = ?", (made["id"],)).fetchone()
            conn.close()
            self.assertAlmostEqual(expires - created, api.PROBATION_TTLS["tripod"], delta=5)
        finally:
            api.PROBATION_MODE = original

    # --- отзыв своей отметки ---

    def test_author_cancels_own_fresh_report(self):
        """Промах пальцем должен отзываться, иначе единственный выход —
        голосовать против себя, а в одиночку это и не работает."""
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "me"})
        status, body = _call(self.port, "POST", "/api/report/cancel",
                             {"id": made["id"], "device": "me"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        _, live = _call(self.port, "GET", "/api/mobile")
        self.assertEqual(live["reports"], [], "отозванная отметка осталась на карте")

    def test_cancel_refuses_someone_elses_report(self):
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "me"})
        status, _body = _call(self.port, "POST", "/api/report/cancel",
                              {"id": made["id"], "device": "stranger"})
        self.assertEqual(status, 403, "чужую отметку снимать нельзя")
        _, live = _call(self.port, "GET", "/api/mobile")
        self.assertEqual(len(live["reports"]), 1)

    def test_cancel_refuses_after_someone_confirmed(self):
        """Право автора кончается там, где начинается чужое доверие: точку,
        которую подтвердил другой водитель, снимает кворум, а не автор."""
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "me"})
        _call(self.port, "POST", "/api/vote",
              {"id": made["id"], "device": "other", "value": 1}, ip="10.1.1.1")
        status, _body = _call(self.port, "POST", "/api/report/cancel",
                              {"id": made["id"], "device": "me"})
        self.assertEqual(status, 409)

    def test_cancel_is_idempotent_on_already_dead_report(self):
        """Повтор после обрыва сети не должен выглядеть ошибкой: результат
        ровно тот, которого просили."""
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "me"})
        _call(self.port, "POST", "/api/report/cancel", {"id": made["id"], "device": "me"})
        status, body = _call(self.port, "POST", "/api/report/cancel",
                             {"id": made["id"], "device": "me"})
        self.assertEqual(status, 200)
        self.assertTrue(body.get("already"))

    def test_cancel_refuses_stale_report(self):
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "me"})
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("UPDATE reports SET created = ? WHERE id = ?",
                     (time.time() - api.CANCEL_WINDOW - 60, made["id"]))
        conn.commit()
        conn.close()
        status, _body = _call(self.port, "POST", "/api/report/cancel",
                              {"id": made["id"], "device": "me"})
        self.assertEqual(status, 409, "через час это уже не промах пальцем")

    # --- теневой бан ---

    def test_blocked_source_gets_normal_answer_but_empty_map(self):
        """Заблокированный не должен узнать, что он заблокирован: иначе он
        подбирает обход вместо того, чтобы бросить."""
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("INSERT INTO blocked(kind, value, until, note, created) "
                     "VALUES('ip', '10.9.9.9', ?, 'спам', ?)",
                     (time.time() + 3600, time.time()))
        conn.commit()
        conn.close()
        status, body = _call(self.port, "POST", "/api/report",
                             {"lat": 41.31, "lon": 69.25, "device": "spammer"},
                             ip="10.9.9.9")
        self.assertEqual(status, 200, "ответ обязан быть обычным")
        self.assertIn("id", body)
        _, live = _call(self.port, "GET", "/api/mobile")
        self.assertEqual(live["reports"], [], "отметка заблокированного попала на карту")

    def test_block_by_device_survives_new_network(self):
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("INSERT INTO blocked(kind, value, until, note, created) "
                     "VALUES('device', 'badguy', ?, '', ?)",
                     (time.time() + 3600, time.time()))
        conn.commit()
        conn.close()
        _call(self.port, "POST", "/api/report",
              {"lat": 41.31, "lon": 69.25, "device": "badguy"}, ip="10.5.5.5")
        _, live = _call(self.port, "GET", "/api/mobile")
        self.assertEqual(live["reports"], [])

    def test_expired_block_lets_reports_through(self):
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("INSERT INTO blocked(kind, value, until, note, created) "
                     "VALUES('ip', '10.9.9.9', ?, '', ?)",
                     (time.time() - 60, time.time() - 3600))
        conn.commit()
        conn.close()
        _call(self.port, "POST", "/api/report",
              {"lat": 41.31, "lon": 69.25, "device": "reformed"}, ip="10.9.9.9")
        _, live = _call(self.port, "GET", "/api/mobile")
        self.assertEqual(len(live["reports"]), 1, "срок блокировки истёк — отметка должна жить")

    # --- радиус слияния по классу дороги ---

    def test_two_tripods_on_a_highway_stay_two_points(self):
        """250 м на трассе — две разные засады. Раньше вторая молча
        засчитывалась подтверждением первой."""
        _call(self.port, "POST", "/api/report",
              {"lat": 41.0, "lon": 65.0, "device": "a", "type": "tripod",
               "cls": "residential"})
        status, body = _call(self.port, "POST", "/api/report",
                             {"lat": 41.00225, "lon": 65.0, "device": "b",
                              "type": "tripod", "cls": "residential"})
        self.assertFalse(body["merged"], "в квартале 250 м — разные точки")

    def test_same_spot_on_a_highway_still_merges(self):
        _call(self.port, "POST", "/api/report",
              {"lat": 41.0, "lon": 65.0, "device": "a", "type": "tripod",
               "cls": "motorway"})
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.00225, "lon": 65.0, "device": "b",
                         "type": "tripod", "cls": "motorway"})
        self.assertTrue(body["merged"], "250 м на трассе — та же тренога")

    def test_unknown_class_keeps_the_old_radius(self):
        """Старый клиент класс не шлёт — поведение обязано остаться прежним."""
        _call(self.port, "POST", "/api/report",
              {"lat": 41.0, "lon": 65.0, "device": "a"})
        _, body = _call(self.port, "POST", "/api/report",
                        {"lat": 41.00225, "lon": 65.0, "device": "b"})
        self.assertTrue(body["merged"])

    # --- причина закрытия (для метрик качества) ---

    def test_closed_reason_records_who_ended_the_report(self):
        """Без причины «доля подтверждённых» и «доля снесённых» неотличимы:
        в таблице видно только active = 0."""
        _, mine = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "me"})
        _call(self.port, "POST", "/api/report/cancel", {"id": mine["id"], "device": "me"})
        _, other = _call(self.port, "POST", "/api/report",
                         {"lat": 41.5, "lon": 69.9, "device": "creator"})
        for i, device in enumerate(("h1", "h2", "h3")):
            _call(self.port, "POST", "/api/vote",
                  {"id": other["id"], "device": device, "value": -1}, ip=f"10.0.0.{i + 1}")
        conn = sqlite3.connect(api.DB_PATH)
        reasons = dict(conn.execute("SELECT id, closed FROM reports").fetchall())
        conn.close()
        self.assertEqual(reasons[mine["id"]], "author")
        self.assertEqual(reasons[other["id"]], "quorum")

    def test_misplaced_vote_is_kept_apart_for_the_moderator(self):
        """«Стоит не там» — не «радара нет»: точка в двухстах метрах всё равно
        предупреждает, гасить её мгновенно нельзя, но модератор обязан видеть
        именно этот сигнал."""
        _, made = _call(self.port, "POST", "/api/report",
                        {"lat": 41.31, "lon": 69.25, "device": "creator"})
        status, body = _call(self.port, "POST", "/api/vote",
                             {"id": made["id"], "device": "driver", "value": -1,
                              "kind": "misplaced"}, ip="10.2.2.2")
        self.assertEqual(status, 200)
        self.assertTrue(body["active"], "один голос не гасит отметку")
        conn = sqlite3.connect(api.DB_PATH)
        kind = conn.execute("SELECT kind FROM votes WHERE report_id = ?",
                            (made["id"],)).fetchone()[0]
        conn.close()
        self.assertEqual(kind, "misplaced")


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

    def test_queued_report_lives_from_when_it_was_marked(self):
        """Отметка из очереди телефона (не было связи) — срок от момента,
        когда её поставили (S25); вздорный возраст не принимается."""
        import time as t
        now = t.time()
        _, fresh = _call(self.port, "POST", "/api/report",
                         {"lat": 41.45, "lon": 69.45, "device": "q1", "type": "tripod"})
        _, late = _call(self.port, "POST", "/api/report",
                        {"lat": 41.55, "lon": 69.55, "device": "q2", "type": "tripod", "age": 2400})
        _, silly = _call(self.port, "POST", "/api/report",
                         {"lat": 41.65, "lon": 69.65, "device": "q3", "type": "tripod", "age": "много"})
        conn = sqlite3.connect(api.DB_PATH)
        exp = {rid: conn.execute("SELECT expires FROM reports WHERE id = ?", (rid,)).fetchone()[0]
               for rid in (fresh["id"], late["id"], silly["id"])}
        conn.close()
        self.assertAlmostEqual(exp[fresh["id"]] - exp[late["id"]], 2400, delta=5)
        self.assertGreater(exp[late["id"]], now, "но ещё жива")
        self.assertAlmostEqual(exp[silly["id"]], exp[fresh["id"]], delta=5)

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

    def _seed_density(self):
        """Плотность, при которой испытательный срок вообще имеет смысл:
        подтверждать отметку должно быть кому (см. probation_active)."""
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        for index in range(api.PROBATION_MIN_DEVICES):
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, "
                         "active) VALUES(41.0, 69.0, ?, ?, ?, 'radar', 0)",
                         (now - 3600, now - 60, "seed-%d" % index))
        conn.commit()
        conn.close()
        api._probation_cache = (0.0, None)

    def test_new_report_lives_probation_not_full_ttl(self):
        """Неподтверждённая отметка живёт испытательный срок: фейк, которого
        никто не подтвердил, умирает сам — без модерации и кворума.

        Плотность засеваем явно: с пустой базой срок не включается вовсе, и
        это отдельное поведение со своим тестом (холодный старт)."""
        self._seed_density()
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

    def test_metrics_accepts_large_diagnostic(self):
        # Диагностика с деревом стеков бывает за 200 КБ — раньше её отбивало 400.
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "diagnostic", "payload": "x" * 600000})
        self.assertEqual(status, 200)

    def test_metrics_diagnostic_still_has_a_ceiling(self):
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "diagnostic", "payload": "x" * 2010000})
        self.assertEqual(status, 400)

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

    def test_stat_stores_decision_quality_counters(self):
        """Счётчики качества решений обязаны ДОХОДИТЬ до базы.

        Три недели они считались на телефоне и не доезжали: клиент собирал
        payload руками и новые поля в него не дописал, а у сервера не было
        куда их положить. На эти данные был заложен план А4 — и ждал их
        впустую."""
        status, _ = _call(self.port, "POST", "/api/stat", {
            "device": "d1", "day": "2026-08-06", "trips": 1,
            "limitSource": {"tag": 7, "assumed": 2, "none": 1},
            "maneuvers": {"right": 4, "roundabout": 1},
            "tripsDropped": {"short": 1},
            "alertRecall": {"passed": 49, "warned": 47, "silent": 2}})
        self.assertEqual(status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT quality FROM usage_stats").fetchone()
        conn.close()
        quality = json.loads(row[0])
        self.assertEqual(quality["limitSource"], {"tag": 7, "assumed": 2, "none": 1})
        self.assertEqual(quality["alertRecall"]["warned"], 47)
        self.assertEqual(quality["maneuvers"]["right"], 4)

    def test_stat_stores_carplay_session_counters(self):
        """Экран машины: сессии, минуты, фризы. Жалоба «на CarPlay км/ч не
        работает» приходит из машины, где лог не прочесть."""
        _call(self.port, "POST", "/api/stat", {
            "device": "d3", "day": "2026-10-10",
            "carPlay": {"sessions": 1, "minutes": 34, "hitches": 2, "longHitches": 1,
                        "maxHitchMs": 1800}})
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT quality FROM usage_stats WHERE device='d3'").fetchone()
        conn.close()
        quality = json.loads(row[0])
        self.assertEqual(quality["carPlay"]["minutes"], 34)
        self.assertEqual(quality["carPlay"]["maxHitchMs"], 1800)

    def test_stat_quality_is_counters_and_nothing_else(self):
        """Та же дисциплина, что у screens: значение проходит через clamp_int,
        ключ обрезается. Координате или времени тут не во что попасть."""
        _call(self.port, "POST", "/api/stat", {
            "device": "d2", "day": "2026-08-06",
            "limitSource": {"x" * 80: "41.311,69.279", "ok": 5},
            "alertRecall": "не словарь"})
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT quality FROM usage_stats WHERE device='d2'").fetchone()
        conn.close()
        quality = json.loads(row[0])
        # Строка с координатами превратилась в ноль, длинный ключ обрезан.
        self.assertEqual(quality["limitSource"]["ok"], 5)
        self.assertEqual(quality["limitSource"]["x" * 24], 0)
        self.assertNotIn("alertRecall", quality)

    def test_stat_stores_data_versions_from_a_closed_list(self):
        """Что дошло до телефона: номера публикаций и ничего больше."""
        _call(self.port, "POST", "/api/stat", {
            "device": "d3", "day": "2026-09-27",
            "dataVersions": {"cameras": 12, "limits": 1790513640, "roads": 0x834f04a,
                             "lat": 41311, "home": "41.311,69.279"}})
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT quality FROM usage_stats WHERE device='d3'").fetchone()
        conn.close()
        versions = json.loads(row[0])["dataVersions"]
        self.assertEqual(versions, {"cameras": 12, "limits": 1790513640, "roads": 0x834f04a})
        self.assertNotIn("lat", versions, "ключ вне списка не должен доезжать")

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



class TrafficTest(ServerTestBase):
    """Куски следа для пробок. Важнее формы — то, чего сервер НЕ должен
    сделать: сохранить устройство, поездку, время или точку за границей."""

    @staticmethod
    def piece(lat=41.3110, lon=69.2790, n=6, step=0.0006, dt=8, extra=None):
        p = {"p": [[lat + i * step, lon, i * dt, 40] for i in range(n)]}
        if extra:
            p.update(extra)
        return p

    def stored(self):
        conn = sqlite3.connect(api.TRAFFIC_DB_PATH)
        rows = conn.execute("SELECT points FROM traffic_pieces").fetchall()
        conn.close()
        return [json.loads(r[0]) for r in rows]

    def test_accepts_clean_piece_and_stores_only_numbers(self):
        status, body = _call(self.port, "POST", "/api/traffic",
                             {"v": 1, "device": "abc", "trip": 7,
                              "pieces": [self.piece(extra={"device": "abc", "ts": 1760000000})]})
        self.assertEqual((status, body.get("accepted")), (200, 1))
        rows = self.stored()
        self.assertEqual(len(rows), 1)
        self.assertTrue(all(len(point) == 4 for point in rows[0]))
        raw = json.dumps(rows)
        for leak in ("device", "abc", "trip", "ts", "1760000000"):
            self.assertNotIn(leak, raw)

    def test_rejects_bad_envelope(self):
        for payload in ({"v": 2, "pieces": []}, {"pieces": []}, {"v": 1, "pieces": "x"}):
            status, _ = _call(self.port, "POST", "/api/traffic", payload)
            self.assertEqual(status, 400)

    def test_skips_bad_pieces_keeps_good(self):
        outside = self.piece(lat=55.75, lon=37.61)            # Москва
        short = self.piece(n=2)
        late_start = {"p": [[41.31, 69.27, 5, 40], [41.311, 69.27, 10, 40], [41.312, 69.27, 15, 40]]}
        teleport = {"p": [[41.31, 69.27, 0, 40], [41.40, 69.27, 1, 40], [41.41, 69.27, 2, 40]]}
        status, body = _call(self.port, "POST", "/api/traffic",
                             {"v": 1, "pieces": [outside, short, late_start, teleport, self.piece()]})
        self.assertEqual((status, body.get("accepted")), (200, 1))
        self.assertEqual(len(self.stored()), 1)

    def test_ip_quota(self):
        old = api.TRAFFIC_PIECES_PER_IP_DAY
        api.TRAFFIC_PIECES_PER_IP_DAY = 2
        try:
            status, body = _call(self.port, "POST", "/api/traffic",
                                 {"v": 1, "pieces": [self.piece(lat=41.31 + i * 0.01) for i in range(3)]},
                                 ip="10.0.0.9")
            self.assertEqual(body.get("accepted"), 2)
            status, body = _call(self.port, "POST", "/api/traffic",
                                 {"v": 1, "pieces": [self.piece(lat=41.35)]}, ip="10.0.0.10")
            self.assertEqual(body.get("accepted"), 1, "лимит — на адрес, а не на всех")
        finally:
            api.TRAFFIC_PIECES_PER_IP_DAY = old

    def test_repeat_of_a_lost_answer_is_stored_once(self):
        """Ответ потерялся — телефон шлёт ту же пачку снова: одна машина не
        набирает «два независимых куска» сама с собой."""
        batch = {"v": 1, "pieces": [self.piece(), self.piece(lat=41.32)]}
        status, body = _call(self.port, "POST", "/api/traffic", batch)
        self.assertEqual((status, body.get("accepted")), (200, 2))
        status, body = _call(self.port, "POST", "/api/traffic", batch)
        self.assertEqual(status, 200, "повтор — не ошибка: телефон должен снять его с очереди")
        self.assertEqual(body.get("accepted"), 0)
        self.assertEqual(len(self.stored()), 2)
        # Внутри одной пачки — тоже.
        status, body = _call(self.port, "POST", "/api/traffic",
                             {"v": 1, "pieces": [self.piece(lat=41.33)] * 2})
        self.assertEqual(body.get("accepted"), 1)
        self.assertEqual(len(self.stored()), 3)

    def test_repeat_does_not_spend_the_address_quota(self):
        old = api.TRAFFIC_PIECES_PER_IP_DAY
        api.TRAFFIC_PIECES_PER_IP_DAY = 2
        try:
            first = {"v": 1, "pieces": [self.piece(lat=41.36)]}
            _call(self.port, "POST", "/api/traffic", first, ip="10.0.0.21")
            _call(self.port, "POST", "/api/traffic", first, ip="10.0.0.21")
            status, body = _call(self.port, "POST", "/api/traffic",
                                 {"v": 1, "pieces": [self.piece(lat=41.37)]}, ip="10.0.0.21")
            self.assertEqual(body.get("accepted"), 1, "повтор не съел квоту адреса")
        finally:
            api.TRAFFIC_PIECES_PER_IP_DAY = old

    def test_seen_marks_expire(self):
        old = api.TRAFFIC_SEEN_TTL
        api.TRAFFIC_SEEN_TTL = -1
        try:
            batch = {"v": 1, "pieces": [self.piece()]}
            _call(self.port, "POST", "/api/traffic", batch)
            status, body = _call(self.port, "POST", "/api/traffic", batch)
            self.assertEqual(body.get("accepted"), 1, "отпечаток истёк — кусок снова новый")
        finally:
            api.TRAFFIC_SEEN_TTL = old
        conn = sqlite3.connect(api.TRAFFIC_DB_PATH)
        rows = conn.execute("SELECT * FROM traffic_seen").fetchall()
        conn.close()
        self.assertTrue(all(len(row) == 2 for row in rows), "в отпечатке — только хэш и время приёма")

class RoadEventsTest(ServerTestBase):
    """Перекрытия и ремонт (12б.5): свой список, свои сроки, курс отметившего."""

    def report(self, rtype, device="d1", lat=41.31, lon=69.25, **extra):
        body = {"lat": lat, "lon": lon, "device": device, "type": rtype}
        body.update(extra)
        return _call(self.port, "POST", "/api/report", body)

    def test_old_clients_never_see_road_events(self):
        """Старые сборки читают незнакомый тип как «радар» — в /api/mobile
        перекрытию и ремонту не место."""
        self.report("closure")
        self.report("radar", device="d2", lat=41.35)
        _, mobile = _call(self.port, "GET", "/api/mobile")
        self.assertEqual([r["type"] for r in mobile["reports"]], ["radar"])
        _, road = _call(self.port, "GET", "/api/road")
        self.assertEqual([r["type"] for r in road["reports"]], ["closure"])

    def test_course_travels_and_garbage_is_unknown(self):
        self.report("closure", course=93.5)
        self.report("roadwork", device="d2", lat=41.35, course=999)
        _, road = _call(self.port, "GET", "/api/road")
        courses = sorted(r["course"] for r in road["reports"])
        self.assertEqual(courses, [-1, 93.5], "курс вне 0…360 — неизвестен, а не 999")

    def test_lifetimes_probation_and_full(self):
        api._probation_cache = (time.time(), True)     # испытательный срок включён
        try:
            _, made = self.report("roadwork")
            conn = sqlite3.connect(api.DB_PATH)
            created, expires = conn.execute(
                "SELECT created, expires FROM reports WHERE id = ?", (made["id"],)).fetchone()
            conn.close()
            self.assertAlmostEqual(expires - created, 24 * 3600, delta=5, msg="ремонт: сутки на испытании")
            full = api.lifecycle_expires(created, expires, "roadwork", True, created + 3600)
            self.assertAlmostEqual(full - created, 7 * 86400, delta=5,
                                   msg="подтверждённый ремонт — неделя, MAX_LIFE его не режет")
            self.assertAlmostEqual(api.lifecycle_expires(created, created + 3 * 3600, "closure", True,
                                                         created + 600) - created, 12 * 3600, delta=5)
        finally:
            api._probation_cache = (0.0, None)

    def test_road_events_do_not_lock_the_radar_button(self):
        """Ремонт живёт неделю: три своих ремонта не запирают «Радар!»."""
        for index in range(3):
            conn = sqlite3.connect(api.DB_PATH)
            now = time.time()
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, ip, active) "
                         "VALUES(?,?,?,?,?,?,?,1)",
                         (41.30 + index * 0.02, 69.2, now - 600, now + 86400, "me", "roadwork", "1.1.1.1"))
            conn.commit()
            conn.close()
        status, _ = self.report("radar", device="me", lat=41.40)
        self.assertEqual(status, 200)

    def test_refine_moves_point_between_lists(self):
        """«Радар!» → «Что это было?» → «перекрыто»: та же точка уходит из
        списка камер в список дороги — только по явному amend_id."""
        _, made = self.report("radar", device="me")
        status, amended = self.report("closure", device="me", amend_id=made["id"])
        self.assertEqual(status, 200)
        self.assertTrue(amended.get("amended"))
        _, mobile = _call(self.port, "GET", "/api/mobile")
        _, road = _call(self.port, "GET", "/api/road")
        self.assertEqual(mobile["reports"], [])
        self.assertEqual([r["id"] for r in road["reports"]], [made["id"]])


    def test_implicit_amend_never_crosses_camera_road_boundary(self):
        """«Ремонт» рукой в 300 м от своего свежего «Радар!» — новая точка,
        а не переписанный радар: иначе радар пропадал у всех."""
        _, radar = self.report("radar", device="me")
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("UPDATE reports SET created = created - 200")   # мимо «не чаще 120 с»
        conn.commit()
        conn.close()
        status, road = self.report("roadwork", device="me", lat=41.3125)
        self.assertEqual(status, 200)
        self.assertFalse(road.get("amended"))
        _, mobile = _call(self.port, "GET", "/api/mobile")
        self.assertEqual([r["id"] for r in mobile["reports"]], [radar["id"]], "радар жив")

    def test_crossing_amend_takes_new_type_lifetime(self):
        api._probation_cache = (time.time(), False)     # испытательный срок выключен
        try:
            _, made = self.report("radar", device="me")
            self.report("closure", device="me", amend_id=made["id"])
            conn = sqlite3.connect(api.DB_PATH)
            created, expires = conn.execute(
                "SELECT created, expires FROM reports WHERE id = ?", (made["id"],)).fetchone()
            conn.close()
            self.assertAlmostEqual(expires - created, api.PROBATION_TTLS["closure"], delta=5,
                                   msg="срок перекрытия, а не радара; дороге — всегда испытательный")
        finally:
            api._probation_cache = (0.0, None)

    def test_road_events_have_their_own_ip_cap(self):
        """Дюжина ремонтов за одним адресом не запирает «Радар!» всем за ним."""
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        for index in range(api.MAX_ACTIVE_PER_IP):
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, ip, active) "
                         "VALUES(?,?,?,?,?,?,?,1)",
                         (41.20 + index * 0.01, 69.1, now - 600, now + 86400, f"d{index}", "roadwork",
                          "127.0.0.1"))
        conn.commit()
        conn.close()
        status, _ = self.report("radar", device="fresh", lat=41.45)
        self.assertEqual(status, 200)
        status, _ = self.report("roadwork", device="fresh2", lat=41.46)
        self.assertEqual(status, 429, "свой кап дороги — исчерпан")

class CngTest(ServerTestBase):
    """Метан на АГНКС (12б.4): тот же цикл доверия, что у радаров, и ответ
    без устройства, адреса и времени отметки."""

    STATION = {"lat": 41.31234, "lon": 69.25678}

    def post(self, kind, device="d1", **extra):
        body = dict(self.STATION, kind=kind, device=device)
        body.update(extra)
        return _call(self.port, "POST", "/api/cng", body)

    def stations(self):
        _, answer = _call(self.port, "GET", "/api/cng")
        return answer["stations"]

    def test_status_and_queue_per_station(self):
        self.assertEqual(self.post("gas")[0], 200)
        self.assertEqual(self.post("queue30", device="d2")[0], 200)
        [station] = self.stations()
        self.assertEqual(station["status"], "gas")
        self.assertEqual(station["queue"], 30)
        self.assertEqual(station["status_age"], 5, "возраст — ступенью 5 мин, не точным временем")
        self.assertEqual(station["queue_age"], 5)

    def test_answer_has_no_device_ip_or_time(self):
        self.post("nogas", device="secret-device")
        _, _, body = _get_raw(self.port, "/api/cng")
        text = body.decode()
        for leak in ("secret-device", "device", "ip", "127.0.0.1", "created", "expires"):
            self.assertNotIn(leak, text, f"в ответе {leak!r}")

    def test_own_change_of_mind_replaces_not_adds(self):
        self.post("gas")
        self.post("nogas")
        [station] = self.stations()
        self.assertEqual(station["status"], "nogas", "передумал — это не второй голос")
        conn = sqlite3.connect(api.DB_PATH)
        live = conn.execute("SELECT COUNT(*) FROM cng WHERE active = 1").fetchone()[0]
        conn.close()
        self.assertEqual(live, 1)

    def test_probation_and_independent_confirmation(self):
        self.post("gas", device="a")
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute("SELECT created, expires FROM cng").fetchone()
        conn.close()
        self.assertAlmostEqual(expires - created, api.CNG_PROBATION_TTL["status"], delta=5)
        self.assertFalse(self.stations()[0]["confirmed"])
        # Второй голос с другого устройства, но того же адреса — не подтверждение.
        self.post("gas", device="b")
        self.assertFalse(self.stations()[0]["confirmed"], "тот же адрес — не независимый")
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("UPDATE cng SET ip = '10.0.0.9' WHERE device = 'b'")
        conn.commit()
        conn.close()
        self.post("gas", device="c")   # пересчёт: c с 127.0.0.1, b с 10.0.0.9 — независимы
        self.assertTrue(self.stations()[0]["confirmed"])
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute("SELECT created, expires FROM cng WHERE device = 'b'").fetchone()
        conn.close()
        self.assertAlmostEqual(expires - created, api.CNG_FULL_TTL["status"], delta=5)

    def test_queue_lives_shorter_than_status(self):
        self.assertLess(api.CNG_FULL_TTL["queue"], api.CNG_FULL_TTL["status"])
        self.post("queue60")
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute("SELECT created, expires FROM cng").fetchone()
        conn.close()
        self.assertAlmostEqual(expires - created, api.CNG_PROBATION_TTL["queue"], delta=5)

    def test_bad_input_is_refused(self):
        self.assertEqual(self.post("maybe")[0], 400)
        self.assertEqual(_call(self.port, "POST", "/api/cng",
                               {"lat": 55.7, "lon": 37.6, "kind": "gas", "device": "x"})[0], 400)

    def test_expired_is_not_shown(self):
        self.post("gas")
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("UPDATE cng SET expires = ?", (time.time() - 1,))
        conn.commit()
        conn.close()
        self.assertEqual(self.stations(), [])

    def test_fresh_queue_does_not_freshen_old_status(self):
        self.post("gas")
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("UPDATE cng SET created = created - 7000, expires = expires + 3600")
        conn.commit()
        conn.close()
        self.post("queue15", device="d2")
        [station] = self.stations()
        self.assertGreaterEqual(station["status_age"], 115, "статусу почти два часа")
        self.assertEqual(station["queue_age"], 5)

    def test_unconfirmed_rumor_does_not_override_confirmed_status(self):
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        for device, ip in (("a", "10.0.0.1"), ("b", "10.0.0.2")):
            conn.execute("INSERT INTO cng(station, lat, lon, kind, created, expires, device, ip) "
                         "VALUES(?,?,?,?,?,?,?,?)",
                         (api.cng_station_key(**self.STATION), self.STATION["lat"], self.STATION["lon"],
                          "gas", now - 600, now + 3600, device, ip))
        conn.commit()
        conn.close()
        self.post("nogas", device="rumor")
        [station] = self.stations()
        self.assertEqual(station["status"], "gas", "один слух не перекрывает подтверждённый факт")
        self.assertTrue(station["confirmed"])

    def test_blocked_source_posts_nothing_visible(self):
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("INSERT INTO blocked(kind, value, until, created) VALUES('device', 'bad', ?, ?)",
                     (time.time() + 3600, time.time()))
        conn.commit()
        conn.close()
        self.assertEqual(self.post("nogas", device="bad")[0], 200, "заблокированный не должен узнать о блоке")
        self.assertEqual(self.stations(), [])

    def test_one_device_cannot_mark_every_station(self):
        for index in range(api.CNG_DEVICE_DAILY_STATIONS):
            self.assertEqual(self.post("nogas", lat=41.20 + index * 0.01)[0], 200)
        self.assertEqual(self.post("nogas", lat=41.40)[0], 429)
        self.assertEqual(self.post("gas", lat=41.20)[0], 200, "своя станция — ответ можно поменять")

if __name__ == "__main__":
    unittest.main(verbosity=2)


class EtaShareTest(ServerTestBase):
    """«Поделиться прибытием». Важнее формы — что сервер НЕ хранит: ни точки,
    ни цели, ни устройства; и что ссылка гаснет сама."""

    TOKEN = "Q2xhdWRlU2hhcmVkRVRBdGVzdA"

    def setUp(self):
        super().setUp()
        with api._eta_lock:
            api._eta_links.clear()

    def post(self, **fields):
        payload = {"token": self.TOKEN, "eta": time.time() + 25 * 60, "left_m": 12400, "status": "driving"}
        payload.update(fields)
        return _call(self.port, "POST", "/api/eta", payload)

    def page(self, token=None):
        status, headers, body = _get_raw(self.port, f"/api/eta/{token or self.TOKEN}")
        return status, headers, body.decode()

    def test_driver_update_shows_arrival_page(self):
        self.assertEqual(self.post()[0], 200)
        status, headers, html = self.page()
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers.get("Content-Type", ""))
        self.assertEqual(headers.get("Cache-Control"), "no-store")
        self.assertIn("Будет примерно в", html)
        self.assertIn("через 25 мин", html)
        self.assertIn("12,4 км", html)
        self.assertNotIn("<script", html)

    def test_stores_only_four_numbers(self):
        self.post(lat=41.31, lon=69.28, name="Дом", device="abc", dest="Мустакиллик 5")
        with api._eta_lock:
            stored = dict(api._eta_links)
        self.assertEqual(set(stored[self.TOKEN]), {"eta", "left_m", "status", "updated"})
        raw = json.dumps(stored, ensure_ascii=False)
        for leak in ("41.31", "69.28", "Дом", "abc", "Мустакиллик"):
            self.assertNotIn(leak, raw)

    def test_rejects_bad_updates(self):
        for fields in ({"token": "short"}, {"token": "../../etc/passwd" + "x" * 20},
                       {"status": "flying"}, {"eta": time.time() + 10 * 86400},
                       {"eta": "soon"}, {"left_m": -5}, {"eta": True}):
            self.assertEqual(self.post(**fields)[0], 400, fields)

    def test_unknown_or_stale_link_says_so(self):
        status, _, html = self.page("A" * 26)
        self.assertEqual(status, 404)
        self.assertIn("Ссылка устарела", html)
        self.post()
        with api._eta_lock:
            api._eta_links[self.TOKEN]["updated"] -= api.ETA_TTL + 1
        self.assertEqual(self.page()[0], 404, "без обновлений два часа — ссылка гаснет")

    def test_arrival_and_its_short_tail(self):
        self.post(status="arrived", left_m=0)
        status, _, html = self.page()
        self.assertEqual(status, 200)
        self.assertIn("На месте с", html)
        with api._eta_lock:
            api._eta_links[self.TOKEN]["updated"] -= api.ETA_ARRIVED_TTL + 1
        self.assertEqual(self.page()[0], 404)

    def test_uzbek_viewer(self):
        self.post()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/api/eta/{self.TOKEN}",
                                     headers={"Accept-Language": "uz-UZ"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            html = resp.read().decode()
        self.assertIn("daqiqadan keyin", html)

    def test_driver_can_stop_sharing(self):
        self.post()
        self.post(status="ended")
        status, _, html = self.page()
        self.assertEqual(status, 200)
        self.assertIn("больше не отслеживается", html)
