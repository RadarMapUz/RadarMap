#!/usr/bin/env python3
"""Тесты панели модератора: поднимаем настоящий сервер на случайном порту с
временной БД и ходим в него HTTP-клиентом stdlib.

Проверяем прежде всего то, что панель НЕ должна делать: предлагать скрытие по
слабому сигналу, верить накрутке с одного адреса, принимать POST со стороны.
Запуск: python3 server/test_admin.py
"""
import json
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
import api

DAY = 86400


def _get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as resp:
        return resp.status, resp.read().decode()


def _post(port, path, fields, origin=None):
    data = urllib.parse.urlencode(fields).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
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

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), admin.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
