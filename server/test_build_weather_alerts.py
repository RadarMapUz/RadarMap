#!/usr/bin/env python3
"""Тесты прототипа ленты Узгидромета: Atom → CAP → наше предупреждение.
Без сети — на выгрузке 02.11.2026 (два «Дождя») и трёхъязычном CAP
января 2026 (сильный ветер, Бухарская обл.) из server/fixtures/.
Запуск: python3 server/test_build_weather_alerts.py
"""
import datetime
import os
import unittest

import build_weather_alerts as weather

HERE = os.path.dirname(os.path.abspath(__file__))
UTC = datetime.timezone.utc


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), "rb") as handle:
        return handle.read()


class FeedTests(unittest.TestCase):
    def test_atom_gives_cap_links_from_its_own_host_only(self):
        links = weather.cap_links(fixture("uzhydromet_atom_ru.xml"))
        self.assertEqual(len(links), 2)
        self.assertTrue(all(link.startswith("https://meteoalert.meteoinfo.ru/uzbekistan/") for link in links))
        foreign = fixture("uzhydromet_atom_ru.xml").replace(
            b'type="application/cap+xml" href="https://meteoalert.meteoinfo.ru',
            b'type="application/cap+xml" href="https://evil.example')
        self.assertEqual(weather.cap_links(foreign), [])

    def test_entity_tricks_are_refused(self):
        bomb = b'<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "x">]><a>&x;</a>'
        with self.assertRaises(weather.FeedError):
            weather.cap_links(bomb)


class CapTests(unittest.TestCase):
    def test_rain_alert_keeps_place_time_and_level(self):
        alert = weather.parse_cap(fixture("uzhydromet_cap_rain.xml"))
        self.assertEqual(alert["kind"], "rain")
        self.assertEqual(alert["level"], 1)
        self.assertEqual(alert["area"], "Республика Каракалпакстан")
        self.assertEqual(alert["onset"], "2026-11-05T06:00:00+00:00")
        self.assertEqual(alert["expires"], "2026-11-06T07:00:00+00:00")
        self.assertEqual(len(alert["polygons"]), 1)
        self.assertGreaterEqual(len(alert["polygons"][0]), 3)

    def test_three_language_cap_reads_russian_and_thins_polygons(self):
        alert = weather.parse_cap(fixture("uzhydromet_cap_wind_3lang.xml"))
        self.assertEqual(alert["kind"], "wind")
        self.assertEqual(alert["level"], 2)
        self.assertIn("ветр", alert["event"])
        self.assertTrue(all(len(p) <= weather.MAX_POLYGON_POINTS + 1 for p in alert["polygons"]))

    def test_event_words_map_to_road_kinds(self):
        self.assertEqual(weather.event_kind("Гололёд"), "ice")
        self.assertEqual(weather.event_kind("Скользкие дороги"), "ice")
        self.assertEqual(weather.event_kind("Предупреждение о селе-паводковых явлениях"), "mudflow")
        self.assertEqual(weather.event_kind("Туман"), "fog")
        self.assertEqual(weather.event_kind("Пыльная буря"), "dust")
        self.assertEqual(weather.event_kind("Лавиноопасность"), "avalanche")
        self.assertEqual(weather.event_kind("Сильный дождь"), "rain")
        self.assertEqual(weather.event_kind("Солнечное затмение"), "other")

    def test_exercise_or_test_message_is_not_an_alert(self):
        test = fixture("uzhydromet_cap_rain.xml").replace(b"<status>Actual</status>", b"<status>Test</status>")
        self.assertIsNone(weather.parse_cap(test))

    def test_alert_without_expiry_is_not_published(self):
        data = fixture("uzhydromet_cap_rain.xml")
        start = data.index(b"<expires>")
        end = data.index(b"</expires>") + len(b"</expires>")
        self.assertIsNone(weather.parse_cap(data[:start] + data[end:]))


class AssembleTests(unittest.TestCase):
    def setUp(self):
        self.rain = weather.parse_cap(fixture("uzhydromet_cap_rain.xml"))
        self.rain2 = weather.parse_cap(fixture("uzhydromet_cap_rain2.xml"))

    def test_expired_alerts_drop_out(self):
        before = datetime.datetime(2026, 11, 3, tzinfo=UTC)
        after = datetime.datetime(2026, 11, 7, tzinfo=UTC)
        self.assertEqual(len(weather.assemble([self.rain, self.rain2], before)["alerts"]), 2)
        self.assertEqual(weather.assemble([self.rain, self.rain2], after)["alerts"], [])

    def test_cancel_removes_the_referenced_alert(self):
        cancel = dict(self.rain2, id="cancel-1", msg="Cancel", references=[self.rain["id"]])
        payload = weather.assemble([self.rain, self.rain2, cancel], datetime.datetime(2026, 11, 3, tzinfo=UTC))
        self.assertEqual([a["id"] for a in payload["alerts"]], [self.rain2["id"]])
        self.assertEqual(payload["source"], "Узгидромет")

    def test_collect_runs_end_to_end_on_saved_feed(self):
        files = {weather.FEED_URL: fixture("uzhydromet_atom_ru.xml")}
        base = "https://meteoalert.meteoinfo.ru/uzbekistan/cap-feed/ru/"
        files[base + "20261102065441-0034887.xml"] = fixture("uzhydromet_cap_rain.xml")
        files[base + "20261102065218-0034885.xml"] = fixture("uzhydromet_cap_rain2.xml")
        payload, errors = weather.collect(now=datetime.datetime(2026, 11, 3, tzinfo=UTC), fetch=files.__getitem__)
        self.assertEqual(errors, [])
        self.assertEqual({a["area"] for a in payload["alerts"]},
                         {"Республика Каракалпакстан", "Наманганская область"})


if __name__ == "__main__":
    unittest.main()
