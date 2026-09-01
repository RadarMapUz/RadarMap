#!/usr/bin/env python3
"""Разбор maxspeed и ворота публикации лимитов.

Тестов у этого файла не было вовсе — он и в репозитории-то не лежал. Здесь
проверяется то, что попадает водителю на экран цифрой лимита и суммой штрафа.
"""
import json
import os
import tempfile
import unittest

import extract_speed_limits as sl


class ParseLimitTest(unittest.TestCase):
    def test_plain_number(self):
        self.assertEqual(sl.parse_limit("70"), 70)

    def test_with_units(self):
        self.assertEqual(sl.parse_limit("70 km/h"), 70)

    def test_first_of_a_list(self):
        # "50;30" — сезонное ограничение; берём первое, оно основное.
        self.assertEqual(sl.parse_limit("50;30"), 50)

    def test_miles_are_skipped(self):
        # Мили в Узбекистане не встречаются, но встречаются в чужих правках,
        # и молча превратить 50 mph в 50 км/ч значит занизить лимит на треть.
        self.assertIsNone(sl.parse_limit("50 mph"))

    def test_words_are_skipped(self):
        for word in ("none", "signals", "walk", "RU:urban", ""):
            self.assertIsNone(sl.parse_limit(word), word)

    def test_absurd_values_are_skipped(self):
        # Опечатка в OSM («130» → «1300») не должна отключить превышение на
        # целой дороге.
        self.assertIsNone(sl.parse_limit("1300"))
        self.assertIsNone(sl.parse_limit("3"))
        self.assertEqual(sl.parse_limit("130"), 130)


class GateTest(unittest.TestCase):
    def test_normal_month_passes(self):
        allowed, _why = sl.decide(21558, 21700)
        self.assertTrue(allowed)

    def test_truncated_extract_is_refused(self):
        # Главный сценарий, ради которого ворота и стоят: выгрузка приехала
        # обрезанной, файл собрался успешно и выглядит обычным — просто меньше.
        allowed, why = sl.decide(21558, 9000)
        self.assertFalse(allowed)
        self.assertIn("не бывает", why)

    def test_absurdly_small_is_refused_even_without_history(self):
        allowed, _why = sl.decide(0, 100)
        self.assertFalse(allowed)

    def test_first_build_passes(self):
        allowed, _why = sl.decide(0, 21558)
        self.assertTrue(allowed)

    def test_growth_is_capped_too(self):
        # Удвоение так же неправдоподобно, как и потеря половины: скорее всего
        # сменился фильтр, а не страна.
        allowed, _why = sl.decide(21558, 50000)
        self.assertFalse(allowed)


class PreviousCountTest(unittest.TestCase):
    def test_reads_existing_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"version": 1, "segments": [[60, [41.0, 69.0, 41.1, 69.1]]]}, f)
            path = f.name
        try:
            self.assertEqual(sl.previous_count(path), 1)
        finally:
            os.unlink(path)

    def test_missing_file_is_zero_not_a_crash(self):
        self.assertEqual(sl.previous_count("/nonexistent/limits.json"), 0)

    def test_broken_file_is_zero_not_a_crash(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{битый")
            path = f.name
        try:
            self.assertEqual(sl.previous_count(path), 0)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
