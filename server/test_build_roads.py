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
import tempfile
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
        geometry = {"type": shape,
                    "coordinates": [coords] if shape == "Polygon" else coords}
        return json.dumps({"type": "Feature", "properties": props,
                           "geometry": geometry})

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


if __name__ == "__main__":
    unittest.main()
