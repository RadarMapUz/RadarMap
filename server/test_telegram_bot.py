#!/usr/bin/env python3
"""Тесты Telegram-бота отметок (12б.7): соль и ротация хэша, лимиты, поток
«геопозиция → тип → API», испытательный срок через настоящий API (свой
повтор не подтверждает, другой человек — подтверждает), и главное —
Telegram-id нет ни в базе бота, ни в базе отметок. Без сети.

Запуск: python3 server/test_telegram_bot.py
"""
import json
import os
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import api
import telegram_bot as bot

USER = 987654321
OTHER = 123456789
SALT = "test-salt-0123456789abcdef"
NOW = 1_800_000_000.0


class HashTest(unittest.TestCase):
    def test_device_rotates_and_hides_the_id(self):
        device = bot.device_for(SALT, USER, NOW)
        self.assertEqual(device, bot.device_for(SALT, USER, NOW + 3600), "то же окно — то же устройство")
        self.assertNotEqual(device, bot.device_for(SALT, USER, NOW + bot.ROTATION_SECONDS),
                            "через 30 дней — другое")
        self.assertNotEqual(device, bot.device_for("other-salt", USER, NOW), "без соли сервера не подобрать")
        self.assertNotIn(str(USER), device)
        self.assertNotEqual(bot.pseudo_ip_for(SALT, USER, NOW), bot.pseudo_ip_for(SALT, OTHER, NOW))


class LimitsTest(unittest.TestCase):
    def setUp(self):
        self.db = bot.open_db(":memory:")

    def test_interval_and_daily_cap(self):
        who = bot.user_hash(SALT, USER, NOW)
        self.assertIsNone(bot.check_and_count(self.db, who, NOW))
        self.assertEqual(bot.check_and_count(self.db, who, NOW + 10), "slow")
        for step in range(1, bot.BOT_DAILY_REPORTS):
            self.assertIsNone(bot.check_and_count(self.db, who, NOW + step * 61))
        self.assertEqual(bot.check_and_count(self.db, who, NOW + (bot.BOT_DAILY_REPORTS + 1) * 61), "limit")


class FlowTest(unittest.TestCase):
    """Логика бота с подменённой сетью."""

    def setUp(self):
        self.sent = []
        self.posted = []
        self.answer = (200, {"id": 1, "merged": False})
        self.db = bot.open_db(":memory:")
        self.clock = [NOW]
        self.bot = bot.Bot(SALT, self.db, send=lambda m, p: self.sent.append((m, p)),
                           api_post=lambda path, body, ip: (self.posted.append((path, body, ip)), self.answer)[1],
                           now=lambda: self.clock[0])

    def location(self, user=USER):
        self.bot.handle({"message": {"chat": {"id": 1}, "from": {"id": user},
                                     "location": {"latitude": 41.31, "longitude": 69.28}}})

    def tap(self, data, user=USER):
        self.bot.handle({"callback_query": {"id": "q", "data": data, "from": {"id": user},
                                            "message": {"chat": {"id": 1}}}})

    def test_location_then_type_goes_to_api(self):
        self.location()
        self.assertIn("reply_markup", self.sent[-1][1], "после геопозиции — кнопки типов")
        self.tap("tripod")
        path, body, ip = self.posted[-1]
        self.assertEqual(path, "/api/report")
        self.assertEqual(body["type"], "tripod")
        self.assertEqual(body["device"], bot.device_for(SALT, USER, NOW))
        self.assertTrue(ip.startswith("tg-"))
        self.assertNotIn(str(USER), json.dumps(body) + ip, "id не уходит в API")
        self.assertEqual(self.sent[-1][1]["text"], bot.TEXTS["created"])

    def test_cng_goes_to_cng_endpoint(self):
        self.location()
        self.tap("cng")
        self.assertEqual(self.sent[-1][1]["text"], bot.TEXTS["pick_cng"])
        self.tap("nogas")
        self.assertEqual(self.posted[-1][0], "/api/cng")
        self.assertEqual(self.posted[-1][1]["kind"], "nogas")

    def test_type_without_fresh_point_is_refused(self):
        self.tap("radar")
        self.assertEqual(self.posted, [])
        self.assertEqual(self.sent[-1][1]["text"], bot.TEXTS["expired"])
        self.location()
        self.clock[0] += bot.PENDING_TTL + 1
        self.tap("radar")
        self.assertEqual(self.posted, [], "точка старше 10 минут забыта")

    def test_no_raw_id_in_memory_after_handling(self):
        self.location()
        self.assertNotIn(USER, self.bot.pending)
        self.assertNotIn(str(USER), json.dumps(list(self.bot.pending.keys())))


class ApiIntegrationTest(unittest.TestCase):
    """Через настоящий API: свой повтор не подтверждает отметку, другой
    пользователь бота — подтверждает; в базе отметок нет Telegram-id."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        api.DB_PATH = os.path.join(cls.dir, "reports.db")
        api.init_db()
        api.TRAFFIC_DB_PATH = os.path.join(cls.dir, "traffic.db")
        api.init_traffic_db()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        conn = sqlite3.connect(api.DB_PATH)
        for table in ("reports", "votes", "cng"):
            conn.execute(f"DELETE FROM {table}")
        conn.commit()
        conn.close()
        with api._ip_lock:
            api._ip_counters.clear()

    def post(self, path, body, ip):
        request = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json", "X-Real-IP": ip})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            return error.code, {}

    def make(self, salt_db=":memory:"):
        return bot.Bot(SALT, bot.open_db(salt_db), send=lambda m, p: None, api_post=self.post)

    def test_own_repeat_does_not_confirm_other_user_does(self):
        api._probation_cache = (time.time(), True)
        try:
            first = self.make()
            for user in (USER, USER):
                first.handle({"message": {"chat": {"id": 1}, "from": {"id": user},
                                          "location": {"latitude": 41.33, "longitude": 69.29}}})
                first.handle({"callback_query": {"id": "q", "data": "radar", "from": {"id": user},
                                                 "message": {"chat": {"id": 1}}}})
                first.db.execute("DELETE FROM bot_limits")   # мимо своего лимита частоты
            conn = sqlite3.connect(api.DB_PATH)
            rid = conn.execute("SELECT id FROM reports WHERE type = 'radar'").fetchone()[0]
            self.assertFalse(api.confirmed_independently(conn, rid, bot.device_for(SALT, USER, time.time()),
                                                         bot.pseudo_ip_for(SALT, USER, time.time())),
                             "свой повтор — не подтверждение")
            other = self.make()
            other.handle({"message": {"chat": {"id": 2}, "from": {"id": OTHER},
                                      "location": {"latitude": 41.33, "longitude": 69.29}}})
            other.handle({"callback_query": {"id": "q", "data": "radar", "from": {"id": OTHER},
                                             "message": {"chat": {"id": 2}}}})
            self.assertTrue(api.confirmed_independently(conn, rid, bot.device_for(SALT, USER, time.time()),
                                                        bot.pseudo_ip_for(SALT, USER, time.time())),
                            "другой человек — независимое подтверждение")
            dump = "\n".join(conn.iterdump())
            conn.close()
            self.assertNotIn(str(USER), dump, "в базе отметок нет Telegram-id")
            self.assertNotIn(str(OTHER), dump)
        finally:
            api._probation_cache = (0.0, None)

    def test_bot_db_holds_no_id(self):
        path = os.path.join(self.dir, "bot.db")
        b = self.make(path)
        b.handle({"message": {"chat": {"id": 1}, "from": {"id": USER},
                              "location": {"latitude": 41.35, "longitude": 69.30}}})
        b.handle({"callback_query": {"id": "q", "data": "post", "from": {"id": USER},
                                     "message": {"chat": {"id": 1}}}})
        b.db.close()
        with open(path, "rb") as handle:
            self.assertNotIn(str(USER).encode(), handle.read())


class UnitFileTest(unittest.TestCase):
    """Бот разбирает чужой ввод из интернета и держит токен — работает от
    root, как api и панель, значит и песочница у него та же
    (systemd-radarmap-sandbox.conf): ошибка в разборе не должна давать запись
    по всему общему VPS."""

    def test_bot_unit_is_sandboxed_like_the_api(self):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "radarmap-bot.service")
        with open(path, encoding="utf-8") as handle:
            lines = {line.strip() for line in handle}
        for directive in ("NoNewPrivileges=yes", "ProtectSystem=strict", "ProtectHome=yes",
                          "PrivateTmp=yes", "PrivateDevices=yes",
                          "ReadWritePaths=/opt/radarmap/api",
                          "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"):
            self.assertIn(directive, lines, f"в юните бота нет {directive}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
