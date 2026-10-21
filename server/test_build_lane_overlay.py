#!/usr/bin/env python3
"""Слой полос (план 20.8): контракт, отказы, нормализация, детерминизм,
turn:lanes из OSM и publish_lanes.sh --check без ключа.

Главное здесь — что НЕ должно доехать до телефона: неизвестная стрелка,
девять полос, точка в Казахстане, два подхода, которые телефон не различит,
строка-образец из шаблона. Каждый такой вход обязан остановить сборку.

    cd server && python3 -W ignore -m unittest test_build_lane_overlay -v
"""
import datetime
import io
import json
import math
import os
import random
import re
import shutil
import subprocess
import tempfile
import unittest

import build_lane_overlay as blo

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE = os.path.join(HERE, "fixtures", "lanes_overlay_sample.json")
TEMPLATE = os.path.join(HERE, "lanes", "lanes_template.csv")
TODAY = datetime.date(2026, 10, 21)
# Тот же забор, что LimitsManifest.isSafeName на телефоне, и без каталога.
CLIENT_NAME = re.compile(r"^[A-Za-z0-9._-]+$")

HEADER = "id,lat,lon,bearing,tolerance,lanes,src,checked"


def row(**overrides):
    base = {"id": "t-1", "lat": "41.31102", "lon": "69.27951", "bearing": "352",
            "tolerance": "30", "lanes": "left|straight|straight;right",
            "src": "survey", "checked": "2026-10-21"}
    base.update(overrides)
    return base


def rows_of(*raws):
    return [("in.csv:%d" % (i + 2), raw) for i, raw in enumerate(raws)]


def assemble(*raws, **kwargs):
    return blo.assemble(rows_of(*raws), TODAY, **kwargs)


def offset(lat, lon, north_m=0.0, east_m=0.0):
    return (lat + north_m / blo.LAT_METERS,
            lon + east_m / (blo.LAT_METERS * math.cos(math.radians(lat))))


class ContractSampleTest(unittest.TestCase):
    def test_contract_sample_passes_and_survives_unchanged(self):
        junctions, errors, dropped = blo.assemble(blo.read_input(SAMPLE), TODAY)
        self.assertEqual(errors, [])
        self.assertEqual(dropped, [])
        sample = json.load(open(SAMPLE, encoding="utf-8"))["junctions"]
        self.assertEqual(junctions, sorted(sample, key=lambda j: j["id"]),
                         "образец контракта уже канонический — сборка не должна его менять")
        data = blo.build_data(junctions)
        self.assertEqual(blo.check_data(data, TODAY), junctions)

    def test_output_has_exactly_contract_fields(self):
        junctions, errors, _ = blo.assemble(blo.read_input(SAMPLE), TODAY)
        doc = json.loads(blo.build_data(junctions))
        self.assertEqual(sorted(doc), ["generated", "junctions", "v"])
        self.assertEqual(doc["v"], 1)
        for junction in doc["junctions"]:
            self.assertEqual(sorted(junction), sorted(blo.CSV_FIELDS))
            for lane in junction["lanes"]:
                for token in lane.split(";"):
                    self.assertIn(token, blo.VOCABULARY)

    def test_confidence_and_notes_never_reach_the_phone(self):
        junctions, errors, _ = assemble(row(confidence="0.93", note="у школы"))
        self.assertEqual(errors, [])
        self.assertNotIn(b"confidence", blo.build_data(junctions))
        self.assertNotIn("у школы".encode(), blo.build_data(junctions))


class TemplateTest(unittest.TestCase):
    def test_template_header_is_the_contract(self):
        with open(TEMPLATE, encoding="utf-8") as handle:
            self.assertEqual(handle.readline().strip(), HEADER)

    def test_template_rows_are_valid_but_refused_as_examples(self):
        rows = blo.read_input(TEMPLATE)
        self.assertEqual(len(rows), 3)
        junctions, errors, _ = blo.assemble(rows, TODAY, allow_examples=True)
        self.assertEqual(errors, [], "образцы шаблона обязаны быть верными строками")
        self.assertEqual(len(junctions), 3)
        _, errors, _ = blo.assemble(rows, TODAY)
        self.assertEqual(len(errors), 3)
        self.assertTrue(all("образец" in reason for _w, _i, reason in errors))

    def test_template_shows_osm_spelling_and_default_tolerance(self):
        junctions, _, _ = blo.assemble(blo.read_input(TEMPLATE), TODAY, allow_examples=True)
        by_id = {j["id"]: j for j in junctions}
        self.assertEqual(by_id["example-2"]["lanes"], ["uturn;left", "straight", "straight;right"])
        self.assertEqual(by_id["example-2"]["tolerance"], blo.DEFAULT_TOLERANCE)


class NormaliseTest(unittest.TestCase):
    def test_osm_tokens_become_osrm_vocabulary(self):
        cases = {"through": "straight", "slight_left": "slight left",
                 "slight_right": "slight right", "sharp_left": "sharp left",
                 "sharp_right": "sharp right", "merge_to_left": "merge to left",
                 "merge_to_right": "merge to right", "reverse": "uturn", "": "none",
                 "  Left ": "left", "slight left": "slight left", "uturn": "uturn"}
        for raw, expected in cases.items():
            self.assertEqual(blo.normalize_token(raw), expected, raw)

    def test_lane_is_deduplicated_and_ordered_left_to_right(self):
        self.assertEqual(blo.normalize_lane("through;left"), "left;straight")
        self.assertEqual(blo.normalize_lane("right;through;through"), "straight;right")
        self.assertEqual(blo.normalize_lane("left;reverse"), "uturn;left")

    def test_empty_lane_is_none_and_osm_string_parses(self):
        self.assertEqual(blo.parse_lanes("left||through;right"), ["left", "none", "straight;right"])
        self.assertEqual(blo.parse_lanes(["reverse", "through"]), ["uturn", "straight"])

    def test_same_meaning_gives_same_bytes(self):
        one, _, _ = assemble(row(lanes="through;left|through|right;through"))
        two, _, _ = assemble(row(lanes="left;straight|straight|straight;right"))
        self.assertEqual(blo.build_data(one), blo.build_data(two))

    def test_coordinates_round_to_five_digits_and_bearing_to_degree(self):
        junctions, errors, _ = assemble(row(lat="41.3110249", lon="69.2795149", bearing="351.6"))
        self.assertEqual(errors, [])
        self.assertEqual((junctions[0]["lat"], junctions[0]["lon"], junctions[0]["bearing"]),
                         (41.31102, 69.27951, 352))
        junctions, errors, _ = assemble(row(bearing="359.6"))
        self.assertEqual(junctions[0]["bearing"], 0, "359,6° — это север, а не 360")


class DefectTest(unittest.TestCase):
    """Каждый класс дефекта по контракту — отказ, с причиной и местом."""

    def refused(self, raw, fragment):
        junctions, errors, _ = assemble(raw)
        self.assertEqual(junctions, [], "дефектная строка не должна попасть в слой")
        self.assertEqual(len(errors), 1, errors)
        where, ident, reason = errors[0]
        self.assertEqual(where, "in.csv:2")
        self.assertIn(fragment, reason)

    def test_lane_count(self):
        self.refused(row(lanes=""), "lanes пусто")
        self.refused(row(lanes="|".join(["straight"] * 9)), "9 полос")
        self.refused(row(lanes="none|none"), "ни одной стрелки")

    def test_vocabulary(self):
        self.refused(row(lanes="left|forward"), "не из словаря")
        self.refused(row(lanes="none;left|straight"), "none вместе")

    def test_outside_uzbekistan(self):
        self.refused(row(lat="50.1"), "вне Узбекистана")
        self.refused(row(lon="76.9"), "вне Узбекистана")
        self.refused(row(lat="abc"), "не число")

    def test_bearing(self):
        self.refused(row(bearing="360"), "0–359")
        self.refused(row(bearing="-1"), "0–359")
        self.refused(row(bearing=""), "bearing пусто")

    def test_tolerance(self):
        self.refused(row(tolerance="46"), "5–45")
        self.refused(row(tolerance="2"), "5–45")

    def test_source_and_date(self):
        self.refused(row(src="yandex"), "src")
        self.refused(row(checked="21.10.2026"), "ГГГГ-ММ-ДД")
        self.refused(row(checked="2026-02-30"), "такой даты нет")
        self.refused(row(checked="2026-10-25"), "из будущего")

    def test_identifier(self):
        self.refused(row(id=""), "id пусто")
        self.refused(row(id="с пробелом"), "латиница")
        self.refused(row(id="example-9"), "образец")

    def test_confidence_out_of_range(self):
        self.refused(row(confidence="1.5"), "0..1")

    def test_duplicate_id_names_both_places(self):
        junctions, errors, _ = assemble(row(id="a"), row(id="a", bearing="90"))
        self.assertEqual(junctions, [])
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("in.csv:2, in.csv:3" in reason for _w, _i, reason in errors))

    def test_duplicate_approach_within_15_m_and_20_degrees(self):
        lat, lon = offset(41.31102, 69.27951, north_m=10)
        junctions, errors, _ = assemble(row(id="a", bearing="0"),
                                        row(id="b", lat=str(lat), lon=str(lon), bearing="15"))
        self.assertEqual(junctions, [])
        self.assertEqual(len(errors), 2)
        self.assertIn("дубль подхода", errors[0][2])

    def test_near_but_distinct_approaches_pass(self):
        lat, lon = offset(41.31102, 69.27951, north_m=10)
        far_lat, far_lon = offset(41.31102, 69.27951, north_m=20)
        junctions, errors, _ = assemble(
            row(id="a", bearing="0"),
            row(id="b", lat=str(lat), lon=str(lon), bearing="25"),          # курс другой
            row(id="c", lat=str(far_lat), lon=str(far_lon), bearing="0"))   # 20 м — другой подход
        self.assertEqual(errors, [])
        self.assertEqual([j["id"] for j in junctions], ["a", "b", "c"])

    def test_duplicates_across_north_wrap(self):
        lat, lon = offset(41.31102, 69.27951, east_m=5)
        _, errors, _ = assemble(row(id="a", bearing="355"),
                                row(id="b", lat=str(lat), lon=str(lon), bearing="5"))
        self.assertEqual(len(errors), 2, "355° и 5° — один курс")

    def test_geojson_non_point_and_missing_csv_column(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        path = os.path.join(tmp, "line.geojson")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"type": "FeatureCollection", "features": [{
                "type": "Feature", "properties": row(),
                "geometry": {"type": "LineString", "coordinates": [[69.2, 41.3], [69.3, 41.4]]}}]},
                handle)
        _, errors, _ = blo.assemble(blo.read_input(path), TODAY)
        self.assertIn("Point", errors[0][2])
        bad = os.path.join(tmp, "bad.csv")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write("id,lat,lon,lanes\nx,41.3,69.2,left\n")
        with self.assertRaises(ValueError) as caught:
            blo.read_input(bad)
        self.assertIn("bearing", str(caught.exception))

    def test_limits(self):
        saved = blo.MAX_JUNCTIONS
        blo.MAX_JUNCTIONS = 1
        try:
            _, errors, _ = assemble(row(id="a"), row(id="b", bearing="90"))
        finally:
            blo.MAX_JUNCTIONS = saved
        self.assertIn("больше 1", errors[-1][2])
        saved = blo.MAX_BYTES
        blo.MAX_BYTES = 100
        try:
            junctions, _, _ = assemble(row())
            with self.assertRaises(ValueError):
                blo.build_data(junctions)
        finally:
            blo.MAX_BYTES = saved

    def test_empty_overlay_is_refused(self):
        with self.assertRaises(ValueError) as caught:
            blo.build_data([])
        self.assertIn("пульт", str(caught.exception))


class MergeRulesTest(unittest.TestCase):
    def test_osm_yields_to_a_survey_row(self):
        lat, lon = offset(41.31102, 69.27951, north_m=5)
        junctions, errors, dropped = assemble(
            row(id="survey-1"), row(id="osm-w1-f", lat=str(lat), lon=str(lon), src="osm"))
        self.assertEqual(errors, [])
        self.assertEqual([j["id"] for j in junctions], ["survey-1"])
        self.assertIn("уступает", dropped[0][2])

    def test_two_osm_approaches_in_one_place_are_both_dropped(self):
        lat, lon = offset(41.31102, 69.27951, north_m=5)
        junctions, errors, dropped = assemble(
            row(id="osm-w1-f", src="osm"), row(id="osm-w2-f", lat=str(lat), lon=str(lon), src="osm"),
            row(id="survey-2", bearing="90"))
        self.assertEqual(errors, [])
        self.assertEqual([j["id"] for j in junctions], ["survey-2"])
        self.assertEqual(len(dropped), 2)

    def test_confidence_threshold(self):
        junctions, errors, dropped = assemble(
            row(id="d-1", src="dashcam", confidence="0.55"),
            row(id="d-2", src="dashcam", confidence="0.91", bearing="90"),
            row(id="s-1", bearing="180"), min_confidence=0.8)
        self.assertEqual(errors, [])
        self.assertEqual([j["id"] for j in junctions], ["d-2", "s-1"])
        self.assertIn("ниже порога", dropped[0][2])

    def test_low_confidence_row_does_not_count_as_duplicate(self):
        lat, lon = offset(41.31102, 69.27951, north_m=5)
        _, errors, _ = assemble(row(id="s-1"),
                                row(id="d-1", lat=str(lat), lon=str(lon), src="dashcam",
                                    confidence="0.3"), min_confidence=0.8)
        self.assertEqual(errors, [])

    def test_dashcam_without_confidence_under_threshold_is_a_defect(self):
        _, errors, _ = assemble(row(id="d-1", src="dashcam"), min_confidence=0.8)
        self.assertIn("без confidence", errors[0][2])


class DeterminismTest(unittest.TestCase):
    def raws(self):
        out = []
        for i in range(40):
            lat, lon = offset(41.30, 69.25, north_m=100 * i)
            out.append(row(id="j-%03d" % i, lat="%.6f" % lat, lon="%.6f" % lon,
                           bearing=str((i * 37) % 360), checked="2026-10-%02d" % (1 + i % 20)))
        return out

    def test_same_input_in_any_order_gives_same_sha_and_name(self):
        raws = self.raws()
        first, errors, _ = assemble(*raws)
        self.assertEqual(errors, [])
        shuffled = list(raws)
        random.Random(7).shuffle(shuffled)
        second, _, _ = assemble(*shuffled)
        one, two = blo.build_data(first), blo.build_data(second)
        self.assertEqual(one, two)
        self.assertEqual(blo.build_payload(one, 9), blo.build_payload(two, 9))
        name = blo.build_payload(one, 9)["files"][0]["name"]
        self.assertTrue(CLIENT_NAME.match(name))
        self.assertEqual(name, "lanes.%s.json" % blo.sha256_hex(one)[:16])

    def test_generated_is_midnight_utc_of_latest_check(self):
        junctions, _, _ = assemble(*self.raws())
        doc = json.loads(blo.build_data(junctions))
        expected = datetime.datetime(2026, 10, 20, tzinfo=datetime.timezone.utc).timestamp()
        self.assertEqual(doc["generated"], int(expected))

    def test_payload_is_canonical_and_versioned(self):
        junctions, _, _ = assemble(row())
        payload = blo.build_payload(blo.build_data(junctions), 42)
        self.assertEqual(sorted(payload), ["files", "format", "version"])
        self.assertEqual(sorted(payload["files"][0]), ["bytes", "format", "name", "sha256"])
        raw = blo.encode_payload(payload)
        self.assertEqual(raw, blo.encode_payload(json.loads(raw)))
        for bad in (0, -1, True, "3"):
            with self.assertRaises(ValueError):
                blo.build_payload(b"x", bad)


class StageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        junctions, _, _ = blo.assemble(blo.read_input(SAMPLE), TODAY)
        self.data = blo.build_data(junctions)
        self.payload = blo.build_payload(self.data, 1792560000)
        blo.write_stage(self.tmp, self.data, self.payload)
        self.name = self.payload["files"][0]["name"]

    def test_round_trip(self):
        payload, junctions = blo.verify_stage(self.tmp, TODAY)
        self.assertEqual(payload, self.payload)
        self.assertEqual(len(junctions), 3)

    def test_tampered_file_fails(self):
        path = os.path.join(self.tmp, self.name)
        with open(path, "wb") as handle:
            handle.write(self.data.replace(b'"left"', b'"right"', 1))
        with self.assertRaises(ValueError):
            blo.verify_stage(self.tmp, TODAY)

    def test_non_canonical_payload_fails(self):
        with open(os.path.join(self.tmp, "index_payload.json"), "w", encoding="utf-8") as handle:
            json.dump(self.payload, handle, indent=1)
        with self.assertRaises(ValueError):
            blo.verify_stage(self.tmp, TODAY)

    def test_check_data_rejects_what_phone_must_not_get(self):
        doc = json.loads(self.data)
        doc["junctions"][0]["lanes"] = ["left"] * 9
        with self.assertRaises(ValueError):
            blo.check_data(json.dumps(doc).encode(), TODAY)
        doc = json.loads(self.data)
        doc["junctions"][0]["extra"] = 1
        with self.assertRaises(ValueError):
            blo.check_data(json.dumps(doc).encode(), TODAY)


class ReadersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path

    def test_russian_excel_csv(self):
        """«;» как разделитель, десятичная запятая, BOM, комментарий."""
        path = self.write("ru.csv", "﻿id;lat;lon;bearing;tolerance;lanes;src;checked;note\n"
                          "# черновик;;;;;;;;\n"
                          "r-1;41,31102;69,27951;352;30;\"left|left;through|through\";survey;2026-10-21;\n")
        junctions, errors, _ = blo.assemble(blo.read_input(path), TODAY)
        self.assertEqual(errors, [])
        self.assertEqual(junctions[0]["lanes"], ["left", "left;straight", "straight"])
        self.assertEqual(junctions[0]["lat"], 41.31102)

    def test_geojson_lines_from_dashcam(self):
        feature = {"type": "Feature", "geometry": {"type": "Point", "coordinates": [69.27951, 41.31102]},
                   "properties": {"id": "cam-1", "bearing": 352, "lanes": ["left", "through"],
                                  "src": "dashcam", "checked": "2026-10-20", "confidence": 0.9}}
        path = self.write("ml.geojsonl", "\x1e" + json.dumps(feature) + "\n")
        junctions, errors, _ = blo.assemble(blo.read_input(path), TODAY, min_confidence=0.8)
        self.assertEqual(errors, [])
        self.assertEqual(junctions[0]["lanes"], ["left", "straight"])

    def test_published_file_is_an_input_for_rollback(self):
        junctions, _, _ = blo.assemble(blo.read_input(SAMPLE), TODAY)
        data = blo.build_data(junctions)
        path = os.path.join(self.tmp, blo.published_name(blo.sha256_hex(data)))
        with open(path, "wb") as handle:
            handle.write(data)
        again, errors, _ = blo.assemble(blo.read_input(path), TODAY)
        self.assertEqual(errors, [])
        self.assertEqual(blo.build_data(again), data, "откат на прошлый файл — те же байты и то же имя")


def way(way_id, coords, **tags):
    props = {"highway": "primary"}
    props.update(tags)
    return {"type": "Feature", "id": way_id, "properties": props,
            "geometry": {"type": "LineString", "coordinates": [[lon, lat] for lat, lon in coords]}}


class OsmRowsTest(unittest.TestCase):
    """Перекрёсток J: подход с юга (w1, односторонняя, turn:lanes), улица
    восток—запад сквозь J (w2), выезд на север (w3)."""

    J = (41.30000, 69.28000)

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def extract(self, *features):
        path = os.path.join(self.tmp, "roads.geojsonl")
        with open(path, "w", encoding="utf-8") as handle:
            for feature in features:
                handle.write("\x1e" + json.dumps(feature) + "\n")
        return path

    def cross(self, south_way):
        west, east = offset(*self.J, east_m=-150), offset(*self.J, east_m=150)
        north = offset(*self.J, north_m=150)
        return self.extract(south_way, way("w2", [west, self.J, east]), way("w3", [self.J, north]))

    def test_oneway_approach_at_junction(self):
        south = [offset(*self.J, north_m=-120), offset(*self.J, north_m=-30), self.J]
        path = self.cross(way("w1", south, oneway="yes", **{"turn:lanes": "left|through|through;right"}))
        rows, stats = blo.osm_rows(path, "2026-10-19")
        self.assertEqual(len(rows), 1, stats)
        approach = rows[0]
        self.assertEqual(approach["id"], "osm-w1-f")
        self.assertEqual((approach["lat"], approach["lon"]), self.J)
        self.assertIn(approach["bearing"], (0, 359, 1))
        self.assertEqual(approach["lanes"], ["left", "straight", "straight;right"])
        self.assertEqual(approach["src"], "osm")
        junctions, errors, _ = blo.assemble([("osm", r) for r in rows], TODAY)
        self.assertEqual(errors, [], "выход OSM обязан проходить ворота как есть")

    def test_backward_oneway_and_forward_backward_tags(self):
        # oneway=-1: точки с севера на юг, едут на север — подход в ПЕРВОЙ точке.
        reversed_south = [self.J, offset(*self.J, north_m=-120)]
        path = self.cross(way("w1", reversed_south, oneway="-1", **{"turn:lanes": "left|through"}))
        rows, _ = blo.osm_rows(path, "2026-10-19")
        self.assertEqual([(r["id"], r["bearing"] in (0, 359, 1)) for r in rows], [("osm-w1-b", True)])

        # Двусторонняя с :forward и :backward — по подходу на каждый конец-перекрёсток.
        a, b = offset(*self.J, north_m=-150), offset(*self.J, north_m=-300)
        path = self.extract(
            way("w1", [b, a], **{"turn:lanes:forward": "left|through", "turn:lanes:backward": "through|right"}),
            way("w4", [offset(a[0], a[1], east_m=-100), a]), way("w5", [a, offset(a[0], a[1], east_m=100)]),
            way("w6", [offset(b[0], b[1], east_m=-100), b]), way("w7", [b, offset(b[0], b[1], east_m=100)]))
        rows, _ = blo.osm_rows(path, "2026-10-19")
        by_id = {r["id"]: r for r in rows}
        self.assertEqual(sorted(by_id), ["osm-w1-b", "osm-w1-f"])
        self.assertIn(by_id["osm-w1-f"]["bearing"], (0, 359, 1))
        self.assertEqual(by_id["osm-w1-b"]["bearing"], 180)

    def test_conservative_skips(self):
        south = [offset(*self.J, north_m=-120), self.J]
        # Голый turn:lanes на двусторонней — неоднозначен.
        rows, stats = blo.osm_rows(self.cross(way("w1", south, **{"turn:lanes": "left|through"})), "2026-10-19")
        self.assertEqual(rows, [])
        self.assertEqual(stats["turn:lanes на двусторонней без :forward/:backward"], 1)
        # Конец линии посреди улицы (продолжение одной линией) — пропуск.
        middle = offset(*self.J, north_m=-60)
        path = self.extract(way("w1", [offset(*self.J, north_m=-120), middle], oneway="yes",
                                **{"turn:lanes": "left|through"}),
                            way("w9", [middle, self.J], oneway="yes"))
        rows, stats = blo.osm_rows(path, "2026-10-19")
        self.assertEqual(rows, [])
        self.assertEqual(stats["конец линии не на перекрёстке"], 1)
        # Девять полос и неизвестная стрелка — не в слой, но и не обрыв выгрузки.
        rows, stats = blo.osm_rows(self.cross(way("w1", south, oneway="yes",
                                                  **{"turn:lanes": "|".join(["through"] * 9)})), "2026-10-19")
        self.assertEqual(rows, [])
        self.assertEqual(stats["turn:lanes не разобран"], 1)
        # Пешеходная дорожка — не автодорога.
        rows, _ = blo.osm_rows(self.cross(way("w1", south, highway="footway", oneway="yes",
                                              **{"turn:lanes": "left|through"})), "2026-10-19")
        self.assertEqual(rows, [])

    def test_cli_from_osm_output_is_a_valid_input(self):
        south = [offset(*self.J, north_m=-120), self.J]
        path = self.cross(way("w1", south, oneway="yes", **{"turn:lanes": "left|through"}))
        out = os.path.join(self.tmp, "lanes_osm.json")
        buffer = io.StringIO()
        self.assertEqual(blo.main(["--from-osm", path, "--osm-out", out, "--osm-date", "2026-10-19"],
                                  out=buffer), 0)
        junctions, errors, _ = blo.assemble(blo.read_input(out), TODAY)
        self.assertEqual((errors, [j["id"] for j in junctions]), ([], ["osm-w1-f"]))


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def run_main(self, *argv):
        buffer = io.StringIO()
        code = blo.main(list(argv) + ["--today", TODAY.isoformat()], out=buffer)
        return code, buffer.getvalue()

    def test_report_counts_by_source(self):
        code, text = self.run_main(SAMPLE, "--report")
        self.assertEqual(code, 0)
        self.assertIn("подходов принято: 3", text)
        self.assertIn("osm 1, survey 1, dashcam 1", text)

    def test_defect_refuses_with_a_clear_message_and_writes_nothing(self):
        path = os.path.join(self.tmp, "bad.csv")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(HEADER + "\nb-1,41.3,69.2,90,30,left|sideways,survey,2026-10-21\n")
        stage = os.path.join(self.tmp, "stage")
        code, text = self.run_main(path, "--out-dir", stage)
        self.assertEqual(code, 1)
        self.assertIn("НЕ ПОДПИСЫВАТЬ", text)
        self.assertIn("bad.csv:2 b-1", text)
        self.assertIn("sideways", text)
        self.assertFalse(os.path.exists(stage))

    def test_build_then_verify_and_review(self):
        stage = os.path.join(self.tmp, "stage")
        review = os.path.join(self.tmp, "review.geojson")
        code, _ = self.run_main(SAMPLE, "--out-dir", stage, "--version", "7", "--review", review)
        self.assertEqual(code, 0)
        code, text = self.run_main("--verify", stage)
        self.assertEqual(code, 0, text)
        self.assertIn("версия 7", text)
        doc = json.load(open(review, encoding="utf-8"))
        self.assertEqual(len(doc["features"]), 6, "по точке и линии курса на подход")


@unittest.skipIf(os.environ.get("RADARMAP_LANES_SELFTEST"),
                 "внутри самотеста publish_lanes.sh — иначе скрипт и тест вызывали бы друг друга")
@unittest.skipUnless(shutil.which("bash"), "нет bash")
class PublishCheckTest(unittest.TestCase):
    """publish_lanes.sh --check: самотест и ворота БЕЗ ключа и БЕЗ сети.

    Ключ указывает в несуществующий файл, HOME — пустой каталог, а ssh и scp
    подменены заглушками, оставляющими след: --check не имеет права тронуть
    ни то, ни другое."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.marker = os.path.join(self.tmp, "network-touched")
        fake_bin = os.path.join(self.tmp, "bin")
        os.makedirs(fake_bin)
        for tool in ("ssh", "scp"):
            path = os.path.join(fake_bin, tool)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("#!/bin/sh\necho \"$0 $*\" >> '%s'\nexit 1\n" % self.marker)
            os.chmod(path, 0o755)
        home = os.path.join(self.tmp, "home")
        os.makedirs(home)
        self.env = dict(os.environ, HOME=home, PATH=fake_bin + os.pathsep + os.environ.get("PATH", ""),
                        RADARMAP_OTA_KEY=os.path.join(self.tmp, "no-such-key.pem"),
                        RADARMAP_HOST="nobody@invalid.invalid")

    def run_script(self, *args):
        return subprocess.run(["bash", os.path.join(HERE, "publish_lanes.sh")] + list(args),
                              env=self.env, cwd=self.tmp, capture_output=True, text=True, timeout=300)

    def test_check_passes_on_good_data_without_key_or_network(self):
        result = self.run_script("--check", "--input", SAMPLE)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--check: данные годны", result.stdout)
        self.assertRegex(result.stdout, r"[0-9a-f]{64}  lanes/lanes\.[0-9a-f]{16}\.json")
        self.assertFalse(os.path.exists(self.marker), "в --check ssh/scp не вызываются")

    def test_check_refuses_bad_data(self):
        bad = os.path.join(self.tmp, "bad.csv")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write(HEADER + "\nb-1,50.0,69.2,90,30,left,survey,2026-10-21\n")
        result = self.run_script("--check", "--input", bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("вне Узбекистана", result.stdout)
        self.assertFalse(os.path.exists(self.marker))

    def test_check_refuses_remote_osm_and_publish_needs_key(self):
        result = self.run_script("--check", "--osm", "--input", SAMPLE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--osm-input", result.stdout)
        result = self.run_script("--input", SAMPLE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("нет ключа подписи", result.stdout)
        self.assertFalse(os.path.exists(self.marker), "без ключа — ни одного обращения к серверу")


if __name__ == "__main__":
    unittest.main()
