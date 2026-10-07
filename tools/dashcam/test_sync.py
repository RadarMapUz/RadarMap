#!/usr/bin/env python3
"""Тесты синхронизации часов регистратора с треком по скорости.

Главное: синтетика со сдвигом 7 с находится как 7 ± 1, на шумной скорости
тоже; нет общих данных — честное None, а не «сдвиг 0»; пик на краю сетки —
не годится.
"""
import random
import unittest

import sync


def drive(seconds=1800, seed=3):
    """Городская езда: разгоны, крейсер, остановки у светофоров (ступеньки)."""
    rnd = random.Random(seed)
    v, out, t = 0.0, [], 0
    target, hold = 50.0, 60
    while t < seconds:
        if hold <= 0:
            target = rnd.choice([0, 0, 25, 40, 55, 70])
            hold = rnd.randint(20, 90)
        v += max(-8.0, min(4.0, target - v))
        v = max(0.0, v)
        out.append((1_791_340_000 + t, round(v)))
        hold -= 1
        t += 1
    return out


class SyncTest(unittest.TestCase):
    def test_finds_seven_seconds(self):
        ocr = drive()
        track = [(t + 7, v) for t, v in ocr]
        res = sync.find_offset(ocr, track)
        self.assertAlmostEqual(res['offset'], 7, delta=1)
        self.assertTrue(res['good'])
        self.assertGreater(res['quality'], 0.99)

    def test_negative_shift_noise_and_misreads(self):
        rnd = random.Random(5)
        truth = drive(seed=8)
        # OCR: 6 % кадров не прочиталось, 2 % — «146» вместо «46»
        ocr = []
        for t, v in truth:
            r = rnd.random()
            if r < 0.06:
                continue
            ocr.append((t, v + 100 if r < 0.08 and 40 <= v < 60 else v))
        # трек: пятая часть точек выпала, скорость с шумом GPS
        track = [(t - 23.4, max(0.0, v + rnd.gauss(0, 1.5)))
                 for t, v in truth if rnd.random() < 0.8]
        res = sync.find_offset(ocr, track)
        self.assertAlmostEqual(res['offset'], -23.4, delta=1)
        self.assertTrue(res['good'])

    def test_no_overlap_is_none(self):
        ocr = drive(600)
        track = [(t + 10_000, v) for t, v in ocr]
        self.assertIsNone(sync.find_offset(ocr, track))

    def test_standing_still_has_no_correlation(self):
        ocr = [(1000 + i, 0) for i in range(600)]
        self.assertIsNone(sync.find_offset(ocr, list(ocr)))

    def test_shift_beyond_window_is_not_good(self):
        ocr = drive(1200)
        track = [(t + 200, v) for t, v in ocr]  # дальше сетки ±120
        res = sync.find_offset(ocr, track)
        self.assertTrue(res is None or not res['good'])

    def test_series_gap_is_not_interpolated(self):
        s = sync.Series([(0, 10), (1, 20), (20, 40)])
        self.assertAlmostEqual(s.at(0.5), 15)
        self.assertIsNone(s.at(10))
        self.assertIsNone(s.at(-1))

    def test_pearson(self):
        self.assertAlmostEqual(sync.pearson([1, 2, 3], [2, 4, 6]), 1.0)
        self.assertAlmostEqual(sync.pearson([1, 2, 3], [3, 2, 1]), -1.0)
        self.assertIsNone(sync.pearson([1, 1, 1], [1, 2, 3]))

    def test_anchor_quality_threshold(self):
        ok = {'anchors_used': 5, 'residual_median_m': 40.0}
        self.assertTrue(sync.anchors_quality(ok))
        self.assertFalse(sync.anchors_quality({**ok, 'anchors_used': 1}))
        self.assertFalse(sync.anchors_quality({**ok, 'residual_median_m': sync.ANCHOR_GOOD_M + 1}))


if __name__ == '__main__':
    unittest.main()
