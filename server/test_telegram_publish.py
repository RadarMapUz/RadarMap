#!/usr/bin/env python3
"""Тесты публикации в Telegram: выборка (только подтверждённые независимо),
группировка по городу, формат строки, защита от утечки (ни device, ни ip, ни
секунд), идемпотентность (второй прогон не шлёт), адрес из нашей клетки,
отсутствие конфига. Без сети: отправитель подменён.
Запуск: python3 server/test_telegram_publish.py
"""
import json
import os
import re
import sqlite3
import tempfile
import time
import unittest
import io

import api
import telegram_publish as tg

#: 2026-10-12 09:37:48 UTC = 14:37:48 по Ташкенту → в канале «14:35».
NOW = 1791797868.0
DEVICE = "0f3c7b2e-aaaa-bbbb-cccc-1234567890ab"
IP = "203.0.113.77"
CONFIG = {"token": "123:abc", "chat_id": "@radarmap_uz"}


class Stand(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.reports = os.path.join(self.dir, "reports.db")
        self.journal = os.path.join(self.dir, "telegram.db")
        saved = api.DB_PATH
        api.DB_PATH = self.reports
        try:
            api.init_db()
        finally:
            api.DB_PATH = saved
        self.sent = []

    def sender(self, token, chat_id, text):
        self.sent.append((chat_id, text))
        return 100 + len(self.sent)

    def add(self, lat, lon, kind="tripod", created=NOW - 600, active=1,
            device=DEVICE, ip=IP, expires=None):
        conn = sqlite3.connect(self.reports)
        cur = conn.execute(
            "INSERT INTO reports(lat, lon, created, expires, device, ip, type, active) "
            "VALUES(?,?,?,?,?,?,?,?)",
            (lat, lon, created, expires or created + 6 * 3600, device, ip, kind, active))
        conn.commit()
        rid = cur.lastrowid
        conn.close()
        return rid

    def vote(self, rid, device="other-device", ip="198.51.100.5", value=1):
        conn = sqlite3.connect(self.reports)
        conn.execute("INSERT OR REPLACE INTO votes(report_id, device, value, ts, ip, kind) "
                     "VALUES(?,?,?,?,?,'')", (rid, device, value, NOW - 300, ip))
        conn.commit()
        conn.close()

    def run_once(self, **kw):
        return tg.run(self.reports, self.journal, CONFIG, now=NOW, sender=self.sender, **kw)


class SelectionTests(Stand):
    def test_only_independently_confirmed_live_reports_of_our_kinds(self):
        confirmed = self.add(41.3111, 69.2797)
        self.vote(confirmed)
        self_voted = self.add(41.32, 69.28)
        self.vote(self_voted, device="d2", ip=IP)              # тот же адрес — не считается
        same_device = self.add(41.33, 69.28)
        self.vote(same_device, device=DEVICE, ip="198.51.100.9")   # то же устройство
        no_ip = self.add(41.34, 69.28)
        self.vote(no_ip, ip="")                                 # старый голос без ip
        self.add(41.35, 69.28, kind="accident"); self.vote(4 + 1)
        old = self.add(41.36, 69.28, created=NOW - 4 * 3600); self.vote(old)
        dead = self.add(41.37, 69.28, active=0); self.vote(dead)
        downvoted = self.add(41.38, 69.28); self.vote(downvoted, value=-1)

        conn = sqlite3.connect(self.reports)
        rows = tg.select_confirmed(conn, now=NOW)
        conn.close()
        self.assertEqual([r["id"] for r in rows], [confirmed])
        self.assertEqual(rows[0]["confirmations"], 1)
        self.assertNotIn("device", rows[0])
        self.assertNotIn("ip", rows[0])

    def test_confirmations_count_distinct_addresses(self):
        rid = self.add(41.3111, 69.2797)
        self.vote(rid, device="a", ip="198.51.100.1")
        self.vote(rid, device="b", ip="198.51.100.1")   # тот же адрес — один человек
        self.vote(rid, device="c", ip="198.51.100.2")
        conn = sqlite3.connect(self.reports)
        rows = tg.select_confirmed(conn, now=NOW)
        conn.close()
        self.assertEqual(rows[0]["confirmations"], 2)


class TextTests(unittest.TestCase):
    def report(self, lat, lon, kind="tripod", count=2, created=NOW):
        return {"id": 1, "lat": lat, "lon": lon, "type": kind, "created": created,
                "confirmations": count}

    def test_line_format_with_coordinates_and_rounded_time(self):
        line = tg.line_for(self.report(41.311081, 69.279737))
        self.assertEqual(
            line.split("\n")[0],
            "📍 Ташкент · тренога · 41.3111, 69.2797 · подтверждена 2 водителями · 14:35")
        self.assertIn("openstreetmap.org/?mlat=41.3111&mlon=69.2797", line)
        self.assertNotIn("41.311081", line, "шесть знаков — это уже след, а не место")

    def test_address_replaces_coordinates_and_one_driver_declines(self):
        line = tg.line_for(self.report(41.3111, 69.2797, kind="post", count=1),
                           address="Амира Темура, 12")
        self.assertTrue(line.startswith(
            "📍 Ташкент · пост ДПС · Амира Темура, 12 · подтверждена 1 водителем · 14:35"))

    def test_time_is_rounded_down_to_five_minutes(self):
        self.assertEqual(tg.local_time(NOW), "14:35")               # 14:37:48
        self.assertEqual(tg.local_time(NOW - 180), "14:30")         # 14:34:48
        self.assertEqual(tg.local_time(NOW + 133), "14:40")         # 14:40:01

    def test_nearest_city_and_the_highway_label(self):
        self.assertEqual(tg.city_label(39.6542, 66.9597), "Самарканд")
        self.assertEqual(tg.city_label(37.2242, 67.2783), "Термез")
        self.assertEqual(tg.city_label(42.4531, 59.6103), "Нукус")
        # Между Джизаком и Гулистаном, в 40 км от Джизака — трасса.
        label = tg.city_label(40.33, 68.17)
        self.assertRegex(label, r"^(Джизак|Гулистан), \d+ км$")

    def test_grouping_is_one_message_per_city_ordered_by_time(self):
        reports = [
            {"id": 3, "lat": 39.6542, "lon": 66.9597, "type": "radar", "created": NOW - 100, "confirmations": 1},
            {"id": 1, "lat": 41.3111, "lon": 69.2797, "type": "tripod", "created": NOW - 900, "confirmations": 2},
            {"id": 2, "lat": 41.3300, "lon": 69.2500, "type": "post", "created": NOW - 500, "confirmations": 1},
        ]
        out = tg.messages(reports)
        self.assertEqual([ids for _, ids in out], [[1, 2], [3]])
        self.assertEqual(out[0][0].count("📍 Ташкент"), 2)
        self.assertIn("📍 Самарканд · радар", out[1][0])

    def test_long_city_list_is_split(self):
        reports = [{"id": i, "lat": 41.31 + i * 0.001, "lon": 69.28, "type": "tripod",
                    "created": NOW - i, "confirmations": 1} for i in range(1, 21)]
        out = tg.messages(reports, per_message=15)
        self.assertEqual([len(ids) for _, ids in out], [15, 5])


class AddressTests(unittest.TestCase):
    def test_street_and_house_from_our_address_cell(self):
        roads = tempfile.mkdtemp()
        lat, lon = 41.3111, 69.2797
        ilat, ilon = round(lat * 1e5), round(lon * 1e5)
        cell = {"version": 1, "streets": [
            {"n": "Амира Темура", "h": ["12", "14"], "p": [ilat, ilon, 30, 40]},
            {"n": "Далёкая", "h": ["1"], "p": [ilat + 5000, ilon]}]}
        with open(os.path.join(roads, f"road2_{tg.address_key(lat, lon)}_a.json"), "w",
                  encoding="utf-8") as handle:
            json.dump(cell, handle, ensure_ascii=False)
        self.assertEqual(tg.nearest_address(roads, lat, lon), "Амира Темура, 12")
        self.assertEqual(tg.nearest_address(roads, lat + 0.0003, lon + 0.0004), "Амира Темура, 14")
        self.assertIsNone(tg.nearest_address(roads, lat + 0.01, lon), "километр — не адрес")
        self.assertIsNone(tg.nearest_address(roads, 39.65, 66.96), "клетки нет — молча None")
        self.assertIsNone(tg.nearest_address(None, lat, lon))


class RunTests(Stand):
    def test_nothing_private_reaches_the_channel(self):
        rid = self.add(41.311081, 69.279737, created=NOW - 600)
        self.vote(rid)
        self.assertEqual(self.run_once(), 1)
        chat, text = self.sent[0]
        self.assertEqual(chat, CONFIG["chat_id"])
        for forbidden in (DEVICE, DEVICE[:8], IP, "198.51.100", "device", "ip=",
                          "41.311081", "69.279737", ":48", str(int(NOW - 600))):
            self.assertNotIn(forbidden, text, forbidden)
        self.assertRegex(text, r"· \d\d:[0-5][05]$|· \d\d:[0-5][05]\n")

    def test_second_run_sends_nothing(self):
        rid = self.add(41.3111, 69.2797)
        self.vote(rid)
        self.assertEqual(self.run_once(), 1)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(len(self.sent), 1)
        journal = sqlite3.connect(self.journal)
        rows = journal.execute("SELECT report_id, message_id, chat_id FROM telegram_posted").fetchall()
        journal.close()
        self.assertEqual(rows, [(rid, 101, CONFIG["chat_id"])])

    def test_new_confirmation_later_is_sent_once_without_the_old(self):
        first = self.add(41.3111, 69.2797)
        self.vote(first)
        self.run_once()
        second = self.add(39.6542, 66.9597, kind="radar")
        self.vote(second)
        self.assertEqual(self.run_once(), 1)
        self.assertIn("Самарканд", self.sent[1][1])
        self.assertNotIn("Ташкент", self.sent[1][1])

    def test_failed_send_is_not_marked_and_is_retried(self):
        rid = self.add(41.3111, 69.2797)
        self.vote(rid)

        def broken(token, chat_id, text):
            raise OSError("timeout")
        self.assertEqual(tg.run(self.reports, self.journal, CONFIG, now=NOW, sender=broken), 0)
        self.assertEqual(self.run_once(), 1)

    def test_dry_run_prints_and_marks_nothing(self):
        rid = self.add(41.3111, 69.2797)
        self.vote(rid)
        out = io.StringIO()
        self.assertEqual(self.run_once(dry_run=True, out=out), 0)
        self.assertIn("📍 Ташкент · тренога", out.getvalue())
        self.assertEqual(self.sent, [])
        self.assertEqual(self.run_once(), 1, "после сухого прогона настоящий всё ещё шлёт")

    def test_unconfirmed_report_waits_for_its_confirmation(self):
        rid = self.add(41.3111, 69.2797)
        self.assertEqual(self.run_once(), 0)
        self.vote(rid)
        self.assertEqual(self.run_once(), 1)


class ConfigTests(unittest.TestCase):
    def test_missing_or_incomplete_config_is_none(self):
        self.assertIsNone(tg.read_config("/nonexistent/telegram.conf"))
        path = os.path.join(tempfile.mkdtemp(), "telegram.conf")
        with open(path, "w") as handle:
            handle.write("# канал\ntoken=123:abc\n")
        self.assertIsNone(tg.read_config(path))
        with open(path, "a") as handle:
            handle.write("chat_id = @radarmap_uz\n")
        self.assertEqual(tg.read_config(path), {"token": "123:abc", "chat_id": "@radarmap_uz"})

    def test_main_without_config_exits_zero_with_a_message(self):
        import sys
        saved = sys.argv
        sys.argv = ["telegram_publish.py", "--config", "/nonexistent/telegram.conf"]
        out = io.StringIO()
        saved_out, sys.stdout = sys.stdout, out
        try:
            code = tg.main()
        finally:
            sys.stdout = saved_out
            sys.argv = saved
        self.assertEqual(code, 0)
        self.assertIn("не настроен", out.getvalue())


if __name__ == "__main__":
    unittest.main()
