#!/usr/bin/env python3
"""Тесты Telegram-бота отметок (12б.7, аудит 14.3): соль и ротация хэша,
scrypt и его цена, лимиты (в счёт — только принятое, интервал — как у API),
поток «геопозиция → тип → API», метан на точке АГНКС из файла заведений
(ключ станции — как у телефона), испытательный срок через настоящий API
(свой повтор не подтверждает, другой человек — подтверждает), и главное —
Telegram-id нет ни в базе бота, ни в базе отметок. Близкие (22.3): /start
f_<адрес> и /stop уходят в подписки, остальное — как было. Без сети.

Запуск: python3 server/test_telegram_bot.py
"""
import hashlib
import json
import math
import os
import re
import sqlite3
import statistics
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import api
import build_roads
import family_notify
import telegram_bot as bot

USER = 987654321
OTHER = 123456789
SALT = "test-salt-0123456789abcdef"
NOW = 1_800_000_000.0
HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(os.path.dirname(HERE), "RadarMap")

HAS_SCRYPT = hasattr(hashlib, "scrypt")
if not HAS_SCRYPT:
    # Системный python3 мака собран с LibreSSL, scrypt в нём нет (на сервере —
    # есть, им же хэширует пароли панель). Логику вокруг хэша проверяем на
    # подмене той же формы; сам scrypt — тестами ниже, там, где он есть.
    bot._kdf = lambda password, salt: hashlib.sha256(salt + b"|" + password).digest()

# АГНКС у Чиланзара. Координаты выбраны с умыслом: у 4130005 и 6928025
# умножение на 1e-5 даёт ДРУГОЙ ключ станции, чем деление на 1e5 (41.3001 вместо
# 41.3000) — телефон делит (VenueBook.decode), и бот обязан делить так же.
CNG_LAT_E5, CNG_LON_E5 = 4130005, 6928025
CNG_POINT = (CNG_LAT_E5 / 1e5, CNG_LON_E5 / 1e5)


def offset(point, north=0.0, east=0.0):
    """Точка в `north`/`east` метрах от `point`."""
    lat, lon = point
    return (lat + north / 111_320.0, lon + east / (111_320.0 * math.cos(math.radians(lat))))


def write_venues(directory, rows):
    """Файлы заведений тем же кодом, что на сервере (build_roads.venues_by_cell
    и имя файла из write_tiles): контракт проверяется от производителя."""
    os.makedirs(directory, exist_ok=True)
    for key, payload in build_roads.venues_by_cell(rows).items():
        name = f"road2_{key}_{build_roads.SET_VENUES}.json"
        with open(os.path.join(directory, name), "wb") as handle:
            handle.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode())


def standard_venues(directory):
    """АГНКС; в 20 м от «пропановой точки» — пропан и бензин, но не метан."""
    lpg = offset(CNG_POINT, north=300)
    write_venues(directory, [
        (build_roads.VENUE_CNG, "АГНКС Чиланзар", CNG_POINT[1], CNG_POINT[0]),
        (build_roads.VENUE_LPG, "Пропан", lpg[1], lpg[0]),
        (1, "Бензин", offset(lpg, east=15)[1], offset(lpg, east=15)[0]),
    ])
    return lpg


class HashTest(unittest.TestCase):
    def test_device_rotates_and_hides_the_id(self):
        device = bot.device_for(SALT, USER, NOW)
        self.assertEqual(device, bot.device_for(SALT, USER, NOW + 3600), "то же окно — то же устройство")
        self.assertNotEqual(device, bot.device_for(SALT, USER, NOW + bot.ROTATION_SECONDS),
                            "через 30 дней — другое")
        self.assertNotEqual(device, bot.device_for("other-salt", USER, NOW), "без соли сервера не подобрать")
        self.assertNotIn(str(USER), device)
        self.assertNotEqual(bot.pseudo_ip_for(SALT, USER, NOW), bot.pseudo_ip_for(SALT, OTHER, NOW))
        self.assertEqual(bot.pseudo_ip_for(SALT, USER, NOW), bot.pseudo_ip_for(SALT, USER, NOW + 3600),
                         "адрес тоже стабилен внутри окна — иначе капы API на человека разваливаются")

    @unittest.skipUnless(HAS_SCRYPT, "в этом Python нет hashlib.scrypt")
    def test_hash_is_scrypt_not_bruteforceable_sha256(self):
        """N6: соль лежит на том же VPS, id — ~10^10 чисел подряд. sha256
        перебирается за час одного ядра, scrypt — за годы на окно."""
        window = bot.period(NOW)
        expected = hashlib.scrypt(f"{USER}|{window}".encode(), salt=SALT.encode(),
                                  n=bot.KDF_N, r=bot.KDF_R, p=bot.KDF_P, dklen=32).hex()
        self.assertEqual(bot.user_hash(SALT, USER, NOW), expected)
        self.assertNotEqual(bot.user_hash(SALT, USER, NOW),
                            hashlib.sha256(f"{SALT}|{USER}|{window}".encode()).hexdigest())
        self.assertGreaterEqual(bot.KDF_N, 1 << 12, "дешевле — перебор снова в часах")
        self.assertLessEqual(128 * bot.KDF_N * bot.KDF_R, 32 << 20,
                             "в предел памяти OpenSSL по умолчанию — без maxmem")

    @unittest.skipUnless(HAS_SCRYPT, "в этом Python нет hashlib.scrypt")
    def test_kdf_cost_per_message_fits_budget(self):
        """Хэш считается на каждое сообщение: бюджет 50 мс на маленьком VPS.
        Здесь — не больше половины: сервер медленнее рабочей машины."""
        costs = []
        for step in range(5):
            started = time.perf_counter()
            bot.user_hash(SALT, USER + step, NOW)
            costs.append(time.perf_counter() - started)
        self.assertLess(statistics.median(costs), 0.025, f"scrypt {statistics.median(costs) * 1000:.1f} мс")

    def test_one_kdf_per_update(self):
        """Устройство и адрес — срезы одного хэша: на сообщение или нажатие
        scrypt считается ровно один раз, а не три."""
        calls = []
        real = bot._kdf
        bot._kdf = lambda password, salt: (calls.append(1), real(password, salt))[1]
        try:
            directory = tempfile.mkdtemp()
            standard_venues(directory)
            b = bot.Bot(SALT, bot.open_db(":memory:"), send=lambda m, p: None,
                        api_post=lambda path, body, ip: (200, {"id": 1, "merged": False, "ok": True}),
                        now=lambda: NOW, venues=bot.CngVenues(directory, logger=lambda text: None))
            near = offset(CNG_POINT, east=20)
            for update in ({"message": {"chat": {"id": 1}, "from": {"id": USER},
                                        "location": {"latitude": near[0], "longitude": near[1]}}},
                           {"callback_query": {"id": "q", "data": "cng", "from": {"id": USER},
                                               "message": {"chat": {"id": 1}}}},
                           {"callback_query": {"id": "q", "data": "gas", "from": {"id": USER},
                                               "message": {"chat": {"id": 1}}}}):
                calls.clear()
                b.handle(update)
                self.assertEqual(len(calls), 1, f"хэшей на обновление: {len(calls)}")
        finally:
            bot._kdf = real


class LimitsTest(unittest.TestCase):
    def setUp(self):
        self.db = bot.open_db(":memory:")
        self.who = bot.user_hash(SALT, USER, NOW)

    def test_daily_cap_counts_only_what_was_counted(self):
        self.assertFalse(bot.limit_reached(self.db, self.who, NOW))
        self.assertFalse(bot.limit_reached(self.db, self.who, NOW), "проверка сама не считает")
        for _ in range(bot.BOT_DAILY_REPORTS):
            bot.count_accepted(self.db, self.who, NOW)
        self.assertTrue(bot.limit_reached(self.db, self.who, NOW))
        self.assertFalse(bot.limit_reached(self.db, self.who, NOW + 86400), "назавтра — заново")

    def test_old_counters_go_even_when_nobody_reports(self):
        """Счётчик — хэш человека и день. Чистка только при новой отметке
        оставила бы хэши последних людей молчащему боту навсегда; цикл бота
        зовёт prune_limits раз в час (RETENTION.md: 3 суток)."""
        old = NOW - (bot.BOT_LIMITS_KEEP_DAYS + 2) * 86400
        bot.count_accepted(self.db, self.who, old)
        bot.count_accepted(self.db, "fresh", NOW - 3600)
        bot.prune_limits(self.db, NOW)
        left = [row[0] for row in self.db.execute("SELECT who FROM bot_limits")]
        self.assertEqual(left, ["fresh"])

    def test_interval_is_the_api_rule(self):
        """N9: у API 120 с между отметками одной категории. Бот держал 60 —
        и тап через 61–119 с упирался в 429."""
        self.assertEqual(bot.BOT_MIN_INTERVAL, 120)
        mine = [(NOW, "radar", 1)]
        self.assertTrue(bot.too_soon(mine, "radar", NOW + 61))
        self.assertTrue(bot.too_soon(mine, "radar", NOW + 119))
        self.assertFalse(bot.too_soon(mine, "radar", NOW + 120))
        self.assertFalse(bot.too_soon([], "radar", NOW))

    def test_retype_of_own_report_is_left_to_the_api(self):
        """Другой тип рядом со своей свежей — уточнение (amend), и API пускает
        его в обход интервала: бот не вправе отказать за API."""
        mine = [(NOW, "radar", 1)]
        self.assertFalse(bot.too_soon(mine, "tripod", NOW + 30))
        self.assertFalse(bot.too_soon(mine + [(NOW + 5, "tripod", 2)], "tripod", NOW + 30),
                         "среди своих свежих есть радар — tripod может уточнить его")

    def test_categories_follow_the_api(self):
        self.assertEqual(bot.category_of("closure"), "road")
        self.assertEqual(bot.category_of("radar"), "camera")
        self.assertEqual(bot.ROAD_TYPES, api.ROAD_TYPES)
        self.assertEqual(bot.AMEND_WINDOW, api.AMEND_WINDOW)


class VenueContractTest(unittest.TestCase):
    """Бот читает те же файлы, что телефон, и обязан получить ту же
    координату до бита — иначе ключ станции у сервера другой."""

    def read(self, *parts):
        path = os.path.join(APP, *parts)
        if not os.path.exists(path):
            self.skipTest("исходников приложения рядом нет")
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def test_constants_match_the_producer(self):
        self.assertEqual(bot.VENUE_CNG, build_roads.VENUE_CNG)
        self.assertEqual(bot.VENUE_SCALE, build_roads.SCALE)
        self.assertEqual(bot.VENUE_CELL_DEGREES, build_roads.ADDRESS_DEGREES)
        self.assertEqual(bot.venue_cell(*CNG_POINT), build_roads.address_key(*CNG_POINT))

    def test_constants_match_the_phone(self):
        self.assertIn("case hotel = 11, cng = 12", self.read("Models", "VenueBook.swift"))
        venue_book = self.read("Models", "VenueBook.swift")
        self.assertIn("latitude: lat / RoadTiles.scale", venue_book, "телефон делит — и бот делит")
        self.assertRegex(self.read("Models", "RoadTiles.swift"), r"static let scale = 1e5\b")
        self.assertRegex(self.read("Models", "AddressBook.swift"), r"static let cellDegrees = 0\.5\b")
        ask = re.search(r"static let cngAskMeters = ([\d.]+)", self.read("Support", "AppConfig.swift"))
        self.assertEqual(float(ask.group(1)), bot.CNG_SNAP_METERS, "радиус вопроса приложения")

    def test_coordinate_is_bit_identical_to_the_phone(self):
        directory = tempfile.mkdtemp()
        standard_venues(directory)
        venue = bot.CngVenues(directory).nearest(*offset(CNG_POINT, east=30))
        self.assertEqual((venue[0], venue[1]), (CNG_LAT_E5 / 1e5, CNG_LON_E5 / 1e5))
        self.assertEqual(api.cng_station_key(venue[0], venue[1]), "41.3000,69.2802")
        self.assertNotEqual(api.cng_station_key(CNG_LAT_E5 * 1e-5, CNG_LON_E5 * 1e-5), "41.3000,69.2802",
                            "проверка не пустая: умножение дало бы другую станцию")


class VenueSourceTest(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.join(tempfile.mkdtemp(), "roads")
        self.logs = []

    def venues(self):
        return bot.CngVenues(self.dir, logger=self.logs.append)

    def test_venue_across_the_cell_border_is_found(self):
        """Клетка кончается на 41,5°: колонка через дорогу — в соседнем файле."""
        station = (41.50020, 69.28000)
        write_venues(self.dir, [(12, "АГНКС на границе", station[1], station[0])])
        here = (41.49990, 69.28000)
        self.assertNotEqual(bot.venue_cell(*here), bot.venue_cell(*station))
        venue = self.venues().nearest(*here)
        self.assertIsNotNone(venue)
        self.assertEqual(venue[2], "АГНКС на границе")

    def test_only_cng_within_60_m(self):
        lpg = standard_venues(self.dir)
        venues = self.venues()
        self.assertIsNone(venues.nearest(*lpg), "пропан и бензин — не метан")
        self.assertIsNone(venues.nearest(*offset(CNG_POINT, east=75)), "75 м — уже не у колонки")
        self.assertIsNotNone(venues.nearest(*offset(CNG_POINT, east=55)))

    def test_missing_source_fails_closed_and_logs_once(self):
        venues = self.venues()
        for _ in range(3):
            with self.assertRaises(bot.VenueSourceError):
                venues.nearest(*CNG_POINT)
        self.assertEqual(len(self.logs), 1, self.logs)
        os.makedirs(self.dir)
        with self.assertRaises(bot.VenueSourceError, msg="каталог без файлов заведений — не источник"):
            venues.nearest(*CNG_POINT)
        self.assertEqual(len(self.logs), 2)
        standard_venues(self.dir)
        stamp = os.stat(self.dir).st_mtime_ns
        os.utime(self.dir, ns=(stamp, stamp + 1_000_000_000))   # на грубых часах ФС — тоже новый
        self.assertIsNotNone(venues.nearest(*CNG_POINT), "источник поправился — метан снова принимаем")

    def test_broken_file_fails_closed(self):
        standard_venues(self.dir)
        path = os.path.join(self.dir, f"road2_{bot.venue_cell(*CNG_POINT)}_v.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("{не json")
        venues = self.venues()
        for _ in range(2):
            with self.assertRaises(bot.VenueSourceError):
                venues.nearest(*CNG_POINT)
        self.assertEqual(len(self.logs), 1)

    def test_changed_file_is_reloaded(self):
        standard_venues(self.dir)
        venues = self.venues()
        self.assertEqual(venues.nearest(*CNG_POINT)[2], "АГНКС Чиланзар")
        moved = offset(CNG_POINT, north=40)
        path = os.path.join(self.dir, f"road2_{bot.venue_cell(*CNG_POINT)}_v.json")
        stat = os.stat(path)
        write_venues(self.dir, [(12, "АГНКС Чиланзар (перенесена)", moved[1], moved[0])])
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
        venue = venues.nearest(*CNG_POINT)
        self.assertEqual(venue[2], "АГНКС Чиланзар (перенесена)")


class FlowTest(unittest.TestCase):
    """Логика бота с подменённой сетью."""

    def setUp(self):
        self.sent = []
        self.posted = []
        self.answer = (200, {"id": 1, "merged": False})
        self.db = bot.open_db(":memory:")
        self.clock = [NOW]
        self.venue_dir = tempfile.mkdtemp()
        self.lpg = standard_venues(self.venue_dir)
        self.logs = []
        self.bot = bot.Bot(SALT, self.db, send=lambda m, p: self.sent.append((m, p)),
                           api_post=lambda path, body, ip: (self.posted.append((path, body, ip)), self.answer)[1],
                           now=lambda: self.clock[0],
                           venues=bot.CngVenues(self.venue_dir, logger=self.logs.append))

    def location(self, user=USER, point=(41.31, 69.28)):
        self.bot.handle({"message": {"chat": {"id": 1}, "from": {"id": user},
                                     "location": {"latitude": point[0], "longitude": point[1]}}})

    def tap(self, data, user=USER):
        self.bot.handle({"callback_query": {"id": "q", "data": data, "from": {"id": user},
                                            "message": {"chat": {"id": 1}}}})

    def text(self):
        return self.sent[-1][1]["text"]

    def counted(self, user=USER):
        return bot.daily_count(self.db, bot.user_hash(SALT, user, self.clock[0]), self.clock[0])

    def test_location_then_type_goes_to_api(self):
        self.location()
        self.assertIn("reply_markup", self.sent[-1][1], "после геопозиции — кнопки типов")
        self.tap("tripod")
        path, body, ip = self.posted[-1]
        self.assertEqual(path, "/api/report")
        self.assertEqual(body["type"], "tripod")
        self.assertEqual(body["device"], bot.device_for(SALT, USER, NOW))
        self.assertEqual(ip, bot.pseudo_ip_for(SALT, USER, NOW))
        self.assertNotIn(str(USER), json.dumps(body) + ip, "id не уходит в API")
        self.assertEqual(self.text(), bot.TEXTS["created"])
        self.assertEqual(self.counted(), 1)

    def test_cng_is_posted_at_the_venue_not_at_the_person(self):
        """N3: своя точка человека — другая станция; отметка бота не сливалась
        с отметками приложения у той же колонки."""
        here = offset(CNG_POINT, north=25, east=20)
        self.location(point=here)
        self.tap("cng")
        self.assertEqual(self.text(), bot.TEXTS["pick_cng_at"].format(name="АГНКС Чиланзар"))
        self.tap("nogas")
        path, body, _ = self.posted[-1]
        self.assertEqual(path, "/api/cng")
        self.assertEqual(body["kind"], "nogas")
        self.assertEqual((body["lat"], body["lon"]), CNG_POINT, "координата колонки, до бита")
        self.assertEqual(api.cng_station_key(body["lat"], body["lon"]), api.cng_station_key(*CNG_POINT))
        self.assertNotEqual(api.cng_station_key(body["lat"], body["lon"]), api.cng_station_key(*here))
        self.assertEqual(self.text(), bot.TEXTS["cng_ok"])

    def test_cng_without_a_station_nearby_is_refused_and_not_counted(self):
        self.location(point=self.lpg)
        self.tap("cng")
        self.assertEqual(self.text(), bot.TEXTS["cng_far"])
        self.assertEqual(self.text(), "Рядом нет заправки метаном в нашей базе — "
                                      "отправьте геопозицию у самой колонки.")
        self.tap("gas")   # callback_data присылает клиент — второй ряд мог прийти и без первого
        self.assertEqual(self.text(), bot.TEXTS["cng_far"])
        self.assertEqual(self.posted, [])
        self.assertEqual(self.counted(), 0, "отказ — не в суточный лимит")
        self.tap("radar")
        self.assertEqual(self.posted[-1][0], "/api/report", "точка осталась — можно отметить другое")

    def test_cng_without_a_venue_source_fails_closed(self):
        broken = bot.Bot(SALT, self.db, send=lambda m, p: self.sent.append((m, p)),
                         api_post=lambda path, body, ip: (self.posted.append((path, body, ip)), self.answer)[1],
                         now=lambda: self.clock[0],
                         venues=bot.CngVenues(os.path.join(self.venue_dir, "нет"), logger=self.logs.append))
        point = offset(CNG_POINT, east=10)
        broken.handle({"message": {"chat": {"id": 1}, "from": {"id": USER},
                                   "location": {"latitude": point[0], "longitude": point[1]}}})
        for data in ("cng", "gas"):
            broken.handle({"callback_query": {"id": "q", "data": data, "from": {"id": USER},
                                              "message": {"chat": {"id": 1}}}})
            self.assertEqual(self.text(), bot.TEXTS["cng_unavailable"])
        self.assertEqual(self.posted, [])
        self.assertEqual(len(self.logs), 1, "в журнал — один раз")
        self.assertEqual(self.counted(), 0)

    def test_second_tap_inside_the_api_interval_is_slow_without_asking_the_api(self):
        """N9: раньше тап через 90 с проходил свои 60 с и получал 429 от API."""
        self.location()
        self.tap("radar")
        self.clock[0] = NOW + 90
        self.location()
        self.tap("radar")
        self.assertEqual(len(self.posted), 1, "заведомый 429 не тратит кап адреса в API")
        self.assertEqual(self.text(), bot.TEXTS["slow"])
        self.assertTrue(self.text().startswith("Не так часто"))
        self.assertEqual(self.counted(), 1)
        self.clock[0] = NOW + bot.BOT_MIN_INTERVAL
        self.tap("radar")
        self.assertEqual(len(self.posted), 2, "точка дождалась — та же кнопка работает")
        self.assertEqual(self.counted(), 2)

    def test_api_refusal_says_not_so_often_and_is_not_counted(self):
        """N9: 429 — «Не так часто», а не «не получилось», и не в счёт."""
        self.answer = (429, {"error": "too fast"})
        self.location()
        self.tap("radar")
        self.assertEqual(self.text(), bot.TEXTS["slow"])
        self.assertEqual(self.counted(), 0)
        self.answer = (429, {"error": "too many active reports"})
        self.tap("radar")
        self.assertEqual(self.text(), bot.TEXTS["busy"])
        self.assertTrue(self.text().startswith("Не так часто"))
        self.answer = (500, {})
        self.tap("radar")
        self.assertEqual(self.text(), bot.TEXTS["error"])
        self.assertEqual(self.counted(), 0, "в счёт — только 200")
        self.answer = (200, {"id": 5, "merged": False})
        self.tap("radar")
        self.assertEqual(self.text(), bot.TEXTS["created"], "точка пережила отказы")
        self.assertEqual(self.counted(), 1)

    def test_cng_refusal_is_not_counted_either(self):
        self.answer = (429, {"error": "too many"})
        self.location(point=offset(CNG_POINT, east=10))
        self.tap("gas")
        self.assertEqual(self.posted[-1][0], "/api/cng")
        self.assertTrue(self.text().startswith("Не так часто"))
        self.assertEqual(self.counted(), 0)

    def test_retype_inside_the_interval_reaches_the_api(self):
        """Ошибся типом — отправил точку ещё раз с другим: API уточняет свою
        отметку (amend) в обход интервала, и бот не отказывает за него."""
        self.answer = (200, {"id": 7, "merged": False})
        self.location()
        self.tap("radar")
        self.clock[0] = NOW + 30
        self.answer = (200, {"id": 7, "merged": True, "amended": True})
        self.location()
        self.tap("tripod")
        self.assertEqual(len(self.posted), 2)
        self.assertEqual(self.text(), bot.TEXTS["amended"])
        self.clock[0] = NOW + 60
        self.location()
        self.tap("tripod")
        self.assertEqual(len(self.posted), 2, "тот же тип после уточнения — заведомый 429")
        self.assertEqual(self.text(), bot.TEXTS["slow"])

    def test_categories_and_merges_do_not_share_the_interval(self):
        self.location()
        self.tap("radar")
        self.clock[0] = NOW + 10
        self.location()
        self.tap("closure")
        self.assertEqual(len(self.posted), 2, "события дороги — своя категория, как в API")
        self.clock[0] = NOW + 20
        self.location(point=offset(CNG_POINT, east=10))
        self.tap("gas")
        self.assertEqual(len(self.posted), 3, "у метана интервала нет и в API")
        self.clock[0] = NOW + 40
        self.answer = (200, {"id": 9, "merged": True})
        self.location(user=OTHER)
        self.tap("tripod", user=OTHER)
        self.clock[0] = NOW + 70
        self.location(user=OTHER)
        self.tap("tripod", user=OTHER)
        self.assertEqual(len(self.posted), 5, "голос в чужую отметку интервал не начинает")

    def test_daily_cap(self):
        for step in range(bot.BOT_DAILY_REPORTS):
            self.clock[0] = NOW + step * (bot.BOT_MIN_INTERVAL + 1)
            self.location()
            self.tap("radar")
        self.assertEqual(len(self.posted), bot.BOT_DAILY_REPORTS)
        self.clock[0] += bot.BOT_MIN_INTERVAL + 1
        self.location()
        self.tap("radar")
        self.assertEqual(len(self.posted), bot.BOT_DAILY_REPORTS)
        self.assertEqual(self.text(), bot.TEXTS["limit"])

    def test_type_without_fresh_point_is_refused(self):
        self.tap("radar")
        self.assertEqual(self.posted, [])
        self.assertEqual(self.text(), bot.TEXTS["expired"])
        self.location()
        self.clock[0] += bot.PENDING_TTL + 1
        self.tap("radar")
        self.assertEqual(self.posted, [], "точка старше 10 минут забыта")

    def test_no_raw_id_in_memory_after_handling(self):
        self.location()
        self.tap("radar")
        self.location()
        self.assertNotIn(USER, self.bot.pending)
        memory = json.dumps([list(self.bot.pending.keys()), self.bot.recent])
        self.assertNotIn(str(USER), memory)


class ApiIntegrationTest(unittest.TestCase):
    """Через настоящий API: свой повтор не подтверждает отметку, другой
    пользователь бота — подтверждает; интервал бота — интервал API; метан
    бота попадает в станцию телефона; в базе отметок нет Telegram-id."""

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
        cls.venue_dir = os.path.join(cls.dir, "roads")
        standard_venues(cls.venue_dir)

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
            return error.code, bot._json_or_empty(error.read())

    def make(self, salt_db=":memory:", sent=None):
        return bot.Bot(SALT, bot.open_db(salt_db),
                       send=lambda m, p: sent.append(p) if sent is not None else None,
                       api_post=self.post, venues=bot.CngVenues(self.venue_dir))

    @staticmethod
    def report(b, user, point, data, chat=1):
        b.handle({"message": {"chat": {"id": chat}, "from": {"id": user},
                              "location": {"latitude": point[0], "longitude": point[1]}}})
        b.handle({"callback_query": {"id": "q", "data": data, "from": {"id": user},
                                     "message": {"chat": {"id": chat}}}})

    def test_own_repeat_does_not_confirm_other_user_does(self):
        api._probation_cache = (time.time(), True)
        try:
            first = self.make()
            self.report(first, USER, (41.33, 69.29), "radar")
            conn = sqlite3.connect(api.DB_PATH)
            rid = conn.execute("SELECT id FROM reports WHERE type = 'radar'").fetchone()[0]
            # Мимо интервала (и своего, и API): повтор должен дойти до слияния,
            # иначе проверять «свой голос не в счёт» было бы нечем.
            conn.execute("UPDATE reports SET created = created - ?", (bot.BOT_MIN_INTERVAL + 1,))
            conn.commit()
            first.recent.clear()
            self.report(first, USER, (41.33, 69.29), "radar")
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM votes WHERE report_id = ?", (rid,)).fetchone()[0],
                             1, "повтор дошёл и слился голосом")
            self.assertFalse(api.confirmed_independently(conn, rid, bot.device_for(SALT, USER, time.time()),
                                                         bot.pseudo_ip_for(SALT, USER, time.time())),
                             "свой повтор — не подтверждение")
            other = self.make()
            self.report(other, OTHER, (41.33, 69.29), "radar", chat=2)
            self.assertTrue(api.confirmed_independently(conn, rid, bot.device_for(SALT, USER, time.time()),
                                                        bot.pseudo_ip_for(SALT, USER, time.time())),
                            "другой человек — независимое подтверждение")
            dump = "\n".join(conn.iterdump())
            conn.close()
            self.assertNotIn(str(USER), dump, "в базе отметок нет Telegram-id")
            self.assertNotIn(str(OTHER), dump)
        finally:
            api._probation_cache = (0.0, None)

    def test_bot_interval_is_the_api_interval(self):
        """N9 на настоящем API: своя отметка моложе BOT_MIN_INTERVAL — API
        отказывает, бот говорит «Не так часто» и не считает; старше — API
        принимает. Сменит API интервал — этот тест скажет."""
        sent = []
        b = self.make(sent=sent)
        device = bot.device_for(SALT, USER, time.time())
        ip = bot.pseudo_ip_for(SALT, USER, time.time())
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, ip, active) "
                     "VALUES(41.20, 69.20, ?, ?, ?, 'radar', ?, 1)",
                     (now - (bot.BOT_MIN_INTERVAL - 5), now + 3600, device, ip))
        conn.commit()
        self.report(b, USER, (41.33, 69.29), "radar")
        self.assertEqual(sent[-1]["text"], bot.TEXTS["slow"])
        self.assertEqual(bot.daily_count(b.db, bot.user_hash(SALT, USER, time.time()), time.time()), 0)
        conn.execute("UPDATE reports SET created = ?", (time.time() - (bot.BOT_MIN_INTERVAL + 1),))
        conn.commit()
        b.handle({"callback_query": {"id": "q", "data": "radar", "from": {"id": USER},
                                     "message": {"chat": {"id": 1}}}})
        self.assertEqual(sent[-1]["text"], bot.TEXTS["created"], "та же кнопка, точка дождалась")
        self.assertEqual(bot.daily_count(b.db, bot.user_hash(SALT, USER, time.time()), time.time()), 1)
        conn.close()

    def test_bot_cng_joins_the_phone_station(self):
        """N3 на настоящем API: телефон отвечает в точке заведения из своего
        файла, человек в Telegram — в 30 м от колонки. Одна станция, и
        независимый ответ бота подтверждает ответ телефона."""
        status, _ = self.post("/api/cng", {"lat": CNG_LAT_E5 / 1e5, "lon": CNG_LON_E5 / 1e5,
                                           "kind": "gas", "device": "phone-uuid-0001"}, "10.1.2.3")
        self.assertEqual(status, 200)
        b = self.make()
        here = offset(CNG_POINT, north=-20, east=22)
        b.handle({"message": {"chat": {"id": 1}, "from": {"id": USER},
                              "location": {"latitude": here[0], "longitude": here[1]}}})
        for data in ("cng", "gas"):
            b.handle({"callback_query": {"id": "q", "data": data, "from": {"id": USER},
                                         "message": {"chat": {"id": 1}}}})
        with urllib.request.urlopen(self.base + "/api/cng", timeout=5) as response:
            stations = json.loads(response.read())["stations"]
        self.assertEqual(len(stations), 1, stations)
        self.assertEqual(stations[0]["status"], "gas")
        self.assertTrue(stations[0]["confirmed"], "бот и телефон — независимые водители у одной колонки")

    def test_bot_db_holds_no_id(self):
        path = os.path.join(self.dir, "bot.db")
        b = self.make(path)
        self.report(b, USER, (41.35, 69.30), "post")
        b.db.close()
        with open(path, "rb") as handle:
            self.assertNotIn(str(USER).encode(), handle.read())


class FamilyRoutingTest(unittest.TestCase):
    """22.3: команды близких — до разбора отметок; геопозиция, кнопки и
    приветствие работают как раньше. Логика подписок — test_family_notify."""

    ADDRESS = api.eta_address("family-routing-test-key-0001")

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "family.db")
        family_notify.init_db(self.path)
        self.sent = []
        self.family = family_notify.FamilyCommands(family_notify.connect(self.path), SALT,
                                                   kdf=lambda password, salt: bot._kdf(password, salt))
        self.bot = self.make(self.family)

    def tearDown(self):
        self.family.conn.close()

    def make(self, family):
        return bot.Bot(SALT, bot.open_db(":memory:"), send=lambda m, p: self.sent.append(p),
                       api_post=lambda path, body, ip: (500, {}), now=lambda: NOW, family=family)

    def message(self, text, lang="ru", target=None, user=USER):
        (target or self.bot).handle({"message": {"chat": {"id": user}, "from": {"id": user, "language_code": lang},
                                                 "text": text}})
        return self.sent[-1]["text"]

    def test_deep_link_subscribes_and_stop_unsubscribes(self):
        self.assertEqual(self.message(f"/start f_{self.ADDRESS}"), family_notify.REPLIES["ru"]["subscribed"])
        self.assertEqual(self.message(f"/start f_{self.ADDRESS}", lang="uz", user=OTHER),
                         family_notify.REPLIES["uz"]["subscribed"])
        self.assertEqual(self.message("/stop"), family_notify.REPLIES["ru"]["stopped"])
        conn = sqlite3.connect(self.path)
        try:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM family_subs").fetchone()[0], 1)
            dump = "\n".join(conn.iterdump())
        finally:
            conn.close()
        self.assertNotIn(str(OTHER), dump, "номер чата в подписке — только зашифрованным")

    def test_bad_family_link_is_answered_not_greeted(self):
        self.assertEqual(self.message("/start f_broken"), family_notify.REPLIES["ru"]["bad_link"])

    def test_other_text_still_gets_the_greeting(self):
        for text in ("/start", "привет", "/start ref42"):
            self.assertEqual(self.message(text), bot.TEXTS["start"], text)

    def test_without_family_the_link_gets_the_greeting(self):
        self.assertEqual(self.message(f"/start f_{self.ADDRESS}", target=self.make(None)), bot.TEXTS["start"])

    def test_location_flow_is_untouched(self):
        self.bot.handle({"message": {"chat": {"id": 1}, "from": {"id": USER},
                                     "location": {"latitude": 41.31, "longitude": 69.28}}})
        self.assertEqual(self.sent[-1]["text"], bot.TEXTS["pick"])
        self.assertIn("reply_markup", self.sent[-1])

    def test_one_kdf_per_family_command(self):
        calls = []
        real = bot._kdf
        bot._kdf = lambda password, salt: (calls.append(1), real(password, salt))[1]
        try:
            for text in (f"/start f_{self.ADDRESS}", "/stop"):
                calls.clear()
                self.message(text)
                self.assertEqual(len(calls), 1, text)
        finally:
            bot._kdf = real

    def test_start_family_wires_commands_and_one_courier_thread(self):
        started = []
        logs = []
        saved_thread, saved_log = bot.threading.Thread, bot.log

        class FakeThread:
            def __init__(self, target, name, daemon):
                started.append((name, daemon, target.__self__.path))

            def start(self):
                pass
        bot.threading.Thread, bot.log = FakeThread, logs.append
        try:
            commands = bot.start_family({"salt": SALT, "username": "RadarMapBot"}, send=None, path=self.path)
            self.assertIsInstance(commands, family_notify.FamilyCommands)
            self.assertEqual(started, [("family-courier", True, self.path)])
            self.assertEqual(logs, [])
            commands.conn.close()
            bot.start_family({"salt": SALT}, send=None, path=self.path).conn.close()
            self.assertTrue(any("username" in line for line in logs), "без username — запись в журнал")
            logs.clear()
            self.assertIsNone(bot.start_family({"salt": SALT, "username": "RadarMapBot"}, send=None,
                                               path=os.path.join(self.dir, "нет", "family.db")))
            self.assertTrue(logs, "база не открылась — бот живёт без подписок и говорит об этом")
        finally:
            bot.threading.Thread, bot.log = saved_thread, saved_log


class UnitFileTest(unittest.TestCase):
    """Бот разбирает чужой ввод из интернета и держит токен — работает от
    root, как api и панель, значит и песочница у него та же
    (systemd-radarmap-sandbox.conf): ошибка в разборе не должна давать запись
    по всему общему VPS."""

    def test_bot_unit_is_sandboxed_like_the_api(self):
        path = os.path.join(HERE, "radarmap-bot.service")
        with open(path, encoding="utf-8") as handle:
            lines = {line.strip() for line in handle}
        for directive in ("NoNewPrivileges=yes", "ProtectSystem=strict", "ProtectHome=yes",
                          "PrivateTmp=yes", "PrivateDevices=yes",
                          "ReadWritePaths=/opt/radarmap/api",
                          "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"):
            self.assertIn(directive, lines, f"в юните бота нет {directive}")
        self.assertFalse(any(line.startswith(("InaccessiblePaths", "TemporaryFileSystem")) for line in lines),
                         "файлы заведений в webroot бот читает — их нельзя спрятать")

    def test_default_venues_dir_is_where_publish_roads_puts_them(self):
        with open(os.path.join(HERE, "publish_roads.sh"), encoding="utf-8") as handle:
            script = handle.read()
        webroot = re.search(r'WEBROOT="\$\{RADARMAP_WEBROOT:-([^}]+)\}"', script).group(1)
        self.assertIn("'$WEBROOT/roads/'", script)
        self.assertEqual(bot.DEFAULT_VENUES_DIR, webroot + "/roads")

    def test_deploy_refuses_a_python_without_scrypt(self):
        with open(os.path.join(HERE, "deploy_bot.sh"), encoding="utf-8") as handle:
            self.assertIn("hashlib.scrypt", handle.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
