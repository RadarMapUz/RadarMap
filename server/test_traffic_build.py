#!/usr/bin/env python3
"""Тесты сборщика пробок. Запуск: python3 server/test_traffic_build.py

Ответ OSRM — настоящий, снятый с прод-сервера на условном следе по Амира
Темура (fixtures/osrm_match_amir_temur.json): в середине следа «пробка» —
три шага по 40 с вместо 8.
"""
import json
import math
import os
import sqlite3
import tempfile
import unittest

import traffic_build as tb

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = json.load(open(os.path.join(HERE, "fixtures", "osrm_match_amir_temur.json"), encoding="utf-8"))


def meters(a, b):
    lat = math.radians((a[0] + b[0]) / 2)
    return math.hypot((a[0] - b[0]) * 111_320, (a[1] - b[1]) * 111_320 * math.cos(lat))


class EdgesFromMatchTest(unittest.TestCase):
    def setUp(self):
        self.points = FIXTURE["points"]
        self.samples, self.nodes, self.models = tb.edges_from_match(FIXTURE["response"], self.points)

    def test_samples_are_osm_edges_with_sane_speeds(self):
        self.assertGreater(len(self.samples), 10)
        for u, v, kmh, weight in self.samples:
            self.assertIsInstance(u, int)
            self.assertIsInstance(v, int)
            self.assertNotEqual(u, v)
            self.assertTrue(0 <= kmh <= tb.MAX_KMH)
            self.assertGreater(weight, 0)

    def test_jam_part_of_the_trace_is_slower(self):
        speeds = sorted({round(kmh) for _, _, kmh, _ in self.samples})
        self.assertLess(speeds[0], 15, "шаги по 40 с — это ползком")
        self.assertGreater(speeds[-1], 30, "шаги по 8 с — это ход")

    def test_node_coordinates_lie_on_the_trace(self):
        """Выравнивание геометрии: узел обязан быть рядом со следом, иначе
        участки дороги на карте окажутся не там."""
        self.assertGreater(len(self.nodes), 5)
        for lat, lon in self.nodes.values():
            nearest = min(meters((lat, lon), (p[0], p[1])) for p in self.points)
            self.assertLess(nearest, 120)

    def test_graph_speed_is_known_for_edges(self):
        self.assertTrue(self.models)
        for kmh in self.models.values():
            self.assertTrue(5 < kmh < 130)

    def test_low_confidence_and_errors_give_nothing(self):
        self.assertEqual(tb.edges_from_match({"code": "NoMatch"}, self.points), ([], {}, {}))
        weak = json.loads(json.dumps(FIXTURE["response"]))
        weak["matchings"][0]["confidence"] = 0.01
        self.assertEqual(tb.edges_from_match(weak, self.points)[0], [])


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.conn = sqlite3.connect(self.tmp.name)
        tb.schema(self.conn)
        self.now = 1_760_000_000.0

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)

    def add_piece(self, received=None):
        self.conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                          (received or self.now, json.dumps(FIXTURE["points"])))
        self.conn.commit()

    def test_matched_piece_is_deleted_at_once(self):
        self.add_piece()
        done, segments = tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        self.assertEqual(done, 1)
        self.assertGreater(segments, 0)
        left = self.conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0]
        self.assertEqual(left, 0, "сырой след не хранится после сопоставления")

    def test_unmatched_piece_waits_but_not_forever(self):
        self.add_piece()

        def down(points):
            raise OSError("connection refused")

        tb.process(self.conn, self.now, matcher=down)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0], 1)
        tb.prune(self.conn, self.now + tb.PIECE_TTL + 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0], 0)

    def test_one_piece_is_not_enough_to_publish(self):
        self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        self.assertEqual(tb.aggregate(self.conn, self.now), [],
                         "один водитель у обочины пробку не рисует")

    def test_two_pieces_publish_edges_with_levels(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        edges = tb.aggregate(self.conn, self.now)
        self.assertTrue(edges)
        self.assertEqual({e[4] for e in edges} - {1, 2, 3}, set())
        self.assertIn(3, {e[4] for e in edges}, "ползком на проспекте — пробка")

    def test_prune_clears_old_repeat_marks(self):
        # Таблицу создаёт api.py; старого api.py без неё cron не роняет.
        tb.prune(self.conn, self.now)
        self.conn.execute("CREATE TABLE traffic_seen(hash TEXT PRIMARY KEY, received REAL NOT NULL)")
        self.conn.execute("INSERT INTO traffic_seen VALUES('old', ?), ('new', ?)",
                          (self.now - tb.SEEN_TTL - 1, self.now))
        tb.prune(self.conn, self.now)
        left = [r[0] for r in self.conn.execute("SELECT hash FROM traffic_seen")]
        self.assertEqual(left, ["new"])

    def test_old_samples_leave_the_window(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        self.assertEqual(tb.aggregate(self.conn, self.now + tb.SAMPLE_WINDOW + 1), [])
        tb.prune(self.conn, self.now + tb.SAMPLE_KEEP + 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_samples").fetchone()[0], 0)

    def test_profile_accumulates_by_hour_of_week(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        hows = {row[0] for row in self.conn.execute("SELECT DISTINCT how FROM traffic_profile")}
        self.assertEqual(hows, {tb.hour_of_week(self.now)})

    def test_payload_carries_nothing_but_edges(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        body = tb.payload(tb.aggregate(self.conn, self.now), self.now)
        self.assertEqual(set(body), {"v", "generated", "edges"})
        for edge in body["edges"]:
            self.assertEqual(len(edge), 7)
            self.assertTrue(all(isinstance(x, (int, float)) for x in edge))


class PureTest(unittest.TestCase):
    def test_levels(self):
        self.assertEqual(tb.level(10, 60), 3)
        self.assertEqual(tb.level(30, 60), 2)
        self.assertEqual(tb.level(50, 60), 1)
        self.assertIsNone(tb.level(50, 0))

    def test_weighted_median(self):
        self.assertEqual(tb.weighted_median([(10, 1), (50, 1), (60, 5)]), 60)
        self.assertEqual(tb.weighted_median([(10, 3), (50, 1)]), 10)
        self.assertIsNone(tb.weighted_median([]))

    def test_hour_of_week_is_tashkent_local(self):
        # 2026-10-12 03:30 UTC — понедельник 08:30 в Ташкенте.
        self.assertEqual(tb.hour_of_week(1_791_775_800), 8)


if __name__ == "__main__":
    unittest.main()
