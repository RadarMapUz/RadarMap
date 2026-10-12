#!/usr/bin/env python3
"""Тесты очереди кандидатов: разбор строки области и узла OSM, битые
координаты, порог 300 м от базы, слияние источников, разбор каталога.
Без сети; OSM — крошечный .osm.pbf, собранный на месте через pyosmium.
Запуск: python3 server/test_build_camera_candidates.py
"""
import json
import os
import tempfile
import unittest

import build_camera_candidates as bcc

HERE = os.path.dirname(os.path.abspath(__file__))


def fixture_rows(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as handle:
        return json.load(handle)["result"]["data"]


class EgovRowTests(unittest.TestCase):
    def setUp(self):
        self.rows = fixture_rows("egov_cameras_bukhara_sample.json")

    def test_row_becomes_a_candidate_with_region_source_and_note(self):
        item = bcc.candidate_from_egov("buxoro", self.rows[0])
        self.assertEqual(item["source"], "egov-buxoro")
        self.assertTrue(item["id"].startswith("egov-buxoro:"))
        self.assertAlmostEqual(item["lat"], 40.527389, places=5)
        self.assertAlmostEqual(item["lon"], 68.21746, places=5)
        self.assertIn("А-380", item["note"])
        self.assertIn("Радар", item["type"])          # «ПДД КАМЕРА, СТАЦИОНАР РАДАР» → без капса

    def test_broken_coordinates_are_dropped(self):
        """В бухарском наборе есть lat=39809352: запятая потеряна при вводе.
        Такое не чинится делением — выбрасывается."""
        broken = [row for row in self.rows
                  if (row["tableColumn"]["latitude"]["number"] or 0) > 1000]
        self.assertTrue(broken, "фикстура должна содержать битую строку")
        self.assertIsNone(bcc.candidate_from_egov("buxoro", broken[0]))
        good = [bcc.candidate_from_egov("buxoro", row) for row in self.rows]
        self.assertEqual(sum(1 for g in good if g), 4)

    def test_swapped_pair_is_recognised(self):
        row = json.loads(json.dumps(self.rows[0]))
        row["tableColumn"]["latitude"]["number"] = 68.21746
        row["tableColumn"]["longitude"]["number"] = 40.527389
        item = bcc.candidate_from_egov("buxoro", row)
        self.assertAlmostEqual(item["lat"], 40.527389, places=5)


class OsmNodeTests(unittest.TestCase):
    def test_speed_camera_node_with_limit_and_direction(self):
        item = bcc.candidate_from_node(42, 41.31, 69.25,
                                       {"highway": "speed_camera", "maxspeed": "70",
                                        "direction": "forward", "name": "Камера"})
        self.assertEqual(item["id"], "osm:42")
        self.assertEqual(item["source"], "osm")
        self.assertEqual(item["maxspeed"], 70)
        self.assertEqual(item["direction"], "forward")
        self.assertEqual(item["note"], "Камера")

    def test_other_nodes_and_outside_points_are_not_candidates(self):
        self.assertIsNone(bcc.candidate_from_node(1, 41.31, 69.25, {"highway": "traffic_signals"}))
        self.assertIsNone(bcc.candidate_from_node(2, 55.75, 37.62, {"highway": "speed_camera"}))

    def test_pbf_is_read_with_pyosmium(self):
        try:
            import osmium
        except ImportError:
            self.skipTest("pyosmium не установлен")
        path = os.path.join(tempfile.mkdtemp(), "mini.osm.pbf")
        writer = osmium.SimpleWriter(path)
        try:
            writer.add_node(osmium.osm.mutable.Node(
                id=10, location=(69.25, 41.31),
                tags={"highway": "speed_camera", "maxspeed": "60"}))
            writer.add_node(osmium.osm.mutable.Node(
                id=11, location=(69.26, 41.32), tags={"highway": "traffic_signals"}))
        finally:
            writer.close()
        items = bcc.osm_candidates(path)
        self.assertEqual([i["id"] for i in items], ["osm:10"])
        self.assertEqual(items[0]["maxspeed"], 60)


class BuildTests(unittest.TestCase):
    CAMERAS = [(41.3100, 69.2500), (40.5274, 68.2175)]

    def test_point_within_300_m_of_the_db_is_the_same_camera(self):
        near = bcc.candidate_from_node(1, 41.3120, 69.2500, {"highway": "speed_camera"})   # 220 м
        far = bcc.candidate_from_node(2, 41.3140, 69.2500, {"highway": "speed_camera"})    # 445 м
        kept = bcc.build([near, far], [], self.CAMERAS)
        self.assertEqual([k["id"] for k in kept], ["osm:2"])
        self.assertEqual(kept[0]["nearest_m"], 445)

    def test_far_from_everything_has_no_nearest(self):
        lone = bcc.candidate_from_node(3, 42.0, 60.0, {"highway": "speed_camera"})
        self.assertIsNone(bcc.build([lone], [], self.CAMERAS)[0]["nearest_m"])

    def test_osm_node_and_regional_row_at_one_spot_are_one_candidate(self):
        osm = bcc.candidate_from_node(5, 41.4000, 69.3000,
                                      {"highway": "speed_camera", "maxspeed": "70"})
        egov = {"id": "egov-buxoro:x", "lat": 41.4002, "lon": 69.3001,
                "type": "Пдд Камера", "source": "egov-buxoro", "note": "Ромитан"}
        kept = bcc.build([osm], [egov], self.CAMERAS)
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["source"], "osm", "OSM первым: у него лимит и направление")
        self.assertEqual(kept[0]["also"], ["egov-buxoro"])
        self.assertIn("Ромитан", kept[0]["note"])
        self.assertEqual(kept[0]["maxspeed"], 70)

    def test_output_is_sorted_and_deterministic(self):
        a = bcc.candidate_from_node(1, 41.5, 69.5, {"highway": "speed_camera"})
        b = bcc.candidate_from_node(2, 41.4, 69.4, {"highway": "speed_camera"})
        one = bcc.build([a, b], [], self.CAMERAS)
        two = bcc.build([b, a], [], self.CAMERAS)
        self.assertEqual(one, two)
        self.assertEqual([k["id"] for k in one], ["osm:2", "osm:1"])

    def test_fixture_rows_against_a_db_that_already_has_one_of_them(self):
        rows = fixture_rows("egov_cameras_bukhara_sample.json")
        items = [c for c in (bcc.candidate_from_egov("buxoro", r) for r in rows) if c]
        # Первая точка «есть в базе» в 50 м, остальные три — нет.
        db = [(items[0]["lat"] + 0.0004, items[0]["lon"])]
        kept = bcc.build([], items, db)
        self.assertEqual(len(kept), 3)
        self.assertTrue(all(k["source"] == "egov-buxoro" for k in kept))


class CatalogTests(unittest.TestCase):
    def test_regional_sets_are_found_by_title_and_the_national_one_is_skipped(self):
        items = [
            {"structId": bcc.NATIONAL_GUID,
             "dataName": {"rusText": "Информация о доступных онлайн фото-радарах и умных камерах в Республике Узбекистан"}},
            {"structId": "637f15614878653e5fe430a7",
             "dataName": {"rusText": "Информация о доступных онлайн фото-радарах и умных камерах  по Бухарской области"}},
            {"structId": "637f15214878653e5fe430a3",
             "dataName": {"rusText": "Информация о доступных онлайн фото-радарах и умных камерах по Хорезмской обласи"}},
            {"structId": "637f14df4878653e5fe42f3d",
             "dataName": {"rusText": "Информация о доступных онлайн фото-радарах и умных камерах по Республики Каракалпакстан"}},
            {"structId": "000000000000000000000001",
             "dataName": {"rusText": "Перечень сертифицированных специалистов"}},
        ]
        found = bcc.regional_sets_from_catalog(items)
        self.assertEqual(found, {"buxoro": "637f15614878653e5fe430a7",
                                 "xorazm": "637f15214878653e5fe430a3",
                                 "qoraqalpogiston": "637f14df4878653e5fe42f3d"})

    def test_unknown_region_is_kept_under_its_id(self):
        items = [{"structId": "abcdef123456",
                  "dataName": {"rusText": "Информация о доступных онлайн фото-радарах по Марсу"}}]
        self.assertEqual(bcc.regional_sets_from_catalog(items), {"123456": "abcdef123456"})


class FetchTests(unittest.TestCase):
    def test_failed_region_is_skipped_not_fatal(self):
        def fetch(guid):
            if guid == "bad":
                raise RuntimeError("down")
            return fixture_rows("egov_cameras_bukhara_sample.json")
        items = bcc.egov_candidates({"buxoro": "ok", "navoiy": "bad"}, fetch=fetch)
        self.assertEqual(len(items), 4)
        self.assertTrue(all(i["source"] == "egov-buxoro" for i in items))

    def test_pages_are_walked(self):
        rows = [{"id": str(i), "tableColumn": {}} for i in range(5)]
        calls = []

        def page(guid, offset, limit):
            calls.append(offset)
            return rows[offset:offset + limit], len(rows)
        got = bcc.fetch_rows("g", page=2, fetch=page)
        self.assertEqual(len(got), 5)
        self.assertEqual(calls, [0, 2, 4])


if __name__ == "__main__":
    unittest.main()
