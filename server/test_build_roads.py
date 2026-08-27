#!/usr/bin/env python3
"""Тесты сборки дорожных тайлов. Запуск: python3 server/test_build_roads.py

Главное, что здесь сторожится, — контракт с телефоном: формат дельт,
раскладка по тайлам (дорога на границе — в обоих) и то, что sha256 в индексе
считан от РОВНО тех байтов, которые лежат в файле тайла: подпись владельца
накрывает тайлы именно через эти хэши.
"""
import hashlib
import json
import os
import shutil
import tempfile
import io
import math
import sys
import unittest

import build_roads


def decode(encoded):
    """Эталонный декодер дельт — то же самое делает телефон (RoadTiles)."""
    points = []
    lat, lon = encoded[0], encoded[1]
    points.append((lat / build_roads.SCALE, lon / build_roads.SCALE))
    for i in range(2, len(encoded), 2):
        lat += encoded[i]
        lon += encoded[i + 1]
        points.append((lat / build_roads.SCALE, lon / build_roads.SCALE))
    return points


class EncodeTests(unittest.TestCase):
    def test_round_trip(self):
        # GeoJSON: [lon, lat]; декодер обязан вернуть те же точки в 1e-5°.
        source = [(69.25, 41.31), (69.251, 41.311), (69.253, 41.311)]
        encoded = build_roads.encode(source)
        decoded = decode(encoded)
        self.assertEqual(len(decoded), 3)
        for (lat, lon), (src_lon, src_lat) in zip(decoded, source):
            self.assertAlmostEqual(lat, src_lat, places=5)
            self.assertAlmostEqual(lon, src_lon, places=5)

    def test_duplicate_points_dropped(self):
        # После квантования соседние точки часто совпадают — чистый мусор.
        encoded = build_roads.encode([(69.25, 41.31), (69.25, 41.31),
                                      (69.251, 41.31)])
        self.assertEqual(len(encoded), 4, "дубль обязан быть выброшен")


class OrientationTests(unittest.TestCase):
    def test_reverse_oneway_is_flipped(self):
        # oneway=-1: односторонняя ПРОТИВ порядка точек. Телефон рисует
        # стрелки по порядку точек, поэтому геометрия разворачивается здесь.
        points = [(69.25, 41.31), (69.26, 41.31)]
        flipped = build_roads.oriented(points, {"oneway": "-1"})
        self.assertEqual(flipped[0], (69.26, 41.31))
        self.assertEqual(build_roads.flags_of({"oneway": "-1"}),
                         build_roads.FLAG_ONEWAY)

    def test_normal_oneway_is_untouched(self):
        points = [(69.25, 41.31), (69.26, 41.31)]
        self.assertEqual(build_roads.oriented(points, {"oneway": "yes"}), points)
        self.assertEqual(build_roads.oriented(points, {}), points)


class TileTests(unittest.TestCase):
    def test_border_road_lands_in_both_tiles(self):
        # Дорога через границу тайлов 0.5°: обязана лежать в обоих целиком.
        keys = build_roads.tile_keys_of([(69.49, 41.31), (69.51, 41.31)])
        self.assertEqual(len(keys), 2)

    def test_key_matches_client_formula(self):
        # (41.31 + 90) / 0.5 = 262.62 → 262; (69.25 + 180) / 0.5 = 498.5 → 498.
        self.assertEqual(build_roads.tile_key(41.31, 69.25), "262_498")

    def test_index_sha_matches_file_bytes(self):
        roads = [(3, 0, [(69.25, 41.31), (69.251, 41.311)], "")]
        with tempfile.TemporaryDirectory() as work:
            index, _ = build_roads.write_tiles(roads, work)
            self.assertIn("262_498", index)
            blob = open(os.path.join(work, "tile_262_498.json"), "rb").read()
            self.assertEqual(index["262_498"]["sha256"],
                             hashlib.sha256(blob).hexdigest(),
                             "подпись индекса накрывает тайл через этот sha")
            self.assertEqual(index["262_498"]["bytes"], len(blob))
            # И сам индексный payload лежит рядом и разбирается.
            payload = json.load(open(os.path.join(work, "index_payload.json")))
            self.assertEqual(payload["version"], 1)
            self.assertEqual(payload["tileDegrees"], build_roads.TILE_DEGREES)
            self.assertEqual(payload["tiles"]["262_498"]["sha256"],
                             index["262_498"]["sha256"])

    def test_tile_format_is_what_phone_expects(self):
        roads = [(1, 3, [(69.25, 41.31), (69.251, 41.311)], "")]
        with tempfile.TemporaryDirectory() as work:
            build_roads.write_tiles(roads, work)
            tile = json.load(open(os.path.join(work, "tile_262_498.json")))
            self.assertEqual(tile["version"], 1)
            code, flags, encoded = tile["roads"][0]
            self.assertEqual(code, 1)
            self.assertEqual(flags, 3)   # oneway | bridge
            self.assertEqual(decode(encoded)[0], (41.31, 69.25))


class GeneraliseTests(unittest.TestCase):
    """Генерализация: то, что раньше считал телефон на каждом квартале.

    Тесты здесь про ЗАПРЕТЫ. Дорожная сеть едет на телефоны молча и рисуется
    водителю за рулём — значит выдумать дорогу нельзя, развернуть
    одностороннюю нельзя, сшить магистраль с двором нельзя.
    """

    def road(self, code, flags, coords, name=""):
        return (code, flags, [(lon, lat) for lat, lon in coords], name)

    def line_north(self, code, flags, lon, lat0, lat1, steps=4, name=""):
        step = (lat1 - lat0) / steps
        return self.road(code, flags,
                         [(lat0 + step * i, lon) for i in range(steps + 1)], name)

    def test_side_road_ending_mid_way_becomes_a_node(self):
        # Главный случай, ради которого написана разрезка. В OSM топология
        # УЗЛОВАЯ: проспект проходит СКВОЗЬ перекрёсток одной линией, а боковая
        # улица в него упирается. Общий узел — внутренняя вершина одной линии
        # и конец другой, и склейка по концам его не видит вовсе.
        avenue = self.road(3, 0, [(41.300, 69.25), (41.301, 69.25), (41.302, 69.25)])
        side = self.road(3, 0, [(41.301, 69.25), (41.301, 69.252)])
        split = build_roads.split_at_junctions([avenue, side])
        self.assertEqual(len(split), 3, "проспект обязан разрезаться на узле")
        ends = {(round(r[2][0][1], 5), round(r[2][0][0], 5)) for r in split}
        ends |= {(round(r[2][-1][1], 5), round(r[2][-1][0], 5)) for r in split}
        self.assertIn((41.301, 69.25), ends)

    def test_split_does_not_cut_at_shape_vertices(self):
        # Вершина, через которую проходит одна линия, — это форма дороги, а не
        # перекрёсток. Резать по ней значило бы рассыпать сеть на отрезки.
        lonely = self.road(3, 0, [(41.300, 69.25), (41.301, 69.251), (41.302, 69.25)])
        self.assertEqual(len(build_roads.split_at_junctions([lonely])), 1)

    def test_loop_does_not_declare_itself_a_junction(self):
        # Кольцо возвращается в свою же вершину. Без дедупликации внутри линии
        # оно объявило бы себя перекрёстком и развалилось на куски.
        ring = self.road(3, 0, [(41.300, 69.250), (41.301, 69.251),
                                (41.300, 69.252), (41.300, 69.250)])
        self.assertEqual(len(build_roads.split_at_junctions([ring])), 1)

    def test_simplification_runs_after_the_graph_is_built(self):
        # Дуглас—Пекер держит концы, но выбрасывает внутренние вершины. Пока
        # он стоял ПЕРВЫМ, он стирал узлы перекрёстков раньше, чем из них
        # строился граф: на живом тайле Ташкента 20% концов оказались лежащими
        # на ОТРЕЗКЕ чужой линии, а не на её вершине.
        #
        # Узел здесь почти на прямой — ровно тот случай, который упрощение
        # съедает первым.
        avenue = self.road(3, 0, [(41.3000, 69.2500), (41.3010, 69.25001),
                                  (41.3020, 69.2500)])
        side = self.road(3, 0, [(41.3010, 69.25001), (41.3010, 69.2520)])
        tolerance = 4.0 / build_roads.LAT_METERS
        result = build_roads.generalise([avenue, side], tolerance)
        joints = [p for r in result for p in (r[2][0], r[2][-1])]
        self.assertTrue(any(abs(lat - 41.3010) < 1e-6 and abs(lon - 69.25001) < 1e-6
                            for lon, lat in joints),
                        "узел перекрёстка обязан пережить упрощение")

    def test_chain_of_ways_becomes_one_street(self):
        a = self.line_north(3, 0, 69.25, 41.300, 41.301)
        b = self.line_north(3, 0, 69.25, 41.301, 41.302)
        merged = build_roads.merge_ways([a, b])
        self.assertEqual(len(merged), 1, "два куска одной улицы — одна ломаная")
        self.assertEqual(merged[0][2][0], a[2][0])
        self.assertEqual(merged[0][2][-1], b[2][-1])

    def test_different_classes_never_merge(self):
        big = self.line_north(3, 0, 69.25, 41.300, 41.301)
        yard = self.line_north(7, 0, 69.25, 41.301, 41.302)
        self.assertEqual(len(build_roads.merge_ways([big, yard])), 2)

    def test_hairpin_is_not_merged(self):
        # Улица не разворачивается на себя в узле: склеенная шпилька рисуется
        # штрихом туда и обратно, и на экране это шип, торчащий из дороги.
        a = self.road(3, 0, [(41.300, 69.2500), (41.302, 69.2500)])
        b = self.road(3, 0, [(41.300, 69.2501), (41.302, 69.2501)])
        self.assertEqual(len(build_roads.merge_ways([a, b])), 2)

    def test_turn_degrees_measures_the_bend(self):
        straight = build_roads._turn_degrees((69.25, 41.30), (69.25, 41.31),
                                             (69.25, 41.32))
        self.assertAlmostEqual(straight, 0, places=3)
        back = build_roads._turn_degrees((69.25, 41.30), (69.25, 41.31),
                                         (69.25, 41.30))
        self.assertAlmostEqual(back, 180, places=3)

    def test_fork_stops_the_chain(self):
        # В узле три конца: продолжение неоднозначно, и выбирать наугад
        # нельзя — улица честно обрывается на перекрёстке.
        trunk = self.line_north(3, 0, 69.25, 41.300, 41.301)
        left = self.road(3, 0, [(41.301, 69.25), (41.302, 69.249)])
        right = self.road(3, 0, [(41.301, 69.25), (41.302, 69.251)])
        self.assertEqual(len(build_roads.merge_ways([trunk, left, right])), 3)

    def test_one_way_is_never_reversed(self):
        # Обе идут К общей точке. Развернуть одну, чтобы сшить, значило бы
        # пустить стрелки направления против движения.
        a = self.line_north(3, build_roads.FLAG_ONEWAY, 69.25, 41.300, 41.301)
        b = self.road(3, build_roads.FLAG_ONEWAY,
                      [(41.302, 69.25), (41.301, 69.25)])
        self.assertEqual(len(build_roads.merge_ways([a, b])), 2)

    def test_stubs_go_after_merging(self):
        # Пять кусков по двадцать метров — стометровая улица. Отсев по длине
        # КУСКА убил бы её целиком.
        step = 20 / build_roads.LAT_METERS
        pieces = [self.road(6, 0, [(41.3 + step * i, 69.25),
                                   (41.3 + step * (i + 1), 69.25)])
                  for i in range(5)]
        self.assertEqual(len(build_roads.generalise(pieces, 0)), 1)

    def test_lone_stub_is_dropped(self):
        short = self.road(7, 0, [(41.3, 69.25),
                                 (41.3 + 10 / build_roads.LAT_METERS, 69.25)])
        self.assertEqual(build_roads.generalise([short], 0), [])

    def test_chaikin_keeps_ends_and_rounds_corner(self):
        corner = [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0)]
        smoothed = build_roads.chaikin(corner)
        self.assertEqual(smoothed[0], corner[0])
        self.assertEqual(smoothed[-1], corner[-1])
        self.assertNotIn((0.0, 1.0), smoothed, "острый угол обязан исчезнуть")

    def test_opposite_carriageways_collapse(self):
        forward = self.line_north(3, build_roads.FLAG_ONEWAY, 69.2500,
                                  41.300, 41.303, steps=6)
        back = self.road(3, build_roads.FLAG_ONEWAY,
                         [(41.303 - 0.0005 * i, 69.2502) for i in range(7)])
        collapsed = build_roads.collapse_dual([forward, back], 45)
        self.assertEqual(len(collapsed), 1)
        self.assertFalse(collapsed[0][1] & build_roads.FLAG_ONEWAY,
                         "схлопнутая дорога двусторонняя: стрелки на ней были бы ложью")

    def test_axis_fades_instead_of_stepping_sideways(self):
        # Встречная проезжая часть покрывает только верх оси. Без затухания ось
        # прыгает вбок на половину разноса ровно там, где пара кончилась, — на
        # экране это излом асфальта, а не конец данных. Ровно этот излом и
        # приехал в симулятор, когда правило было починено на клиенте и забыто
        # на сервере.
        main = [(69.25, 41.300 + 0.00025 * i) for i in range(13)]
        back = [(69.2502, 41.303), (69.2502, 41.3015)]
        axis = build_roads.collapsed_axis(main, [back], 40)
        self.assertEqual(len(axis), len(main))
        self.assertAlmostEqual(axis[-1][0], 69.2501, places=4)
        self.assertAlmostEqual(axis[0][0], 69.25, places=5)
        steps = [abs(axis[i][0] - axis[i - 1][0]) for i in range(1, len(axis))]
        self.assertLess(max(steps) * build_roads.LAT_METERS, 6,
                        "ось обязана сходить плавно, а не шагом")

    def test_same_direction_roads_are_not_collapsed(self):
        # Дублёр в ту же сторону — вторая дорога, а не вторая проезжая часть.
        a = self.line_north(3, build_roads.FLAG_ONEWAY, 69.2500, 41.300, 41.303, steps=6)
        b = self.line_north(3, build_roads.FLAG_ONEWAY, 69.2502, 41.300, 41.303, steps=6)
        self.assertEqual(len(build_roads.collapse_dual([a, b], 45)), 2)

    def test_build_is_deterministic(self):
        # Недетерминированная сборка меняет sha256 всех тайлов каждую неделю,
        # и телефоны перекачивают их впустую.
        roads = [self.line_north(3, 0, 69.25, 41.300, 41.301),
                 self.line_north(6, 0, 69.251, 41.300, 41.302)]
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            build_roads.write_tiles(list(roads), a)
            build_roads.write_tiles(list(reversed(roads)), b)
            for name in sorted(os.listdir(a)):
                self.assertEqual(open(os.path.join(a, name), "rb").read(),
                                 open(os.path.join(b, name), "rb").read(),
                                 f"{name} зависит от порядка входа")

    def test_yards_live_in_their_own_file(self):
        # Дворовые проезды — половина всех дорог, а видны только вблизи.
        # В общем файле телефон возил бы их всю дорогу впустую.
        avenue = self.line_north(3, 0, 69.249, 41.300, 41.302)
        street = self.line_north(6, 0, 69.25, 41.300, 41.302)
        yard = self.line_north(7, 0, 69.251, 41.300, 41.302)
        with tempfile.TemporaryDirectory() as work:
            build_roads.write_tiles([avenue, street, yard], work)
            names = os.listdir(work)
            self.assertTrue(any(n.endswith("_s.json") for n in names))
            self.assertTrue(any(n.endswith("_y.json") for n in names))
            yards = [n for n in names if n.endswith("_y.json")]
            with open(os.path.join(work, yards[0])) as handle:
                tile = json.load(handle)
            self.assertEqual({r[0] for r in tile["roads"]}, {7})
            # Ключ индекса составной: «тайл_набор» — клиент кладёт его в свой
            # плоский словарь без правки структуры.
            with open(os.path.join(work, "index_payload_v2.json")) as handle:
                payload = json.load(handle)
            self.assertEqual(payload["version"], 2)
            self.assertTrue(any(k.endswith("_y") for k in payload["tiles"]))
            self.assertTrue(any(k.endswith("_f") for k in payload["tiles"]),
                            "костяк района — свой набор, только крупные классы")


class BlockTests(unittest.TestCase):
    """Кварталы как грани дорожного графа.

    Контур квартала СЛЕДУЕТ из измеренных дорог — он не берётся ниоткуда.
    Поэтому тесты здесь про то, чтобы не выдумать: не назвать кварталом
    внешнюю область, не превратить тупик в двор, не посчитать грани там, где
    графа ещё нет.
    """

    def grid(self, cells=2, step=0.002):
        """Сетка улиц cells+1 на cells+1 — из неё выходит cells² кварталов."""
        lines = []
        for i in range(cells + 1):
            lat = 41.30 + step * i
            lines.append((3, 0, [(69.25 + step * j, lat) for j in range(cells + 1)], ""))
            lon = 69.25 + step * i
            lines.append((3, 0, [(lon, 41.30 + step * j) for j in range(cells + 1)], ""))
        return lines

    def test_grid_of_streets_yields_its_blocks(self):
        blocks = build_roads.build_blocks(
            build_roads.split_at_junctions(self.grid(cells=2)))
        self.assertEqual(len(blocks), 4)
        for _, flags, ring in blocks:
            self.assertEqual(flags, build_roads.AREA_FLAG_CLOSED)
            self.assertGreater(len(ring), 2)

    def test_outer_region_is_not_a_block(self):
        # Внешняя грань обходится в другую сторону и по площади больше всей
        # сетки. Назвать её кварталом значило бы залить полэкрана застройкой,
        # которой нет.
        blocks = build_roads.build_blocks(
            build_roads.split_at_junctions(self.grid(cells=2)))
        total = sum(abs(build_roads.signed_area_meters(r)) for _, _, r in blocks)
        whole = abs(build_roads.signed_area_meters(
            [(69.25, 41.30), (69.254, 41.30), (69.254, 41.304), (69.25, 41.304)]))
        self.assertLess(total, whole * 1.05)

    def test_dead_end_is_not_a_block(self):
        # Тупик даёт вырожденный обход «туда и обратно» с нулевой площадью.
        spur = [(3, 0, [(69.25, 41.30), (69.25, 41.302)], "")]
        self.assertEqual(build_roads.build_blocks(spur), [])

    def test_oversized_face_is_refused(self):
        # Грань больше полуквадратного километра — это не квартал, а дыра в
        # данных, и выдавать её за застройку нельзя.
        blocks = build_roads.build_blocks(
            build_roads.split_at_junctions(self.grid(cells=2, step=0.02)))
        self.assertEqual(blocks, [])

    def test_blocks_need_the_graph_first(self):
        # Без разрезки перекрёстки внутри линий не существуют: сетка из шести
        # улиц видится обходу одним контуром по внешним углам, и вместо
        # четырёх кварталов получается один — весь квадрат целиком.
        raw = self.grid(cells=2)
        self.assertEqual(len(build_roads.build_blocks(raw)), 1)
        self.assertEqual(len(build_roads.build_blocks(
            build_roads.split_at_junctions(raw))), 4,
            "грани считаются по узлам, а до разрезки их нет")


class NameTests(unittest.TestCase):
    """Имя улицы: подпись под курсором и надёжное схлопывание."""

    def road(self, code, flags, coords, name=""):
        return (code, flags, [(lon, lat) for lat, lon in coords], name)

    def line(self, lon, lat0, lat1, name, flags=0, code=3):
        return self.road(code, flags, [(lat0, lon), ((lat0 + lat1) / 2, lon),
                                       (lat1, lon)], name)

    def test_streets_with_different_names_are_not_merged(self):
        # Узел степени два, но улицы разные. Склеить их значило бы получить
        # «улицу» с двумя названиями, и подпись врала бы на половине пути.
        a = self.line(69.25, 41.300, 41.301, "Амира Темура")
        b = self.line(69.25, 41.301, 41.302, "Шота Руставели")
        self.assertEqual(len(build_roads.merge_ways([a, b])), 2)

    def test_same_name_merges(self):
        a = self.line(69.25, 41.300, 41.301, "Амира Темура")
        b = self.line(69.25, 41.301, 41.302, "Амира Темура")
        self.assertEqual(len(build_roads.merge_ways([a, b])), 1)

    def test_collapse_refuses_different_names(self):
        # Имя надёжнее геометрии: съезд идёт вдоль проспекта и навстречу, но
        # называется иначе — это разные дороги.
        one = build_roads.FLAG_ONEWAY
        avenue = self.road(3, one, [(41.300 + 0.0005 * i, 69.2500) for i in range(7)],
                           "Амира Темура")
        ramp = self.road(3, one, [(41.303 - 0.0005 * i, 69.2502) for i in range(7)],
                         "Съезд")
        self.assertEqual(len(build_roads.collapse_dual([avenue, ramp], 45)), 2)

    def test_name_reaches_the_tile_only_when_present(self):
        named = self.line(69.25, 41.300, 41.302, "Амира Темура")
        plain = self.line(69.251, 41.300, 41.302, "")
        with tempfile.TemporaryDirectory() as work:
            build_roads.write_tiles([named, plain], work)
            path = [n for n in os.listdir(work) if n.endswith("_s.json")][0]
            with open(os.path.join(work, path)) as handle:
                entries = json.load(handle)["roads"]
            lengths = sorted(len(entry) for entry in entries)
            self.assertEqual(lengths, [3, 4],
                             "имя четвёртым и только там, где оно есть")
            named_entry = [entry for entry in entries if len(entry) == 4][0]
            self.assertEqual(named_entry[3], "Амира Темура")


class AreaTests(unittest.TestCase):
    """Слои местности: вода, зелень, рельсы.

    Данные для них ПРИЕЗЖАЮТ НА VPS каждое воскресенье внутри того же .pbf,
    который качается ради дорог, — и до сих пор выбрасывались фильтром по
    highway. На тёмной схеме вода единственный не-серый цвет, и именно она
    отличает местность от чертежа.
    """

    def feature(self, props, coords, shape="Polygon"):
        # «Polygon» здесь — вымысел, удобный для теста. ЖИВОЙ osmium пишет
        # площадь как MultiPolygon всегда, даже когда кольцо одно. Разбор
        # искал «Polygon», не находил и молча выбрасывал КАЖДУЮ площадь —
        # а тесты этого не видели, потому что кормили его геометрией,
        # которой в природе нет. Оба вида поддержаны и оба проверены.
        if shape == "Polygon":
            body = [coords]
        elif shape == "MultiPolygon":
            body = [[coords]]
        else:
            body = coords
        return json.dumps({"type": "Feature", "properties": props,
                           "geometry": {"type": shape, "coordinates": body}})

    def write(self, lines):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        handle.write("\n".join(lines))
        handle.close()
        return handle.name

    def square(self, lat, lon, size_deg):
        return [(lon, lat), (lon + size_deg, lat), (lon + size_deg, lat + size_deg),
                (lon, lat + size_deg), (lon, lat)]

    def test_kinds_are_recognised(self):
        self.assertEqual(build_roads.area_kind({"natural": "water"}),
                         build_roads.AREA_WATER)
        self.assertEqual(build_roads.area_kind({"leisure": "park"}),
                         build_roads.AREA_GREEN)
        self.assertEqual(build_roads.area_kind({"railway": "rail"}),
                         build_roads.AREA_RAIL)
        self.assertIsNone(build_roads.area_kind({"highway": "primary"}),
                          "дороги идут своим путём, а не сюда")

    def test_polygon_is_closed_and_line_is_not(self):
        path = self.write([
            self.feature({"natural": "water"}, self.square(41.3, 69.25, 0.003)),
            self.feature({"railway": "rail"},
                         [(69.25, 41.3), (69.26, 41.31)], shape="LineString"),
        ])
        areas = build_roads.collect_areas(path, 0)
        os.unlink(path)
        kinds = {kind: flags for kind, flags, _ in areas}
        self.assertEqual(kinds[build_roads.AREA_WATER], build_roads.AREA_FLAG_CLOSED)
        self.assertEqual(kinds[build_roads.AREA_RAIL], 0)

    def test_tiny_areas_are_dropped(self):
        # Пруд в двадцать метров на охвате схемы неразличим, а весит столько
        # же, сколько озеро.
        path = self.write([self.feature({"natural": "water"},
                                        self.square(41.3, 69.25, 0.0002))])
        self.assertEqual(build_roads.collect_areas(path, 0), [])
        os.unlink(path)

    def test_areas_get_their_own_files(self):
        road = (3, 0, [(69.25, 41.300), (69.25, 41.302)], "")
        areas = [(build_roads.AREA_WATER, build_roads.AREA_FLAG_CLOSED,
                  self.square(41.300, 69.251, 0.002))]
        with tempfile.TemporaryDirectory() as work:
            build_roads.write_tiles([road], work, areas=areas)
            names = os.listdir(work)
            self.assertTrue(any(n.endswith("_w.json") for n in names),
                            "вода едет своим файлом и не качается без надобности")
            water = [n for n in names if n.endswith("_w.json")][0]
            with open(os.path.join(work, water)) as handle:
                tile = json.load(handle)
            self.assertEqual(tile["roads"][0][0], build_roads.AREA_WATER)
            self.assertEqual(tile["roads"][0][1], build_roads.AREA_FLAG_CLOSED)

    def test_missing_areas_file_is_not_an_error(self):
        # Слой местности необязателен: старый экстракт его не содержит, и
        # сборка обязана пройти без него.
        self.assertEqual(build_roads.collect_areas(None, 0), [])
        self.assertEqual(build_roads.collect_areas("/нет/такого", 0), [])


class PointTests(unittest.TestCase):
    """Светофоры и лежачие: единственный слой, который садится НА дороги."""

    @staticmethod
    def street(lon0, lat0, lon1, lat1, code=3):
        return (code, 0, [(lon0, lat0), (lon1, lat1)], "")

    @staticmethod
    def point(kind, lon, lat):
        return (kind, 0, [(lon, lat)])

    def test_tags_map_to_client_codes(self):
        self.assertEqual(build_roads.point_kind({"highway": "traffic_signals"}),
                         build_roads.POINT_TRAFFIC_LIGHT)
        self.assertEqual(build_roads.point_kind({"traffic_calming": "hump"}),
                         build_roads.POINT_SPEED_BUMP)
        self.assertEqual(build_roads.point_kind({"highway": "stop"}),
                         build_roads.POINT_STOP_LINE)

    def test_narrowing_of_a_carriageway_is_not_a_speed_bump(self):
        # chicane и choker — сужение проезжей части, а не точка, в которой
        # сбрасывают скорость. Пиктограмма лежачего на них соврала бы.
        self.assertIsNone(build_roads.point_kind({"traffic_calming": "chicane"}))
        self.assertIsNone(build_roads.point_kind({"highway": "residential"}))

    def test_point_lands_on_the_axis_not_where_it_stood(self):
        # Светофор в OSM стоит у края проезжей части. На схеме он обязан быть
        # на нарисованной линии, иначе висит рядом с дорогой в воздухе.
        road = self.street(69.20, 41.30, 69.21, 41.30)
        aside = self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.205, 41.30008)
        snapped, dropped = build_roads.snap_points([aside], [road])

        self.assertEqual(dropped, 0)
        self.assertAlmostEqual(snapped[0][2][0][1], 41.30, places=6)

    def test_point_far_from_every_road_is_dropped(self):
        road = self.street(69.20, 41.30, 69.21, 41.30)
        far = self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.205, 41.3020)
        snapped, dropped = build_roads.snap_points([far], [road])

        self.assertEqual(snapped, [])
        self.assertEqual(dropped, 1)

    def test_a_yard_driveway_does_not_steal_the_light(self):
        # Класс 7 из кандидатов исключён: иначе светофор перекрёстка садится на
        # парковочный проезд, оказавшийся на пару метров ближе.
        avenue = self.street(69.20, 41.30, 69.21, 41.30, code=3)
        driveway = self.street(69.2050, 41.30005, 69.2052, 41.30005, code=7)
        light = self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.2051, 41.300055)
        snapped, _ = build_roads.snap_points([light], [avenue, driveway])

        self.assertAlmostEqual(snapped[0][2][0][1], 41.30, places=6)

    def test_four_lights_of_one_junction_become_one(self):
        # Так перекрёсток и размечен в OSM — по светофору на подъезд.
        step = 12.0 / build_roads.LAT_METERS
        junction = [self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20 + dx, 41.30 + dy)
                    for dx, dy in ((step, 0), (-step, 0), (0, step), (0, -step))]

        self.assertEqual(len(build_roads.cluster_points(junction)), 1)

    def test_two_junctions_stay_two(self):
        apart = 60.0 / build_roads.LAT_METERS
        pair = [self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20, 41.30),
                self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20, 41.30 + apart)]

        self.assertEqual(len(build_roads.cluster_points(pair)), 2)

    def test_a_bump_next_to_a_light_survives(self):
        # Сводятся только соседи ОДНОГО вида: лежачий перед светофором — это
        # два разных факта, и водителю нужны оба.
        step = 8.0 / build_roads.LAT_METERS
        mixed = [self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20, 41.30),
                 self.point(build_roads.POINT_SPEED_BUMP, 69.20, 41.30 + step)]

        self.assertEqual(len(build_roads.cluster_points(mixed)), 2)

    def test_a_cluster_stands_in_the_middle_of_the_junction(self):
        # Значок обязан стоять в центре перекрёстка, а не на одном подъезде.
        step = 12.0 / build_roads.LAT_METERS
        junction = [self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20 + dx, 41.30 + dy)
                    for dx, dy in ((step, 0), (-step, 0), (0, step), (0, -step))]
        centre = build_roads.cluster_points(junction)[0][2][0]

        self.assertAlmostEqual(centre[0], 69.20, places=7)
        self.assertAlmostEqual(centre[1], 41.30, places=7)

    def test_junction_node_needs_three_lines(self):
        # Тупик — не перекрёсток: светофору там не к чему привязываться.
        cross = [self.street(69.20, 41.30, 69.21, 41.30),
                 self.street(69.21, 41.30, 69.22, 41.30),
                 self.street(69.21, 41.30, 69.21, 41.31)]
        dead_end = [self.street(69.20, 41.30, 69.21, 41.30),
                    self.street(69.21, 41.30, 69.22, 41.30)]

        self.assertEqual(len(build_roads.junction_nodes(cross)), 1)
        self.assertEqual(build_roads.junction_nodes(dead_end), [])

    def test_four_approaches_meet_in_the_node_however_far_apart(self):
        # Так перекрёсток и размечен в OSM — по светофору на подъезд. На
        # проспекте они разнесены метров на сорок, и радиус между ними их не
        # соберёт; узел собирает.
        node = (69.21, 41.30)
        cross = [self.street(69.20, 41.30, 69.21, 41.30),
                 self.street(69.21, 41.30, 69.22, 41.30),
                 self.street(69.21, 41.30, 69.21, 41.31)]
        step = 22.0 / build_roads.LAT_METERS
        approaches = [self.point(build_roads.POINT_TRAFFIC_LIGHT,
                                 node[0] + dx, node[1] + dy)
                      for dx, dy in ((step, 0), (-step, 0), (0, step), (0, -step))]

        attached = build_roads.attach_to_junctions(approaches,
                                                   build_roads.junction_nodes(cross))
        self.assertEqual(len(attached), 1)
        self.assertAlmostEqual(attached[0][2][0][0], node[0], places=7)

    def test_two_junctions_are_not_merged_however_close(self):
        # Обратная половина того же правила.
        cross = [self.street(69.2000, 41.30, 69.2002, 41.30),
                 self.street(69.2002, 41.30, 69.2004, 41.30),
                 self.street(69.2002, 41.30, 69.2002, 41.3010),
                 self.street(69.2004, 41.30, 69.2006, 41.30),
                 self.street(69.2004, 41.30, 69.2004, 41.3010)]
        lights = [self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20021, 41.30),
                  self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20039, 41.30)]

        attached = build_roads.attach_to_junctions(lights,
                                                   build_roads.junction_nodes(cross))
        self.assertEqual(len(attached), 2)

    def test_a_bump_is_never_pulled_onto_a_crossing(self):
        # Лежачий лежит посреди квартала. Притянуть его к перекрёстку значило
        # бы соврать ровно о том, ради чего он нарисован.
        cross = [self.street(69.20, 41.30, 69.21, 41.30),
                 self.street(69.21, 41.30, 69.22, 41.30),
                 self.street(69.21, 41.30, 69.21, 41.31)]
        aside = 69.21 - 30.0 / build_roads.LAT_METERS
        bump = self.point(build_roads.POINT_SPEED_BUMP, aside, 41.30)

        attached = build_roads.attach_to_junctions([bump],
                                                   build_roads.junction_nodes(cross))
        self.assertAlmostEqual(attached[0][2][0][0], aside, places=7)

    def test_a_crossing_far_from_any_junction_keeps_its_own_icon(self):
        # Пешеходный переход посреди квартала — отдельный светофор, а не
        # подъезд к ближайшему перекрёстку.
        cross = [self.street(69.20, 41.30, 69.21, 41.30),
                 self.street(69.21, 41.30, 69.22, 41.30),
                 self.street(69.21, 41.30, 69.21, 41.31)]
        far = 69.21 - 90.0 / build_roads.LAT_METERS
        light = self.point(build_roads.POINT_TRAFFIC_LIGHT, far, 41.30)

        attached = build_roads.attach_to_junctions([light],
                                                   build_roads.junction_nodes(cross))
        self.assertAlmostEqual(attached[0][2][0][0], far, places=7)

    def test_clustering_does_not_depend_on_reading_order(self):
        # Иначе sha256 тайла меняется от перестановки строк в экстракте, и
        # телефоны перекачивают файл, в котором не изменилось ничего.
        step = 10.0 / build_roads.LAT_METERS
        crowd = [self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20, 41.30),
                 self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20 + step, 41.30),
                 self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.20, 41.30 + step)]

        self.assertEqual(build_roads.cluster_points(crowd),
                         build_roads.cluster_points(list(reversed(crowd))))

    def test_point_rides_its_own_set_and_carries_one_coordinate(self):
        road = self.street(69.20, 41.30, 69.21, 41.30)
        light = self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.205, 41.30)
        with tempfile.TemporaryDirectory() as target:
            _, index_v2 = build_roads.write_tiles([road], target, points=[light])
            key = next(k for k in index_v2 if k.endswith("_" + build_roads.SET_POINTS))
            with open(os.path.join(target, f"road2_{key}.json"), encoding="utf-8") as handle:
                tile = json.load(handle)

        entry = tile["roads"][0]
        self.assertEqual(entry[0], build_roads.POINT_TRAFFIC_LIGHT)
        self.assertEqual(len(entry[2]), 2)

    def test_points_never_reach_the_old_format(self):
        # v1 — один файл на всё. Установленная сборка, не знающая о точках,
        # прочитала бы их как дороги с одной вершиной.
        road = self.street(69.20, 41.30, 69.21, 41.30)
        light = self.point(build_roads.POINT_TRAFFIC_LIGHT, 69.205, 41.30)
        with tempfile.TemporaryDirectory() as target:
            index_v1, _ = build_roads.write_tiles([road], target, points=[light])
            key = next(iter(index_v1))
            with open(os.path.join(target, f"tile_{key}.json"), encoding="utf-8") as handle:
                tile = json.load(handle)

        self.assertTrue(all(len(entry[2]) >= 4 for entry in tile["roads"]))

    def test_missing_points_file_is_not_an_error(self):
        self.assertEqual(build_roads.collect_points(None), [])
        self.assertEqual(build_roads.collect_points("/нет/такого"), [])


class LaneTests(unittest.TestCase):
    """Полосы: старшие биты того же поля flags.

    Здесь сторожатся две разные вещи. Первая — контракт с УЖЕ УСТАНОВЛЕННЫМИ
    сборками: запись тайла обязана остаться длиной 3 или 4, потому что
    RoadTiles.swift на пятом элементе возвращает nil на весь квадрат, и
    телефон теряет не дорогу, а регион. Вторая — что новое поле не разорвало
    склейку: улица, у которой в OSM на одном участке проставлен lanes, а на
    соседнем нет, обязана остаться одной улицей.
    """

    def road(self, code, flags, coords, name=""):
        return (code, flags, [(lon, lat) for lat, lon in coords], name)

    def line_north(self, code, flags, lon, lat0, lat1, steps=4, name=""):
        step = (lat1 - lat0) / steps
        return self.road(code, flags,
                         [(lat0 + step * i, lon) for i in range(steps + 1)], name)

    # --- Упаковка

    def test_lanes_survive_the_round_trip(self):
        for lanes in range(build_roads.MAX_LANES + 1):
            self.assertEqual(build_roads.lanes_of(build_roads.with_lanes(0, lanes)),
                             lanes)

    def test_lanes_do_not_disturb_the_character_bits(self):
        flags = (build_roads.FLAG_ONEWAY | build_roads.FLAG_BRIDGE
                 | build_roads.FLAG_TUNNEL | build_roads.FLAG_RING)
        packed = build_roads.with_lanes(flags, 6)
        self.assertEqual(build_roads.topo(packed), flags,
                         "полосы не имеют права шевелить характер линии")
        self.assertEqual(build_roads.lanes_of(packed), 6)

    def test_lanes_are_clamped_into_their_four_bits(self):
        # 16 полос в четыре бита не влезают и молча стали бы нулём, то есть
        # «не задано», — а ноль рисуется дефолтом класса, и дорога вышла бы уже.
        self.assertEqual(build_roads.lanes_of(build_roads.with_lanes(0, 99)),
                         build_roads.MAX_LANES)
        self.assertEqual(build_roads.lanes_of(build_roads.with_lanes(0, -3)), 0)

    def test_old_client_masks_still_read_the_same_bits(self):
        # Ровно то, что делает RoadTiles.swift:223. Установленная сборка не
        # знает о полосах и обязана прочитать характер линии как раньше.
        flags = build_roads.with_lanes(build_roads.FLAG_ONEWAY, 15)
        self.assertTrue(flags & 1)
        self.assertFalse(flags & 2)
        self.assertFalse(flags & 4)
        self.assertFalse(flags & 8)

    # --- Откуда берутся полосы

    def test_lanes_come_from_the_tag(self):
        self.assertEqual(build_roads.road_lanes({"lanes": "4"}, 3, False), 4)
        self.assertEqual(build_roads.road_lanes({"lanes": 2}, 6, True), 2)

    def test_lanes_fall_back_to_the_class(self):
        # OSM молчит у 91 % дорог центра — это основной путь, а не запасной.
        self.assertEqual(build_roads.road_lanes({}, 3, False), 6)
        self.assertEqual(build_roads.road_lanes({}, 3, True), 3)
        self.assertEqual(build_roads.road_lanes({}, 6, False), 2)
        self.assertEqual(build_roads.road_lanes({}, 7, False), 1)

    def test_nonsense_tag_is_ignored_rather_than_fatal(self):
        for value in ("абра", "", "0", "99", "-2", None):
            lanes = build_roads.road_lanes({"lanes": value}, 4, False)
            self.assertEqual(lanes, 4, f"на теге {value!r} ждём дефолт класса")

    def test_list_tag_takes_the_first_number(self):
        # «2;3» на участке с карманом. Падать из-за этого нельзя: дорога
        # важнее полполосы.
        self.assertEqual(build_roads.road_lanes({"lanes": "2;3"}, 4, False), 2)

    def test_flags_carry_lanes_only_when_the_class_is_known(self):
        props = {"lanes": "4"}
        self.assertEqual(build_roads.lanes_of(build_roads.flags_of(props)), 0)
        self.assertEqual(build_roads.lanes_of(build_roads.flags_of(props, None, 3)), 4)

    # --- Ширина

    # --- «Полосы знаем» против «предположили по классу»

    def test_tag_marks_the_road_as_measured(self):
        # Без этого бита по тайлу нельзя отличить измеренное от подставленного:
        # дефолт класса выглядит ровно так же, как настоящее число.
        tagged = build_roads.flags_of({"lanes": "4"}, None, 3)
        guessed = build_roads.flags_of({}, None, 3)
        self.assertTrue(tagged & build_roads.FLAG_LANES_TAGGED)
        self.assertFalse(guessed & build_roads.FLAG_LANES_TAGGED)
        self.assertEqual(build_roads.lanes_of(guessed), 6, "полосы всё равно есть")

    def test_nonsense_tag_does_not_count_as_measured(self):
        # «99» не делает дорогу измеренной, он делает её ошибочно размеченной.
        # Панель обязана предложить такую наравне с молчащей.
        self.assertFalse(build_roads.flags_of({"lanes": "99"}, None, 3)
                         & build_roads.FLAG_LANES_TAGGED)
        self.assertFalse(build_roads.flags_of({"lanes": "чушь"}, None, 3)
                         & build_roads.FLAG_LANES_TAGGED)

    def test_measured_bit_does_not_disturb_anything_else(self):
        flags = build_roads.flags_of({"lanes": "4", "oneway": "yes",
                                      "bridge": "yes"}, None, 3)
        self.assertTrue(flags & build_roads.FLAG_ONEWAY)
        self.assertTrue(flags & build_roads.FLAG_BRIDGE)
        self.assertEqual(build_roads.lanes_of(flags), 4)

    def test_merge_ignores_the_measured_bit(self):
        # Улица, у которой тег проставлен кусками, — по-прежнему одна улица.
        a = self.road(3, build_roads.flags_of({"lanes": "4"}, None, 3),
                      [(41.300, 69.25), (41.301, 69.25)])
        b = self.road(3, build_roads.flags_of({}, None, 3),
                      [(41.301, 69.25), (41.302, 69.25)])
        self.assertEqual(len(build_roads.merge_ways([a, b])), 1)

    def test_width_follows_class_and_lanes(self):
        self.assertAlmostEqual(build_roads.road_width_meters(3, 6), 22.5)
        self.assertAlmostEqual(build_roads.road_width_meters(6, 2), 7.0)
        self.assertAlmostEqual(build_roads.road_width_meters(7, 1), 4.5)

    def test_unset_lanes_still_give_a_width(self):
        # Ноль означает «не задано», а не «дороги нет»: рисовать её всё равно
        # надо, и ширина берётся дефолтом класса.
        self.assertAlmostEqual(build_roads.road_width_meters(4, 0),
                               build_roads.road_width_meters(4, 4))

    def test_width_can_never_reach_the_gate(self):
        # Ворота стоят на 60 м. Четыре бита физически не дают их достичь —
        # то есть опечатка в теге не может уехать на телефоны в принципе.
        widest = max(build_roads.road_width_meters(code, ceiling)
                     for code, ceiling in build_roads.MAX_LANES_BY_CLASS.items())
        self.assertLess(widest, build_roads.MAX_WIDTH_METERS)

    def test_class_ceiling_survives_a_typo(self):
        # lanes=15 у дворового проезда — опечатка, и без потолка она заливала
        # бы квартал асфальтом в 67 м.
        self.assertEqual(build_roads.road_lanes({"lanes": "15"}, 7, False), 2)
        self.assertEqual(build_roads.road_lanes({"lanes": "15"}, 6, False), 4)
        self.assertEqual(build_roads.road_lanes({"lanes": "15"}, 1, False), 15)

    def test_plausible_tag_above_the_ceiling_is_trimmed_not_dropped(self):
        # Десять полос у secondary — не мусор, а скорее ошибка класса в OSM.
        # Подрезаем до потолка класса; это по-прежнему широкая дорога.
        self.assertEqual(build_roads.road_lanes({"lanes": "10"}, 4, False), 8)

    # --- Склейка и сведение

    def test_street_still_merges_when_only_lanes_differ(self):
        # Регрессия, ради которой в склейке стоит маска. В OSM тег lanes
        # проставлен кусками; сравнение всего поля flags разорвало бы улицу
        # ровно там, где кто-то был аккуратен.
        a = self.line_north(3, build_roads.with_lanes(0, 4), 69.25, 41.300, 41.301)
        b = self.line_north(3, build_roads.with_lanes(0, 2), 69.25, 41.301, 41.302)
        merged = build_roads.merge_ways([a, b])
        self.assertEqual(len(merged), 1, "разное число полос — всё ещё одна улица")

    def test_merged_street_keeps_the_widest_count(self):
        # Ширина рисуется одна на всю линию. Занизить её значит провести
        # асфальт уже перекрёстка, к которому улица расширялась.
        a = self.line_north(3, build_roads.with_lanes(0, 4), 69.25, 41.300, 41.301)
        b = self.line_north(3, build_roads.with_lanes(0, 6), 69.25, 41.301, 41.302)
        merged = build_roads.merge_ways([a, b])
        self.assertEqual(build_roads.lanes_of(merged[0][1]), 6)

    def test_character_bits_still_keep_streets_apart(self):
        # Маска не должна стать дырой: мост и земля остаются разными линиями.
        a = self.line_north(3, build_roads.with_lanes(0, 4), 69.25, 41.300, 41.301)
        b = self.line_north(3, build_roads.with_lanes(build_roads.FLAG_BRIDGE, 4),
                            69.25, 41.301, 41.302)
        self.assertEqual(len(build_roads.merge_ways([a, b])), 2)

    def test_collapsed_axis_sums_the_carriageways(self):
        # Костяк рисуется той же толщиной в метрах, что и детальная сеть.
        # Взять полосы одной половины значило бы нарисовать проспект вдвое
        # уже, чем он есть, — на том самом охвате, где он и читается проспектом.
        forward = self.line_north(3, build_roads.with_lanes(build_roads.FLAG_ONEWAY, 3),
                                  69.2500, 41.300, 41.303, steps=6)
        back = self.road(3, build_roads.with_lanes(build_roads.FLAG_ONEWAY, 3),
                         [(41.303 - 0.0005 * i, 69.2502) for i in range(7)])
        collapsed = build_roads.collapse_dual([forward, back], 45)
        self.assertEqual(len(collapsed), 1)
        self.assertEqual(build_roads.lanes_of(collapsed[0][1]), 6)

    def test_carriageways_with_different_lanes_still_pair(self):
        # Справа карман под правый поворот — обычное дело, парой они быть не
        # перестают.
        forward = self.line_north(3, build_roads.with_lanes(build_roads.FLAG_ONEWAY, 4),
                                  69.2500, 41.300, 41.303, steps=6)
        back = self.road(3, build_roads.with_lanes(build_roads.FLAG_ONEWAY, 3),
                         [(41.303 - 0.0005 * i, 69.2502) for i in range(7)])
        self.assertEqual(len(build_roads.collapse_dual([forward, back], 45)), 1)

    # --- Контракт формата

    def test_record_never_grows_a_fifth_element(self):
        # Тот самый запрет. Пятый элемент не расширяет формат, а роняет разбор
        # ВСЕГО тайла у установленных сборок (RoadTiles.swift:193).
        with tempfile.TemporaryDirectory() as work:
            roads = [self.road(3, build_roads.with_lanes(build_roads.FLAG_ONEWAY, 6),
                               [(41.300, 69.25), (41.302, 69.25)], "Навои")]
            build_roads.write_tiles(roads, work, 0.05, [], [], [], roads)
            for name in os.listdir(work):
                if not name.startswith(("tile_", "road2_")):
                    continue
                with open(os.path.join(work, name), encoding="utf-8") as handle:
                    payload = json.load(handle)
                for entry in payload["roads"]:
                    self.assertIn(len(entry), (3, 4),
                                  f"{name}: запись длиной {len(entry)} убьёт тайл целиком")

    def test_lanes_reach_the_tile(self):
        with tempfile.TemporaryDirectory() as work:
            roads = [self.road(3, build_roads.with_lanes(0, 6),
                               [(41.300, 69.25), (41.302, 69.25)])]
            build_roads.write_tiles(roads, work, 0.05, [], [], [], [])
            with open(os.path.join(work, "tile_262_498.json"), encoding="utf-8") as handle:
                tile = json.load(handle)
            self.assertEqual(build_roads.lanes_of(tile["roads"][0][1]), 6)


class MarkingTests(unittest.TestCase):
    """Разметка: зебры и стоп-линии.

    Разметка — не значок, а ПОПЕРЕЧНАЯ ЧЕРТА, и держится она на двух числах,
    которых у точки раньше не было: азимут дороги под ней и ширина проезжей
    части. Без первого черта ляжет вдоль дороги вместо поперёк, без второго —
    не дотянется до кромки. Оба числа известны ровно в момент посадки на ось и
    больше нигде: дальше по конвейеру дороги уже нет.

    Отдельно сторожится то, что переходы НЕ сводятся в один объект. Светофоры
    перекрёстка сводить надо — их четыре по подъездам, и четыре значка в одном
    пятне это каша. Переходов тоже четыре, но каждый лежит на своём подъезде и
    чертится поперёк своей проезжей части; сведи их — вместо четырёх зебр
    получится одна посреди перекрёстка.
    """

    def road(self, code, flags, coords, name=""):
        return (code, flags, [(lon, lat) for lat, lon in coords], name)

    # --- Упаковка

    def test_azimuth_survives_the_round_trip(self):
        for degrees in range(0, 360, build_roads.PFLAG_AZIMUTH_STEP):
            flags = build_roads.point_flags(degrees, 0)
            self.assertEqual(build_roads.point_azimuth(flags), degrees)

    def test_azimuth_is_rounded_to_its_step(self):
        # Полтора градуса поперечная черта не показывает.
        self.assertEqual(build_roads.point_azimuth(build_roads.point_flags(91, 0)), 90)
        self.assertEqual(build_roads.point_azimuth(build_roads.point_flags(359, 0)), 0)

    def test_width_survives_the_round_trip(self):
        for meters in (0, 7, 22, 45, 63):
            flags = build_roads.point_flags(0, meters)
            self.assertEqual(build_roads.point_width(flags), meters)

    def test_azimuth_and_width_do_not_collide(self):
        flags = build_roads.point_flags(273, 22)
        self.assertEqual(build_roads.point_azimuth(flags), 273)
        self.assertEqual(build_roads.point_width(flags), 22)

    def test_absurd_width_is_clamped_not_wrapped(self):
        # Шесть бит переполняются молча, и ширина 64 стала бы нулём — то есть
        # черта не нарисовалась бы вовсе там, где дорога шире всего.
        self.assertEqual(build_roads.point_width(build_roads.point_flags(0, 999)),
                         build_roads.PFLAG_WIDTH_MASK)

    # --- Азимут берётся у сегмента, а не у линии

    def test_azimuth_comes_from_the_nearest_segment(self):
        # Улица после склейки бывает длиной в километр с поворотом. Общее
        # направление её концов к месту, где стоит зебра, отношения не имеет.
        corner = self.road(3, 0, [(41.300, 69.250), (41.310, 69.250),
                                  (41.310, 69.270)])
        # Точка у ВЕРХНЕГО, широтного плеча: там дорога идёт на восток.
        crossing = (build_roads.POINT_CROSSING, 0, [(69.260, 41.310)])
        snapped, dropped = build_roads.snap_points([crossing], [corner])
        self.assertEqual(dropped, 0)
        azimuth = build_roads.point_azimuth(snapped[0][1])
        self.assertAlmostEqual(azimuth, 90, delta=build_roads.PFLAG_AZIMUTH_STEP,
                               msg="азимут взят у линии целиком, а не у сегмента")

    def test_width_comes_from_the_road_underneath(self):
        avenue = self.road(3, build_roads.with_lanes(0, 6),
                           [(41.300, 69.250), (41.310, 69.250)])
        crossing = (build_roads.POINT_CROSSING, 0, [(69.2501, 41.305)])
        snapped, _ = build_roads.snap_points([crossing], [avenue])
        self.assertEqual(build_roads.point_width(snapped[0][1]),
                         round(build_roads.road_width_meters(3, 6)))

    def test_stop_line_gets_the_same_two_numbers(self):
        # Стоп-линия была точкой без азимута и ширины, то есть нарисовать её
        # было нечем.
        street = self.road(4, build_roads.with_lanes(0, 4),
                           [(41.300, 69.250), (41.310, 69.250)])
        stop = (build_roads.POINT_STOP_LINE, 0, [(69.2501, 41.305)])
        snapped, _ = build_roads.snap_points([stop], [street])
        self.assertGreater(build_roads.point_width(snapped[0][1]), 0)
        self.assertAlmostEqual(build_roads.point_azimuth(snapped[0][1]), 0,
                               delta=build_roads.PFLAG_AZIMUTH_STEP)

    # --- Сведение

    def test_crossings_of_one_junction_stay_four(self):
        # Четыре подъезда перекрёстка — четыре зебры, каждая на своей проезжей.
        near = [(69.2500, 41.3001), (69.2500, 41.2999),
                (69.2501, 41.3000), (69.2499, 41.3000)]
        points = [(build_roads.POINT_CROSSING, 0, [p]) for p in near]
        self.assertEqual(len(build_roads.cluster_points(points)), 4)

    def test_traffic_lights_of_one_junction_still_become_one(self):
        # Правило для переходов не должно отменить правило для светофоров.
        near = [(69.2500, 41.3001), (69.2500, 41.2999),
                (69.2501, 41.3000), (69.2499, 41.3000)]
        points = [(build_roads.POINT_TRAFFIC_LIGHT, 0, [p]) for p in near]
        self.assertEqual(len(build_roads.cluster_points(points)), 1)

    # --- Стрелки полос

    def test_turn_lanes_are_parsed_in_order(self):
        self.assertEqual(build_roads.parse_turn_lanes("left|through|through;right"),
                         [build_roads.TURN_LEFT, build_roads.TURN_THROUGH,
                          build_roads.TURN_THROUGH_RIGHT])

    def test_turn_order_inside_a_lane_does_not_matter(self):
        self.assertEqual(build_roads.turn_code("left;through"),
                         build_roads.turn_code("through;left"))

    def test_nonsense_turn_does_not_lose_the_road(self):
        self.assertEqual(build_roads.parse_turn_lanes("чушь|left"),
                         [build_roads.TURN_NONE, build_roads.TURN_LEFT])

    def test_turns_do_not_collide_with_azimuth_and_width(self):
        flags = build_roads.pack_turns(build_roads.point_flags(273, 22),
                                       [build_roads.TURN_LEFT, build_roads.TURN_THROUGH])
        self.assertEqual(build_roads.point_azimuth(flags), 273)
        self.assertEqual(build_roads.point_width(flags), 22)
        self.assertEqual(build_roads.unpack_turns(flags, 2),
                         [build_roads.TURN_LEFT, build_roads.TURN_THROUGH])

    def test_snap_keeps_the_turns_it_did_not_compute(self):
        street = self.road(4, build_roads.with_lanes(0, 4),
                           [(41.300, 69.250), (41.310, 69.250)])
        arrows = (build_roads.POINT_LANE_ARROWS,
                  build_roads.pack_turns(0, [build_roads.TURN_LEFT,
                                             build_roads.TURN_THROUGH]),
                  [(69.2501, 41.305)])
        snapped, _ = build_roads.snap_points([arrows], [street])
        self.assertEqual(build_roads.unpack_turns(snapped[0][1], 2),
                         [build_roads.TURN_LEFT, build_roads.TURN_THROUGH])
        self.assertGreater(build_roads.point_width(snapped[0][1]), 0)

    def test_arrows_stand_before_the_junction(self):
        way = [(69.250, 41.300), (69.250, 41.310)]
        spot = build_roads._step_back(way, build_roads.ARROW_SETBACK_METERS)
        self.assertIsNotNone(spot)
        back = build_roads.meters_between(spot, way[-1])
        self.assertAlmostEqual(back, build_roads.ARROW_SETBACK_METERS, delta=0.5)

    def test_short_way_gets_no_arrows(self):
        self.assertIsNone(build_roads._step_back(
            [(69.250, 41.3000), (69.250, 41.30005)], 12.0))

    # --- Контракт с клиентом

    def test_crossing_is_read_from_the_tag(self):
        self.assertEqual(build_roads.point_kind({"highway": "crossing"}),
                         build_roads.POINT_CROSSING)

    def test_marking_reaches_the_tile_with_its_numbers(self):
        with tempfile.TemporaryDirectory() as work:
            roads = [self.road(3, build_roads.with_lanes(0, 6),
                               [(41.300, 69.25), (41.310, 69.25)])]
            crossing = (build_roads.POINT_CROSSING,
                        build_roads.point_flags(0, 22), [(69.25, 41.305)])
            build_roads.write_tiles(roads, work, 0.05, [], [crossing], [], roads)
            name = [n for n in os.listdir(work) if n.endswith("_p.json")][0]
            with open(os.path.join(work, name), encoding="utf-8") as handle:
                tile = json.load(handle)
            entry = tile["roads"][0]
            self.assertEqual(entry[0], build_roads.POINT_CROSSING)
            self.assertEqual(build_roads.point_azimuth(entry[1]), 0)
            self.assertEqual(build_roads.point_width(entry[1]), 22)


class DrawnRoadTests(unittest.TestCase):
    """Дороги, нарисованные руками в конструкторе.

    Главное здесь — они добавляются в сеть ДО генерализации. Своя дорога
    обязана пройти ту же разрезку на узлах и склейку, что и всё остальное:
    иначе она ляжет ПОВЕРХ сети, а не внутрь неё, узлов на стыках не появится,
    маршрут по ней не пройдёт, а на схеме она будет тупиком рядом с настоящей
    улицей.
    """

    def edit(self, points, **props):
        return {"kind": "geometry",
                "geom": [[lon, lat] for lat, lon in points],
                "props": props}

    def test_drawn_road_becomes_a_road(self):
        built = build_roads.drawn([self.edit([(41.300, 69.250), (41.302, 69.250)],
                                             cls=3)])
        self.assertEqual(len(built), 1)
        code, flags, points, _ = built[0]
        self.assertEqual(code, 3)
        self.assertEqual(len(points), 2)
        self.assertTrue(flags & build_roads.FLAG_HAND_DRAWN)

    def test_hand_drawn_bit_is_invisible_to_the_phone(self):
        # Телефон читает характер линии масками; старший бит он не видит и
        # видеть не должен — ему всё равно, откуда взялась дорога.
        built = build_roads.drawn([self.edit([(41.300, 69.250), (41.302, 69.250)],
                                             cls=3, oneway=True)])
        flags = built[0][1]
        self.assertTrue(flags & build_roads.FLAG_ONEWAY)
        self.assertEqual(build_roads.topo(flags), build_roads.FLAG_ONEWAY)

    def test_unknown_class_falls_back_to_a_living_street(self):
        built = build_roads.drawn([self.edit([(41.300, 69.250), (41.302, 69.250)],
                                             cls=99)])
        self.assertEqual(built[0][0], 6)

    def test_lanes_by_hand_mark_the_road_as_measured(self):
        built = build_roads.drawn([self.edit([(41.300, 69.250), (41.302, 69.250)],
                                             cls=3, lanes=4)])
        flags = built[0][1]
        self.assertEqual(build_roads.lanes_of(flags), 4)
        self.assertTrue(flags & build_roads.FLAG_LANES_TAGGED,
                        "нарисовал и указал полосы — это измерено, а не догадка")

    def test_lanes_without_a_hand_come_from_the_class(self):
        built = build_roads.drawn([self.edit([(41.300, 69.250), (41.302, 69.250)],
                                             cls=3)])
        flags = built[0][1]
        self.assertEqual(build_roads.lanes_of(flags), 6)
        self.assertFalse(flags & build_roads.FLAG_LANES_TAGGED)

    def test_other_kinds_are_not_roads(self):
        self.assertEqual(build_roads.drawn([{"kind": "lanes", "geom": [69.25, 41.3]}]), [])

    def test_broken_geometry_is_skipped_not_fatal(self):
        for geom in ([], [[69.25, 41.3]], [["чушь", 1], [2, 3]], [69.25, 41.30]):
            self.assertEqual(
                build_roads.drawn([{"kind": "geometry", "geom": geom, "props": {}}]), [])

    def test_drawn_road_joins_the_network_at_its_node(self):
        # Ради этого нарисованное и добавляется ДО генерализации: конец своей
        # дороги, упёршийся в проспект, обязан разрезать его на узле.
        #
        # Само по себе это не работает: разрезка идёт по общим ВЕРШИНАМ, а
        # конец приходит в середину отрезка, где вершины нет. Врезает её graft.
        avenue = (3, 0, [(69.250, 41.300), (69.250, 41.302)], "")
        mine = build_roads.drawn(
            [self.edit([(41.301, 69.250), (41.301, 69.252)], cls=6)])[0]
        grafted = build_roads.graft([avenue], [mine])
        self.assertEqual(len(grafted[0][2]), 3, "вершина в чужую линию не врезана")
        split = build_roads.split_at_junctions(grafted + [mine])
        self.assertEqual(len(split), 3, "проспект обязан разрезаться на узле")

    def test_graft_does_not_move_the_road_it_touches(self):
        # Врезка меняет топологию, а не геометрию: точка и так лежит на отрезке.
        avenue = (3, 0, [(69.250, 41.300), (69.250, 41.302)], "")
        mine = build_roads.drawn(
            [self.edit([(41.301, 69.250), (41.301, 69.252)], cls=6)])[0]
        grafted = build_roads.graft([avenue], [mine])[0]
        self.assertEqual(grafted[2][0], avenue[2][0])
        self.assertEqual(grafted[2][-1], avenue[2][-1])
        self.assertAlmostEqual(grafted[2][1][0], 69.250, places=6)

    def test_graft_does_not_double_an_existing_vertex(self):
        # Конец пришёл ровно в вершину — врезать нечего.
        avenue = (3, 0, [(69.250, 41.300), (69.250, 41.301), (69.250, 41.302)], "")
        mine = build_roads.drawn(
            [self.edit([(41.301, 69.250), (41.301, 69.252)], cls=6)])[0]
        grafted = build_roads.graft([avenue], [mine])[0]
        self.assertEqual(len(grafted[2]), 3)

    def test_graft_leaves_far_away_roads_alone(self):
        far = (3, 0, [(69.300, 41.300), (69.300, 41.302)], "")
        mine = build_roads.drawn(
            [self.edit([(41.301, 69.250), (41.301, 69.252)], cls=6)])[0]
        self.assertIs(build_roads.graft([far], [mine])[0], far)


class IdentityTests(unittest.TestCase):
    """Опора правок на id из OSM.

    Правка привязана к дороге геометрией: класс, имя, азимут, отпечаток. Так
    сделано потому, что id «не переживает» пересборку, — и это верно лишь
    отчасти. Id способа в OSM меняется, когда способ разрезали или удалили, а
    не когда подвинули точку: в большинстве случаев он находит ту же дорогу
    мгновенно и точно, там где геометрический поиск каждую неделю кладёт в
    очередь «посмотрите» то, что не двигалось.

    Проверено на боевом сервере: osmium 1.14 с -u type_id кладёт
    идентификатор в КОРЕНЬ объекта («"id":"w8151512"»), а не в properties.
    """

    def write(self, rows):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        for row in rows:
            json.dump(row, handle, ensure_ascii=False)
            handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def road(self, osm_id=None, lat=41.30, lon=69.25):
        row = {"type": "Feature",
               "properties": {"highway": "primary", "name": "Навои"},
               "geometry": {"type": "LineString",
                            "coordinates": [[lon, lat], [lon, lat + 0.002]]}}
        if osm_id:
            row["id"] = osm_id
        return row

    def test_id_is_taken_from_the_root(self):
        result = build_roads.collect(self.write([self.road("w123")]))
        identities = result[8]
        self.assertEqual(len(identities), 1)
        self.assertEqual(identities[0][0], "w123")

    def test_extract_without_ids_still_builds(self):
        # Экстракт без -u type_id обязан собираться как прежде: привязка
        # останется геометрической, но сборка не должна падать.
        result = build_roads.collect(self.write([self.road()]))
        self.assertEqual(result[8], [])
        self.assertEqual(len(result[0]), 1)

    def test_identity_sits_in_the_middle_not_at_the_end(self):
        # У линии из двух точек «вершина посередине» — это её конец, а концы
        # у дорог на перекрёстке общие: опора указывала бы сразу на несколько.
        identities = build_roads.collect(self.write([self.road("w123")]))[8]
        _, _, lat, _, _ = identities[0]
        self.assertAlmostEqual(lat, 41.301, places=4)

    def test_identity_carries_place_and_bearing(self):
        identities = build_roads.collect(self.write([self.road("w123")]))[8]
        osm_id, lon, lat, bearing, code = identities[0]
        self.assertAlmostEqual(lat, 41.301, places=4)
        self.assertAlmostEqual(lon, 69.25, places=3)
        # Линия идёт на север.
        self.assertAlmostEqual(bearing, 0.0, places=1)
        self.assertEqual(code, build_roads.CLASS_CODES["primary"])

    def test_identities_are_written_beside_tiles_but_not_into_the_index(self):
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        cells = build_roads.write_identities(
            [("w1", 69.25, 41.30, 12.0, 3), ("w2", 66.95, 39.65, 90.0, 4)], work)
        self.assertEqual(cells, 2)
        names = sorted(os.listdir(work))
        self.assertTrue(all(n.startswith("ids_") for n in names), names)
        # Телефон просит только известные наборы и чистит по «нет в индексе»:
        # файл без ключа в индексе он не запросит никогда.
        self.assertFalse(any(n.startswith("road2_") for n in names))

    def test_identity_file_is_readable_and_scaled_like_tiles(self):
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        build_roads.write_identities([("w1", 69.25, 41.30, 12.0, 3)], work)
        name = os.listdir(work)[0]
        with open(os.path.join(work, name), encoding="utf-8") as handle:
            payload = json.load(handle)
        osm_id, ilat, ilon, bearing, code = payload["roads"][0]
        self.assertEqual(osm_id, "w1")
        self.assertEqual(ilat, round(41.30 * build_roads.SCALE))
        self.assertEqual(ilon, round(69.25 * build_roads.SCALE))

    def test_identity_cell_matches_the_address_grid(self):
        # Та же сетка, что у адресов: два способа делить страну на клетки —
        # это два способа промахнуться мимо файла.
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        build_roads.write_identities([("w1", 69.28, 41.31, 0.0, 3)], work)
        self.assertEqual(os.listdir(work),
                         ["ids_" + build_roads.address_key(41.31, 69.28) + ".json"])


class AddressTests(unittest.TestCase):
    """Адреса и поиск без сети.

    Поиск в приложении и так работает — через Apple и только по сети. В
    роуминге, в тоннеле и на краю покрытия «Куда» перестаёт существовать;
    ради этого случая и заводится свой индекс. Потолок назван честно и
    замерен: в кадре центра Ташкента 18 755 объектов с адресом при 54 094
    домах, то есть треть.

    Раскладка здесь НЕ тайловая, и это главное правило слоя: адрес ищут там,
    куда ещё не приехали, а окрестность отвечает только про то, где стоишь.
    """

    def write(self, rows):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        for tags, geometry in rows:
            json.dump({"type": "Feature", "properties": tags,
                       "geometry": geometry}, handle, ensure_ascii=False)
            handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def point(self, lon, lat):
        return {"type": "Point", "coordinates": [lon, lat]}

    def square(self, lat, lon, meters=20):
        step = meters / 111_320.0
        return {"type": "Polygon", "coordinates": [[
            [lon, lat], [lon + step, lat], [lon + step, lat + step],
            [lon, lat + step], [lon, lat]]]}

    def test_point_address_is_taken(self):
        rows = build_roads.collect_addresses(self.write([
            ({"addr:street": "Навои", "addr:housenumber": "12"},
             self.point(69.25, 41.30))]))
        self.assertEqual(rows, [("Навои", "12", 69.25, 41.30)])

    def test_building_address_lands_in_the_middle(self):
        # Подъезд нам неизвестен, а середина дома — честный ответ на «куда
        # ехать». В OSM адрес чаще контур, чем точка: 17 153 против 1 517.
        rows = build_roads.collect_addresses(self.write([
            ({"addr:street": "Навои", "addr:housenumber": "12"},
             self.square(41.30, 69.25))]))
        self.assertEqual(len(rows), 1)
        _, _, lon, lat = rows[0]
        self.assertGreater(lat, 41.30)
        self.assertLess(lat, 41.3002)

    def test_address_without_street_is_useless(self):
        # «Дом 12» без улицы не найти и не показать.
        self.assertEqual(build_roads.collect_addresses(self.write([
            ({"addr:housenumber": "12"}, self.point(69.25, 41.30))])), [])

    def test_address_without_number_is_useless(self):
        self.assertEqual(build_roads.collect_addresses(self.write([
            ({"addr:street": "Навои"}, self.point(69.25, 41.30))])), [])

    def test_broken_line_is_skipped_not_fatal(self):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        handle.write("{не json\n")
        json.dump({"type": "Feature",
                   "properties": {"addr:street": "Навои",
                                  "addr:housenumber": "1"},
                   "geometry": {"type": "Point", "coordinates": [69.25, 41.30]}},
                  handle, ensure_ascii=False)
        handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        self.assertEqual(len(build_roads.collect_addresses(handle.name)), 1)

    def test_missing_file_is_not_an_error(self):
        self.assertEqual(build_roads.collect_addresses("/нет/такого"), [])

    # --- Раскладка

    def test_city_lands_in_one_cell(self):
        # Полградуса — полсотни километров: город целиком в одной клетке, и
        # поиск по нему не требует собирать десяток файлов.
        cells = build_roads.addresses_by_cell([
            ("Навои", "1", 69.20, 41.28),
            ("Амира Темура", "5", 69.33, 41.34)])
        self.assertEqual(len(cells), 1)

    def test_street_name_is_written_once(self):
        # Улиц в городе тысячи против десятков тысяч домов: повторять название
        # у каждого дома значит платить за него всем.
        cells = build_roads.addresses_by_cell(
            [("Навои", str(i), 69.25 + i / 10000, 41.30) for i in range(50)])
        payload = list(cells.values())[0]
        self.assertEqual(len(payload["streets"]), 1)
        self.assertEqual(len(payload["streets"][0]["h"]), 50)

    def test_coordinates_are_deltas_like_in_tiles(self):
        # Второй способ паковать координаты в одном проекте — это второй
        # способ ошибиться. Первый дом абсолютный, дальше дельты.
        cells = build_roads.addresses_by_cell([
            ("Навои", "1", 69.25, 41.30),
            ("Навои", "3", 69.25, 41.301)])
        points = list(cells.values())[0]["streets"][0]["p"]
        self.assertEqual(points[0], round(41.30 * build_roads.SCALE))
        self.assertEqual(points[1], round(69.25 * build_roads.SCALE))
        self.assertEqual(len(points), 4)
        self.assertEqual(points[2], 100, "дельта широты посчитана неверно")

    def test_numbers_stay_parallel_to_points(self):
        cells = build_roads.addresses_by_cell([
            ("Навои", "1", 69.25, 41.300),
            ("Навои", "2", 69.25, 41.301),
            ("Навои", "3", 69.25, 41.302)])
        street = list(cells.values())[0]["streets"][0]
        self.assertEqual(len(street["h"]) * 2, len(street["p"]),
                         "номеров и координат разное число — адреса разъедутся")

    def test_two_cities_are_two_files(self):
        cells = build_roads.addresses_by_cell([
            ("Навои", "1", 69.25, 41.30),
            ("Мустакиллик", "2", 66.95, 39.65)])
        self.assertEqual(len(cells), 2)

    def test_empty_input_writes_nothing(self):
        self.assertEqual(build_roads.addresses_by_cell([]), {})


class StreetMergeTests(unittest.TestCase):
    """Куски → улицы, и одна ширина на улицу.

    Сеть при этом ОСТАЁТСЯ сетью: куски, разрезанные по перекрёсткам, — это
    граф, по которому работают магнит, привязка правок и весь конструктор.
    Склейка нужна поверхности — производному слою для картинки.

    Замерено на живом кадре центра: 413 кусков это восемь улиц, по пятнадцать
    кусков на улицу, и у всех восьми в одном кадре две-три разные ширины.
    Отсюда «сосиски»: круглые торцы посреди проезжей части и ступени по
    ширине.
    """

    def road(self, points, code=3, lanes=0, name="Навои", tagged=False,
             oneway=False):
        flags = build_roads.with_lanes(0, lanes)
        if tagged:
            flags |= build_roads.FLAG_LANES_TAGGED
        if oneway:
            flags |= build_roads.FLAG_ONEWAY
        return (code, flags, [tuple(p) for p in points], name)

    def test_pieces_become_one_street(self):
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)]),
            self.road([(69.26, 41.30), (69.27, 41.30)]),
            self.road([(69.27, 41.30), (69.28, 41.30)]),
        ])
        self.assertEqual(len(streets), 1)
        self.assertEqual(len(streets[0][2]), 4, "вершины продублировались")

    def test_pieces_join_whichever_way_they_are_written(self):
        # В экстракте кусок может лежать в обратную сторону; склейка обязана
        # его развернуть, а не начать вторую улицу.
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)]),
            self.road([(69.27, 41.30), (69.26, 41.30)]),
        ])
        self.assertEqual(len(streets), 1)
        self.assertEqual(len(streets[0][2]), 3)

    def test_same_name_apart_stays_two_streets(self):
        # «Мустакиллик» есть в каждом районе: совпавшего имени мало.
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)]),
            self.road([(69.40, 41.35), (69.41, 41.35)]),
        ])
        self.assertEqual(len(streets), 2)

    def test_oneway_is_not_merged_with_its_opposite(self):
        # Односторонняя и встречная ей — две проезжие части, и склеить их в
        # одну ленту значило бы нарисовать одну дорогу там, где их две.
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)], oneway=True),
            self.road([(69.26, 41.30), (69.27, 41.30)], oneway=False),
        ])
        self.assertEqual(len(streets), 2)

    def test_bridge_is_not_merged_with_the_ground(self):
        piece = self.road([(69.26, 41.30), (69.27, 41.30)])
        bridge = (piece[0], piece[1] | build_roads.FLAG_BRIDGE, piece[2], piece[3])
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)]), bridge])
        self.assertEqual(len(streets), 2)

    def test_different_class_stays_apart(self):
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)], code=3),
            self.road([(69.26, 41.30), (69.27, 41.30)], code=6),
        ])
        self.assertEqual(len(streets), 2)

    # --- Ширина

    def test_street_gets_one_width(self):
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)], lanes=6, tagged=True),
            self.road([(69.26, 41.30), (69.27, 41.30)], lanes=3, tagged=True),
        ])
        self.assertEqual(len(streets), 1)
        self.assertAlmostEqual(streets[0][4],
                               build_roads.road_width_meters(3, 6), places=1)

    def test_measured_beats_guessed(self):
        # У куска без тега ширина посчитана по классу; она не должна побеждать
        # измеренную только потому, что оказалась больше.
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)], lanes=2, tagged=True),
            self.road([(69.26, 41.30), (69.27, 41.30)]),
        ])
        self.assertAlmostEqual(streets[0][4],
                               build_roads.road_width_meters(3, 2), places=1)
        self.assertTrue(streets[0][5], "улица не помечена измеренной")

    def test_street_without_measurements_falls_back_to_class(self):
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)])])
        self.assertAlmostEqual(streets[0][4],
                               build_roads.road_width_meters(3, 0), places=1)
        self.assertFalse(streets[0][5])

    # --- Устойчивость

    def test_width_is_per_ribbon_not_per_name(self):
        """Ширина считается по непрерывной ленте, а не по имени улицы.

        Разбор данных: у «Amir Temur shoh ko'chasi» 67 кусков класса 3
        (проспект, 3–5 полос) и 30 кусков класса 4 (дублёр с тем же именем,
        2–3 полосы). Дублёр действительно уже проспекта. Свести их к одной
        ширине значило бы соврать в сторону красивой картинки.
        """
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)], code=3, lanes=6,
                      tagged=True),
            self.road([(69.40, 41.35), (69.41, 41.35)], code=4, lanes=2,
                      tagged=True),
        ])
        widths = sorted(s[4] for s in streets)
        self.assertEqual(len(set(widths)), 2, "дублёр стал проспектом")

    def test_step_inside_one_ribbon_disappears(self):
        # Настоящая причина «сосисок»: пятнадцать кусков подряд, каждый своей
        # шириной. Внутри одной ленты ширина обязана быть одна.
        streets = build_roads.merge_streets([
            self.road([(69.25, 41.30), (69.26, 41.30)], lanes=6, tagged=True),
            self.road([(69.26, 41.30), (69.27, 41.30)], lanes=3, tagged=True),
            self.road([(69.27, 41.30), (69.28, 41.30)], lanes=4, tagged=True),
        ])
        self.assertEqual(len(streets), 1)
        self.assertEqual(len({streets[0][4]}), 1)

    def test_pieces_joined_across_a_bucket_edge(self):
        """Стык на границе клетки индекса — тот же стык.

        Склейка ищет продолжение словарём по концам, а не перебором: перебор
        квадратичен и на стране не кончился бы за ночь. Цена приёма — две
        точки ближе эпсилона могут лечь в РАЗНЫЕ клетки; поэтому соседние
        обходятся тоже. Без этого терялась бы часть стыков, и терялась бы
        молча: улица просто оставалась бы двумя лентами.
        """
        step = 1e-8
        just_before = edge = None
        x = 69.25
        while x < 69.2501:
            if (build_roads._spot_bucket((x, 41.30))
                    != build_roads._spot_bucket((x + step, 41.30))):
                just_before, edge = x, x + step
                break
            x += step
        self.assertIsNotNone(edge, "границы клетки не нашлось")
        self.assertNotEqual(build_roads._spot_bucket((edge, 41.30)),
                            build_roads._spot_bucket((just_before, 41.30)),
                            "точки легли в одну клетку — проверка ничего не ловит")
        self.assertTrue(build_roads._same_spot((edge, 41.30),
                                               (just_before, 41.30)))
        streets = build_roads.merge_streets([
            self.road([(69.24, 41.30), (edge, 41.30)]),
            self.road([(just_before, 41.30), (69.26, 41.30)]),
        ])
        self.assertEqual(len(streets), 1, "стык на границе клетки потерян")

    def test_order_does_not_depend_on_input_order(self):
        # Недетерминированная сборка меняет sha256 всех тайлов, и каждый
        # телефон перекачивает свои файлы впустую.
        pieces = [self.road([(69.25, 41.30), (69.26, 41.30)]),
                  self.road([(69.26, 41.30), (69.27, 41.30)]),
                  self.road([(69.40, 41.35), (69.41, 41.35)], name="Другая")]
        first = build_roads.merge_streets(pieces)
        second = build_roads.merge_streets(list(reversed(pieces)))
        self.assertEqual(first, second)

    def test_network_itself_is_not_touched(self):
        # Сеть остаётся сетью: склейка ничего не должна менять в переданном.
        pieces = [self.road([(69.25, 41.30), (69.26, 41.30)]),
                  self.road([(69.26, 41.30), (69.27, 41.30)])]
        copy = [(p[0], p[1], list(p[2]), p[3]) for p in pieces]
        build_roads.merge_streets(pieces)
        self.assertEqual([(p[0], p[1], list(p[2]), p[3]) for p in pieces], copy)

    def test_empty_input(self):
        self.assertEqual(build_roads.merge_streets([]), [])


class StreamedHouseTests(unittest.TestCase):
    """Дома раскладываются ПОТОКОМ, а не списком.

    Это единственный слой, который в память не влезает: в одном кадре центра
    Ташкента 54 094 дома при семистах дорогах, по стране — миллионы контуров.
    На сервере 2 ГБ памяти, свободен один, и рядом работают API и панель;
    собранный списком слой убил бы их обоих.
    """

    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.work, True)

    def write(self, squares):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        for lat, lon, meters in squares:
            step = meters / 111_320.0
            ring = [[lon, lat], [lon + step, lat], [lon + step, lat + step],
                    [lon, lat + step], [lon, lat]]
            json.dump({"type": "Feature", "properties": {"building": "yes"},
                       "geometry": {"type": "Polygon", "coordinates": [ring]}},
                      handle)
            handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def rows_of(self, composite):
        path = os.path.join(self.work, f"road2_{composite}.json")
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)["roads"]

    def test_houses_land_in_their_tiles(self):
        source = self.write([(41.30, 69.25, 40), (41.36, 69.25, 40)])
        laid = build_roads.stream_houses(source, self.work, 0.05)
        self.assertEqual(len(laid), 2, "дома не разошлись по тайлам")
        self.assertEqual(sum(len(self.rows_of(k)) for k in laid), 2)
        for composite, meta in laid.items():
            self.assertTrue(composite.endswith("_h"))
            self.assertGreater(meta["bytes"], 0)
            self.assertEqual(len(meta["sha256"]), 64)

    def test_records_are_ready_for_the_tile(self):
        laid = build_roads.stream_houses(
            self.write([(41.30, 69.25, 40)]), self.work, 0.05)
        record = self.rows_of(list(laid)[0])[0]
        self.assertEqual(record[0], build_roads.AREA_HOUSE)
        self.assertTrue(record[1] & build_roads.AREA_FLAG_CLOSED)
        self.assertGreaterEqual(len(record[2]), 8, "контур короче четырёх точек")

    def test_order_inside_a_tile_is_stable(self):
        # Недетерминированная сборка меняет sha256 всех тайлов каждую неделю,
        # и каждый телефон перекачивает свои файлы впустую.
        source = self.write([(41.302, 69.252, 40), (41.301, 69.251, 40),
                             (41.303, 69.253, 40)])
        first = build_roads.stream_houses(source, self.work, 0.05)
        second = build_roads.stream_houses(source, self.work, 0.05)
        self.assertEqual(first, second)

    def test_shed_is_dropped_in_the_stream_too(self):
        laid = build_roads.stream_houses(
            self.write([(41.30, 69.25, 3)]), self.work, 0.05)
        self.assertEqual(laid, {})

    def test_missing_file_is_not_an_error(self):
        self.assertEqual(build_roads.stream_houses("/нет/такого", self.work, 0.05), {})

    def test_temporary_files_do_not_stay(self):
        # Каталог тайлов — то, что уедет на телефоны. Рабочие файлы в нём
        # означали бы мусор в публикации.
        laid = build_roads.stream_houses(self.write([(41.30, 69.25, 40)]),
                                         self.work, 0.05)
        left = sorted(os.listdir(self.work))
        self.assertEqual(left, sorted(f"road2_{k}.json" for k in laid),
                         "в каталоге публикации остался рабочий файл")

    def test_more_tiles_than_open_files(self):
        # Ради этого потоковая раскладка и заводилась: число тайлов не должно
        # упираться в число одновременно открытых файлов.
        squares = [(41.30 + i * 0.06, 69.25, 40) for i in range(12)]
        laid = build_roads.stream_houses(self.write(squares), self.work, 0.05,
                                         handles=3)
        self.assertGreater(len(laid), 3, "тайлов меньше, чем открытых файлов")
        self.assertGreaterEqual(sum(len(self.rows_of(k)) for k in laid), 12)
        # Дом на границе попадает в оба тайла — как дорога, задевшая два: на
        # телефоне тайлы приходят порознь, и объект, лежащий только в одном,
        # исчезал бы на краю соседнего.


class DrawnHouseTests(unittest.TestCase):
    """Дом, обведённый руками.

    Правило то же, что у всего остального в конструкторе: панель заводит
    объект ТОГО ЖЕ вида, что приезжает из OSM. Поэтому нарисованный дом едет
    тем же слоем, а его адрес — тем же адресным файлом, и телефон не знает и
    не должен знать, откуда взялся дом.
    """

    def ring(self, lat, lon, meters=20, **props):
        step = meters / 111_320.0
        return {"kind": "area",
                "geom": [[lon, lat], [lon + step, lat], [lon + step, lat + step],
                         [lon, lat + step], [lon, lat]],
                "props": dict(props, area=build_roads.AREA_HOUSE)}

    def test_drawn_house_becomes_a_house(self):
        built = build_roads.drawn_areas([self.ring(41.30, 69.25)])
        self.assertEqual(len(built), 1)
        self.assertEqual(built[0][0], build_roads.AREA_HOUSE)
        self.assertTrue(built[0][1] & build_roads.AREA_FLAG_CLOSED)

    def test_house_has_its_own_size_floor(self):
        # Типовой дом в периметре — сорок метров; общий порог местности в
        # тридцать выбросил бы половину нарисованных руками домов.
        self.assertLess(build_roads.MIN_DRAWN_HOUSE_METERS,
                        build_roads.MIN_DRAWN_AREA_METERS)
        self.assertEqual(len(build_roads.drawn_areas([self.ring(41.30, 69.25, 8)])), 1)

    def test_tiny_scribble_is_still_noise(self):
        self.assertEqual(build_roads.drawn_areas([self.ring(41.30, 69.25, 1)]), [])

    def test_address_of_a_drawn_house_reaches_the_search(self):
        rows = build_roads.drawn_addresses(
            [self.ring(41.30, 69.25, street="Навои", house="12")])
        self.assertEqual(len(rows), 1)
        street, number, lon, lat = rows[0]
        self.assertEqual((street, number), ("Навои", "12"))
        self.assertAlmostEqual(lat, 41.3001, places=3)

    def test_house_without_address_is_still_drawn(self):
        # Требовать номер ради обводки — значит получить выдуманные номера.
        one = self.ring(41.30, 69.25)
        self.assertEqual(build_roads.drawn_addresses([one]), [])
        self.assertEqual(len(build_roads.drawn_areas([one])), 1)

    def test_half_an_address_is_not_an_address(self):
        self.assertEqual(build_roads.drawn_addresses(
            [self.ring(41.30, 69.25, street="Навои")]), [])
        self.assertEqual(build_roads.drawn_addresses(
            [self.ring(41.30, 69.25, house="12")]), [])

    def test_other_areas_bring_no_addresses(self):
        green = {"kind": "area", "props": {"area": build_roads.AREA_GREEN,
                                           "street": "Навои", "house": "1"},
                 "geom": [[69.25, 41.30], [69.26, 41.30], [69.26, 41.31]]}
        self.assertEqual(build_roads.drawn_addresses([green]), [])


class HouseTests(unittest.TestCase):
    """Дома.

    Самый большой слой по числу объектов и самый спорный за рулём: водитель
    едет по дороге, а не по подъездам. Замерено на живых данных — в одном
    кадре центра Ташкента 54 094 дома из OSM против семисот дорог, — поэтому
    у слоя свой порог размера и своё, более грубое упрощение. Всё остальное в
    нём должно быть таким же, как у воды и зелени: тот же список, та же
    запись, та же отрисовка на телефоне.
    """

    def write(self, rows):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        for ring in rows:
            json.dump({"type": "Feature", "properties": {"building": "yes"},
                       "geometry": {"type": "Polygon", "coordinates": [ring]}},
                      handle)
            handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def square(self, lat, lon, meters):
        step = meters / 111_320.0
        return [[lon, lat], [lon + step, lat], [lon + step, lat + step],
                [lon, lat + step], [lon, lat]]

    def test_house_becomes_a_closed_area(self):
        built = build_roads.collect_houses(
            self.write([self.square(41.30, 69.25, 40)]), 0.0)
        self.assertEqual(len(built), 1)
        kind, flags, points = built[0]
        self.assertEqual(kind, build_roads.AREA_HOUSE)
        self.assertTrue(flags & build_roads.AREA_FLAG_CLOSED)
        self.assertEqual(points[0], points[-1], "контур не замкнут")

    def test_typical_house_survives_the_pipeline_tolerance(self):
        # Сторож против ошибки, которая уже случилась: допуск домов был задан
        # кратным дорожному, и шестнадцать метров сглаживания стирали типовой
        # дом целиком — в тайлы доезжала треть. Допуск обязан быть соразмерен
        # ОБЪЕКТУ, а не соседнему слою.
        source = self.write([self.square(41.30, 69.25, 10)])
        built = build_roads.collect_houses(
            source, build_roads.HOUSE_SIMPLIFY_METERS / 111_320.0)
        self.assertEqual(len(built), 1, "типовой дом схлопнулся при упрощении")

    def test_house_tolerance_is_smaller_than_the_house_floor(self):
        # Правило, из которого следует предыдущий тест: сглаживать сильнее,
        # чем сам порог размера, — значит гарантированно терять пограничные
        # дома.
        self.assertLess(build_roads.HOUSE_SIMPLIFY_METERS,
                        build_roads.MIN_HOUSE_METERS)

    def test_shed_is_dropped(self):
        # Гараж и навес за рулём не помогают найти подъезд, а по числу их
        # больше, чем домов: порог убирает треть объектов.
        self.assertEqual(build_roads.collect_houses(
            self.write([self.square(41.30, 69.25, 4)]), 0.0), [])

    def test_line_is_not_a_house(self):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        json.dump({"type": "Feature", "properties": {"building": "yes"},
                   "geometry": {"type": "LineString",
                                "coordinates": [[69.25, 41.30], [69.26, 41.31]]}},
                  handle)
        handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        self.assertEqual(build_roads.collect_houses(handle.name, 0.0), [])

    def test_broken_line_is_skipped_not_fatal(self):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        handle.write("{не json\n")
        json.dump({"type": "Feature", "properties": {},
                   "geometry": {"type": "Polygon",
                                "coordinates": [self.square(41.30, 69.25, 40)]}},
                  handle)
        handle.write("\n")
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        self.assertEqual(len(build_roads.collect_houses(handle.name, 0.0)), 1)

    def test_missing_file_is_not_an_error(self):
        # Ключ необязателен: сборка без зданий должна работать так же, как до
        # того, как слой появился.
        self.assertEqual(build_roads.collect_houses("/нет/такого", 0.0), [])

    def test_houses_ride_in_their_own_set(self):
        # Слой, невидимый на текущем охвате, не качается и не разбирается —
        # тот же закон, что у воды и зелени. Дома с их числом объектов это
        # правило и оправдывает.
        self.assertIn(build_roads.AREA_HOUSE, {build_roads.AREA_WATER: 0,
                                               build_roads.AREA_GREEN: 0,
                                               build_roads.AREA_RAIL: 0,
                                               build_roads.AREA_BLOCK: 0,
                                               build_roads.AREA_SIDEWALK: 0,
                                               build_roads.AREA_HOUSE: 0})
        self.assertEqual(build_roads.SET_HOUSES, "h")
        self.assertNotIn(build_roads.SET_HOUSES,
                         {build_roads.SET_WATER, build_roads.SET_GREEN,
                          build_roads.SET_RAIL, build_roads.SET_BLOCKS,
                          build_roads.SET_SIDEWALK, build_roads.SET_FAR,
                          build_roads.SET_STREETS, build_roads.SET_YARDS,
                          build_roads.SET_POINTS, build_roads.SET_POINTS_FAR})

    def test_area_code_does_not_collide(self):
        codes = [build_roads.AREA_WATER, build_roads.AREA_GREEN,
                 build_roads.AREA_RAIL, build_roads.AREA_BLOCK,
                 build_roads.AREA_SIDEWALK, build_roads.AREA_HOUSE]
        self.assertEqual(len(codes), len(set(codes)))


class NameAndLandTests(unittest.TestCase):
    """Название дороги и обведённая руками местность.

    Оба — про то же правило, что и всё остальное в конструкторе: панель заводит
    объект ТОГО ЖЕ вида, что приезжает из OSM, а не параллельный. Поэтому
    телефон рисует их тем же кодом, и добавлять там нечего.
    """

    def road(self, code, coords, name=""):
        return (code, 0, [(lon, lat) for lat, lon in coords], name)

    def naming(self, lat, lon, text):
        return {"kind": "name", "geom": [lon, lat], "props": {"name": text}}

    def ring(self, code, *coords):
        return {"kind": "area", "geom": [[lon, lat] for lat, lon in coords],
                "props": {"area": code}}

    # --- Название

    def test_hand_name_overrides_osm(self):
        # Название — единственное, что человек знает лучше OSM всегда: он там
        # был.
        street = self.road(4, [(41.300, 69.250), (41.310, 69.250)], "Старое")
        patched, applied, _ = build_roads.apply_edits(
            [street], [self.naming(41.305, 69.2501, "Новое")])
        self.assertEqual(applied, 1)
        self.assertEqual(patched[0][3], "Новое")

    def test_empty_name_is_refused(self):
        street = self.road(4, [(41.300, 69.250), (41.310, 69.250)], "Старое")
        patched, applied, missed = build_roads.apply_edits(
            [street], [self.naming(41.305, 69.2501, "   ")])
        self.assertEqual((applied, missed), (0, 1))
        self.assertEqual(patched[0][3], "Старое")

    def test_name_does_not_touch_lanes(self):
        street = self.road(4, [(41.300, 69.250), (41.310, 69.250)])
        before = street[1]
        patched, _, _ = build_roads.apply_edits(
            [street], [self.naming(41.305, 69.2501, "Новое")])
        self.assertEqual(patched[0][1], before)

    # --- Местность

    def test_drawn_area_becomes_a_layer_object(self):
        built = build_roads.drawn_areas([self.ring(
            build_roads.AREA_GREEN, (41.300, 69.250), (41.301, 69.250),
            (41.301, 69.251))])
        self.assertEqual(len(built), 1)
        kind, flags, points = built[0]
        self.assertEqual(kind, build_roads.AREA_GREEN)
        self.assertTrue(flags & build_roads.AREA_FLAG_CLOSED,
                        "обведённое руками — полигон, а не лента")

    def test_unknown_area_kind_is_refused(self):
        self.assertEqual(build_roads.drawn_areas([self.ring(
            99, (41.300, 69.250), (41.301, 69.250), (41.301, 69.251))]), [])

    def test_two_points_are_not_a_contour(self):
        self.assertEqual(build_roads.drawn_areas([self.ring(
            build_roads.AREA_GREEN, (41.300, 69.250), (41.301, 69.250))]), [])

    def test_tiny_contour_is_noise(self):
        self.assertEqual(build_roads.drawn_areas([self.ring(
            build_roads.AREA_GREEN, (41.30000, 69.25000), (41.30001, 69.25000),
            (41.30001, 69.25001))]), [])

    def test_broken_contour_is_skipped_not_fatal(self):
        self.assertEqual(build_roads.drawn_areas(
            [{"kind": "area", "geom": [["чушь", 1], [2, 3], [4, 5]],
              "props": {"area": 2}}]), [])


class ReplaceRoadTests(unittest.TestCase):
    """Перерисованная дорога заменяет старую, а не ложится рядом.

    Модератор, поправивший геометрию улицы, ждёт, что на схеме останется ОДНА
    дорога — его. Без замены их будет две: старая из OSM и новая поверх неё в
    нескольких метрах, и водитель увидит на месте улицы двойную линию.
    """

    def road(self, coords):
        return (4, 0, [(lon, lat) for lat, lon in coords], "")

    def redraw(self, coords, replace=True):
        return {"kind": "geometry",
                "geom": [[lon, lat] for lat, lon in coords],
                "props": {"cls": 4, "replace": replace}}

    def test_redrawn_road_removes_the_old_one(self):
        old = self.road([(41.300, 69.250), (41.302, 69.250)])
        mine = self.redraw([(41.300, 69.25002), (41.302, 69.25002)])
        kept, dropped = build_roads.suppress([old], [mine])
        self.assertEqual((len(kept), dropped), (0, 1))

    def test_road_further_than_the_band_survives(self):
        far = self.road([(41.300, 69.2510), (41.302, 69.2510)])
        mine = self.redraw([(41.300, 69.250), (41.302, 69.250)])
        kept, dropped = build_roads.suppress([far], [mine])
        self.assertEqual((len(kept), dropped), (1, 0))

    def test_drawing_without_replace_removes_nothing(self):
        # Новая дорога рядом с существующей — законный случай: дублёр, съезд.
        old = self.road([(41.300, 69.250), (41.302, 69.250)])
        mine = self.redraw([(41.300, 69.25002), (41.302, 69.25002)], replace=False)
        kept, dropped = build_roads.suppress([old], [mine])
        self.assertEqual((len(kept), dropped), (1, 0))

    def test_road_only_partly_covered_survives(self):
        # У чужой дороги может быть длинный хвост за перерисованным куском —
        # выбрасывать её целиком нельзя.
        long_road = self.road([(41.300, 69.250), (41.302, 69.250),
                               (41.310, 69.250), (41.320, 69.250),
                               (41.330, 69.250)])
        mine = self.redraw([(41.300, 69.25002), (41.302, 69.25002)])
        kept, dropped = build_roads.suppress([long_road], [mine])
        self.assertEqual((len(kept), dropped), (1, 0))

    def test_broken_geometry_suppresses_nothing(self):
        old = self.road([(41.300, 69.250), (41.302, 69.250)])
        broken = {"kind": "geometry", "geom": [["чушь", 1]], "props": {"replace": True}}
        kept, dropped = build_roads.suppress([old], [broken])
        self.assertEqual((len(kept), dropped), (1, 0))


class DrawnPointTests(unittest.TestCase):
    """Обстановка, поставленная руками.

    Виды те же, что приезжают из OSM, и это решение, а не совпадение: панель
    заводит объект ТОГО ЖЕ вида, а не параллельный. Поэтому он идёт общим
    конвейером — привязка к узлу, сведение, посадка на ось с расчётом азимута и
    ширины, — и на телефоне не меняется ничего.
    """

    def mark(self, code, lat=41.305, lon=69.2501, **props):
        props["point"] = code
        return {"kind": "point", "geom": [lon, lat], "props": props}

    def test_hand_placed_light_becomes_a_point(self):
        pts = build_roads.drawn_points([self.mark(build_roads.POINT_TRAFFIC_LIGHT)])
        self.assertEqual(len(pts), 1)
        self.assertEqual(pts[0][0], build_roads.POINT_TRAFFIC_LIGHT)

    def test_unknown_kind_is_refused(self):
        self.assertEqual(build_roads.drawn_points([self.mark(99)]), [])

    def test_a_road_is_not_a_point(self):
        self.assertEqual(build_roads.drawn_points(
            [{"kind": "geometry", "geom": [[69.25, 41.3], [69.26, 41.3]]}]), [])

    def test_broken_geometry_is_skipped(self):
        for geom in ([], [69.25], [[69.25, 41.3]], ["чушь", 1]):
            self.assertEqual(build_roads.drawn_points(
                [{"kind": "point", "geom": geom, "props": {"point": 1}}]), [])

    def test_hand_placed_mark_gets_azimuth_and_width_from_the_road(self):
        # Азимут и ширину считает не человек: он их не знает и знать не должен.
        street = (4, build_roads.with_lanes(0, 4),
                  [(69.250, 41.300), (69.250, 41.310)], "")
        pts = build_roads.drawn_points([self.mark(build_roads.POINT_CROSSING)])
        snapped, dropped = build_roads.snap_points(pts, [street])
        self.assertEqual(dropped, 0)
        self.assertGreater(build_roads.point_width(snapped[0][1]), 0)

    def test_hand_placed_arrows_keep_their_turns(self):
        pts = build_roads.drawn_points([self.mark(
            build_roads.POINT_LANE_ARROWS,
            turns=[build_roads.TURN_LEFT, build_roads.TURN_THROUGH])])
        self.assertEqual(build_roads.unpack_turns(pts[0][1], 2),
                         [build_roads.TURN_LEFT, build_roads.TURN_THROUGH])


class SidewalkTests(unittest.TestCase):
    """Тротуары: свой набор тайла, своя полоса охвата.

    Их больше, чем всех улиц вместе — 3 439 против 8 455 дорог в одном центре
    Ташкента. Слой такого размера обязан жить отдельным файлом, иначе он
    удваивает трафик всю дорогу ради вида, который наступает только вблизи.
    """

    def line(self, coords):
        return [(lon, lat) for lat, lon in coords]

    def test_sidewalk_is_read_from_the_same_file_as_roads(self):
        # Фильтр osmium берёт w/highway целиком, тротуары отсеивает уже
        # CLASS_CODES. Читать экстракт второй раз ради них незачем.
        source = ('{"type":"Feature","properties":{"highway":"footway"},'
                  '"geometry":{"type":"LineString","coordinates":'
                  '[[69.25,41.30],[69.25,41.302]]}}\n'
                  '{"type":"Feature","properties":{"highway":"primary"},'
                  '"geometry":{"type":"LineString","coordinates":'
                  '[[69.26,41.30],[69.26,41.302]]}}\n')
        with tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                         delete=False, encoding="utf-8") as handle:
            handle.write(source)
            path = handle.name
        try:
            roads, _, _, _, _, _, sidewalks, _, _ = build_roads.collect(path)
        finally:
            os.unlink(path)
        self.assertEqual(len(roads), 1, "тротуар не должен попасть в дороги")
        self.assertEqual(len(sidewalks), 1, "тротуар обязан приехать отдельно")

    def test_stairs_and_paths_are_not_sidewalks(self):
        # Лестница — не путь вдоль дороги, на схеме она обрубок; тропа может
        # уходить куда угодно.
        self.assertNotIn("steps", build_roads.SIDEWALK_HIGHWAYS)
        self.assertNotIn("path", build_roads.SIDEWALK_HIGHWAYS)
        self.assertIn("footway", build_roads.SIDEWALK_HIGHWAYS)

    def test_stubs_are_dropped(self):
        short = self.line([(41.3000, 69.2500), (41.30005, 69.2500)])
        long = self.line([(41.3000, 69.2500), (41.3010, 69.2500)])
        built = build_roads.build_sidewalks([short, long], 0)
        self.assertEqual(len(built), 1, "обрубок короче порога — шум на схеме")

    def test_sidewalk_is_an_open_ribbon(self):
        built = build_roads.build_sidewalks(
            [self.line([(41.300, 69.250), (41.302, 69.250)])], 0)
        kind, flags, _ = built[0]
        self.assertEqual(kind, build_roads.AREA_SIDEWALK)
        self.assertFalse(flags & build_roads.AREA_FLAG_CLOSED,
                         "тротуар — лента, а не полигон: замкнутый залился бы")

    def test_sidewalks_go_to_their_own_tile_set(self):
        with tempfile.TemporaryDirectory() as work:
            road = (3, 0, self.line([(41.300, 69.25), (41.302, 69.25)]), "")
            walk = build_roads.build_sidewalks(
                [self.line([(41.300, 69.2502), (41.302, 69.2502)])], 0)
            build_roads.write_tiles([road], work, 0.05, walk, [], [], [road])
            names = os.listdir(work)
            self.assertTrue(any(n.endswith("_t.json") for n in names),
                            f"набора тротуаров нет среди {sorted(names)}")
            # И их нет в наборе улиц: иначе слой качался бы всегда.
            street = [n for n in names if n.endswith("_s.json")][0]
            with open(os.path.join(work, street), encoding="utf-8") as handle:
                tile = json.load(handle)
            self.assertTrue(all(entry[0] != build_roads.AREA_SIDEWALK
                                for entry in tile["roads"]))


class EditBakingTests(unittest.TestCase):
    """Запекание правок панели в тайлы.

    Запекаем, а не возим отдельным файлом: иначе телефону пришлось бы качать
    его, разбирать и СЛИВАТЬ С ДОРОГАМИ — то есть делать работу, которую с него
    только что сняли. Запечённая правка не стоит ему ничего.

    Правка ищет свою дорогу по МЕСТУ. По id нельзя: id ведёт в OSM и не
    переживает воскресной пересборки — у той же улицы назавтра другой way.
    """

    def road(self, code, flags, coords, name=""):
        return (code, flags, [(lon, lat) for lat, lon in coords], name)

    def edit(self, lat, lon, lanes, kind="lanes"):
        return {"kind": kind, "geom": [lon, lat], "props": {"lanes": lanes}}

    def test_edit_overrides_the_class_default(self):
        street = self.road(4, 0, [(41.300, 69.250), (41.310, 69.250)])
        patched, applied, missed = build_roads.apply_edits(
            [street], [self.edit(41.305, 69.2501, 6)])
        self.assertEqual((applied, missed), (1, 0))
        self.assertEqual(build_roads.lanes_of(patched[0][1]), 6)

    def test_edit_beats_the_osm_tag(self):
        # Рука модератора старше автоматики: он смотрел на спутник.
        street = self.road(4, build_roads.with_lanes(0, 2),
                           [(41.300, 69.250), (41.310, 69.250)])
        patched, _, _ = build_roads.apply_edits(
            [street], [self.edit(41.305, 69.2501, 6)])
        self.assertEqual(build_roads.lanes_of(patched[0][1]), 6)

    def test_edit_does_not_beat_the_class_ceiling(self):
        # …но не старше физики: опечатка модератора не должна залить квартал.
        yard = self.road(7, 0, [(41.300, 69.250), (41.310, 69.250)])
        patched, _, _ = build_roads.apply_edits(
            [yard], [self.edit(41.305, 69.2501, 15)])
        self.assertEqual(build_roads.lanes_of(patched[0][1]),
                         build_roads.MAX_LANES_BY_CLASS[7])

    def test_edit_that_lost_its_road_is_reported_not_swallowed(self):
        # Промах — сигнал для очереди изменений, а не мелочь для лога.
        street = self.road(4, 0, [(41.300, 69.250), (41.310, 69.250)])
        _, applied, missed = build_roads.apply_edits(
            [street], [self.edit(41.900, 69.900, 6)])
        self.assertEqual((applied, missed), (0, 1))

    def test_edit_takes_the_road_off_the_queue(self):
        # Модератор смотрел на спутник — дороге в очереди конструктора больше
        # делать нечего.
        street = self.road(4, 0, [(41.300, 69.250), (41.310, 69.250)])
        patched, _, _ = build_roads.apply_edits(
            [street], [self.edit(41.305, 69.2501, 6)])
        self.assertTrue(patched[0][1] & build_roads.FLAG_LANES_TAGGED)

    def test_edit_does_not_disturb_other_roads(self):
        target = self.road(4, 0, [(41.300, 69.250), (41.310, 69.250)])
        other = self.road(4, 0, [(41.300, 69.260), (41.310, 69.260)])
        patched, _, _ = build_roads.apply_edits(
            [target, other], [self.edit(41.305, 69.2501, 6)])
        self.assertEqual(build_roads.lanes_of(patched[1][1]), 0)

    def test_other_kinds_are_left_for_their_own_stage(self):
        # turn_lanes и своя геометрия запекаются иначе; молча применять их как
        # полосы нельзя.
        street = self.road(4, 0, [(41.300, 69.250), (41.310, 69.250)])
        patched, applied, _ = build_roads.apply_edits(
            [street], [self.edit(41.305, 69.2501, 6, kind="turn_lanes")])
        self.assertEqual(applied, 0)
        self.assertEqual(build_roads.lanes_of(patched[0][1]), 0)

    def test_build_works_where_the_panel_never_existed(self):
        self.assertEqual(build_roads.load_edits(None), [])
        self.assertEqual(build_roads.load_edits("/нет/такого"), [])
        self.assertEqual(build_roads.apply_edits([], []), ([], 0, 0))


if __name__ == "__main__":
    unittest.main()


class SurfaceTests(unittest.TestCase):
    """Контур полотна считается в сборке, а не в браузере на каждый кадр."""

    def street(self, points, code=4, width=14.0):
        return (code, 0, points, "", width, True)

    def test_contour_is_closed_and_wraps_both_sides(self):
        points = [(69.25, 41.30), (69.26, 41.30)]
        ring = build_roads.road_contour(points, 14.0)
        self.assertGreaterEqual(len(ring), 4)
        above = [p for p in ring if p[1] > 41.30]
        below = [p for p in ring if p[1] < 41.30]
        self.assertTrue(above and below, "контур обошёл осевую с одной стороны")

    def test_area_matches_length_by_width(self):
        points = [(69.25, 41.30), (69.26, 41.30)]
        width = 14.0
        ring = build_roads.road_contour(points, width)
        got = abs(build_roads.signed_area_meters(ring))
        want = build_roads.polyline_meters(points) * width
        self.assertLess(abs(got - want) / want, 0.10,
                        f"площадь {got:.0f} м² против ожидаемых {want:.0f} м²")

    def test_turn_does_not_grow_a_beak(self):
        # Острый угол без скругления даёт «клюв» длиной в несколько ширин:
        # площадь взлетает, и это видно на карте как шип поперёк квартала.
        straight = [(69.25, 41.30), (69.26, 41.30)]
        bent = [(69.25, 41.30), (69.26, 41.30), (69.26, 41.31)]
        turned = abs(build_roads.signed_area_meters(
            build_roads.road_contour(bent, 14.0)))
        line = abs(build_roads.signed_area_meters(
            build_roads.road_contour(straight, 14.0)))
        self.assertLess(turned, line * 2.6, "на повороте вырос клюв")

    def test_yards_get_no_surface(self):
        made = build_roads.build_surface([self.street(
            [(69.25, 41.30), (69.26, 41.30)], code=7)])
        self.assertEqual(made, [], "дворовый проезд получил полотно")

    def test_class_travels_in_flags(self):
        made = build_roads.build_surface([self.street(
            [(69.25, 41.30), (69.26, 41.30)], code=3)])
        self.assertEqual(len(made), 1)
        kind, flags, _ring = made[0]
        self.assertEqual(kind, build_roads.AREA_ROAD)
        self.assertTrue(flags & build_roads.AREA_FLAG_CLOSED)
        self.assertEqual(build_roads.surface_class(flags), 3)

    def test_record_stays_three_long(self):
        # Пятый элемент возвращает nil на ВЕСЬ тайл у установленных сборок.
        for record in build_roads.build_surface([self.street(
                [(69.25, 41.30), (69.26, 41.30)])]):
            self.assertEqual(len(record), 3)

    def test_degenerate_input_gives_nothing(self):
        self.assertEqual(build_roads.road_contour([(69.25, 41.30)], 14.0), [])
        self.assertEqual(build_roads.road_contour(
            [(69.25, 41.30), (69.25, 41.30)], 14.0), [])
        self.assertEqual(build_roads.road_contour(
            [(69.25, 41.30), (69.26, 41.30)], 0), [])


class JunctionTests(unittest.TestCase):
    """Перекрёсток — площадь между кромками, а не круг и не заглушка."""

    def cross(self):
        node = (69.25, 41.30)
        arms = [[(node, (69.26, 41.30), 14.0)],
                [(node, (69.24, 41.30), 14.0)],
                [(node, (69.25, 41.31), 10.0)]]
        return {build_roads._node_key(node): [a[0] for a in arms]}

    def test_three_arms_give_a_polygon(self):
        made = build_roads.build_junctions(self.cross())
        self.assertEqual(len(made), 1)
        kind, flags, ring = made[0]
        self.assertEqual(kind, build_roads.AREA_JUNCTION)
        self.assertTrue(flags & build_roads.AREA_FLAG_CLOSED)
        self.assertGreaterEqual(len(ring), 3)

    def test_two_arms_give_nothing(self):
        node = (69.25, 41.30)
        arms = {build_roads._node_key(node): [
            (node, (69.26, 41.30), 14.0), (node, (69.24, 41.30), 14.0)]}
        self.assertEqual(build_roads.build_junctions(arms), [],
                         "стык двух кусков выдан за перекрёсток")

    def test_hull_covers_the_node(self):
        _kind, _flags, ring = build_roads.build_junctions(self.cross())[0]
        lons = [p[0] for p in ring]
        lats = [p[1] for p in ring]
        self.assertLess(min(lons), 69.25)
        self.assertGreater(max(lons), 69.25)
        self.assertLess(min(lats), 41.30)
        self.assertGreater(max(lats), 41.30)

    def test_flare_is_not_wider_than_a_quarter_nor_than_the_node(self):
        node = (69.25, 41.30)
        arms = {build_roads._node_key(node): [
            (node, (69.26, 41.30), 20.0),
            (node, (69.24, 41.30), 20.0),
            (node, (69.25, 41.31), 4.0)]}
        made = build_roads.build_flares(arms)
        self.assertTrue(made, "фаска не построена")
        for _kind, _flags, ring in made:
            width = build_roads.meters_between(ring[1], ring[2])
            self.assertLessEqual(width, 20.0 + 0.01, "фаска шире узла")
            self.assertLessEqual(width, 4.0 * 1.5 + 0.01,
                                 "фаска шире четверти на сторону")

    def test_records_stay_three_long(self):
        for record in (build_roads.build_junctions(self.cross())
                       + build_roads.build_flares(self.cross())):
            self.assertEqual(len(record), 3)


class SurfaceFlagTests(unittest.TestCase):
    """Слой считается по ВСЕЙ сети — включать его на боевом молча нельзя."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.roads = [(4, 0, [(69.25, 41.30), (69.26, 41.30)], ""),
                      (4, 0, [(69.26, 41.30), (69.26, 41.31)], "")]

    def files(self):
        return [f for f in os.listdir(self.dir) if f.endswith("_d.json")]

    def test_surface_is_written_by_default(self):
        build_roads.write_tiles(self.roads, self.dir)
        self.assertTrue(self.files(), "набор d не написан")

    def test_surface_can_be_switched_off(self):
        build_roads.write_tiles(self.roads, self.dir, surface=False)
        self.assertEqual(self.files(), [], "набор d написан вопреки ключу")


class StreamedSurfaceTests(unittest.TestCase):
    """Поверхность — на диск потоком, как дома.

    Списком её держать нельзя: 433 байта на дорогу при 604 522 дорогах в
    стране. Первый боевой прогон это и доказал — ядро убило сборку на шаге
    3/4, при полутора гигабайтах свободной памяти.
    """

    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.work, True)
        # Нарочно ВНУТРИ одного тайла: фигура, задевшая два, пишется в оба —
        # как дорога, — и сравнивать её с плоским списком было бы сравнением
        # разного. Раздвоение на границе стережёт тест домов.
        self.roads = [(4, 0, [(69.262, 41.312), (69.270, 41.312)], "Первая"),
                      (4, 0, [(69.270, 41.312), (69.270, 41.318)], "Первая"),
                      (4, 0, [(69.270, 41.312), (69.276, 41.316)], "Вторая")]

    def rows_of(self, composite):
        with open(os.path.join(self.work, f"road2_{composite}.json"),
                  encoding="utf-8") as handle:
            return json.load(handle)["roads"]

    def test_writes_files_and_returns_only_the_index(self):
        laid = build_roads.stream_surface(self.roads, self.work, 0.05)
        self.assertTrue(laid, "поверхность не написана")
        for composite, meta in laid.items():
            self.assertTrue(composite.endswith("_d"))
            self.assertEqual(len(meta["sha256"]), 64)
            self.assertGreater(meta["bytes"], 0)
            self.assertTrue(os.path.exists(
                os.path.join(self.work, f"road2_{composite}.json")))

    def test_same_shapes_as_the_in_memory_build(self):
        laid = build_roads.stream_surface(self.roads, self.work, 0.05)
        streamed = sum(len(self.rows_of(k)) for k in laid)
        self.assertEqual(streamed, len(build_roads.build_road_surface(self.roads)),
                         "поток и список дали разное число фигур")

    def test_records_stay_three_long(self):
        laid = build_roads.stream_surface(self.roads, self.work, 0.05)
        for composite in laid:
            for record in self.rows_of(composite):
                self.assertEqual(len(record), 3)

    def test_temporary_files_do_not_stay(self):
        laid = build_roads.stream_surface(self.roads, self.work, 0.05)
        self.assertEqual(sorted(os.listdir(self.work)),
                         sorted(f"road2_{k}.json" for k in laid),
                         "в каталоге публикации остался рабочий файл")

    def test_order_is_stable(self):
        first = build_roads.stream_surface(self.roads, self.work, 0.05)
        second = build_roads.stream_surface(self.roads, self.work, 0.05)
        self.assertEqual(first, second)


class MainSmokeTests(unittest.TestCase):
    """Сборка проходит целиком, со всеми слоями и с отчётом.

    Ни один из остальных тестов не запускает main(), и это однажды стоило
    прогона: освобождение сырья `del raw, hand` сломало печать отчёта в самом
    конце — `hand` там ещё читался. Все тесты остались зелёными, а боевая
    сборка падала на последней строке, уже написав тайлы.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def geojsonl(self, name, features):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            for feature in features:
                json.dump(feature, handle)
                handle.write("\n")
        return path

    def line(self, points, tags):
        return {"type": "Feature", "properties": tags,
                "geometry": {"type": "LineString", "coordinates": points}}

    def polygon(self, points, tags):
        return {"type": "Feature", "properties": tags,
                "geometry": {"type": "Polygon", "coordinates": [points + [points[0]]]}}

    def test_whole_build_runs_and_reports(self):
        roads = self.geojsonl("roads.geojsonl", [
            self.line([[69.25, 41.30], [69.26, 41.30]],
                      {"highway": "primary", "name": "Первая", "lanes": "4"}),
            self.line([[69.26, 41.30], [69.26, 41.31]],
                      {"highway": "residential", "name": "Вторая"}),
        ])
        areas = self.geojsonl("areas.geojsonl", [
            self.polygon([[69.255, 41.305], [69.256, 41.305], [69.256, 41.306]],
                         {"natural": "water"}),
        ])
        points = self.geojsonl("points.geojsonl", [
            {"type": "Feature", "properties": {"highway": "traffic_signals"},
             "geometry": {"type": "Point", "coordinates": [69.26, 41.30]}},
        ])
        houses = self.geojsonl("houses.geojsonl", [
            self.polygon([[69.2540, 41.3040], [69.2545, 41.3040],
                          [69.2545, 41.3045], [69.2540, 41.3045]],
                         {"building": "yes", "building:levels": "9"}),
        ])
        addresses = self.geojsonl("addresses.geojsonl", [
            {"type": "Feature",
             "properties": {"addr:street": "Первая", "addr:housenumber": "1"},
             "geometry": {"type": "Point", "coordinates": [69.2541, 41.3041]}},
        ])
        out = os.path.join(self.dir, "tiles")
        argv = ["build_roads.py", "--in", roads, "--areas", areas,
                "--points", points, "--houses", houses,
                "--addresses", addresses, "--tiles", out]
        saved, sys.argv = sys.argv, argv
        stdout, sys.stdout = sys.stdout, io.StringIO()
        try:
            build_roads.main()
            report = sys.stdout.getvalue()
        finally:
            sys.argv, sys.stdout = saved, stdout
        self.assertIn("дорог:", report)
        self.assertTrue(os.path.exists(os.path.join(out, "index_payload_v2.json")))
        written = os.listdir(out)
        for suffix in ("_s.json", "_h.json", "_d.json", "_p.json"):
            self.assertTrue(any(name.endswith(suffix) for name in written),
                            f"набор {suffix} не написан")

    def test_two_builds_with_mvt_agree_byte_for_byte(self):
        """Это ровно то, что проверяет конвейер, и на чём он останавливается.

        Недетерминированная сборка меняет байты всех тайлов каждую неделю, и
        каждый телефон перекачивает свои файлы впустую. С появлением дерева
        MVT проверка стала сравнивать ещё и его — а сортировка там своя.
        """
        roads = self.geojsonl("roads.geojsonl", [
            self.line([[69.25, 41.30], [69.26, 41.30]],
                      {"highway": "primary", "name": "Первая", "lanes": "4"}),
            self.line([[69.26, 41.30], [69.26, 41.31]],
                      {"highway": "residential", "name": "Вторая"}),
            self.line([[69.26, 41.30], [69.27, 41.29]],
                      {"highway": "secondary", "name": "Третья"}),
        ])
        houses = self.geojsonl("houses.geojsonl", [
            self.polygon([[69.2540, 41.3040], [69.2545, 41.3040],
                          [69.2545, 41.3045], [69.2540, 41.3045]],
                         {"building": "yes"}),
        ])

        def build(into):
            saved, sys.argv = sys.argv, [
                "build_roads.py", "--in", roads, "--houses", houses,
                "--mvt", "--tiles", into]
            stdout, sys.stdout = sys.stdout, io.StringIO()
            try:
                build_roads.main()
            finally:
                sys.argv, sys.stdout = saved, stdout

        first, second = os.path.join(self.dir, "a"), os.path.join(self.dir, "b")
        build(first)
        build(second)

        def snapshot(root):
            out = {}
            for folder, _dirs, names in os.walk(root):
                for name in names:
                    path = os.path.join(folder, name)
                    with open(path, "rb") as handle:
                        out[os.path.relpath(path, root)] = handle.read()
            return out

        made = snapshot(first)
        self.assertTrue(any(name.endswith(".mvt") for name in made),
                        "дерево MVT не написано")
        self.assertEqual(made, snapshot(second),
                         "две сборки одного экстракта разошлись")

    def test_build_runs_without_the_optional_layers(self):
        # Сборка обязана работать на машине, где половины экстрактов нет.
        roads = self.geojsonl("roads.geojsonl", [
            self.line([[69.25, 41.30], [69.26, 41.30]], {"highway": "primary"}),
        ])
        out = os.path.join(self.dir, "bare")
        saved, sys.argv = sys.argv, ["build_roads.py", "--in", roads,
                                     "--tiles", out, "--no-surface"]
        stdout, sys.stdout = sys.stdout, io.StringIO()
        try:
            build_roads.main()
        finally:
            sys.argv, sys.stdout = saved, stdout
        self.assertTrue(os.path.exists(os.path.join(out, "index_payload_v2.json")))
        self.assertFalse([n for n in os.listdir(out) if n.endswith("_d.json")])


class MedianTests(unittest.TestCase):
    """Разделительная — полоса земли, и только там, где она есть.

    На проспекте потоки разделены физически: газон, отбойник, бордюр. Рисовать
    там пунктир значит утверждать, что это разметка. Знаем мы это не из тегов,
    а из геометрии: две ОДНОСТОРОННИЕ ленты одной улицы навстречу друг другу.
    """

    def street(self, points, name="Проспект", oneway=True, width=11.0):
        flags = build_roads.FLAG_ONEWAY if oneway else 0
        return ((3, flags, points, name, width, True), [])

    def pair(self, gap_degrees, name="Проспект", oneway=True):
        south = [(69.25 + i * 0.002, 41.30) for i in range(6)]
        north = [(69.25 + (5 - i) * 0.002, 41.30 + gap_degrees) for i in range(6)]
        return [self.street(south, name, oneway),
                self.street(north, name, oneway)]

    def test_dual_carriageway_gets_a_median(self):
        made = build_roads.build_medians(self.pair(20 / 111_320.0))
        self.assertEqual(len(made), 1)
        kind, flags, ring = made[0]
        self.assertEqual(kind, build_roads.AREA_MEDIAN)
        self.assertTrue(flags & build_roads.AREA_FLAG_CLOSED)
        self.assertGreaterEqual(len(ring), 4)

    def test_two_way_street_gets_nothing(self):
        # Одна проезжая — разделять нечего, там честная разметка.
        self.assertEqual(build_roads.build_medians(
            self.pair(20 / 111_320.0, oneway=False)), [])

    def test_lanes_too_close_are_one_road(self):
        # Восемь метров — ширина двух полос: это разметка, а не островок.
        self.assertEqual(build_roads.build_medians(
            self.pair(4 / 111_320.0)), [])

    def test_streets_too_far_are_two_streets(self):
        self.assertEqual(build_roads.build_medians(
            self.pair(120 / 111_320.0)), [])

    def test_same_direction_is_not_a_pair(self):
        # Две попутные односторонние — это дублёр, а не встречные потоки.
        line = [(69.25 + i * 0.002, 41.30) for i in range(6)]
        beside = [(69.25 + i * 0.002, 41.30 + 20 / 111_320.0) for i in range(6)]
        self.assertEqual(build_roads.build_medians(
            [self.street(line), self.street(beside)]), [])

    def test_different_names_are_not_a_pair(self):
        pair = self.pair(20 / 111_320.0)
        other = list(pair[1][0])
        other[3] = "Другая"
        self.assertEqual(build_roads.build_medians(
            [pair[0], (tuple(other), [])]), [])

    def test_nameless_ribbons_are_skipped(self):
        pair = self.pair(20 / 111_320.0, name="")
        self.assertEqual(build_roads.build_medians(pair), [])

    def test_strip_stops_at_a_junction(self):
        """Полоса не имеет права идти сквозь перекрёсток.

        На перекрёстке встречная проезжая никуда не девается и держится на том
        же расстоянии, поэтому по одному расстоянию полоса продолжается прямо
        через узел и закрашивает асфальт тёмным. На карте это чёрная клякса
        поперёк перекрёстка — ровно то, от чего уходили, убирая швы.
        """
        pair = self.pair(20 / 111_320.0)
        middle = (69.25 + 0.004, 41.30 + 10 / 111_320.0)
        made = build_roads.build_medians(pair, junctions=[(middle, 25.0)])
        joined = build_roads.build_medians(pair)
        self.assertTrue(joined, "проверка ничего не ловит: полосы и так нет")
        for _kind, _flags, ring in made:
            for point in ring:
                self.assertGreater(
                    build_roads.meters_between(point, middle), 20.0,
                    "полоса зашла в перекрёсток")

    def test_junction_spots_take_the_widest_arm(self):
        node = (69.25, 41.30)
        arms = {build_roads._node_key(node): [
            (node, (69.26, 41.30), 20.0),
            (node, (69.24, 41.30), 8.0),
            (node, (69.25, 41.31), 8.0)]}
        spots = build_roads.junction_spots(arms)
        self.assertEqual(len(spots), 1)
        self.assertGreaterEqual(spots[0][1], 10.0, "радиус уже самой дороги")

    def test_a_plain_joint_is_not_a_junction(self):
        node = (69.25, 41.30)
        arms = {build_roads._node_key(node): [
            (node, (69.26, 41.30), 8.0), (node, (69.24, 41.30), 8.0)]}
        self.assertEqual(build_roads.junction_spots(arms), [])

    def test_record_stays_three_long(self):
        for record in build_roads.build_medians(self.pair(20 / 111_320.0)):
            self.assertEqual(len(record), 3)


class IslandTests(unittest.TestCase):
    """Островок на съезде — грань графа, слишком маленькая для квартала.

    Считать его отдельно не надо: он уже находится там же, где кварталы, и
    отбрасывается порогом площади. Граница ведётся по СОСТАВУ дорог, а не
    только по площади: дворовая петля той же площади — это двор.
    """

    def triangle(self, side_meters, cls=3):
        step = side_meters / 111_320.0
        a = (69.25, 41.30)
        b = (69.25 + step, 41.30)
        c = (69.25 + step / 2, 41.30 + step)
        return [(cls, 0, [a, b], ""), (cls, 0, [b, c], ""), (cls, 0, [c, a], "")]

    def test_small_gore_becomes_an_island(self):
        made = build_roads.build_islands(self.triangle(30))
        self.assertEqual(len(made), 1)
        self.assertEqual(made[0][0], build_roads.AREA_MEDIAN)
        self.assertTrue(made[0][1] & build_roads.AREA_FLAG_CLOSED)

    def test_a_city_block_is_not_an_island(self):
        # Квартал начинается там, где островок кончается.
        self.assertEqual(build_roads.build_islands(self.triangle(200)), [])

    def test_a_yard_loop_is_not_an_island(self):
        # Та же площадь, но дворовые проезды: это двор, и красить его
        # асфальтовым бордюром было бы враньём.
        self.assertEqual(build_roads.build_islands(self.triangle(30, cls=7)), [])

    def test_dust_is_not_an_island(self):
        self.assertEqual(build_roads.build_islands(self.triangle(3)), [])

    def test_blocks_still_come_out_as_blocks(self):
        made = build_roads.build_blocks(self.triangle(200))
        self.assertTrue(made)
        self.assertEqual(made[0][0], build_roads.AREA_BLOCK)

    def test_record_stays_three_long(self):
        for record in build_roads.build_islands(self.triangle(30)):
            self.assertEqual(len(record), 3)


class JunctionShapeTests(unittest.TestCase):
    """Перекрёсток закрыт целиком, но не заливает двор.

    Обе беды измерены, а не оценены на глаз. Дыра — непокрытая точка,
    окружённая асфальтом с трёх сторон: их было у 32 % перекрёстков, стало у
    13 %. Разлив — площадь оболочки против квадрата самой широкой дороги:
    находились кластеры в 55 раз больше ожидаемого.
    """

    def arms(self, spec):
        node = (69.25, 41.30)
        return {build_roads._node_key(node): [(node, towards, width)
                                              for towards, width in spec]}

    def test_hull_reaches_into_the_approaches(self):
        # Оболочка выпуклая, её рёбра — прямые хорды. Построенная по кромкам
        # ровно в узле, она срезает углы внутрь полотна.
        arms = self.arms([((69.26, 41.30), 14.0), ((69.24, 41.30), 14.0),
                          ((69.25, 41.31), 14.0)])
        ring = build_roads.build_junctions(arms)[0][2]
        span = max(build_roads.meters_between((69.25, 41.30), p) for p in ring)
        self.assertGreater(span, 14.0, "оболочка не зашла на подходы")

    def test_oversized_cluster_falls_apart(self):
        # Лучше шов, чем двор, залитый асфальтом.
        far = {}
        for step in range(4):
            node = (69.25 + step * 0.0003, 41.30)
            far[build_roads._node_key(node)] = [
                (node, (node[0] + 0.02, node[1]), 4.0),
                (node, (node[0] - 0.02, node[1]), 4.0),
                (node, (node[0], node[1] + 0.02), 4.0)]
        made = build_roads.build_junctions(far)
        self.assertTrue(made)
        for _kind, _flags, ring in made:
            area = abs(build_roads.signed_area_meters(ring))
            self.assertLessEqual(area, 4.0 ** 2 * build_roads.JUNCTION_MAX_AREA,
                                 "оболочка залила больше, чем перекрёсток")

    def test_straight_joint_needs_no_patch(self):
        # Обе соседние вершины смотрят НАРУЖУ от узла: у сквозной ленты угол
        # между ними ноль, а не развёрнутый. Первая версия сравнивала со 180°
        # и объявляла изломом каждый прямой стык.
        node = (69.25, 41.30)
        self.assertFalse(build_roads._seam_needs_patch(
            [(node, (69.26, 41.30), 14.0), (node, (69.24, 41.30), 14.0)]))

    def test_bent_joint_gets_a_patch(self):
        node = (69.25, 41.30)
        self.assertTrue(build_roads._seam_needs_patch(
            [(node, (69.26, 41.30), 14.0), (node, (69.25, 41.31), 14.0)]))

    def test_step_in_width_gets_a_patch(self):
        node = (69.25, 41.30)
        self.assertTrue(build_roads._seam_needs_patch(
            [(node, (69.26, 41.30), 20.0), (node, (69.24, 41.30), 7.0)]))


class OsmiumGeometryTests(unittest.TestCase):
    """Разбор обязан понимать то, что пишет НАСТОЯЩИЙ osmium.

    Замерено на боевом экстракте, 300 тысяч записей: колец из многоугольников
    38 755, замкнутых линий 37 761, линий без кольца-двойника — 2, колец без
    линии-двойника — 946. Последние и терялись целиком: это площади-отношения,
    большие парки и озёра с островами, у которых своей линии нет.

    Замкнутое кольцо приезжает ДВАЖДЫ: многоугольником и линией с совпавшими
    концами. Класть в тайл надо одно.
    """

    def feature(self, props, geometry):
        return json.dumps({"type": "Feature", "properties": props,
                           "geometry": geometry})

    def ring(self, lat, lon, size):
        return [[lon, lat], [lon + size, lat], [lon + size, lat + size],
                [lon, lat + size], [lon, lat]]

    def write(self, lines):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        handle.write("\n".join(lines))
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_multipolygon_is_a_closed_area(self):
        path = self.write([self.feature(
            {"leisure": "park"},
            {"type": "MultiPolygon", "coordinates": [[self.ring(41.3, 69.25, 0.003)]]})])
        areas = build_roads.collect_areas(path, 0)
        self.assertEqual(len(areas), 1, "площадь osmium потерялась при разборе")
        self.assertEqual(areas[0][0], build_roads.AREA_GREEN)
        self.assertEqual(areas[0][1], build_roads.AREA_FLAG_CLOSED,
                         "парк приехал контуром вместо заливки")

    def test_the_line_twin_of_an_area_is_dropped(self):
        # То же кольцо, что и выше, но вторым телом — линией.
        path = self.write([
            self.feature({"leisure": "park"},
                         {"type": "MultiPolygon",
                          "coordinates": [[self.ring(41.3, 69.25, 0.003)]]}),
            self.feature({"leisure": "park"},
                         {"type": "LineString",
                          "coordinates": self.ring(41.3, 69.25, 0.003)}),
        ])
        self.assertEqual(len(build_roads.collect_areas(path, 0)), 1,
                         "площадь легла в тайл дважды")

    def test_an_open_line_still_travels(self):
        # Арык и рельсы — настоящие линии, у них двойника нет.
        path = self.write([self.feature(
            {"waterway": "canal"},
            {"type": "LineString", "coordinates": [[69.25, 41.30], [69.26, 41.31]]})])
        areas = build_roads.collect_areas(path, 0)
        self.assertEqual(len(areas), 1)
        self.assertEqual(areas[0][1], 0, "линия приехала замкнутой")

    def test_every_ring_of_a_multipolygon_arrives(self):
        path = self.write([self.feature(
            {"natural": "water"},
            {"type": "MultiPolygon",
             "coordinates": [[self.ring(41.30, 69.25, 0.003)],
                             [self.ring(41.32, 69.28, 0.003)]]})])
        self.assertEqual(len(build_roads.collect_areas(path, 0)), 2)

    def test_a_hole_does_not_become_an_area(self):
        # Пруд внутри парка рисуется своим объектом набора воды поверх зелени;
        # в записи тайла лежит ОДНО кольцо.
        outer = self.ring(41.30, 69.25, 0.01)
        inner = self.ring(41.303, 69.253, 0.002)
        path = self.write([self.feature(
            {"leisure": "park"},
            {"type": "MultiPolygon", "coordinates": [[outer, inner]]})])
        areas = build_roads.collect_areas(path, 0)
        self.assertEqual(len(areas), 1, "дырка приехала отдельной площадью")


class PlaceSetTests(unittest.TestCase):
    """Названия населённых пунктов — свой набор, а не обстановка.

    Обстановка живёт на ближнем плане и посажена на дорогу; название города
    нужно ровно там, где дорог уже не видно. До этого набора дальний план
    оставался картой без адресов: сеть есть, а где Чирчик и где Ангрен —
    неизвестно.
    """

    def feature(self, props, geometry):
        return json.dumps({"type": "Feature", "properties": props,
                           "geometry": geometry})

    def write(self, lines):
        handle = tempfile.NamedTemporaryFile("w", suffix=".geojsonl",
                                             delete=False, encoding="utf-8")
        handle.write("\n".join(lines))
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_a_city_node_becomes_a_record_with_a_name(self):
        path = self.write([self.feature(
            {"place": "city", "name": "Toshkent"},
            {"type": "Point", "coordinates": [69.24, 41.31]})])
        places = build_roads.collect_places(path)
        self.assertEqual(len(places), 1)
        rank, flags, points, name = places[0]
        self.assertEqual(rank, 1)
        self.assertEqual(name, "Toshkent")
        self.assertEqual(points, [(69.24, 41.31)])

    def test_a_place_drawn_as_a_boundary_gets_its_middle(self):
        # Город в OSM бывает и узлом, и границей. Центр нам неизвестен,
        # середина рамки — честный ответ на «где примерно».
        ring = [[69.2, 41.3], [69.4, 41.3], [69.4, 41.4], [69.2, 41.4], [69.2, 41.3]]
        path = self.write([self.feature(
            {"place": "town", "name": "Chirchiq"},
            {"type": "MultiPolygon", "coordinates": [[ring]]})])
        places = build_roads.collect_places(path)
        self.assertEqual(len(places), 1)
        self.assertEqual(places[0][2], [(69.3, 41.35)])

    def test_a_place_without_a_name_is_not_a_place(self):
        # Подписывать нечем, а точка без подписи на схеме не нужна: там и так
        # есть дороги.
        path = self.write([self.feature(
            {"place": "village"},
            {"type": "Point", "coordinates": [69.24, 41.31]})])
        self.assertEqual(build_roads.collect_places(path), [])

    def test_unknown_kinds_are_skipped(self):
        path = self.write([self.feature(
            {"place": "ocean", "name": "Аральское"},
            {"type": "Point", "coordinates": [59.0, 45.0]})])
        self.assertEqual(build_roads.collect_places(path), [])

    def test_places_travel_in_their_own_set(self):
        road = (3, 0, [(69.25, 41.300), (69.25, 41.302)], "")
        places = [(1, 0, [(69.251, 41.301)], "Toshkent")]
        with tempfile.TemporaryDirectory() as work:
            build_roads.write_tiles([road], work, places=places)
            names = os.listdir(work)
            own = [n for n in names if n.endswith("_n.json")]
            self.assertTrue(own, "набор мест не написан")
            with open(os.path.join(work, own[0]), encoding="utf-8") as handle:
                rows = json.load(handle)["roads"]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0][0], 1, "ранг не доехал")
            self.assertEqual(rows[0][3], "Toshkent", "имя не доехало")
            self.assertLessEqual(len(rows[0]), 4,
                                 "пятый элемент убивает тайл у старых сборок")

    def test_no_places_no_file(self):
        road = (3, 0, [(69.25, 41.300), (69.25, 41.302)], "")
        with tempfile.TemporaryDirectory() as work:
            build_roads.write_tiles([road], work)
            self.assertFalse([n for n in os.listdir(work) if n.endswith("_n.json")])
