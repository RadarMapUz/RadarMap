import json
import math
import os
import shutil
import tempfile
import unittest

import tree_planting as tp

# Начало — у юго-западного угла тайла z15 с запасом: тест на лимит тайла
# обязан уложиться в один тайл.
_X, _Y = tp.tile_of(69.27, 41.31)
LON0 = (_X + 0.05) / (1 << tp.TILE_ZOOM) * 360 - 180
LAT0 = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (_Y + 0.95) / (1 << tp.TILE_ZOOM)))))
KX = tp.M_LAT * math.cos(math.radians(LAT0))


def square(x0, y0, side):
    """Квадрат в метрах от (LON0, LAT0) → кольцо в градусах (замкнутое)."""
    pts = [(x0, y0), (x0 + side, y0), (x0 + side, y0 + side), (x0, y0 + side), (x0, y0)]
    return [(LON0 + x / KX, LAT0 + y / tp.M_LAT) for x, y in pts]


def feature(props, ring, holes=()):
    return {"type": "Feature", "properties": props,
            "geometry": {"type": "MultiPolygon", "coordinates": [[ring, *holes]]}}


def line(props, pts_m):
    return {"type": "Feature", "properties": props,
            "geometry": {"type": "LineString",
                         "coordinates": [(LON0 + x / KX, LAT0 + y / tp.M_LAT) for x, y in pts_m]}}


def metres(tree):
    return (tree[0] - LON0) * KX, (tree[1] - LAT0) * tp.M_LAT


class PlantingTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def write(self, name, features):
        path = os.path.join(self.dir, name)
        with open(path, "w") as handle:
            for f in features:
                handle.write(json.dumps(f) + "\n")
        return path

    def test_park_gets_trees_on_a_lattice_away_from_its_edge(self):
        areas = self.write("a.geojsonl", [feature({"leisure": "park"}, square(0, 0, 200))])
        trees = tp.plant_from_files(areas)
        step = tp.PLANT_STEP[tp.PARK]
        expected = (200 / step) ** 2
        self.assertGreater(len(trees), expected * 0.6)
        self.assertLess(len(trees), expected * 1.2)
        for tree in trees:
            x, y = metres(tree)
            self.assertTrue(tp.PLANT_EDGE_METERS - 0.01 <= x <= 200 - tp.PLANT_EDGE_METERS + 0.01)
            self.assertTrue(tp.PLANT_EDGE_METERS - 0.01 <= y <= 200 - tp.PLANT_EDGE_METERS + 0.01)

    def test_same_input_same_trees(self):
        areas = self.write("a.geojsonl", [feature({"leisure": "park"}, square(0, 0, 150))])
        self.assertEqual(tp.plant_from_files(areas), tp.plant_from_files(areas))

    def test_trees_avoid_paths_roads_houses_water_and_holes(self):
        areas = self.write("a.geojsonl", [
            feature({"leisure": "park"}, square(0, 0, 300), holes=[square(200, 200, 80)[::-1]]),
            feature({"natural": "water"}, square(20, 200, 60)),
            feature({"leisure": "playground"}, square(200, 20, 50))])
        roads = self.write("r.geojsonl", [line({"highway": "footway"}, [(0, 100), (300, 100)]),
                                          line({"highway": "primary"}, [(150, 0), (150, 300)])])
        houses = self.write("h.geojsonl", [feature({"building": "yes"}, square(40, 30, 40))])
        trees = tp.plant_from_files(areas, roads, houses)
        self.assertGreater(len(trees), 50)
        for tree in trees:
            x, y = metres(tree)
            self.assertGreaterEqual(abs(y - 100), tp.PATH_HALF_METERS + tp.CROWN_CLEAR_METERS - 0.05, tree)
            self.assertGreaterEqual(abs(x - 150), tp.ROAD_HALF_METERS["primary"] + tp.CROWN_CLEAR_METERS - 0.05)
            self.assertFalse(40 - 1 <= x <= 80 + 1 and 30 - 1 <= y <= 70 + 1, "на доме")
            self.assertFalse(20 <= x <= 80 and 200 <= y <= 260, "в пруду")
            self.assertFalse(200 <= x <= 250 and 20 <= y <= 70, "на площадке")
            self.assertFalse(200 <= x <= 280 and 200 <= y <= 280, "в дыре парка (поляна)")

    def test_osm_trees_are_not_doubled(self):
        areas = self.write("a.geojsonl", [feature({"leisure": "park"}, square(0, 0, 120))])
        bare = tp.plant_from_files(areas)
        existing = [(LON0 + x / KX, LAT0 + y / tp.M_LAT) for x in range(5, 120, 5) for y in range(5, 120, 5)]
        self.assertEqual(tp.plant_from_files(areas, existing=existing), [], "OSM уже засадил сквер")
        self.assertTrue(bare)

    def test_narrow_or_small_lawn_and_big_forest_are_skipped(self):
        areas = self.write("a.geojsonl", [
            feature({"landuse": "grass"}, [(LON0, LAT0), (LON0 + 400 / KX, LAT0),
                                           (LON0 + 400 / KX, LAT0 + 6 / tp.M_LAT), (LON0, LAT0 + 6 / tp.M_LAT),
                                           (LON0, LAT0)]),
            feature({"landuse": "grass"}, square(1000, 0, 40)),
            feature({"natural": "wood"}, square(0, 2000, 800))])
        self.assertEqual(tp.plant_from_files(areas), [])

    def test_tile_cap_keeps_parks_first(self):
        green = [(tp.GRASS, [square(0, 0, 300)], None), (tp.PARK, [square(400, 0, 200)], None)]
        self.assertEqual(len({tp.tile_of(*p) for _k, r, _b in green for p in r[0]}), 1)
        green = [(k, r, tp._box(r)) for k, r, _ in green]
        trees = tp.plant(sorted(green, key=lambda g: tp.RANK[g[0]]), tile_max=60)
        self.assertEqual(len(trees), 60)
        self.assertTrue(all(metres(t)[0] >= 400 for t in trees), "газон уступает парку")


if __name__ == "__main__":
    unittest.main()
