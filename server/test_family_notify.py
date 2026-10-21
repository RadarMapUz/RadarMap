#!/usr/bin/env python3
"""Тесты близких в Telegram (22.3): когда писать (первое «в пути», порог и
промежуток «задерживается», «дома» один раз, тишина на конце не дома и
продолжение после остановки), тексты ru/uz, подписка и /stop (адрес, капы,
языки), очередь и доставка с подменённым Telegram (повтор, 429, закрытый
чат, устаревшее), сроки хранения, хук в настоящем api.py — и главное, чего
быть не должно: номера чата в подписках, имени на диске после доставки и
того и другого в журнале. Без сети.

Запуск: python3 -m unittest test_family_notify
"""
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import string
import struct
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import api
import family_notify as fam
import telegram_bot

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = 1_800_001_200.0           # 15.01.2027 13:20 по Ташкенту
SALT = "test-salt-0123456789abcdef"
CHAT = 735_012_448
OTHER_CHAT = 912_334_005
NAME = "Зафар"
KEY = "d3JpdGUta2V5LWZvci1mYW1pbHktdGVzdHM"        # ключ записи телефона (22+ знаков)
ADDRESS = api.eta_address(KEY)


def fast_kdf(password, salt):
    """Подмена scrypt той же формы: логику вокруг хэша проверяем быстро;
    настоящий scrypt бота — в BotRoutingTest."""
    return hashlib.sha256(salt + b"|" + password).digest()


def address_of(n):
    return api.eta_address(f"family-key-{n:04d}-padding-xx")


@contextlib.contextmanager
def captured_log():
    lines = []
    saved = fam.log
    fam.log = lines.append
    try:
        yield lines
    finally:
        fam.log = saved


def item(status="driving", eta=None, name=NAME, keyed=True, **extra):
    out = {"status": status, "eta": eta, "left_m": 12000, "updated": NOW, "keyed": keyed}
    if name is not None:
        out["name"] = name
    out.update(extra)
    return out


class TempDb(unittest.TestCase):
    """Своя family.db на каждый тест; DB_PATH модуля — на неё."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "family.db")
        self.saved_path = fam.DB_PATH
        fam.DB_PATH = self.path
        fam.init_db(self.path)
        self.conn = fam.connect(self.path)
        self.commands = fam.FamilyCommands(fam.connect(self.path), SALT, fast_kdf)

    def tearDown(self):
        self.conn.close()
        self.commands.conn.close()
        fam.DB_PATH = self.saved_path
        shutil.rmtree(self.dir, ignore_errors=True)

    def subscribe(self, chat=CHAT, address=ADDRESS, lang="ru", now=NOW):
        return self.commands.command(f"/start f_{address}", chat, lang, now)

    def rows(self, sql, args=()):
        return self.conn.execute(sql, args).fetchall()

    def outbox(self):
        return self.rows("SELECT chat_id, text FROM family_outbox ORDER BY id")


class AddressTest(unittest.TestCase):
    def test_family_address_of_a_write_key_is_accepted(self):
        self.assertEqual(len(ADDRESS), fam.ADDRESS_LENGTH)
        self.assertTrue(fam.valid_address(ADDRESS))

    def test_anything_else_is_refused(self):
        legacy = "Q2xhdWRlU2hhcmVkRVRBdGVzdA"           # 26 знаков старых сборок
        for bad in (legacy, ADDRESS[:-1], ADDRESS + "A", "!" + ADDRESS[1:], ADDRESS.replace(ADDRESS[5], "="),
                    None, 42, ""):
            self.assertFalse(fam.valid_address(bad), bad)

    def test_non_canonical_tail_is_refused(self):
        """Последний знак несёт 4 бита и два нулевых: тот же sha256, записанный
        другим хвостом, — не адрес, а подделка формы."""
        alphabet = string.ascii_uppercase + string.ascii_lowercase + string.digits + "-_"
        index = alphabet.index(ADDRESS[-1])
        self.assertEqual(index % 4, 0)
        self.assertFalse(fam.valid_address(ADDRESS[:-1] + alphabet[index + 1]))

    def test_deep_link_fits_telegram_start_parameter(self):
        link = fam.deep_link("@RadarMapBot", ADDRESS)
        self.assertEqual(link, f"https://t.me/RadarMapBot?start=f_{ADDRESS}")
        start = link.split("start=", 1)[1]
        self.assertLessEqual(len(start), 64, "Telegram режет start длиннее 64")
        self.assertRegex(start, r"^[A-Za-z0-9_-]+$")
        self.assertIsNone(fam.deep_link("no", ADDRESS), "короткое имя бота — не имя")
        self.assertIsNone(fam.deep_link("RadarMapBot", "short"))

    def test_username_is_read_alone_from_the_bot_config(self):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False, encoding="utf-8") as handle:
            handle.write("token=123:SECRET\nsalt=abc\n# username=Wrong_bot\nusername = @RadarMapBot\n")
        try:
            self.assertEqual(fam.read_username(handle.name), "RadarMapBot")
        finally:
            os.unlink(handle.name)
        self.assertIsNone(fam.read_username(os.path.join(tempfile.gettempdir(), "нет-такого.conf")))


class SealTest(unittest.TestCase):
    def test_chat_id_opens_only_with_its_address(self):
        box = fam.seal(ADDRESS, CHAT)
        self.assertEqual(fam.unseal(ADDRESS, box), CHAT)
        self.assertIsNone(fam.unseal(address_of(1), box), "другой адрес — не открыть")
        self.assertNotIn(str(CHAT), box)
        self.assertNotIn(struct.pack(">q", CHAT).hex(), box)
        self.assertNotEqual(fam.seal(ADDRESS, CHAT), box, "свой nonce у каждой подписки")
        for chat in (-1001234567890, 1, 2 ** 52):
            self.assertEqual(fam.unseal(ADDRESS, fam.seal(ADDRESS, chat)), chat)

    def test_damaged_box_is_none_not_a_stranger(self):
        box = fam.seal(ADDRESS, CHAT)
        for broken in (box[:-2] + ("00" if box[-2:] != "00" else "11"),
                       box[:40] + ("0" if box[40] != "0" else "1") + box[41:], box[:20], "zz", None):
            self.assertIsNone(fam.unseal(ADDRESS, broken), broken)


class DecideTest(unittest.TestCase):
    ETA = NOW + 25 * 60

    def drive(self, trip, eta, at):
        return fam.decide(trip, "driving", eta, at)

    def test_first_driving_departs_with_or_without_time(self):
        trip, notice = self.drive(None, self.ETA, NOW)
        self.assertEqual(notice, ("departed", self.ETA))
        self.assertEqual((trip.phase, trip.eta, trip.noticed), ("driving", self.ETA, NOW))
        self.assertEqual(self.drive(None, None, NOW)[1], ("departed", None))

    def test_next_updates_are_silent(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        for step in range(1, 20):
            trip, notice = self.drive(trip, self.ETA + 60 * (step % 4), NOW + 30 * step)
            self.assertIsNone(notice, f"шаг {step}: сдвиг меньше 5 минут — молчим")

    def test_delay_needs_five_minutes_and_ten_since_the_last_notice(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        _, notice = self.drive(trip, self.ETA + fam.DELAY_STEP, NOW + fam.NOTICE_GAP - 1)
        self.assertIsNone(notice, "сдвиг есть, но десяти минут не прошло")
        _, notice = self.drive(trip, self.ETA + fam.DELAY_STEP - 1, NOW + fam.NOTICE_GAP)
        self.assertIsNone(notice, "десять минут прошли, но сдвиг меньше пяти")
        trip, notice = self.drive(trip, self.ETA + fam.DELAY_STEP, NOW + fam.NOTICE_GAP)
        self.assertEqual(notice, ("delayed", self.ETA + fam.DELAY_STEP))
        # Дальше порог — от НОВОГО объявленного времени, промежуток — от этого сообщения.
        later = NOW + 2 * fam.NOTICE_GAP
        _, notice = self.drive(trip, self.ETA + fam.DELAY_STEP + 4 * 60, later)
        self.assertIsNone(notice)
        _, notice = self.drive(trip, self.ETA + 2 * fam.DELAY_STEP, later - 60)
        self.assertIsNone(notice, "с прошлого «задерживается» меньше десяти минут")
        _, notice = self.drive(trip, self.ETA + 2 * fam.DELAY_STEP, later)
        self.assertEqual(notice[0], "delayed")

    def test_earlier_arrival_is_not_announced_and_does_not_move_the_bar(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        trip, notice = self.drive(trip, self.ETA - 15 * 60, NOW + 20 * 60)
        self.assertIsNone(notice)
        self.assertEqual(trip.eta, self.ETA, "сравниваем с объявленным, а не с последним")
        _, notice = self.drive(trip, self.ETA + 3 * 60, NOW + 30 * 60)
        self.assertIsNone(notice, "позже объявленного всего на 3 минуты")

    def test_time_that_appears_mid_trip_is_said_once_and_at_once(self):
        trip, _ = self.drive(None, None, NOW)
        trip, notice = self.drive(trip, self.ETA, NOW + 60)
        self.assertEqual(notice, ("eta", self.ETA), "без десятиминутного промежутка")
        trip, notice = self.drive(trip, None, NOW + 120)
        self.assertIsNone(notice)
        self.assertEqual(trip.eta, self.ETA, "маршрут пропал — объявленное время помним")
        self.assertIsNone(self.drive(trip, self.ETA, NOW + 180)[1])

    def test_arrival_is_said_once(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        trip, notice = fam.decide(trip, "arrived", None, NOW + 20 * 60)
        self.assertEqual(notice, ("arrived", NOW + 20 * 60))
        trip, notice = fam.decide(trip, "arrived", None, NOW + 21 * 60)
        self.assertIsNone(notice, "повтор «на месте» молчит")
        self.assertIsNone(fam.decide(trip, "ended", None, NOW + 22 * 60)[1])
        # Уехал снова — это новая поездка.
        self.assertEqual(self.drive(trip, self.ETA + 3600, NOW + 25 * 60)[1][0], "departed")

    def test_arrival_without_a_known_trip_is_still_said(self):
        self.assertEqual(fam.decide(None, "arrived", None, NOW), (fam.Trip("arrived", None, NOW, NOW),
                                                                  ("arrived", NOW)))

    def test_ended_not_at_home_is_silent(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        trip, notice = fam.decide(trip, "ended", None, NOW + 5 * 60)
        self.assertIsNone(notice)
        self.assertEqual(trip.phase, "paused")
        self.assertEqual(fam.decide(None, "ended", None, NOW), (None, None), "конец без поездки — ничего")

    def test_shop_stop_on_the_way_is_the_same_trip(self):
        """Остановка у магазина: «задерживается», а не второе «едет домой»."""
        trip, _ = self.drive(None, self.ETA, NOW)
        trip, _ = fam.decide(trip, "ended", None, NOW + 12 * 60)
        trip, notice = self.drive(trip, self.ETA + 20 * 60, NOW + 12 * 60 + fam.RESUME_WINDOW)
        self.assertEqual(notice, ("delayed", self.ETA + 20 * 60))
        trip, _ = fam.decide(trip, "ended", None, NOW + 3600)
        _, notice = self.drive(trip, self.ETA + 3 * 3600, NOW + 3600 + fam.RESUME_WINDOW + 1)
        self.assertEqual(notice[0], "departed", "после получаса остановки — новая поездка")

    def test_silence_forgets_the_trip(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        _, notice = self.drive(trip, self.ETA, NOW + fam.TRIP_TTL)
        self.assertIsNone(notice, "ровно два часа — ещё та же поездка")
        _, notice = self.drive(trip, self.ETA + 3 * 3600, NOW + fam.TRIP_TTL + 1)
        self.assertEqual(notice[0], "departed")

    def test_unknown_status_changes_nothing(self):
        trip, _ = self.drive(None, self.ETA, NOW)
        self.assertEqual(fam.decide(trip, "flying", None, NOW + 60), (trip, None))


class RenderTest(unittest.TestCase):
    ETA = NOW + 25 * 60       # 13:45 по Ташкенту

    def test_times_are_tashkent_and_match_the_page(self):
        self.assertEqual(fam.clock(NOW), "13:20")
        self.assertEqual(fam.clock(NOW + 59), "13:20", "секунды отбрасываются, как на странице")
        page = api.eta_page({"eta": self.ETA, "left_m": 1000, "status": "driving", "updated": NOW,
                             "keyed": True}, NOW)
        self.assertIn(fam.clock(self.ETA), page, "сообщение и страница называют одно время")

    def test_russian_texts(self):
        cases = {
            ("departed", self.ETA): "🚗 Зафар едет домой — будет примерно в 13:45",
            ("departed", None): "🚗 Зафар едет домой",
            ("eta", self.ETA): "🕒 Зафар будет дома примерно в 13:45",
            ("delayed", self.ETA): "⏱ Зафар задерживается — теперь около 13:45",
            ("arrived", NOW): "🏠 Зафар дома, 13:20",
        }
        for notice, text in cases.items():
            self.assertEqual(fam.render(notice, "ru", NAME), text)

    def test_uzbek_texts(self):
        cases = {
            ("departed", self.ETA): "🚗 Zafar uyga ketyapti — taxminan 13:45 da yetib keladi",
            ("departed", None): "🚗 Zafar uyga ketyapti",
            ("eta", self.ETA): "🕒 Zafar taxminan 13:45 da uyda boʻladi",
            ("delayed", self.ETA): "⏱ Zafar kechikyapti — endi taxminan 13:45 da",
            ("arrived", NOW): "🏠 Zafar uyda, 13:20",
        }
        for notice, text in cases.items():
            self.assertEqual(fam.render(notice, "uz", "Zafar"), text)

    def test_default_name_by_language(self):
        self.assertEqual(fam.render(("arrived", NOW), "ru"), "🏠 Водитель дома, 13:20")
        self.assertEqual(fam.render(("arrived", NOW), "uz"), "🏠 Haydovchi uyda, 13:20")

    def test_texts_have_no_gender(self):
        """Имя задаёт водитель: «Мама выехал» не должно случиться никогда."""
        for lang in fam.NOTICES:
            for text in fam.NOTICES[lang].values():
                for word in ("выехал", "приехал", "доехал", "уехал", "(а)"):
                    self.assertNotIn(word, text)

    def test_trip_not_home_says_no_home(self):
        self.assertEqual(fam.render(("departed", self.ETA), "ru", NAME, home=False),
                         "🚗 Зафар в пути — будет на месте примерно в 13:45")
        self.assertEqual(fam.render(("arrived", NOW), "ru", NAME, home=False), "📍 Зафар на месте, 13:20")
        for lang in fam.NOTICES:
            for key, text in fam.NOTICES[lang].items():
                if key.endswith("_away"):
                    self.assertNotIn("дом", text)
                    self.assertNotIn("uy", text)

    def test_every_text_has_both_languages_and_formats(self):
        self.assertEqual(set(fam.NOTICES["ru"]), set(fam.NOTICES["uz"]))
        self.assertEqual(set(fam.REPLIES["ru"]), set(fam.REPLIES["uz"]))
        for kind in ("departed", "eta", "delayed", "arrived"):
            for home in (True, False):
                for at in (self.ETA, None) if kind == "departed" else (self.ETA,):
                    for lang in ("ru", "uz"):
                        self.assertNotIn("{", fam.render((kind, at), lang, NAME, home))

    def test_name_is_cleaned(self):
        self.assertEqual(fam.clean_name("  Зафар\n\tака "), "Зафар ака")
        self.assertEqual(fam.clean_name("‮рамаЗ"), "рамаЗ", "переворот строки — прочь")
        self.assertEqual(len(fam.clean_name("Я" * 100)), fam.NAME_MAX)
        self.assertEqual(fam.clean_name("Мама 👩‍🦳"), "Мама 👩‍🦳", "ZWJ держит смайлик")
        for empty in ("", "   ", "​", None, 7, ["Зафар"]):
            self.assertIsNone(fam.clean_name(empty))


class CommandsTest(TempDb):
    def test_subscribe_replies_in_the_chat_language(self):
        self.assertEqual(self.subscribe(lang="ru"), fam.REPLIES["ru"]["subscribed"])
        self.assertIn("/stop", fam.REPLIES["ru"]["subscribed"])
        self.assertEqual(self.subscribe(chat=OTHER_CHAT, lang="uz-UZ"), fam.REPLIES["uz"]["subscribed"])
        self.assertEqual(self.subscribe(chat=OTHER_CHAT + 1, lang="en"), fam.REPLIES["ru"]["subscribed"])
        langs = sorted(r[0] for r in self.rows("SELECT lang FROM family_subs"))
        self.assertEqual(langs, ["ru", "ru", "uz"])

    def test_stored_subscription_has_no_chat_id_and_no_address(self):
        self.subscribe()
        dump = "\n".join(self.conn.iterdump())
        self.assertNotIn(str(CHAT), dump)
        self.assertNotIn(struct.pack(">q", CHAT).hex(), dump)
        self.assertNotIn(ADDRESS, dump, "адрес — только хэшем")
        self.assertIn(fam.link_hash(ADDRESS), dump)

    def test_bad_link_is_refused(self):
        for payload in ("f_short", "f_" + ADDRESS[:-1], "f_" + ADDRESS + "x", "f_" + "!" * 43):
            self.assertEqual(self.commands.command(f"/start {payload}", CHAT, "ru", NOW),
                             fam.REPLIES["ru"]["bad_link"])
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 0)

    def test_other_messages_are_not_ours(self):
        for text in ("/start", "/start abc", "привет", "", "  ", "/help", f"/start x_{ADDRESS}"):
            self.assertIsNone(self.commands.command(text, CHAT, "ru", NOW), text)
        self.assertIsNone(self.commands.command(f"/start f_{ADDRESS}", True, "ru", NOW), "bool — не чат")

    def test_repeat_is_idempotent_and_refreshes(self):
        self.subscribe(lang="ru")
        self.assertEqual(self.subscribe(lang="uz", now=NOW + 86400), fam.REPLIES["uz"]["subscribed"])
        self.assertEqual(self.rows("SELECT lang, seen FROM family_subs"), [("uz", NOW + 86400)])

    def test_cap_per_link(self):
        for n in range(fam.MAX_PER_LINK):
            self.assertEqual(self.subscribe(chat=CHAT + n), fam.REPLIES["ru"]["subscribed"])
        reply = self.subscribe(chat=CHAT + 99)
        self.assertEqual(reply, fam.REPLIES["ru"]["link_full"].format(link_cap=fam.MAX_PER_LINK))
        self.assertIn(str(fam.MAX_PER_LINK), reply)
        self.assertEqual(self.subscribe(chat=CHAT), fam.REPLIES["ru"]["subscribed"], "свой повтор — не новый")

    def test_cap_per_chat(self):
        for n in range(fam.MAX_PER_CHAT):
            self.assertEqual(self.subscribe(address=address_of(n)), fam.REPLIES["ru"]["subscribed"])
        self.assertEqual(self.subscribe(address=address_of(99)),
                         fam.REPLIES["ru"]["chat_full"].format(chat_cap=fam.MAX_PER_CHAT))

    def test_global_cap_refuses_and_logs_without_ids(self):
        saved = fam.MAX_SUBSCRIPTIONS
        fam.MAX_SUBSCRIPTIONS = 2
        try:
            self.subscribe(chat=1)
            self.subscribe(chat=2)
            with captured_log() as lines:
                self.assertEqual(self.subscribe(chat=CHAT), fam.REPLIES["ru"]["busy"])
            self.assertTrue(lines)
            self.assertNotIn(str(CHAT), " ".join(lines))
        finally:
            fam.MAX_SUBSCRIPTIONS = saved

    def test_stop_removes_every_subscription_of_the_chat_and_its_queue(self):
        self.subscribe()
        self.subscribe(address=address_of(1))
        self.subscribe(chat=OTHER_CHAT)
        fam.on_update(ADDRESS, item(eta=NOW + 1500), NOW)
        self.assertEqual(len(self.outbox()), 2)
        self.assertEqual(self.commands.command("/stop@RadarMapBot", CHAT, "ru", NOW),
                         fam.REPLIES["ru"]["stopped"])
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 1, "чужая подписка осталась")
        self.assertEqual([r[0] for r in self.outbox()], [OTHER_CHAT], "своё неотправленное — тоже прочь")
        self.assertEqual(self.commands.command("/stop", CHAT, "uz", NOW), fam.REPLIES["uz"]["none"])

    def test_database_failure_answers_busy(self):
        self.commands.conn.close()
        self.commands.conn = sqlite3.connect(":memory:")       # без таблиц
        self.commands.conn.isolation_level = None
        with captured_log() as lines:
            self.assertEqual(self.subscribe(), fam.REPLIES["ru"]["busy"])
        self.assertEqual(len(lines), 1)

    def test_one_kdf_per_command(self):
        calls = []
        self.commands.kdf = lambda password, salt: (calls.append(1), fast_kdf(password, salt))[1]
        for text in (f"/start f_{ADDRESS}", "/stop", f"/start f_{ADDRESS}"):
            calls.clear()
            self.commands.command(text, CHAT, "ru", NOW)
            self.assertEqual(len(calls), 1, text)
        calls.clear()
        self.commands.command("/start f_bad", CHAT, "ru", NOW)
        self.assertEqual(calls, [], "плохая ссылка — хэш не считаем")


class NotifyTest(TempDb):
    ETA = NOW + 25 * 60

    def test_no_family_db_means_nothing_and_no_file(self):
        missing = os.path.join(self.dir, "нет", "family.db")
        fam.DB_PATH = missing
        self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA), NOW), 0)
        self.assertFalse(os.path.exists(missing), "хук не создаёт базу — её создаёт бот")
        self.assertIsNone(fam.sweep_file(NOW))

    def test_link_without_subscribers_writes_nothing(self):
        self.subscribe(address=address_of(1))
        self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA), NOW), 0)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_trips")[0][0], 0)

    def test_link_without_a_write_key_never_notifies(self):
        self.subscribe()
        self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA, keyed=False), NOW), 0)
        self.assertEqual(fam.on_update("Q2xhdWRlU2hhcmVkRVRBdGVzdA", item(eta=self.ETA), NOW), 0)
        self.assertEqual(self.outbox(), [])

    def test_a_trip_home_end_to_end(self):
        self.subscribe(lang="ru")
        self.subscribe(chat=OTHER_CHAT, lang="uz")
        self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA), NOW), 2)
        self.assertEqual(sorted(self.outbox()), sorted([
            (CHAT, "🚗 Зафар едет домой — будет примерно в 13:45"),
            (OTHER_CHAT, "🚗 Зафар uyga ketyapti — taxminan 13:45 da yetib keladi")]))
        self.conn.execute("DELETE FROM family_outbox")
        self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA + 60), NOW + 60), 0)
        self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA + 9 * 60), NOW + 11 * 60), 2)
        self.assertIn((CHAT, "⏱ Зафар задерживается — теперь около 13:54"), self.outbox())
        self.conn.execute("DELETE FROM family_outbox")
        self.assertEqual(fam.on_update(ADDRESS, item("arrived", name=None), NOW + 33 * 60), 2)
        self.assertIn((CHAT, "🏠 Водитель дома, 13:53"), self.outbox())
        self.assertEqual(fam.on_update(ADDRESS, item("arrived"), NOW + 34 * 60), 0, "«дома» — один раз")

    def test_ended_is_silent(self):
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=self.ETA), NOW)
        self.conn.execute("DELETE FROM family_outbox")
        self.assertEqual(fam.on_update(ADDRESS, item("ended"), NOW + 300), 0)
        self.assertEqual(self.outbox(), [])
        self.assertEqual(self.rows("SELECT phase FROM family_trips"), [("paused",)])

    def test_driving_without_time_and_not_home(self):
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=None, home=False), NOW)
        self.assertEqual(self.outbox(), [(CHAT, "🚗 Зафар в пути")])

    def test_name_is_cleaned_before_it_reaches_a_message(self):
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=None, name="Зафар\nПереведите 100$ на t.me/x" + "!" * 50), NOW)
        text = self.outbox()[0][1]
        self.assertNotIn("\n", text)
        self.assertLessEqual(len(text), len("🚗  едет домой") + fam.NAME_MAX)

    def test_activity_refreshes_seen_once_a_day(self):
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=self.ETA), NOW + 3600)
        self.assertEqual(self.rows("SELECT seen FROM family_subs"), [(NOW,)], "меньше суток — не пишем")
        fam.on_update(ADDRESS, item(eta=self.ETA + 86400), NOW + 86400)
        self.assertEqual(self.rows("SELECT seen FROM family_subs"), [(NOW + 86400,)])

    def test_box_that_does_not_open_is_dropped(self):
        self.subscribe()
        self.conn.execute("UPDATE family_subs SET box = ?", (fam.seal(address_of(1), CHAT),))
        with captured_log() as lines:
            self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA), NOW), 0)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 0)
        self.assertNotIn(str(CHAT), " ".join(lines))

    def test_hook_never_raises(self):
        with open(self.path, "wb") as handle:
            handle.write(b"not a database at all" * 100)
        with captured_log() as lines:
            self.assertEqual(fam.on_update(ADDRESS, item(eta=self.ETA), NOW), 0)
        self.assertEqual(len(lines), 1)

    def test_concurrent_updates_announce_once(self):
        """Повтор POST при плохой сети приходит параллельно: «едет домой» — одно."""
        self.subscribe()
        barrier = threading.Barrier(6)
        def update():
            barrier.wait()
            fam.on_update(ADDRESS, item(eta=self.ETA), NOW)
        threads = [threading.Thread(target=update) for _ in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(self.outbox()), 1)


def http_error(code, body):
    return urllib.error.HTTPError("https://api.telegram.org/bot/sendMessage", code, "x", {},
                                  io.BytesIO(json.dumps(body).encode()))


class CourierTest(TempDb):
    def setUp(self):
        super().setUp()
        self.clock = [NOW]
        self.sent = []
        self.failure = None
        def send(method, payload):
            if self.failure is not None:
                raise self.failure() if callable(self.failure) else self.failure
            self.sent.append((method, payload))
            return {"ok": True}
        self.courier = fam.Courier(send, path=self.path, now=lambda: self.clock[0])
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=NOW + 1500), NOW)

    def tearDown(self):
        if self.courier._conn is not None:
            self.courier._conn.close()
        super().tearDown()

    def pending(self):
        return self.rows("SELECT attempts, next_try FROM family_outbox")

    def test_delivered_and_removed(self):
        done = self.courier.drain()
        self.assertEqual(done["sent"], 1)
        self.assertEqual(self.sent, [("sendMessage", {"chat_id": CHAT,
                                                      "text": "🚗 Зафар едет домой — будет примерно в 13:45"})])
        self.assertEqual(self.outbox(), [], "после доставки ни номера чата, ни имени на диске")
        dump = "\n".join(self.conn.iterdump())
        self.assertNotIn(str(CHAT), dump)
        self.assertNotIn(NAME, dump)

    def test_network_failure_is_retried_then_dropped(self):
        self.failure = lambda: urllib.error.URLError("сеть")
        with captured_log() as lines:
            for attempt, pause in enumerate(fam.RETRY_DELAYS, start=1):
                self.courier.drain()
                self.assertEqual(self.pending(), [(attempt, self.clock[0] + pause)])
                self.courier.drain()
                self.assertEqual(self.pending()[0][0], attempt, "до паузы не трогаем")
                self.clock[0] += pause
            self.courier.drain()
        self.assertEqual(self.pending(), [], f"после {fam.SEND_ATTEMPTS} попыток — снято")
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 1, "подписка жива")
        self.assertEqual(len(lines), 1)

    def test_blocked_bot_removes_the_subscription(self):
        self.failure = http_error(403, {"ok": False, "description": "Forbidden: bot was blocked by the user"})
        with captured_log() as lines:
            self.assertEqual(self.courier.drain()["gone"], 1)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 0)
        self.assertEqual(self.outbox(), [])
        self.assertIn("403", lines[0])

    def test_chat_not_found_removes_other_bad_request_only_drops(self):
        self.failure = http_error(400, {"ok": False, "description": "Bad Request: message text is empty"})
        self.assertEqual(self.courier.drain()["drop"], 1)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 1, "наша ошибка — не повод снимать")
        self.clock[0] = NOW + 60
        fam.on_update(ADDRESS, item("arrived"), NOW + 60)
        self.failure = http_error(400, {"ok": False, "description": "Bad Request: chat not found"})
        self.assertEqual(self.courier.drain()["gone"], 1)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 0)

    def test_flood_waits_as_told_and_stops_the_round(self):
        self.subscribe(chat=OTHER_CHAT)
        self.clock[0] = at = NOW + 60
        fam.on_update(ADDRESS, item("arrived"), at)             # два сообщения: двум чатам
        self.conn.execute("DELETE FROM family_outbox WHERE chat_id = ? AND text LIKE '🚗%'", (CHAT,))
        self.failure = http_error(429, {"ok": False, "parameters": {"retry_after": 17}})
        done = self.courier.drain()
        self.assertEqual((done["flood"], done["sent"]), (1, 0))
        self.assertIn((0, at + 17), self.pending(), "попытка не сгорела, пауза — как сказано")
        self.failure = None
        self.assertEqual(self.courier.drain()["sent"], 1, "второй — следующим проходом")
        self.clock[0] += 17
        self.assertEqual(self.courier.drain()["sent"], 1)

    def test_stale_message_is_not_sent(self):
        self.clock[0] = NOW + fam.OUTBOX_TTL + 1
        with captured_log():
            done = self.courier.drain()
        self.assertEqual((done["stale"], done["sent"]), (1, 0))
        self.assertEqual(self.sent, [], "«едет домой» через десять минут — уже неправда")

    def test_odd_exception_counts_as_an_attempt(self):
        """Обрыв посреди ответа — не OSError; он не должен ронять проход и
        слать то же сообщение каждые 2 секунды."""
        import http.client
        self.failure = lambda: http.client.IncompleteRead(b"")
        self.courier.drain()
        self.assertEqual(self.pending()[0][0], 1)

    def test_run_survives_a_broken_round(self):
        stop = threading.Event()
        calls = []
        def boom():
            calls.append(1)
            if len(calls) == 1:
                raise sqlite3.OperationalError("disk I/O error")
            stop.set()
            return {}
        pauses = []
        self.courier.step = boom
        self.courier.sleep = pauses.append
        with captured_log() as lines:
            self.courier.run(stop)
        self.assertEqual(len(calls), 2, "после сбоя поток живёт")
        self.assertIn("OperationalError", lines[0])
        self.assertEqual(pauses, [fam.FAILURE_PAUSE, fam.DRAIN_INTERVAL], "после сбоя — пауза, не спам в журнал")

    def test_closed_chat_is_tried_once_per_round(self):
        fam.on_update(ADDRESS, item("arrived"), NOW)              # второе сообщение тому же чату
        tries = []
        def closed(method, payload):
            tries.append(payload["chat_id"])
            raise http_error(403, {"description": "Forbidden: bot was blocked by the user"})
        self.courier.send = closed
        with captured_log():
            self.courier.drain()
        self.assertEqual(tries, [CHAT])
        self.assertEqual(self.outbox(), [])

    def test_odd_flood_answer_does_not_break_the_round(self):
        self.failure = http_error(429, {"parameters": ["not", "a", "dict"]})
        with captured_log():
            self.assertEqual(self.courier.drain()["flood"], 1)
        self.assertEqual(self.pending(), [(0, NOW + fam.RETRY_DELAYS[0])])


class RetentionTest(TempDb):
    def test_quiet_subscriptions_go_after_55_days(self):
        self.subscribe()
        self.subscribe(address=address_of(1), now=NOW - 50 * 86400)
        self.subscribe(address=address_of(2), now=NOW - 56 * 86400)
        with captured_log():
            done = fam.sweep(self.conn, NOW)
        self.assertEqual(done["subs"], 1)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 2)

    def test_driving_keeps_a_subscription_alive(self):
        self.subscribe(now=NOW - 54 * 86400)
        fam.on_update(ADDRESS, item(eta=NOW + 1500), NOW)
        with captured_log():
            fam.sweep(self.conn, NOW + 30 * 86400)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_subs")[0][0], 1)

    def test_queue_and_trips_do_not_outlive_their_purpose(self):
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=NOW + 1500), NOW)
        with captured_log():
            fam.sweep(self.conn, NOW + fam.OUTBOX_TTL + 1)
        self.assertEqual(self.outbox(), [])
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_trips")[0][0], 1, "поездка ещё идёт")
        with captured_log():
            fam.sweep(self.conn, NOW + fam.TRIP_TTL + 1)
        self.assertEqual(self.rows("SELECT COUNT(*) FROM family_trips")[0][0], 0)

    def test_stop_leaves_no_trip_or_queue_behind(self):
        self.subscribe()
        fam.on_update(ADDRESS, item(eta=NOW + 1500), NOW)
        self.commands.command("/stop", CHAT, "ru", NOW)
        with captured_log():
            fam.sweep(self.conn, NOW + 1)
        for table in ("family_subs", "family_trips", "family_outbox"):
            self.assertEqual(self.rows(f"SELECT COUNT(*) FROM {table}")[0][0], 0, table)

    def test_api_sweep_works_without_the_bot(self):
        self.subscribe(now=NOW - 60 * 86400)
        with captured_log():
            self.assertEqual(fam.sweep_file(NOW)["subs"], 1)


class RetentionDocTest(unittest.TestCase):
    """RETENTION.md: строки family.db равны коду, сроки — потолку api.py."""

    def doc(self):
        import test_api
        return test_api.retention_doc(), test_api.created_tables("family_notify.py")

    def test_rows_match_the_code(self):
        doc, tables = self.doc()
        self.assertEqual(tables, set(fam.RETENTION_DAYS), "таблица family_notify.py без срока в коде")
        for table, days in fam.RETENTION_DAYS.items():
            self.assertEqual(doc.get(table), days, f"{table}: RETENTION.md и код разошлись")

    def test_ceilings_follow_the_api(self):
        self.assertEqual(fam.KEEP_DAYS, api.LIVE_MAX_DAYS)
        self.assertEqual(fam.TRIP_TTL, api.ETA_TTL)
        self.assertEqual(fam.ARRIVED_HOLD, api.ETA_ARRIVED_TTL)
        self.assertLessEqual(fam.OUTBOX_TTL, 86400 * fam.RETENTION_DAYS["family_outbox"])
        self.assertLessEqual(fam.TRIP_TTL, 86400 * fam.RETENTION_DAYS["family_trips"])

    def test_tables_with_person_columns_have_a_ceiling(self):
        doc, _ = self.doc()
        work = tempfile.mkdtemp()
        try:
            path = os.path.join(work, "family.db")
            fam.init_db(path)
            conn = sqlite3.connect(path)
            try:
                for (table,) in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' "
                                             "AND name NOT LIKE 'sqlite_%'"):
                    columns = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
                    if columns & {"chat", "chat_id", "box", "link"}:
                        self.assertIsInstance(doc.get(table), int, f"{table}: поля человека без срока")
            finally:
                conn.close()
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def test_family_db_is_not_backed_up(self):
        with open(os.path.join(HERE, "backup_db.sh"), encoding="utf-8") as handle:
            self.assertNotIn("family.db", handle.read())
        with open(os.path.join(HERE, "RETENTION.md"), encoding="utf-8") as handle:
            self.assertIn("family.db", handle.read().split("## Вне таблиц", 1)[1])


class ApiHookTest(unittest.TestCase):
    """Через настоящий api.py: POST /api/eta с ключом кладёт сообщение в
    очередь; ссылка без ключа — нет; без family.db и с битой — ответ 200."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.saved = api.DB_PATH, api.TRAFFIC_DB_PATH, fam.DB_PATH
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
        api.DB_PATH, api.TRAFFIC_DB_PATH, fam.DB_PATH = cls.saved
        shutil.rmtree(cls.dir, ignore_errors=True)

    def setUp(self):
        fam.DB_PATH = os.path.join(self.dir, f"family-{self.id().rsplit('.', 1)[1]}.db")
        with api._eta_lock:
            api._eta_links.clear()
        with api._ip_lock:
            api._ip_counters.clear()

    def post(self, body):
        request = urllib.request.Request(self.base + "/api/eta", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def subscribed(self):
        fam.init_db(fam.DB_PATH)
        commands = fam.FamilyCommands(fam.connect(fam.DB_PATH), SALT, fast_kdf)
        commands.command(f"/start f_{ADDRESS}", CHAT, "ru", time.time())
        commands.conn.close()

    def outbox(self):
        conn = sqlite3.connect(fam.DB_PATH)
        try:
            return conn.execute("SELECT chat_id, text FROM family_outbox ORDER BY id").fetchall()
        finally:
            conn.close()

    def test_keyed_update_reaches_the_queue(self):
        self.subscribed()
        eta = time.time() + 25 * 60
        self.assertEqual(self.post({"key": KEY, "eta": eta, "left_m": 12400, "status": "driving"}), 200)
        self.assertEqual(self.outbox(), [(CHAT, f"🚗 Водитель едет домой — будет примерно в {fam.clock(eta)}")])
        before = time.time()
        self.assertEqual(self.post({"key": KEY, "eta": eta, "left_m": 0, "status": "arrived"}), 200)
        self.assertIn(self.outbox()[-1][1], {f"🏠 Водитель дома, {fam.clock(at)}" for at in (before, time.time())})

    def test_legacy_token_never_notifies(self):
        self.subscribed()
        token = "Q2xhdWRlU2hhcmVkRVRBdGVzdA"
        self.assertEqual(self.post({"token": token, "eta": time.time() + 600, "left_m": 1, "status": "driving"}),
                         200)
        self.assertEqual(self.outbox(), [])

    def test_no_family_db_and_a_broken_one_still_answer_200(self):
        body = {"key": KEY, "eta": time.time() + 600, "left_m": 1, "status": "driving"}
        self.assertEqual(self.post(body), 200)
        self.assertFalse(os.path.exists(fam.DB_PATH))
        with open(fam.DB_PATH, "wb") as handle:
            handle.write(b"garbage" * 200)
        with captured_log():
            self.assertEqual(self.post(body), 200)

    def test_hook_runs_outside_the_link_lock(self):
        """Хук после блокировки ссылок: пока он пишет в family.db, чтение
        страниц и чужие обновления не ждут."""
        seen = []
        saved = fam.on_update
        fam.on_update = lambda address, item, now: seen.append(api._eta_lock.locked())
        try:
            api.eta_put(ADDRESS, {"eta": time.time() + 60, "left_m": 1, "status": "driving",
                                  "updated": time.time(), "keyed": True}, time.time())
        finally:
            fam.on_update = saved
        self.assertEqual(seen, [False])


class LogPrivacyTest(TempDb):
    def test_no_chat_id_name_or_text_in_the_log(self):
        with captured_log() as lines:
            self.subscribe()
            self.subscribe(chat=OTHER_CHAT, lang="uz")
            self.conn.execute("UPDATE family_subs SET box = ? WHERE lang = 'uz'", (fam.seal(address_of(3), 1),))
            fam.on_update(ADDRESS, item(eta=NOW + 1500), NOW)
            courier = fam.Courier(lambda method, payload: (_ for _ in ()).throw(
                http_error(403, {"description": "Forbidden: bot was blocked by the user"})),
                path=self.path, now=lambda: NOW)
            courier.step()
            courier._conn.close()
            self.commands.command("/stop", CHAT, "ru", NOW)
        self.assertTrue(lines, "сбои пишутся")
        joined = "\n".join(lines)
        for leak in (str(CHAT), str(OTHER_CHAT), NAME, "едет домой", ADDRESS, fam.link_hash(ADDRESS)):
            self.assertNotIn(leak, joined)


class DeployTest(unittest.TestCase):
    """api.py импортирует family_notify на старте: без файла на сервере он
    не поднимется — обе выкладки обязаны его возить."""

    def read(self, name):
        with open(os.path.join(HERE, name), encoding="utf-8") as handle:
            return handle.read()

    def test_both_deploys_ship_the_module(self):
        api_deploy = self.read("deploy_api.sh")
        self.assertIn('"$DIR/family_notify.py"', api_deploy)
        self.assertIn("$FAMILY.new", api_deploy.split("for f in", 1)[0], "синтаксис проверяется до подмены")
        self.assertRegex(api_deploy, r"mv \$FAMILY\.new \$FAMILY")
        bot_deploy = self.read("deploy_bot.sh")
        modules = re.search(r'^MODULES="([^"]+)"$', bot_deploy, re.M)
        self.assertIsNotNone(modules, "deploy_bot.sh возит модули списком MODULES")
        self.assertIn("family_notify.py", modules.group(1).split())
        self.assertIn('"$DIR/$f"', bot_deploy)
        self.assertIn("test_family_notify", bot_deploy)
        self.assertRegex(self.read("drift.sh"), r"(?m)^family_notify\.py\s+/opt/radarmap/api/family_notify\.py$")

    def test_family_db_lives_where_both_units_may_write(self):
        self.assertTrue(fam.DEFAULT_DB.startswith("/opt/radarmap/api/"))
        bot_unit = self.read("radarmap-bot.service")
        self.assertIn("ReadWritePaths=/opt/radarmap/api", bot_unit)
        self.assertIn("ReadWritePaths=/opt/radarmap\n", self.read("systemd-radarmap-sandbox.conf"))
        self.assertEqual(os.path.dirname(fam.DEFAULT_DB), os.path.dirname(telegram_bot.DEFAULT_DB))

    def test_runbook_explains_how_to_turn_it_on(self):
        runbook = self.read("RUNBOOK.md")
        self.assertTrue("## Близкие в Telegram" in runbook, "в RUNBOOK.md нет раздела")
        section = runbook.split("## Близкие в Telegram", 1)[1].split("\n## ", 1)[0]
        self.assertIn("username", section)
        self.assertLess(section.index("deploy_api.sh"), section.index("deploy_bot.sh"), "порядок: api → бот")


if __name__ == "__main__":
    unittest.main(verbosity=2)
