#!/usr/bin/env python3
"""Выборочное принятие результата снапа.

Инструмент существует ради одного правила: камеры ниже порога не меняются
вообще. snap_cameras.py пересчитывает профиль всей базе, и на прогоне
01.09.2026 шесть старых камер повернули ось ровно на 90° — то есть уехали на
поперечную улицу. При cameraAxisMaxAngle 55° такая камера перестаёт считаться
«нашей дорогой» и замолкает, а молчание о настоящей камере — худший исход.
"""
import unittest

import adopt_snap


def cam(ident, **extra):
    base = {"id": ident, "region": "R", "city": "C", "location": "L",
            "lat": 41.0, "lon": 69.0, "type": "Стационар радар"}
    base.update(extra)
    return base


class AdoptTest(unittest.TestCase):
    def test_old_cameras_are_untouched_even_when_snap_changed_them(self):
        base = [cam(1, axis=38, cls="trunk")]
        # Снап развернул камеру на 90° и пересадил во двор — ровно тот случай,
        # ради которого инструмент и написан.
        snapped = [cam(1, axis=128, cls="living_street", lat=41.001)]
        result, touched = adopt_snap.adopt(base, snapped, from_id=3504)
        self.assertEqual(touched, 0)
        self.assertEqual(result[0], base[0])

    def test_new_camera_gets_the_profile(self):
        base = [cam(3504)]
        snapped = [cam(3504, axis=90, dir=180, split=False, cls="primary",
                       road=[1, 2, 3, 4], lat=41.0005, lon=69.0005)]
        result, touched = adopt_snap.adopt(base, snapped, from_id=3504)
        self.assertEqual(touched, 1)
        self.assertEqual(result[0]["axis"], 90)
        self.assertEqual(result[0]["cls"], "primary")
        self.assertEqual(result[0]["road"], [1, 2, 3, 4])
        self.assertEqual(result[0]["lat"], 41.0005, "координата обязана сесть на ось")

    def test_identity_and_human_fields_stay_from_the_base(self):
        # Снап не распоряжается ни адресом, ни типом: он знает про дороги, а не
        # про реестр. Если он их поменял — это его ошибка, а не новость.
        base = [cam(3504, location="Правильный адрес", type="Стационар камера")]
        snapped = [cam(3504, axis=10, location="ЧУШЬ", type="Квадрокоптер")]
        result, _ = adopt_snap.adopt(base, snapped, from_id=3504)
        self.assertEqual(result[0]["location"], "Правильный адрес")
        self.assertEqual(result[0]["type"], "Стационар камера")

    def test_review_flag_follows_the_snap(self):
        base = [cam(3504, needsReview=True)]
        snapped = [cam(3504, axis=10)]          # снап пометку снял
        result, _ = adopt_snap.adopt(base, snapped, from_id=3504)
        self.assertNotIn("needsReview", result[0])

    def test_camera_absent_from_the_snap_is_left_alone(self):
        base = [cam(3504, needsReview=True)]
        result, touched = adopt_snap.adopt(base, [], from_id=3504)
        self.assertEqual(touched, 0)
        self.assertTrue(result[0]["needsReview"])


class VerifyTest(unittest.TestCase):
    def test_untouched_below_threshold_passes(self):
        base = [cam(1, axis=38), cam(3504)]
        snapped = [cam(1, axis=128), cam(3504, axis=90)]
        result, _ = adopt_snap.adopt(base, snapped, from_id=3504)
        ok, _why = adopt_snap.verify(base, result, 3504)
        self.assertTrue(ok)

    def test_change_below_threshold_is_caught(self):
        base = [cam(1, axis=38)]
        sneaked = [cam(1, axis=128)]
        ok, why = adopt_snap.verify(base, sneaked, 3504)
        self.assertFalse(ok)
        self.assertIn("ниже порога", why)

    def test_losing_a_camera_is_caught(self):
        ok, why = adopt_snap.verify([cam(1), cam(2)], [cam(1)], 3504)
        self.assertFalse(ok)
        self.assertIn("число камер", why)

    def test_reordering_is_caught(self):
        ok, why = adopt_snap.verify([cam(1), cam(2)], [cam(2), cam(1)], 3504)
        self.assertFalse(ok)
        self.assertIn("порядок", why)


if __name__ == "__main__":
    unittest.main()
