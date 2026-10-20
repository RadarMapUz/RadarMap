#!/usr/bin/env python3
"""Тесты resnap_profiles (11.3): точка камеры неприкосновенна, тротуар в индекс
не попадает, профиль пишется только по доказательству — на перекрёстке без
имени и у кармана рядом с магистралью профиль остаётся прежним, потому что
доверенный неверный профиль глушит камеру, а недоверенный только шумит.
Без данных и сети — дороги синтетические, во временном файле."""
import copy
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import snap_cameras as snap
import resnap_profiles as rp


def line(highway, coords, **props):
    props = dict(props, highway=highway)
    return {"type": "Feature", "properties": props,
            "geometry": {"type": "LineString", "coordinates": coords}}


def north(lon, lat0=41.300, lat1=41.320):
    return [[lon, lat0 + (lat1 - lat0) * k / 10] for k in range(11)]


def roads_file():
    features = [
        # A: односторонняя улица на север и тротуар вдоль неё (~12 м восточнее).
        line("secondary", north(69.2800), name="Test ko'chasi", oneway="yes", lanes="3"),
        line("footway", north(69.28015)),
        # B: перекрёсток двух безымянных для адреса улиц.
        line("secondary", north(69.3000), name="Birinchi"),
        line("secondary", [[69.290, 41.3100], [69.310, 41.3100]], name="Ikkinchi"),
        # C: боковой проезд и магистраль в ~25 м от него.
        line("service", north(69.3200)),
        line("primary", north(69.3203), name="Katta"),
        # D: трасса с ref и ближе к камере — жилая улица.
        line("trunk", north(69.3403), ref="M39"),
        line("residential", north(69.3400), name="Boshqa"),
        # Грунтовка: камера рядом с ней — всё равно «нет проезжей части».
        line("track", north(69.4000)),
    ]
    f = tempfile.NamedTemporaryFile("w", suffix=".geojson", delete=False,
                                    encoding="utf-8")
    json.dump({"type": "FeatureCollection", "features": features}, f)
    f.close()
    return f.name


def cam(cid, lat, lon, location="Тест", **extra):
    out = {"id": cid, "region": "R", "city": "C", "location": location,
           "lat": lat, "lon": lon, "type": "Стационар радар"}
    out.update(extra)
    return out


FOOTWAY = dict(axis=0, cls="footway", road=[0, 0, 100, 0])


class ResnapProfilesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = roads_file()
        cls.index, _, _ = snap.load_roads(cls.path, keep_highway=rp.is_carriageway)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.path)

    def run_one(self, camera, others=()):
        cameras = [camera, *others]
        result, rows = rp.resnap_profiles(cameras, self.index)
        return result, rows

    # --- отбор -----------------------------------------------------------

    def test_needs_resnap_classes(self):
        self.assertEqual(rp.needs_resnap({"cls": "footway", "axis": 5}), "pedestrian")
        self.assertEqual(rp.needs_resnap({"cls": "platform"}), "pedestrian")
        self.assertEqual(rp.needs_resnap({"cls": "bus_stop", "axis": 1}), "pedestrian")
        self.assertEqual(rp.needs_resnap({"needsReview": True}), "no-profile")
        self.assertIsNone(rp.needs_resnap({"cls": "primary", "axis": 10, "road": [1, 2]}))
        self.assertIsNone(rp.needs_resnap({"cls": "service", "axis": 10}))

    def test_pedestrian_set_matches_app_rule(self):
        # RoadShape.swift: RoadClass.init(raw:) → .pedestrian ровно для этих.
        self.assertEqual(rp.PEDESTRIAN_CLASSES, {
            "footway", "path", "cycleway", "steps", "pedestrian", "platform", "bus_stop"})
        self.assertFalse(rp.PEDESTRIAN_CLASSES & rp.CARRIAGEWAY_CLASSES)

    def test_index_holds_no_footways_or_tracks(self):
        classes = {a.cls for a in self.index.attrs}
        self.assertNotIn("footway", classes)
        self.assertNotIn("track", classes)
        self.assertIn("secondary", classes)

    # --- выбор дороги ----------------------------------------------------

    def test_footway_camera_gets_carriageway_at_same_point(self):
        c = cam(1, 41.3100, 69.28013, location="Test ko'chasi", needsReview=True,
                **FOOTWAY)
        result, rows = self.run_one(c)
        out = result[0]
        self.assertEqual((out["lat"], out["lon"]), (41.3100, 69.28013),
                         "координата не двигается")
        self.assertEqual(out["cls"], "secondary")
        self.assertEqual(out["dir"], 0, "односторонняя на север")
        self.assertEqual(out["lanes"], 3)
        self.assertLess(min(out["axis"], 180 - out["axis"]), 3)
        self.assertNotEqual(out["road"], FOOTWAY["road"])
        self.assertTrue(out["needsReview"], "точку человек не проверял — флаг остаётся")
        self.assertEqual(rows[0]["status"], "fixed")
        self.assertIn("name", rows[0]["note"])
        # Исходный список не изменён.
        self.assertEqual(c["cls"], "footway")

    def test_road_stub_is_relative_to_unmoved_camera(self):
        c = cam(1, 41.3100, 69.28013, location="Test ko'chasi", **FOOTWAY)
        out = self.run_one(c)[0][0]
        # Кусок — дельты 1e-6° от камеры: ось дороги в ~11 м западнее.
        dlons = out["road"][1::2]
        self.assertTrue(all(-140 <= d <= -120 for d in dlons), dlons)

    def test_no_carriageway_keeps_profile(self):
        c = cam(2, 41.3100, 69.4001, **FOOTWAY)   # рядом только грунтовка
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[0]["status"], "no_carriageway")

    def test_no_profile_camera_far_from_roads_stays_empty(self):
        c = cam(3, 41.3100, 69.5000, needsReview=True)
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[0]["reason"], "no-profile")
        self.assertIn("300 м", rows[0]["note"])

    def test_no_profile_camera_on_road_gets_profile(self):
        c = cam(4, 41.3100, 69.28005, location="Test ko'chasi", needsReview=True)
        out = self.run_one(c)[0][0]
        self.assertEqual(out["cls"], "secondary")
        self.assertIn("road", out)

    def test_unnamed_intersection_is_ambiguous(self):
        c = cam(5, 41.3101, 69.3001, location="Noma'lum joy", **FOOTWAY)
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c, "на перекрёстке без имени не угадываем")
        self.assertEqual(rows[0]["status"], "ambiguous")

    def test_named_intersection_takes_the_named_street(self):
        c = cam(6, 41.3101, 69.3001, location="Ikkinchi ko'chasi", **FOOTWAY)
        out = self.run_one(c)[0][0]
        self.assertEqual(out["axis"], 90, "ось улицы из адреса, а не ближайшей")

    def test_minor_road_next_to_major_is_ambiguous(self):
        # Карман в 4 м, магистраль в ~29 м: дальше запаса, но в радиусе.
        c = cam(7, 41.3100, 69.31995, **FOOTWAY)
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[0]["status"], "ambiguous")

    def test_major_beats_closer_service_within_margin(self):
        c = cam(8, 41.3100, 69.3201, **FOOTWAY)   # проезд ~8 м, магистраль ~17 м
        out = self.run_one(c)[0][0]
        self.assertEqual(out["cls"], "primary")

    def test_ref_beats_closer_road(self):
        c = cam(9, 41.3100, 69.34005, location="M-39 avtomobil yo'li 12 km", **FOOTWAY)
        out = self.run_one(c)[0][0]
        self.assertEqual(out["cls"], "trunk")

    def test_trusted_cameras_are_untouched(self):
        other = cam(10, 41.3100, 69.3001, axis=0, cls="secondary", road=[0, 0, 1, 1],
                    dir=0, split=True)
        result, rows = rp.resnap_profiles([other], self.index)
        self.assertEqual(result[0], other)
        self.assertEqual(rows, [])

    # --- пары и проверка различий -----------------------------------------

    def test_twins_are_remarked_across_the_base(self):
        fixed = cam(11, 41.3100, 69.28013, location="Test ko'chasi", **FOOTWAY)
        partner = cam(12, 41.3104, 69.2800, axis=0, cls="secondary", dir=180,
                      split=True, road=[0, 0, 1, 1])
        stale = cam(13, 41.5000, 69.9000, axis=0, cls="primary", dir=0, split=True,
                    road=[0, 0, 1, 1], twin=True)
        result, _ = rp.resnap_profiles([fixed, partner, stale], self.index)
        by_id = {c["id"]: c for c in result}
        self.assertTrue(by_id[11].get("twin"))
        self.assertTrue(by_id[12].get("twin"))
        self.assertNotIn("twin", by_id[13], "пары нет — признак не переживает")
        stats = rp.verify_diff([fixed, partner, stale], result, {11})
        self.assertEqual(stats["profile_changed"], [11])
        self.assertEqual(stats["twin_added"], [11, 12])
        self.assertEqual(stats["twin_removed"], [13])

    def test_verify_diff_refuses_moves_and_foreign_changes(self):
        base = [cam(1, 41.31, 69.28, **FOOTWAY), cam(2, 41.32, 69.28, axis=5, cls="primary")]
        moved = copy.deepcopy(base)
        moved[0]["lat"] = 41.3101
        with self.assertRaises(ValueError):
            rp.verify_diff(base, moved, {1})
        foreign = copy.deepcopy(base)
        foreign[1]["axis"] = 6
        with self.assertRaises(ValueError):
            rp.verify_diff(base, foreign, {1})
        flag = copy.deepcopy(base)
        flag[0]["needsReview"] = True
        with self.assertRaises(ValueError):
            rp.verify_diff(base, flag, {1})
        reordered = list(reversed(base))
        with self.assertRaises(ValueError):
            rp.verify_diff(base, reordered, {1, 2})

    def test_verify_diff_accepts_real_run(self):
        cameras = [cam(1, 41.3100, 69.28013, location="Test ko'chasi", **FOOTWAY),
                   cam(2, 41.3101, 69.3001, **FOOTWAY),
                   cam(3, 41.3300, 69.2800, axis=0, cls="secondary", road=[0, 0, 1, 1])]
        result, _ = rp.resnap_profiles(cameras, self.index)
        stats = rp.verify_diff(cameras, result,
                               {c["id"] for c in cameras if rp.needs_resnap(c)})
        self.assertEqual(stats["profile_changed"], [1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
