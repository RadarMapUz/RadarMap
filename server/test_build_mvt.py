import gzip
import json
import os
import shutil
import tempfile
import unittest

import build_mvt
import mvt
from test_mvt import parse, shapes_of


class BuildTests(unittest.TestCase):
    """MVT пишется из ТЕХ ЖЕ данных, что наш JSON, — не второй копией карты."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def road(self, points, code=3, flags=0, name="Навои"):
        return (code, flags, points, name)

    def tiles(self):
        root = os.path.join(self.dir, "mvt")
        out = []
        for folder, _dirs, names in os.walk(root):
            for name in names:
                out.append(os.path.join(folder, name))
        return sorted(out)

    def parsed(self, path):
        with open(path, "rb") as handle:
            return parse(handle.read())

    def test_road_becomes_a_line_with_its_properties(self):
        made = build_mvt.build_mvt(
            [self.road([(69.28, 41.311), (69.281, 41.312)], code=3,
                       flags=build_mvt.FLAG_ONEWAY)], self.dir)
        self.assertTrue(made, "ни одного тайла")
        layers = self.parsed(self.tiles()[0])
        self.assertIn(build_mvt.LAYER_ROADS, layers)
        layer = layers[build_mvt.LAYER_ROADS]
        feature = layer["features"][0]
        self.assertEqual(feature["type"], mvt.LINESTRING)
        props = {layer["keys"][feature["tags"][i]]:
                 layer["values"][feature["tags"][i + 1]]
                 for i in range(0, len(feature["tags"]), 2)}
        self.assertEqual(props["cls"], 3)
        self.assertEqual(props["name"], "Навои")
        self.assertTrue(props["oneway"])
        self.assertIn("width", props)

    def test_layers_are_kept_apart(self):
        made = build_mvt.build_mvt(
            [self.road([(69.28, 41.311), (69.281, 41.312)])], self.dir,
            areas=[(build_mvt.AREA_HOUSE, 1,
                    [(69.280, 41.3110), (69.2805, 41.3110),
                     (69.2805, 41.3115), (69.280, 41.3115)]),
                   (1, 1, [(69.2802, 41.3112), (69.2807, 41.3112),
                           (69.2807, 41.3117)])],
            points=[(1, 0, [(69.2801, 41.3111)])])
        names = set()
        for path in self.tiles():
            names.update(self.parsed(path))
        self.assertEqual(names, {build_mvt.LAYER_ROADS, build_mvt.LAYER_HOUSES,
                                 build_mvt.LAYER_LAND, build_mvt.LAYER_POINTS})

    def test_surface_carries_its_class(self):
        flags = 1 | (4 << build_mvt.SURFACE_CLASS_SHIFT)
        build_mvt.build_mvt([], self.dir, areas=[(build_mvt.AREA_ROAD, flags,
            [(69.280, 41.3110), (69.2805, 41.3110), (69.2805, 41.3115)])])
        layers = self.parsed(self.tiles()[0])
        layer = layers[build_mvt.LAYER_SURFACE]
        feature = layer["features"][0]
        props = {layer["keys"][feature["tags"][i]]:
                 layer["values"][feature["tags"][i + 1]]
                 for i in range(0, len(feature["tags"]), 2)}
        self.assertEqual(props["cls"], 4)
        self.assertEqual(feature["type"], mvt.POLYGON)

    def test_far_network_goes_to_its_own_zoom(self):
        build_mvt.build_mvt([], self.dir,
                            far=[self.road([(69.28, 41.311), (69.30, 41.32)])])
        paths = self.tiles()
        self.assertTrue(paths)
        for path in paths:
            self.assertIn(f"/mvt/{build_mvt.ZOOM_FAR}/", path)

    def test_road_across_a_border_lands_in_both_tiles(self):
        # Как у нас в JSON: дубль на границе дешевле, чем склейка на клиенте.
        far_apart = [(69.20, 41.30), (69.35, 41.30)]
        made = build_mvt.build_mvt([self.road(far_apart)], self.dir)
        self.assertGreater(len(made), 1, "дорога легла в один тайл")

    def test_long_segment_reaches_every_intermediate_tile(self):
        points = [(69.20, 41.30), (69.35, 41.30)]
        build_mvt.build_mvt([self.road(points)], self.dir)
        x0, y = mvt.tile_of(41.30, 69.20, build_mvt.ZOOM_DETAIL)
        x1, _ = mvt.tile_of(41.30, 69.35, build_mvt.ZOOM_DETAIL)
        for x in range(x0, x1 + 1):
            path = os.path.join(self.dir, "mvt", str(build_mvt.ZOOM_DETAIL),
                                str(x), f"{y}.mvt")
            self.assertTrue(os.path.exists(path), f"missing intermediate tile {x}/{y}")
            self.assertIn(build_mvt.LAYER_ROADS, self.parsed(path))

    def test_polygon_interior_reaches_tiles_without_vertices(self):
        polygon = [(69.20, 41.30), (69.35, 41.30),
                   (69.35, 41.40), (69.20, 41.40)]
        build_mvt.build_mvt([], self.dir, areas=[(1, 1, polygon)])
        x, y = mvt.tile_of(41.35, 69.27, build_mvt.ZOOM_DETAIL)
        path = os.path.join(self.dir, "mvt", str(build_mvt.ZOOM_DETAIL),
                            str(x), f"{y}.mvt")
        self.assertTrue(os.path.exists(path), "polygon interior is missing")
        self.assertIn(build_mvt.LAYER_LAND, self.parsed(path))

    def test_bytes_do_not_change_between_runs(self):
        # Недетерминированная сборка меняет байты каждую неделю, и всё, что
        # кэшируется по хэшу, качается заново.
        roads = [self.road([(69.280, 41.3110), (69.2805, 41.3112)]),
                 self.road([(69.2802, 41.3111), (69.2807, 41.3113)], name="Тест")]
        first = build_mvt.build_mvt(roads, self.dir)
        def read(path):
            with open(path, "rb") as handle:
                return handle.read()

        blobs = {p: read(p) for p in self.tiles()}
        second = build_mvt.build_mvt(list(reversed(roads)), self.dir)
        self.assertEqual(first, second)
        for path, blob in blobs.items():
            self.assertEqual(read(path), blob, path)

    def test_no_working_files_are_left(self):
        build_mvt.build_mvt([self.road([(69.28, 41.311), (69.281, 41.312)])],
                            self.dir)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "_mvt")))

    def test_more_tiles_than_open_files(self):
        roads = [self.road([(69.0 + i * 0.02, 41.3), (69.005 + i * 0.02, 41.3)])
                 for i in range(12)]
        made = build_mvt.build_mvt(roads, self.dir, handles=3)
        self.assertGreater(len(made), 3)

    def test_empty_input_writes_nothing(self):
        self.assertEqual(build_mvt.build_mvt([], self.dir), {})
        self.assertEqual(self.tiles(), [])

    def test_only_confirmed_oneway_lanes_are_marked(self):
        points = [(69.28, 41.311), (69.282, 41.311)]
        tagged = build_mvt.FLAG_LANES_TAGGED | (3 << 4)
        self.assertEqual(list(build_mvt.lane_markings([self.road(points, flags=tagged)])), [])
        self.assertEqual(list(build_mvt.lane_markings([self.road(points, flags=build_mvt.FLAG_ONEWAY)])), [])
        lines = list(build_mvt.lane_markings([self.road(points, flags=tagged | build_mvt.FLAG_ONEWAY)]))
        self.assertEqual(len(lines), 2)
        self.assertLess(lines[0][0][1], points[0][1])
        self.assertGreater(lines[1][0][1], points[0][1])

    def test_markings_stop_before_crossing_and_resume_after(self):
        center = (69.28, 41.311)
        flags = build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (2 << 4)
        roads = [self.road([(69.278, 41.311), center], flags=flags),
                 self.road([center, (69.282, 41.311)], flags=flags),
                 self.road([(69.28, 41.309), center]),
                 self.road([center, (69.28, 41.313)])]
        lines = list(build_mvt.lane_markings(roads))
        self.assertEqual(len(lines), 2)
        self.assertLess(lines[0][-1][0], center[0] - .00005)
        self.assertGreater(lines[1][0][0], center[0] + .00005)

    def test_simple_continuation_has_no_marking_gap(self):
        middle = (69.28, 41.311)
        flags = build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (2 << 4)
        lines = list(build_mvt.lane_markings([
            self.road([(69.278, 41.311), middle], flags=flags),
            self.road([middle, (69.282, 41.311)], flags=flags)]))
        self.assertAlmostEqual(lines[0][-1][0], lines[1][0][0], places=8)
        self.assertAlmostEqual(lines[0][-1][1], lines[1][0][1], places=8)

    def test_bridge_does_not_create_a_ground_level_gap(self):
        middle = (69.28, 41.311)
        flags = build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (2 << 4)
        roads = [self.road([(69.278, 41.311), middle], flags=flags),
                 self.road([middle, (69.282, 41.311)], flags=flags),
                 self.road([middle, (69.28, 41.313)], flags=build_mvt.FLAG_BRIDGE)]
        lines = list(build_mvt.lane_markings(roads))
        self.assertAlmostEqual(lines[0][-1][0], middle[0], places=8)

    def test_markings_are_in_detail_tile_only(self):
        road = self.road([(69.28, 41.311), (69.281, 41.311)],
                         flags=build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (2 << 4))
        build_mvt.build_mvt([road], self.dir, far=[road])
        for path in self.tiles():
            expected = f"/mvt/{build_mvt.ZOOM_DETAIL}/" in path
            self.assertEqual(build_mvt.LAYER_MARKINGS in self.parsed(path), expected)


class DraftTests(unittest.TestCase):
    """Черновики тайлов: диск — расплата за память, но соразмерная.

    Несжатые черновики заняли 17 ГБ против 1,7 ГБ готового набора, забили диск
    сервера до нуля и едва не уронили живой api, который пишет базу на тот же
    том. Тесты здесь сторожат обе половины починки.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_drafts_are_written_compressed(self):
        work = os.path.join(self.dir, "_mvt")
        buckets = build_mvt._Buckets(work)
        buckets.sink("14_1_2").write('["roads",2,[[0,0]],{}]\n')
        buckets.close()
        path = os.path.join(work, "14_1_2.jsonl.gz")
        self.assertTrue(os.path.exists(path), "черновик обязан быть .jsonl.gz")
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(2), b"\x1f\x8b", "это должен быть gzip")
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            self.assertEqual(json.loads(handle.read())[0], "roads")

    def test_no_uncompressed_drafts_are_left_behind(self):
        roads = [(3, 0, [(69.2, 41.3), (69.21, 41.3)], "Навои")]
        build_mvt.build_mvt(roads, self.dir)
        stray = []
        for root, _dirs, files in os.walk(self.dir):
            stray += [f for f in files if f.endswith(".jsonl")]
        self.assertEqual(stray, [], "несжатых черновиков быть не должно")
        self.assertFalse(os.path.exists(os.path.join(self.dir, "_mvt")),
                         "рабочий каталог сносится после сборки")


if __name__ == "__main__":
    unittest.main(verbosity=1)