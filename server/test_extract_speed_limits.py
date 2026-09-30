#!/usr/bin/env python3
"""Разбор maxspeed и ворота публикации лимитов.

Тестов у этого файла не было вовсе — он и в репозитории-то не лежал. Здесь
проверяется то, что попадает водителю на экран цифрой лимита и суммой штрафа.
"""
import gzip
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


class RoadClassTests(unittest.TestCase):
    """Класс дороги в выгрузке: без него лимит — половина ответа."""

    def test_known_types_map_to_client_codes(self):
        # Контракт с RoadClass в RadarMap/Models/RoadShape.swift.
        self.assertEqual(sl.road_class_code("primary"), 3)
        self.assertEqual(sl.road_class_code("primary_link"), 3)
        self.assertEqual(sl.road_class_code("service"), 7)
        self.assertEqual(sl.road_class_code("living_street"), 6)

    def test_unknown_type_is_zero_not_a_crash(self):
        # Чужой тег не должен ронять месячную сборку лимитов.
        self.assertEqual(sl.road_class_code("raceway"), 0)
        self.assertEqual(sl.road_class_code(None), 0)

    def test_every_code_is_a_class_the_client_knows(self):
        self.assertTrue(set(sl.ROAD_CLASS_CODES.values()) <= set(range(1, 9)))


class PublishedFilesTests(unittest.TestCase):
    """Что раздаёт nginx с gzip_static: .gz обязан совпадать с файлом.

    С 01.09 по 27.09.2026 телефоны получали лимиты от 15 июля: скрипт обновлял
    .json, а nginx отдавал оставшийся рядом старый .gz.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.out = os.path.join(self.dir, "speed_limits.json")

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def write_both(self):
        sl.write_published(self.out, '{"v":1}')
        sl.write_published(self.out.replace(".json", "_v2.json"), '{"v":2}')

    def test_gz_is_written_with_the_file_and_matches_it(self):
        sl.write_published(self.out, '{"segments":[]}')
        with open(self.out, "rb") as f, open(self.out + ".gz", "rb") as g:
            self.assertEqual(gzip.decompress(g.read()), f.read())
        self.assertFalse(os.path.exists(self.out + ".tmp"))
        self.assertFalse(os.path.exists(self.out + ".gz.tmp"))

    def test_rewrite_replaces_a_stale_gz(self):
        with open(self.out + ".gz", "wb") as g:
            g.write(gzip.compress(b'{"july":true}'))
        sl.write_published(self.out, '{"september":true}')
        with open(self.out + ".gz", "rb") as g:
            self.assertEqual(gzip.decompress(g.read()), b'{"september":true}')

    def test_fresh_when_everything_matches(self):
        self.write_both()
        self.assertTrue(sl.companions_fresh(self.out))

    def test_stale_gz_is_not_fresh(self):
        # Ровно боевой случай: сегменты те же, хэш тот же, а .gz — июльский.
        self.write_both()
        with open(self.out + ".gz", "wb") as g:
            g.write(gzip.compress(b'{"july":true}'))
        self.assertFalse(sl.companions_fresh(self.out))

    def test_missing_v2_is_not_fresh(self):
        # Второй боевой случай: v2 на проде не выкладывался ни разу (404).
        sl.write_published(self.out, '{"v":1}')
        self.assertFalse(sl.companions_fresh(self.out))

    def test_missing_gz_is_not_fresh(self):
        self.write_both()
        os.unlink(self.out + ".gz")
        self.assertFalse(sl.companions_fresh(self.out))

class MainRoadFloorTests(unittest.TestCase):
    def test_main_roads_below_sixty_are_raised(self):
        # «В городе радары все 60»: 50 на проспекте — это не знак у камеры.
        segments = [[50, 3, []], [40, 5, []], [30, 2, []], [80, 3, []], [60, 4, []]]
        self.assertEqual(sl.floor_main_roads(segments), 3)
        self.assertEqual([s[0] for s in segments], [60, 60, 60, 80, 60])

    def test_yards_and_service_roads_keep_their_signs(self):
        # 20 у школы и 5 на парковке — настоящие знаки, камер там нет.
        segments = [[20, 6, []], [40, 6, []], [5, 7, []], [30, 8, []]]
        self.assertEqual(sl.floor_main_roads(segments), 0)
        self.assertEqual([s[0] for s in segments], [20, 40, 5, 30])


if __name__ == "__main__":
    unittest.main(verbosity=1)
