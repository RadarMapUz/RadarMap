"""Тесты чистой логики полос: python3 -m unittest test_logic (без numpy)."""
import math
import os
import re
import unittest

from logic import (BOUNDARY_RIGHT, carriageway_width, classify, dash_runs,
                   lane_layout, lanes_in_gap, median_kind, model_width,
                   road_extent, robust_count, robust_value, seg_key,
                   strip_kind, track_filter)


class ClassifyTests(unittest.TestCase):
    STEP = 0.5

    def test_solid(self):
        occ = [True] * 30
        occ[10] = False              # одна выпавшая ячейка — всё равно сплошная
        self.assertEqual(classify(occ, self.STEP)[0], "solid")

    def test_dashed_1_to_3(self):
        # штрих 1 м, разрыв 3 м (1.5 ПДД) на 20 м
        occ = ([True] * 2 + [False] * 6) * 5
        kind, fill = classify(occ, self.STEP)
        self.assertEqual(kind, "dashed")
        self.assertAlmostEqual(fill, 0.25)

    def test_dashed_long_strokes(self):
        # 1.6: штрих втрое длиннее разрыва — не сплошная из-за разрывов 1,5 м?
        # разрыв 1,5 м < SOLID_MAX_GAP, но заполнение 0,75 → сплошная по
        # заполнению… поэтому 1.6 с разрывом 3 м:
        occ = ([True] * 18 + [False] * 6) * 2
        self.assertEqual(classify(occ, self.STEP)[0], "dashed")

    def test_noise_is_not_line(self):
        occ = [False] * 20 + [True] + [False] * 20
        self.assertIsNone(classify(occ, self.STEP)[0])

    def test_edge_emptiness_is_not_gap(self):
        # пустота у краёв — конец видимости, а не разрыв: сплошная
        occ = [False] * 8 + [True] * 24 + [False] * 8
        self.assertEqual(classify(occ, self.STEP)[0], "solid")

    def test_single_dash_seen(self):
        occ = [False] * 4 + [True] * 3 + [False] * 30
        self.assertEqual(classify(occ, self.STEP)[0], "dashed")


class WidthTests(unittest.TestCase):
    def test_lanes_in_gap(self):
        self.assertEqual(lanes_in_gap(3.5), 1)
        self.assertEqual(lanes_in_gap(2.0), 0)       # не полоса
        self.assertEqual(lanes_in_gap(7.0), 2)       # потерянная линия посередине
        self.assertEqual(lanes_in_gap(4.6), 0)       # между 1 и 2 — неправдоподобно
        self.assertEqual(lanes_in_gap(9.5), 0)

    def test_layout_three_lanes(self):
        lines = [(-5.3, "solid", 0.9), (-1.8, "dashed", 0.3),
                 (1.7, "dashed", 0.3), (5.2, "edge", 1.0)]
        lay = lane_layout(lines)
        self.assertEqual((lay["lanes"], lay["left"], lay["right"]), (3, 1, 1))
        self.assertTrue(lay["plausible"])

    def test_left_solid_stops_chain(self):
        # за сплошной слева — встречка, её не считаем
        lines = [(-8.8, "dashed", 0.3), (-5.3, "solid", 0.9), (-1.8, "dashed", 0.3),
                 (1.7, "dashed", 0.3)]
        lay = lane_layout(lines)
        self.assertEqual(lay["left"], 1)

    def test_right_solid_does_not_stop(self):
        self.assertNotIn("solid", BOUNDARY_RIGHT)
        lines = [(-1.8, "dashed", 0.3), (1.7, "solid", 0.9), (5.2, "dashed", 0.3)]
        self.assertEqual(lane_layout(lines)["right"], 1)

    def test_implausible_own_lane(self):
        self.assertIsNone(lane_layout([(-1.0, "dashed", 0.3), (0.9, "dashed", 0.3)]))

    def test_line_under_car_means_no_verdict(self):
        self.assertIsNone(lane_layout([(-3.5, "dashed", 0.3), (0.2, "dashed", 0.3),
                                       (3.6, "dashed", 0.3)]))

    def test_one_false_line_skipped(self):
        # блик на +1,2 рядом с настоящей линией +2,7
        lay = lane_layout([(-1.1, "dashed", 0.4), (1.2, "dashed", 0.2), (2.7, "dashed", 0.4)])
        self.assertAlmostEqual(lay["own_width"], 3.8)

    def test_unmarked_curb_lane(self):
        # за последней прерывистой до бордюра 3,6 м — ряд без разметки
        lay = lane_layout([(-1.8, "dashed", 0.3), (1.7, "dashed", 0.3)], (None, 5.3))
        self.assertEqual((lay["right"], lay["unmarked"]), (1, 1))
        self.assertTrue(lay["right_edge_ok"])

    def test_far_edge_is_unreliable(self):
        lay = lane_layout([(-1.8, "dashed", 0.3), (1.7, "dashed", 0.3)], (None, 9.0))
        self.assertEqual(lay["unmarked"], 0)
        self.assertFalse(lay["right_edge_ok"])

    def test_left_curb_bounds_own_lane(self):
        # своя — от бордюра разделительной (-2,2) до прерывистой (+1,8);
        # «сплошная» в 0,3 м от бордюра — его же кромка
        lay = lane_layout([(-1.9, "solid", 0.9), (1.8, "dashed", 0.3),
                           (5.4, "dashed", 0.3)], (-2.2, None))
        self.assertEqual((lay["lanes"], lay["left"], lay["right"]), (2, 0, 1))
        self.assertEqual(lay["left_kind"], "edge")

    def test_chain_skips_one_false_line(self):
        # +4,0 — бок машины между настоящими +1,8 и +5,5
        lay = lane_layout([(-1.8, "dashed", 0.3), (1.8, "dashed", 0.3),
                           (4.0, "dashed", 0.2), (5.5, "dashed", 0.3)])
        self.assertEqual(lay["right"], 1)

    def test_lines_beyond_edge_ignored(self):
        lay = lane_layout([(-1.8, "dashed", 0.3), (1.7, "dashed", 0.3),
                           (8.0, "dashed", 0.3)], (None, 5.2))
        self.assertEqual(lay["right"], 1)


class ExtentTests(unittest.TestCase):
    def test_extent(self):
        step = 0.2
        xs = [round(-6 + i * step, 2) for i in range(61)]
        a = [0.0 if (x < -4.0 or x > 3.6) else 0.9 for x in xs]
        a[35] = 0.1                      # одна тёмная клякса (машина) — не край
        le, re_ = road_extent(xs, a, step)
        self.assertAlmostEqual(le, -4.1, places=1)
        self.assertAlmostEqual(re_, 3.7, places=1)

    def test_extent_not_visible(self):
        xs = [i * 0.2 - 2 for i in range(21)]
        a = [0.9] * 15 + [float("nan")] * 6
        self.assertEqual(road_extent(xs, a, 0.2)[1], None)


class RoadsideTests(unittest.TestCase):
    def test_strip_kind(self):
        self.assertEqual(strip_kind(0.5, 0.1, 0.1, 0.2), "газон")
        self.assertEqual(strip_kind(0.0, 0.6, 0.1, 0.1), "бордюр")
        self.assertEqual(strip_kind(0.0, 0.1, 0.8, 0.0), "асфальт")
        self.assertEqual(strip_kind(0.0, 0.1, 0.1, 0.7), "ограждение")
        self.assertIsNone(strip_kind(0.1, 0.1, 0.3, 0.2))

    def test_median_kind(self):
        self.assertEqual(median_kind("dashed", False, "газон"), "газон")
        self.assertEqual(median_kind("solid", False, "асфальт"), "сплошная")
        self.assertEqual(median_kind("dashed", False, None), "нет")

    def test_carriageway_width(self):
        self.assertAlmostEqual(carriageway_width(-5.2, 5.3), 10.5)
        self.assertAlmostEqual(carriageway_width(None, 5.3, -1.8), 7.1)
        self.assertIsNone(carriageway_width(None, 5.3))
        self.assertIsNone(carriageway_width(-1.0, 0.5))      # 1,5 м — не дорога

    def test_model_width_matches_server(self):
        self.assertEqual(model_width(4, "primary", True), 15.0)
        self.assertEqual(model_width(4, "secondary", False), 7.0)
        self.assertEqual(model_width(None, "residential", False), 3.5)
        self.assertIsNone(model_width(2, "footway", True))

    def test_constants_copied_from_build_roads(self):
        # Ширина считается копией формулы — сверяем константы с оригиналом.
        import logic
        path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "server", "build_roads.py")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        for name in ("DEFAULT_LANES", "LANE_METERS"):
            m = re.search(name + r" = (\{[^}]*\})", src)
            self.assertEqual(eval(m.group(1)), getattr(logic, name), name)


class DashTests(unittest.TestCase):
    def test_dash_lengths(self):
        # штрихи 1 м через 3 м на 6–20 м, точки каждые 5 см
        zs = [z / 100 for z in range(600, 2000, 5) if (z - 600) % 400 < 100]
        st, gp = dash_runs(zs, 6.0, 20.0)
        self.assertTrue(all(abs(s - 0.95) < 0.06 for s in st), st)
        self.assertTrue(all(abs(g - 3.05) < 0.06 for g in gp), gp)

    def test_cut_strokes_are_not_measured(self):
        zs = [z / 100 for z in range(600, 680, 5)]       # штрих, обрезанный низом кадра
        self.assertEqual(dash_runs(zs, 6.0, 20.0), ([], []))

    def test_sparse_far_rows_join(self):
        # вдали строки через 0,4 м: без row_step штрих рассыпается
        zs = [15.0, 15.4, 15.8, 16.2]
        st, _ = dash_runs(zs, 6.0, 20.0, row_step=lambda z: z * z / (749 * 1.3))
        self.assertEqual(len(st), 1)


class AggregateTests(unittest.TestCase):
    def test_robust_count(self):
        self.assertEqual(robust_count([3, 3, 3, 2])[0], 3)
        self.assertEqual(robust_count([3, 2, 4, 2, 3])[0], None)   # нет согласия
        self.assertEqual(robust_count([3, None, 3]), (None, 0.0, 2))  # мало голосов
        n, conf, votes = robust_count([2, 2, 2, 2, 3])
        self.assertEqual((n, conf, votes), (2, 0.8, 5))

    def test_robust_value(self):
        self.assertAlmostEqual(robust_value([10.1, 10.4, 10.2, 9.9])[0], 10.15)
        self.assertIsNone(robust_value([7.0, 10.0, 14.0, 9.0])[0])      # разброс
        self.assertIsNone(robust_value([10.0])[0])

    def test_seg_key(self):
        a = seg_key(41.3110, 69.2790, 90)
        b = seg_key(41.3110, 69.27905, 92)          # 4 м рядом, тот же курс
        c = seg_key(41.3110, 69.27905, 270)         # встречное направление
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)
        far = seg_key(41.3110, 69.2790 + 200 / (111320 * math.cos(math.radians(41.311))), 90)
        self.assertNotEqual(a, far)

    def test_track_filter(self):
        def fr(i, lines):
            return {"lat": 41.3 + i * 8 / 111320, "lon": 69.2, "course": 0.0, "lines": lines}
        frames = [fr(i, [[-1.8, "dashed"], [1.7, "dashed"]]) for i in range(7)]
        frames[3]["lines"].append([4.9, "solid"])         # бок машины — один кадр
        kept = track_filter(frames)
        self.assertEqual([l[0] for l in kept[3]], [-1.8, 1.7])
        # одиночный кадр без соседей не судим
        self.assertEqual(track_filter([fr(0, [[-1.8, "dashed"]])]), [[]])


if __name__ == "__main__":
    unittest.main()
