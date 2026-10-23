#!/usr/bin/env python3
"""Тесты RadarMap API: поднимаем настоящий сервер на случайном порту с временной
БД и ходим в него HTTP-клиентом stdlib. Запуск: python3 server/test_api.py
"""
import json
import os
import re
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

import api
import telegram_bot


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
        # Конфиг бота (имя для подсказки Telegram на странице близкого) —
        # несуществующий файл: тесты не читают ничего из /opt/radarmap.
        api.ETA_BOT_CONFIG = os.path.join(tempfile.gettempdir(), "radarmap-no-bot-%d.conf" % os.getpid())
        api._eta_bot.update(checked=None, username=None)
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


# --- Сроки хранения (15.5) ------------------------------------------------------

DAY = 86400
SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
# Колонки, по которым строку можно связать с телефоном или человеком. «who»
# сюда не входит: в панели это имя модератора (candidate_decisions), а хэш
# человека в bot_limits проверяется отдельно.
DEVICE_COLUMNS = {"device", "ip", "contact"}
_CREATE_TABLE = re.compile(r"CREATE TABLE(?: IF NOT EXISTS)?\s+(\w+)\s*\(")


def retention_doc(path=None):
    """Таблица «Таблицы и файлы» из RETENTION.md: имя → потолок в днях или
    None («—»). Строка — `| \\`имя\\` | … |`, потолок — пятая колонка."""
    path = path or os.path.join(SERVER_DIR, "RETENTION.md")
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    section = text.split("## Таблицы и файлы", 1)[1].split("\n## ", 1)[0]
    out = {}
    for line in section.splitlines():
        if not line.startswith("| `"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 7:
            raise AssertionError(f"RETENTION.md: в строке не 7 колонок: {line}")
        name, ceiling = cells[0].strip("`"), cells[4]
        if ceiling == "—":
            out[name] = None
        elif re.fullmatch(r"\d+", ceiling):
            out[name] = int(ceiling)
        else:
            raise AssertionError(f"RETENTION.md: потолок «{ceiling}» у {name} — не число и не «—»")
    return out


def created_tables(filename):
    with open(os.path.join(SERVER_DIR, filename), encoding="utf-8") as handle:
        return set(_CREATE_TABLE.findall(handle.read()))


class RetentionTest(ServerTestBase):
    """Потолок хранения всего, что привязано к устройству. Проверяется то, что
    должно ИСЧЕЗНУТЬ, и то, что обязано остаться: молча стёртая свежая жалоба
    на камеру — такой же провал, как вечно живущий адрес."""

    def setUp(self):
        super().setUp()
        self.now = time.time()
        self.conn = sqlite3.connect(api.DB_PATH)

    def tearDown(self):
        self.conn.close()

    def sweep(self):
        conn = api.db()
        try:
            return api.enforce_retention(conn, self.now)
        finally:
            conn.close()

    def ago(self, days):
        return self.now - days * DAY

    def count(self, sql, args=()):
        return self.conn.execute(sql, args).fetchone()[0]

    def test_feedback_older_than_ceiling_goes_whole_whatever_its_status(self):
        """В тексте бывают место и время проезда («Не предупредила») и телефон —
        вырезать личное из свободного текста нельзя, поэтому строка уходит
        целиком, и неразобранная тоже."""
        old = api.LIVE_MAX_DAYS + 1
        for message, days, status in (("старое новое", old, "new"),
                                      ("старое отвеченное", old, "answered"),
                                      ("свежее", api.LIVE_MAX_DAYS - 1, "new")):
            self.conn.execute("INSERT INTO feedback(message, contact, app_version, device, "
                              "received, status) VALUES(?, '+998 90 000 00 00', '2.3', 'd1', ?, ?)",
                              (message, self.ago(days), status))
        self.conn.commit()
        self.assertEqual(self.sweep()["feedback"], 2)
        left = [row[0] for row in self.conn.execute("SELECT message FROM feedback")]
        self.assertEqual(left, ["свежее"])

    def test_old_camera_report_resolved_goes_unresolved_loses_device_and_ip(self):
        old, fresh = self.ago(api.LIVE_MAX_DAYS + 5), self.ago(10)
        rows = ((7, "gone", "dev-a", "10.0.0.1", old, 1),            # разобрана
                (7, "gone", "dev-b", "10.0.0.2", old, 2),            # отклонена
                (8, "wrong_location", "dev-c", "10.0.0.3", old, 0),  # ждёт модератора
                (8, "wrong_location", "dev-d", "10.0.0.4", fresh, 0))
        for camera_id, reason, device, ip, received, resolved in rows:
            self.conn.execute("INSERT INTO camera_reports(camera_id, reason, lat, lon, "
                              "db_version, device, received, ip, resolved) "
                              "VALUES(?, ?, 41.3, 69.2, 11, ?, ?, ?, ?)",
                              (camera_id, reason, device, received, ip, resolved))
        self.conn.commit()
        done = self.sweep()
        self.assertEqual((done["camera_reports"], done["camera_reports_stripped"]), (2, 1))
        left = self.conn.execute("SELECT camera_id, reason, device, ip, received, lat, resolved "
                                 "FROM camera_reports ORDER BY received").fetchall()
        self.assertEqual(left, [(8, "wrong_location", "", "", old, 41.3, 0),
                                (8, "wrong_location", "dev-d", "10.0.0.4", fresh, 41.3, 0)],
                         "неразобранная жалоба — сигнал очереди: камера, причина и время остаются")
        self.assertEqual(self.sweep()["camera_reports_stripped"], 0, "повторный проход — без работы")

    def test_usage_stats_and_metrics_have_their_ceilings(self):
        for device, days in (("old", api.LIVE_MAX_DAYS + 1), ("new", api.LIVE_MAX_DAYS - 1)):
            self.conn.execute("INSERT INTO usage_stats(device, day, received) VALUES(?, '2026-08-01', ?)",
                              (device, self.ago(days)))
        for device, days in (("old", api.METRICS_KEEP_DAYS + 1), ("new", api.METRICS_KEEP_DAYS - 1)):
            self.conn.execute("INSERT INTO metrics(device, kind, received, payload) "
                              "VALUES(?, 'metric', ?, '{}')", (device, self.ago(days)))
        self.conn.commit()
        self.sweep()
        self.assertEqual([r[0] for r in self.conn.execute("SELECT device FROM usage_stats")], ["new"])
        self.assertEqual([r[0] for r in self.conn.execute("SELECT device FROM metrics")], ["new"])

    def test_metrics_go_even_when_no_new_metrics_arrive(self):
        """Раньше метрики чистились только в POST /api/metrics: выключи их
        пультом — и строки с UUID жили бы вечно."""
        self.conn.execute("INSERT INTO metrics(device, kind, received, payload) "
                          "VALUES('d', 'metric', ?, '{}')", (self.ago(400),))
        self.conn.commit()
        self.sweep()
        self.assertEqual(self.count("SELECT COUNT(*) FROM metrics"), 0)

    def test_ban_goes_when_expired_and_never_outlives_a_month(self):
        rows = (("ip", "10.1.1.1", self.now - 60, self.ago(1)),          # истёк
                ("device", "live", self.now + 3600, self.now),            # действует
                ("ip", "10.2.2.2", self.now + 365 * DAY, self.ago(api.BAN_MAX_DAYS + 1)))
        for kind, value, until, created in rows:
            self.conn.execute("INSERT INTO blocked(kind, value, until, note, created) "
                              "VALUES(?, ?, ?, '', ?)", (kind, value, until, created))
        self.conn.commit()
        self.sweep()
        self.assertEqual([r[0] for r in self.conn.execute("SELECT value FROM blocked")], ["live"])
        self.assertTrue(api.is_blocked(self.conn, "", "live", self.now), "живой бан обязан работать")

    def test_report_backstop_takes_its_votes(self):
        """Метку, продлённую модератором за все сроки, всё равно снимает
        потолок по created — вместе с голосами (в них тоже UUID и адрес)."""
        for device, created in (("old", self.ago(api.LIVE_MAX_DAYS + 1)), ("new", self.now)):
            cur = self.conn.execute("INSERT INTO reports(lat, lon, created, expires, device, ip) "
                                    "VALUES(41.3, 69.2, ?, ?, ?, '10.0.0.1')",
                                    (created, self.now + 3600, device))
            self.conn.execute("INSERT INTO votes(report_id, device, value, ts, ip) "
                              "VALUES(?, ?, 1, ?, '10.0.0.9')", (cur.lastrowid, device + "-voter", created))
        self.conn.commit()
        self.sweep()
        self.assertEqual([r[0] for r in self.conn.execute("SELECT device FROM reports")], ["new"])
        self.assertEqual([r[0] for r in self.conn.execute("SELECT device FROM votes")], ["new-voter"])

    def test_cng_goes_without_new_cng_posts(self):
        rows = (("a", self.ago(2), self.ago(2) + 3600),                          # погасла позавчера
                ("b", self.ago(api.LIVE_MAX_DAYS + 1), self.now + 3600),         # потолок по created
                ("c", self.now, self.now + 3600))                                # живая
        for device, created, expires in rows:
            self.conn.execute("INSERT INTO cng(station, lat, lon, kind, created, expires, device, ip) "
                              "VALUES('41.3000,69.2000', 41.3, 69.2, 'gas', ?, ?, ?, '10.0.0.1')",
                              (created, expires, device))
        self.conn.commit()
        self.sweep()
        self.assertEqual([r[0] for r in self.conn.execute("SELECT device FROM cng")], ["c"])

    def test_sweep_rides_the_mobile_poll_once_an_hour(self):
        """Проход живёт в той же чистке, что и погасшие метки: не на каждый
        запрос, а раз в RETENTION_SWEEP_SECONDS."""
        insert = ("INSERT INTO feedback(message, device, received) VALUES('старое', 'd', ?)",
                  (self.ago(api.LIVE_MAX_DAYS + 1),))
        self.conn.execute(*insert)
        self.conn.commit()
        with api._cleanup_lock:
            api._last_retention = 0.0
        self.assertEqual(_call(self.port, "GET", "/api/mobile")[0], 200)
        self.assertEqual(self.count("SELECT COUNT(*) FROM feedback"), 0, "первый опрос проходит сроки")
        self.conn.execute(*insert)
        self.conn.commit()
        with api._mobile_lock:
            api._mobile_cache = None
        self.assertEqual(_call(self.port, "GET", "/api/mobile")[0], 200)
        self.assertEqual(self.count("SELECT COUNT(*) FROM feedback"), 1,
                         "второй опрос в пределах часа базу сроков не трогает")


class RetentionDocTest(unittest.TestCase):
    """RETENTION.md — единый источник правды о сроках; эти тесты не дают ему
    разойтись с кодом, со схемой и со сроками резервных копий."""

    def test_every_table_on_the_server_has_a_row(self):
        doc = retention_doc()
        sources = sorted(name for name in os.listdir(SERVER_DIR)
                         if name.endswith(".py") and not name.startswith("test_"))
        missing = {}
        for filename in sources:
            absent = created_tables(filename) - set(doc)
            if absent:
                missing[filename] = sorted(absent)
        self.assertEqual(missing, {}, "новая таблица без строки в RETENTION.md")
        self.assertTrue({"feedback", "camera_reports", "overrides"} <= set(doc), "разбор md сломан")

    def test_every_api_table_has_a_ceiling_in_code_equal_to_the_doc(self):
        doc = retention_doc()
        self.assertEqual(created_tables("api.py"), set(api.RETENTION_DAYS),
                         "таблица api.py без записи в api.RETENTION_DAYS")
        for table, days in api.RETENTION_DAYS.items():
            self.assertEqual(doc[table], days, f"{table}: RETENTION.md и код разошлись")
        self.assertEqual(doc["bot_limits"], telegram_bot.BOT_LIMITS_KEEP_DAYS)

    def test_tables_with_device_columns_have_a_ceiling(self):
        """По живой схеме, а не по списку: колонка ip, добавленная миграцией
        в «бессрочную» таблицу, тоже должна покраснеть."""
        doc = retention_doc()
        saved = api.DB_PATH, api.TRAFFIC_DB_PATH
        work = tempfile.mkdtemp()
        try:
            api.DB_PATH = os.path.join(work, "reports.db")
            api.TRAFFIC_DB_PATH = os.path.join(work, "traffic.db")
            api.init_db()
            api.init_traffic_db()
            for path in (api.DB_PATH, api.TRAFFIC_DB_PATH):
                conn = sqlite3.connect(path)
                try:
                    tables = [r[0] for r in conn.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table' "
                        "AND name NOT LIKE 'sqlite_%'")]
                    for table in tables:
                        columns = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
                        if columns & DEVICE_COLUMNS:
                            self.assertIsInstance(doc.get(table), int,
                                                  f"{table}: поля устройства без срока")
                finally:
                    conn.close()
        finally:
            api.DB_PATH, api.TRAFFIC_DB_PATH = saved
            shutil.rmtree(work, ignore_errors=True)
        bot = telegram_bot.open_db(":memory:")
        try:
            columns = {r[1] for r in bot.execute("PRAGMA table_info(bot_limits)")}
        finally:
            bot.close()
        self.assertIn("who", columns, "хэш человека в bot_limits — псевдоустройство")
        self.assertIsInstance(doc["bot_limits"], int)
        self.assertIsInstance(doc["blocked"], int, "в blocked.value лежат UUID и адреса")

    def test_ceiling_holds_together_with_backups(self):
        """90 дней обещаны вместе с копиями: строка, удалённая из базы,
        ещё лежит в ночной копии на VPS и в копии у владельца."""
        self.assertEqual(api.RETENTION_CEILING_DAYS, 90)
        self.assertLessEqual(api.LIVE_MAX_DAYS + api.BACKUP_MAX_DAYS, api.RETENTION_CEILING_DAYS)
        doc = retention_doc()
        self.assertLessEqual(max(d for d in doc.values() if d is not None), api.LIVE_MAX_DAYS)
        with open(os.path.join(SERVER_DIR, "backup_db.sh"), encoding="utf-8") as handle:
            vps_copies = int(re.search(r"tail -n \+(\d+)", handle.read()).group(1)) - 1
        with open(os.path.join(SERVER_DIR, "pull_backup.sh"), encoding="utf-8") as handle:
            offsite_days = int(re.search(r"^KEEP_DAYS=(\d+)$", handle.read(), re.M).group(1))
        self.assertEqual(vps_copies, 7)
        self.assertLessEqual(vps_copies, api.BACKUP_MAX_DAYS, "ночных копий на VPS больше, чем заложено")
        # +3: mtime — время забора (до суток после снимка), find -mtime +N
        # срабатывает на N+1-е сутки, запуск — раз в сутки.
        self.assertLessEqual(offsite_days + 3, api.BACKUP_MAX_DAYS,
                             "копия у владельца живёт дольше, чем заложено в потолок")

    def test_doc_parser_rejects_a_vague_ceiling(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
            handle.write("## Таблицы и файлы\n\n| `x` | a | b | c | пару месяцев | d | e |\n")
        try:
            with self.assertRaises(AssertionError):
                retention_doc(handle.name)
        finally:
            os.unlink(handle.name)


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

    # --- «Ещё перекрыто?» после проезда: голос водителя по событию дороги ---

    def vote(self, rid, device, value, ip, kind="pass"):
        return _call(self.port, "POST", "/api/vote",
                     {"id": rid, "device": device, "value": value, "kind": kind}, ip=ip)

    def road_item(self, rid):
        _, road = _call(self.port, "GET", "/api/road")
        return next((r for r in road["reports"] if r["id"] == rid), None)

    def stored(self, rid):
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT created, expires, active FROM reports WHERE id = ?",
                           (rid,)).fetchone()
        conn.close()
        return row

    def test_pass_yes_confirms_road_event_by_independent_driver_only(self):
        """«Да» после проезда — тот же лайк, что у радара: свой адрес не
        подтверждает, чужое устройство И адрес — полный срок и confirmed."""
        api._probation_cache = (time.time(), True)
        try:
            _, made = _call(self.port, "POST", "/api/report",
                            {"lat": 41.31, "lon": 69.25, "device": "owner", "type": "roadwork"},
                            ip="10.5.1.1")
            rid = made["id"]
            status, _ = self.vote(rid, "same-wifi", 1, ip="10.5.1.1")
            self.assertEqual(status, 200)
            self.assertFalse(self.road_item(rid)["confirmed"], "свой адрес подтвердил свой ремонт")
            status, _ = self.vote(rid, "stranger", 1, ip="10.5.1.2")
            self.assertEqual(status, 200)
            self.assertTrue(self.road_item(rid)["confirmed"])
            created, expires, _ = self.stored(rid)
            self.assertAlmostEqual(expires - created, api.REPORT_TTLS["roadwork"], delta=60,
                                   msg="подтверждённый ремонт — полный срок")
            conn = sqlite3.connect(api.DB_PATH)
            kind = conn.execute("SELECT kind FROM votes WHERE report_id = ? AND device = 'stranger'",
                                (rid,)).fetchone()[0]
            conn.close()
            self.assertEqual(kind, "pass", "модератор видит голос после проезда")
        finally:
            api._probation_cache = (0.0, None)

    def test_pass_noes_cut_life_and_hide_road_event(self):
        """«Нет» с нового адреса срезает срок, три разных адреса снимают
        событие из /api/road — как у радара."""
        _, made = self.report("closure", device="owner")
        rid = made["id"]
        _, start, _ = self.stored(rid)
        self.vote(rid, "n1", -1, ip="10.5.2.1")
        self.assertAlmostEqual(self.stored(rid)[1], start - api.DOWN_PENALTY, delta=5)
        self.vote(rid, "n2", -1, ip="10.5.2.2")
        self.assertIsNotNone(self.road_item(rid), "два адреса — ещё не кворум")
        status, body = self.vote(rid, "n3", -1, ip="10.5.2.3")
        self.assertEqual(status, 200)
        self.assertFalse(body["active"])
        self.assertIsNone(self.road_item(rid), "открытая дорога ушла из списка")
        status, _ = self.vote(rid, "late", 1, ip="10.5.2.4")
        self.assertEqual(status, 404, "голос за снятое событие не воскрешает его")

    def test_noes_from_one_address_do_not_hide_road_event(self):
        _, made = self.report("roadwork", device="owner")
        rid = made["id"]
        for device in ("r1", "r2", "r3"):
            _, body = self.vote(rid, device, -1, ip="10.5.3.3")
        self.assertTrue(body["active"], "ротация UUID с одного адреса — не кворум")

    def _seed_old_yes(self, rid, count, age):
        conn = sqlite3.connect(api.DB_PATH)
        for index in range(count):
            conn.execute("INSERT INTO votes(report_id, device, value, ts, ip, kind) "
                         "VALUES(?,?,1,?,?,'pass')",
                         (rid, f"old{index}", time.time() - age, f"10.6.0.{index + 1}"))
        conn.execute("UPDATE reports SET up = ? WHERE id = ?", (count, rid))
        conn.commit()
        conn.close()

    def test_old_confirmations_do_not_shield_finished_roadwork(self):
        """Пять «да» понедельника не держат закончившийся в пятницу ремонт:
        кворум дороги меряется по свежему окну."""
        _, made = self.report("roadwork", device="owner")
        rid = made["id"]
        self._seed_old_yes(rid, 5, age=api.ROAD_VOTE_FRESH + 3600)
        for index in range(3):
            _, body = self.vote(rid, f"fri{index}", -1, ip=f"10.6.1.{index + 1}")
        self.assertFalse(body["active"], "старые подтверждения заслонили открытую дорогу")
        self.assertEqual(body["up"], 5, "счётчик голосов — по-прежнему за всё время")

    def test_fresh_confirmations_still_outweigh_noes(self):
        _, made = self.report("roadwork", device="owner")
        rid = made["id"]
        self._seed_old_yes(rid, 4, age=600)
        for index in range(3):
            _, body = self.vote(rid, f"n{index}", -1, ip=f"10.6.2.{index + 1}")
        self.assertTrue(body["active"], "четыре свежих «да» против трёх «нет» — ремонт идёт")

    def test_radar_quorum_still_counts_every_vote(self):
        """Окно — только у дороги: у радара все голоса в счёте, как было."""
        _, made = self.report("radar", device="owner")
        rid = made["id"]
        self._seed_old_yes(rid, 4, age=api.ROAD_VOTE_FRESH + 3600)
        for index in range(3):
            _, body = self.vote(rid, f"n{index}", -1, ip=f"10.6.3.{index + 1}")
        self.assertTrue(body["active"], "кворум радара изменился")

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
        """Четыре числа, метка «создано ключом или token» (14.12) и первое
        обещанное время поездки (22.2, «задерживается») — и всё. Имя водителя
        для близких (22.1) — отдельным тестом в FamilyPageTest."""
        self.post(lat=41.31, lon=69.28, place="Дом", device="abc", dest="Мустакиллик 5")
        with api._eta_lock:
            stored = dict(api._eta_links)
        self.assertEqual(set(stored[self.TOKEN]), {"eta", "left_m", "status", "updated", "keyed", "first_eta"})
        self.assertFalse(stored[self.TOKEN]["keyed"])
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

    def test_footer_offers_install_on_both_languages(self):
        """28.J: внизу «Отправлено из RadarMap» и «Установить» — на ru и uz, на
        разовой странице и на странице близкого. Подвал — только ссылка:
        страница по-прежнему без скриптов, внешних ресурсов и счётчиков."""
        self.post()
        cases = (("ru", "Отправлено из RadarMap — антирадар и навигатор для Узбекистана", "Установить"),
                 ("uz-UZ", "RadarMap orqali yuborildi — Oʻzbekiston uchun antiradar va navigator",
                  "Oʻrnatish"))
        for path in (f"/api/eta/{self.TOKEN}", f"/api/eta/f/{self.TOKEN}", "/api/eta/" + "A" * 26):
            for lang, line, button in cases:
                req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}",
                                             headers={"Accept-Language": lang})
                try:
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        html, headers = resp.read().decode(), resp.headers
                except urllib.error.HTTPError as err:      # устаревшая ссылка — 404, подвал тот же
                    html, headers = err.read().decode(), err.headers
                where = f"{path} {lang}"
                self.assertIn(line, html, where)
                self.assertIn(f'href="{api.ETA_INSTALL_URL}"', html, where)
                self.assertIn(f">{button}</a>", html, where)
                self.assertNotIn("<script", html.lower(), where)
                self.assertNotIn("<img", html.lower(), where)
                self.assertNotIn("<iframe", html.lower(), where)
                # Единственный внешний адрес на странице — ссылка «Установить».
                self.assertEqual(re.findall(r'https?://[^"\s<>]+', html), [api.ETA_INSTALL_URL], where)
                self.assertNotIn("‘", html, "узбекский — с ʻ (U+02BB), не с кавычкой")
                self.assertEqual(headers.get("Referrer-Policy"), "no-referrer", where)
                self.assertIn("default-src 'none'", headers.get("Content-Security-Policy", ""), where)
                self.assertEqual(headers.get("Cache-Control"), "no-store", where)
                self.assertEqual(headers.get("X-Robots-Tag"), "noindex", where)
        self.assertTrue(api.ETA_INSTALL_URL.startswith("https://"))

    def test_driver_can_stop_sharing(self):
        self.post()
        self.post(status="ended")
        status, _, html = self.page()
        self.assertEqual(status, 200)
        self.assertIn("больше не отслеживается", html)

    def test_family_link_says_not_on_the_way(self):
        """Семейная ссылка живёт месяц: вне поездки — «сейчас не в пути», 200,
        и страница обновляется сама до следующей поездки домой."""
        status, _, body = _get_raw(self.port, "/api/eta/f/" + self.TOKEN)
        self.assertEqual(status, 200)
        self.assertIn("Сейчас не в пути", body.decode())
        self.assertIn('http-equiv="refresh" content="60"', body.decode())
        _call(self.port, "POST", "/api/eta", {"token": self.TOKEN, "eta": time.time() + 1200,
                                               "left_m": 0, "status": "driving"})
        status, _, body = _get_raw(self.port, "/api/eta/f/" + self.TOKEN)
        self.assertIn("В пути — будет в", body.decode())
        self.assertNotIn("осталось", body.decode(), "без остатка пути: близкому — только время")
        _call(self.port, "POST", "/api/eta", {"token": self.TOKEN, "eta": time.time(),
                                               "left_m": 0, "status": "arrived"})
        self.assertIn("Дома", _get_raw(self.port, "/api/eta/f/" + self.TOKEN)[2].decode())
        _call(self.port, "POST", "/api/eta", {"token": self.TOKEN, "eta": time.time(),
                                               "left_m": 0, "status": "ended"})
        self.assertIn("Сейчас не в пути", _get_raw(self.port, "/api/eta/f/" + self.TOKEN)[2].decode(),
                      "пауза водителя — не «перестал делиться навсегда»")

    def test_family_page_rejects_garbage_token(self):
        status, _, _ = _get_raw(self.port, "/api/eta/f/short")
        self.assertEqual(status, 404)


class EtaWriteKeyTest(ServerTestBase):
    """14.12: ключ записи отдельно от ссылки. У кого ссылка (мама и кому она
    её переслала) — тот видит, но не пишет: ни ложного «дома», ни чужого
    времени. Старые сборки (один token) работают как работали."""

    # Тот же вектор — в EtaShareTests.testAddressMatchesTheServer (Swift):
    # телефон и сервер обязаны получать из ключа один и тот же адрес.
    KEY = "Zq3xV7kP2mN8rT4wY6bH1c"
    ADDRESS = "823EP9H7rh1PuBrW-GnHMvJAZH189cTt_vOc6Giih3A"

    def setUp(self):
        super().setUp()
        with api._eta_lock:
            api._eta_links.clear()

    def post(self, ip=None, **fields):
        payload = {"eta": time.time() + 25 * 60, "left_m": 12400, "status": "driving"}
        payload.update(fields)
        return _call(self.port, "POST", "/api/eta", payload, ip=ip)

    def page(self, address=None, family=False):
        prefix = "/api/eta/f/" if family else "/api/eta/"
        status, headers, body = _get_raw(self.port, prefix + (address or self.ADDRESS))
        return status, headers, body.decode()

    def test_address_is_the_hash_of_the_key(self):
        self.assertEqual(api.eta_address(self.KEY), self.ADDRESS)
        self.assertEqual(len(self.ADDRESS), 43, "полный sha256 в base64url — длиннее token старых сборок")
        self.assertTrue(api._ETA_TOKEN.fullmatch(self.ADDRESS), "адрес проходит проверку страницы")
        self.assertIsNone(api._ETA_LEGACY_TOKEN.fullmatch(self.ADDRESS), "и не проходит как голый token")

    def test_key_creates_updates_and_shows_the_page(self):
        self.assertEqual(self.post(key=self.KEY)[0], 200)
        status, headers, html = self.page()
        self.assertEqual(status, 200)
        self.assertIn("Будет примерно в", html)
        self.assertEqual(headers.get("X-Eta-Version"), "3")
        self.assertEqual(self.post(key=self.KEY, status="arrived", left_m=0)[0], 200)
        self.assertIn("На месте с", self.page()[2])
        with api._eta_lock:
            self.assertTrue(api._eta_links[self.ADDRESS]["keyed"])

    def test_new_phone_sends_key_with_its_address(self):
        """Новый телефон кладёт рядом с ключом сам адрес — для сервера до 14.12.
        Здесь адрес обязан быть адресом этого ключа."""
        self.assertEqual(self.post(key=self.KEY, token=self.ADDRESS)[0], 200)
        self.assertEqual(self.page()[0], 200)
        other = "B" * 43
        self.assertEqual(self.post(key=self.KEY, token=other)[0], 400, "ключ и адрес разошлись")
        self.assertEqual(self.post(key=self.KEY, token=12345)[0], 400)
        with api._eta_lock:
            self.assertNotIn(other, api._eta_links)

    def test_reader_cannot_write_with_the_link(self):
        """Читатель знает адрес из ссылки — и только. Ни как token, ни как ключ,
        ни пока запись живёт, ни когда её нет (семейная ссылка между поездками
        домой, рестарт сервиса)."""
        status, _ = self.post(token=self.ADDRESS, status="arrived", left_m=0)
        self.assertEqual(status, 400, "запись по адресу ключа без ключа — пока записи нет")
        with api._eta_lock:
            self.assertNotIn(self.ADDRESS, api._eta_links)
        self.assertIn("Сейчас не в пути", self.page(family=True)[2])

        self.post(key=self.KEY)
        status, _ = self.post(token=self.ADDRESS, status="arrived", left_m=0)
        self.assertEqual(status, 400, "запись по адресу ключа без ключа — поверх живой")
        self.post(key=self.ADDRESS, status="arrived", left_m=0)   # адрес вместо ключа — пишет в другое место
        self.post(key=self.ADDRESS, token=self.ADDRESS, status="arrived", left_m=0)
        status, _, html = self.page(family=True)
        self.assertEqual(status, 200)
        self.assertIn("В пути — будет в", html, "читатель подменил «в пути» на «дома»")
        self.assertNotIn("Дома", html)

    def test_token_never_overwrites_an_entry_created_by_key(self):
        """Вторая стена: даже если адрес ключа когда-нибудь станет похож на
        token, запись без ключа не ложится поверх записи с ключом."""
        now = time.time()
        self.assertEqual(self.post(key=self.KEY)[0], 200)
        forged = {"eta": now, "left_m": 0, "status": "arrived", "updated": now, "keyed": False}
        self.assertFalse(api.eta_put(self.ADDRESS, forged, now))
        with api._eta_lock:
            self.assertEqual(api._eta_links[self.ADDRESS]["status"], "driving")
        own = dict(forged, keyed=True)
        self.assertTrue(api.eta_put(self.ADDRESS, own, now), "ключ свою запись обновляет")
        legacy = "L" * 22
        self.assertTrue(api.eta_put(legacy, dict(forged), now))
        self.assertTrue(api.eta_put(legacy, dict(own), now),
                        "ключ поверх token — можно: пишет владелец ключа")

    def test_old_builds_keep_their_token_links(self):
        """Старые сборки шлют один token из 22 знаков — он и адрес, и ключ."""
        legacy = "Ab3_xY-9" + "q" * 14
        for status_name, expected in (("driving", "Будет примерно в"), ("arrived", "На месте с")):
            self.assertEqual(self.post(token=legacy, status=status_name, left_m=0)[0], 200)
            self.assertIn(expected, self.page(legacy)[2])
        self.assertEqual(self.post(token=legacy, eta=time.time() + 1200)[0], 200)
        self.assertIn("В пути — будет в", self.page(legacy, family=True)[2])

    def test_rejects_bad_keys(self):
        for key in ("short", "x" * 65, "../../etc/passwd" + "x" * 20, "ключ" * 8, 123, True,
                    ["a" * 22], self.KEY + "\n", ""):
            self.assertEqual(self.post(key=key)[0], 400, repr(key))
        self.assertEqual(self.post(token="T" * 42 + "\n")[0], 400, "перевод строки в конце — не token")
        with api._eta_lock:
            self.assertEqual(api._eta_links, {})

    def test_key_never_leaves_the_server_or_stays_in_it(self):
        """Ключ записи не сохраняется и не возвращается: ни в ответе, ни на
        странице, ни в памяти — только его хэш как адрес."""
        status, body = self.post(key=self.KEY, token=self.ADDRESS)
        self.assertEqual(status, 200)
        self.assertNotIn(self.KEY, json.dumps(body))
        for family in (False, True):
            status, headers, html = self.page(family=family)
            self.assertNotIn(self.KEY, html)
            self.assertNotIn(self.KEY, json.dumps(headers))
        with api._eta_lock:
            self.assertNotIn(self.KEY, json.dumps(api._eta_links))
        status, body = self.post(key=self.KEY, token="C" * 43)
        self.assertEqual(status, 400)
        self.assertNotIn(self.KEY, json.dumps(body), "и в отказе тоже")

    def test_version_header_on_every_page(self):
        """Проверка выкладки снаружи: и страница устаревшей ссылки, и пробник
        телефона («A» × 22) отвечают версией."""
        for path in ("/api/eta/" + "A" * 22, "/api/eta/f/" + "A" * 22, "/api/eta/f/short"):
            _, headers, _ = _get_raw(self.port, path)
            self.assertEqual(headers.get("X-Eta-Version"), "3", path)



class FamilyPageTest(ServerTestBase):
    """Страница близкого (22.2) и что телефон шлёт для неё (22.1): статус и
    время — ни точки, ни маршрута; «задерживается», «почти дома», «дома в»,
    «едет домой» без выдуманного времени, возраст обновления, подсказка
    Telegram — только когда бот настроен. Края 22.4 — здесь же."""

    KEY = "Zq3xV7kP2mN8rT4wY6bH1c"
    ADDRESS = "823EP9H7rh1PuBrW-GnHMvJAZH189cTt_vOc6Giih3A"

    def setUp(self):
        super().setUp()
        with api._eta_lock:
            api._eta_links.clear()
        self.bot_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.bot_dir, True)
        self.saved_config = api.ETA_BOT_CONFIG
        self.addCleanup(self.restore_bot)

    def restore_bot(self):
        api.ETA_BOT_CONFIG = self.saved_config
        api._eta_bot.update(checked=None, username=None)

    def bot_config(self, text):
        path = os.path.join(self.bot_dir, "telegram_bot.conf")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        api.ETA_BOT_CONFIG = path
        api._eta_bot.update(checked=None, username=None)

    def post(self, **fields):
        payload = {"key": self.KEY, "eta": time.time() + 25 * 60, "left_m": 0, "status": "driving"}
        payload.update(fields)
        payload = {k: v for k, v in payload.items() if v is not None}
        return _call(self.port, "POST", "/api/eta", payload)

    def page(self, lang=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/api/eta/f/{self.ADDRESS}")
        if lang:
            req.add_header("Accept-Language", lang)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, dict(resp.headers), resp.read().decode()

    def age(self, seconds):
        with api._eta_lock:
            api._eta_links[self.ADDRESS]["updated"] -= seconds

    @staticmethod
    def clock(ts):
        return time.strftime("%H:%M", time.gmtime(ts + 5 * 3600))

    # --- 22.1: что принимает сервер ---

    def test_driving_without_eta_says_heading_home(self):
        """Маршрута нет, призрак не знает — телефон шлёт «в пути» без eta, и
        близкий видит «едет домой», а не выдуманное время."""
        status, _ = _call(self.port, "POST", "/api/eta", {"key": self.KEY, "left_m": 0, "status": "driving"})
        self.assertEqual(status, 200)
        _, _, html = self.page()
        self.assertIn("Едет домой", html)
        self.assertIn("Время прибытия пока неизвестно", html)
        self.assertNotRegex(html, r"\b\d\d:\d\d\b", "ни одной выдуманной цифры времени")
        self.assertIn("обновлено", html)
        _, _, one_off = _get_raw(self.port, "/api/eta/" + self.ADDRESS)
        self.assertIn("В пути", one_off.decode(), "разовая страница тоже не падает без времени")
        self.assertEqual(self.post(eta=None, status="arrived")[0], 200, "«дома» без времени — сейчас")
        self.assertIn("Дома в", self.page()[2])

    def test_eta_still_validated_when_present(self):
        for eta in ("soon", True, time.time() + 10 * 86400, float("nan")):
            body = {"key": self.KEY, "eta": eta, "left_m": 0, "status": "driving"}
            data = json.dumps(body).replace("NaN", "1e999").encode() if eta != eta else None
            status = (_post_raw(self.port, "/api/eta", data) if data
                      else _call(self.port, "POST", "/api/eta", body)[0])
            self.assertEqual(status, 400, repr(eta))

    def test_driver_name_is_kept_cleaned_and_escaped(self):
        self.assertEqual(self.post(name="  Зафар\n<script>x</script> " + "я" * 40)[0], 200)
        with api._eta_lock:
            name = api._eta_links[self.ADDRESS]["name"]
        self.assertLessEqual(len(name), api.ETA_NAME_MAX)
        self.assertTrue(name.startswith("Зафар <script>"), "перевод строки — пробел, края обрезаны")
        _, headers, html = self.page()
        self.assertNotIn("<script", html)
        self.assertIn("Зафар &lt;script&gt;", html)
        self.assertNotIn("script-src", headers.get("Content-Security-Policy", ""))
        self.assertEqual(self.post(name=12345)[0], 200, "не строка — без имени, но поездка идёт")
        with api._eta_lock:
            self.assertNotIn("name", api._eta_links[self.ADDRESS])
        self.assertEqual(self.post(name="\u200b\n\t")[0], 200)
        with api._eta_lock:
            self.assertNotIn("name", api._eta_links[self.ADDRESS], "пустое имя не хранится")

    def test_revoke_passes_only_with_the_write_key_and_ended(self):
        """«Убрать близкого» / «Сменить ссылку»: revoke доходит до хука Telegram
        (family_notify снимает подписки) только с ключом записи и «не в пути»."""
        now = time.time()
        base = {"key": self.KEY, "eta": now, "left_m": 0, "status": "ended", "revoke": True}
        self.assertTrue(api.clean_eta(base, now)[1].get("revoke"))
        self.assertNotIn("revoke", api.clean_eta(dict(base, status="driving"), now)[1])
        self.assertNotIn("revoke", api.clean_eta(dict(base, revoke=1), now)[1])
        legacy = {"token": "L" * 22, "eta": now, "left_m": 0, "status": "ended", "revoke": True}
        self.assertNotIn("revoke", api.clean_eta(legacy, now)[1], "без ключа — не отзыв")
        self.assertIsNone(api.clean_eta(dict(base, key=None, token=self.ADDRESS), now),
                          "читатель с адресом из ссылки не пишет вовсе")

    def test_name_shown_but_never_a_position(self):
        """Что бы ни прислали рядом (координаты, цель, скорость), на странице
        и в памяти — только статус, время и имя."""
        self.post(name="Зафар", lat=41.31177, lon=69.27911, dest="Чиланзар 9", kmh=87.4321,
                  route=[[41.29133, 69.21177]])
        _, _, html = self.page()
        self.assertIn("Зафар", html)
        with api._eta_lock:
            raw = json.dumps(api._eta_links, ensure_ascii=False)
        # Значения с точкой и редкими цифрами: в отметках времени они не
        # встретятся случайно (голое «63» встречалось).
        for leak in ("41.31177", "69.27911", "Чиланзар", "87.4321", "41.29133", "69.21177"):
            self.assertNotIn(leak, html)
            self.assertNotIn(leak, raw)
        for field in ('"lat"', '"lon"', '"dest"', '"kmh"', '"route"'):
            self.assertNotIn(field, raw)

    # --- 22.2: статусы страницы ---

    def test_on_the_way_then_delayed_after_five_minutes(self):
        first = time.time() + 25 * 60
        self.post(eta=first)
        _, _, html = self.page()
        self.assertIn(f"В пути — будет в {self.clock(first)}", html)
        self.assertIn(f'<p class="big">{self.clock(first)}</p>', html, "время — крупно")
        self.post(eta=first + 4 * 60)
        self.assertIn("В пути — будет в", self.page()[2], "4 минуты — ещё не задержка")
        later = first + 6 * 60
        self.post(eta=later)
        _, _, html = self.page()
        self.assertIn("Задерживается на 6 мин", html, "насколько позже первого обещания")
        self.assertIn(f'<p class="big">{self.clock(later)}</p>', html, "новое время — крупно, один раз")
        self.assertEqual(html.count(self.clock(later)), 1, "время не повторяется в строке статуса")
        self.post(eta=first + 60)
        self.assertIn("В пути — будет в", self.page()[2], "пробка рассосалась — уже не задерживается")

    def test_new_trip_starts_without_old_delay(self):
        first = time.time() + 25 * 60
        self.post(eta=first)
        self.post(eta=first + 20 * 60)
        self.post(status="arrived", eta=None)
        self.post(eta=time.time() + 40 * 60)
        self.assertIn("В пути — будет в", self.page()[2], "задержка прошлой поездки не переходит в новую")

    def test_first_promise_arrives_late(self):
        """Сначала времени не было («едет домой»), потом появилось — первым
        обещанием считается оно, а не «нет времени»."""
        self.post(eta=None)
        eta = time.time() + 30 * 60
        self.post(eta=eta)
        _, _, html = self.page()
        self.assertIn("В пути — будет в", html)
        with api._eta_lock:
            entry = api._eta_links[self.ADDRESS]
            self.assertEqual(entry["first_eta"], entry["eta"])

    def test_almost_home_and_home_at(self):
        self.post(eta=time.time() + 2 * 60)
        self.assertIn("Почти дома", self.page()[2])
        self.post(status="arrived", eta=time.time())
        _, _, html = self.page()
        self.assertIn(f"Дома в {self.clock(time.time())}", html)
        self.assertNotIn("обновлено", html, "дома — возраст обновления не нужен")

    def test_not_a_trip_home(self):
        """«Каждая поездка» (22.1): не домой — «в пути, прибытие около», без
        «будет дома»; без времени — просто «в пути»."""
        self.post(home=False)
        _, _, html = self.page()
        self.assertIn("В пути — прибытие около", html)
        self.assertNotIn("Едет домой", html)
        self.post(home=False, eta=None)
        _, _, html = self.page()
        self.assertIn("<h1 class=\"word\">В пути</h1>", html)
        self.post(home=False, eta=time.time() + 60)
        self.assertIn("Почти на месте", self.page()[2])
        self.post(home=True)
        self.assertIn("В пути — будет в", self.page()[2])

    def test_ended_and_unknown_say_not_on_the_way(self):
        self.assertIn("Сейчас не в пути", self.page()[2])
        self.post()
        self.post(status="ended", eta=None)
        _, _, html = self.page()
        self.assertIn("Сейчас не в пути", html)
        self.assertIn('content="60"', html, "вне поездки страница ждёт следующую сама")

    def test_uzbek_family_page(self):
        self.post(name="Zafar")
        _, _, html = self.page("uz-UZ,uz;q=0.9")
        self.assertIn('lang="uz"', html)
        self.assertIn("Yoʻlda — ", html)
        self.assertIn("soniya oldin yangilandi", html)
        self.post(status="arrived", eta=None)
        self.assertIn("Uyda — ", self.page("uz")[2])
        first = time.time() + 25 * 60
        self.post(eta=first)
        self.post(eta=first + 12 * 60)
        self.assertIn("12 daqiqaga kechikmoqda", self.page("uz")[2])

    # --- 22.4: края ---

    def test_no_network_shows_the_age_not_a_made_up_time(self):
        """Телефон без сети: страница не двигает время сама и честно говорит,
        сколько лет последнему обновлению."""
        self.post()
        self.age(20)
        self.assertRegex(self.page()[2], r"обновлено 2\d с назад")
        self.age(8 * 60)
        _, _, html = self.page()
        self.assertIn("обновлено 8 мин назад", html)
        self.assertNotIn("Давно нет обновлений", html, "8 мин — телефон ещё мог просто ехать ровно")
        self.age(5 * 60)
        _, _, html = self.page()
        self.assertIn("обновлено 13 мин назад", html)
        self.assertIn("Давно нет обновлений — возможно, телефон без сети.", html)

    def test_app_deleted_link_goes_quiet_by_itself(self):
        """Водитель удалил приложение посреди поездки: через 2 часа без
        обновлений — «сейчас не в пути», без «в пути» навсегда."""
        self.post()
        self.age(api.ETA_TTL + 1)
        status, _, html = self.page()
        self.assertEqual(status, 200)
        self.assertIn("Сейчас не в пути", html)

    def test_shop_on_the_way_keeps_the_trip_continuous(self):
        """Магазин по дороге домой (TripMerge): телефон не шлёт «не в пути» на
        стоянке, а после неё — то же «в пути» с более поздним временем.
        Страница не начинает заново: это задержка той же поездки."""
        first = time.time() + 20 * 60
        self.post(eta=first)
        self.age(18 * 60)            # 18 минут в магазине — без обновлений
        self.assertIn("В пути — будет в", self.page()[2])
        self.post(eta=first + 15 * 60)
        self.assertIn("Задерживается на 15 мин", self.page()[2])

    # --- подсказка Telegram, значок, заголовки ---

    def test_telegram_hint_only_when_the_bot_is_configured(self):
        self.post()
        _, headers, html = self.page()
        self.assertNotIn("t.me", html)
        self.assertNotIn("X-Eta-Bot", headers)
        self.bot_config("token=123:SECRET-TOKEN\nsalt=pepper-salt\nusername=@RadarMapUzBot\n")
        _, headers, html = self.page()
        self.assertIn(f'href="https://t.me/RadarMapUzBot?start=f_{self.ADDRESS}"', html)
        self.assertIn("Получать сообщения в Telegram", html)
        self.assertEqual(headers.get("X-Eta-Bot"), "RadarMapUzBot")
        for secret in ("SECRET-TOKEN", "pepper-salt"):
            self.assertNotIn(secret, html)
            self.assertNotIn(secret, json.dumps(headers))
        _, probe_headers, _ = _get_raw(self.port, "/api/eta/" + "A" * 22)
        self.assertEqual(probe_headers.get("X-Eta-Bot"), "RadarMapUzBot", "пробник телефона узнаёт имя бота")
        legacy = "Ab3_xY-9" + "q" * 14
        _call(self.port, "POST", "/api/eta", {"token": legacy, "eta": time.time() + 600, "left_m": 0,
                                               "status": "driving"})
        _, _, legacy_page = _get_raw(self.port, "/api/eta/f/" + legacy)
        self.assertNotIn("t.me", legacy_page.decode(),
                         "ссылка без ключа не подписывается: читатель прислал бы ложное «дома»")
        for bad in ("username=bad name\n", "username=\n", "username=<b>x</b>\n", "token=1\n"):
            self.bot_config(bad)
            _, headers, html = self.page()
            self.assertNotIn("t.me", html, bad)
            self.assertNotIn("X-Eta-Bot", headers, bad)

    def test_home_screen_icon_and_note(self):
        self.post()
        _, headers, html = self.page()
        self.assertIn('rel="apple-touch-icon" href="../icon.png"', html)
        self.assertIn("На экран „Домой“", html)
        self.assertIn("img-src 'self'", headers.get("Content-Security-Policy", ""))
        self.assertNotIn("<script", html)
        status, icon_headers, body = _get_raw(self.port, "/api/eta/icon.png")
        self.assertEqual(status, 200)
        self.assertEqual(icon_headers.get("Content-Type"), "image/png")
        self.assertTrue(body.startswith(b"\x89PNG\r\n\x1a\n"))

    def test_family_state_is_a_pure_decision(self):
        now = 1_800_000_000
        item = {"eta": now + 1500, "first_eta": now + 1500, "status": "driving", "updated": now}
        self.assertEqual(api.family_state(None, now), "idle")
        self.assertEqual(api.family_state(dict(item, status="ended"), now), "idle")
        self.assertEqual(api.family_state(dict(item, status="arrived"), now), "arrived")
        self.assertEqual(api.family_state(dict(item, eta=None), now), "unknown")
        self.assertEqual(api.family_state(item, now), "driving")
        self.assertEqual(api.family_state(dict(item, eta=now + 1500 + 299), now), "driving")
        self.assertEqual(api.family_state(dict(item, eta=now + 1500 + 300), now), "delayed")
        self.assertEqual(api.family_state(dict(item, eta=now + 180), now), "almost")
        self.assertEqual(api.family_state(dict(item, eta=now + 180, first_eta=now), now), "almost",
                         "почти дома важнее задержки")


def _post_raw(port, path, body):
    """POST готовыми байтами: json.dumps не построит тело, которое ломает
    разбор на сервере (вложенность в тысячи скобок)."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


class ServerAuditTest(ServerTestBase):
    """Аудит сервера 14.3 (20.10): каждая проверка — дыра, найденная ревью, и
    до правки падала. Важнее формы — чего сервер НЕ должен позволить."""

    def setUp(self):
        super().setUp()
        with api._eta_lock:
            api._eta_links.clear()

    def report(self, rtype, device, ip, lat=41.31, lon=69.25, **extra):
        body = {"lat": lat, "lon": lon, "device": device, "type": rtype}
        body.update(extra)
        return _call(self.port, "POST", "/api/report", body, ip=ip)

    def lists(self):
        _, mobile = _call(self.port, "GET", "/api/mobile")
        _, road = _call(self.port, "GET", "/api/road")
        return [r["id"] for r in mobile["reports"]], [r["id"] for r in road["reports"]]

    def seed(self, rtype, count, ip):
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        for index in range(count):
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, ip, active) "
                         "VALUES(?,?,?,?,?,?,?,1)",
                         (40.0 + index * 0.01, 71.5, now - 600, now + 86400, f"seed-{ip}-{index}",
                          rtype, ip))
        conn.commit()
        conn.close()

    def lifetime(self, rid):
        conn = sqlite3.connect(api.DB_PATH)
        created, expires = conn.execute("SELECT created, expires FROM reports WHERE id = ?",
                                        (rid,)).fetchone()
        conn.close()
        return expires - created

    # --- уточнение типа через границу камера/дорога ---

    def test_crossing_amend_respects_the_road_cap_of_the_address(self):
        """«Радар» → amend «перекрыто» не обходит кап дороги на адрес: иначе
        один адрес держал бы сколько угодно перекрытий вместо шести."""
        self.seed("roadwork", api.MAX_ACTIVE_ROAD_PER_IP, ip="10.14.1.1")
        status, radar = self.report("radar", "fresh", ip="10.14.1.1")
        self.assertEqual(status, 200)
        status, _ = self.report("closure", "fresh", ip="10.14.1.1", amend_id=radar["id"])
        self.assertEqual(status, 429, "amend через границу обошёл кап дороги на адрес")
        mobile, road = self.lists()
        self.assertIn(radar["id"], mobile, "отказ не трогает сам радар")
        self.assertNotIn(radar["id"], road)

    def test_crossing_amend_respects_the_global_road_cap(self):
        old = api.MAX_ACTIVE_ROAD
        api.MAX_ACTIVE_ROAD = 2
        try:
            self.seed("roadwork", 1, ip="10.14.2.1")
            self.seed("closure", 1, ip="10.14.2.2")
            status, radar = self.report("radar", "fresh", ip="10.14.2.9")
            self.assertEqual(status, 200)
            status, _ = self.report("closure", "fresh", ip="10.14.2.9", amend_id=radar["id"])
            self.assertEqual(status, 429, "amend через границу обошёл общий кап дороги")
            self.assertIn(radar["id"], self.lists()[0])
        finally:
            api.MAX_ACTIVE_ROAD = old

    def test_crossing_amend_respects_the_camera_cap_of_the_address(self):
        """Обратная сторона: «перекрыто» → «радар» не обходит кап камер на адрес."""
        self.seed("radar", api.MAX_ACTIVE_PER_IP, ip="10.14.3.1")
        status, closure = self.report("closure", "fresh", ip="10.14.3.1")
        self.assertEqual(status, 200)
        status, _ = self.report("radar", "fresh", ip="10.14.3.1", amend_id=closure["id"])
        self.assertEqual(status, 429)
        self.assertIn(closure["id"], self.lists()[1])

    def test_author_cannot_move_a_confirmed_radar_off_the_camera_list(self):
        """Отзыв подтверждённой другими отметки запрещён — и amend в «перекрыто»
        (то же исчезновение радара из /api/mobile) запрещён так же."""
        _, radar = self.report("radar", "author", ip="10.14.4.1")
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": radar["id"], "device": "witness", "value": 1}, ip="10.14.4.2")
        self.assertEqual(status, 200)
        status, _ = self.report("closure", "author", ip="10.14.4.1", amend_id=radar["id"])
        self.assertEqual(status, 409)
        mobile, road = self.lists()
        self.assertIn(radar["id"], mobile, "подтверждённый другими радар пропал у всех")
        self.assertEqual(road, [])

    def test_same_category_amend_never_keeps_a_longer_lifetime(self):
        """Ремонт (сутки на испытании) → «перекрыто» своей же точкой: срок —
        перекрытия (3 ч), а не ремонта; обратно — не продлевает."""
        api._probation_cache = (time.time(), True)
        try:
            _, made = self.report("roadwork", "me", ip="10.14.5.1")
            status, body = self.report("closure", "me", ip="10.14.5.1")
            self.assertTrue(body.get("amended"))
            self.assertAlmostEqual(self.lifetime(made["id"]), api.PROBATION_TTLS["closure"], delta=5,
                                   msg="неподтверждённое перекрытие живёт сроком ремонта")
            self.report("roadwork", "me", ip="10.14.5.1")
            self.assertAlmostEqual(self.lifetime(made["id"]), api.PROBATION_TTLS["closure"], delta=5,
                                   msg="уточнение типа продлило свою точку")
        finally:
            api._probation_cache = (0.0, None)

    # --- IPv6: адрес — это сеть /64, а не 2^64 адресов ---

    def test_one_ipv6_subnet_cannot_hide_a_report(self):
        """Кворум скрытия — три РАЗНЫХ адреса. Три адреса одной /64 — один
        абонент: иначе один телефон снимал бы с карты любой радар."""
        _, radar = self.report("radar", "owner", ip="10.14.6.1")
        for index, host in enumerate(("a", "b", "c")):
            _, body = _call(self.port, "POST", "/api/vote",
                            {"id": radar["id"], "device": f"v{index}", "value": -1},
                            ip=f"2001:db8:14:6::{host}")
        self.assertTrue(body["active"], "три адреса одной /64 сняли радар")

    def test_one_ipv6_subnet_cannot_confirm_its_own_report(self):
        api._probation_cache = (time.time(), True)
        try:
            _, radar = self.report("radar", "owner", ip="2001:db8:14:7::1")
            _call(self.port, "POST", "/api/vote", {"id": radar["id"], "device": "other", "value": 1},
                  ip="2001:db8:14:7::2")
            _, mobile = _call(self.port, "GET", "/api/mobile")
            self.assertFalse(mobile["reports"][0]["confirmed"], "своя /64 подтвердила свою отметку")
            _call(self.port, "POST", "/api/vote", {"id": radar["id"], "device": "stranger", "value": 1},
                  ip="2001:db8:99:1::1")
            _, mobile = _call(self.port, "GET", "/api/mobile")
            self.assertTrue(mobile["reports"][0]["confirmed"], "чужая сеть — независимое подтверждение")
        finally:
            api._probation_cache = (0.0, None)

    def test_client_key_keeps_ipv4_and_bot_pseudo_addresses(self):
        self.assertEqual(api.client_key("10.0.0.1"), "10.0.0.1")
        self.assertEqual(api.client_key("::ffff:10.0.0.1"), "10.0.0.1")
        self.assertEqual(api.client_key("2001:db8:1:2:3:4:5:6"), "2001:db8:1:2::/64")
        self.assertEqual(api.client_key("tg-0123456789abcdef"), "tg-0123456789abcdef")

    # --- «Поделиться прибытием»: полная таблица не запирает новых ---

    def test_full_link_table_still_takes_a_new_driver(self):
        """Пять тысяч ссылок с трёх адресов запирали «Поделиться прибытием»
        всей стране на два часа (503). Теперь уходит самая давно не
        обновлявшаяся ссылка: живые обновляются раз в минуту и возвращаются."""
        old = api.ETA_MAX_LINKS
        api.ETA_MAX_LINKS = 3
        try:
            now = time.time()
            for index in range(3):
                api.eta_put(f"flood{index}" + "x" * 20,
                            {"eta": now + 600, "left_m": 1, "status": "driving",
                             "updated": now - 60 * (index + 1)}, now)
            token = "R" * 22
            status, _ = _call(self.port, "POST", "/api/eta",
                              {"token": token, "eta": now + 1500, "left_m": 5000, "status": "driving"})
            self.assertEqual(status, 200, "полная таблица отказала новому водителю")
            self.assertEqual(_get_raw(self.port, "/api/eta/" + token)[0], 200)
            with api._eta_lock:
                self.assertLessEqual(len(api._eta_links), 3)
                self.assertNotIn("flood2" + "x" * 20, api._eta_links, "ушла не самая старая")
                self.assertIn("flood0" + "x" * 20, api._eta_links)
        finally:
            api.ETA_MAX_LINKS = old

    # --- числа и вложенность, на которых падал разбор ---

    def test_huge_numbers_answer_400_not_a_dropped_connection(self):
        """Infinity и целое в 400 знаков проходят json.loads, но int()/float()
        бросают OverflowError — обработчик падал без ответа, трейс в журнал."""
        for path, payload in (
                ("/api/vote", {"id": float("inf"), "device": "d", "value": 1}),
                ("/api/report/cancel", {"id": float("inf"), "device": "d"}),
                ("/api/camera_report", {"camera_id": float("inf"), "reason": "gone", "device": "d"}),
                ("/api/report", {"lat": 10 ** 400, "lon": 69.25, "device": "d"}),
                ("/api/cng", {"lat": 10 ** 400, "lon": 69.25, "device": "d", "kind": "gas"}),
                ("/api/eta", {"token": "Z" * 22, "eta": 10 ** 400, "left_m": 0, "status": "driving"})):
            status, _ = _call(self.port, "POST", path, payload)
            self.assertEqual(status, 400, path)

    def test_garbage_numbers_keep_their_documented_defaults(self):
        """Где мусор в поле по контракту — «по умолчанию», он им и остаётся."""
        status, body = self.report("radar", "d1", ip="10.14.8.1", amend_id=float("inf"),
                                   age=10 ** 400)
        self.assertEqual(status, 200, "кривой amend_id или age не роняет отметку")
        self.assertFalse(body["merged"])
        status, _ = _call(self.port, "POST", "/api/stat",
                          {"device": "d", "day": "2026-10-20", "trips": float("inf")})
        self.assertEqual(status, 200, "испорченный счётчик — ноль, а не обрыв")
        good = TrafficTest.piece()
        bad = {"p": [[10 ** 400, 69.27, 0, 40], [41.311, 69.27, 8, 40], [41.312, 69.27, 16, 40]]}
        status, body = _call(self.port, "POST", "/api/traffic", {"v": 1, "pieces": [bad, good]})
        self.assertEqual((status, body.get("accepted")), (200, 1), "плохой кусок роняет пачку")

    def test_deeply_nested_body_is_400(self):
        """На сервере Python 3.10: вложенность в 2000 скобок — RecursionError
        в json.loads, мимо except ValueError (на 3.14 разбор не падает)."""
        depth = 2000
        status = _post_raw(self.port, "/api/report", b"[" * depth + b"]" * depth)
        self.assertEqual(status, 400)
        status = _post_raw(self.port, "/api/metrics", b"[" * depth + b"]" * depth)
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
