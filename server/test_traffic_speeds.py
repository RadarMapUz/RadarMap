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


def parse(body):
    rows = []
    for line in body.splitlines():
        match = LINE.match(line)
        assert match, f"строка не в формате OSRM: {line!r}"
        rows.append(tuple(int(x) for x in match.groups()))
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
        for edge, kmh in live.items():
            self.assertIn(edge, published, "только рёбра now.json")
            self.assertGreaterEqual(published[edge][6], 2, "свободный поток в граф не пишется")
            self.assertEqual(kmh, published[edge][7])
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
        body = ts.csv_body(ts.speeds(self.conn, self.now, "now"))
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
        for edge, kmh in typical.items():
            self.assertLess(kmh, rows[edge][8] * tb.SLOW_RATIO)

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
        for edge, kmh in live.items():
            self.assertEqual(merged[edge], kmh)
        self.assertTrue(set(typical) <= set(merged) | set(live))

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
            self.assertTrue(parse(f.read()))
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
