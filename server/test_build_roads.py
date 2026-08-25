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


if __name__ == "__main__":
    unittest.main()
