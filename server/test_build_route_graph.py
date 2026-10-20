#!/usr/bin/env python3
"""Граф трасс для маршрута без сети: топология, односторонность, индекс.

Главное здесь — то, что телефон строит граф ПО СОВПАДЕНИЮ КООРДИНАТ: узел
перекрёстка, потерянный при упрощении или сдвинутый квантованием на метр,
разрывает трассу, и маршрут молча говорит «пути нет». Поэтому большинство
тестов — про то, что общие точки линий доезжают до файла одинаковыми.

    cd server && python3 -W ignore -m unittest test_build_route_graph -v
"""
import hashlib
import json
import os
import re
import shutil
import tempfile
import unittest

import build_roads
import build_route_graph as brg

# Тот же забор, что LimitsManifest.isSafeName на телефоне.
CLIENT_NAME = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")

# Ворота для крошечных синтетических наборов.
SMALL = {"min_bytes": 1, "max_bytes": brg.MAX_BYTES, "min_ways": 1}


def feature(highway, coordinates, **tags):
    properties = {"highway": highway}
    properties.update(tags)
    return {"type": "Feature", "properties": properties,
            "geometry": {"type": "LineString", "coordinates": coordinates}}


def decode(flat):
    """Эталонный декодер — то же делает RoadTiles.decodeEntries: целые 1e-5°."""
    lat, lon = flat[0], flat[1]
    points = [(lat, lon)]
    for i in range(2, len(flat), 2):
        lat += flat[i]
        lon += flat[i + 1]
        points.append((lat, lon))
    return points


def wiggly(lon0, lon1, lat, count, amplitude=1e-6):
    """Почти прямая с мелким шумом — Дуглас—Пекер выбросит середину."""
    step = (lon1 - lon0) / (count - 1)
    return [[lon0 + i * step, lat + (amplitude if i % 2 else 0.0)] for i in range(count)]


class Extract:
    """Синтетический geojsonl во временном каталоге — с байтом 0x1E, как у osmium."""

    def __init__(self, features):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "roads.geojsonl")
        with open(self.path, "w", encoding="utf-8") as handle:
            for item in features:
                handle.write("\x1e" + json.dumps(item) + "\n")
            handle.write("\x1e{битая строка\n")

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def build(features):
    extract = Extract(features)
    try:
        ways, stats = brg.read_ways(extract.path)
    finally:
        extract.close()
    doc, _ = brg.build_graph(ways)
    return doc, stats


def nodes_of(doc):
    return [decode(entry[2]) for entry in doc["roads"]]


class ClassFilterTest(unittest.TestCase):
    def test_only_codes_one_to_four(self):
        line = [[69.20, 41.30], [69.21, 41.30]]
        doc, _ = build([feature(highway, line) for highway in (
            "motorway", "motorway_link", "trunk", "trunk_link", "primary",
            "primary_link", "secondary", "secondary_link", "tertiary",
            "residential", "service", "footway", "unclassified")])
        self.assertEqual(sorted(entry[0] for entry in doc["roads"]),
                         [1, 1, 2, 2, 3, 3, 4, 4])

    def test_codes_match_build_roads(self):
        for highway, code in brg.ROUTE_CLASSES.items():
            self.assertEqual(build_roads.CLASS_CODES[highway], code)
        self.assertNotIn("tertiary", brg.ROUTE_CLASSES)

    def test_broken_line_and_non_lines_skipped(self):
        polygon = {"type": "Feature", "properties": {"highway": "primary"},
                   "geometry": {"type": "Polygon", "coordinates": [[[69.2, 41.3]]]}}
        single = feature("primary", [[69.2, 41.3]])
        same = feature("primary", [[69.2, 41.3], [69.2000001, 41.3000001]])
        doc, stats = build([polygon, single, same])
        self.assertEqual(doc["roads"], [])
        self.assertEqual(stats["skipped"], 1)

    def test_document_shape_is_tile_v1(self):
        doc, _ = build([feature("trunk", [[69.2, 41.3], [69.3, 41.4]], name="М-39")])
        self.assertEqual(sorted(doc), ["roads", "version"])
        self.assertEqual(doc["version"], 1)
        # Без имени: запись из трёх полей, как принимает decodeTile.
        self.assertEqual(len(doc["roads"][0]), 3)


class OnewayTest(unittest.TestCase):
    A, B, C = [69.20, 41.30], [69.21, 41.31], [69.22, 41.30]

    def only(self, **tags):
        doc, _ = build([feature(tags.pop("highway", "primary"), [self.A, self.B, self.C], **tags)])
        self.assertEqual(len(doc["roads"]), 1)
        code, flags, flat = doc["roads"][0]
        return flags, decode(flat)

    def test_two_way_has_no_flag(self):
        flags, points = self.only()
        self.assertEqual(flags, 0)
        self.assertEqual(points[0], (4130000, 6920000))

    def test_oneway_yes_keeps_order(self):
        flags, points = self.only(oneway="yes")
        self.assertEqual(flags, brg.FLAG_ONEWAY)
        self.assertEqual(points[0], (4130000, 6920000))
        self.assertEqual(points[-1], (4130000, 6922000))

    def test_oneway_minus_one_is_reversed(self):
        # Телефон знает только «по ходу точек»: -1 обязан приехать развёрнутым.
        flags, points = self.only(oneway="-1")
        self.assertEqual(flags, brg.FLAG_ONEWAY)
        self.assertEqual(points[0], (4130000, 6922000))
        self.assertEqual(points[-1], (4130000, 6920000))

    def test_implied_oneway_motorway_and_roundabout(self):
        flags, _ = self.only(highway="motorway")
        self.assertEqual(flags, brg.FLAG_ONEWAY)
        flags, _ = self.only(highway="motorway", oneway="no")
        self.assertEqual(flags, 0)
        flags, _ = self.only(junction="roundabout")
        self.assertEqual(flags, brg.FLAG_ONEWAY | brg.FLAG_RING)

    def test_closed_loop_without_junction_tag_is_not_a_ring(self):
        # Телефон ведёт по кольцу по ходу точек — двусторонняя петля с флагом
        # кольца потеряла бы встречное направление.
        doc, _ = build([feature("primary", [self.A, self.B, self.C, self.A])])
        self.assertEqual(doc["roads"][0][1], 0)

    def test_reversible_dropped(self):
        doc, stats = build([feature("primary", [self.A, self.B], oneway="reversible")])
        self.assertEqual(doc["roads"], [])
        self.assertEqual(stats["reversible"], 1)


class JunctionTest(unittest.TestCase):
    """Две трассы крест-накрест, общий узел в середине обеих, вокруг — шум."""

    CROSS = [69.25, 41.30]

    def crossing(self):
        east = wiggly(69.20, 69.25, 41.30, 26)[:-1] + [self.CROSS] \
            + wiggly(69.25, 69.30, 41.30, 26)[1:]
        north = [[69.25, 41.25 + i * 0.002 + (1e-6 if i % 2 else 0)] for i in range(25)] \
            + [self.CROSS] \
            + [[69.25 + (1e-6 if i % 2 else 0), 41.30 + i * 0.002] for i in range(1, 26)]
        return [feature("trunk", east), feature("primary", north)]

    def test_shared_point_survives_simplification_identically(self):
        doc, _ = build(self.crossing())
        east, north = nodes_of(doc)
        cross = (4130000, 6925000)
        self.assertIn(cross, east)
        self.assertIn(cross, north)
        # Упрощение работало: от 51 точки остались концы и узел.
        self.assertEqual(east, [(4130000, 6920000), cross, (4130000, 6930000)])
        self.assertLess(len(north), 10)

    def test_without_anchor_simplify_would_drop_it(self):
        # Контрольный опыт: тот же build_roads.simplify на целой линии узел
        # стирает — значит, держит его именно разрезка по узлам.
        east = self.crossing()[0]["geometry"]["coordinates"]
        simple = build_roads.simplify([tuple(p) for p in east], brg.tolerance_degrees())
        self.assertNotIn(tuple(self.CROSS), simple)

    def test_quantization_merges_before_junction_search(self):
        # Узел в двух линиях записан с разным «хвостом» float — после 1e-5°
        # это одна точка, и в файле обязан быть один и тот же узел.
        one = [[69.20, 41.30], [69.2500000001, 41.3000000004], [69.30, 41.30]]
        two = [[69.25, 41.25], [69.2499999999, 41.2999999996], [69.25, 41.35]]
        doc, _ = build([feature("trunk", one), feature("trunk", two)])
        first, second = nodes_of(doc)
        self.assertEqual(first[1], (4130000, 6925000))
        self.assertEqual(second[1], (4130000, 6925000))

    def test_t_junction_end_on_the_middle_of_another(self):
        main = wiggly(69.20, 69.30, 41.30, 41)
        branch = [main[20], [69.25, 41.35]]
        doc, _ = build([feature("trunk", main), feature("secondary", branch)])
        trunk, side = nodes_of(doc)
        self.assertIn(side[0], trunk)

    def test_endpoints_always_kept(self):
        line = wiggly(69.20, 69.30, 41.30, 30)
        doc, _ = build([feature("primary", line)])
        points = nodes_of(doc)[0]
        self.assertEqual(points[0], (4130000, 6920000))
        self.assertEqual(points[-1], (4130000, 6930000))

    def test_no_zero_length_steps(self):
        # Туда-обратно: после квантования и упрощения нулевых шагов нет.
        line = [[69.2, 41.3], [69.2, 41.3], [69.20000001, 41.30000001],
                [69.21, 41.3], [69.2100001, 41.3], [69.2, 41.3]]
        doc, _ = build([feature("primary", line)])
        flat = doc["roads"][0][2]
        steps = list(zip(flat[2::2], flat[3::2]))
        self.assertNotIn((0, 0), steps)


class EncodingTest(unittest.TestCase):
    def test_round_trip_exact_integers(self):
        points = [(4130123, 6925456), (4130200, 6925400), (4129000, 6926000)]
        self.assertEqual(decode(brg.encoded(points)), points)

    def test_same_as_build_roads_encode(self):
        points = [(4130123, 6925456), (4130200, 6925400)]
        floats = [(lon / 1e5, lat / 1e5) for lat, lon in points]
        self.assertEqual(brg.encoded(points), build_roads.encode(floats))

    def test_file_is_compact_and_deterministic(self):
        doc, _ = build(JunctionTest().crossing())
        data = brg.encode_graph(doc)
        self.assertNotIn(b" ", data)
        self.assertEqual(json.loads(data), doc)
        again, _ = build(JunctionTest().crossing())
        self.assertEqual(brg.encode_graph(again), data)


class IndexTest(unittest.TestCase):
    def setUp(self):
        doc, _ = build(JunctionTest().crossing())
        self.data = brg.encode_graph(doc)
        self.payload = brg.build_payload(self.data, 20_381)
        self.stage = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.stage, ignore_errors=True)

    def test_schema_is_the_client_contract(self):
        # RouteGraphManifest: format, version, files[format, name, sha256, bytes].
        self.assertEqual(sorted(self.payload), ["files", "format", "version"])
        self.assertEqual(self.payload["format"], 1)
        self.assertEqual(self.payload["version"], 20_381)
        (entry,) = self.payload["files"]
        self.assertEqual(sorted(entry), ["bytes", "format", "name", "sha256"])
        self.assertEqual(entry["format"], 1)
        self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(entry["name"], CLIENT_NAME)

    def test_sha_and_size_of_the_exact_bytes(self):
        entry = self.payload["files"][0]
        self.assertEqual(entry["sha256"], hashlib.sha256(self.data).hexdigest())
        self.assertEqual(entry["bytes"], len(self.data))

    def test_name_is_content_addressed(self):
        entry = self.payload["files"][0]
        # Без каталога: телефон сам кладёт его в routes/ и чистит по префиксу.
        self.assertEqual(entry["name"], "route_graph.%s.json" % entry["sha256"][:16])
        other = brg.build_payload(self.data + b" ", 20_381)
        self.assertNotEqual(other["files"][0]["name"], entry["name"])

    def test_stage_files_match_index(self):
        brg.write_stage(self.stage, self.data, self.payload)
        entry = self.payload["files"][0]
        with open(os.path.join(self.stage, entry["name"]), "rb") as handle:
            written = handle.read()
        self.assertEqual(hashlib.sha256(written).hexdigest(), entry["sha256"])
        self.assertEqual(len(written), entry["bytes"])
        with open(os.path.join(self.stage, "index_payload.json"), "rb") as handle:
            raw = handle.read()
        self.assertEqual(json.loads(raw), self.payload)
        self.assertEqual(raw, brg.encode_payload(self.payload))
        payload, ways = brg.verify_stage(self.stage, **SMALL)
        self.assertEqual(payload, self.payload)
        self.assertEqual(ways, 2)

    def test_verify_rejects_tampered_file(self):
        brg.write_stage(self.stage, self.data, self.payload)
        name = os.path.join(self.stage, self.payload["files"][0]["name"])
        with open(name, "wb") as handle:
            handle.write(self.data.replace(b"[2,", b"[3,", 1))
        with self.assertRaises(ValueError):
            brg.verify_stage(self.stage, **SMALL)

    def test_bad_version_refused(self):
        for version in (0, -1, True, "1"):
            with self.assertRaises(ValueError):
                brg.build_payload(self.data, version)


class GateTest(unittest.TestCase):
    def setUp(self):
        doc, _ = build(JunctionTest().crossing())
        self.data = brg.encode_graph(doc)

    def test_small_set_passes_with_small_gates(self):
        self.assertEqual(brg.check_graph(self.data, **SMALL), 2)

    def test_truncated_extract_refused(self):
        with self.assertRaises(ValueError):
            brg.check_graph(self.data)   # боевые ворота: слишком мало

    def test_bad_entries_refused(self):
        for doc in ({"version": 2, "roads": []},
                    {"version": 1, "roads": [[5, 0, [1, 2, 3, 4]]]},
                    {"version": 1, "roads": [[1, 2, [1, 2, 3, 4]]]},
                    {"version": 1, "roads": [[1, 0, [1, 2, 3]]]},
                    {"version": 1, "roads": [[1, 0, [1, 2, 3, 4], "имя"]]}):
            with self.assertRaises(ValueError):
                brg.check_graph(json.dumps(doc).encode(), **SMALL)

    def test_size_cap_below_client_cap(self):
        # AppConfig.offlineGraphMaxBytes = 16 000 000: файл больше телефон отвергнет.
        self.assertLess(brg.MAX_BYTES, 16_000_000)


class CliTest(unittest.TestCase):
    def test_main_writes_stage(self):
        extract = Extract(JunctionTest().crossing())
        out = tempfile.mkdtemp()
        try:
            gates = (brg.MIN_BYTES, brg.MIN_WAYS)
            brg.MIN_BYTES, brg.MIN_WAYS = 1, 1
            try:
                code = brg.main(["--input", extract.path, "--out-dir", out, "--version", "7"])
                self.assertEqual(code, 0)
                payload, _ = brg.verify_stage(out, **SMALL)
                self.assertEqual(payload["version"], 7)
                self.assertEqual(brg.main(["--verify", out]), 0)
            finally:
                brg.MIN_BYTES, brg.MIN_WAYS = gates
            # С боевыми воротами тот же каталог не проходит.
            self.assertEqual(brg.main(["--verify", out]), 1)
        finally:
            extract.close()
            shutil.rmtree(out, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
