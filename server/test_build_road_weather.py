#!/usr/bin/env python3
"""Тесты сборщика погоды на трассах. Запуск: python3 server/test_build_road_weather.py

Ответ open-meteo — записанный вручную по документированному формату (тот же
вид, что отдаёт API на пачку точек: массив объектов, ряды hourly с unixtime):
fixtures/open_meteo_road_weather.json. Сеть тесты не трогают.
"""
import json
import os
import tempfile
import unittest
import urllib.parse

import build_road_weather as rw

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = json.load(open(os.path.join(HERE, "fixtures", "open_meteo_road_weather.json"), encoding="utf-8"))
T0 = 1792519200            # первый час ряда в записи (18:00 UTC)
NOW = T0 + 20 * 60         # прогон в 18:20 — текущий час 18:00
HOUR = 3600


def point(pid, lat, lon, group=None, kind="pass"):
    return {"id": pid, "group": group or pid, "kind": kind, "road": "A373", "lat": lat, "lon": lon, "r": 3000,
            "name": {"ru": f"Точка {pid}", "uz": f"Nuqta {pid}"},
            "where": {"ru": f"На точке {pid}", "uz": f"{pid} nuqtasida"}}


# Точки в порядке записанного ответа.
POINTS = [point("fog", 41.08438, 70.54011, "kamchik"),
          point("snow", 41.11173, 70.49804, "kamchik"),
          point("wind", 39.29, 66.932),
          point("clear", 40.949, 68.74544, kind="plain"),
          point("freezing", 40.70109, 71.03131, kind="plain")]


def hourly(**series):
    """Один час-ряд из 7 значений вокруг T0 для проверки порогов."""
    base = {"time": [T0 + i * HOUR for i in range(7)],
            "temperature_2m": [10.0] * 7, "precipitation": [0.0] * 7, "snowfall": [0.0] * 7,
            "visibility": [20000.0] * 7, "wind_speed_10m": [1.0] * 7, "weather_code": [0] * 7}
    base.update(series)
    return {"hourly_units": {"time": "unixtime", "temperature_2m": "°C", "wind_speed_10m": "m/s"},
            "hourly": base}


def kinds(hazards):
    return [h["k"] for h in hazards]


class RequestTest(unittest.TestCase):
    def test_one_request_for_all_points(self):
        url = rw.forecast_url(POINTS)
        self.assertTrue(url.startswith("https://api.open-meteo.com/v1/forecast?"))
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertEqual(len(query["latitude"][0].split(",")), len(POINTS))
        self.assertEqual(len(query["longitude"][0].split(",")), len(POINTS))
        self.assertEqual(query["latitude"][0].split(",")[0], "41.08438")
        self.assertEqual(set(query["hourly"][0].split(",")),
                         {"temperature_2m", "precipitation", "snowfall", "visibility",
                          "wind_speed_10m", "weather_code"})
        self.assertEqual(query["wind_speed_unit"], ["ms"])
        self.assertEqual(query["timeformat"], ["unixtime"])
        self.assertEqual(query["forecast_hours"], ["7"], "сейчас и шесть часов вперёд")

    def test_commas_are_not_escaped(self):
        # open-meteo ждёт запятые как есть: «%2C» он тоже понимает, но в логах
        # nginx и в ручной проверке строка должна читаться.
        self.assertIn("latitude=41.08438,41.11173", rw.forecast_url(POINTS))


class ShippedPointsTest(unittest.TestCase):
    """Список, который уедет на сервер: проверяется тем же кодом, что в cron."""

    def setUp(self):
        self.points = rw.load_points()
        self.raw = json.load(open(rw.POINTS_PATH, encoding="utf-8"))["points"]

    def test_kamchik_has_both_slopes_and_the_tunnel(self):
        kamchik = [p for p in self.points if p["group"] == "kamchik"]
        self.assertGreaterEqual(len(kamchik), 3)
        self.assertTrue(all(p["road"] == "A373" and p["kind"] == "pass" for p in kamchik))
        ids = {p["id"] for p in kamchik}
        self.assertTrue({"kamchik-north", "kamchik-tunnel", "kamchik-south"} <= ids)
        # Одно имя на весь перевал: телефон говорит о нём одной фразой.
        self.assertEqual({p["where"]["ru"] for p in kamchik}, {"На перевале Камчик"})

    def test_takhtakaracha_and_plains(self):
        self.assertTrue(any(p["group"] == "takhtakaracha" for p in self.points))
        plains = [p for p in self.points if p["kind"] == "plain"]
        self.assertGreaterEqual(len(plains), 4)
        self.assertEqual({p["road"] for p in plains}, {"M39", "A373"})

    def test_every_point_waits_for_the_owner(self):
        for raw in self.raw:
            self.assertIn("проверить", raw.get("check", ""), raw["id"])

    def test_owner_notes_are_not_published(self):
        body = rw.build(self.points, [hourly()] * len(self.points), NOW)
        for p in body["points"]:
            self.assertNotIn("check", p)

    def test_bad_lists_are_refused(self):
        good = {"v": 1, "points": [dict(POINTS[0])]}
        rw.validate_points(good)
        for broken in (
            {"v": 1, "points": [dict(POINTS[0], lat=48.0)]},               # Казахстан
            {"v": 1, "points": [POINTS[0], POINTS[0]]},                     # повтор id
            {"v": 1, "points": [dict(POINTS[0], name={"ru": "Камчик"})]},   # без uz
            {"v": 1, "points": [dict(POINTS[0], kind="tunnel")]},
            {"v": 1, "points": [dict(POINTS[0], r=100_000)]},
            {"v": 1, "points": []},
            {"v": 2, "points": [POINTS[0]]},
        ):
            with self.assertRaises(rw.FormatError):
                rw.validate_points(broken)


class RecordedResponseTest(unittest.TestCase):
    def setUp(self):
        self.body = rw.build(POINTS, FIXTURE, NOW)
        self.by_id = {p["id"]: p for p in self.body["points"]}

    def test_format(self):
        self.assertEqual(self.body["v"], 1)
        self.assertEqual(self.body["generated"], NOW)
        self.assertEqual([p["id"] for p in self.body["points"]], [p["id"] for p in POINTS])
        p = self.by_id["fog"]
        self.assertEqual(set(p), {"id", "group", "kind", "road", "lat", "lon", "r", "name", "where",
                                  "hazards", "until", "t", "vis"})
        self.assertEqual(p["group"], "kamchik")

    def test_fog_now_until_it_lifts(self):
        p = self.by_id["fog"]
        self.assertEqual(p["hazards"], [{"k": "fog", "from": T0, "to": T0 + 2 * HOUR}])
        self.assertEqual(p["until"], T0 + 2 * HOUR)
        self.assertEqual(p["vis"], 150)
        self.assertEqual(p["t"], 3.5)

    def test_snow_and_ice_on_the_pass_ice_first(self):
        p = self.by_id["snow"]
        self.assertEqual(kinds(p["hazards"]), ["ice", "snow"], "гололёд важнее снега")
        for h in p["hazards"]:
            self.assertEqual((h["from"], h["to"]), (T0 + HOUR, T0 + 4 * HOUR))
        self.assertEqual(p["t"], -0.5)

    def test_wind_later_in_the_window(self):
        p = self.by_id["wind"]
        self.assertEqual(p["hazards"], [{"k": "wind", "from": T0 + 4 * HOUR, "to": T0 + 6 * HOUR}])

    def test_missing_visibility_is_not_fog(self):
        p = self.by_id["clear"]
        self.assertEqual(p["hazards"], [])
        self.assertIsNone(p["until"])
        self.assertIsNone(p["vis"])

    def test_freezing_drizzle_code_is_ice_above_zero(self):
        p = self.by_id["freezing"]
        self.assertEqual(p["hazards"], [{"k": "ice", "from": T0 + 2 * HOUR, "to": T0 + 3 * HOUR}])

    def test_single_location_answer_is_an_object(self):
        body = rw.build(POINTS[:1], FIXTURE[0], NOW)
        self.assertEqual(kinds(body["points"][0]["hazards"]), ["fog"])

    def test_point_count_must_match(self):
        # Иначе погода Камчика досталась бы Чиназу.
        with self.assertRaises(rw.FormatError):
            rw.build(POINTS, FIXTURE[:4], NOW)


class ThresholdTest(unittest.TestCase):
    def hazards_at(self, **values):
        series = {name: [value] + [None] * 6 for name, value in values.items()}
        found, _, _ = rw.assess(hourly(**series), NOW)
        return set(kinds(found))

    def test_fog_below_200_m(self):
        self.assertEqual(self.hazards_at(visibility=199.0), {"fog"})
        self.assertEqual(self.hazards_at(visibility=200.0), set())

    def test_wind_from_15_ms(self):
        self.assertEqual(self.hazards_at(wind_speed_10m=15.0), {"wind"})
        self.assertEqual(self.hazards_at(wind_speed_10m=14.9), set())

    def test_ice_needs_frost_and_precipitation(self):
        self.assertEqual(self.hazards_at(temperature_2m=0.0, precipitation=0.1), {"ice"})
        self.assertEqual(self.hazards_at(temperature_2m=0.1, precipitation=2.0), set(), "дождь в плюс")
        self.assertEqual(self.hazards_at(temperature_2m=-5.0, precipitation=0.0), set(), "сухой мороз")

    def test_snow_by_amount_or_code(self):
        self.assertEqual(self.hazards_at(snowfall=0.1), {"snow"})
        self.assertEqual(self.hazards_at(snowfall=0.09), set())
        self.assertEqual(self.hazards_at(weather_code=75), {"snow"})

    def test_kmh_wind_is_converted(self):
        answer = hourly(wind_speed_10m=[60.0] + [1.0] * 6)
        answer["hourly_units"]["wind_speed_10m"] = "km/h"
        found, _, _ = rw.assess(answer, NOW)
        self.assertEqual(kinds(found), ["wind"], "60 км/ч = 16,7 м/с")
        answer["hourly_units"]["wind_speed_10m"] = "beaufort"
        found, _, _ = rw.assess(answer, NOW)
        self.assertEqual(found, [], "незнакомая единица — ветра не знаем")

    def test_fahrenheit_is_refused(self):
        answer = hourly()
        answer["hourly_units"]["temperature_2m"] = "°F"
        with self.assertRaises(rw.FormatError):
            rw.assess(answer, NOW)

    def test_series_of_wrong_length_is_refused(self):
        with self.assertRaises(rw.FormatError):
            rw.assess(hourly(visibility=[100.0] * 3), NOW)

    def test_window_is_now_and_six_hours(self):
        """Прошедший час не в счёт, час позже шести часов — тоже."""
        times = [T0 - 2 * HOUR + i * HOUR for i in range(10)]   # 16:00 … 01:00
        fog = [100.0, 100.0] + [20000.0] * 7 + [100.0]            # 16, 17 и 01:00 — туман
        found, _, vis = rw.assess(hourly(time=times, visibility=fog, temperature_2m=[5.0] * 10,
                                         precipitation=[0.0] * 10, snowfall=[0.0] * 10,
                                         wind_speed_10m=[1.0] * 10, weather_code=[0] * 10), NOW)
        self.assertEqual(found, [], "туман был до 18:00 и будет после 00:20")
        self.assertEqual(vis, 20000, "сейчас — час 18:00")

    def test_hour_in_progress_counts(self):
        found, _, _ = rw.assess(hourly(visibility=[100.0] + [20000.0] * 6), T0 + 59 * 60)
        self.assertEqual(found, [{"k": "fog", "from": T0, "to": T0 + HOUR}])


class WriteTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.dir.name, "weather", "roads.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_written_once_until_something_changes(self):
        _, written = rw.run(POINTS, FIXTURE, NOW, out_path=self.out)
        self.assertTrue(written)
        stored = json.load(open(self.out, encoding="utf-8"))
        self.assertEqual(stored["generated"], NOW)
        # Тот же прогноз через полчаса — файл тот же, ETag тот же.
        _, written = rw.run(POINTS, FIXTURE, NOW + 1800, out_path=self.out)
        self.assertFalse(written)
        self.assertEqual(json.load(open(self.out, encoding="utf-8"))["generated"], NOW)
        self.assertFalse(os.path.exists(self.out + ".tmp"))

    def test_unchanged_file_is_refreshed_before_it_goes_stale(self):
        rw.run(POINTS, FIXTURE, NOW, out_path=self.out)
        _, written = rw.run(POINTS, FIXTURE, NOW + rw.REWRITE_EVERY, out_path=self.out)
        self.assertTrue(written, "телефон считает файл старше 2 ч отсутствием данных")
        self.assertLess(rw.REWRITE_EVERY + 30 * 60, 2 * 3600, "запись + интервал cron < срока телефона")

    def test_changed_weather_is_written_at_once(self):
        rw.run(POINTS, FIXTURE, NOW, out_path=self.out)
        changed = json.loads(json.dumps(FIXTURE))
        changed[3]["hourly"]["visibility"] = [90.0] * 7
        _, written = rw.run(POINTS, changed, NOW + 60, out_path=self.out)
        self.assertTrue(written)
        stored = json.load(open(self.out, encoding="utf-8"))
        self.assertEqual(kinds(stored["points"][3]["hazards"]), ["fog"])

    def test_broken_file_is_replaced(self):
        os.makedirs(os.path.dirname(self.out))
        with open(self.out, "w") as f:
            f.write("{обрыв")
        _, written = rw.run(POINTS, FIXTURE, NOW, out_path=self.out)
        self.assertTrue(written)

    def test_bad_answer_leaves_the_old_file(self):
        rw.run(POINTS, FIXTURE, NOW, out_path=self.out)
        before = open(self.out, encoding="utf-8").read()
        with self.assertRaises(rw.FormatError):
            rw.run(POINTS, {"error": True, "reason": "Too many requests"}, NOW + 7200, out_path=self.out)
        self.assertEqual(open(self.out, encoding="utf-8").read(), before)


class MainTest(unittest.TestCase):
    """Командная строка на записанном ответе: файл пишется, сломанный ответ
    файла не трогает и даёт код 1 (cron пишет причину в журнал)."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.points = os.path.join(self.dir.name, "points.json")
        with open(self.points, "w", encoding="utf-8") as f:
            json.dump({"v": 1, "points": POINTS}, f, ensure_ascii=False)
        self.response = os.path.join(self.dir.name, "answer.json")
        with open(self.response, "w", encoding="utf-8") as f:
            json.dump(FIXTURE, f)
        self.out = os.path.join(self.dir.name, "www", "weather", "roads.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_writes_the_file(self):
        code = rw.main(["--points", self.points, "--response", self.response, "--out", self.out])
        self.assertEqual(code, 0)
        body = json.load(open(self.out, encoding="utf-8"))
        self.assertEqual(len(body["points"]), len(POINTS))

    def test_broken_answer_keeps_the_file_away(self):
        with open(self.response, "w") as f:
            f.write("<html>502</html>")
        code = rw.main(["--points", self.points, "--response", self.response, "--out", self.out])
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main()
