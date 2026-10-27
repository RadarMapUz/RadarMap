#!/usr/bin/env python3
"""Тесты 33D — события водителей в файле скоростей (traffic_speeds.py,
--reports-db): подтверждённая отметка и нет, истечение, пересечение с живой
пробкой (берётся меньшая скорость), направление. reports.db — настоящая
схема api.init_db(); OSRM подменён (рёбра отметки задаёт тест).
Запуск: python3 server/test_traffic_events.py
"""
import io
import json
import os
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout

import api
import traffic_build as tb
import traffic_config as tc
import traffic_speeds as ts

NOW = 1_792_954_800 + 18 * 3600      # понедельник 26.10.2026 18:00 Ташкент
POINT = (41.3111, 69.2797)


class FakeOsrm:
    """Рёбра по курсу: север — (1, 2), юг — (2, 1); остальные стороны — пусто."""

    def __init__(self):
        self.calls = []

    def __call__(self, lat, lon, rtype, course):
        self.calls.append((rtype, course))
        out = {}
        for bearing, _tol in ts.event_bearings(rtype, course):
            if bearing in (0, 0.0) or abs(bearing - 0) < 1:
                out[(1, 2)] = (50.0, 30.0)
            elif abs(bearing - 180) < 1:
                out[(2, 1)] = (50.0, 30.0)
        return out


class EventsTest(unittest.TestCase):

    def setUp(self):
        self.reports = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        api.DB_PATH = self.reports.name
        api.init_db()
        self.traffic = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        conn = sqlite3.connect(self.traffic.name)
        tb.schema(conn)
        conn.close()
        self.dir = tempfile.mkdtemp()
        self.osrm = FakeOsrm()

    def tearDown(self):
        for path in (self.reports.name, self.traffic.name):
            os.unlink(path)
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def mark(self, rtype, course=-1.0, confirmers=1, created=NOW - 600, expires=NOW + 3600, active=1):
        conn = sqlite3.connect(self.reports.name)
        cur = conn.execute("INSERT INTO reports(lat, lon, created, expires, device, type, course, ip, active) "
                           "VALUES(?, ?, ?, ?, 'author', ?, ?, '10.0.0.1', ?)",
                           (POINT[0], POINT[1], created, expires, rtype, course, active))
        rid = cur.lastrowid
        for k in range(confirmers):
            conn.execute("INSERT INTO votes(report_id, device, value, ip) VALUES(?, ?, 1, ?)",
                         (rid, f"other{k}", f"10.0.1.{k}"))
        # Самоподтверждение: тот же адрес, новый UUID — не в счёт.
        conn.execute("INSERT INTO votes(report_id, device, value, ip) VALUES(?, 'rotated', 1, '10.0.0.1')", (rid,))
        conn.commit()
        conn.close()
        return rid

    def run_main(self, now=NOW):
        out = io.StringIO()
        speeds = os.path.join(self.dir, "speeds.csv")
        with redirect_stdout(out):
            code = ts.main(["--db", self.traffic.name, "--out", speeds, "--source", "route",
                            "--reports-db", self.reports.name, "--events-cache",
                            os.path.join(self.dir, "events.json"), "--now", str(now)], resolver=self.osrm)
        self.assertEqual(code, 0, out.getvalue())
        rows = {}
        with open(speeds, encoding="ascii") as f:
            for line in f:
                u, v, model, rate = line.strip().split(",")
                rows[(int(u), int(v))] = round(float(rate) * 3.6)
        return rows, out.getvalue()

    def test_confirmed_accident_slows_both_sides(self):
        self.mark("accident", course=0.0)
        rows, log = self.run_main()
        self.assertEqual(rows, {(1, 2): 30, (2, 1): 30}, "ДТП — 0,6 графа в обе стороны")
        self.assertIn("событий 1", log)

    def test_unconfirmed_mark_changes_nothing(self):
        self.mark("accident", course=0.0, confirmers=0)
        self.assertEqual(self.run_main()[0], {}, "неподтверждённая — только показ")
        self.assertEqual(self.osrm.calls, [])

    def test_closure_needs_two_independent_confirmers(self):
        self.mark("closure", course=0.0, confirmers=1)
        self.assertEqual(self.run_main()[0], {})
        self.mark("closure", course=0.0, confirmers=2)
        self.assertEqual(self.run_main()[0], {(1, 2): tc.CLOSURE_KMH}, "перекрытие — 5 км/ч по курсу")

    def test_closure_without_course_blocks_both_ways(self):
        self.mark("closure", course=-1.0, confirmers=2)
        self.assertEqual(self.run_main()[0], {(1, 2): 5, (2, 1): 5})

    def test_expired_and_old_marks_drop_out(self):
        self.mark("accident", course=0.0, expires=NOW - 1)
        self.mark("accident", course=0.0, created=NOW - tc.EVENT_MAX_AGE - 60, expires=NOW + 3600)
        self.mark("accident", course=0.0, active=0)
        self.assertEqual(self.run_main()[0], {}, "истекла, старше 2 ч или снята — граф")

    def test_live_jam_and_event_take_the_slower(self):
        conn = sqlite3.connect(self.traffic.name)
        conn.execute("INSERT INTO traffic_edges VALUES(1, 2, 50)")
        for piece in range(3):
            conn.execute("INSERT INTO traffic_samples(u, v, kmh, weight, ts, piece, passed) "
                         "VALUES(1, 2, 12, 100, ?, ?, 1)", (NOW, piece))
        conn.commit()
        conn.close()
        self.mark("accident", course=0.0)
        rows, _ = self.run_main()
        self.assertEqual(rows[(1, 2)], 12, "живая пробка медленнее ДТП — берётся она")
        self.assertEqual(rows[(2, 1)], 30)

    def test_route_is_resolved_once_per_mark(self):
        rid = self.mark("accident", course=0.0)
        self.run_main()
        self.run_main()
        self.assertEqual(len(self.osrm.calls), 1, "путь отметки — один раз, из кэша дальше")
        with open(os.path.join(self.dir, "events.json"), encoding="utf-8") as f:
            cache = json.load(f)
        self.assertEqual(list(cache), [str(rid)])
        for word in ("device", "ip", "author"):
            self.assertNotIn(word, json.dumps(cache))

    def test_osrm_failure_means_no_penalty_this_cycle(self):
        self.mark("accident", course=0.0)

        def broken(*_args):
            raise OSError("стенд перезапускается")
        out = io.StringIO()
        speeds = os.path.join(self.dir, "speeds.csv")
        with redirect_stdout(out), redirect_stdout(io.StringIO()):
            import contextlib
            with contextlib.redirect_stderr(io.StringIO()):
                code = ts.main(["--db", self.traffic.name, "--out", speeds, "--source", "route",
                                "--reports-db", self.reports.name, "--now", str(NOW)], resolver=broken)
        self.assertEqual(code, 0)
        with open(speeds) as f:
            self.assertEqual(f.read(), "")

    def test_route_answer_too_long_is_not_our_road(self):
        body = {"code": "Ok", "routes": [{"distance": 400, "legs": [{"annotation": {
            "nodes": [1, 2], "distance": [400], "duration": [30]}}]}]}
        self.assertEqual(ts.event_edges_from_route(body), {}, "путь в 400 м на 60 м отметки — развязка")
        body["routes"][0]["distance"] = 60
        body["routes"][0]["legs"][0]["annotation"]["distance"] = [60]
        self.assertEqual(ts.event_edges_from_route(body), {(1, 2): (60 / 30 * 3.6, 60)})

    def test_bearings_follow_the_rules(self):
        self.assertEqual(ts.event_bearings("closure", 90.0), [(90.0, 30)])
        self.assertEqual(ts.event_bearings("accident", 90.0), [(90.0, 30), (270.0, 30)])
        self.assertEqual(len(ts.event_bearings("accident", -1)), 4)

    def test_layer_switch(self):
        self.mark("accident", course=0.0)
        old = tc.LAYER_EVENTS
        tc.LAYER_EVENTS = False
        try:
            self.assertEqual(self.run_main()[0], {})
        finally:
            tc.LAYER_EVENTS = old


if __name__ == "__main__":
    unittest.main()
