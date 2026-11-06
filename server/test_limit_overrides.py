#!/usr/bin/env python3
"""Поправки лимитов: куда они ложатся, куда нет и когда публикация отказывает.

Большинство тестов — про то, чего быть не должно: 80 на параллельной улице или на
съезде, поправка без доказанной привязки, снижение, поднявшее настоящий знак.
80 вместо 100 звучит голосом и считает штраф.
"""
import json
import os
import tempfile
import unittest

import build_limits_index as bli
import extract_speed_limits as sl
import limit_overrides as lo

# Прямая дорога на восток по широте 41.0: 0.001° долготы ≈ 84 м.
LAT = 41.0
TRUNK = 2


def line(start_id, lat, lon_start, count, step=0.001):
    return [(start_id + i, lat, round(lon_start + i * step, 5)) for i in range(count)]


def record(way_id, nodes, ref="A373", highway="trunk", oneway="yes", limit=None):
    segment = None
    if limit is not None:
        segment = [limit, sl.road_class_code(highway),
                   [value for _id, lat, lon in nodes for value in (lat, lon)]]
    return lo.way_record(way_id, highway, sl.road_class_code(highway), oneway, ref, nodes, segment)


def carriageways(lon_start=69.0, count=61, limit=None):
    """Раздельная дорога ~5 км: восток по 41.0, запад — по параллельному полотну."""
    east = record(1, line(1000, LAT, lon_start, count), limit=limit)
    west = record(2, list(reversed(line(2000, LAT + 0.0003, lon_start, count))), limit=limit)
    return [east, west]


def override(start=None, end=None, limit=80, ident="a", refs=None, length=None, probes=None, status="verified"):
    start = start or [LAT, 69.01]
    end = end or [LAT, 69.05]
    measured = lo._meters(start[0], start[1], end[0], end[1])
    return {"id": ident, "status": status, "limit": limit, "refs": refs or ["A373"],
            "start": start, "end": end, "length_m": length or round(measured),
            "probes": probes or []}


def document(*entries):
    return {"format": lo.FORMAT, "overrides": list(entries)}


def flat_of(segments, limit=None):
    return [s for s in segments if limit is None or s[0] == limit]


def lons(segment):
    return segment[2][1::2]


def lats(segment):
    return segment[2][0::2]


class NormalizeRefTest(unittest.TestCase):
    def test_cyrillic_and_latin_are_one_road(self):
        self.assertEqual(lo.normalize_ref("А-373"), {"A373"})
        self.assertEqual(lo.normalize_ref("4Р12"), {"4P12"})
        self.assertEqual(lo.normalize_ref("4P-12"), {"4P12"})

    def test_several_refs(self):
        self.assertEqual(lo.normalize_ref("A373;D105"), {"A373", "D105"})

    def test_branch_is_another_road(self):
        # А-373а — другая дорога с другими километрами.
        self.assertFalse(lo.normalize_ref("A373a") & {"A373"})
        self.assertFalse(lo.normalize_ref("D012d") & {"D012"})

    def test_empty(self):
        self.assertEqual(lo.normalize_ref(None), set())
        self.assertEqual(lo.normalize_ref(""), set())


class OverlayTest(unittest.TestCase):
    def test_both_sides_of_a_divided_road(self):
        ways = carriageways()
        result, report = lo.apply_overrides([], ways, document(override()))
        self.assertEqual(report["applied"], ["a"])
        self.assertEqual({s[0] for s in result}, {80})
        side_lats = {round(lats(s)[0], 4) for s in result}
        self.assertEqual(side_lats, {LAT, round(LAT + 0.0003, 4)}, "обе стороны")

    def test_only_the_stretch_between_start_and_end(self):
        result, _ = lo.apply_overrides([], carriageways(), document(override()))
        all_lons = [lon for s in result for lon in lons(s)]
        self.assertAlmostEqual(min(all_lons), 69.01, places=3)
        self.assertAlmostEqual(max(all_lons), 69.05, places=3)

    def test_segment_is_created_where_no_tag_existed(self):
        result, report = lo.apply_overrides([], carriageways(), document(override()))
        self.assertTrue(result)
        self.assertEqual(report["stats"]["replaced"], 0)
        self.assertGreater(report["stats"]["created"], 0)

    def test_class_is_the_class_of_the_road(self):
        result, _ = lo.apply_overrides([], carriageways(), document(override()))
        self.assertEqual({s[1] for s in result}, {TRUNK})

    def test_tagged_way_keeps_its_old_limit_outside_the_zone(self):
        ways = carriageways(limit=100)
        segments = [w["segment"] for w in ways]
        result, report = lo.apply_overrides(segments, ways, document(override()))
        self.assertEqual(report["stats"]["replaced"], 2)
        outside = flat_of(result, 100)
        inside = flat_of(result, 80)
        self.assertTrue(outside and inside)
        for segment in inside:
            self.assertTrue(all(69.01 - 1e-4 <= lon <= 69.05 + 1e-4 for lon in lons(segment)))
        for segment in outside:
            self.assertTrue(all(lon <= 69.0101 or lon >= 69.0499 for lon in lons(segment)))
        # Начало и конец way остались при своём теге.
        covered = [lon for s in outside for lon in lons(s)]
        self.assertAlmostEqual(min(covered), 69.0, places=3)
        self.assertAlmostEqual(max(covered), 69.06, places=3)

    def test_lower_tag_is_never_raised(self):
        # Снижение до 80 не отменяет знак 60 у моста.
        ways = carriageways(limit=60)
        segments = [w["segment"] for w in ways]
        result, report = lo.apply_overrides(segments, ways, document(override()))
        self.assertEqual(flat_of(result, 80), [])
        self.assertEqual(len(flat_of(result, 60)), 2)
        self.assertGreater(report["stats"]["kept_lower_m"], 0)

    def test_same_tag_is_left_alone(self):
        ways = carriageways(limit=80)
        segments = [w["segment"] for w in ways]
        result, report = lo.apply_overrides(segments, ways, document(override()))
        self.assertEqual(result, segments)
        self.assertEqual(report["stats"]["replaced"], 0)

    def test_parallel_street_is_untouched(self):
        # Улица в тридцати метрах, параллельно и того же направления, без ref.
        ways = carriageways()
        street = record(3, line(3000, LAT - 0.0003, 69.0, 61), ref=None, highway="tertiary", limit=60)
        ways.append(street)
        result, _ = lo.apply_overrides([street["segment"]], ways, document(override()))
        self.assertIn(street["segment"], result)
        self.assertFalse([s for s in flat_of(result, 80) if lats(s)[0] == LAT - 0.0003])

    def test_parallel_street_with_tag_of_another_road_is_untouched(self):
        ways = carriageways()
        ways.append(record(3, line(3000, LAT - 0.0003, 69.0, 61), ref="A373a"))
        result, _ = lo.apply_overrides([], ways, document(override()))
        self.assertFalse([s for s in result if lats(s)[0] == LAT - 0.0003])

    def test_exit_with_the_same_ref_is_untouched(self):
        # В OSM съезд несёт ref основной дороги: A373 trunk_link.
        ways = carriageways()
        ramp_nodes = [(1020, LAT, 69.02), (4001, LAT - 0.001, 69.021), (4002, LAT - 0.002, 69.022)]
        ramp = record(4, ramp_nodes, highway="trunk_link", limit=60)
        ways.append(ramp)
        result, _ = lo.apply_overrides([ramp["segment"]], ways, document(override()))
        self.assertIn(ramp["segment"], result)
        self.assertFalse([s for s in flat_of(result, 80) if min(lats(s)) < LAT - 1e-4])

    def test_two_way_road_is_one_geometry(self):
        # Обе стороны одного way: сегмент один, а не два поверх друг друга.
        ways = [record(1, line(1000, LAT, 69.0, 61), oneway=None)]
        result, _ = lo.apply_overrides([], ways, document(override()))
        pairs = [tuple(s[2]) for s in result]
        self.assertEqual(len(pairs), len(set(pairs)))
        self.assertAlmostEqual(min(lon for s in result for lon in lons(s)), 69.01, places=3)
        self.assertAlmostEqual(max(lon for s in result for lon in lons(s)), 69.05, places=3)

    def test_long_way_is_chunked(self):
        # Длинный горный way обходился бы целиком на каждом GPS-тике.
        result, _ = lo.apply_overrides([], carriageways(), document(override()))
        self.assertTrue(all(len(s[2]) // 2 <= lo.MAX_POINTS_PER_SEGMENT for s in result))
        east = sorted((s for s in result if lats(s)[0] == LAT), key=lambda s: lons(s)[0])
        for first, second in zip(east, east[1:]):
            self.assertEqual(lons(first)[-1], lons(second)[0], "стык без щели")


class NotAppliedTest(unittest.TestCase):
    def assert_failed(self, ways, entry, needle):
        result, report = lo.apply_overrides([], ways, document(entry))
        self.assertEqual(result, [])
        self.assertEqual(report["applied"], [])
        self.assertIn(needle, report["failed"][entry["id"]])

    def test_unverified_is_never_applied(self):
        entry = {"id": "u", "status": "unverified", "why": "нет привязки"}
        result, report = lo.apply_overrides([], carriageways(), document(entry))
        self.assertEqual(result, [])
        self.assertEqual(report["failed"], {})
        self.assertEqual(report["applied"], [])

    def test_anchor_far_from_the_road(self):
        self.assert_failed(carriageways(), override(start=[LAT + 0.01, 69.01], length=3300), "дальше")

    def test_broken_chain_of_refs(self):
        # Половина дороги потеряла ref: без неё не доказать, что это тот участок.
        nodes = line(1000, LAT, 69.0, 61)
        ways = [record(1, nodes[:25]), record(2, nodes[24:40], ref=None), record(3, nodes[39:]),
                record(4, list(reversed(line(2000, LAT + 0.0003, 69.0, 61))))]
        self.assert_failed(ways, override(), "разорвана")

    def test_gap_in_one_direction_means_nothing_at_all(self):
        # Полотно в одну сторону не нашли — не применяем и другое: половина
        # поправки выглядела бы как ошибка приложения.
        east = record(1, line(1000, LAT, 69.0, 61))
        west_a = record(2, list(reversed(line(2000, LAT + 0.0003, 69.0, 20))))
        west_b = record(3, list(reversed(line(2500, LAT + 0.0003, 69.03, 31))))
        result, report = lo.apply_overrides([], [east, west_a, west_b], document(override()))
        self.assertEqual(result, [])
        self.assertIn("a", report["failed"])

    def test_length_disagrees_with_the_recorded_one(self):
        self.assert_failed(carriageways(), override(length=9000), "длина")

    def test_conflict_with_another_override(self):
        first = override(ident="first")
        second = override(ident="second", limit=70, start=[LAT, 69.03], end=[LAT, 69.055])
        result, report = lo.apply_overrides([], carriageways(), document(first, second))
        self.assertEqual(report["applied"], ["first"])
        self.assertIn("second", report["failed"])
        self.assertEqual({s[0] for s in result}, {80})


class IdempotentTest(unittest.TestCase):
    def test_input_is_not_mutated(self):
        ways = carriageways(limit=100)
        segments = [w["segment"] for w in ways]
        before = json.dumps(segments)
        lo.apply_overrides(segments, ways, document(override()))
        self.assertEqual(json.dumps(segments), before)

    def test_same_input_same_bytes(self):
        ways = carriageways(limit=100)
        segments = [w["segment"] for w in ways]
        first, _ = lo.apply_overrides(segments, ways, document(override()))
        second, _ = lo.apply_overrides(segments, ways, document(override()))
        self.assertEqual(json.dumps(first), json.dumps(second))

    def test_applied_twice_is_the_same_file(self):
        ways = carriageways()
        once, _ = lo.apply_overrides([], ways, document(override()))
        twice, _ = lo.apply_overrides(once, ways, document(override()))
        self.assertEqual(json.dumps(once), json.dumps(twice))

    def test_order_of_overrides_does_not_change_the_fingerprint(self):
        a, b = override(ident="a"), override(ident="b", start=[LAT, 69.02], end=[LAT, 69.04])
        self.assertEqual(lo.fingerprint(document(a, b)), lo.fingerprint(document(b, a)))

    def test_fingerprint_follows_the_result_not_the_prose(self):
        base = override()
        described = dict(base, source={"url": "x"})
        moved = dict(base, end=[LAT, 69.06])
        self.assertEqual(lo.fingerprint(document(base)), lo.fingerprint(document(described)))
        self.assertNotEqual(lo.fingerprint(document(base)), lo.fingerprint(document(moved)))
        self.assertEqual(lo.fingerprint(document(dict(override(), status="verified"))),
                         lo.fingerprint(document(override(), {"id": "u", "status": "unverified"})))


class ValidateTest(unittest.TestCase):
    def test_short_piece_is_refused(self):
        # Кусок короче километра — 100→80→100 за полминуты.
        with self.assertRaisesRegex(ValueError, "короче"):
            lo.validate(document(override(length=400)))

    def test_bad_limit_is_refused(self):
        with self.assertRaisesRegex(ValueError, "лимит"):
            lo.validate(document(override(limit=5)))
        with self.assertRaisesRegex(ValueError, "лимит"):
            lo.validate(document(override(limit="80")))

    def test_duplicate_id_is_refused(self):
        with self.assertRaisesRegex(ValueError, "повтор"):
            lo.validate(document(override(), override()))

    def test_unverified_needs_no_geometry(self):
        lo.validate(document({"id": "u", "status": "unverified"}))

    def test_foreign_format_is_refused(self):
        with self.assertRaisesRegex(ValueError, "формат"):
            lo.validate({"format": 99, "overrides": []})


class ShippedFileTest(unittest.TestCase):
    """Сам limit_overrides.json из репозитория: то, что уедет на сервер."""

    def setUp(self):
        self.doc = lo.load()

    def test_every_verified_has_source_km_and_probes(self):
        entries = lo.verified(self.doc)
        self.assertTrue(entries)
        for entry in entries:
            self.assertTrue(entry["source"]["url"].startswith("https://"), entry["id"])
            self.assertRegex(entry["source"]["date"], r"^\d{4}-\d{2}-\d{2}$")
            self.assertEqual(len(entry["km"]), 2)
            self.assertTrue(entry["proof"])
            self.assertGreaterEqual(entry["length_m"], lo.MIN_APPLIED_METERS)
            self.assertGreaterEqual(len(entry["probes"]), 4)

    def test_unverified_says_why(self):
        rest = [entry for entry in self.doc["overrides"] if entry["status"] != lo.VERIFIED]
        self.assertTrue(rest)
        for entry in rest:
            self.assertEqual(entry["status"], "unverified", entry["id"])
            self.assertTrue(entry["why"], entry["id"])

    def test_truck_limit_is_only_a_note(self):
        # Тип машины нам неизвестен: 50 для грузовиков не должно попасть в лимит.
        for entry in lo.verified(self.doc):
            self.assertNotEqual(entry["limit"], entry.get("limit_hgv_info"))
            self.assertEqual(entry["limit"], 80)

    def test_applied_zone_stays_inside_the_official_range(self):
        for entry in lo.verified(self.doc):
            self.assertGreaterEqual(entry["applied_km"][0], entry["km"][0], entry["id"])
            self.assertLessEqual(entry["applied_km"][1], entry["km"][1], entry["id"])


def built(segments, mark):
    doc = {"version": 1_790_000_000, "format": 2, "segments": segments}
    if mark is not None:
        doc["limit_overrides"] = mark
    return doc


class GateTest(unittest.TestCase):
    def setUp(self):
        self.ways = carriageways()
        probes = lo.measure(self.ways, override())["probes"]
        self.doc = document(override(probes=probes))
        self.segments, report = lo.apply_overrides([], self.ways, self.doc)
        self.mark = {"sha": report["sha"], "applied": report["applied"], "failed": report["failed"]}

    def test_applied_passes(self):
        lo.check_built(built(self.segments, self.mark), self.doc)

    def test_no_verified_overrides_needs_nothing(self):
        lo.check_built(built([], None), document({"id": "u", "status": "unverified"}))

    def test_file_from_old_code_is_refused(self):
        with self.assertRaisesRegex(ValueError, "нет отметки"):
            lo.check_built(built(self.segments, None), self.doc)

    def test_other_set_on_the_server_is_refused(self):
        with self.assertRaisesRegex(ValueError, "другим набором"):
            lo.check_built(built(self.segments, dict(self.mark, sha="0" * 16)), self.doc)

    def test_override_failed_on_the_server_is_refused(self):
        mark = dict(self.mark, applied=[], failed={"a": "цепочка ref разорвана"})
        with self.assertRaisesRegex(ValueError, "цепочка ref разорвана"):
            lo.check_built(built([], mark), self.doc)

    def test_mark_without_geometry_is_refused(self):
        # Отметка говорит «применено», а сегментов нет: файл правили руками.
        with self.assertRaisesRegex(ValueError, "нет сегмента"):
            lo.check_built(built([], self.mark), self.doc)

    def test_higher_limit_at_a_probe_is_refused(self):
        spoiled = [[100, s[1], s[2]] for s in self.segments]
        with self.assertRaisesRegex(ValueError, "лимит 100 вместо 80"):
            lo.check_built(built(spoiled, self.mark), self.doc)

    def test_override_without_probes_is_refused(self):
        doc = document(override())
        mark = dict(self.mark, sha=lo.fingerprint(doc))
        with self.assertRaisesRegex(ValueError, "без проб"):
            lo.check_built(built(self.segments, mark), doc)

    def test_lower_tag_at_every_probe_is_refused(self):
        # Единичный тег ниже — норма, но весь участок ниже — не наша поправка.
        lowered = [[60, s[1], s[2]] for s in self.segments]
        with self.assertRaisesRegex(ValueError, "только у"):
            lo.check_built(built(lowered, self.mark), self.doc)

    def files(self, mark):
        version = 1_790_000_000
        padded = [[60, 3, [41.3 + i * 1e-3, 69.2, 41.301 + i * 1e-3, 69.201]] for i in range(3)]
        segments = self.segments + padded
        extra = {"limit_overrides": mark} if mark else {}
        legacy = [[limit, flat] for limit, _cls, flat in segments]
        return {1: json.dumps(dict({"version": version, "segments": legacy}, **extra)).encode(),
                2: json.dumps(dict({"version": version, "format": 2, "segments": segments}, **extra)).encode()}

    def test_build_payload_refuses(self):
        with self.assertRaisesRegex(ValueError, "нет отметки"):
            bli.build_payload(self.files(None), min_segments=3, overrides=self.doc)

    def test_build_payload_passes(self):
        payload = bli.build_payload(self.files(self.mark), min_segments=3, overrides=self.doc)
        self.assertEqual(payload["format"], bli.INDEX_FORMAT)

    def test_v1_and_v2_with_different_marks_are_refused(self):
        files = self.files(self.mark)
        other = self.files(dict(self.mark, sha="0" * 16))
        with self.assertRaisesRegex(ValueError, "разной отметкой"):
            bli.build_payload({1: other[1], 2: files[2]}, min_segments=3, overrides=self.doc)

    def test_v2_is_required_for_the_check(self):
        with self.assertRaisesRegex(ValueError, "формата 2"):
            bli.build_payload({1: self.files(self.mark)[1]}, min_segments=3, overrides=self.doc)

    def test_main_refuses_and_writes_nothing(self):
        padded = [[60, 3, [41.3 + i * 1e-3, 69.2, 41.301 + i * 1e-3, 69.201]]
                  for i in range(sl.MIN_SEGMENTS)]
        version = 1_790_000_000
        with tempfile.TemporaryDirectory() as work:
            paths = {}
            payloads = {1: {"version": version, "segments": [[s[0], s[2]] for s in padded]},
                        2: {"version": version, "format": 2, "segments": padded}}
            for fmt, doc in payloads.items():
                paths[fmt] = os.path.join(work, "in_%d.json" % fmt)
                with open(paths[fmt], "w", encoding="utf-8") as handle:
                    json.dump(doc, handle)
            overrides = os.path.join(work, "limit_overrides.json")
            with open(overrides, "w", encoding="utf-8") as handle:
                json.dump(self.doc, handle)
            out = os.path.join(work, "stage")
            code = bli.main(["--v1", paths[1], "--v2", paths[2], "--out", out, "--overrides", overrides])
            self.assertEqual(code, 1)
            self.assertFalse(os.path.exists(os.path.join(out, "index_payload.json")))

    def test_main_refuses_when_the_overrides_file_is_missing(self):
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "v2.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"version": 1, "format": 2, "segments": []}, handle)
            code = bli.main(["--v2", path, "--out", os.path.join(work, "stage"),
                             "--overrides", os.path.join(work, "нет.json")])
            self.assertEqual(code, 1)


class ExtractWiringTest(unittest.TestCase):
    def test_broken_file_does_not_stop_the_cron(self):
        # Лимиты для старых сборок должны обновиться и без поправок.
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            handle.write("{битый")
            path = handle.name
        try:
            self.assertIsNone(sl.load_overrides(path))
        finally:
            os.unlink(path)
        self.assertIsNone(sl.load_overrides("/nonexistent/limit_overrides.json"))

    def test_mark_goes_with_the_segments(self):
        ways = carriageways()
        result, mark = sl.overlay_overrides([], ways, document(override()))
        self.assertTrue(result)
        self.assertEqual(mark["applied"], ["a"])
        self.assertEqual(mark["sha"], lo.fingerprint(document(override())))
        self.assertEqual(sorted(mark), ["applied", "failed", "sha"])

    def test_failed_override_is_written_to_the_mark(self):
        result, mark = sl.overlay_overrides([], carriageways(), document(override(length=9000)))
        self.assertEqual(result, [])
        self.assertIn("a", mark["failed"])


if __name__ == "__main__":
    unittest.main()
