#!/usr/bin/env python3
"""Тесты 33B — задержки манёвров и светофоров (traffic_build.turns_from_match,
traffic_profile.turn_penalties, файл --turn-penalty-file в traffic_speeds.py).
Случаи — по docs/spec_traffic_33.md: классификация угла, вычисление
задержки, порог по дням, обрезка 180 с, формат строки, детерминизм.

Фикстура fixtures/osrm_match_left_turn.json — настоящий ответ OSRM `match`
(steps=true) стенда MLD 127.0.0.1:8094 на синтетический след: 36 км/ч,
стоим 40 с в 12 м до левого поворота на Yangishahar ko‘chasi. Стенд собран
тем же образом v26.7.3 и профилем car_radarmap.lua из той же выгрузки OSM,
что прод, — узлы OSM и геометрия те же; прод 8092 по правилам этапа не
опрашивается.
Запуск: python3 server/test_turn_delays.py
"""
import io
import json
import os
import re
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

import traffic_build as tb
import traffic_config as tc
import traffic_profile as tp
import traffic_speeds as ts

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "fixtures", "osrm_match_left_turn.json"), encoding="utf-8") as f:
    FIXTURE = json.load(f)
LEFT = (4545270448, 4568983062, 7851505433)          # тройка левого поворота фикстуры
STOP = range(21, 28)                                 # точки стояния (t = 54…84; 20 — подъезд, 49 с)
LINE = re.compile(r"^\d+,\d+,\d+,\d+$")


def points(wait=40):
    """След фикстуры со стоянием `wait` секунд вместо 40."""
    out = []
    for i, (lat, lon, t, kmh) in enumerate(FIXTURE["points"]):
        if i in STOP:
            t = 49 + min(t - 49, max(0, wait - 2) * (t - 49) / 40)
        elif i >= 28:
            t = t - 40 + max(2, wait)
        out.append([lat, lon, t, kmh])
    return out


def left_delay(pts):
    for u, v, w, delay, angle in tb.turns_from_match(FIXTURE["response"], pts):
        if (u, v, w) == LEFT:
            return delay, angle
    return None


class ManeuverTest(unittest.TestCase):

    def test_angle_classes(self):
        self.assertEqual(tb.maneuver(0), "straight")
        self.assertEqual(tb.maneuver(29.9), "straight")
        self.assertEqual(tb.maneuver(-29.9), "straight")
        self.assertEqual(tb.maneuver(45), "right")
        self.assertEqual(tb.maneuver(-87.5), "left")
        self.assertEqual(tb.maneuver(150.1), "uturn")
        self.assertEqual(tb.maneuver(-175), "uturn")
        self.assertEqual(tb.maneuver(150), "right", "ровно 150° — ещё поворот")

    def test_turn_angle_sign_is_right_positive(self):
        north, centre, east, west = (41.0, 69.0), (41.001, 69.0), (41.001, 69.001), (41.001, 68.999)
        self.assertAlmostEqual(tb.turn_angle(north, centre, east), 90, delta=1)
        self.assertAlmostEqual(tb.turn_angle(north, centre, west), -90, delta=1)

    def test_profile_ceiling_is_an_upper_bound(self):
        # прямо: светофор 8 с + сигмоида ~0; налево: + налево с главной 15 с;
        # разворот: + 20 с.
        self.assertAlmostEqual(tb.profile_turn_ceiling(0), 8.0, delta=0.1)
        self.assertGreater(tb.profile_turn_ceiling(-90), 15 + 2)
        self.assertGreater(tb.profile_turn_ceiling(-175), tb.profile_turn_ceiling(-90) + 19)


class DelayTest(unittest.TestCase):

    def test_left_turn_waits_forty_seconds(self):
        delay, angle = left_delay(points(40))
        self.assertEqual(tb.maneuver(angle), "left")
        self.assertAlmostEqual(delay, 40, delta=3, msg="стояли 40 с — задержка ~40 с")

    def test_no_wait_no_delay(self):
        delay, _ = left_delay(points(0))
        self.assertLess(delay, 5, "проехали на зелёный — задержки нет")

    def test_one_maneuver_per_crossing(self):
        turns = tb.turns_from_match(FIXTURE["response"], points(40))
        vias = [via for _, via, _, _, _ in turns]
        self.assertEqual(len(vias), len(set(vias)))
        # Узел в 20 м за левым поворотом (разделительная) — тот же перекрёсток.
        self.assertNotIn(7851505433, vias, "второй узел в 19 м — тот же перекрёсток")
        others = [delay for u, v, w, delay, _ in turns if (u, v, w) != LEFT]
        self.assertTrue(others and max(others) < 5, "прямо через свободные узлы — без задержки")

    def test_long_stop_is_clipped_to_180(self):
        delay, _ = left_delay(points(400))
        self.assertEqual(delay, tc.TURN_MAX_DELAY)

    def test_piece_ending_at_the_node_is_not_counted(self):
        with mock.patch.object(tb, "PIECE_END_GUARD", 600):
            self.assertIsNone(left_delay(points(40)), "окно у конца куска — не манёвр")

    def test_without_steps_there_are_no_crossings(self):
        bare = json.loads(json.dumps(FIXTURE["response"]))
        for matching in bare["matchings"]:
            for leg in matching["legs"]:
                leg.pop("steps", None)
        self.assertEqual(tb.turns_from_match(bare, points(40)), [], "узел с одной парой рёбер — пропуск")


class AggregateTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.conn = sqlite3.connect(self.tmp.name)
        tb.schema(self.conn)
        self.now = 1_792_954_800 + 18 * 3600       # понедельник 26.10.2026 18:00
        self.out = tempfile.mkdtemp()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)
        for name in os.listdir(self.out):
            os.unlink(os.path.join(self.out, name))
        os.rmdir(self.out)

    def observe(self, days, per_day=1, wait=40, shared=True):
        """Кусок фикстуры `per_day` раз в каждый из `days` понедельников —
        через настоящий process/store."""
        pts = points(wait)
        for week in range(days):
            at = self.now - week * 7 * 86400
            for _ in range(per_day):
                self.conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                                  (at, json.dumps(pts)))
            self.conn.commit()
            tb.process(self.conn, at, matcher=lambda p: FIXTURE["response"])
        if shared:
            for u, v in ((LEFT[0], LEFT[1]), (LEFT[1], LEFT[2])):
                self.conn.execute("INSERT OR REPLACE INTO traffic_shared(u, v, seen) VALUES(?, ?, ?)",
                                  (u, v, self.now))
        self.conn.commit()

    def test_needs_five_pieces_on_three_days(self):
        self.observe(days=2, per_day=3)
        self.assertEqual(tp.turn_penalties(self.conn, self.now), [], "6 кусков за 2 дня — не годен")
        self.observe(days=3, per_day=1)
        penalties = tp.turn_penalties(self.conn, self.now)
        self.assertEqual([row[:3] for row in penalties], [LEFT], "3 дня, ≥ 5 кусков — годен")
        self.assertAlmostEqual(penalties[0][3], 40, delta=3)

    def test_small_delay_is_not_written(self):
        self.observe(days=5, wait=20)          # 20 с — не больше профиля (~20) + 5
        self.assertEqual(tp.turn_penalties(self.conn, self.now), [])

    def test_other_hour_and_one_driver_give_nothing(self):
        self.observe(days=5)
        self.assertEqual(tp.turn_penalties(self.conn, self.now + 3600), [], "другой слот часа")
        self.conn.execute("DELETE FROM traffic_shared")
        self.conn.commit()
        self.assertEqual(tp.turn_penalties(self.conn, self.now), [], "манёвр одного человека — нет")

    def test_median_resists_one_long_stop(self):
        self.observe(days=5)
        self.observe(days=1, wait=400)
        self.assertAlmostEqual(tp.turn_penalties(self.conn, self.now)[0][3], 40, delta=3)

    def run_main(self):
        out = io.StringIO()
        speeds, turns = os.path.join(self.out, "speeds.csv"), os.path.join(self.out, "turns.csv")
        with redirect_stdout(out):
            code = ts.main(["--db", self.tmp.name, "--out", speeds, "--turns-out", turns,
                            "--source", "route", "--now", str(self.now)])
        with open(turns, "rb") as f:
            return code, f.read(), out.getvalue()

    def test_file_format_and_determinism(self):
        self.observe(days=5)
        code, body, log = self.run_main()
        self.assertEqual(code, 0)
        lines = body.decode("ascii").splitlines()
        self.assertEqual(len(lines), 1)
        self.assertRegex(lines[0], LINE, "from_osm,via_osm,to_osm,penalty_s — целые")
        self.assertTrue(lines[0].startswith("%d,%d,%d," % LEFT))
        self.assertIn("манёвров 1", log)
        for word in ("lat", "lon", "piece", "device", "day", "."):
            self.assertNotIn(word, body.decode())
        os.unlink(os.path.join(self.out, "turns.csv"))
        self.assertEqual(self.run_main()[1], body, "тот же вход — те же байты")

    def test_layer_switch_turns_off(self):
        self.observe(days=5)
        self.assertEqual(tp.turn_penalties(self.conn, self.now, enabled=False), [])

    def test_cap_keeps_the_biggest_excess(self):
        rows = [(1, 2, 3, 60, 40.0), (4, 5, 6, 30, 10.0), (7, 8, 9, 90, 70.0)]
        kept, trimmed = ts.cap_turns(rows, limit=2)
        self.assertEqual(trimmed, 1)
        self.assertEqual([row[:3] for row in kept], [(1, 2, 3), (7, 8, 9)])


if __name__ == "__main__":
    unittest.main()
