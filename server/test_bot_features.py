#!/usr/bin/env python3
"""Тесты того, что бот ОТДАЁТ (план 23.1–23.7): профиль и меню выставляются
один раз, тексты на двух языках, «что рядом» (состав, порядок, честное «не
подтверждена», пауза 20 с), /metan с отметкой статуса у станции, трансляция
(только новое впереди, «ещё стоит?» один раз → /api/vote kind=pass),
перевалы (сообщение на появление и уход опасности), город (только
подтверждённое, тихие часы, потолок в час), /my, /stats только владельцу,
отмена отметки 2 минуты, пульт features.bot, сроки bot.db — и главное:
ни геопозиции, ни Telegram-id в журнале и в bot.db. Без сети: Telegram и API
подменены.

Запуск: python3 server/test_bot_features.py
"""
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import tempfile
import time
import unittest

import api
import bot_near
import bot_subs
import bot_texts
import family_notify
import telegram_bot as bot
import telegram_publish
from test_telegram_bot import CNG_POINT, SALT, USER, OTHER, offset, write_venues

#: 2027-01-15 08:00 UTC = 13:00 по Ташкенту — не тихие часы.
NOW = 1_800_000_000.0
HERE = os.path.dirname(os.path.abspath(__file__))
#: Человек в 200 м южнее АГНКС «Чиланзар».
HOME = offset(CNG_POINT, north=-200)
STREET = "ул. Шота Руставели"


def at(**shift):
    return offset(HOME, **shift)


def report(rid, rtype, point, created, confirmed=False, expires=None):
    return {"id": rid, "lat": point[0], "lon": point[1], "created": created,
            "expires": expires or created + 3 * 3600, "up": 1, "down": 0, "type": rtype,
            "confirmed": confirmed}


def write_address(directory, point, street, number):
    """Адресная клетка формата build_roads.addresses_by_cell: улица, номера,
    координаты дельтами 1e-5° от нуля."""
    key = telegram_publish.address_key(*point)
    cell = {"streets": [{"n": street, "h": [number],
                         "p": [int(round(point[0] * 1e5)), int(round(point[1] * 1e5))]}]}
    with open(os.path.join(directory, f"road2_{key}_a.json"), "w", encoding="utf-8") as handle:
        json.dump(cell, handle, ensure_ascii=False)


class FakeApi:
    """GET и POST API: списки задаются тестом, запросы записываются."""

    def __init__(self):
        self.mobile = []
        self.road = []
        self.cng = []
        self.down = False
        self.posted = []
        self.answers = {}

    def get(self, path):
        if self.down:
            return 0, {}
        key = {"/api/mobile": ("reports", self.mobile), "/api/road": ("reports", self.road),
               "/api/cng": ("stations", self.cng)}[path]
        return 200, {key[0]: list(key[1])}

    def post(self, path, body, ip):
        self.posted.append((path, body, ip))
        return self.answers.get(path, (200, {"id": 77, "merged": False, "ok": True}))


class Stand(unittest.TestCase):
    """Бот с источниками на временных файлах, часы — в руках теста."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.clock = [NOW]
        self.api = FakeApi()
        self.sent = []
        self.roads = os.path.join(self.dir, "roads")
        write_venues(self.roads, [
            (12, "АГНКС Чиланзар", CNG_POINT[1], CNG_POINT[0]),
            (12, "Метан Юг", at(north=-2000)[1], at(north=-2000)[0]),
            (12, "Метан Восток", at(east=4000)[1], at(east=4000)[0]),
            (12, "Метан Далёкий", at(north=-30000)[1], at(north=-30000)[0]),
        ])
        write_address(self.roads, at(north=1200), STREET, "12")
        self.cameras_path = os.path.join(self.dir, "cameras.json")
        with open(self.cameras_path, "w", encoding="utf-8") as handle:
            json.dump([
                {"id": 501, "lat": at(north=600)[0], "lon": at(north=600)[1], "type": "Стационар радар",
                 "location": "Amir Temur shoh koʻchasi"},
                {"id": 502, "lat": at(east=2500)[0], "lon": at(east=2500)[1], "type": "Стационар камера",
                 "location": "Bunyodkor"},
                {"id": 503, "lat": at(north=20000)[0], "lon": at(north=20000)[1], "type": "Стационар камера"},
            ], handle, ensure_ascii=False)
        self.weather_path = os.path.join(self.dir, "roads.json")
        self.write_weather([])
        self.api.mobile = [report(1, "tripod", at(north=1200), NOW - 25 * 60, confirmed=True),
                           report(2, "post", at(east=3400), NOW - 600)]
        self.api.road = [report(4, "closure", at(north=-4100), NOW - 600, expires=NOW + 5 * 3600)]
        self.api.cng = [{"lat": round(CNG_POINT[0], 5), "lon": round(CNG_POINT[1], 5), "status": "gas",
                         "status_age": 15, "queue": None, "queue_age": None, "confirmed": True}]
        self.db_path = os.path.join(self.dir, "bot.db")
        self.config = {}
        self.pult = None
        self.family = None
        self.bot = self.make()

    def make(self):
        tick = lambda: self.clock[0]
        self.venues = bot.CngVenues(self.roads, logger=lambda text: None, clock=tick)
        self.sources = bot_near.Sources(api_get=self.api.get,
                                        cameras=bot_near.CameraDb(self.cameras_path, clock=tick),
                                        venues=self.venues, addresses=bot_near.Addresses(self.roads),
                                        weather_path=self.weather_path, clock=tick, wall=tick)
        return bot.Bot(SALT, bot.open_db(self.db_path), send=lambda m, p: self.sent.append((m, p)),
                       api_post=self.api.post, now=tick, venues=self.venues, family=self.family,
                       sources=self.sources, pult=self.pult, config=self.config)

    def write_weather(self, points, generated=None):
        with open(self.weather_path, "w", encoding="utf-8") as handle:
            json.dump({"v": 1, "generated": NOW if generated is None else generated, "points": points},
                      handle, ensure_ascii=False)

    # --- обновления Telegram --------------------------------------------------

    def text(self, value, user=USER, lang="ru", chat=None):
        self.bot.handle({"message": {"chat": {"id": chat or user}, "from": {"id": user, "language_code": lang},
                                     "text": value}})
        return self.last()

    def location(self, point=HOME, user=USER, lang="ru", live=None, date=None):
        location = {"latitude": point[0], "longitude": point[1]}
        if live is not None:
            location["live_period"] = live
        message = {"chat": {"id": user}, "from": {"id": user, "language_code": lang}, "location": location,
                   "date": int(self.clock[0] if date is None else date)}
        self.bot.handle({"message": message})
        return self.last()

    def live_edit(self, point, user=USER, live=3600, date=NOW, lang="ru"):
        location = {"latitude": point[0], "longitude": point[1]}
        if live is not None:
            location["live_period"] = live
        self.bot.handle({"edited_message": {"chat": {"id": user}, "from": {"id": user, "language_code": lang},
                                            "location": location, "date": int(date)}})

    def tap(self, data, user=USER, lang="ru"):
        self.bot.handle({"callback_query": {"id": "q", "data": data,
                                            "from": {"id": user, "language_code": lang},
                                            "message": {"chat": {"id": user}}}})
        return self.last()

    def messages(self):
        return [p for m, p in self.sent if m == "sendMessage"]

    def last(self):
        out = self.messages()
        return out[-1] if out else None

    def buttons(self, payload):
        markup = (payload or {}).get("reply_markup") or {}
        return [b["callback_data"] for row in markup.get("inline_keyboard", []) for b in row]


# --- тексты и профиль (23.1) -----------------------------------------------------------

class TextsTest(unittest.TestCase):
    def test_both_languages_have_the_same_keys_and_placeholders(self):
        ru, uz = bot_texts.TEXTS["ru"], bot_texts.TEXTS["uz"]
        self.assertEqual(set(ru), set(uz))
        for key in ru:
            self.assertEqual(set(re.findall(r"\{(\w+)\}", ru[key])), set(re.findall(r"\{(\w+)\}", uz[key])), key)
        for table in (bot_texts.KIND_NAMES, bot_texts.KIND_WORDS, bot_texts.CNG_NAMES, bot_texts.CAMERA_NAMES,
                      bot_texts.HAZARD_NAMES):
            self.assertEqual(set(table["ru"]), set(table["uz"]))
        self.assertEqual(set(bot_texts.CITY_NAMES_UZ), {city for city, _, _ in telegram_publish.CITIES})

    def uzbek_strings(self):
        tables = [bot_texts.TEXTS["uz"], bot_texts.KIND_NAMES["uz"], bot_texts.KIND_WORDS["uz"],
                  bot_texts.CNG_NAMES["uz"], bot_texts.CAMERA_NAMES["uz"], bot_texts.HAZARD_NAMES["uz"],
                  bot_texts.CITY_NAMES_UZ, bot_texts.PROFILE["uz"]["commands"]]
        out = [v for table in tables for v in table.values()]
        out += [bot_texts.PROFILE["uz"][k] for k in ("name", "short", "description")]
        return out

    def test_uzbek_latin_uses_the_right_apostrophes(self):
        """ʻ (U+02BB) — только после o и g; ни ASCII-апострофа, ни кавычек-запятых."""
        for value in self.uzbek_strings():
            for bad in ("'", "’", "‘", "`"):
                self.assertNotIn(bad, value, value)
            for match in re.finditer("ʻ", value):
                self.assertIn(value[match.start() - 1], "oOgG", value)
        self.assertIn("yoʻq", bot_texts.TEXTS["uz"]["cng_nogas"])
        self.assertIn("maʼlumot", bot_texts.TEXTS["uz"]["cng_unknown"])

    def test_profile_fits_bot_api_limits(self):
        limits = bot_texts.PROFILE_LIMITS
        for lang in bot_texts.LANGS:
            profile = bot_texts.PROFILE[lang]
            self.assertLessEqual(len(profile["name"]), limits["name"])
            self.assertLessEqual(len(profile["short"]), limits["short"], lang)
            self.assertLessEqual(len(profile["description"]), limits["description"], lang)
            self.assertEqual(tuple(profile["commands"]), bot_texts.COMMANDS)
            for command, description in profile["commands"].items():
                self.assertRegex(command, r"^[a-z0-9_]{1,32}$")
                self.assertLessEqual(len(description), limits["command"])
        self.assertEqual(bot_texts.COMMANDS, ("near", "report", "metan", "pereval", "city", "my", "app",
                                              "lang", "help", "privacy", "stop"))


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.db = bot.open_db(":memory:")
        self.calls = []
        self.logs = []

    def send(self, method, payload):
        self.calls.append((method, payload))
        return {"ok": True, "result": True}

    def test_profile_is_set_once_and_again_only_when_it_changes(self):
        self.assertTrue(bot.ensure_profile(self.send, self.db, self.logs.append))
        methods = [m for m, _ in self.calls]
        for method in ("setMyName", "setMyShortDescription", "setMyDescription", "setMyCommands"):
            self.assertEqual(methods.count(method), 3, f"{method}: по умолчанию, ru и uz")
        self.assertIn(("setChatMenuButton", {"menu_button": {"type": "commands"}}), self.calls)
        uz = [p for m, p in self.calls if m == "setMyCommands" and p.get("language_code") == "uz"][0]
        self.assertEqual([c["command"] for c in uz["commands"]], list(bot_texts.COMMANDS))
        self.assertEqual(uz["commands"][0]["description"], bot_texts.PROFILE["uz"]["commands"]["near"])
        default = [p for m, p in self.calls if m == "setMyName" and "language_code" not in p][0]
        self.assertEqual(default["name"], bot_texts.PROFILE["ru"]["name"])
        self.calls.clear()
        self.assertFalse(bot.ensure_profile(self.send, self.db, self.logs.append))
        self.assertEqual(self.calls, [], "не менялся — Telegram не трогаем")
        saved = bot_texts.PROFILE["ru"]["short"]
        bot_texts.PROFILE["ru"]["short"] = saved + "!"
        try:
            self.assertTrue(bot.ensure_profile(self.send, self.db, self.logs.append))
            self.assertTrue(self.calls)
        finally:
            bot_texts.PROFILE["ru"]["short"] = saved

    def test_a_failed_call_is_retried_on_the_next_start(self):
        def failing(method, payload):
            self.calls.append(method)
            raise OSError("сеть")
        self.assertFalse(bot.ensure_profile(failing, self.db, self.logs.append))
        self.assertEqual(len(self.calls), 1, "после первого сбоя — стоп")
        self.assertTrue(any("профиль не выставлен" in line for line in self.logs))
        self.assertTrue(bot.ensure_profile(self.send, self.db, self.logs.append), "отпечаток не записан — повтор")


class MenuTest(Stand):
    def test_greeting_carries_the_persistent_location_keyboard(self):
        reply = self.text("/start")
        self.assertEqual(reply["text"], bot_texts.TEXTS["ru"]["start"])
        keyboard = reply["reply_markup"]
        self.assertTrue(keyboard["is_persistent"])
        first = keyboard["keyboard"][0]
        self.assertEqual(first[0], {"text": "📍 Отправить геопозицию", "request_location": True})
        self.assertEqual(first[1]["text"], "⛽ Метан рядом")
        uz = self.text("/help", lang="uz", user=OTHER)
        self.assertEqual(uz["text"], bot_texts.TEXTS["uz"]["help"])
        self.assertEqual(uz["reply_markup"]["keyboard"][0][0]["text"], "📍 Joylashuvni yuborish")

    def test_privacy_and_app(self):
        self.assertIn("https://soulmed.uz/radarmap/privacy.html", self.text("/privacy")["text"])
        self.assertEqual(self.text("/app")["text"], bot_texts.TEXTS["ru"]["app_soon"])
        self.config["app_url"] = "https://apps.apple.com/app/id123"
        self.assertIn("https://apps.apple.com/app/id123", self.text("/app")["text"])
        uz = self.text("/app@RadarMapUzBot", lang="uz", user=OTHER)["text"]
        self.assertEqual(uz, bot_texts.TEXTS["uz"]["app_link"].format(url="https://apps.apple.com/app/id123"))
        self.config["app_url"] = ""
        self.assertIn("tez orada", self.text("/app", lang="uz", user=OTHER)["text"])

    def test_lang_is_stored_by_the_person_hash_and_wins_over_telegram(self):
        reply = self.text("/lang")
        self.assertEqual(self.buttons(reply), ["lang:ru", "lang:uz"])
        self.assertEqual(self.tap("lang:uz")["text"], bot_texts.TEXTS["uz"]["lang_set"])
        self.assertEqual(self.text("/help", lang="ru")["text"], bot_texts.TEXTS["uz"]["help"])
        dump = "\n".join(self.bot.db.iterdump())
        self.assertIn(bot.user_hash(SALT, USER, NOW), dump)
        self.assertNotIn(str(USER), dump)
        self.tap("lang:ru")
        self.assertEqual(self.text("/help", lang="uz")["text"], bot_texts.TEXTS["ru"]["help"])

    def test_report_without_a_point_asks_for_one_then_shows_the_picker(self):
        self.assertEqual(self.text("/report")["text"], bot_texts.TEXTS["ru"]["need_location_report"])
        reply = self.location()
        self.assertEqual(reply["text"], bot_texts.TEXTS["ru"]["pick"])
        self.assertIn("tripod", self.buttons(reply))


# --- «что рядом» (23.2) ------------------------------------------------------------------

class NearTest(Stand):
    def test_card_lists_everything_nearby_in_order_and_honestly(self):
        reply = self.location()
        self.assertEqual(len(self.messages()), 1, "ответ — одно сообщение")
        self.assertEqual(reply["text"], "\n".join([
            "📍 В радиусе 5 км:",
            f"📷 Тренога — 1,2 км, {STREET}, 12 · подтверждена, 25 мин назад",
            "👮 Пост ДПС — 3,4 км · отметка водителя, не подтверждена, 10 мин назад",
            "⛔ Перекрыто — 4,1 км · до 18:00",
            "📷 Стационарных камер: 2, ближайшая — 600 м (радар, Amir Temur shoh koʻchasi)",
            "⛽ Метан: «АГНКС Чиланзар» 200 м — газ есть, 15 мин назад",
        ]))
        self.assertEqual(self.buttons(reply), ["mark", "near15"])

    def test_card_in_uzbek(self):
        reply = self.location(user=OTHER, lang="uz")
        self.assertEqual(reply["text"], "\n".join([
            "📍 5 km radiusda:",
            f"📷 Uch oyoq kamera — 1,2 km, {STREET}, 12 · tasdiqlangan, 25 daqiqa oldin",
            "👮 YPX posti — 3,4 km · haydovchi belgisi, tasdiqlanmagan, 10 daqiqa oldin",
            "⛔ Yoʻl yopiq — 4,1 km · 18:00 gacha",
            "📷 Statsionar kameralar: 2 ta, eng yaqini — 600 m (radar, Amir Temur shoh koʻchasi)",
            "⛽ Metan: «АГНКС Чиланзар» 200 m — gaz bor, 15 daqiqa oldin",
        ]))

    def test_further_shows_15_km_and_mark_opens_the_picker(self):
        self.api.mobile.append(report(3, "radar", at(north=9000), NOW - 300))
        self.assertNotIn("Радар", self.location()["text"])
        self.clock[0] += 21
        far = self.tap("near15")
        self.assertTrue(far["text"].startswith("📍 В радиусе 15 км:"))
        self.assertIn("📡 Радар — 9 км", far["text"])
        self.assertEqual(self.buttons(far), ["mark"], "дальше 15 км — некуда")
        picker = self.tap("mark")
        self.assertEqual(picker["text"], bot_texts.TEXTS["ru"]["pick"])
        self.tap("tripod")
        self.assertEqual(self.api.posted[-1][1]["lat"], HOME[0], "отметка — в точке человека")

    def test_rate_limit_one_card_per_20_seconds(self):
        self.location()
        self.clock[0] += 10
        reply = self.location()
        self.assertEqual(reply["text"], bot_texts.TEXTS["ru"]["near_slow"])
        self.assertIn("radar", self.buttons(reply), "вместо карточки — сразу кнопки отметки")
        self.clock[0] += 11
        self.assertTrue(self.location()["text"].startswith("📍"))
        self.assertTrue(self.location(user=OTHER)["text"].startswith("📍"), "пауза — на человека, не на всех")

    def test_api_down_is_said_and_the_rest_still_shows(self):
        self.api.down = True
        text = self.location()["text"]
        self.assertIn(bot_texts.TEXTS["ru"]["near_live_down"], text)
        self.assertIn("Стационарных камер: 2", text)
        self.assertIn("нет данных", text, "статус метана без API — «нет данных», не «газ есть»")

    def test_near_command_uses_the_last_point(self):
        self.assertEqual(self.text("/near")["text"], bot_texts.TEXTS["ru"]["need_location"])
        self.assertTrue(self.location()["text"].startswith("📍"))
        self.clock[0] += 30
        self.assertTrue(self.text("/near")["text"].startswith("📍"), "точка свежая — ответ по ней")

    def test_one_kdf_per_location(self):
        calls = []
        real = bot._kdf
        bot._kdf = lambda password, salt: (calls.append(1), real(password, salt))[1]
        try:
            self.location()
            self.assertEqual(len(calls), 1)
        finally:
            bot._kdf = real


# --- метан (23.3) -------------------------------------------------------------------------

class MetanTest(Stand):
    def test_list_of_nearest_stations_with_status(self):
        self.text("/metan")
        reply = self.location()
        self.assertEqual(reply["text"], "\n".join([
            "⛽ Ближайшие АГНКС:",
            "1. «АГНКС Чиланзар» — 200 м — газ есть, 15 мин назад",
            "2. «Метан Юг» — 2 км — нет данных",
            "3. «Метан Восток» — 4 км — нет данных",
        ]))
        self.assertEqual(self.buttons(reply), ["cs:0"], "отметить — только у станции в 300 м")

    def test_keyboard_button_text_is_the_metan_command(self):
        self.location()
        self.clock[0] += 21
        self.assertTrue(self.text("⛽ Метан рядом")["text"].startswith("⛽ Ближайшие АГНКС:"))
        self.clock[0] += 21
        self.assertTrue(self.text("⛽ Yaqindagi metan", lang="uz")["text"].startswith("⛽ Eng yaqin AGTKSlar:"),
                        "кнопка понимается на обоих языках")

    def test_mark_status_goes_to_the_station(self):
        self.text("/metan")
        self.location()
        reply = self.tap("cs:0")
        self.assertEqual(reply["text"], bot_texts.TEXTS["ru"]["pick_cng_at"].format(name="АГНКС Чиланзар"))
        self.tap("queue60")
        path, body, _ = self.api.posted[-1]
        self.assertEqual(path, "/api/cng")
        self.assertEqual((body["lat"], body["lon"]), CNG_POINT, "координата колонки, до бита")
        self.assertEqual(body["kind"], "queue60")

    def test_forged_station_number_is_refused(self):
        self.text("/metan")
        self.location()
        self.assertEqual(self.tap("cs:2")["text"], bot_texts.TEXTS["ru"]["expired"],
                         "номер станции, к которой бот не давал кнопки, не принимается")
        self.assertEqual(self.api.posted, [])


# --- трансляция (23.4) ---------------------------------------------------------------------

class LiveTest(Stand):
    def start(self):
        self.location(live=3600)
        self.assertEqual(self.messages()[-2]["text"], bot_texts.TEXTS["ru"]["live_on"])

    def test_only_new_items_ahead_once_a_minute(self):
        self.start()
        sent = len(self.messages())
        self.clock[0] = NOW + 10
        self.live_edit(at(north=50))
        self.clock[0] = NOW + 30
        self.api.mobile.append(report(10, "tripod", at(north=2500), NOW + 20))
        self.api.mobile.append(report(11, "post", at(north=-2500), NOW + 20))       # позади
        self.live_edit(at(north=300))
        self.assertEqual(len(self.messages()), sent, "минуты ещё не прошло")
        self.clock[0] = NOW + 70
        self.live_edit(at(north=600))
        ahead = self.last()["text"]
        self.assertTrue(ahead.startswith("🚗 Впереди по ходу:"), ahead)
        self.assertIn("📷 Тренога — 1,9 км", ahead)
        self.assertNotIn("Пост", ahead, "позади — не впереди")
        self.assertNotIn("1,2 км", ahead.split("\n")[1], "отметка из первой карточки — не новая")
        sent = len(self.messages())
        self.clock[0] = NOW + 140
        self.live_edit(at(north=700))
        self.assertEqual(len(self.messages()), sent, "то же самое второй раз не шлём")

    def test_stationary_camera_ahead_is_announced(self):
        self.start()
        self.clock[0] = NOW + 10
        self.live_edit(at(north=-600))
        self.clock[0] = NOW + 70
        self.live_edit(at(north=-400))
        text = self.last()["text"]
        self.assertIn("📷 1 км — радар, Amir Temur shoh koʻchasi", text)

    def test_still_there_is_asked_once_after_passing(self):
        self.start()
        self.clock[0] = NOW + 10
        self.live_edit(at(north=1150))           # в 50 м от треноги
        self.clock[0] = NOW + 20
        self.live_edit(at(north=1300))           # 100 м — ещё рядом
        self.assertNotIn("ещё стоит", self.last()["text"])
        self.clock[0] = NOW + 30
        self.live_edit(at(north=1400))           # 200 м — уехал
        question = self.last()
        self.assertEqual(question["text"], "Тренога ещё стоит?")
        self.assertEqual(self.buttons(question), ["pv:1:y", "pv:1:n", "pv:1:x"])
        self.clock[0] = NOW + 40
        self.live_edit(at(north=1500))
        self.clock[0] = NOW + 50
        self.live_edit(at(north=1100))           # вернулся и снова уехал
        self.clock[0] = NOW + 60
        self.live_edit(at(north=1500))
        asked = [p for p in self.messages() if p["text"] == "Тренога ещё стоит?"]
        self.assertEqual(len(asked), 1, "спрашиваем один раз")
        self.assertEqual(self.tap("pv:1:y")["text"], bot_texts.TEXTS["ru"]["vote_thanks"])
        path, body, ip = self.api.posted[-1]
        self.assertEqual(path, "/api/vote")
        self.assertEqual(body, {"id": 1, "device": bot.device_for(SALT, USER, NOW), "value": 1, "kind": "pass"})
        self.assertEqual(ip, bot.pseudo_ip_for(SALT, USER, NOW))
        self.assertEqual(self.tap("pv:1:n")["text"], bot_texts.TEXTS["ru"]["vote_gone"], "второй ответ — нет")
        self.assertEqual(len([p for p in self.api.posted if p[0] == "/api/vote"]), 1)

    def test_not_seen_sends_nothing_and_unasked_votes_are_refused(self):
        self.start()
        self.assertEqual(self.tap("pv:2:n")["text"], bot_texts.TEXTS["ru"]["vote_gone"],
                         "о посте не спрашивали — голос не принимается")
        self.clock[0] = NOW + 10
        self.live_edit(at(north=1180))
        self.clock[0] = NOW + 20
        self.live_edit(at(north=1450))
        self.assertEqual(self.tap("pv:1:x")["text"], bot_texts.TEXTS["ru"]["vote_skip"])
        self.assertEqual([p for p in self.api.posted if p[0] == "/api/vote"], [])

    def test_own_report_is_not_asked_about(self):
        self.location(point=at(north=1200))
        self.api.answers["/api/report"] = (200, {"id": 1, "merged": False})
        self.tap("tripod")
        self.clock[0] = NOW + 30
        self.location(live=3600)
        self.clock[0] = NOW + 40
        self.live_edit(at(north=1190))
        self.clock[0] = NOW + 50
        self.live_edit(at(north=1450))
        self.assertNotEqual(self.last()["text"], "Тренога ещё стоит?")

    def test_one_session_per_person_and_it_ends(self):
        self.start()
        first = self.bot.live[bot.user_hash(SALT, USER, NOW)]
        self.clock[0] = NOW + 30
        self.location(live=900)
        self.assertIsNot(self.bot.live[bot.user_hash(SALT, USER, NOW)], first, "новая заменяет старую")
        self.assertEqual(len(self.bot.live), 1)
        self.live_edit(at(north=100), live=None)
        self.assertEqual(self.bot.live, {}, "правка без live_period — трансляцию остановили")
        self.clock[0] = NOW + 60
        self.location(live=900, date=NOW + 60)
        reply = self.text("/stop")
        self.assertIn(bot_texts.TEXTS["ru"]["stop_live"], reply["text"])
        self.assertEqual(self.bot.live, {})
        self.clock[0] = NOW + 5000
        self.live_edit(at(north=200), live=900, date=NOW + 60)
        self.assertEqual(self.bot.live, {}, "после срока трансляции правки не оживляют её")

    def test_stop_is_not_undone_by_the_same_live_location(self):
        self.location(live=3600, date=NOW)
        self.text("/stop")
        sent = len(self.messages())
        self.clock[0] = NOW + 30
        self.live_edit(at(north=100), date=NOW)
        self.assertEqual(self.bot.live, {})
        self.assertEqual(len(self.messages()), sent, "правки остановленной трансляции молчат")
        self.clock[0] = NOW + 60
        self.location(live=600, date=NOW + 60)
        self.assertEqual(len(self.bot.live), 1, "новая трансляция — снова работает")

    def test_mark_during_live_uses_the_current_point(self):
        self.start()
        self.clock[0] = NOW + 30
        self.live_edit(at(north=800))
        self.tap("mark")
        self.tap("post")
        body = self.api.posted[-1][1]
        self.assertEqual((body["lat"], body["lon"]), at(north=800))

    def test_one_kdf_per_live_edit(self):
        self.start()
        calls = []
        real = bot._kdf
        bot._kdf = lambda password, salt: (calls.append(1), real(password, salt))[1]
        try:
            self.clock[0] = NOW + 10
            self.live_edit(at(north=60))
            self.assertEqual(len(calls), 1)
        finally:
            bot._kdf = real


# --- перевалы (23.5) -------------------------------------------------------------------------

def pass_point(pid, group, hazards=(), until=None, t=None, name=("Перевал Камчик", "Qamchiq dovoni")):
    return {"id": pid, "group": group, "kind": "pass", "road": "A373", "lat": 41.1, "lon": 70.5, "r": 5000,
            "name": {"ru": name[0], "uz": name[1]},
            "where": {"ru": "На перевале " + name[0].split()[-1], "uz": name[1].replace(" dovoni", " dovonida")},
            "hazards": [{"k": k, "from": NOW, "to": until or NOW + 3600} for k in hazards],
            "until": until, "t": t, "vis": None}


class PerevalTest(Stand):
    def setUp(self):
        super().setUp()
        self.calm()

    def calm(self, generated=None):
        self.write_weather([pass_point("k1", "kamchik", t=3), pass_point("k2", "kamchik", t=-2),
                            pass_point("t1", "takhtakaracha", t=5, name=("Перевал Тахтакарача", "Taxtaqoracha dovoni")),
                            dict(pass_point("p1", "plain"), kind="plain")], generated)

    def hazard(self, generated=None):
        self.write_weather([pass_point("k1", "kamchik", ("fog",), until=NOW + 3600, t=-2),
                            pass_point("k2", "kamchik", ("ice",), until=NOW + 7200, t=-4),
                            pass_point("t1", "takhtakaracha", t=5, name=("Перевал Тахтакарача", "Taxtaqoracha dovoni"))],
                           generated)

    def test_status_text_and_buttons(self):
        self.hazard()
        reply = self.text("/pereval")
        self.assertEqual(reply["text"], "⛰ Перевалы:\nПеревал Камчик: гололёд, туман до 15:00, −4 °C\n"
                                        "Перевал Тахтакарача: сейчас спокойно, 5 °C")
        self.assertEqual(self.buttons(reply), ["ps:kamchik", "ps:takhtakaracha"])
        uz = self.text("/pereval", user=OTHER, lang="uz")["text"]
        self.assertIn("Qamchiq dovoni: 15:00 gacha yaxmalak, tuman, −4 °C", uz)
        self.write_weather([pass_point("k1", "kamchik", ("fog",))], generated=NOW - 3 * 3600)
        self.assertIn("свежих данных нет", self.text("/pereval")["text"])

    def test_subscription_alerts_on_appear_and_on_clear_once(self):
        self.assertEqual(self.tap("ps:kamchik")["text"],
                         "Готово: напишу, когда на перевале Камчик появится опасность, и когда она уйдёт. "
                         "Подписки — /my\nПеревал Камчик: сейчас спокойно, −2 °C")
        self.assertTrue(self.tap("ps:kamchik", user=OTHER, lang="uz")["text"].startswith(
            "Tayyor: Qamchiq dovonida xavf paydo boʻlganda"))
        pusher = bot_subs.Pusher(self.db_path, bot_subs.box_key(SALT), self.sources, now=lambda: self.clock[0])
        outbox = lambda: [r[0] for r in sqlite3.connect(self.db_path).execute(
            "SELECT text FROM bot_outbox ORDER BY id")]
        self.assertEqual(pusher.pass_step(NOW), 0, "первое наблюдение — только запомнить")
        self.hazard()
        self.assertEqual(pusher.pass_step(NOW + 300), 2, "обоим подписчикам, каждому на своём языке")
        self.assertEqual(outbox(), ["⚠️ Перевал Камчик: гололёд, туман до 15:00, −4 °C. Осторожно на подъёме.",
                                    "⚠️ Qamchiq dovoni: 15:00 gacha yaxmalak, tuman, −4 °C. "
                                    "Koʻtarilishda ehtiyot boʻling."])
        self.assertEqual(pusher.pass_step(NOW + 600), 0, "та же опасность — молчим")
        self.calm()
        self.assertEqual(pusher.pass_step(NOW + 900), 0, "ушла только что — ждём, не перебрасываемся")
        self.hazard()
        self.assertEqual(pusher.pass_step(NOW + 1200), 0, "вернулась до срока — это та же опасность")
        self.calm()
        pusher.pass_step(NOW + 1500)
        self.assertEqual(pusher.pass_step(NOW + 1500 + bot_subs.PASS_CLEAR_HOLD), 2)
        self.assertEqual(outbox()[-2:], ["✅ Перевал Камчик: опасность ушла, −2 °C.",
                                         "✅ Qamchiq dovoni: xavf ketdi, −2 °C."])
        self.calm(generated=NOW - 5 * 3600)
        self.assertEqual(pusher.pass_step(NOW + 9000), 0, "нет свежих данных — не повод писать")

    def test_subscription_stores_no_clear_chat_id(self):
        self.tap("ps:kamchik")
        dump = "\n".join(sqlite3.connect(self.db_path).iterdump())
        self.assertNotIn(str(USER), dump)
        sub = sqlite3.connect(self.db_path).execute("SELECT chat, box FROM bot_subs").fetchone()
        self.assertEqual(sub[0], family_notify.chat_tag(SALT, USER, lambda p, s: bot._kdf(p, s)),
                         "тот же хэш чата, что у близких — /stop один")
        self.assertEqual(family_notify.unseal_key(bot_subs.box_key(SALT), sub[1]), USER)
        self.assertIsNone(family_notify.unseal_key(bot_subs.box_key("чужая соль"), sub[1]))

    def test_subscription_command_costs_two_hashes(self):
        calls = []
        real = bot._kdf
        bot._kdf = lambda password, salt: (calls.append(1), real(password, salt))[1]
        try:
            self.tap("ps:kamchik")
            self.assertEqual(len(calls), 2, "хэш человека (язык) и хэш чата (подписка)")
        finally:
            bot._kdf = real


# --- город (23.6) ---------------------------------------------------------------------------

TASHKENT_CENTER = (41.3111, 69.2797)


class CityTest(Stand):
    def setUp(self):
        super().setUp()
        self.reports_db = os.path.join(self.dir, "reports.db")
        saved = api.DB_PATH
        api.DB_PATH = self.reports_db
        try:
            api.init_db()
        finally:
            api.DB_PATH = saved
        self.pusher = bot_subs.Pusher(self.db_path, bot_subs.box_key(SALT), self.sources,
                                      reports_db=self.reports_db, now=lambda: self.clock[0])

    def add(self, point, kind="tripod", created=NOW - 600, confirm=True):
        conn = sqlite3.connect(self.reports_db)
        rid = conn.execute("INSERT INTO reports(lat, lon, created, expires, device, ip, type, active) "
                           "VALUES(?, ?, ?, ?, 'author-device', '203.0.113.1', ?, 1)",
                           (point[0], point[1], created, created + 6 * 3600, kind)).lastrowid
        if confirm:
            conn.execute("INSERT INTO votes(report_id, device, value, ts, ip, kind) "
                         "VALUES(?, 'other-device', 1, ?, '198.51.100.7', '')", (rid, created + 60))
        conn.commit()
        conn.close()
        return rid

    def outbox(self):
        return [r[0] for r in sqlite3.connect(self.db_path).execute("SELECT text FROM bot_outbox ORDER BY id")]

    def test_pick_and_receive_only_confirmed_tripods_and_posts(self):
        reply = self.text("/city")
        self.assertEqual(self.buttons(reply)[0], "ct:0")
        self.assertEqual(reply["reply_markup"]["inline_keyboard"][0][0]["text"], "Ташкент")
        self.assertIn("Готово: Ташкент", self.tap("ct:0")["text"])
        tripod = self.add(offset(TASHKENT_CENTER, north=500))
        self.add(offset(TASHKENT_CENTER, north=700), confirm=False)               # слух
        self.add(offset(TASHKENT_CENTER, north=900), kind="radar")                # не тренога и не пост
        self.add((39.6542, 66.9597), kind="post")                                 # Самарканд
        self.assertEqual(self.pusher.city_step(NOW), 1)
        text = self.outbox()[0]
        self.assertTrue(text.startswith("📍 Ташкент — подтверждено водителями:"), text)
        self.assertEqual(text.count("Тренога"), 1)
        self.assertNotIn("Радар", text)
        self.assertNotIn("Пост", text)
        self.assertIn("12:50", text, "время — вниз до 5 минут, как в канале")
        for leak in ("author-device", "other-device", "203.0.113", "198.51.100", str(USER)):
            self.assertNotIn(leak, text)
        self.assertRegex(text, r"\d+\.\d{4}, \d+\.\d{4}", "координаты — 4 знака")
        self.assertEqual(self.pusher.city_step(NOW + 60), 0, "уже ушло — второй раз нет")
        sent = sqlite3.connect(self.db_path).execute("SELECT report FROM bot_city_sent").fetchall()
        self.assertEqual(sent, [(tripod,)])

    def test_quiet_hours_hold_until_morning(self):
        self.tap("ct:0")
        night = NOW + 10.5 * 3600                  # 23:30 по Ташкенту
        self.add(offset(TASHKENT_CENTER, north=500), created=night - 600)
        self.clock[0] = night
        self.assertEqual(self.pusher.city_step(night), 0)
        self.assertEqual(self.pusher.city_step(night + 6 * 3600), 0, "05:30 — ещё тихо")
        morning = NOW + 18.1 * 3600                # 07:06
        self.add(offset(TASHKENT_CENTER, north=800), created=morning - 600)
        self.assertEqual(self.pusher.city_step(morning), 1, "утром — то, что ещё стоит")
        self.assertEqual(self.outbox()[0].count("Тренога"), 1, "ночная уже погасла")

    def test_at_most_six_messages_an_hour(self):
        self.tap("ct:0")
        for minute in range(8):
            self.add(offset(TASHKENT_CENTER, north=100 * minute), created=NOW + minute * 60 - 30)
            self.pusher.city_step(NOW + minute * 60)
        self.assertEqual(len(self.outbox()), bot_subs.CITY_HOURLY)
        self.pusher.city_step(NOW + 3601)
        self.assertEqual(len(self.outbox()), bot_subs.CITY_HOURLY + 1, "новый час — то, что ждало, одним сообщением")
        self.assertEqual(self.outbox()[-1].count("Тренога"), 2)

    def test_one_city_per_chat(self):
        self.tap("ct:0")
        self.tap("ct:1")
        rows = sqlite3.connect(self.db_path).execute("SELECT target FROM bot_subs").fetchall()
        self.assertEqual(rows, [("Самарканд",)])

    def test_delivery_goes_through_the_family_courier(self):
        self.tap("ct:0")
        self.add(offset(TASHKENT_CENTER, north=500))
        self.pusher.city_step(NOW)
        sent = []
        courier = family_notify.Courier(lambda m, p: sent.append((m, p)), path=self.db_path, outbox="bot_outbox",
                                        subs="bot_subs", now=lambda: NOW,
                                        sweeper=lambda c, n: bot_subs.sweep(c, n, bot_subs.box_key(SALT)),
                                        extra={"disable_web_page_preview": True})
        courier.step()
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0][1]["chat_id"], USER)
        self.assertTrue(sent[0][1]["disable_web_page_preview"])
        self.assertEqual(self.outbox(), [], "ушло — из очереди прочь")
        self.assertEqual(courier.totals["sent"], 1)


# --- /my, /stop, /stats, отмена (23.7) ----------------------------------------------------------

class MyTest(Stand):
    ADDRESS = api.eta_address("bot-features-my-test-key-0001")

    def setUp(self):
        super().setUp()
        path = os.path.join(self.dir, "family.db")
        family_notify.init_db(path)
        self.family = family_notify.FamilyCommands(family_notify.connect(path), SALT,
                                                   kdf=lambda password, salt: bot._kdf(password, salt))
        self.addCleanup(self.family.conn.close)
        self.bot = self.make()

    def test_list_and_remove_one(self):
        self.assertEqual(self.text("/my")["text"], bot_texts.TEXTS["ru"]["my_none"])
        self.text(f"/start f_{self.ADDRESS}")
        self.tap("ps:kamchik")
        self.tap("ct:0")
        reply = self.text("/my")
        self.assertEqual(reply["text"].split("\n"), ["Ваши подписки:", "👨‍👩‍👧 Близкий водитель — с 15.01",
                                                     "⛰ Перевал Камчик", "🏙 Город: Ташкент"])
        buttons = self.buttons(reply)
        self.assertEqual([b.split(":")[1] for b in buttons], ["f", "b", "b"])
        self.assertEqual(self.tap(buttons[1])["text"], bot_texts.TEXTS["ru"]["removed"])
        self.assertEqual(self.tap(buttons[1])["text"], bot_texts.TEXTS["ru"]["remove_missing"])
        self.assertEqual(self.tap(buttons[0])["text"], bot_texts.TEXTS["ru"]["removed"])
        self.assertEqual(self.text("/my")["text"].split("\n"), ["Ваши подписки:", "🏙 Город: Ташкент"])

    def test_someone_elses_subscription_cannot_be_removed(self):
        self.tap("ct:0", user=OTHER)
        sid = sqlite3.connect(self.db_path).execute("SELECT id FROM bot_subs").fetchone()[0]
        self.assertEqual(self.tap(f"rm:b:{sid}")["text"], bot_texts.TEXTS["ru"]["remove_missing"])
        self.assertEqual(sqlite3.connect(self.db_path).execute("SELECT COUNT(*) FROM bot_subs").fetchone()[0], 1)

    def test_stop_removes_family_and_bot_subscriptions(self):
        self.text(f"/start f_{self.ADDRESS}")
        self.tap("ps:kamchik")
        self.assertEqual(self.text("/stop")["text"], bot_texts.TEXTS["ru"]["stop_done"])
        self.assertEqual(self.text("/my")["text"], bot_texts.TEXTS["ru"]["my_none"])
        self.assertEqual(self.text("/stop")["text"], bot_texts.TEXTS["ru"]["stop_none"])


class StatsTest(Stand):
    def test_only_the_owner_gets_stats(self):
        self.assertEqual(self.text("/stats")["text"], bot_texts.TEXTS["ru"]["start"], "без owner_hash — как неизвестная")
        self.config["owner_hash"] = bot.owner_hash_of(SALT, USER)
        self.assertNotIn(str(USER), self.config["owner_hash"])
        self.location()
        self.tap("tripod")
        stats = self.text("/stats")["text"]
        self.assertTrue(stats.startswith("📊 Бот"), stats)
        self.assertIn("Отметок принято сегодня: 1", stats)
        self.assertIn("«что рядом» 1", stats)
        self.assertEqual(self.text("/stats", user=OTHER)["text"], bot_texts.TEXTS["ru"]["start"])

    def test_owner_hash_is_the_documented_one_liner(self):
        expected = bot._kdf(f"owner|{USER}".encode(), SALT.encode()).hex()
        self.assertEqual(bot.owner_hash_of(SALT, USER), expected)
        if hasattr(hashlib, "scrypt"):
            self.assertEqual(expected, hashlib.scrypt(f"owner|{USER}".encode(), salt=SALT.encode(),
                                                      n=4096, r=8, p=1, dklen=32).hex())
        with open(os.path.join(HERE, "RUNBOOK.md"), encoding="utf-8") as handle:
            runbook = handle.read()
        self.assertIn('f"owner|{i}"', runbook)
        self.assertIn("n=4096,r=8,p=1,dklen=32", runbook)
        self.assertEqual((bot.KDF_N, bot.KDF_R, bot.KDF_P), (4096, 8, 1))
        out = io.StringIO()
        self.assertEqual(bot.print_owner_hash({"salt": SALT}, stream=io.StringIO(f"{USER}\n"), out=out), 0)
        self.assertEqual(out.getvalue().strip(), f"owner_hash={expected}")


class CancelTest(Stand):
    def created(self, rid=77):
        self.api.answers["/api/report"] = (200, {"id": rid, "merged": False})
        self.location()
        return self.tap("radar")

    def test_cancel_within_two_minutes(self):
        reply = self.created()
        self.assertEqual(reply["text"], bot_texts.TEXTS["ru"]["created"])
        self.assertEqual(self.buttons(reply), ["cx:77"])
        self.clock[0] += 100
        self.api.answers["/api/report/cancel"] = (200, {"ok": True})
        self.assertEqual(self.tap("cx:77")["text"], bot_texts.TEXTS["ru"]["cancelled"])
        self.assertEqual(self.api.posted[-1][:2], ("/api/report/cancel",
                                                   {"id": 77, "device": bot.device_for(SALT, USER, NOW)}))
        self.location()
        self.tap("radar")
        self.assertEqual(self.api.posted[-1][0], "/api/report", "отменённая не держит интервал")

    def test_late_or_confirmed_cannot_be_cancelled(self):
        self.created()
        self.clock[0] += bot.CANCEL_WINDOW + 1
        posted = len(self.api.posted)
        self.assertEqual(self.tap("cx:77")["text"], bot_texts.TEXTS["ru"]["cancel_late"])
        self.assertEqual(len(self.api.posted), posted, "поздно — API не спрашиваем")
        self.clock[0] = NOW + 1000
        self.created(rid=78)
        self.api.answers["/api/report/cancel"] = (409, {"error": "confirmed by others"})
        self.assertEqual(self.tap("cx:78")["text"], bot_texts.TEXTS["ru"]["cancel_confirmed"])
        self.assertEqual(self.tap("cx:5", user=OTHER)["text"], bot_texts.TEXTS["ru"]["cancel_late"],
                         "чужую отметку не отменить: её нет среди своих")


class CancelApiTest(unittest.TestCase):
    """Отмена через настоящий API: устройство бота — автор, и путь тот же."""

    def test_real_api_cancels_own_report(self):
        import threading
        from http.server import ThreadingHTTPServer
        work = tempfile.mkdtemp()
        saved = api.DB_PATH, api.TRAFFIC_DB_PATH
        try:
            api.DB_PATH = os.path.join(work, "reports.db")
            api.TRAFFIC_DB_PATH = os.path.join(work, "traffic.db")
            api.init_db()
            api.init_traffic_db()
            server = ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            base = f"http://127.0.0.1:{server.server_address[1]}"
            saved_base = bot.API_BASE
            bot.API_BASE = base
            sent = []
            b = bot.Bot(SALT, bot.open_db(":memory:"), send=lambda m, p: sent.append(p), api_post=bot.api_post)
            try:
                b.handle({"message": {"chat": {"id": 1}, "from": {"id": USER},
                                      "location": {"latitude": 41.33, "longitude": 69.29}}})
                b.handle({"callback_query": {"id": "q", "data": "tripod", "from": {"id": USER},
                                             "message": {"chat": {"id": 1}}}})
                button = sent[-1]["reply_markup"]["inline_keyboard"][0][0]["callback_data"]
                b.handle({"callback_query": {"id": "q", "data": button, "from": {"id": USER},
                                             "message": {"chat": {"id": 1}}}})
                self.assertEqual(sent[-1]["text"], bot_texts.TEXTS["ru"]["cancelled"])
                conn = sqlite3.connect(api.DB_PATH)
                self.assertEqual(conn.execute("SELECT active, closed FROM reports").fetchone(), (0, "author"))
                conn.close()
            finally:
                bot.API_BASE = saved_base
                server.shutdown()
        finally:
            api.DB_PATH, api.TRAFFIC_DB_PATH = saved
            shutil.rmtree(work, ignore_errors=True)


# --- пульт ---------------------------------------------------------------------------------------

class PultTest(Stand):
    def envelope(self, config, path=None):
        import base64
        path = path or os.path.join(self.dir, "config.json")
        payload = json.dumps(config).encode()
        with open(path, "w") as handle:
            json.dump({"payload": base64.b64encode(payload).decode(), "sig": "c2ln"}, handle)
        return path

    def test_signed_off_switch_leaves_only_reporting(self):
        path = self.envelope({"features": {"bot": False}})
        self.pult = bot_near.Pult(path, verify=lambda data, sig: True, clock=lambda: self.clock[0])
        self.bot = self.make()
        reply = self.location()
        self.assertEqual(reply["text"], bot_texts.TEXTS["ru"]["pick"], "выключено — сразу кнопки отметки")
        self.tap("tripod")
        self.assertEqual(self.api.posted[-1][0], "/api/report", "отметки работают всегда")
        for command in ("/metan", "/pereval", "/city", "/near"):
            self.assertEqual(self.text(command)["text"].split("\n")[0], bot_texts.TEXTS["ru"]["off"], command)
        self.assertEqual(self.text("/my")["text"], bot_texts.TEXTS["ru"]["my_none"], "/my — всегда")

    def test_unsigned_broken_or_missing_means_on(self):
        path = self.envelope({"features": {"bot": False}})
        for verify in (lambda d, s: False, lambda d, s: None):
            self.assertTrue(bot_near.Pult(path, verify=verify).enabled())
        self.assertTrue(bot_near.Pult(os.path.join(self.dir, "нет.json")).enabled())
        with open(path, "w") as handle:
            handle.write("{битый")
        self.assertTrue(bot_near.Pult(path, verify=lambda d, s: True).enabled())
        self.assertTrue(bot_near.Pult(self.envelope({"features": {"routing": False}}),
                                      verify=lambda d, s: True).enabled(), "нет ключа — включено")

    def test_publish_config_accepts_the_key(self):
        with open(os.path.join(HERE, "publish_config.sh"), encoding="utf-8") as handle:
            script = handle.read()
        allowed = re.search(r'unknown = set\(features\) - \{([^}]+)\}', script).group(1)
        self.assertIn('"bot"', allowed)

    def test_pusher_is_silent_when_off(self):
        pusher = bot_subs.Pusher(self.db_path, bot_subs.box_key(SALT), self.sources, now=lambda: NOW)
        self.assertEqual(pusher.step(enabled=False), {"pass": 0, "city": 0})


# --- сроки и приватность -------------------------------------------------------------------------

class RetentionTest(Stand):
    def test_sweep_expires_quiet_subscriptions_with_one_goodbye(self):
        self.tap("lang:uz")
        self.tap("ps:kamchik")
        conn = family_notify.connect(self.db_path)
        later = NOW + (bot_subs.KEEP_DAYS + 1) * 86400
        done = bot_subs.sweep(conn, later, bot_subs.box_key(SALT))
        self.assertEqual(done["subs"], 1)
        self.assertEqual(done["prefs"], 1, "язык старше 30 дней — прочь")
        rows = conn.execute("SELECT sub, chat_id, text FROM bot_outbox").fetchall()
        self.assertEqual(rows, [(0, USER, "«Qamchiq dovoni» obunasi tugadi: 55 kun buyruqlaringiz boʻlmadi. "
                                          "Uzaytirish — /pereval")])
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM bot_subs").fetchone()[0], 0)
        conn.close()

    def test_my_keeps_a_used_subscription_alive(self):
        self.tap("ct:0")
        self.clock[0] = NOW + 50 * 86400
        self.text("/my")
        conn = family_notify.connect(self.db_path)
        self.assertEqual(bot_subs.sweep(conn, NOW + 60 * 86400, bot_subs.box_key(SALT))["subs"], 0)
        conn.close()


class RetentionDocTest(unittest.TestCase):
    def test_bot_tables_match_the_doc(self):
        import test_api
        doc = test_api.retention_doc()
        self.assertEqual(test_api.created_tables("bot_subs.py"), set(bot_subs.RETENTION_DAYS))
        for table, days in bot_subs.RETENTION_DAYS.items():
            self.assertEqual(doc.get(table, "нет строки"), days, table)
        self.assertEqual(bot_subs.KEEP_DAYS, api.LIVE_MAX_DAYS)
        self.assertLessEqual(family_notify.OUTBOX_TTL, 86400 * bot_subs.RETENTION_DAYS["bot_outbox"])
        self.assertEqual(bot_subs.PREFS_KEEP_DAYS * 86400, bot.ROTATION_SECONDS)

    def test_tables_with_person_columns_have_a_ceiling(self):
        import test_api
        doc = test_api.retention_doc()
        conn = bot.open_db(":memory:")
        for (table,) in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'"):
            columns = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
            if columns & {"who", "chat", "chat_id", "box", "sub"}:
                self.assertIsInstance(doc.get(table), int, f"{table}: поля человека без срока")


class PrivacyTest(Stand):
    def test_no_location_or_id_in_logs_or_bot_db(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.location()
            self.clock[0] += 30
            self.api.down = True
            self.location(live=3600)
            self.api.down = False
            self.clock[0] += 30
            self.live_edit(at(north=1150))
            self.clock[0] += 30
            self.live_edit(at(north=1400))
            self.tap("pv:1:y")
            self.text("/metan")
            self.tap("ps:kamchik")
            self.tap("ct:0")
            self.tap("lang:uz")
            os.remove(self.cameras_path)
            self.bot.sources.cameras._checked = None
            self.clock[0] += 100
            self.location(user=OTHER)
        journal = stderr.getvalue()
        self.assertTrue(journal, "сбои пишутся")
        for point in (HOME, at(north=1150), at(north=1400)):
            for value in point:
                for digits in (3, 4, 5):
                    self.assertNotIn(f"{value:.{digits}f}", journal)
        for leak in (str(USER), str(OTHER)):
            self.assertNotIn(leak, journal)
        dump = "\n".join(sqlite3.connect(self.db_path).iterdump())
        for leak in (str(USER), str(OTHER), f"{HOME[0]:.4f}", f"{HOME[1]:.4f}", f"{HOME[0]:.3f}"):
            self.assertNotIn(leak, dump)

    def test_memory_holds_hashes_not_ids(self):
        self.location(live=3600)
        memory = json.dumps([list(self.bot.pending), list(self.bot.live), list(self.bot.data_at)])
        self.assertNotIn(str(USER), memory)


if __name__ == "__main__":
    unittest.main(verbosity=2)
