#!/usr/bin/env python3
"""Тесты чистой логики этапа «камеры по видео»: python3 -m unittest test_cams"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import events  # noqa: E402
import passes  # noqa: E402


def const_odo(kmh, t0=0.0, t1=600.0, step=1.0):
    n = int((t1 - t0) / step) + 1
    return passes.Odo([(t0 + i * step, kmh) for i in range(n)])


class PassTimeTest(unittest.TestCase):
    def test_release_path_city_uses_settings_radius(self):
        # 50 км/ч × 22 с = 306 м < 600 → радиус 600 + 120 + запас
        self.assertAlmostEqual(passes.release_path_m(50), 600 + 120 + passes.RELEASE_EXTRA_M)

    def test_release_path_grows_with_speed(self):
        # 110 км/ч: трасса, 29 с → 886 м
        self.assertAlmostEqual(passes.release_path_m(110), 110 / 3.6 * 29 + 120 + passes.RELEASE_EXTRA_M)
        self.assertGreater(passes.release_path_m(90), passes.release_path_m(60))

    def test_pass_time_rewinds_path_not_time(self):
        odo = const_odo(36.0)  # 10 м/с
        tp = passes.pass_time(odo, 300.0)
        self.assertAlmostEqual(300.0 - tp, passes.release_path_m(36) / 10, places=3)

    def test_pass_time_none_outside_video_or_over_gap(self):
        odo = const_odo(36.0, 0, 100)
        self.assertIsNone(passes.pass_time(odo, 50.0))      # не успели проехать 740 м от начала
        self.assertIsNone(passes.pass_time(odo, 500.0))     # wpt вне видео
        gap = passes.Odo([(t, 36.0) for t in range(0, 100)] + [(t, 36.0) for t in range(160, 400)])
        self.assertIsNone(passes.pass_time(gap, 200.0))     # дыра в скорости внутри отмотки

    def test_odo_time_at_inverts_at(self):
        odo = passes.Odo([(0, 0), (10, 36), (20, 72), (30, 72)])
        for t in (3.0, 12.5, 25.0):
            self.assertAlmostEqual(odo.time_at(odo.at(t)), t, places=6)


class SampleRulesTest(unittest.TestCase):
    def setUp(self):
        self.odo = const_odo(36.0)  # 10 м/с

    def test_positive_window(self):
        tp = 200.0
        self.assertTrue(passes.label_positive(198.0, 36, tp, self.odo))       # 2 с, 20 м
        self.assertFalse(passes.label_positive(199.8, 36, tp, self.odo))      # 0,2 с — камера над головой
        self.assertFalse(passes.label_positive(196.0, 36, tp, self.odo))      # 4 с — ещё далеко
        self.assertFalse(passes.label_positive(201.0, 36, tp, self.odo))      # после проезда — камера сзади
        self.assertFalse(passes.label_positive(198.0, 2, tp, self.odo))       # стоим

    def test_positive_distance_bound(self):
        slow = const_odo(7.2)  # 2 м/с: 2,5 с — всего 5 м, камера уже над головой
        self.assertFalse(passes.label_positive(197.5, 7.2, 200.0, slow))

    def test_negative_needs_distance_by_path_and_place(self):
        pts = [200.0]
        self.assertTrue(passes.label_negative(240.0, 36, pts, self.odo, 500.0))   # 400 м пути, 500 м до камеры
        self.assertFalse(passes.label_negative(220.0, 36, pts, self.odo, 500.0))  # 200 м по пути
        self.assertFalse(passes.label_negative(240.0, 36, pts, self.odo, 120.0))  # камера базы рядом
        self.assertFalse(passes.label_negative(240.0, 36, pts, self.odo, None))   # места нет — не доказано
        self.assertFalse(passes.label_negative(240.0, 5, pts, self.odo, 500.0))   # стоим

    def test_split_by_trip_is_deterministic_and_disjoint(self):
        keys = [f'k{i}' for i in range(12)]
        a, b = passes.split_by_trip(keys), passes.split_by_trip(list(reversed(keys)))
        self.assertEqual(a, b)
        self.assertEqual(sum(v == 'val' for v in a.values()), 3)


class SpikesTest(unittest.TestCase):
    def test_spike_needs_two_frames_or_one_confident(self):
        s = [(0, .1, 1), (1, .7, 2), (2, .1, 3), (10, .95, 4), (11, .2, 5), (20, .6, 6), (20.5, .7, 7)]
        runs = events.spikes(s)
        self.assertEqual([[q[2] for q in r] for r in runs], [[4], [6, 7]])

    def test_gap_splits_run(self):
        s = [(0, .8, 1), (1, .8, 2), (5, .8, 3), (5.5, .8, 4)]
        self.assertEqual(len(events.spikes(s)), 2)

    def test_event_time_is_after_last_frame_by_lead(self):
        odo = const_odo(36.0)
        evs = events.events_from_series([(100, .8, 1), (100.6, .9, 2)], odo)
        self.assertEqual(len(evs), 1)
        self.assertAlmostEqual(evs[0]['t'], 100.6 + events.EVENT_LEAD_M / 10, places=3)
        self.assertEqual(evs[0]['frame_id'], 2)

    def test_close_spikes_merge(self):
        odo = const_odo(36.0)
        s = [(100, .8, 1), (100.5, .8, 2), (101, .1, 3), (103.0, .8, 4), (103.5, .8, 5)]
        self.assertEqual(len(events.events_from_series(s, odo)), 1)   # 30 м — одна опора
        s2 = [(100, .8, 1), (100.5, .8, 2), (101, .1, 3), (110.0, .8, 4), (110.5, .8, 5)]
        self.assertEqual(len(events.events_from_series(s2, odo)), 2)


class MatchTest(unittest.TestCase):
    def test_greedy_match(self):
        pairs, extra, miss = events.match([10, 50, 51, 200], [11, 52, 300], tol_s=5)
        self.assertEqual(pairs, [(0, 0), (2, 1)])
        self.assertEqual(extra, [1, 3])
        self.assertEqual(miss, [2])

    def test_dedup_truth(self):
        self.assertEqual(events.dedup_truth([(10, 1), (10.5, 2), (40, 3)]), [(10, {1, 2}), (40, {3})])


def cam(i, lat, lon, d=None):
    c = {'id': i, 'lat': lat, 'lon': lon}
    if d is not None:
        c['dir'] = d
    return c


class NearestTest(unittest.TestCase):
    def setUp(self):
        # две камеры у одной точки — на разные стороны дороги
        self.cams = [cam(1, 41.3000, 69.2000, d=0), cam(2, 41.3001, 69.2000, d=180),
                     cam(3, 41.3100, 69.2000)]
        self.grid = passes.CamGrid(self.cams)

    def test_course_picks_own_side(self):
        i, d = events.nearest_camera(41.29995, 69.2, 0.0, self.grid)
        self.assertEqual(self.cams[i]['id'], 1)
        i, d = events.nearest_camera(41.29995, 69.2, 180.0, self.grid)
        self.assertEqual(self.cams[i]['id'], 2)

    def test_unknown_course_takes_nearest(self):
        i, _ = events.nearest_camera(41.30012, 69.2, -1, self.grid)
        self.assertEqual(self.cams[i]['id'], 2)

    def test_none_beyond_radius(self):
        i, d = events.nearest_camera(41.3050, 69.2, 0.0, self.grid)
        self.assertIsNone(i)

    def test_camera_without_dir_fits_any_course(self):
        i, _ = events.nearest_camera(41.3100, 69.2001, 90.0, self.grid)
        self.assertEqual(self.cams[i]['id'], 3)


class FakeOSRM:
    """Дороги — прямые с коэффициентом извилистости k."""

    def __init__(self, k=1.2):
        self.k = k

    def route(self, a, b, bearings=None):
        d = passes.haversine(a[0], a[1], b[0], b[1]) * self.k
        return [a, b], d


class HMMSyntheticTest(unittest.TestCase):
    def test_chain_recovered_on_sparse_grid(self):
        import hmm
        # камеры на неравномерной «улице» + шум вокруг
        lat0, lon0 = 41.3, 69.2
        step = [0, 700, 1900, 2600, 4400, 5100]
        line = [cam(10 + i, lat0 + s / 111000, lon0) for i, s in enumerate(step)]
        noise = [cam(100 + i, lat0 + 0.05 + (i % 7) * 0.013, lon0 + 0.03 + (i // 7) * 0.017) for i in range(40)]
        cams = line + noise
        idx = hmm.index(cams)
        k = 1.2
        dist = [(b - a) * k for a, b in zip(step, step[1:])]
        times = [0.0]
        for d in dist:
            times.append(times[-1] + d / 10)
        odo = const_odo(36.0, 0, times[-1] + 10)
        res = hmm.identify([(t, 1.0) for t in times], odo.at, idx, FakeOSRM(k))
        self.assertEqual(res['status'], 'ok')
        got = {round(t): cams[j]['id'] for t, j, _ in res['anchors']}
        want = {round(t): 10 + i for i, t in enumerate(times)}
        self.assertTrue(got)
        for t, cid in got.items():
            self.assertEqual(cid, want[t])

    def test_too_few_events(self):
        import hmm
        res = hmm.identify([(0, 1.0), (10, 1.0)], lambda t: t * 10, hmm.index([cam(1, 41.3, 69.2)]), FakeOSRM())
        self.assertEqual(res['status'], 'too_few_events')


class RulesTest(unittest.TestCase):
    def ev(self, trip, lat, lon, course=0.0, p=0.9):
        return {'trip': trip, 'lat': lat, 'lon': lon, 'course': course, 'p': p}

    def test_new_needs_two_trips(self):
        one = [self.ev('2026-10-01-08', 41.3, 69.2), self.ev('2026-10-01-08', 41.30005, 69.2)]
        self.assertEqual(events.new_camera_candidates(one), [])
        same_day = one + [self.ev('2026-10-01-18', 41.30010, 69.2)]
        self.assertEqual(events.new_camera_candidates(same_day), [])   # туда-обратно в один день — не повтор
        two = one + [self.ev('2026-10-02-08', 41.30010, 69.2)]
        self.assertEqual(len(events.new_camera_candidates(two)), 1)

    def test_new_splits_by_place_and_course(self):
        evs = [self.ev('2026-10-01-a', 41.3, 69.2), self.ev('2026-10-02-b', 41.3, 69.2, course=180),
               self.ev('2026-10-03-c', 41.31, 69.2), self.ev('2026-10-04-d', 41.31, 69.2)]
        c = events.new_camera_candidates(evs)
        self.assertEqual(len(c), 1)
        self.assertEqual({e['trip'] for e in c[0]}, {'2026-10-03-c', '2026-10-04-d'})

    def test_removed_needs_three_good_passes_without_spike(self):
        v = {'day': True, 'covered': True, 'kmh': 40, 'seen': False}
        self.assertEqual(events.removed_verdict([v, v]), 'unknown')
        self.assertEqual(events.removed_verdict([v, v, v]), 'removed')
        self.assertEqual(events.removed_verdict([v, v, v, dict(v, seen=True)]), 'present')

    def test_removed_ignores_night_slow_and_uncovered(self):
        v = {'day': True, 'covered': True, 'kmh': 40, 'seen': False}
        bad = [dict(v, day=False), dict(v, kmh=5), dict(v, covered=False)]
        self.assertEqual(events.removed_verdict([v, v] + bad), 'unknown')


class WebTest(unittest.TestCase):
    def test_crop_names_whitelisted(self):
        import camsweb
        for bad in ('../cams.db', 'new_1.jpg/../../x', 'other_1.jpg', 'new_.jpg', '/etc/passwd'):
            self.assertIsNone(camsweb.crop_bytes(bad))


class HMMLoopTest(unittest.TestCase):
    def test_loop_detection(self):
        import hmm
        self.assertTrue(hmm.has_loop([1, None, 2, 1]))
        self.assertFalse(hmm.has_loop([1, 2, 3, 4, 1]))   # через 4 опознанных — уже не «туда-обратно»


if __name__ == '__main__':
    unittest.main()
