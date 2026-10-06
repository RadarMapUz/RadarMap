"""Тесты очереди перекрёстков: светофоры склеиваются, недостача считается честно."""
import math
import unittest

import junction_worklist as jw

LAT, LON = 41.31, 69.28
KX = 111_320 * math.cos(math.radians(LAT))


def m(dx, dy):
    return (LON + dx / KX, LAT + dy / 111_320)


class ClusterTests(unittest.TestCase):
    def test_signals_of_one_junction_are_one(self):
        clusters = jw.cluster_signals([m(0, 0), m(20, 5), m(-15, 10), m(300, 0)])
        self.assertEqual(sorted(n for _c, n in clusters), [1, 3])


class AssessTests(unittest.TestCase):
    def test_untagged_primary_crossing_is_listed(self):
        ways = [("primary", {"name": "Беруни"}, [m(-100, 0), m(100, 0)]),
                ("secondary", {"name": "Сакичмон"}, [m(0, -100), m(0, 100)])]
        result = jw.assess(m(0, 0), ways, [])
        self.assertEqual(result["weight"], 7)
        self.assertEqual(len(result["missing"]), 3)
        self.assertEqual(result["names"], ["Беруни", "Сакичмон"])

    def test_fully_tagged_junction_has_nothing_missing(self):
        tags = {"lanes": "3", "turn:lanes": "left|through|right"}
        ways = [("primary", tags, [m(-100, 0), m(100, 0)])]
        result = jw.assess(m(0, 0), ways, [m(10, 0), m(-10, 0)])
        self.assertEqual(result["missing"], [])

    def test_far_roads_do_not_count(self):
        self.assertIsNone(jw.assess(m(0, 0), [("primary", {}, [m(200, 200), m(300, 300)])], []))


if __name__ == "__main__":
    unittest.main()
