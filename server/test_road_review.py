"""Тесты контролёра дороги: выбор мест, разбор ответа модели, сводка."""
import math
import os
import tempfile
import unittest

import road_review

LAT, LON = 41.311, 69.28


def square(dx, dy, side):
    k = 111_320 * math.cos(math.radians(LAT))
    corners = [(dx, dy), (dx + side, dy), (dx + side, dy + side), (dx, dy + side)]
    return [(LON + x / k, LAT + y / 111_320) for x, y in corners]


class PickPlacesTests(unittest.TestCase):
    def test_largest_first_one_per_place(self):
        big = square(0, 0, 40)
        near_big = square(50, 0, 20)          # тот же район — не второе место
        far = square(2000, 0, 25)
        places = road_review.pick_places([far, near_big, big], 10)
        self.assertEqual(len(places), 2)
        self.assertAlmostEqual(places[0][1], sum(p[0] for p in big) / 4, places=6)

    def test_count_is_respected(self):
        cores = [square(1000 * i, 0, 30) for i in range(5)]
        self.assertEqual(len(road_review.pick_places(cores, 3)), 3)


class ParseReviewTests(unittest.TestCase):
    def test_known_classes_only(self):
        text = ('Вот ответ: {"defects": [{"class": "white_wedge", "severity": "major", "where": "центр"},'
                ' {"class": "придумано", "severity": "major"}]}')
        self.assertEqual(road_review.parse_review(text),
                         [{"class": "white_wedge", "severity": "major", "where": "центр"}])

    def test_unknown_severity_becomes_minor(self):
        found = road_review.parse_review('{"defects": [{"class": "spike", "severity": "ужас"}]}')
        self.assertEqual(found[0]["severity"], "minor")

    def test_garbage_is_none_not_a_crash(self):
        self.assertIsNone(road_review.parse_review("не JSON"))
        self.assertIsNone(road_review.parse_review("{сломано"))
        self.assertEqual(road_review.parse_review('{"defects": []}'), [])


class ReportTests(unittest.TestCase):
    def test_summary_counts_by_class_and_severity(self):
        results = [{"defects": [{"class": "spike", "severity": "major", "where": ""}]},
                   {"defects": [{"class": "spike", "severity": "minor", "where": ""},
                                {"class": "road_gap", "severity": "major", "where": ""}]},
                   {"defects": None}]
        self.assertEqual(road_review.summarize(results), {"spike": [1, 1], "road_gap": [1, 0]})

    def test_report_files_are_written(self):
        out = tempfile.mkdtemp()
        results = [{"lat": LAT, "lon": LON, "image": None, "defects": None}]
        road_review.write_report(out, results, {}, reviewed=False)
        self.assertTrue(os.path.exists(os.path.join(out, "report.html")))
        with open(os.path.join(out, "report.html"), encoding="utf-8") as handle:
            self.assertIn("кадр пустой", handle.read())


if __name__ == "__main__":
    unittest.main()
