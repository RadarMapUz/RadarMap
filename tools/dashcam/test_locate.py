#!/usr/bin/env python3
"""Тесты «где был кадр»: подробный трек (интерполяция, курс на стоянке,
клик по треку → время) и старая поездка по опорам (позиция на опоре точная,
между опорами монотонная, невязка считается)."""
import math
import unittest

import gpx
import locate

LAT0, LON0 = 41.31, 69.25
M_LAT = 1 / 111195.0                                  # градусов широты на метр
M_LON = 1 / (111195.0 * math.cos(math.radians(LAT0)))  # градусов долготы на метр


def at(east_m, north_m):
    return LAT0 + north_m * M_LAT, LON0 + east_m * M_LON


class TimedTest(unittest.TestCase):
    def setUp(self):
        # 0–10 с на восток 10 м/с, 10–20 с стоим, 20–30 с на север
        self.pts = []
        for i in range(0, 11):
            self.pts.append((100 + i, *at(10 * i, 0), 36.0))
        for i in range(11, 21):
            self.pts.append((100 + i, *at(100, 0), 0.0))
        for i in range(21, 31):
            self.pts.append((100 + i, *at(100, 10 * (i - 20)), 36.0))

    def test_interpolation_and_course(self):
        lat, lon, course = locate.position_at(self.pts, 104.5)
        elat, elon = at(45, 0)
        self.assertAlmostEqual(lat, elat, places=7)
        self.assertAlmostEqual(lon, elon, places=7)
        self.assertAlmostEqual(course, 90, delta=0.5)
        self.assertAlmostEqual(locate.position_at(self.pts, 125)[2], 0, delta=0.5)

    def test_course_at_standstill_is_from_arrival(self):
        self.assertAlmostEqual(locate.position_at(self.pts, 115)[2], 90, delta=0.5)

    def test_outside_track_is_none(self):
        self.assertIsNone(locate.position_at(self.pts, 99))
        self.assertIsNone(locate.position_at(self.pts, 131))

    def test_click_to_time(self):
        lat, lon = at(63, 4)  # рядом с отрезком на восток
        self.assertAlmostEqual(locate.nearest_time(self.pts, lat, lon), 106.3, delta=0.05)

    def test_frame_time(self):
        self.assertEqual(locate.frame_time(1000.0, 12.5, 7.0), 1019.5)


class AnchoredTest(unittest.TestCase):
    """Ломаная: 1000 м на восток, затем 1000 м на север. Скорость из кадра —
    10 м/с с остановкой 20 с; опоры в 0, 1000 и 1800 м по ломаной."""

    def setUp(self):
        self.shape = [at(0, 0), at(500, 0), at(1000, 0), at(1000, 1000)]
        speed = []
        for i in range(0, 221):  # t = 0…220 с
            moving = not (100 <= i < 120)
            speed.append((float(i), 36.0 if moving else 0.0))
        self.speed = speed
        # По скорости: t=10→100 — 895 м (последняя секунда — торможение до 0),
        # t=100→200 — 805 м. Опоры по ломаной: 100 м, 1100 м, 1800 м — перегоны
        # 1000 и 700 м, т. е. невязки −105 и +105 м: опора тянет машину туда,
        # где она была на самом деле, а невязка говорит, насколько скорость врёт.
        self.anchors = [(10.0, *at(100, 3), 'камера 1'),     # 3 м сбоку от дороги
                        (100.0, *at(1000, 100), 'камера 2'),
                        (200.0, *at(1000, 800), 'камера 3')]
        self.track = locate.AnchoredTrack(self.shape, self.anchors, self.speed)

    def test_position_on_anchor_is_exact(self):
        for t, lat, lon, _ in self.anchors[1:]:
            plat, plon, _ = self.track.position(t)
            self.assertLess(gpx.haversine(plat, plon, lat, lon), 0.5)
        plat, plon, _ = self.track.position(10.0)
        self.assertLess(gpx.haversine(plat, plon, *at(100, 0)), 0.5)  # проекция опоры

    def test_monotonic_between_anchors(self):
        prev = -1.0
        for i in range(0, 2201):
            s = self.track.s_at(i / 10)
            self.assertGreaterEqual(s, prev - 1e-9)
            prev = s

    def test_stop_keeps_position(self):
        self.assertAlmostEqual(self.track.s_at(105), self.track.s_at(115), delta=1e-6)

    def test_before_first_and_after_last_follow_speed(self):
        self.assertAlmostEqual(self.track.s_at(5.0), 50.0, delta=0.5)
        self.assertAlmostEqual(self.track.s_at(210.0), 1900.0, delta=0.5)
        self.assertEqual(self.track.s_at(-100.0), 0.0)  # не уходит за начало ломаной

    def test_residuals(self):
        res = self.track.residuals()
        self.assertEqual(len(res), 2)
        self.assertAlmostEqual(res[0], -105.0, delta=1.0)  # 895 по скорости − 1000 по ломаной
        self.assertAlmostEqual(res[1], 105.0, delta=1.0)   # 805 − 700
        s = self.track.summary()
        self.assertEqual((s['anchors'], s['anchors_used']), (3, 3))
        self.assertAlmostEqual(s['residual_max_m'], 105.0, delta=1.0)
        self.assertAlmostEqual(s['residual_median_m'], 105.0, delta=1.0)
        self.assertAlmostEqual(s['anchor_offset_max_m'], 3.0, delta=0.2)

    def test_course_follows_shape(self):
        self.assertAlmostEqual(self.track.position(50)[2], 90, delta=0.5)
        self.assertAlmostEqual(self.track.position(150)[2], 0, delta=0.5)

    def test_anchor_outside_video_is_not_used(self):
        anchors = self.anchors + [(1000.0, *at(1000, 1000), 'после видео')]
        tr = locate.AnchoredTrack(self.shape, anchors, self.speed)
        self.assertEqual(tr.summary()['anchors_used'], 3)
        self.assertEqual(len(tr.residuals()), 2)

    def test_projection_is_forward_only(self):
        # Ломаная туда и обратно по одной улице: вторая опора в той же точке,
        # что и первая, должна лечь на обратный ход, а не назад к первой.
        shape = [at(0, 0), at(1000, 0), at(0, 1)]
        tr = locate.AnchoredTrack(shape, [(0.0, *at(300, 0), 'a'), (50.0, *at(800, 0), 'b'),
                                          (150.0, *at(300, 0), 'c')], self.speed)
        ss = [a['s'] for a in tr.anchors]
        self.assertEqual(ss, sorted(ss))
        self.assertAlmostEqual(ss[2], 1700, delta=2)

    def test_dense_track(self):
        dense = self.track.timed([0, 50, 150], [36, 36, 36])
        self.assertEqual(len(dense), 3)
        self.assertEqual(dense[1][3], 36)


if __name__ == '__main__':
    unittest.main()
