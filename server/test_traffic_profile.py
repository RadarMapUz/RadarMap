#!/usr/bin/env python3
"""Тесты 33A — типичные пробки по профилю часа недели и живые поверх
(traffic_profile.py, источник route в traffic_speeds.py). Случаи — по
docs/spec_traffic_33.md: сжатие при n = 1/3/30, медиана против выброса,
переход слотов по минутам, 167 → 0, затухание живого, смесь, гистерезис
1,9 / 2,1 км/ч, инвариант 6 на краях, детерминизм, греп приватности.
Запуск: python3 server/test_traffic_profile.py
"""
import calendar
import io
import os
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout

import traffic_build as tb
import traffic_config as tc
import traffic_profile as tp
import traffic_speeds as ts

# Понедельник 26.10.2026 00:00 по Ташкенту (UTC+5) — обычный будний день.
MONDAY = calendar.timegm((2026, 10, 25, 19, 0, 0))
GRAPH = 50.0


def at(day, hour, minute=0):
    """Момент: день недели (0 — понедельник), час и минута по Ташкенту."""
    return MONDAY + day * 86400 + hour * 3600 + minute * 60


class FormulaTest(unittest.TestCase):

    def test_shrink_at_one_three_thirty_days(self):
        # Медиана 10 км/ч на графе 50: при n = 1 — почти граф, при 30 — почти медиана.
        self.assertAlmostEqual(tp.shrink(10, 1, GRAPH), (10 + 3 * 50) / 4)       # 40
        self.assertAlmostEqual(tp.shrink(10, 3, GRAPH), 30.0)
        self.assertAlmostEqual(tp.shrink(10, 30, GRAPH), (300 + 150) / 33)       # 13,6
        self.assertEqual(tc.SHRINK_K, 3)

    def test_median_ignores_one_slow_piece(self):
        days = [(d, 40.0) for d in range(5)] + [(5, 2.0)]   # один встал у обочины
        v = tp.slot_typical(days, GRAPH)
        self.assertAlmostEqual(v, tp.shrink(40.0, 6, GRAPH))
        self.assertGreater(v, 40.0, "выброс медиану не тянет")

    def test_slot_needs_three_days_and_five_pieces(self):
        self.assertIsNone(tp.slot_typical([(1, 10.0)] * 5 + [(2, 10.0)], GRAPH), "два дня — не годен")
        self.assertIsNone(tp.slot_typical([(1, 10.0), (2, 10.0), (3, 10.0), (3, 10.0)], GRAPH),
                          "три дня, но четыре куска — не годен")
        self.assertIsNotNone(tp.slot_typical([(1, 10.0), (2, 10.0), (3, 10.0), (3, 10.0), (1, 10.0)], GRAPH))

    def test_slots_blend_by_minute(self):
        self.assertEqual(tp.slot_mix(at(0, 18, 0)), [(18, 1.0), (19, 0.0)])
        (s0, w0), (s1, w1) = tp.slot_mix(at(0, 18, 15))
        self.assertEqual((s0, s1), (18, 19))
        self.assertAlmostEqual(w0, 0.75)
        self.assertAlmostEqual(w1, 0.25)
        (_, w0), (_, w1) = tp.slot_mix(at(0, 18, 59))
        self.assertAlmostEqual(w1, 59 / 60)
        # Негодный слот — граф: 18:30 при пробке 20 в 18 и пустом 19 → 35.
        self.assertAlmostEqual(tp.base_speed([(20.0, 0.5), (None, 0.5)], GRAPH), 35.0)

    def test_sunday_night_wraps_to_monday(self):
        mix = tp.slot_mix(at(6, 23, 30))
        self.assertEqual([slot for slot, _ in mix], [167, 0], "воскресенье 23:xx → понедельник 0")
        self.assertAlmostEqual(mix[1][1], 0.5)

    def test_live_decays_with_age(self):
        n = tc.LIVE_FULL_PIECES
        self.assertAlmostEqual(tp.live_weight(n, 0), 1.0)
        self.assertAlmostEqual(tp.live_weight(n, 6 * 60), 0.3679, places=3, msg="τ = 6 мин")
        self.assertAlmostEqual(tp.live_weight(n, 15 * 60), 0.0821, places=3)
        self.assertEqual(tp.live_weight(n, 16 * 60), 0.0, "старше 15 мин — не участвует")
        self.assertAlmostEqual(tp.live_weight(2, 0), 2 / 3, msg="вес — min(1, n/3)")
        self.assertEqual(tp.live_weight(1, 0), 0.0, "для пути — от двух кусков (33F)")

    def test_live_and_typical_mix(self):
        self.assertAlmostEqual(tp.blend(10.0, 0.5, 30.0), 20.0)
        self.assertAlmostEqual(tp.blend(10.0, 0.0, 30.0), 30.0)
        self.assertAlmostEqual(tp.blend(10.0, 1.0, 30.0), 10.0)

    def test_hysteresis(self):
        self.assertTrue(tp.keep_previous(15.0 + 1.9, 15.0), "1,9 км/ч — без записи")
        self.assertFalse(tp.keep_previous(15.0 + 2.1, 15.0), "2,1 км/ч — запись")
        self.assertTrue(tp.keep_previous(40.0 + 3.9, 40.0), "у 40 км/ч порог — 10 % = 4")
        self.assertFalse(tp.keep_previous(40.0 + 4.1, 40.0))
        self.assertFalse(tp.keep_previous(20.0, None))

    def test_only_slowdown_inside_floor_and_graph(self):
        self.assertIsNone(tp.file_speed(42.6, GRAPH), "43 ≥ 0,85·50 — не пишется")
        self.assertEqual(tp.file_speed(42.4, GRAPH), 42.0)
        self.assertEqual(tp.file_speed(1.0, GRAPH), tc.SPEED_FLOOR_KMH, "не ниже 5 км/ч")
        self.assertIsNone(tp.file_speed(70.0, GRAPH), "быстрее графа — не пишется")
        self.assertIsNone(tp.file_speed(10.0, 0), "без графа — не пишется")


class RouteDbTest(unittest.TestCase):
    """Слой 33A на настоящей схеме traffic.db."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.conn = sqlite3.connect(self.tmp.name)
        tb.schema(self.conn)
        self.out = os.path.join(tempfile.mkdtemp(), "speeds.csv")

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)
        for name in os.listdir(os.path.dirname(self.out)):
            os.unlink(os.path.join(os.path.dirname(self.out), name))
        os.rmdir(os.path.dirname(self.out))

    def edge(self, u=1, v=2, model=GRAPH, shared_at=None):
        self.conn.execute("INSERT OR REPLACE INTO traffic_edges(u, v, model_kmh) VALUES(?, ?, ?)", (u, v, model))
        self.conn.execute("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, 41.3, 69.28)", (u,))
        self.conn.execute("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, 41.301, 69.28)", (v,))
        self.conn.execute("INSERT OR REPLACE INTO traffic_shared(u, v, seen) VALUES(?, ?, ?)",
                          (u, v, shared_at or at(0, 18)))

    def evening_jam(self, u=1, v=2, days=6, kmh=12.0):
        """«Вечерняя пробка на Амира Темура в 18:00»: по куску в 18-м слоте
        понедельника `days` недель подряд."""
        self.edge(u, v)
        for week in range(days):
            day = tb.day_number(at(0, 18)) - 7 * week
            self.conn.execute("INSERT INTO traffic_slot_obs(u, v, slot, day, kmh) VALUES(?, ?, 18, ?, ?)",
                              (u, v, day, kmh))
        self.conn.commit()

    def live(self, pieces, age, kmh, u=1, v=2, now=None):
        now = now or at(0, 18, 10)
        for piece in range(pieces):
            self.conn.execute("""INSERT INTO traffic_samples(u, v, kmh, weight, ts, piece, passed, src, gen)
                                 VALUES(?, ?, ?, 100, ?, ?, 1, hex(randomblob(4)), 1)""", (u, v, kmh, now - age, 100 + piece))
        self.conn.commit()

    def test_evening_jam_is_written_at_18_10_and_not_at_3(self):
        self.evening_jam()
        edges, _, stats = tp.route_edges(self.conn, at(0, 18, 10))
        # 6 дней, медиана 12 → (6·12 + 3·50)/9 = 24,7; 18:10 — 5/6 слота 18 и 1/6 графа (19 пуст).
        self.assertEqual(edges, {(1, 2): float(round(5 / 6 * (72 + 150) / 9 + 1 / 6 * 50))})
        self.assertEqual(stats["typical"], 1)
        self.assertEqual(tp.route_edges(self.conn, at(0, 3))[0], {}, "в 3:00 — граф")
        self.assertEqual(tp.route_edges(self.conn, at(1, 18, 10))[0], {}, "вторник — свой слот, пуст")

    def test_one_driver_never_makes_a_typical_jam(self):
        self.evening_jam()
        self.conn.execute("UPDATE traffic_shared SET seen = ?", (at(0, 18) - tb.SHARED_TTL - 60,))
        self.conn.commit()
        self.assertEqual(tp.route_edges(self.conn, at(0, 18, 10))[0], {})

    def test_old_observations_drop_out(self):
        self.evening_jam(days=3)
        now = at(0, 18, 10) + (tc.PROFILE_KEEP_DAYS - 13) * 86400
        self.conn.execute("UPDATE traffic_shared SET seen = ?", (now,))
        self.conn.commit()
        self.assertEqual(tp.route_edges(self.conn, now)[0], {}, "наблюдения старше 8 недель не в счёт")

    def test_live_on_top_of_graph_and_of_typical(self):
        self.edge()
        self.live(3, 0, 6.0)
        edges, _, stats = tp.route_edges(self.conn, at(0, 18, 10))
        self.assertEqual(edges, {(1, 2): 6.0}, "три свежих куска — живое целиком")
        self.assertEqual(stats["live"], 1)
        self.conn.execute("DELETE FROM traffic_samples")
        self.live(2, 6 * 60, 6.0)
        w = 2 / 3 * 0.36788
        self.assertEqual(tp.route_edges(self.conn, at(0, 18, 10))[0],
                         {(1, 2): float(round(w * 6 + (1 - w) * 50))})

    def test_one_live_piece_does_not_move_the_route(self):
        self.edge()
        self.live(1, 0, 5.0)
        self.assertEqual(tp.route_edges(self.conn, at(0, 18, 10))[0], {})

    def test_live_faster_than_graph_is_not_written(self):
        self.edge()
        self.live(3, 0, 90.0)
        self.assertEqual(tp.route_edges(self.conn, at(0, 18, 10))[0], {})

    def test_directions_are_independent(self):
        self.evening_jam(1, 2)
        self.edge(2, 1)
        edges = tp.route_edges(self.conn, at(0, 18, 10))[0]
        self.assertIn((1, 2), edges)
        self.assertNotIn((2, 1), edges, "(u,v) ≠ (v,u)")

    def test_previous_value_is_kept_inside_hysteresis(self):
        self.edge()
        self.live(3, 0, 20.0)
        self.assertEqual(tp.route_edges(self.conn, at(0, 18, 10), previous={(1, 2): 21.0})[0],
                         {(1, 2): 21.0})
        self.assertEqual(tp.route_edges(self.conn, at(0, 18, 10), previous={(1, 2): 23.0})[0],
                         {(1, 2): 20.0})

    def run_main(self, *extra):
        out = io.StringIO()
        with redirect_stdout(out):
            code = ts.main(["--db", self.tmp.name, "--out", self.out, "--source", "route", *extra])
        return code, out.getvalue()

    def test_two_runs_give_the_same_bytes(self):
        self.evening_jam()
        self.evening_jam(5, 6, kmh=8.0)
        self.live(3, 60, 7.0, u=7, v=8)
        self.edge(7, 8)
        self.conn.commit()
        now = str(at(0, 18, 10))
        self.run_main("--now", now)
        with open(self.out, "rb") as f:
            first = f.read()
        os.unlink(self.out)
        self.run_main("--now", now)
        with open(self.out, "rb") as f:
            self.assertEqual(f.read(), first)
        self.assertEqual(first.decode().splitlines(), sorted(first.decode().splitlines()))

    def test_outputs_carry_nothing_personal(self):
        self.evening_jam()
        self.live(3, 60, 7.0)
        code, log = self.run_main("--now", str(at(0, 18, 10)))
        self.assertEqual(code, 0)
        with open(self.out, encoding="ascii") as f:
            body = f.read()
        self.assertTrue(body)
        for line in body.splitlines():
            u, v, model, rate = line.split(",")
            self.assertTrue(u.isdigit() and v.isdigit())
        for word in ("lat", "lon", "piece", "device", "ip", "day", "ts", "41.", "69."):
            self.assertNotIn(word, body)
        self.assertEqual(len(log.strip().splitlines()), 1, "одна строка журнала на запуск")
        self.assertIn("слоты 18/19", log)

    def test_error_writes_an_empty_file_not_the_old_one(self):
        with open(self.out, "w") as f:
            f.write("1,2,50.0,2.778\n")
        self.conn.execute("DROP TABLE traffic_slot_obs")
        self.conn.commit()
        code, log = self.run_main("--now", str(at(0, 18, 10)))
        self.assertEqual(code, 1)
        self.assertIn("ОШИБКА", log)
        with open(self.out) as f:
            self.assertEqual(f.read(), "", "отказ = граф: файл пустой, не прошлый")

    def test_second_run_while_locked_leaves_with_a_log(self):
        import fcntl
        with open(self.out + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, log = self.run_main("--now", str(at(0, 18, 10)))
        self.assertEqual(code, 0)
        self.assertIn("пропуск", log)
        self.assertFalse(os.path.exists(self.out))

    def test_cap_trims_least_significant(self):
        edges = {(1, 2): (10.0, 50.0), (3, 4): (40.0, 50.0), (5, 6): (5.0, 50.0)}
        lengths = {(1, 2): 100.0, (3, 4): 100.0, (5, 6): 30.0}
        kept, trimmed = ts.cap(edges, lengths, 2)
        self.assertEqual(trimmed, 1)
        self.assertEqual(set(kept), {(1, 2), (5, 6)}, "100 м × 0,8 и 30 м × 0,9 значимее 100 м × 0,2")


class ProfileJsonTest(RouteDbTest):
    """33C, сервер: profile.json — годные медленные слоты для телефона."""

    def test_only_valid_slow_slots_of_shared_edges(self):
        self.evening_jam()                       # 1→2: слот 18 годен, медленный
        self.evening_jam(3, 4, days=2)           # 3→4: два дня — не годен
        self.evening_jam(5, 6, kmh=48.0)         # 5→6: годен, но почти граф
        import json
        body, count, trimmed = tp.profile_body(self.conn, at(0, 18, 10))
        data = json.loads(body)
        self.assertEqual((data["v"], data["generated"], count, trimmed), (1, at(0, 18, 10), 1, 0))
        [edge] = data["edges"]
        self.assertEqual(edge[:5], [41.3, 69.28, 41.301, 69.28, 50])
        self.assertEqual(edge[5], [[18, round((6 * 12 + 3 * 50) / 9)]], "та же типичная, что у маршрутизатора")

    def test_carries_nothing_personal(self):
        self.evening_jam()
        body, _, _ = tp.profile_body(self.conn, at(0, 18, 10))
        for word in ("device", "ip", "piece", "day", "ts", "seen"):
            self.assertNotIn(word, body)

    def test_too_big_is_trimmed_by_significance(self):
        self.evening_jam()
        self.evening_jam(5, 6, kmh=8.0)
        import json
        full, _, _ = tp.profile_body(self.conn, at(0, 18, 10))
        import gzip
        limit = len(gzip.compress(full.encode(), 6)) - 1
        body, count, trimmed = tp.profile_body(self.conn, at(0, 18, 10), max_gzip=limit)
        self.assertEqual((count, trimmed), (1, 1))
        self.assertEqual(json.loads(body)["edges"][0][5][0][1], round((6 * 8 + 3 * 50) / 9), "медленнее — значимее")

    def test_written_daily_with_a_fresh_stamp(self):
        self.evening_jam()
        path = os.path.join(os.path.dirname(self.out), "profile.json")
        self.assertTrue(tb.profile_due(self.conn, at(0, 18)))
        tb.write_profile_json(self.conn, at(0, 18), path)
        self.assertFalse(tb.profile_due(self.conn, at(0, 23)))
        self.assertTrue(tb.profile_due(self.conn, at(1, 18)), "раз в сутки — с новой меткой")


if __name__ == "__main__":
    unittest.main()
