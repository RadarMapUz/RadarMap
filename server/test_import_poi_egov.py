#!/usr/bin/env python3
"""Тесты импорта банкоматов и гостиниц с портала: разбор строки, проверка
координат, дубли, формат файла и слияние с OSM в build_roads. Без сети —
на пяти настоящих строках каждого набора из server/fixtures/.
Запуск: python3 server/test_import_poi_egov.py
"""
import copy
import json
import os
import tempfile
import unittest

import build_roads
import import_poi_egov as poi

HERE = os.path.dirname(os.path.abspath(__file__))


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as handle:
        return json.load(handle)["result"]["data"]


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.atms = fixture("egov_atm_sample.json")
        self.hotels = fixture("egov_hotel_sample.json")

    def test_atm_row_gives_bank_coordinates_and_address(self):
        record = poi.parse_atm(self.atms[0])
        self.assertEqual(record["name"], "Ziraat Bank Uzbekistan")
        self.assertEqual(record["operator"], "Ziraat Bank Uzbekistan")
        self.assertAlmostEqual(record["lat"], 41.337837, places=5)
        self.assertAlmostEqual(record["lon"], 69.273552, places=5)
        self.assertIn("Кичик Халка", record["address"])
        self.assertEqual(record["region"], "город Ташкент")
        self.assertTrue(record["egov_id"])

    def test_atm_bank_wins_over_internal_title(self):
        """«АТБ "Узагроэкспортбанк" 24/7» — внутреннее имя точки; водитель ищет
        банк, и в name идёт банк."""
        record = poi.parse_atm(self.atms[2])
        self.assertEqual(record["name"], "AVO bank")
        self.assertIn("Узагроэкспортбанк", record["description"])

    def test_hotel_name_is_the_quoted_part_of_the_legal_entity(self):
        names = [poi.parse_hotel(row)["name"] for row in self.hotels]
        self.assertEqual(names[0], "SM HOTEL")
        self.assertEqual(names[3], "ARS HOTEL")   # «"ARS HOTEL" MChJ ("LAVRASIYA TRAVELS" MChJ)»
        record = poi.parse_hotel(self.hotels[0])
        self.assertIn("Мозий", record["address"])
        self.assertEqual(record["region"], "Ферганская область")

    def test_legal_name_without_quotes_drops_the_legal_form(self):
        self.assertEqual(poi.legal_name("Silk Road Palace MChJ"), "Silk Road Palace")
        self.assertEqual(poi.legal_name("Grand MChJ (ООО)"), "Grand (ООО)")

    def test_text_prefers_russian_then_latin(self):
        self.assertEqual(poi.text_of({"text": {"uzbText": "Toshkent", "rusText": "Ташкент"}}),
                         "Ташкент")
        self.assertEqual(poi.text_of({"text": {"uzbText": "Toshkent", "rusText": None}}),
                         "Toshkent")
        self.assertEqual(poi.text_of({"text": None, "data": "Uzcard", "default": "Uzcard"}),
                         "Uzcard")
        self.assertEqual(poi.text_of(None), "")


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.row = copy.deepcopy(fixture("egov_atm_sample.json")[0])

    def with_coordinates(self, lat, lon):
        row = copy.deepcopy(self.row)
        row["tableColumn"]["latitude"] = {"text": None, "number": lat, "data": None, "default": lat}
        row["tableColumn"]["longitude"] = {"text": None, "number": lon, "data": None, "default": lon}
        return row

    def test_coordinates_outside_uzbekistan_are_dropped(self):
        """lat=39809352 — потерянная запятая. Такое не чинится, а выбрасывается."""
        self.assertIsNone(poi.parse_atm(self.with_coordinates(39809352.0, 64430345.0)))
        self.assertIsNone(poi.parse_atm(self.with_coordinates(0.0, 0.0)))
        self.assertIsNone(poi.parse_atm(self.with_coordinates(48.02, 50.10)))   # за границей

    def test_swapped_latitude_and_longitude_are_recognised(self):
        record = poi.parse_atm(self.with_coordinates(69.2735, 41.3378))
        self.assertAlmostEqual(record["lat"], 41.3378, places=4)
        self.assertAlmostEqual(record["lon"], 69.2735, places=4)

    def test_coordinates_as_text_with_comma(self):
        row = copy.deepcopy(self.row)
        row["tableColumn"]["latitude"] = {"text": None, "number": 0.0, "data": "41,31", "default": "41,31"}
        row["tableColumn"]["longitude"] = {"text": None, "number": 0.0, "data": "69,25", "default": "69,25"}
        record = poi.parse_atm(row)
        self.assertAlmostEqual(record["lat"], 41.31, places=4)

    def test_missing_coordinates_are_dropped(self):
        row = copy.deepcopy(self.row)
        del row["tableColumn"]["latitude"]
        self.assertIsNone(poi.parse_atm(row))


class DedupTests(unittest.TestCase):
    def test_same_name_within_20_m_is_one_record(self):
        rows = [{"name": "Kapitalbank", "lat": 41.3100, "lon": 69.2500},
                {"name": "KAPITALBANK", "lat": 41.3101, "lon": 69.2500},    # 11 м
                {"name": "Kapitalbank", "lat": 41.3105, "lon": 69.2500}]    # 55 м
        self.assertEqual(len(poi.dedup(rows)), 2)

    def test_different_banks_in_one_hall_stay(self):
        rows = [{"name": "Kapitalbank", "lat": 41.31, "lon": 69.25},
                {"name": "Ipak Yuli", "lat": 41.31, "lon": 69.25}]
        self.assertEqual(len(poi.dedup(rows)), 2)

    def test_build_on_fixture_keeps_all_five_atms(self):
        records = poi.build("atm", fixture("egov_atm_sample.json"))
        self.assertEqual(len(records), 5)
        self.assertEqual(len(poi.build("hotel", fixture("egov_hotel_sample.json"))), 5)


class FileTests(unittest.TestCase):
    def write(self, kind, rows):
        path = os.path.join(tempfile.mkdtemp(), f"egov_{kind}.geojsonl")
        poi.write_geojsonl(path, kind, poi.build(kind, rows), "2026-10-12")
        return path

    def test_first_line_carries_the_licence(self):
        path = self.write("atm", fixture("egov_atm_sample.json"))
        with open(path, encoding="utf-8") as handle:
            first = json.loads(handle.readline().lstrip("\x1e"))
        self.assertEqual(first["type"], "Attribution")
        self.assertEqual(first["license"], "CC BY-SA 4.0")
        self.assertIn("data.egov.uz", first["source"])
        self.assertIn("4-009-0061", first["dataset"])
        self.assertEqual(first["count"], 5)

    def test_features_carry_osm_tags_build_roads_understands(self):
        atm_path = self.write("atm", fixture("egov_atm_sample.json"))
        hotel_path = self.write("hotel", fixture("egov_hotel_sample.json"))
        atms = build_roads.collect_venues(atm_path)
        hotels = build_roads.collect_venues(hotel_path)
        self.assertEqual([row[0] for row in atms], [9] * 5)      # Venue.Kind.atm
        self.assertEqual([row[0] for row in hotels], [11] * 5)   # гостиница
        self.assertEqual(atms[0][1], "Ziraat Bank Uzbekistan")
        self.assertEqual(hotels[0][1], "SM HOTEL")
        with open(atm_path, encoding="utf-8") as handle:
            second = json.loads(handle.readlines()[1].lstrip("\x1e"))
        self.assertEqual(second["properties"]["amenity"], "atm")
        self.assertEqual(second["properties"]["source"], "data.egov.uz 4-009-0061")
        self.assertIn("addr:full", second["properties"])

    def test_no_personal_fields_leave_the_registry(self):
        """ИНН и номер сертификата гостиницы — не для файла поиска."""
        path = self.write("hotel", fixture("egov_hotel_sample.json"))
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
        self.assertNotIn("STIR", body)
        self.assertNotIn("311137448", body)
        self.assertNotIn("UZ.SMT", body)


class MergeTests(unittest.TestCase):
    """Слияние с OSM живёт в build_roads: сборка заведений — его дело."""

    def test_registry_point_near_osm_point_is_the_same_atm(self):
        osm = [(9, "Капиталбанк", 69.2500, 41.3100)]
        egov = [(9, "Kapitalbank", 69.2502, 41.3101),   # ~20 м — тот же
                (9, "Kapitalbank", 69.2600, 41.3100)]   # 840 м — новый
        merged = build_roads.merge_venues(osm, egov)
        self.assertEqual(len(merged), 2)
        self.assertEqual(merged[0][1], "Капиталбанк", "OSM остаётся первым и со своим именем")

    def test_other_kind_nearby_is_not_a_duplicate(self):
        osm = [(1, "Lukoil", 69.25, 41.31)]
        egov = [(9, "Kapitalbank", 69.25, 41.31)]
        self.assertEqual(len(build_roads.merge_venues(osm, egov)), 2)

    def test_hotel_kind_is_eleven_and_tourism_tags_are_collected(self):
        self.assertEqual(build_roads.venue_kind({"tourism": "hotel"}), 11)
        self.assertEqual(build_roads.venue_kind({"tourism": "guest_house"}), 11)
        self.assertIsNone(build_roads.venue_kind({"tourism": "museum"}))

    def test_merge_without_extra_is_identity(self):
        osm = [(1, "Lukoil", 69.25, 41.31)]
        self.assertEqual(build_roads.merge_venues(osm, []), osm)


class FetchTests(unittest.TestCase):
    """Постраничная загрузка с подменённой сетью."""

    def test_pages_are_walked_to_the_end_and_retried(self):
        rows = [{"id": str(i)} for i in range(7)]
        calls = []

        def fetch(guid, offset, limit):
            calls.append(offset)
            if len(calls) == 2:
                raise OSError("timeout")
            return rows[offset:offset + limit], len(rows)

        got = poi.fetch_all("guid", page=3, fetch=fetch, sleep=lambda s: None)
        self.assertEqual([r["id"] for r in got], [str(i) for i in range(7)])
        self.assertEqual(calls, [0, 3, 3, 6])

    def test_persistent_failure_raises_instead_of_a_half_set(self):
        def fetch(guid, offset, limit):
            raise OSError("down")
        with self.assertRaises(RuntimeError):
            poi.fetch_all("guid", page=3, retries=2, fetch=fetch, sleep=lambda s: None)

    def test_short_set_against_declared_count_raises(self):
        def fetch(guid, offset, limit):
            return ([{"id": "1"}] if offset == 0 else []), 100
        with self.assertRaises(RuntimeError):
            poi.fetch_all("guid", page=3, fetch=fetch, sleep=lambda s: None)



class PlaceholderTest(unittest.TestCase):
    """Заглушки геокодера и точки вне страны (план 11.12)."""

    def test_one_point_with_different_addresses_is_a_placeholder(self):
        records = [
            {"name": "Агробанк", "lat": 41.31115, "lon": 69.27975, "address": "24/7"},
            {"name": "Халк банки", "lat": 41.31115, "lon": 69.27975, "address": "здание филиала"},
            {"name": "Капиталбанк", "lat": 41.32, "lon": 69.25, "address": "ул. Навои, 1"},
        ]
        self.assertEqual([r["name"] for r in poi.drop_placeholders(records)], ["Капиталбанк"])

    def test_round_coordinates_are_dropped(self):
        records = [{"name": "Узпромстройбанк", "lat": 40.0, "lon": 64.0, "address": "ТРЦ"},
                   {"name": "Агробанк", "lat": 40.1234, "lon": 64.4321, "address": "банк"}]
        self.assertEqual([r["name"] for r in poi.drop_placeholders(records)], ["Агробанк"])

    def test_same_address_twice_is_a_duplicate_not_a_placeholder(self):
        records = [{"name": "Агробанк", "lat": 41.3, "lon": 69.21, "address": "банк"},
                   {"name": "Агробанк", "lat": 41.3, "lon": 69.21, "address": "банк"}]
        self.assertEqual(len(poi.drop_placeholders(records)), 2, "повтор схлопнет dedup, не этот фильтр")

    def test_north_of_the_country_is_outside(self):
        # Гостиница с адресом в Ташкентской области на 45.65° — Казахстан.
        def cells(lat, lon):
            return {"latitude": {"text": None, "number": 0.0, "data": lat, "default": lat},
                    "longitude": {"text": None, "number": 0.0, "data": lon, "default": lon}}
        self.assertIsNone(poi.coordinates(cells("45.653803", "69.402083")))
        self.assertIsNotNone(poi.coordinates(cells("45.55", "58.9")), "север Каракалпакстана")

if __name__ == "__main__":
    unittest.main()
