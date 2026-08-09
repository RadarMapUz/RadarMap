#!/usr/bin/env python3
"""Тесты resnap_moved: точка модератора неприкосновенна, профиль снимается
заново у новой точки, протухший twin не переживает переезд партнёра.
Без данных и сети — дорога синтетическая, во временном файле."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import snap_cameras as snap
import resnap_moved as rm


def road_file():
    """Прямая односторонняя улица на север, ~2 км."""
    coords = [[69.2800, 41.3000 + i * 0.002] for i in range(11)]
    feature = {"type": "Feature",
               "properties": {"highway": "secondary", "name": "Test ko'chasi",
                              "lanes": "4", "oneway": "yes"},
               "geometry": {"type": "LineString", "coordinates": coords}}
    f = tempfile.NamedTemporaryFile("w", suffix=".geojson", delete=False,
                                    encoding="utf-8")
    json.dump({"type": "FeatureCollection", "features": [feature]}, f)
    f.close()
    return f.name


class ResnapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.index, _, _ = snap.load_roads(road_file())

    def cam(self, cid, lat, lon, **extra):
        out = {"id": cid, "lat": lat, "lon": lon, "type": "Стационар радар",
               "location": "Тест"}
        out.update(extra)
        return out

    def test_moved_camera_keeps_moderator_point_and_gets_fresh_profile(self):
        stale = self.cam(1, 41.4000, 69.4000, axis=90, dir=90, road=[1, 2, 3, 4],
                         split=True, twin=True, needsReview=True)
        items = [{"id": 1, "op": "move", "lat": 41.3100, "lon": 69.28001}]
        result, report = rm.resnap([stale], items, self.index)
        out = result[0]
        # Точка модератора — истина: пересъёмка её не трогает.
        self.assertAlmostEqual(out["lat"], 41.3100)
        self.assertAlmostEqual(out["lon"], 69.28001)
        # Профиль свежий: ось ≈ север, oneway дал направление, кусок дороги снят.
        self.assertIsNotNone(out.get("axis"))
        self.assertLess(min(out["axis"], 180 - out["axis"]), 10)
        self.assertIsNotNone(out.get("dir"))
        self.assertIn("road", out)
        self.assertNotEqual(out.get("road"), [1, 2, 3, 4])
        # Дорога нашлась под человеческой точкой — подозрение снято.
        self.assertNotIn("needsReview", out)
        self.assertIn("переснят", report[0][3])

    def test_move_into_emptiness_clears_profile_and_flags_review(self):
        cam = self.cam(1, 41.3100, 69.2800, axis=0, dir=0, road=[1, 2, 3, 4])
        items = [{"id": 1, "op": "move", "lat": 41.3100, "lon": 69.5000}]
        result, report = rm.resnap([cam], items, self.index)
        out = result[0]
        self.assertTrue(out.get("needsReview"))
        # Протухший профиль мерен у другой точки — пережить переезд не имеет права.
        for key in ("axis", "dir", "road", "split", "twin"):
            self.assertNotIn(key, out)
        self.assertIn("не нашлось", report[0][3])

    def test_non_move_and_unknown_ids_leave_base_untouched(self):
        cam = self.cam(7, 41.3100, 69.2800, axis=0)
        items = [{"id": 7, "op": "hide"},
                 {"id": 999, "op": "move", "lat": 41.31, "lon": 69.28},
                 {"id": 7, "op": "retype", "type": "Стационар камера"}]
        result, report = rm.resnap([cam], items, self.index)
        self.assertEqual(result[0], cam)   # hide/retype — не про геометрию
        self.assertEqual(len(report), 1)   # но пропуск чужого id виден в отчёте
        self.assertIn("пропуск", report[0][3])

    def test_stale_twin_does_not_survive_partner_move(self):
        a = self.cam(2, 41.3100, 69.2800, dir=0, twin=True)
        b = self.cam(3, 41.3104, 69.2800, dir=180, twin=True)
        items = [{"id": 3, "op": "move", "lat": 41.3104, "lon": 69.5000}]
        result, _ = rm.resnap([a, b], items, self.index)
        by_id = {c["id"]: c for c in result}
        self.assertNotIn("twin", by_id[3], "уехавшая камера: профиль пуст")
        self.assertNotIn("twin", by_id[2],
                         "бывший партнёр: пары больше нет — глушить по "
                         "направлению из-за протухшей метки нельзя")


if __name__ == "__main__":
    unittest.main(verbosity=2)
