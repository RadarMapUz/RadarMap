"""Тесты логики v2: отслеживание, «бегут ли штрихи», правило краёв,
раскладка по трекам и голосование окна. Только числа, без картинок.

    python3 test_v2.py
"""
import unittest

from logic import UNMARKED_MIN, edge_kind, lane_layout2, outer_unmarked, vote
from track import (best_shift, cumulative, dash_like, frame_peaks, frame_shift,
                   is_line_track, link_tracks, motion_test, path_from_speed, profile,
                   strokes, track_x_at)


def hist(xs, x0=-5.0, n=100, step=0.1, val=10.0):
    h = [0.0] * n
    for x in xs:
        h[int((x - x0) / step)] += val
    return h


def dashed_profile(offset, z0=5.0, z1=17.0, stroke=3.0, period=12.0):
    """Профиль преривистой 3+9 м, сдвинутой к машине на offset м."""
    zs = []
    z = z0
    while z < z1:
        w = (z + offset) % period
        if w < stroke:
            zs.append(z)
        z += 0.05
    return profile(zs, z0, z1)


class TestPeaksAndShift(unittest.TestCase):
    def test_peaks_found_and_separated(self):
        h = hist([-1.75, 1.75, 1.8])
        pk = frame_peaks(h, -5.0, 3.0)
        xs = [round(x, 1) for x, _ in pk]
        self.assertEqual(len(xs), 2)
        self.assertAlmostEqual(xs[0], -1.75, delta=0.1)
        self.assertAlmostEqual(xs[1], 1.75, delta=0.15)

    def test_shift_follows_all_lines(self):
        a = hist([-1.75, 1.75])
        b = hist([-1.55, 1.95])          # машина вильнула влево на 0,2 м
        self.assertAlmostEqual(frame_shift(a, b), 0.2, places=6)
        self.assertEqual(frame_shift(a, [0.0] * 100), 0.0)

    def test_cumulative(self):
        self.assertEqual(cumulative([0.1, 0.1, -0.2]), [0.0, 0.1, 0.2, 0.0])


class TestLinking(unittest.TestCase):
    def test_lane_change_keeps_tracks(self):
        """Перестроение: все линии плывут вправо на 0,1 м за кадр — треки
        не рвутся, потому что сравнение идёт за вычетом общего сдвига."""
        n = 20
        times = [k * 0.08 for k in range(n)]
        peaks = [[(-1.75 + 0.1 * k, 10.0), (1.75 + 0.1 * k, 10.0)] for k in range(n)]
        shifts = [0.1] * (n - 1)
        tr = link_tracks(peaks, times, shifts)
        self.assertEqual(len(tr), 2)
        self.assertTrue(all(is_line_track(t, times) for t in tr))
        # Без учёта сдвига (shifts = 0) при допуске 0,05 треки бы рвались.
        tr0 = link_tracks(peaks, times, [0.0] * (n - 1), tol=0.05)
        self.assertGreater(len(tr0), 2)

    def test_flash_is_not_a_line(self):
        """Блик/бок машины в двух кадрах — трек короче секунды."""
        times = [k * 0.08 for k in range(20)]
        peaks = [[(-1.75, 10.0)] + ([(0.9, 10.0)] if k in (5, 6) else []) for k in range(20)]
        tr = link_tracks(peaks, times, [0.0] * 19)
        lines = [t for t in tr if is_line_track(t, times)]
        self.assertEqual(len(lines), 1)
        self.assertAlmostEqual(lines[0]["x"][0], -1.75)

    def test_gap_tolerated(self):
        times = [k * 0.08 for k in range(20)]
        peaks = [[(-1.75, 10.0)] if k not in (8, 9, 10) else [] for k in range(20)]
        tr = link_tracks(peaks, times, [0.0] * 19)
        self.assertEqual(len(tr), 1)

    def test_track_x_at_uses_shift_when_unseen(self):
        times = [k * 0.1 for k in range(5)]
        peaks = [[(1.0, 5.0)], [(1.1, 5.0)], [], [], []]
        shifts = [0.1, 0.1, 0.1, 0.1]
        t = link_tracks(peaks, times, shifts)[0]
        cum = cumulative(shifts)
        self.assertAlmostEqual(track_x_at(t, 4, cum), 1.4)


class TestMotion(unittest.TestCase):
    def test_best_shift_finds_travel(self):
        a = dashed_profile(0.0)
        b = dashed_profile(4.0)          # проехали 4 м
        d, score = best_shift(a, b, 12.0)
        self.assertAlmostEqual(d, 4.0, delta=0.3)
        self.assertGreater(score, 0.8)

    def test_painted_dashes_run_reflection_stands(self):
        times = [k * 0.08 for k in range(40)]
        path = path_from_speed(times, [54.0] * 40)        # 15 м/с → 1,2 м за кадр
        paint = [dashed_profile(p) for p in path]
        n, moving, static = motion_test(paint, path)
        self.assertGreater(n, 5)
        self.assertGreater(moving, 0.8 * n)
        self.assertEqual(static, 0)
        glare = [dashed_profile(0.0) for _ in path]     # стоит в кадре
        n, moving, static = motion_test(glare, path)
        self.assertGreater(static, 0.8 * n)
        self.assertEqual(moving, 0)

    def test_solid_is_silent(self):
        times = [k * 0.08 for k in range(30)]
        path = path_from_speed(times, [50.0] * 30)
        solid = [[1] * 48 for _ in path]
        self.assertEqual(motion_test(solid, path), (0, 0, 0))

    def test_unknown_cells_do_not_vote(self):
        """Ячейки под нитями отражения (−1) не сравниваются: дыра в маске,
        стоящая в кадре, не превращает бегущую линию в «стоящую»."""
        times = [k * 0.08 for k in range(40)]
        path = path_from_speed(times, [54.0] * 40)
        paint = []
        for p in path:
            pr = dashed_profile(p)
            for i in range(10, 14):
                pr[i] = -1
            paint.append(pr)
        n, moving, static = motion_test(paint, path)
        self.assertGreater(moving, static)

    def test_strokes_and_dash_like(self):
        st, gp = strokes([0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1])
        self.assertEqual(st, [1.0, 1.0])
        self.assertEqual(gp, [1.0])
        # Трава: обрывки по 0,25–0,5 м — не штрихи.
        grass = [[0, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0] * 2 for _ in range(5)]
        self.assertFalse(dash_like(grass)[0])
        paint = [dashed_profile(o) for o in (0.0, 1.0, 2.0, 5.0, 7.0)]
        self.assertTrue(dash_like(paint)[0])


class TestEdges(unittest.TestCase):
    def test_curb_is_straight_and_steady(self):
        frames = [[4.0, 4.1, 3.9]] * 8
        self.assertEqual(edge_kind(frames, "газон")[0], "curb")

    def test_parked_cars_jump(self):
        """Машины у тротуара: края по дальностям расходятся и меняются."""
        frames = [[3.0, 4.5, 3.2], [4.4, 3.0, None], [3.1, 3.1, 4.6], [4.5, 3.0, 3.9],
                  [3.0, 4.6, 4.4], [4.0, 3.0, 3.0]]
        self.assertEqual(edge_kind(frames)[0], "cars")

    def test_asphalt_beyond_is_not_curb(self):
        frames = [[4.0, 4.1, 3.9]] * 8
        self.assertEqual(edge_kind(frames, "асфальт")[0], "cars")

    def test_too_little_data(self):
        self.assertEqual(edge_kind([[None, 4.0, None]] * 10), (None, None))

    def test_unmarked_right_lane_rule(self):
        self.assertEqual(outer_unmarked(1.75, 1.75 + UNMARKED_MIN, "dashed"), 1)
        self.assertEqual(outer_unmarked(1.75, 1.75 + UNMARKED_MIN - 0.1, "dashed"), 0)
        self.assertEqual(outer_unmarked(1.75, 8.0, "dashed"), 1)     # широкий ряд у бордюра
        self.assertEqual(outer_unmarked(1.75, 9.0, "dashed"), 0)     # уже не один ряд
        self.assertEqual(outer_unmarked(1.75, 5.0, "edge"), 0)
        self.assertEqual(outer_unmarked(1.75, None, "dashed"), 0)


class TestLayout2(unittest.TestCase):
    def test_five_lanes_between_curbs(self):
        lay = lane_layout2([(-5.25, "dashed"), (-1.75, "dashed"), (1.75, "dashed"),
                            (5.25, "dashed")], left_bound=-8.7, right_bound=8.7)
        self.assertEqual((lay["lanes"], lay["own"]), (5, 3))

    def test_unmarked_curb_lane_counts(self):
        """Своя у бордюра без линии справа: до бордюра 4,5 м — своя полоса."""
        lay = lane_layout2([(-5.25, "dashed"), (-1.75, "dashed")],
                           left_bound=-8.7, right_bound=2.75)
        self.assertEqual((lay["lanes"], lay["own"]), (3, 3))

    def test_extra_lane_beyond_last_dashed(self):
        """За крайней прерывистой справа — ещё ряд, даже если бордюра не видно."""
        lay = lane_layout2([(-1.75, "solid"), (1.75, "dashed")])
        self.assertEqual((lay["lanes"], lay["own"]), (2, 1))

    def test_parked_cars_are_not_a_lane(self):
        """Справа не бордюр (машины → right_bound None) и крайняя — сплошная:
        лишнего ряда не добавляем."""
        lay = lane_layout2([(-1.75, "solid"), (1.75, "solid")])
        self.assertEqual(lay["lanes"], 1)

    def test_left_solid_stops_chain(self):
        lay = lane_layout2([(-5.25, "dashed"), (-1.75, "solid"), (1.75, "dashed"),
                            (5.25, "edge")])
        self.assertEqual((lay["lanes"], lay["own"]), (2, 1))

    def test_spurious_line_inside_lane_skipped(self):
        lay = lane_layout2([(-1.75, "solid"), (1.75, "dashed"), (2.6, "solid"),
                            (5.25, "edge")])
        self.assertEqual((lay["lanes"], lay["own"]), (2, 1))

    def test_far_grass_is_not_a_lane(self):
        """Шаг цепочки — по своей полосе: «линия» в 4,6 м за прерывистой — не ряд."""
        lay = lane_layout2([(-1.75, "solid"), (1.6, "dashed"), (6.2, "dashed")])
        self.assertEqual(lay["lanes"], 2)        # своя + одна за прерывистой

    def test_line_under_car_refuses(self):
        self.assertIsNone(lane_layout2([(-0.3, "dashed"), (3.2, "dashed")]))

    def test_lines_beyond_curb_ignored(self):
        lay = lane_layout2([(-1.75, "solid"), (1.75, "dashed"), (7.0, "dashed")],
                           right_bound=5.25)
        self.assertEqual(lay["lanes"], 2)


class TestVote(unittest.TestCase):
    def lay(self, n, own):
        return {"lanes": n, "own": own}

    def test_majority(self):
        ls = [self.lay(3, 2)] * 6 + [self.lay(4, 2)] * 2 + [None] * 2
        self.assertEqual(vote(ls, 0.5), (3, 2, 0.6))

    def test_silent_frames_count_against(self):
        ls = [self.lay(3, 2)] * 4 + [None] * 6
        lanes, own, share = vote(ls, 0.5)
        self.assertIsNone(lanes)
        self.assertAlmostEqual(share, 0.4)

    def test_own_mode_among_winner(self):
        ls = [self.lay(3, 2)] * 3 + [self.lay(3, 3)] * 1 + [self.lay(2, 3)] * 6
        self.assertEqual(vote(ls, 0.5)[:2], (2, 3))
        ls = [self.lay(3, 2)] * 4 + [self.lay(3, 3)] * 2
        self.assertEqual(vote(ls, 0.5)[:2], (3, 2))


class TestHybrid(unittest.TestCase):
    """Гибрид v2 + модель: модель снимает/возвращает, отражения не трогает."""

    def votes(self, line_cls, n_line, n_other):
        import numpy as np
        v = np.zeros(8, int)
        v[line_cls] = n_line
        v[0] = n_other
        return [v]

    def test_support(self):
        from window import model_support
        m = model_support(self.votes(2, 30, 10))
        self.assertAlmostEqual(m["line"], 0.75)
        self.assertEqual(m["kind"], "dashed")
        self.assertIsNone(model_support([]))

    def test_veto_and_rescue(self):
        from window import judge_hybrid, model_support
        l = {"width": 0.15, "model": model_support(self.votes(1, 1, 30))}
        self.assertIsNone(judge_hybrid(l, "dashed", "штрихи бегут")[0])
        self.assertEqual(judge_hybrid(l, "edge", "асфальт с одной стороны")[0], "edge")
        l = {"width": 0.15, "model": model_support(self.votes(2, 30, 5))}
        self.assertEqual(judge_hybrid(l, None, "контраст")[0], "dashed")
        # отражение («стоит в кадре») модель не возвращает
        self.assertIsNone(judge_hybrid(l, None, "стоит в кадре")[0])
        # широкое облако — не линия, даже если модель «за»
        l["width"] = 0.6
        self.assertIsNone(judge_hybrid(l, None, "контраст")[0])
        # без модели — как v2
        self.assertEqual(judge_hybrid({"model": None}, "solid", "по заполнению"), ("solid", "по заполнению"))


if __name__ == "__main__":
    unittest.main()
