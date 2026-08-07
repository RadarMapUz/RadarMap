#!/usr/bin/env python3
"""Тесты панели модератора: поднимаем настоящий сервер на случайном порту с
временной БД и ходим в него HTTP-клиентом stdlib.

Проверяем прежде всего то, что панель НЕ должна делать: предлагать скрытие по
слабому сигналу, верить накрутке с одного адреса, принимать POST со стороны.
Запуск: python3 server/test_admin.py
"""
import json
import os
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
        for table in ("camera_reports", "feedback", "reports", "votes",
                      "metrics", "overrides", "moderation_log", "usage_stats"):
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

if __name__ == "__main__":
    unittest.main(verbosity=2)
