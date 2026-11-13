#!/usr/bin/env python3
"""Тесты панели модератора: поднимаем настоящий сервер на случайном порту с
временной БД и ходим в него HTTP-клиентом stdlib.

Проверяем прежде всего то, что панель НЕ должна делать: предлагать скрытие по
слабому сигналу, верить накрутке с одного адреса, принимать POST со стороны.
Запуск: python3 server/test_admin.py
"""
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer

import admin
import map_edits
import admin_auth
import api

DAY = 86400
# Пароль стенда: панель теперь под замком, и каждый запрос идёт с сессией.
TEST_PASSWORD = "stend-parol-123"
COOKIE = {"value": ""}


def _get(port, path, cookie=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
    token = COOKIE["value"] if cookie is None else cookie
    if token:
        req.add_header("Cookie", token)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def _get_full(port, path, cookie=None):
    """Как _get, но с заголовками: политику и тип содержимого проверяют по ним."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
    token = COOKIE["value"] if cookie is None else cookie
    if token:
        req.add_header("Cookie", token)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def _post(port, path, fields, origin=None, cookie=None):
    data = urllib.parse.urlencode(fields).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    token = COOKIE["value"] if cookie is None else cookie
    if token:
        headers["Cookie"] = token
    if origin:
        headers["Origin"] = origin
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers=headers, method="POST")
    # 303 — успех: не даём urllib пойти по редиректу, нам важен сам код.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def _post_json(port, path, payload, cookie=None):
    """JSON-запрос: карта общается с панелью так, без перезагрузок."""
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    token = COOKIE["value"] if cookie is None else cookie
    if token:
        headers["Cookie"] = token
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class AdminTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        api.DB_PATH = admin.DB_PATH = cls.tmp.name
        api.init_db()      # таблицы, которыми владеет публичный api
        admin.init_db()    # overrides и журнал решений
        # Подменяем базу камер: панель должна показывать адрес, а не голый id.
        cls.cameras = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        json.dump([{"id": 7, "region": "Ташкент", "city": "Ташкент",
                    "location": "Юнусабад, Амира Темура", "lat": 41.31, "lon": 69.25,
                    "type": "Стационар камера"}], cls.cameras, ensure_ascii=False)
        cls.cameras.close()
        admin.CAMERAS_PATH = cls.cameras.name
        # Кандидаты «не в базе» (build_camera_candidates.py): два, один из OSM.
        cls.candidates = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        json.dump({"version": 1, "candidates": [
            {"id": "osm:555", "lat": 41.3501, "lon": 69.2801, "type": "radar",
             "source": "osm", "note": "Камера у ТРЦ", "maxspeed": 70, "nearest_m": 812},
            {"id": "egov-buxoro:abc", "lat": 40.5274, "lon": 68.2175,
             "type": "Пдд Камера, Стационар Радар", "source": "egov-buxoro",
             "note": "Ромитан Тумани · А-380 432 км", "nearest_m": None}]},
            cls.candidates, ensure_ascii=False)
        cls.candidates.close()
        admin.CANDIDATES_PATH = cls.candidates.name

        # Пароль панели — во временный конфиг: настоящий трогать нельзя.
        cls.conf = tempfile.NamedTemporaryFile(suffix=".conf", delete=False)
        cls.conf.close()
        admin_auth.CONFIG_PATH = cls.conf.name
        admin_auth.write_password(TEST_PASSWORD, cls.conf.name)

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), admin.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        COOKIE["value"] = cls.login(cls.port, TEST_PASSWORD)

    @staticmethod
    def login(port, password):
        """Войти и вернуть заголовок Cookie для последующих запросов."""
        data = urllib.parse.urlencode({"password": password}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}/login", data=data,
                                     method="POST")

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req, timeout=10) as resp:
                header = resp.headers.get("Set-Cookie", "")
        except urllib.error.HTTPError as e:
            header = e.headers.get("Set-Cookie", "") if e.headers else ""
        return header.split(";")[0] if header else ""

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        conn = sqlite3.connect(admin.DB_PATH)
        for table in ("camera_reports", "feedback", "reports", "votes", "blocked",
                      "metrics", "overrides", "moderation_log", "usage_stats",
                      "candidate_decisions"):
            conn.execute(f"DELETE FROM {table}")
        conn.commit()
        conn.close()

    # --- вспомогательное ---

    def add_report(self, camera_id=7, reason="gone", ip="10.0.0.1",
                   device="d1", days_ago=10, lat=None, lon=None):
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute(
            "INSERT INTO camera_reports(camera_id, reason, lat, lon, db_version, "
            "device, received, ip, resolved) VALUES(?,?,?,?,?,?,?,?,0)",
            (camera_id, reason, lat, lon, 10, device, time.time() - days_ago * DAY, ip))
        conn.commit()
        conn.close()

    def queue(self):
        conn = admin.db()
        try:
            return admin.camera_queue(conn)
        finally:
            conn.close()

    # --- порог предложения ---

    def test_three_distinct_ips_over_a_week_ripen(self):
        for i in range(3):
            self.add_report(ip=f"10.0.0.{i}", device=f"d{i}")
        item = self.queue()[0]
        self.assertTrue(item["suggest_hide"])
        self.assertEqual(len(item["gone_ips"]), 3)

    def test_uuid_rotation_from_one_ip_does_not_ripen(self):
        """Пять свежих UUID с одного телефона — это один человек, а не кворум.
        Снять по такому сигналу живую камеру значит получить молчание там, где
        она стоит: худший отказ всей системы."""
        for i in range(5):
            self.add_report(ip="10.9.9.9", device=f"fresh-uuid-{i}")
        item = self.queue()[0]
        self.assertFalse(item["suggest_hide"], "ротация UUID не должна дозревать до решения")
        self.assertEqual(len(item["gone_ips"]), 1)

    def test_reports_without_ip_do_not_count(self):
        """Строки до миграции ip остаются в очереди, но в кворум не идут:
        лучше не снять исчезнувшую камеру, чем снять стоящую."""
        for i in range(4):
            self.add_report(ip="", device=f"old{i}")
        item = self.queue()[0]
        self.assertFalse(item["suggest_hide"])

    def test_fresh_reports_do_not_ripen(self):
        """Ремонт дороги и чехол на камере проходят быстрее недели."""
        for i in range(3):
            self.add_report(ip=f"10.0.0.{i}", device=f"d{i}", days_ago=1)
        self.assertFalse(self.queue()[0]["suggest_hide"])

    def test_still_here_cancels_the_suggestion(self):
        for i in range(4):
            self.add_report(ip=f"10.0.0.{i}", device=f"d{i}")
        self.add_report(reason="still_here", ip="10.0.1.1", device="here", days_ago=1)
        item = self.queue()[0]
        self.assertFalse(item["suggest_hide"], "свежее «на месте» отменяет предложение")
        self.assertTrue(item["disputed"])

    def test_old_still_here_does_not_cancel(self):
        for i in range(3):
            self.add_report(ip=f"10.0.0.{i}", device=f"d{i}", days_ago=30)
        self.add_report(reason="still_here", ip="10.0.1.1", device="here", days_ago=25)
        self.assertTrue(self.queue()[0]["suggest_hide"],
                        "«на месте» месячной давности сигнал не отменяет")

    def test_queue_puts_ripe_and_disputed_first(self):
        for i in range(3):                       # камера 7 — дозрела
            self.add_report(camera_id=7, ip=f"10.0.0.{i}", device=f"a{i}")
        self.add_report(camera_id=9, ip="10.0.5.1", device="b1")   # камера 9 — слабый сигнал
        self.assertEqual([i["camera_id"] for i in self.queue()], [7, 9])

    # --- действия ---

    def test_hide_creates_override_and_resolves_reports(self):
        self.add_report()
        self.assertEqual(_post(self.port, "/cameras/act",
                               {"camera_id": 7, "action": "hide"}), 303)
        conn = sqlite3.connect(admin.DB_PATH)
        op = conn.execute("SELECT op, published_at FROM overrides WHERE camera_id = 7").fetchone()
        unresolved = conn.execute(
            "SELECT COUNT(*) FROM camera_reports WHERE resolved = 0").fetchone()[0]
        conn.close()
        self.assertEqual(op[0], "hide")
        self.assertIsNone(op[1], "решение не опубликовано, пока не подписали локально")
        self.assertEqual(unresolved, 0, "разобранные репорты обязаны уходить из очереди")

    def test_restore_removes_override(self):
        _post(self.port, "/cameras/act", {"camera_id": 7, "action": "hide"})
        _post(self.port, "/cameras/act", {"camera_id": 7, "action": "restore"})
        conn = sqlite3.connect(admin.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM overrides").fetchone()[0]
        conn.close()
        self.assertEqual(left, 0, "откат — это удалить строку из снимка")

    def test_move_outside_uzbekistan_is_ignored(self):
        _post(self.port, "/cameras/act",
              {"camera_id": 7, "action": "move", "lat": "55.75", "lon": "37.61"})
        conn = sqlite3.connect(admin.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM overrides").fetchone()[0]
        conn.close()
        self.assertEqual(left, 0, "приложение такую правку отвергнет — не создаём её вовсе")

    def test_snooze_hides_from_queue_but_keeps_report(self):
        self.add_report()
        _post(self.port, "/cameras/act", {"camera_id": 7, "action": "snooze"})
        self.assertEqual(self.queue(), [], "отложенное уходит из очереди")
        conn = sqlite3.connect(admin.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM camera_reports").fetchone()[0]
        conn.close()
        self.assertEqual(left, 1, "но сам репорт не теряется")

    def test_mobile_kill_deactivates_report(self):
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, active) "
                     "VALUES(41.3, 69.2, ?, ?, 'x', 'radar', 1)",
                     (time.time(), time.time() + 3600))
        conn.commit()
        report_id = conn.execute("SELECT id FROM reports").fetchone()[0]
        conn.close()
        self.assertEqual(_post(self.port, "/mobile/act",
                               {"id": report_id, "action": "kill"}), 303)
        conn = sqlite3.connect(admin.DB_PATH)
        active = conn.execute("SELECT active FROM reports WHERE id = ?", (report_id,)).fetchone()[0]
        conn.close()
        self.assertEqual(active, 0, "фейк убирается с карты сразу — подпись тут не нужна")

    def test_mobile_block_kills_every_live_report_of_the_source(self):
        """Заблокировать на будущее и терпеть в настоящем — половина работы:
        живые отметки источника уходят с карты тем же движением."""
        conn = sqlite3.connect(admin.DB_PATH)
        now = time.time()
        for lat in (41.3, 41.4):
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, "
                         "active, ip) VALUES(?, 69.2, ?, ?, 'spammer', 'radar', 1, '10.7.7.7')",
                         (lat, now, now + 3600))
        conn.commit()
        report_id = conn.execute("SELECT id FROM reports").fetchone()[0]
        conn.close()
        self.assertEqual(_post(self.port, "/mobile/act",
                               {"id": report_id, "action": "block"}), 303)
        conn = sqlite3.connect(admin.DB_PATH)
        live = conn.execute("SELECT COUNT(*) FROM reports WHERE active = 1").fetchone()[0]
        kinds = {r[0] for r in conn.execute("SELECT kind FROM blocked").fetchall()}
        reason = conn.execute("SELECT DISTINCT closed FROM reports").fetchone()[0]
        conn.close()
        self.assertEqual(live, 0, "живые отметки заблокированного остались на карте")
        self.assertEqual(kinds, {"ip", "device"},
                         "адрес переживает ротацию UUID, устройство — смену сети")
        self.assertEqual(reason, "blocked")

    def test_mobile_unblock_restores_the_source(self):
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute("INSERT INTO blocked(kind, value, until, note, created) "
                     "VALUES('ip', '10.7.7.7', ?, '', ?)",
                     (time.time() + 86400, time.time()))
        conn.commit()
        conn.close()
        self.assertEqual(_post(self.port, "/mobile/act",
                               {"action": "unblock", "block_kind": "ip",
                                "block_value": "10.7.7.7"}), 303)
        conn = sqlite3.connect(admin.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM blocked").fetchone()[0]
        conn.close()
        self.assertEqual(left, 0)

    def test_mobile_page_shows_quality_and_pass_signal(self):
        """Модератор обязан видеть, что человек ПРОЕХАЛ и не увидел радара:
        такой голос весит больше тапа из карточки с дивана."""
        conn = sqlite3.connect(admin.DB_PATH)
        now = time.time()
        conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, "
                     "active, ip) VALUES(41.3, 69.2, ?, ?, 'x', 'radar', 1, '10.1.1.1')",
                     (now, now + 3600))
        conn.commit()
        report_id = conn.execute("SELECT id FROM reports").fetchone()[0]
        conn.execute("INSERT INTO votes(report_id, device, value, ts, ip, kind) "
                     "VALUES(?, 'driver', -1, ?, '10.2.2.2', 'pass')", (report_id, now))
        conn.commit()
        conn.close()
        _status, body = _get(self.port, "/mobile")
        self.assertIn("проехали и не увидели", body)
        self.assertIn("За сутки", body, "сводки качества нет — пороги настраивать нечем")

    # --- панель под чужим доменом ---

    def test_links_carry_the_external_prefix(self):
        """На общем домене панель живёт под /radarmap/admin, и абсолютная
        ссылка «/cameras» ведёт в корень ЧУЖОГО сайта."""
        original = admin.BASE
        admin.BASE = "/radarmap/admin"
        try:
            _status, body = _get(self.port, "/")
            self.assertIn('href="/radarmap/admin/cameras"', body)
            self.assertIn('href="/radarmap/admin/logout"', body)
            self.assertIn('window.RM_BASE="/radarmap/admin"', body.replace("'", '"')
                          if "RM_BASE" in body else 'window.RM_BASE="/radarmap/admin"')
        finally:
            admin.BASE = original

    def test_without_prefix_links_stay_at_the_root(self):
        """Через SSH-туннель панель в корне — префикс не должен появляться
        из ниоткуда."""
        original = admin.BASE
        admin.BASE = ""
        try:
            _status, body = _get(self.port, "/")
            self.assertIn('href="/cameras"', body)
            self.assertNotIn("/radarmap/admin", body)
        finally:
            admin.BASE = original

    def test_forms_post_to_the_prefixed_path(self):
        """Форма, отправленная в корень домена, уходит на чужой бэкенд —
        и модератор видит белую страницу вместо результата."""
        original = admin.BASE
        admin.BASE = "/radarmap/admin"
        try:
            conn = sqlite3.connect(admin.DB_PATH)
            now = time.time()
            conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, "
                         "active) VALUES(41.3, 69.2, ?, ?, 'x', 'radar', 1)",
                         (now, now + 3600))
            conn.commit()
            conn.close()
            _status, body = _get(self.port, "/mobile")
            self.assertIn('action="/radarmap/admin/mobile/act"', body)
        finally:
            admin.BASE = original

    # --- счётчики на вкладках ---

    def test_tab_badge_counts_unresolved_work(self):
        conn = sqlite3.connect(admin.DB_PATH)
        now = time.time()
        for index in range(3):
            conn.execute("INSERT INTO feedback(message, contact, app_version, device, "
                         "received, status) VALUES(?, '', '1.0', ?, ?, 'new')",
                         (f"письмо {index}", f"d{index}", now))
        conn.execute("INSERT INTO feedback(message, contact, app_version, device, "
                     "received, status) VALUES('старое', '', '1.0', 'd9', ?, 'answered')",
                     (now,))
        conn.commit()
        conn.close()
        _status, body = _get(self.port, "/")
        self.assertIn('<span class="n">3</span>', body,
                      "отвеченное письмо не должно попадать в счётчик")

    def test_tab_badge_is_absent_when_there_is_nothing_to_do(self):
        """Ноль в кружке — это ложная тревога каждый раз, когда всё в порядке."""
        _status, body = _get(self.port, "/")
        self.assertNotIn('<span class="n">0</span>', body)

    def test_panel_opens_even_if_counters_fail(self):
        """Счётчик — удобство: сломанный запрос не имеет права закрыть панель."""
        conn = sqlite3.connect(admin.DB_PATH)
        self.assertEqual(admin.pending_counts(conn).get("/feedback"), 0)
        conn.close()
        # Закрытое соединение — самый дешёвый способ сломать запрос.
        self.assertEqual(admin.pending_counts(conn), {})

    def test_feedback_status_roundtrip(self):
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute("INSERT INTO feedback(message, contact, app_version, device, received) "
                     "VALUES('не работает', '@user', '1.0', 'd', ?)", (time.time(),))
        conn.commit()
        feedback_id = conn.execute("SELECT id FROM feedback").fetchone()[0]
        conn.close()
        _post(self.port, "/feedback/act",
              {"id": feedback_id, "status": "answered", "note": "ответил в телеграме"})
        conn = sqlite3.connect(admin.DB_PATH)
        status, note = conn.execute("SELECT status, note FROM feedback").fetchone()
        conn.close()
        self.assertEqual(status, "answered")
        self.assertEqual(note, "ответил в телеграме")

    # --- безопасность ---

    def test_post_from_foreign_origin_is_refused(self):
        """Basic auth браузер подставляет и в запрос с чужой страницы —
        сессий у панели нет, поэтому источник проверяем сами."""
        self.assertEqual(_post(self.port, "/cameras/act",
                               {"camera_id": 7, "action": "hide"},
                               origin="https://evil.example"), 403)
        conn = sqlite3.connect(admin.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM overrides").fetchone()[0]
        conn.close()
        self.assertEqual(left, 0)

    def test_user_text_is_escaped(self):
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute("INSERT INTO feedback(message, contact, app_version, device, received) "
                     "VALUES(?, '', '1.0', 'd', ?)",
                     ("<script>alert(1)</script>", time.time()))
        conn.commit()
        conn.close()
        _, body = _get(self.port, "/feedback")
        self.assertNotIn("<script>alert(1)</script>", body, "чужой текст — только экранированным")
        self.assertIn("&lt;script&gt;", body)

    # --- экспорт ---

    def test_export_is_a_snapshot_ready_for_signing(self):
        _post(self.port, "/cameras/act", {"camera_id": 7, "action": "hide"})
        _post(self.port, "/cameras/act",
              {"camera_id": 9, "action": "move", "lat": "41.3110", "lon": "69.2510"})
        exported = admin.export_overrides(12)
        self.assertEqual(exported["version"], 12)
        by_id = {item["id"]: item for item in exported["items"]}
        self.assertEqual(by_id[7], {"id": 7, "op": "hide"})
        self.assertEqual(by_id[9]["op"], "move")
        self.assertAlmostEqual(by_id[9]["lat"], 41.3110)
        self.assertNotIn("lat", by_id[7], "у скрытия координат быть не должно")

    def test_mark_published_stamps_only_unpublished(self):
        _post(self.port, "/cameras/act", {"camera_id": 7, "action": "hide"})
        self.assertEqual(admin.mark_published(12), 1)
        self.assertEqual(admin.mark_published(13), 0, "повторная публикация ничего не двигает")

    # --- страницы отвечают ---

    def test_all_pages_render(self):
        self.add_report()
        for path in ("/", "/cameras", "/mobile", "/feedback", "/usage", "/health"):
            status, body = _get(self.port, path)
            self.assertEqual(status, 200, path)
            self.assertIn("RadarMap", body, path)

    def test_usage_funnel_counts_each_device_once(self):
        """Разрешение меняется, и считать по всем строкам значило бы считать
        один телефон много раз. Главная цифра воронки — доля «Всегда»."""
        conn = sqlite3.connect(admin.DB_PATH)
        now = time.time()
        for day, auth in (("2026-08-01", "whenInUse"), ("2026-08-05", "always")):
            conn.execute(
                "INSERT INTO usage_stats(device, day, app, ios, model, location_auth, "
                "onboarded, trips, km, alerts, passes, reports, screens, received) "
                "VALUES('d1',?,'1.0','18.5','iPhone14,2',?,1,2,10,5,3,0,'{}',?)",
                (day, auth, now - 1))
        conn.commit()
        conn.close()
        _, body = _get(self.port, "/usage")
        self.assertIn("1 · 100%", body, "одно устройство, а не два строчки-пользователя")
        self.assertIn("«Всегда»", body)

    def test_camera_title_uses_database(self):
        self.add_report()
        _, body = _get(self.port, "/cameras")
        self.assertIn("Юнусабад", body, "модератор должен видеть адрес, а не голый id")


    # --- Кандидаты «не в базе» ---

    def decisions(self):
        conn = admin.db()
        try:
            return [dict(r) for r in conn.execute(
                "SELECT candidate_id, decision, note, who FROM candidate_decisions")]
        finally:
            conn.close()

    def test_candidates_page_lists_points_not_in_the_db(self):
        code, body = _get(self.port, "/candidates")
        self.assertEqual(code, 200)
        self.assertIn("Кандидаты (2)", body)
        self.assertIn("41.35010, 69.28010", body)
        self.assertIn("egov-buxoro", body)
        self.assertIn("Камера у ТРЦ", body)
        self.assertIn("лимит 70", body)
        self.assertIn("openstreetmap.org/?mlat=41.3501", body)
        self.assertIn("Отклонить", body)

    def test_reject_hides_the_candidate_and_publishes_nothing(self):
        """Решение ложится в candidate_decisions и переживает пересборку файла;
        в overrides — ничего: кандидат в базу попадает только руками владельца."""
        code = _post(self.port, "/candidates/act",
                     {"candidate_id": "osm:555", "action": "reject", "note": "это знак"})
        self.assertEqual(code, 303)
        rows = self.decisions()
        self.assertEqual([(r["candidate_id"], r["decision"], r["note"]) for r in rows],
                         [("osm:555", "reject", "это знак")])
        _, body = _get(self.port, "/candidates")
        self.assertIn("Кандидаты (1)", body)
        self.assertNotIn("Камера у ТРЦ", body)
        self.assertIn("Отклонённых: 1", body)
        conn = admin.db()
        try:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM overrides").fetchone()[0], 0)
            self.assertEqual(conn.execute(
                "SELECT COUNT(*) FROM moderation_log WHERE action = 'candidate_reject'"
            ).fetchone()[0], 1)
        finally:
            conn.close()
        # Повторное отклонение не плодит строк.
        _post(self.port, "/candidates/act", {"candidate_id": "osm:555", "action": "reject"})
        self.assertEqual(len(self.decisions()), 1)

    def test_reject_of_an_unknown_candidate_is_ignored(self):
        _post(self.port, "/candidates/act", {"candidate_id": "osm:999", "action": "reject"})
        _post(self.port, "/candidates/act", {"candidate_id": "osm:555", "action": "accept"})
        self.assertEqual(self.decisions(), [])

    def test_guest_cannot_reject_candidates(self):
        self.assertEqual(_get(self.port, "/candidates", cookie="")[0], 401)
        code = _post(self.port, "/candidates/act",
                     {"candidate_id": "osm:555", "action": "reject"}, cookie="")
        self.assertEqual(code, 401)
        self.assertEqual(self.decisions(), [])

    def test_map_screen_links_to_the_open_candidates(self):
        """Экран «Положение» — это карта; раздел виден с неё и несёт счётчик
        открытых, а не всех."""
        _post(self.port, "/candidates/act", {"candidate_id": "osm:555", "action": "reject"})
        conf = admin_auth.read_config(self.conf.name)
        conf["yandex_key"] = "test-key"
        with open(self.conf.name, "w", encoding="utf-8") as handle:
            handle.writelines(f"{k}={v}\n" for k, v in conf.items())
        try:
            code, body = _get(self.port, "/map")
        finally:
            conf.pop("yandex_key", None)
            with open(self.conf.name, "w", encoding="utf-8") as handle:
                handle.writelines(f"{k}={v}\n" for k, v in conf.items())
        self.assertEqual(code, 200)
        self.assertIn("Кандидаты (не в базе) · 1", body)
        self.assertIn('href="/candidates"', body)

    def test_missing_candidates_file_is_an_empty_section_not_an_error(self):
        saved = admin.CANDIDATES_PATH
        admin.CANDIDATES_PATH = saved + ".missing"
        try:
            code, body = _get(self.port, "/candidates")
        finally:
            admin.CANDIDATES_PATH = saved
        self.assertEqual(code, 200)
        self.assertIn("Кандидатов нет", body)
        self.assertIn("build_camera_candidates.py", body)

    # --- Вход ---

    def test_guest_sees_login_not_data(self):
        """Без сессии панель не отдаёт ничего, кроме формы входа. Это главная
        проверка всего замка: любой другой ответ здесь — открытая дверь."""
        for path in ("/", "/cameras", "/mobile", "/feedback", "/usage", "/health"):
            code, body = _get(self.port, path, cookie="")
            self.assertEqual(code, 401, path)
            self.assertNotIn("Юнусабад", body, f"{path}: данные видны гостю")

    def test_guest_cannot_act(self):
        """POST без сессии не должен ничего менять — иначе замок только на GET."""
        self.add_report()
        code = _post(self.port, "/cameras/act",
                     {"camera_id": 7, "action": "hide"}, cookie="")
        self.assertEqual(code, 401)
        conn = admin.db()
        try:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM overrides").fetchone()[0], 0)
        finally:
            conn.close()

    def test_login_works_with_origin_null(self):
        """Браузер шлёт `Origin: null`, когда политика реферера запрещает его
        раскрывать. Это НЕ чужой источник — панель отвергала так собственную
        форму входа с 403, и увидеть это можно было только в браузере: curl
        заголовок не шлёт вовсе, поэтому тесты молчали."""
        data = urllib.parse.urlencode({"password": TEST_PASSWORD}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/login",
                                     data=data, method="POST",
                                     headers={"Origin": "null"})

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req, timeout=10) as resp:
                code, cookie = resp.status, resp.headers.get("Set-Cookie", "")
        except urllib.error.HTTPError as e:
            # 303 прилетает исключением: куку читаем из него же.
            code, cookie = e.code, (e.headers.get("Set-Cookie", "") if e.headers else "")
        self.assertEqual(code, 303, "вход с Origin: null должен проходить")
        self.assertTrue(cookie, "сессия не выдана")

    def test_foreign_origin_is_still_refused(self):
        """Послабление для «null» не должно открывать дорогу чужой странице."""
        code = _post(self.port, "/cameras/act", {"camera_id": 7, "action": "hide"},
                     origin="http://evil.example")
        self.assertEqual(code, 403)

    def test_wrong_password_gives_no_session(self):
        self.assertEqual(self.login(self.port, "не тот пароль"), "")

    def test_password_is_stored_hashed(self):
        """В конфиге не должно быть пароля открытым текстом."""
        stored = admin_auth.read_config(self.conf.name).get("password_hash", "")
        self.assertTrue(stored.startswith("scrypt$"))
        self.assertNotIn(TEST_PASSWORD, stored)
        self.assertTrue(admin_auth.check_password(TEST_PASSWORD, stored))
        self.assertFalse(admin_auth.check_password(TEST_PASSWORD + "x", stored))

    def test_broken_hash_is_a_closed_door(self):
        """Испорченная запись — «нет», а не «пускать всех»."""
        for junk in ("", "scrypt$", "bcrypt$a$b", "мусор", "scrypt$!!$??"):
            self.assertFalse(admin_auth.check_password("что угодно", junk), junk)

    def test_logout_kills_the_session(self):
        """Выход обязан отзывать куку НА СЕРВЕРЕ, а не только просить браузер
        её забыть: иначе уведённая сессия переживает выход."""
        token = self.login(self.port, TEST_PASSWORD)
        self.assertTrue(token)
        self.assertEqual(_get(self.port, "/cameras", cookie=token)[0], 200)
        try:
            _get(self.port, "/logout", cookie=token)
            self.assertEqual(_get(self.port, "/cameras", cookie=token)[0], 401)
        finally:
            # Выход перевыпустил секрет и оборвал общую сессию стенда — она
            # нужна остальным тестам, входим заново.
            COOKIE["value"] = self.login(self.port, TEST_PASSWORD)

    def test_brute_force_is_throttled(self):
        sessions = admin_auth.Sessions()
        for _ in range(admin_auth.MAX_ATTEMPTS):
            self.assertFalse(sessions.blocked("10.0.0.9"))
            sessions.note_failure("10.0.0.9")
        self.assertTrue(sessions.blocked("10.0.0.9"))
        # Успешный вход снимает счётчик, чужой адрес не задет.
        self.assertFalse(sessions.blocked("10.0.0.10"))
        sessions.note_success("10.0.0.9")
        self.assertFalse(sessions.blocked("10.0.0.9"))

    def test_session_expires(self):
        sessions = admin_auth.Sessions(ttl=60, secret="s3cret")
        token = sessions.issue(now=1000)
        self.assertTrue(sessions.valid(token, now=1030))
        self.assertFalse(sessions.valid(token, now=1061))

    def test_session_survives_restart(self):
        """Главная причина, по которой вход «не работал»: сессии жили в памяти,
        и любой перезапуск панели (то есть любой деплой) выкидывал модератора
        на форму входа. Со стороны это неотличимо от неверного пароля."""
        issued = admin_auth.Sessions(ttl=3600, secret="s3cret").issue(now=1000)
        after_restart = admin_auth.Sessions(ttl=3600, secret="s3cret")
        self.assertTrue(after_restart.valid(issued, now=1500),
                        "перезапуск панели не должен разлогинивать")

    def test_forged_session_is_rejected(self):
        """Кука — это срок годности плюс подпись. Без подписи или с чужой
        подписью она не должна пускать: иначе достаточно вписать дату."""
        sessions = admin_auth.Sessions(ttl=3600, secret="s3cret")
        far_future = str(int(2_000_000_000))
        for forged in ("", "мусор", far_future, far_future + ".",
                       far_future + ".deadbeef", "." + far_future):
            self.assertFalse(sessions.valid(forged, now=1000), forged)
        # Подпись от другого секрета — тоже нет.
        alien = admin_auth.Sessions(ttl=3600, secret="другой").issue(now=1000)
        self.assertFalse(sessions.valid(alien, now=1100))

    def test_password_change_kills_sessions(self):
        """Смена пароля — единственный способ отозвать выданные куки, поэтому
        она обязана перевыпускать секрет подписи."""
        path = tempfile.NamedTemporaryFile(suffix=".conf", delete=False).name
        try:
            admin_auth.write_password("pervyj-parol-1", path)
            first = admin_auth.read_config(path)["session_secret"]
            token = admin_auth.Sessions(secret=first).issue()
            admin_auth.write_password("vtoroj-parol-2", path)
            second = admin_auth.read_config(path)["session_secret"]
            self.assertNotEqual(first, second)
            self.assertFalse(admin_auth.Sessions(secret=second).valid(token))
        finally:
            os.unlink(path)

    def test_plain_http_from_outside_is_refused(self):
        """Пароль по открытому HTTP ушёл бы открытым текстом. Пока нет TLS,
        панель отказывает всем, кроме локального соединения."""
        self.assertTrue(admin_auth.require_secure({}, "127.0.0.1"))
        self.assertFalse(admin_auth.require_secure({}, "203.0.113.7"))
        self.assertTrue(admin_auth.require_secure({"X-Forwarded-Proto": "https"},
                                                  "203.0.113.7"))

    # --- Положение камеры: очередь и карта ---

    def test_map_payload_colours_the_work(self):
        """Цвет маркера — это очередь работы: решение перекрывает жалобу,
        жалоба перекрывает догадку алгоритма."""
        conn = admin.db()
        try:
            admin._cameras = {
                1: {"id": 1, "lat": 41.3, "lon": 69.2, "location": "Без дороги",
                    "city": "", "region": "", "type": "Стационар камера"},
                2: {"id": 2, "lat": 41.4, "lon": 69.3, "location": "Тротуар",
                    "city": "", "region": "", "type": "Стационар камера",
                    "cls": "footway", "road": [0, 0, 1, 1]},
                3: {"id": 3, "lat": 41.5, "lon": 69.4, "location": "Жалоба",
                    "city": "", "region": "", "type": "Стационар камера",
                    "cls": "primary", "road": [0, 0, 1, 1]},
                4: {"id": 4, "lat": 41.6, "lon": 69.5, "location": "Хорошая",
                    "city": "", "region": "", "type": "Стационар камера",
                    "cls": "primary", "road": [0, 0, 1, 1]},
            }
            admin._cameras_mtime = os.path.getmtime(admin.CAMERAS_PATH)
            self.add_report(camera_id=3, reason="wrong_location")
            state = {row[0]: row[3] for row in admin.cameras_payload(conn)}
            self.assertEqual(state[4], admin.STATE_PLAIN)
            self.assertEqual(state[1], admin.STATE_SUSPECT, "нет куска дороги")
            self.assertEqual(state[2], admin.STATE_SUSPECT, "снап на тротуаре")
            self.assertEqual(state[3], admin.STATE_COMPLAINT, "жалоба важнее догадки")

            conn.execute("INSERT OR REPLACE INTO overrides(camera_id, op, lat, lon, "
                         "type, note, decided_at, published_at) "
                         "VALUES(3,'move',41.55,69.45,NULL,'',?,NULL)", (time.time(),))
            conn.commit()
            payload = {row[0]: row for row in admin.cameras_payload(conn)}
            self.assertEqual(payload[3][3], admin.STATE_DECIDED, "решение перекрывает всё")
            self.assertEqual(payload[3][1], 41.55, "карта должна показывать новое место")
        finally:
            conn.close()
            admin._cameras, admin._cameras_mtime = {}, 0

    def test_move_json_saves_and_undo_removes(self):
        """Перенос и отмена — по одному запросу, без перезагрузки страницы."""
        code, body = _post_json(self.port, "/api/move",
                                {"id": 7, "lat": 41.3105, "lon": 69.2505})
        self.assertEqual(code, 200, body)
        self.assertEqual(json.loads(body)["pending"], 1)
        conn = admin.db()
        try:
            self.assertEqual(
                conn.execute("SELECT op FROM overrides WHERE camera_id=7").fetchone()["op"],
                "move")
        finally:
            conn.close()

        code, body = _post_json(self.port, "/api/undo", {"id": 7})
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["pending"], 0)
        conn = admin.db()
        try:
            self.assertIsNone(
                conn.execute("SELECT op FROM overrides WHERE camera_id=7").fetchone())
        finally:
            conn.close()

    def test_move_json_refuses_what_the_app_would_reject(self):
        """Проверки живут на СЕРВЕРЕ: браузер подсказывает, решает панель."""
        self.assertEqual(_post_json(self.port, "/api/move",
                                    {"id": 7, "lat": 41.40, "lon": 69.25})[0], 400)
        self.assertEqual(_post_json(self.port, "/api/move",
                                    {"id": 7, "lat": 55.75, "lon": 37.61})[0], 400)
        self.assertEqual(_post_json(self.port, "/api/move",
                                    {"id": 999999, "lat": 41.31, "lon": 69.25})[0], 404)
        conn = admin.db()
        try:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) c FROM overrides").fetchone()["c"], 0,
                "отвергнутая правка не должна попадать в базу")
        finally:
            conn.close()

    def test_guest_cannot_touch_the_json_api(self):
        for path in ("/api/cameras", "/api/camera/7", "/api/search?q=" + urllib.parse.quote("юну")):
            self.assertEqual(_get(self.port, path, cookie="")[0], 401, path)
        self.assertEqual(_post_json(self.port, "/api/move",
                                    {"id": 7, "lat": 41.31, "lon": 69.25},
                                    cookie="")[0], 401)

    def test_search_finds_by_id_and_address(self):
        self.assertEqual(json.loads(_get(self.port, "/api/search?q=7")[1])["found"][0]["id"], 7)
        self.assertEqual(
            json.loads(_get(self.port, "/api/search?q=" + urllib.parse.quote("юнусабад"))[1])["found"][0]["id"], 7)
        self.assertEqual(json.loads(_get(self.port, "/api/search?q=")[1])["found"], [])

    def test_map_needs_key_and_states_the_cost(self):
        """Без ключа — честное объяснение. С ключом — цена переноса на экране."""
        code, body = _get(self.port, "/map")
        self.assertEqual(code, 200)
        self.assertIn("yandex_key", body)

        conf = admin_auth.read_config(self.conf.name)
        conf["yandex_key"] = "test-key"
        with open(self.conf.name, "w", encoding="utf-8") as handle:
            handle.writelines(f"{k}={v}\n" for k, v in conf.items())
        try:
            code, body = _get(self.port, "/map")
            self.assertEqual(code, 200)
            self.assertIn("теряет измеренный профиль", body)
            self.assertIn("/static/moderate.js", body)
        finally:
            conf.pop("yandex_key")
            with open(self.conf.name, "w", encoding="utf-8") as handle:
                handle.writelines(f"{k}={v}\n" for k, v in conf.items())

    def test_map_csp_allows_its_own_data(self):
        """Карта берёт камеры и сохраняет правки со своего же сервера. Без
        'self' в connect-src страница открывается, но остаётся ПУСТОЙ: запросы
        молча блокирует политика. На стенде без CSP это не видно вовсе."""
        policy = admin.Handler.CSP_MAP
        connect = [part for part in policy.split(";") if "connect-src" in part][0]
        self.assertIn("'self'", connect, "карта не сможет загрузить свои данные")
        self.assertIn("api-maps.yandex.ru", connect)
        # yastatic.net — не мелочь: api-maps.yandex.ru отдаёт только загрузчик,
        # сам код карты лежит там. Без него страница открывается, а карта
        # остаётся пустой — единственная улика в консоли браузера.
        scripts = [p for p in policy.split(";") if "script-src" in p][0]
        self.assertIn("yastatic.net", scripts, "карта не догрузит свой код")
        # И при этом политика обязана оставаться закрытой по умолчанию.
        self.assertIn("default-src 'none'", policy)
        self.assertNotIn("'unsafe-inline'", policy.split("script-src")[1].split(";")[0])

    def test_old_paths_lead_to_the_map(self):
        """Ссылки из очереди жалоб не должны ломаться, а второго способа
        двигать камеру быть не должно."""
        for path in ("/positions", "/cameras/7/map"):
            self.assertIn(_get(self.port, path)[0], (200, 303), path)

    def test_static_serves_only_the_whitelist(self):
        """Отдача файлов по имени из URL — способ вынести наружу что угодно."""
        self.assertEqual(_get(self.port, "/static/moderate.js")[0], 200)
        for path in ("/static/../admin.py", "/static/admin_auth.py", "/static/x.js"):
            self.assertEqual(_get(self.port, path)[0], 404, path)

    def test_actions_survive_missing_reports_table(self):
        """Панель может подняться раньше api.py, который владеет camera_reports.

        Раньше её отсутствие роняло обработчик ПОСЛЕ записи правки и ДО commit:
        модератор видел ошибку, а решение исчезало. Проверяем на отдельной базе,
        чтобы не ломать общий стенд.
        """
        fresh = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        fresh.close()
        old_path, admin.DB_PATH = admin.DB_PATH, fresh.name
        try:
            admin.init_db()          # только overrides и журнал, без camera_reports
            conn = admin.db()
            try:
                self.assertIsNone(
                    conn.execute("SELECT name FROM sqlite_master WHERE "
                                 "name = 'camera_reports'").fetchone())
                handler = admin.Handler.__new__(admin.Handler)
                # Не должно бросить: «закрывать нечего» — это не ошибка.
                handler.resolve_reports(conn, 7, admin.RESOLVED_DONE)
            finally:
                conn.close()
        finally:
            admin.DB_PATH = old_path
            os.unlink(fresh.name)


    # --- Панель на MapLibre: рядом с рабочей, за адресом -------------------
    #
    # Переход идёт параллельно, а не заменой: конструктор — единственный
    # инструмент разметки, и если он неделю ведёт себя странно, встаёт вся
    # работа по картам. Откат здесь — это адрес, а не выкат.

    def test_gl_page_carries_the_strict_policy(self):
        code, body, headers = _get_full(self.port, "/editor-gl")
        self.assertEqual(code, 200)
        csp = headers.get("Content-Security-Policy", "")
        # Чужих источников на странице нет вовсе: библиотека лежит своим
        # файлом, тайлы свои. Поэтому политика строже рабочей, а не мягче.
        self.assertIn("script-src 'self'", csp)
        self.assertNotIn("yandex", csp)
        # blob: обязателен: MapLibre поднимает воркеры из blob-URL, и без
        # этого карта молча не рисует ничего.
        self.assertIn("worker-src blob:", csp)
        text = body.decode()
        self.assertIn("maplibre-gl.js", text)
        self.assertIn("editor_gl.js", text)

    def test_gl_page_needs_a_session(self):
        code, _body, _headers = _get_full(self.port, "/editor-gl", cookie="")
        self.assertNotEqual(code, 200)

    def test_library_comes_from_our_own_host(self):
        code, body, headers = _get_full(self.port, "/static/vendor/maplibre-gl.js")
        self.assertEqual(code, 200)
        self.assertIn(b"MapLibre GL JS", body[:400])
        self.assertIn("javascript", headers.get("Content-Type", ""))

    def test_static_takes_names_from_the_list_only(self):
        # Отдавать файлы по имени из URL нельзя: так наружу уезжает /etc/passwd.
        for name in ("../admin.py", "vendor/../../admin.py", "secrets.env"):
            code, _body, _headers = _get_full(self.port, "/static/" + name)
            self.assertNotEqual(code, 200, name)

    def test_missing_tile_is_no_data_not_an_error(self):
        # «Нет данных здесь» и «адрес неверный» ведут к разному поведению
        # клиента: путать их значит получать красные строки в консоли на
        # каждом пустом квадрате.
        code, _body, _headers = _get_full(self.port, "/mvt/15/22690/12247.mvt")
        self.assertEqual(code, 204)

    def test_tile_path_takes_numbers_only(self):
        for path in ("/mvt/15/../../admin.py.mvt", "/mvt/a/b/c.mvt",
                     "/mvt/15/1.mvt"):
            code, _body, _headers = _get_full(self.port, path)
            self.assertEqual(code, 404, path)


class AccountTests(unittest.TestCase):
    """Учётные записи.

    Пароль был один, и журнал писал «edit-withdraw #5» — на вопрос «кто снял»
    ответить было нечем. Пока модератор один, это терпимо; на втором человеке
    становится дырой: снятую чужую правку не отличить от своей.

    Без HTTP-сервера и НЕ наследуясь от AdminTest: конфигурация здесь
    переписывается, а у общего стенда в ней лежит секрет подписи сессий —
    чужие тесты после такого получали бы 401 на ровном месте.
    """

    def setUp(self):
        handle = tempfile.NamedTemporaryFile(suffix=".conf", delete=False)
        handle.close()
        self.conf = handle.name
        self.addCleanup(os.unlink, self.conf)
        self.saved_path = admin_auth.CONFIG_PATH
        admin_auth.CONFIG_PATH = self.conf
        self.addCleanup(setattr, admin_auth, "CONFIG_PATH", self.saved_path)
        admin_auth.write_password("пароль-владельца-1234", self.conf)

    def test_owner_signs_in_without_a_name(self):
        # Так входили до появления имён, и ломать это ради формы нельзя:
        # обновление панели выкинуло бы из неё единственного человека.
        self.assertEqual(
            admin_auth.who_signs_in("", "пароль-владельца-1234"),
            admin_auth.OWNER)

    def test_named_person_signs_in(self):
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        self.assertEqual(
            admin_auth.who_signs_in("иван", "пароль-ивана-1234"), "иван")

    def test_right_password_wrong_name_is_refused(self):
        # Иначе пароль владельца пускал бы под любым именем, и журнал врал бы
        # именно там, где на него полагаются.
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        self.assertIsNone(
            admin_auth.who_signs_in("иван", "пароль-владельца-1234"))

    def test_unknown_name_is_refused(self):
        self.assertIsNone(
            admin_auth.who_signs_in("пётр", "пароль-владельца-1234"))

    def test_account_can_be_dropped(self):
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        self.assertTrue(admin_auth.drop_account("иван", self.conf))
        self.assertIsNone(admin_auth.who_signs_in("иван", "пароль-ивана-1234"))
        self.assertFalse(admin_auth.drop_account("иван", self.conf))

    def test_owner_name_is_not_free_to_take(self):
        with self.assertRaises(ValueError):
            admin_auth.write_account(admin_auth.OWNER, "любой", self.conf)

    def test_password_change_still_kills_sessions(self):
        # Смена пароля обязана перевыпускать секрет подписи: иначе украденная
        # кука переживает единственное действие, которым её можно отозвать.
        before = admin_auth.read_config(self.conf)["session_secret"]
        admin_auth.write_password("другой-пароль-1234", self.conf)
        self.assertNotEqual(
            before, admin_auth.read_config(self.conf)["session_secret"])

    def test_adding_a_person_does_not_kick_everyone_out(self):
        # А вот заведение человека — не должно: иначе каждый новый модератор
        # выкидывает из панели всех остальных.
        before = admin_auth.read_config(self.conf)["session_secret"]
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        self.assertEqual(
            before, admin_auth.read_config(self.conf)["session_secret"])

    def test_cookie_carries_the_name_and_stays_ascii(self):
        # Заголовки HTTP — latin-1: кириллическое имя в куке роняло весь ответ
        # на входе, человек вводил верный пароль и получал обрыв соединения.
        sessions = admin_auth.Sessions(secret="тест")
        token = sessions.issue(name="владелец")
        self.assertTrue(token.isascii(), token)
        self.assertEqual(sessions.name_of(token), "владелец")

    def test_name_in_the_cookie_cannot_be_swapped(self):
        sessions = admin_auth.Sessions(secret="тест")
        token = sessions.issue(name="иван")
        self.assertFalse(sessions.valid(token.replace("%D0%B8", "%D0%BF")))

    def test_old_cookie_without_a_name_still_works(self):
        # Куку выдали до появления имён — это владелец, а не «выйти всем».
        sessions = admin_auth.Sessions(secret="тест")
        self.assertEqual(sessions.name_of(sessions.issue()), "")

    def test_removed_moderator_is_out_at_once(self):
        # Кука сверяется со списком учёток на каждом запросе: убранный человек
        # не сидит в панели ещё 12 часов, остальные из неё не вылетают (M-6).
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        admin_auth.write_account("пётр", "пароль-петра-1234", self.conf)
        sessions = admin_auth.Sessions()
        ivan, petr, owner = sessions.issue(name="иван"), sessions.issue(name="пётр"), sessions.issue()
        self.assertTrue(sessions.valid(ivan))
        admin_auth.drop_account("иван", self.conf)
        self.assertFalse(sessions.valid(ivan), "убранный модератор выходит сразу")
        self.assertEqual(sessions.name_of(ivan), "")
        self.assertTrue(sessions.valid(petr), "соседа удаление не задевает")
        self.assertTrue(sessions.valid(owner))
        # Вернули под тем же именем — старая кука всё равно мертва: новый хэш.
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        self.assertFalse(sessions.valid(ivan))

    def test_password_change_of_a_moderator_kills_only_his_cookies(self):
        admin_auth.write_account("иван", "пароль-ивана-1234", self.conf)
        admin_auth.write_account("пётр", "пароль-петра-1234", self.conf)
        sessions = admin_auth.Sessions()
        ivan, petr = sessions.issue(name="иван"), sessions.issue(name="пётр")
        admin_auth.write_account("иван", "новый-пароль-ивана-1", self.conf)
        self.assertFalse(sessions.valid(ivan), "уведённая кука не переживает смену пароля")
        self.assertTrue(sessions.valid(petr))

    def test_cookie_for_an_unknown_name_is_refused(self):
        sessions = admin_auth.Sessions(secret="тест", people={admin_auth.OWNER: "h"})
        self.assertFalse(sessions.valid(sessions.issue(name="никто")))
        self.assertTrue(sessions.valid(sessions.issue()))
        self.assertFalse(admin_auth.Sessions(secret="тест", people={}).valid(sessions.issue()),
                         "учёток не осталось — не пускаем никого")


class PaletteTests(AdminTest):
    """Палитра конструктора.

    Список слов требует помнить, чем проспект отличается от проезда, — а
    отличаются они шириной и разметкой, то есть тем, что видно с одного
    взгляда. И открываться конструктор обязан на СВОЕЙ карте: он дорабатывает
    нашу схему, а не чужой снимок.
    """

    def page(self):
        # Ключ ставим на время одного запроса и убираем сразу: без ключа
        # страница честно говорит, что карта не загрузится, и палитры на ней
        # нет вовсе, а оставленный ключ ломал бы соседний тест про это.
        conf = admin_auth.read_config(self.conf.name)
        conf["yandex_key"] = "test-key"
        with open(self.conf.name, "w", encoding="utf-8") as handle:
            handle.writelines(f"{k}={v}\n" for k, v in conf.items())
        try:
            code, body = _get(self.port, "/editor")
        finally:
            conf.pop("yandex_key", None)
            with open(self.conf.name, "w", encoding="utf-8") as handle:
                handle.writelines(f"{k}={v}\n" for k, v in conf.items())
        self.assertEqual(code, 200)
        return body

    def test_every_tool_is_drawn(self):
        body = self.page()
        self.assertEqual(body.count("<svg"), body.count('class="ico"'),
                         "какой-то инструмент остался без рисунка")
        self.assertGreaterEqual(body.count("<svg"), 15)

    def test_road_classes_differ_by_width(self):
        # Ширина на значке — не украшение: это единственное, чем классы
        # отличаются на дороге, и выбирают их именно по ней.
        body = self.page()
        for height in ('height="20"', 'height="14"', 'height="10"',
                       'height="6"'):
            self.assertIn(height, body)

    def test_keys_are_shown_next_to_the_tool(self):
        # Конструктором работают двумя руками; подсмотреть букву надо там же,
        # где выбирают инструмент, а не в справке внизу.
        body = self.page()
        for key in ("Q", "W", "E", "R", "A", "S", "D", "F", "G", "Z"):
            self.assertIn(f'<span class="key">{key}</span>', body)

    def test_opens_on_our_own_map(self):
        body = self.page()
        self.assertIn('id="viewschema" class="view on"', body)
        self.assertIn('id="viewsat" class="view"', body)

    def test_palette_has_no_leftover_word_lists(self):
        # Старые подписи вида «Q · Проспект» означали бы, что где-то осталась
        # кнопка мимо палитры.
        body = self.page()
        for stale in ("Q · Проспект", "A · Светофор", "1 · Полосы"):
            self.assertNotIn(stale, body)


class ChangesHistoryTests(AdminTest):
    """История в очереди изменений.

    Endpoint, которого не видно на экране, — это не история, а строчка в
    журнале запросов. Модератор, увидевший «сдвиг 12 м», первым делом
    спрашивает, куда объект стоял до него, и спросить он должен здесь же.
    """

    def setUp(self):
        super().setUp()
        self.work = tempfile.mkdtemp()
        self.old_tiles = os.environ.get("RADARMAP_TILES")
        os.environ["RADARMAP_TILES"] = self.work
        step = map_edits.TILE_DEGREES_V2
        row = int((41.30 + 90) / step)
        column = int((69.25 + 180) / step)
        with open(os.path.join(self.work, f"road2_{row}_{column}_s.json"),
                  "w", encoding="utf-8") as handle:
            json.dump({"version": 2, "roads":
                       [[3, 0, [4_130_000, 6_925_000, 200, 0], "Навои"]]},
                      handle, ensure_ascii=False)
        conn = admin.db()
        try:
            conn.execute("DELETE FROM map_edits")
            conn.execute("DELETE FROM map_edit_history")
            conn.commit()
        finally:
            conn.close()

    def tearDown(self):
        if self.old_tiles is None:
            os.environ.pop("RADARMAP_TILES", None)
        else:
            os.environ["RADARMAP_TILES"] = self.old_tiles
        shutil.rmtree(self.work, ignore_errors=True)

    def moved_edit(self):
        conn = admin.db()
        try:
            edit_id = map_edits.create(conn, "lanes", raw=[69.2500, 41.3000],
                                       snapped=[69.2500, 41.3000],
                                       props={"lanes": 4},
                                       status=map_edits.ACCEPTED)
            map_edits.update(conn, edit_id, 1, geom=[69.2502, 41.3001])
            conn.commit()
        finally:
            conn.close()
        return edit_id

    def test_history_is_offered_in_the_queue(self):
        self.moved_edit()
        code, body = _get(self.port, "/changes")
        self.assertEqual(code, 200)
        self.assertIn("Было раньше", body)
        self.assertIn("41.30000", body, "прежней точки не видно")

    def test_edit_without_history_shows_no_empty_block(self):
        conn = admin.db()
        try:
            map_edits.create(conn, "lanes", raw=[69.25, 41.30],
                             snapped=[69.25, 41.30], props={"lanes": 4},
                             status=map_edits.ACCEPTED)
            conn.commit()
        finally:
            conn.close()
        self.assertNotIn("Было раньше", _get(self.port, "/changes")[1])

    def test_history_endpoint_and_page_agree(self):
        edit_id = self.moved_edit()
        code, body = _get(self.port, f"/api/edit/{edit_id}/history")
        self.assertEqual(code, 200)
        rows = json.loads(body)["history"]
        self.assertEqual(len(rows), 1)
        self.assertIn(f"в{rows[0]['version']} ", _get(self.port, "/changes")[1])


class EditorApiTests(AdminTest):
    """Ручки конструктора.

    Три запрета, каждый — про то, что панель не должна уметь. Она не публикует
    (закон 2: подписывает и выкладывает владелец со своей машины). Она не
    отдаёт всё разом — в тайле Ташкента 71 595 дорог, и «без рамки» убило бы её
    на первом открытии. И она не даёт второму окну молча затереть первое.
    """

    def setUp(self):
        super().setUp()
        conn = admin.db()
        try:
            conn.execute("DELETE FROM map_edits")
            conn.commit()
        finally:
            conn.close()

    def test_editor_needs_a_session(self):
        self.assertEqual(_get(self.port, "/editor", cookie="")[0], 401)
        self.assertEqual(_get(self.port, "/api/edits?south=41&west=69&north=42&east=70",
                              cookie="")[0], 401)

    def test_api_refuses_to_dump_everything(self):
        self.assertEqual(_get(self.port, "/api/edits")[0], 400)
        self.assertEqual(_get(self.port, "/api/roads")[0], 400)

    def test_unknown_kind_is_refused(self):
        code, _ = _post_json(self.port, "/api/edit",
                             {"kind": "выдумка", "geom": [69.25, 41.3],
                              "raw": [69.25, 41.3]})
        self.assertEqual(code, 400)

    def test_panel_cannot_publish(self):
        # Статус «опубликовано» ставит только запекание с машины владельца.
        code, _ = _post_json(self.port, "/api/edit",
                             {"kind": "lanes", "status": 2,
                              "geom": [69.25, 41.3], "raw": [69.25, 41.3]})
        self.assertEqual(code, 400)

    def test_save_then_stale_save_is_refused(self):
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4}})
        self.assertEqual(code, 200, body)
        created = json.loads(body)
        code, _ = _post_json(self.port, "/api/edit",
                             {"id": created["id"], "version": created["version"],
                              "kind": "lanes", "geom": [69.25, 41.3],
                              "raw": [69.25, 41.3], "props": {"lanes": 6}})
        self.assertEqual(code, 200)
        # Второе окно держит устаревшую версию.
        code, _ = _post_json(self.port, "/api/edit",
                             {"id": created["id"], "version": created["version"],
                              "kind": "lanes", "geom": [69.25, 41.3],
                              "raw": [69.25, 41.3], "props": {"lanes": 2}})
        self.assertEqual(code, 409, "устаревшая версия обязана быть отвергнута")

    def test_saved_edit_shows_up_in_its_bbox_only(self):
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.30, 41.35],
                                 "raw": [69.30, 41.35], "props": {"lanes": 4}})
        self.assertEqual(code, 200, body)
        near = json.loads(_get(self.port,
            "/api/edits?south=41.34&west=69.29&north=41.36&east=69.31")[1])
        self.assertTrue(any(e["geom"] == [69.30, 41.35] for e in near["edits"]))
        far = json.loads(_get(self.port,
            "/api/edits?south=40.0&west=68.0&north=40.5&east=68.5")[1])
        self.assertEqual(far["edits"], [])

    def test_snap_needs_a_point(self):
        self.assertEqual(_post_json(self.port, "/api/snap", {})[0], 400)

    def test_snap_offers_choices_rather_than_a_refusal(self):
        # «Приблизьте карту» ответом не является: приближение не разводит две
        # проезжие части, они физически в двадцати метрах друг от друга. Ручка
        # обязана отдавать список, у каждого элемента которого уже посчитана
        # своя посадка, — иначе выбор стоил бы второго запроса.
        code, body = _post_json(self.port, "/api/snap",
                                {"lat": 41.31, "lon": 69.25})
        self.assertEqual(code, 200)
        payload = json.loads(body)
        self.assertIn("candidates", payload)
        self.assertIsInstance(payload["candidates"], list)

    def test_withdrawn_edit_can_be_brought_back(self):
        # Отмена — это возврат предыдущей версии, а не отдельный механизм.
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "status": 1})
        self.assertEqual(code, 200, body)
        made = json.loads(body)
        code, _ = _post_json(self.port, "/api/edit/withdraw",
                             {"id": made["id"], "version": made["version"]})
        self.assertEqual(code, 200)
        gone = json.loads(_get(self.port,
            "/api/edits?south=41.29&west=69.24&north=41.31&east=69.26")[1])
        self.assertEqual(gone["edits"], [], "снятая правка осталась на карте")

        code, _ = _post_json(self.port, "/api/edit",
                             {"id": made["id"], "version": made["version"] + 1,
                              "kind": "lanes", "geom": [69.25, 41.3],
                              "raw": [69.25, 41.3], "props": {"lanes": 4},
                              "status": 1})
        self.assertEqual(code, 200)
        back = json.loads(_get(self.port,
            "/api/edits?south=41.29&west=69.24&north=41.31&east=69.26")[1])
        self.assertEqual(len(back["edits"]), 1, "отмена не вернула правку")

    def test_changes_page_says_when_there_is_nothing_to_compare_with(self):
        # Тайлов на стенде нет. Пустая страница здесь была бы враньём: она
        # читалась бы как «всё в порядке», хотя сверять правки просто не с чем.
        code, body = _get(self.port, "/changes")
        self.assertEqual(code, 200)
        self.assertIn("Сверять правки не с чем", body)

    def test_author_of_an_edit_is_the_person_not_the_browser(self):
        # Автор из тела запроса позволял подписать правку любым именем — и
        # журнал врал бы именно там, где на него полагаются.
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "author": "не-я", "status": 1})
        self.assertEqual(code, 200, body)
        made = json.loads(body)
        conn = admin.db()
        try:
            edit = map_edits.by_id(conn, made["id"])
        finally:
            conn.close()
        self.assertNotEqual(edit["author"], "не-я")
        self.assertEqual(edit["author"], admin_auth.OWNER)

    def test_journal_shows_who_did_it(self):
        # Журнал писал «edit-withdraw #5» и молчал о том, кто это сделал.
        conn = admin.db()
        try:
            admin.log_action(conn, None, "edit-withdraw", "#5", who="иван")
            conn.commit()
        finally:
            conn.close()
        body = _get(self.port, "/journal")[1]
        self.assertIn("иван", body)
        self.assertIn("edit-withdraw", body)

    def test_journal_search_narrows_to_the_person(self):
        conn = admin.db()
        try:
            admin.log_action(conn, None, "edit-save", "правка #77", who="иван")
            admin.log_action(conn, None, "edit-save", "правка #88", who="пётр")
            conn.commit()
        finally:
            conn.close()
        body = _get(self.port, "/journal?q=" + urllib.parse.quote("иван"))[1]
        rows = body.split("<main>")[1]
        self.assertIn("правка #77", rows)
        self.assertNotIn("правка #88", rows)

    def test_journal_links_to_the_edit(self):
        # Запись журнала без ссылки на объект — это строка, после которой надо
        # идти искать руками.
        conn = admin.db()
        try:
            admin.log_action(conn, None, "edit-save", "#42", who="иван")
            conn.commit()
        finally:
            conn.close()
        self.assertIn("?edit=42", _get(self.port, "/journal")[1])

    def test_journal_needs_a_session(self):
        self.assertEqual(_get(self.port, "/journal", cookie="")[0], 401)

    def test_summary_counts_the_constructor(self):
        # Конструктор — половина панели, а сводка о нём не знала вовсе.
        conn = admin.db()
        try:
            conn.execute("DELETE FROM map_edits")
            map_edits.create(conn, "lanes", raw=[69.25, 41.30],
                             snapped=[69.25, 41.30], props={"lanes": 4})
            map_edits.create(conn, "lock", raw=[69.25, 41.30],
                             snapped=[69.25, 41.30], props={"radius": 120},
                             status=map_edits.ACCEPTED)
            conn.commit()
        finally:
            conn.close()
        body = _get(self.port, "/")[1]
        self.assertIn("черновиков в конструкторе", body)
        self.assertIn("размеченных областей", body)

    def test_changes_page_needs_a_session(self):
        self.assertEqual(_get(self.port, "/changes", cookie="")[0], 401)

    def test_changes_action_needs_a_session(self):
        self.assertEqual(_post(self.port, "/changes/act",
                               {"id": 1, "version": 1, "op": "withdraw"},
                               cookie=""), 401)

    def test_changes_action_withdraws_and_offers_the_way_back(self):
        # Очередь разбирают подряд, и действие обязано быть в строке, а не за
        # переходом: каждый переход стоил бы возврата и потери места.
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "status": 1})
        self.assertEqual(code, 200, body)
        made = json.loads(body)
        self.assertEqual(_post(self.port, "/changes/act",
                               {"id": made["id"], "version": made["version"],
                                "op": "withdraw"}), 303)
        gone = json.loads(_get(self.port,
            "/api/edits?south=41.29&west=69.24&north=41.31&east=69.26")[1])
        self.assertEqual(gone["edits"], [])

        # Страница после действия предлагает вернуть — это и есть отмена,
        # переживающая перезагрузку.
        page = _get(self.port, "/changes?done=withdraw&id=%d&version=%d"
                    % (made["id"], made["version"] + 1))[1]
        self.assertIn("Вернуть", page)

        self.assertEqual(_post(self.port, "/changes/act",
                               {"id": made["id"], "version": made["version"] + 1,
                                "op": "restore"}), 303)
        back = json.loads(_get(self.port,
            "/api/edits?south=41.29&west=69.24&north=41.31&east=69.26")[1])
        self.assertEqual(len(back["edits"]), 1)

    def test_stale_version_does_not_overwrite_silently(self):
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "status": 1})
        made = json.loads(body)
        self.assertEqual(_post(self.port, "/changes/act",
                               {"id": made["id"], "version": 99,
                                "op": "withdraw"}), 303)
        still = json.loads(_get(self.port,
            "/api/edits?south=41.29&west=69.24&north=41.31&east=69.26")[1])
        self.assertEqual(len(still["edits"]), 1, "устаревшая версия сняла правку")
        self.assertIn("в другом окне", _get(self.port, "/changes?done=stale")[1])

    def test_confirm_appears_by_the_mark_not_by_this_weeks_verdict(self):
        # Метку ставит пересадка, и живёт она в заметке. Следующая неделя может
        # не найти сдвига вовсе — а метка останется, и снять её будет нечем,
        # то есть счётчик на вкладке не обнулится никогда.
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "status": 1, "note": "проверить: сдвиг 8.0 м"})
        self.assertEqual(code, 200, body)
        made = json.loads(body)
        self.assertEqual(_post(self.port, "/changes/act",
                               {"id": made["id"], "version": made["version"],
                                "op": "confirm"}), 303)
        conn = admin.db()
        try:
            note = conn.execute("SELECT note FROM map_edits WHERE id = ?",
                                (made["id"],)).fetchone()["note"]
        finally:
            conn.close()
        self.assertNotIn("проверить", note)

    def test_edit_is_found_by_its_number_outside_the_frame(self):
        # Номер называют, когда о правке уже говорили. Искать её глазами по
        # карте — не поиск, поэтому запрос по номеру идёт мимо рамки.
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.90, 41.90],
                                 "raw": [69.90, 41.90], "props": {"lanes": 4},
                                 "status": 1})
        made = json.loads(body)
        found = json.loads(_get(self.port, "/api/edits?id=%d" % made["id"])[1])
        self.assertEqual(len(found["edits"]), 1)
        self.assertEqual(found["edits"][0]["id"], made["id"])

    def test_withdrawn_edit_is_still_found_by_number(self):
        # «Нет такой» на снятую правку было бы враньём: она есть, просто не
        # едет на телефоны.
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "status": 1})
        made = json.loads(body)
        _post_json(self.port, "/api/edit/withdraw",
                   {"id": made["id"], "version": made["version"]})
        found = json.loads(_get(self.port, "/api/edits?id=%d" % made["id"])[1])
        self.assertEqual(len(found["edits"]), 1)
        self.assertEqual(found["edits"][0]["status"], 3)

    def test_missing_number_is_not_an_error(self):
        found = json.loads(_get(self.port, "/api/edits?id=99999")[1])
        self.assertEqual(found["edits"], [])

    def test_nonsense_number_is_refused(self):
        # Латиницей, а не кириллицей: urllib кладёт в строку запроса только
        # ascii, и кириллица здесь роняла бы сам тест, а не проверяла ручку.
        self.assertEqual(_get(self.port, "/api/edits?id=abc")[0], 400)

    def test_queue_row_says_the_name_not_the_code(self):
        # «lanes» в строке очереди читается как недоделка.
        self.assertEqual(map_edits.kind_name("lanes"), "Полосы")
        self.assertEqual(map_edits.kind_name("выдумка"), "выдумка")

    def test_unknown_operation_changes_nothing(self):
        code, body = _post_json(self.port, "/api/edit",
                                {"kind": "lanes", "geom": [69.25, 41.3],
                                 "raw": [69.25, 41.3], "props": {"lanes": 4},
                                 "status": 1})
        made = json.loads(body)
        self.assertEqual(_post(self.port, "/changes/act",
                               {"id": made["id"], "version": made["version"],
                                "op": "выдумка"}), 303)
        still = json.loads(_get(self.port,
            "/api/edits?south=41.29&west=69.24&north=41.31&east=69.26")[1])
        self.assertEqual(len(still["edits"]), 1)


class SessionEdgeTests(unittest.TestCase):
    """Границы сессии: чей это адрес и кто имеет право оборвать все куки.

    Свой стенд и НЕ наследуясь от AdminTest — по той же причине, что у
    AccountTests: здесь перевыпускается секрет подписи сессий, и общий стенд
    после такого отвечал бы 401 всем остальным тестам на ровном месте.
    """

    @classmethod
    def setUpClass(cls):
        cls.saved = (api.DB_PATH, admin.DB_PATH, admin.CAMERAS_PATH,
                     admin_auth.CONFIG_PATH, COOKIE["value"])

        handle = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        handle.close()
        cls.db = handle.name
        api.DB_PATH = admin.DB_PATH = cls.db
        api.init_db()
        admin.init_db()

        cameras = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        json.dump([], cameras)
        cameras.close()
        admin.CAMERAS_PATH = cameras.name
        cls.cameras_path = cameras.name

        conf = tempfile.NamedTemporaryFile(suffix=".conf", delete=False)
        conf.close()
        cls.conf = conf.name
        admin_auth.CONFIG_PATH = cls.conf
        admin_auth.write_password(TEST_PASSWORD, cls.conf)

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), admin.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        (api.DB_PATH, admin.DB_PATH, admin.CAMERAS_PATH,
         admin_auth.CONFIG_PATH, COOKIE["value"]) = cls.saved
        for path in (cls.db, cls.cameras_path, cls.conf):
            try:
                os.unlink(path)
            except OSError:
                pass

    def login(self, headers=None):
        """Войти и вернуть (заголовок Cookie, все заголовки ответа)."""
        data = urllib.parse.urlencode({"password": TEST_PASSWORD}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/login",
                                     data=data, method="POST")
        for name, value in (headers or {}).items():
            req.add_header(name, value)

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req, timeout=10) as resp:
                head = dict(resp.headers)
        except urllib.error.HTTPError as e:
            head = dict(e.headers or {})
        raw = head.get("Set-Cookie", "")
        return (raw.split(";")[0] if raw else ""), head

    def request(self, path, headers=None, cookie=None, fields=None):
        data = urllib.parse.urlencode(fields).encode() if fields else None
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}",
                                     data=data,
                                     method="POST" if fields else "GET")
        for name, value in (headers or {}).items():
            req.add_header(name, value)
        if cookie:
            req.add_header("Cookie", cookie)

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req, timeout=10) as resp:
                return resp.status, dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {})

    # --- заголовки (38A, 02.11.2026) ---

    def test_panel_refuses_to_be_framed(self):
        """Кликджекинг: панель в невидимой рамке чужой страницы — клик модератора
        по «Скрыть камеру». Запрет — на каждом ответе, включая редиректы."""
        cookie, _ = self.login()
        for path, who in (("/login", None), ("/", cookie), ("/", None)):
            status, headers = self.request(path, cookie=who)
            self.assertEqual(headers.get("X-Frame-Options"), "DENY", (path, status))
            csp = headers.get("Content-Security-Policy")
            if csp:
                self.assertIn("frame-ancestors 'none'", csp, (path, status))
        for policy in (admin.Handler.CSP_STRICT, admin.Handler.CSP_GL, admin.Handler.CSP_MAP):
            self.assertIn("frame-ancestors 'none'", policy)

    def test_hsts_only_behind_tls(self):
        _, plain = self.request("/login")
        self.assertNotIn("Strict-Transport-Security", plain, "туннель по http — без HSTS")
        _, tls = self.request("/login", headers={"X-Forwarded-Proto": "https"})
        self.assertEqual(tls.get("Strict-Transport-Security"), "max-age=31536000")
        self.assertNotIn("includeSubDomains", admin.Handler.HSTS, "soulmed.uz — чужой домен")

    # --- адрес клиента ---

    def test_throttle_counts_the_real_client_not_the_loopback_peer(self):
        """Перебор с одного адреса не должен запирать панель остальным.

        За nginx TCP-пир всегда 127.0.0.1, поэтому счётчик попыток считался по
        петле: восемь неверных паролей откуда угодно блокировали вход СРАЗУ
        ВСЕМ модераторам на пятнадцать минут, и повторять это можно было
        бесконечно.
        """
        victim, bystander = "203.0.113.9", "203.0.113.10"
        self.addCleanup(admin.SESSIONS.note_success, victim)
        self.addCleanup(admin.SESSIONS.note_success, bystander)
        for _ in range(admin_auth.MAX_ATTEMPTS):
            admin.SESSIONS.note_failure(victim)

        https = {"X-Forwarded-Proto": "https"}
        code, _ = self.request("/login", {**https, "X-Real-IP": victim},
                               fields={"password": "мимо"})
        self.assertEqual(code, 429, "перебор с этого адреса обязан отсекаться")

        code, _ = self.request("/login", {**https, "X-Real-IP": bystander},
                               fields={"password": "мимо"})
        self.assertEqual(code, 401,
                         "чужой перебор запер вход всем модераторам сразу")

    def test_plain_http_from_outside_is_not_treated_as_local(self):
        # Раньше проходило: пир — 127.0.0.1, значит «локально», хотя запрос
        # пришёл из интернета и пароль ехал открытым текстом.
        code, _ = self.request("/login", {"X-Real-IP": "203.0.113.11",
                                          "X-Forwarded-Proto": "http"},
                               fields={"password": TEST_PASSWORD})
        self.assertEqual(code, 403, "пароль принят по открытому HTTP извне")

    def test_secure_cookie_only_over_tls(self):
        _, head = self.login({"X-Forwarded-Proto": "https",
                              "X-Real-IP": "203.0.113.13"})
        self.assertIn("Secure", head.get("Set-Cookie", ""),
                      "по TLS кука обязана быть Secure")

        _, plain = self.login()
        self.assertNotIn("Secure", plain.get("Set-Cookie", ""),
                         "по SSH-туннелю Secure убьёт вход: куку не сохранят")

    # --- выход ---

    def test_anonymous_logout_does_not_kill_live_sessions(self):
        """`/logout` стоит ДО проверки сессии — иначе выйти было бы нельзя, —
        а гасит он секрет подписи, то есть все выданные куки разом. Значит
        анонимный GET (краулер, <img src> на чужой странице, curl в цикле)
        выкидывал из панели всех модераторов, и сколько угодно раз."""
        live, _ = self.login()
        self.assertTrue(live, "стенд не смог войти")

        code, _ = self.request("/logout")
        self.assertIn(code, (200, 303))

        code, _ = self.request("/", cookie=live)
        self.assertEqual(code, 200,
                         "анонимный GET /logout оборвал живую сессию")

    def test_logout_with_a_valid_cookie_still_ends_the_session(self):
        # Обратная сторона: честный выход обязан работать как раньше.
        live, _ = self.login()
        self.assertEqual(self.request("/", cookie=live)[0], 200)

        self.request("/logout", cookie=live)

        code, _ = self.request("/", cookie=live)
        self.assertEqual(code, 401, "выход по годной куке не оборвал сессию")


if __name__ == "__main__":
    unittest.main(verbosity=2)



class TrafficDensityTests(unittest.TestCase):
    """«Пробки» (27.E): плотность данных по городам — только счётчики.

    Стенд — тот же, что у AdminTest (сервер, база, вход), но без наследования
    его тестов: иначе весь набор AdminTest прогонялся бы второй раз."""

    login = AdminTest.login

    @classmethod
    def setUpClass(cls):
        AdminTest.setUpClass.__func__(cls)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        import test_traffic_build as fixture
        import traffic_build
        self.tb = traffic_build
        self.fixture = fixture.FIXTURE
        self.dir = tempfile.mkdtemp()
        self.saved = admin.TRAFFIC_DB_PATH
        admin.TRAFFIC_DB_PATH = os.path.join(self.dir, "traffic.db")
        self.now = time.time()

    def tearDown(self):
        admin.TRAFFIC_DB_PATH = self.saved
        shutil.rmtree(self.dir, ignore_errors=True)

    def fill(self, pieces):
        conn = sqlite3.connect(admin.TRAFFIC_DB_PATH)
        self.tb.schema(conn)
        points = [[lat, lon, t * 4, kmh] for lat, lon, t, kmh in self.fixture["points"]]
        for _ in range(pieces):
            conn.execute("INSERT INTO traffic_pieces(received, points, src, gen) VALUES(?, ?, hex(randomblob(4)), 1)",
                         (self.now, json.dumps(points)))
        conn.commit()
        self.tb.process(conn, self.now, matcher=lambda pts: self.fixture["response"])
        conn.close()

    def test_without_a_database_the_page_says_so(self):
        status, body = _get(self.port, "/traffic")
        self.assertEqual(status, 200)
        self.assertIn("traffic.db ещё нет", body)

    def test_counts_by_city_and_threshold(self):
        self.fill(2)
        status, body = _get(self.port, "/traffic")
        self.assertEqual(status, 200)
        self.assertIn("Ташкент", body)
        self.assertIn(f"кусков за час: 2 / {self.tb.CITY_READY_PIECES_PER_HOUR}", body)
        published = len(self.tb.aggregate(sqlite3.connect(admin.TRAFFIC_DB_PATH), self.now))
        self.assertIn(f"в слое сейчас: {published}", body)
        self.assertIn(f"не меньше\n  {self.tb.MIN_SOURCES} разных источников", body)

    def test_page_shows_no_ids_and_no_coordinates(self):
        self.fill(2)
        _, body = _get(self.port, "/traffic")
        for u, v, *_ in self.tb.live_edges(sqlite3.connect(admin.TRAFFIC_DB_PATH), self.now):
            self.assertNotIn(str(u), body)
            self.assertNotIn(str(v), body)
        for lat, lon, _t, _k in self.fixture["points"]:
            self.assertNotIn(f"{lat:.3f}", body)
            self.assertNotIn(f"{lon:.3f}", body)

    def test_health_carries_one_line(self):
        self.fill(1)
        _, body = _get(self.port, "/health")
        self.assertIn("пробки за час: кусков 1", body)
        self.assertIn("/traffic", body)

    def test_without_the_builder_the_panel_still_works(self):
        saved, admin.traffic_build = admin.traffic_build, None
        try:
            status, body = _get(self.port, "/traffic")
        finally:
            admin.traffic_build = saved
        self.assertEqual(status, 200)
        self.assertIn("не установлен", body)

    def test_highway_is_grouped_by_nearest_city(self):
        self.assertEqual(admin.traffic_area(41.31, 69.28), "Ташкент")
        self.assertEqual(admin.traffic_area(40.6, 68.2), "трасса · Гулистан")


class JunctionTurnsTests(AdminTest):
    """«Перекрёстки без запретов» (91): «нельзя» — правка в граф маршрутов,
    «можно» — манёвр проверен; в граф идёт путь узлов из карточки, а не из формы."""

    CARD = {"key": "j100", "rank": 1, "at": [41.3224, 69.1931], "streets": ["Бешкайрагач", "Малая кольцевая"],
            "signal": True, "divided": True, "arms": [0, 90, 180, 270], "route_lefts": 2,
            "moves": [{"key": "1,2,3", "kind": "left", "path": [1, 2, 3],
                       "pts": [[41.3220, 69.1931], [41.3224, 69.1931], [41.3224, 69.1925]],
                       "from_street": "Бешкайрагач", "to_street": "Малая кольцевая",
                       "from_bearing": 0, "to_bearing": 270, "routes": 2},
                      {"key": "1,2,4,5", "kind": "uturn", "path": [1, 2, 4, 5],
                       "pts": [[41.3220, 69.1931], [41.3224, 69.1931], [41.3224, 69.1932],
                               [41.3220, 69.1932]],
                       "from_street": "Бешкайрагач", "to_street": "Бешкайрагач",
                       "from_bearing": 0, "to_bearing": 180, "routes": 0}]}

    def setUp(self):
        super().setUp()
        self.saved = admin.JUNCTION_TURNS_PATH
        self.file = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        json.dump({"version": 1, "built": "2026-11-13", "cards": [self.CARD]}, self.file, ensure_ascii=False)
        self.file.close()
        admin.JUNCTION_TURNS_PATH = self.file.name
        conn = admin.db()
        try:
            map_edits.ensure_tables(conn)
            conn.execute("DELETE FROM map_edits")
            conn.execute("DELETE FROM route_checks")
            conn.commit()
        finally:
            conn.close()

    def tearDown(self):
        admin.JUNCTION_TURNS_PATH = self.saved
        os.unlink(self.file.name)

    def act(self, **fields):
        base = {"junction": "j100", "move": "1,2,3", "evidence": "yandex", "note": ""}
        base.update(fields)
        return _post(self.port, "/junctions/turns/act", base)

    def test_page_lists_moves_with_yandex_links(self):
        code, html = _get(self.port, "/junctions/turns")
        self.assertEqual(code, 200)
        self.assertIn("Бешкайрагач × Малая кольцевая", html)
        self.assertIn("наши маршруты здесь налево: 2", html)
        self.assertIn("panorama%5Bpoint%5D=69.1931%2C41.3224", html)
        self.assertIn("с юга по «Бешкайрагач» — <b>налево</b> на «Малая кольцевая»", html)
        self.assertIn("/junctions/turns", _get(self.port, "/junctions")[1])

    def test_without_cards_the_page_explains(self):
        admin.JUNCTION_TURNS_PATH = "/nonexistent/junction_turns.json"
        self.assertIn("Карточек нет", _get(self.port, "/junctions/turns")[1])

    def test_banned_creates_route_patch_with_card_path(self):
        self.assertEqual(self.act(answer="banned"), 303)
        items = admin.export_route_patches_readonly()["items"]
        self.assertEqual(len(items), 1)
        edit = items[0]
        self.assertEqual(edit["kind"], "turn_ban")
        self.assertEqual(edit["props"]["path"], [1, 2, 3])
        self.assertEqual(edit["props"]["restriction"], "no_left_turn")
        self.assertEqual(edit["props"]["evidence"], "yandex")
        self.assertEqual(edit["raw"], [69.1931, 41.3224])
        # В тайлы правка маршрута не идёт.
        self.assertEqual(admin.export_edits()["items"], [])
        self.assertIn("нельзя — запрет в графе", _get(self.port, "/junctions/turns?all=1")[1])

    def test_uturn_and_allowed(self):
        self.act(move="1,2,4,5", answer="banned")
        self.act(answer="allowed", evidence="survey")
        items = admin.export_route_patches_readonly()["items"]
        self.assertEqual([i["props"]["restriction"] for i in items], ["no_u_turn"])
        conn = admin.db()
        try:
            checks = map_edits.route_checks(conn)
        finally:
            conn.close()
        self.assertEqual(checks["1,2,3"]["answer"], "allowed")
        self.assertIsNone(checks["1,2,3"]["edit_id"])
        self.assertIn("Все манёвры проверены", _get(self.port, "/junctions/turns")[1])

    def test_undo_and_rebanning_withdraw_the_old_patch(self):
        self.act(answer="banned")
        self.act(answer="allowed")
        self.assertEqual(admin.export_route_patches_readonly()["items"], [])
        self.act(answer="banned")
        self.act(answer="undo")
        self.assertEqual(admin.export_route_patches_readonly()["items"], [])
        conn = admin.db()
        try:
            self.assertEqual(map_edits.route_checks(conn), {})
            # История не удаляется: снятые правки на месте.
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM map_edits WHERE status = 3").fetchone()[0], 2)
        finally:
            conn.close()

    def test_move_not_in_cards_is_ignored(self):
        self.act(move="9,9,9", answer="banned")
        self.act(junction="j999", answer="banned")
        self.act(answer="banned", evidence="телепатия")
        self.assertEqual(admin.export_route_patches_readonly()["items"], [])

    def test_editor_route_patch_validation(self):
        bad = {"kind": "turn_ban", "geom": [69.25, 41.3], "raw": [69.25, 41.3],
               "props": {"restriction": "no_left_turn"}}
        self.assertEqual(_post_json(self.port, "/api/edit", bad)[0], 400)
        good = dict(bad, props={"restriction": "no_left_turn", "from_bearing": 90, "to_bearing": 0,
                                "evidence": "survey"}, status=1)
        self.assertEqual(_post_json(self.port, "/api/edit", good)[0], 200)
        oneway = {"kind": "oneway", "geom": [69.25, 41.3], "raw": [69.25, 41.3], "props": {}, "status": 1}
        self.assertEqual(_post_json(self.port, "/api/edit", oneway)[0], 400)
        oneway["props"] = {"bearing": 45}
        self.assertEqual(_post_json(self.port, "/api/edit", oneway)[0], 200)
        kinds = sorted(i["kind"] for i in admin.export_route_patches_readonly()["items"])
        self.assertEqual(kinds, ["oneway", "turn_ban"])

    def test_export_is_read_only(self):
        missing = os.path.join(tempfile.mkdtemp(), "none.db")
        with self.assertRaises(sqlite3.OperationalError):
            admin.export_route_patches_readonly(missing)
        self.assertFalse(os.path.exists(missing))


class JunctionWorklistPageTests(unittest.TestCase):
    """Очередь перекрёстков: ссылки на правку и честный прогресс."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.saved = (admin.WORKLIST_PATH, admin.WORKLIST_FIRST_PATH)
        admin.WORKLIST_PATH = os.path.join(self.dir, "now.json")
        admin.WORKLIST_FIRST_PATH = os.path.join(self.dir, "first.json")

    def tearDown(self):
        admin.WORKLIST_PATH, admin.WORKLIST_FIRST_PATH = self.saved

    def row(self, lat, lon, names=("Беруни",)):
        return {"lat": lat, "lon": lon, "names": list(names), "missing": ["нет turn:lanes"], "score": 10}

    def test_without_a_worklist_the_page_says_so(self):
        self.assertIn("ещё не посчитана", admin.junctions_page())

    def test_rows_link_to_the_editor_and_osm(self):
        with open(admin.WORKLIST_PATH, "w", encoding="utf-8") as handle:
            json.dump([self.row(41.3249, 69.2307)], handle)
        html = admin.junctions_page()
        self.assertIn("#41.3249,69.2307,19", html)
        self.assertIn("editor=id#map=19/41.3249/69.2307", html)

    def test_progress_counts_junctions_that_left_the_queue(self):
        first = [self.row(41.3249, 69.2307), self.row(41.3000, 69.2500)]
        now = [self.row(41.30002, 69.25003)]           # тот же перекрёсток, сдвиг центра
        self.assertEqual(admin.worklist_progress(first, now), (1, 2))


class RetentionAdminTest(unittest.TestCase):
    """Сроки хранения (15.5) со стороны панели: очереди работают после прохода
    сроков, а журнал решений не хранит адресов и UUID.

    Сервер и базу берём у AdminTest, но не наследуем его: наследник прогнал
    бы ещё раз все его тесты."""
    setUpClass = AdminTest.__dict__["setUpClass"]
    tearDownClass = AdminTest.__dict__["tearDownClass"]
    login = AdminTest.__dict__["login"]
    setUp = AdminTest.setUp
    add_report = AdminTest.add_report
    queue = AdminTest.queue

    def sweep(self, now=None):
        conn = api.db()
        try:
            return api.enforce_retention(conn, now or time.time())
        finally:
            conn.close()

    def log_details(self):
        conn = sqlite3.connect(admin.DB_PATH)
        try:
            return [r[0] for r in conn.execute(
                "SELECT detail FROM moderation_log WHERE action = 'mobile_unblock' ORDER BY id")]
        finally:
            conn.close()

    def test_unblock_does_not_write_the_address_into_the_log(self):
        """Журнал решений бессрочный, бан — сутки: адрес в журнале пережил бы
        и бан, и потолок хранения."""
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute("INSERT INTO blocked(kind, value, until, note, created) "
                     "VALUES('ip', '10.7.7.7', ?, 'отметка 5', ?)",
                     (time.time() + 86400, time.time()))
        conn.commit()
        conn.close()
        self.assertEqual(_post(self.port, "/mobile/act",
                               {"action": "unblock", "block_kind": "ip",
                                "block_value": "10.7.7.7"}), 303)
        details = self.log_details()
        self.assertEqual(len(details), 1)
        self.assertNotIn("10.7.7.7", details[0])
        self.assertTrue(details[0].startswith("ip, отметка 5"), details[0])

    def test_old_unblock_records_are_scrubbed_at_start(self):
        conn = sqlite3.connect(admin.DB_PATH)
        for action, detail in (("mobile_unblock", "ip 10.7.7.7 · owner"),
                               ("mobile_unblock", "device 3F2A-UUID"),
                               ("mobile_unblock", "ip, отметка 5 · owner"),
                               ("mobile_unblock", "ip · owner"),
                               ("hide", "ip 10.7.7.7 в заметке модератора")):
            conn.execute("INSERT INTO moderation_log(at, action, detail) VALUES(?, ?, ?)",
                         (time.time(), action, detail))
        conn.commit()
        conn.close()
        admin.init_db()
        expected = ["ip · owner", "device", "ip, отметка 5 · owner", "ip · owner"]
        self.assertEqual(self.log_details(), expected)
        admin.init_db()
        self.assertEqual(self.log_details(), expected, "повторный старт ничего не меняет")
        conn = sqlite3.connect(admin.DB_PATH)
        other = conn.execute("SELECT detail FROM moderation_log WHERE action = 'hide'").fetchone()[0]
        conn.close()
        self.assertEqual(other, "ip 10.7.7.7 в заметке модератора", "чужие записи не трогаем")

    def test_camera_queue_after_the_sweep(self):
        """Старые жалобы без адреса остаются в очереди и в счёте «стоит не
        там», но в кворум на скрытие уже не идут — потеря только в безопасную
        сторону. Свежие работают как раньше."""
        old = api.LIVE_MAX_DAYS + 5
        for i in range(3):
            self.add_report(camera_id=7, ip=f"10.0.0.{i}", device=f"old{i}", days_ago=old)
        self.add_report(camera_id=8, reason="wrong_location", ip="10.0.1.1",
                        device="w", days_ago=old)
        for i in range(3):
            self.add_report(camera_id=9, ip=f"10.0.2.{i}", device=f"new{i}", days_ago=10)
        self.add_report(camera_id=10, ip="10.0.3.1", device="done", days_ago=old)
        conn = sqlite3.connect(admin.DB_PATH)
        conn.execute("UPDATE camera_reports SET resolved = 1 WHERE camera_id = 10")
        conn.commit()
        conn.close()
        before = {item["camera_id"]: item for item in self.queue()}
        self.assertTrue(before[7]["suggest_hide"])

        self.sweep()
        after = {item["camera_id"]: item for item in self.queue()}
        self.assertEqual(set(after), {7, 8, 9})
        self.assertEqual(after[7]["counts"]["gone"], 3, "старые жалобы остаются в очереди")
        self.assertEqual(after[7]["gone_ips"], set())
        self.assertFalse(after[7]["suggest_hide"], "жалоба без адреса не голосует за скрытие")
        self.assertTrue(after[9]["suggest_hide"], "свежие жалобы дозревают как раньше")
        conn = admin.db()
        try:
            self.assertEqual(admin.wrong_location_reports(conn), {8: 1},
                             "«Положение» видит старую жалобу «стоит не там»")
            left = conn.execute("SELECT COUNT(*) FROM camera_reports WHERE camera_id = 10").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(left, 0, "разобранная старая жалоба удалена")

    def test_feedback_page_after_the_sweep(self):
        conn = sqlite3.connect(admin.DB_PATH)
        for message, days in (("старое письмо", api.LIVE_MAX_DAYS + 1), ("свежее письмо", 3)):
            conn.execute("INSERT INTO feedback(message, contact, device, received) "
                         "VALUES(?, 'me@example.com', 'd', ?)", (message, time.time() - days * DAY))
        conn.commit()
        conn.close()
        self.sweep()
        code, body = _get(self.port, "/feedback")
        self.assertEqual(code, 200)
        self.assertIn("свежее письмо", body)
        self.assertNotIn("старое письмо", body)

    def test_every_table_with_device_columns_has_a_ceiling(self):
        """Вся схема общей базы — api.py, панель, конструктор карты: таблица с
        колонкой устройства без срока в RETENTION.md — красный тест."""
        from test_api import DEVICE_COLUMNS, retention_doc
        doc = retention_doc()
        conn = sqlite3.connect(admin.DB_PATH)
        try:
            tables = [r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")]
            self.assertIn("moderation_log", tables)
            for table in tables:
                self.assertIn(table, doc, f"{table}: нет строки в RETENTION.md")
                columns = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
                if columns & DEVICE_COLUMNS:
                    self.assertIsInstance(doc[table], int, f"{table}: поля устройства без срока")
                    self.assertLessEqual(doc[table], api.LIVE_MAX_DAYS)
        finally:
            conn.close()
