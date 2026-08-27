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


if __name__ == "__main__":
    unittest.main()


class WrittenLayersTests(unittest.TestCase):
    """Дома и поверхность попадают в MVT из УЖЕ НАПИСАННЫХ тайлов.

    Оба слоя пишутся потоком, прямо в файлы, и в списке areas их нет вовсе —
    иначе сборка страны не поместится в память. Однажды это уже стоило
    картинки: карта на MapLibre поднялась без полотна и без домов, и понять
    это можно было только глазами.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def write(self, set_name, rows):
        path = os.path.join(self.dir, f"road2_2626_4985_{set_name}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": rows}, handle)

    def square(self):
        return [4131100, 6928000, 60, 0, 0, 60, -60, 0]

    def test_houses_and_surface_reach_the_tile(self):
        self.write("h", [[build_mvt.AREA_HOUSE, 1, self.square()]])
        self.write("d", [[build_mvt.AREA_ROAD,
                          1 | (3 << build_mvt.SURFACE_CLASS_SHIFT),
                          self.square()]])
        build_mvt.build_mvt([], self.dir)
        names = set()
        for folder, _dirs, files in os.walk(os.path.join(self.dir, "mvt")):
            for name in files:
                with open(os.path.join(folder, name), "rb") as handle:
                    names.update(parse(handle.read()))
        self.assertIn(build_mvt.LAYER_HOUSES, names, "домов в MVT нет")
        self.assertIn(build_mvt.LAYER_SURFACE, names, "поверхности в MVT нет")

    def test_road_tiles_are_not_read_as_areas(self):
        # Набор улиц — это линии сети, а не местность: прочитать его сюда
        # значило бы нарисовать каждую дорогу дважды.
        self.write("s", [[3, 0, self.square()]])
        self.assertEqual(list(build_mvt.written_areas(self.dir, "h")), [])
        self.assertEqual(list(build_mvt.written_areas(self.dir, "d")), [])

    def test_missing_directory_is_not_an_error(self):
        self.assertEqual(list(build_mvt.written_areas("/нет/такого", "h")), [])
