#!/usr/bin/env python3
"""Тесты файла скоростей для osrm-customize (traffic_speeds.py).
Запуск: python3 server/test_traffic_speeds.py

Образец — тот же настоящий ответ прод-OSRM по Амира Темура, что у сборщика
пробок (fixtures/osrm_match_amir_temur.json): куски кладутся в traffic.db
сборщиком, файл скоростей читает их тем же правилом публикации.
"""
import io
import os
import re
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

import test_traffic_build as fixture
import traffic_build as tb
import traffic_speeds as ts

LINE = re.compile(r"^(\d+),(\d+),(\d+)$")
WEIGHT_LINE = re.compile(r"^(\d+),(\d+),(\d+\.\d),(\d+\.\d{3})$")


def parse(body):
    """Режим duration: (u, v, км/ч)."""
    rows = []
    for line in body.splitlines():
        match = LINE.match(line)
        assert match, f"строка не в формате OSRM: {line!r}"
        rows.append(tuple(int(x) for x in match.groups()))
    return rows


def parse_weight(body):
    """Режим weight: (u, v, км/ч графа, rate м/с)."""
    rows = []
    for line in body.splitlines():
        match = WEIGHT_LINE.match(line)
        assert match, f"строка не в формате OSRM (speed,rate): {line!r}"
        u, v, speed, rate = match.groups()
        rows.append((int(u), int(v), float(speed), float(rate)))
    return rows


class SpeedFileTest(fixture.ProfileFixture, unittest.TestCase):

    def test_empty_database_gives_an_empty_file(self):
        self.assertEqual(ts.csv_body(ts.speeds(self.conn, self.now, "auto")), "",
                         "пусто — честно «пробок нет»: customize вернёт скорости car.lua")

    def test_one_piece_writes_nothing(self):
        self.pieces(1, shared=False, slower=4)
        self.assertEqual(ts.speeds(self.conn, self.now, "now"), {}, "одна машина — не пробка и для графа")

    def test_now_is_only_slow_confirmed_edges(self):
        self.pieces(2, slower=4)
        live = ts.speeds(self.conn, self.now, "now")
        self.assertTrue(live)
        published = {(row[0], row[1]): row for row in tb.live_edges(self.conn, self.now)}
        for edge, (kmh, model) in live.items():
            self.assertIn(edge, published, "только рёбра now.json")
            self.assertGreaterEqual(published[edge][6], 2, "свободный поток в граф не пишется")
            self.assertEqual(kmh, max(ts.SPEED_FLOOR_KMH, published[edge][7]))
            self.assertEqual(model, published[edge][8])
        free = {edge for edge, row in published.items() if row[6] == 1}
        self.assertFalse(free & set(live))

    def test_free_flow_writes_nothing(self):
        self.pieces(2)       # след фикстуры: ход и короткая «пробка» посередине
        live = ts.speeds(self.conn, self.now, "now")
        levels = {(row[0], row[1]): row[6] for row in tb.live_edges(self.conn, self.now)}
        self.assertTrue(all(levels[edge] >= 2 for edge in live))
        self.assertLess(len(live), len(levels), "свободные рёбра отброшены")

    def test_format_is_osrm_csv_sorted_and_never_zero(self):
        self.pieces(2, slower=40)       # почти стоим — темп упирается в пол
        body = ts.csv_body(ts.speeds(self.conn, self.now, "now"), "duration")
        rows = parse(body)
        self.assertTrue(rows)
        self.assertEqual(rows, sorted(rows))
        self.assertEqual(len({(u, v) for u, v, _ in rows}), len(rows), "одна строка на направленное ребро")
        for u, v, kmh in rows:
            self.assertNotEqual(u, v)
            self.assertGreaterEqual(kmh, ts.SPEED_FLOOR_KMH, "0 для OSRM — «ребро закрыто»")
        for word in ("lat", "lon", "piece", "device", "."):
            self.assertNotIn(word, body)

    def test_typical_keeps_only_edges_slower_than_the_graph(self):
        self.pieces(tb.TYPICAL_MIN_PIECES, slower=4)
        typical = ts.speeds(self.conn, self.now, "typical")
        self.assertTrue(typical)
        rows = {(r[1], r[2]): r for r in tb.typical_rows(self.conn, self.now)}
        for edge, (kmh, model) in typical.items():
            self.assertLess(kmh, rows[edge][8] * tb.SLOW_RATIO)
            self.assertEqual(model, rows[edge][8])

    def test_typical_without_graph_speed_writes_nothing(self):
        self.pieces(tb.TYPICAL_MIN_PIECES, slower=4)
        self.conn.execute("DELETE FROM traffic_edges")
        self.conn.commit()
        self.assertEqual(ts.speeds(self.conn, self.now, "typical"), {}, "сравнивать не с чем — не пишем")

    def test_typical_of_another_hour_is_empty(self):
        self.pieces(tb.TYPICAL_MIN_PIECES, slower=4)
        other = "off-03" if self.bucket() != "off-03" else "wd-03"
        self.assertEqual(ts.speeds(self.conn, self.now, "typical", bucket=other), {})

    def test_auto_prefers_live_over_typical(self):
        self.pieces(tb.TYPICAL_MIN_PIECES, slower=4)
        typical = ts.speeds(self.conn, self.now, "typical")
        # Через час живых нет (окно 15 мин), обычное — осталось.
        later = self.now + tb.SAMPLE_WINDOW + 60
        self.assertEqual(ts.speeds(self.conn, later, "now"), {})
        self.assertEqual(ts.speeds(self.conn, later, "auto"),
                         ts.speeds(self.conn, later, "typical"))
        # Сейчас живые есть — на общих рёбрах берётся живое.
        self.pieces(2, slower=8)
        merged = ts.speeds(self.conn, self.now, "auto")
        live = ts.speeds(self.conn, self.now, "now")
        for edge, value in live.items():
            self.assertEqual(merged[edge], value)
        self.assertTrue(set(typical) <= set(merged) | set(live))

    def test_never_faster_than_the_graph_and_never_below_the_floor(self):
        self.assertEqual(ts.bounded(30, 60), 30)
        self.assertEqual(ts.bounded(1, 60), ts.SPEED_FLOOR_KMH, "стояние у светофора — пол, не 1 км/ч")
        self.assertEqual(ts.bounded(80, 60), 60, "быстрее графа файл ребро не делает")
        self.assertEqual(ts.bounded(2, 4), 4, "пол не поднимает ребро выше его скорости графа")
        self.assertIsNone(ts.bounded(10, 0), "без скорости графа — не пишем")
        self.assertIsNone(ts.bounded(10, None))

    def test_rounding_never_lifts_an_edge_above_the_graph(self):
        edges = {(1, 2): (60.4, 60.4), (3, 4): (4.6, 4.6), (5, 6): (12.2, 50.0)}
        self.assertEqual(parse(ts.csv_body(edges, "duration")), [(1, 2, 60), (3, 4, 4), (5, 6, 12)])
        weight = parse_weight(ts.csv_body(edges, "weight"))
        for (_u, _v, speed, rate), (kmh, model) in zip(weight, edges.values()):
            self.assertEqual(speed, round(model, 1), "время в пути — скорость графа")
            self.assertLessEqual(rate * 3.6, model + 0.01, "вес не легче графа")

    def test_weight_mode_keeps_graph_time_and_puts_the_jam_into_the_rate(self):
        self.pieces(2, slower=4)
        live = ts.speeds(self.conn, self.now, "now")
        rows = parse_weight(ts.csv_body(live, "weight"))
        self.assertEqual(len(rows), len(live))
        for u, v, speed, rate in rows:
            kmh, model = live[(u, v)]
            self.assertAlmostEqual(speed, model, delta=0.05, msg="duration по графу: телефон сам прибавит пробку")
            self.assertAlmostEqual(rate, round(kmh) / 3.6, places=3, msg="rate — м/с пробки, как forward_rate в car.lua")
            self.assertLess(rate * 3.6, speed, "пробка медленнее графа")
            self.assertGreaterEqual(rate * 3.6, ts.SPEED_FLOOR_KMH - 0.01)
        for word in ("lat", "lon", "piece", "device"):
            self.assertNotIn(word, ts.csv_body(live, "weight"))

    def test_duration_mode_is_the_plain_osrm_format(self):
        self.pieces(2, slower=4)
        live = ts.speeds(self.conn, self.now, "now")
        rows = parse(ts.csv_body(live, "duration"))
        self.assertEqual({(u, v): kmh for u, v, kmh in rows},
                         {edge: int(round(kmh)) for edge, (kmh, _m) in live.items()})

    def test_bad_mode_is_refused(self):
        with self.assertRaises(ValueError):
            ts.csv_body({}, "guess")

    def test_bad_source_is_refused(self):
        with self.assertRaises(ValueError):
            ts.speeds(self.conn, self.now, "guess")


class MainTest(fixture.ProfileFixture, unittest.TestCase):
    """Запуск как у cron: база только на чтение, неизменный файл не трогается."""

    def run_main(self, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = ts.main(["--db", self.tmp.name, "--out", self.path, "--now", str(self.now), *args])
        return code, out.getvalue()

    def setUp(self):
        super().setUp()
        self.path = os.path.join(tempfile.mkdtemp(), "osrm", "speeds.csv")

    def tearDown(self):
        super().tearDown()
        if os.path.exists(self.path):
            os.unlink(self.path)

    def test_writes_then_reports_unchanged(self):
        self.pieces(2, slower=4)
        self.conn.commit()
        code, text = self.run_main("--source", "now")
        self.assertEqual(code, 0)
        self.assertIn("записано", text)
        with open(self.path, encoding="ascii") as f:
            self.assertTrue(parse_weight(f.read()), "по умолчанию — режим weight")
        before = os.stat(self.path).st_mtime_ns
        code, text = self.run_main("--source", "now")
        self.assertIn("без изменений", text)
        self.assertEqual(os.stat(self.path).st_mtime_ns, before)

    def test_unknown_bucket_is_refused(self):
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            ts.main(["--db", self.tmp.name, "--out", self.path, "--bucket", "wd-25"])

    def test_database_is_opened_read_only(self):
        self.pieces(2, slower=4)
        self.conn.commit()
        os.chmod(self.tmp.name, 0o444)
        try:
            code, _ = self.run_main("--source", "auto")
        finally:
            os.chmod(self.tmp.name, 0o644)
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
