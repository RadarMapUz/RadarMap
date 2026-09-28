import gzip
import json
import math
import os
import shutil
import tempfile
import unittest

import build_mvt
import build_roads
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

    def test_stop_control_is_not_a_painted_line(self):
        flags = build_roads.point_flags(0, 12)
        self.assertEqual(build_mvt.point_properties(3, flags)["kind"], 7)
        self.assertFalse(build_mvt.point_properties(3, flags)["painted"])
        self.assertEqual(list(build_mvt.road_paint(3, flags, (69.28, 41.31))), [])

    def test_stop_paint_never_spans_unproven_two_way_road(self):
        flags = build_roads.point_flags(0, 12) | build_roads.PFLAG_PAINTED
        self.assertEqual(list(build_mvt.road_paint(3, flags, (69.28, 41.31))), [])
        line = list(build_mvt.road_paint(3, flags | build_roads.PFLAG_ONEWAY, (69.28, 41.31)))
        self.assertEqual(len(line), 1)
        self.assertAlmostEqual(line[0][0][1], line[0][1][1])
        self.assertAlmostEqual(build_roads.meters_between(*line[0]), 12, delta=.1)

    def test_crossing_paint_needs_explicit_markings(self):
        flags = build_roads.point_flags(90, 8)
        self.assertEqual(list(build_mvt.road_paint(5, flags, (69.28, 41.31))), [])
        stripes = list(build_mvt.road_paint(5, flags | build_roads.PFLAG_PAINTED, (69.28, 41.31)))
        self.assertEqual(len(stripes), 8)
        for a, b in stripes:
            self.assertAlmostEqual(a[1], b[1])
            self.assertAlmostEqual(build_roads.meters_between(a, b), 3, delta=.1)

    def test_detail_signals_keep_separate_approaches(self):
        road = self.road([(69.28, 41.30), (69.28, 41.32)])
        raw = [(1, 0, [(69.28, 41.3099)]), (1, 0, [(69.28, 41.3101)])]
        snapped, dropped = build_roads.snap_points(raw, [road])
        self.assertEqual(dropped, 0)
        self.assertEqual(len(snapped), 2)
        self.assertNotEqual(snapped[0][2], snapped[1][2])
        build_mvt.build_mvt([road], self.dir, points=snapped)
        features = [f for path in self.tiles()
                    for f in self.parsed(path).get(build_mvt.LAYER_POINTS, {}).get("features", [])]
        self.assertEqual(len(features), 2)

    def test_stop_line_tag_wins_regardless_of_property_order(self):
        self.assertEqual(build_roads.point_kind({"highway": "stop", "road_marking": "stop_line"}), 3)
        self.assertEqual(build_roads.point_kind({"road_marking": "stop_line", "highway": "stop"}), 3)

    def test_explicit_paint_survives_collection_and_snapping(self):
        path = os.path.join(self.dir, "points.geojsonl")
        with open(path, "w") as file:
            for props in [{"highway": "stop"}, {"road_marking": "stop_line"},
                          {"highway": "crossing", "crossing:markings": "zebra"}]:
                file.write(json.dumps({"type": "Feature", "properties": props,
                                       "geometry": {"type": "Point", "coordinates": [69.28, 41.31]}}) + "\n")
        raw = build_roads.collect_points(path)
        road = self.road([(69.28, 41.30), (69.28, 41.32)], flags=build_mvt.FLAG_ONEWAY)
        snapped, _ = build_roads.snap_points(raw, [road])
        self.assertEqual([build_mvt.point_properties(k, f)["kind"] for k, f, _ in snapped], [7, 3, 5])
        self.assertEqual([bool(f & build_roads.PFLAG_PAINTED) for _, f, _ in snapped], [False, True, True])
        self.assertTrue(all(f & build_roads.PFLAG_ONEWAY for _, f, _ in snapped))

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

    def test_junction_area_cuts_the_markings(self):
        # Мукими × Бунёдкор: концы сегментов не совпадают с узлом, пунктир шёл
        # сеткой через перекрёсток. Режет площадь узла, а не степень конца.
        flags = build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (3 << 4)
        road = self.road([(69.278, 41.311), (69.282, 41.311)], flags=flags)
        box = [(69.2797, 41.3108), (69.2803, 41.3108), (69.2803, 41.3112), (69.2797, 41.3112)]
        mask = build_mvt.JunctionMask([box])
        lines = list(build_mvt.lane_markings([road], mask=mask))
        self.assertEqual(len(lines), 4, "по два разделителя полос с каждой стороны узла")
        for line in lines:
            self.assertFalse(any(mask.covers(p) for p in line))
        bridge = self.road(road[2], flags=flags | build_mvt.FLAG_BRIDGE)
        self.assertEqual(len(list(build_mvt.lane_markings([bridge], mask=mask))), 2,
                         "мост над узлом земли не режется")

    def test_core_between_two_divided_avenues_has_no_markings(self):
        # Два проспекта с раздельными проезжими: четыре точки пересечения по
        # углам квадрата. Внутри квадрата пунктира быть не должно.
        def m(dx, dy):
            return (69.28 + dx / (111_320 * math.cos(math.radians(41.311))), 41.311 + dy / 111_320)
        flags = build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (3 << 4)
        a, b = "Muqimiy ko'chasi", "Bunyodkor shoh ko'chasi"
        roads = []
        for y in (-10, 10):          # проезжие Мукими, разрезаны в точках пересечения
            roads += [(3, flags, [m(-200, y), m(-10, y)], a), (3, flags, [m(-10, y), m(10, y)], a),
                      (3, flags, [m(10, y), m(200, y)], a)]
        for x in (-10, 10):          # проезжие Бунёдкора
            roads += [(3, flags, [m(x, -200), m(x, -10)], b), (3, flags, [m(x, -10), m(x, 10)], b),
                      (3, flags, [m(x, 10), m(x, 200)], b)]
        cores = build_mvt.crossing_cores(roads)
        self.assertEqual(len(cores), 1)
        mask = build_mvt.JunctionMask(cores)
        self.assertTrue(mask.covers(m(0, 0)))
        self.assertFalse(mask.covers(m(0, 30)))
        for line in build_mvt.lane_markings(roads, mask=mask):
            self.assertFalse(any(mask.covers(p) for p in line))

    def test_crossover_of_one_street_is_not_a_core(self):
        # Разворот через разделительную — безымянная связка той же улицы.
        def m(dx, dy):
            return (69.28 + dx / (111_320 * math.cos(math.radians(41.311))), 41.311 + dy / 111_320)
        a = "Muqimiy ko'chasi"
        roads = [(3, 1, [m(-100, -10), m(0, -10)], a), (3, 1, [m(0, -10), m(100, -10)], a),
                 (3, 1, [m(-100, 10), m(0, 10)], a), (3, 1, [m(0, 10), m(100, 10)], a),
                 (3, 1, [m(0, -10), m(0, 10)], "")]
        self.assertEqual(build_mvt.crossing_cores(roads), [])

    def test_markings_follow_the_fitted_width(self):
        # Три полосы: разделитель в width/6 от оси — сдвиг прямо зависит от ширины.
        flags = build_mvt.FLAG_LANES_TAGGED | build_mvt.FLAG_ONEWAY | (3 << 4)
        road = self.road([(69.278, 41.311), (69.282, 41.311)], flags=flags)
        wide = list(build_mvt.lane_markings([road]))
        narrow = list(build_mvt.lane_markings([road], {id(road): 6.0}))
        axis = road[2][0][1]
        wide_off = abs(wide[0][0][1] - axis) * 111_320
        narrow_off = abs(narrow[0][0][1] - axis) * 111_320
        self.assertAlmostEqual(narrow_off, 1.0, delta=0.05, msg="полотно сужено до 6 м — пунктир в 1 м от оси")
        self.assertGreater(wide_off, narrow_off)

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


class FarOverviewTests(unittest.TestCase):
    """Обзорный зум: до 27.09.2026 в нём были одни дороги — сеть линий на
    чёрном без единого ориентира. Теперь туда едут вода, крупная зелень и
    названия мест; мелочь и подробности — нет."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def tiles_at(self, zoom):
        root = os.path.join(self.dir, "mvt", str(zoom))
        out = {}
        for folder, _dirs, names in os.walk(root):
            for name in names:
                with open(os.path.join(folder, name), "rb") as handle:
                    out[os.path.join(folder, name)] = parse(handle.read())
        return out

    def square(self, lon, lat, size):
        return [(lon, lat), (lon + size, lat), (lon + size, lat + size),
                (lon, lat + size), (lon, lat)]

    def test_far_land_goes_to_the_far_zoom_only(self):
        lake = (build_roads.AREA_WATER, build_roads.AREA_FLAG_CLOSED,
                self.square(69.28, 41.31, 0.01))
        build_mvt.build_mvt([], self.dir, far_areas=[lake])
        far = self.tiles_at(build_mvt.ZOOM_FAR)
        self.assertTrue(far)
        for layers in far.values():
            self.assertIn(build_mvt.LAYER_LAND, layers)
            land = layers[build_mvt.LAYER_LAND]
            self.assertTrue(land["features"])
            self.assertIn("kind", land["keys"])
            self.assertIn(build_roads.AREA_WATER, land["values"])
        self.assertFalse(self.tiles_at(build_mvt.ZOOM_DETAIL),
                         "обзорная местность не должна дублироваться в детальный зум")

    def test_place_is_named_and_ranked(self):
        city = (1, 0, [(69.2797, 41.3111)], "Toshkent")
        build_mvt.build_mvt([], self.dir, places=[city])
        for zoom in (build_mvt.ZOOM_DETAIL, build_mvt.ZOOM_FAR):
            tiles = self.tiles_at(zoom)
            self.assertEqual(len(tiles), 1, zoom)
            layer = next(iter(tiles.values()))[build_mvt.LAYER_PLACES]
            self.assertEqual(len(layer["features"]), 1)
            self.assertIn("Toshkent", layer["values"])
            self.assertIn("name", layer["keys"])
            self.assertIn("rank", layer["keys"])

    def test_small_places_stay_off_the_overview(self):
        hamlet = (4, 0, [(69.10, 41.20)], "Qoʻrgʻoncha")
        quarter = (6, 0, [(69.28, 41.31)], "Mavze 5")
        build_mvt.build_mvt([], self.dir, places=[hamlet, quarter])
        self.assertFalse(self.tiles_at(build_mvt.ZOOM_FAR))
        self.assertEqual(len(self.tiles_at(build_mvt.ZOOM_DETAIL)), 2)

    def test_nameless_place_is_dropped(self):
        self.assertIsNone(build_mvt.place_properties((1, 0, [(69.2, 41.3)], "  ")))
        self.assertIsNone(build_mvt.place_properties((1, 0, [], "Toshkent")))
        self.assertIsNone(build_mvt.place_properties((9, 0, [(69.2, 41.3)], "X")))

    def test_overview_bytes_do_not_change_between_runs(self):
        lake = (build_roads.AREA_WATER, build_roads.AREA_FLAG_CLOSED,
                self.square(69.28, 41.31, 0.01))
        places = [(1, 0, [(69.2797, 41.3111)], "Toshkent"), (5, 0, [(69.24, 41.33)], "Olmazor")]
        first = build_mvt.build_mvt([], self.dir, far_areas=[lake], places=places)
        second = build_mvt.build_mvt([], self.dir, far_areas=[lake], places=places)
        self.assertEqual(first, second)


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


class ClipTests(unittest.TestCase):
    """Полигон режется по своему тайлу, линия — нет.

    Покрытие внутренними тайлами заставило каждое озеро копироваться ЦЕЛИКОМ в
    каждый накрытый тайл: на боевой стране это дало 349 919 тайлов и 9,8 ГБ
    против 118 439 и 1,7. Ровно это уже проходили в дорожных тайлах — там же
    и лекарство, clip_ring.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def big_square(self):
        """Квадрат примерно 0,2° — заведомо шире одного тайла детального зума."""
        return [(69.10, 41.20), (69.30, 41.20), (69.30, 41.40),
                (69.10, 41.40), (69.10, 41.20)]

    def test_big_polygon_is_not_copied_whole_into_every_tile(self):
        written = build_mvt.build_mvt([], self.dir, areas=[(1, 1, self.big_square())])
        self.assertGreater(len(written), 4, "покрытие внутренними тайлами обязано остаться")
        # Целая копия — это пять вершин исходника В КАЖДОМ тайле; после
        # отсечения внутренний тайл несёт только свой кусок рамки.
        biggest = max(meta["bytes"] for meta in written.values())
        self.assertLess(biggest, 400, "тайл везёт кусок, а не весь полигон")

    def test_polygon_inside_one_tile_survives_intact(self):
        small = [(69.2000, 41.3000), (69.2005, 41.3000),
                 (69.2005, 41.3005), (69.2000, 41.3005), (69.2000, 41.3000)]
        written = build_mvt.build_mvt([], self.dir, areas=[(1, 1, small)])
        self.assertTrue(written, "маленькая площадь обязана попасть в тайл")

    def test_line_is_still_not_clipped(self):
        # Довод про имя и направление улицы на стыке остаётся в силе.
        road = (3, 0, [(69.10, 41.30), (69.30, 41.30)], "Навои")
        written = build_mvt.build_mvt([road], self.dir)
        self.assertGreater(len(written), 1, "длинная улица покрывает несколько тайлов")


if __name__ == "__main__":
    unittest.main(verbosity=1)
