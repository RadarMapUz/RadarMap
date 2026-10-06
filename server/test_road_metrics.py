"""Тесты метрик качества дороги: каждая метрика ловит свой дефект и молчит без него."""
import math
import unittest

import road_metrics as rm

LAT, LON = 41.311, 69.28
KX = 111_320 * math.cos(math.radians(LAT))


def m(dx, dy):
    return (LON + dx / KX, LAT + dy / 111_320)


def square(x0, y0, x1, y1):
    return [m(x0, y0), m(x1, y0), m(x1, y1), m(x0, y1)]


class ShareTests(unittest.TestCase):
    def test_house_half_under_asphalt(self):
        house = square(0, 0, 10, 10)
        asphalt = rm.PolygonIndex([square(-50, -50, 5, 50)])
        self.assertAlmostEqual(rm.share_under([house], asphalt), 0.5, delta=0.1)

    def test_house_clear_of_asphalt(self):
        self.assertEqual(rm.share_under([square(0, 0, 10, 10)], rm.PolygonIndex([square(20, 0, 30, 10)])), 0.0)


class ArrowTests(unittest.TestCase):
    def test_arrow_after_stop_line_is_caught(self):
        # Едем на восток; стоп-линия в 10 м ПОЗАДИ ряда стрелок — брак.
        stop = [m(-10, -5), m(-10, 5)]
        self.assertEqual(rm.arrows_after_stop([(LON, LAT, 90)], [stop]), 1.0)

    def test_arrow_before_stop_line_is_fine(self):
        stop = [m(10, -5), m(10, 5)]
        self.assertEqual(rm.arrows_after_stop([(LON, LAT, 90)], [stop]), 0.0)


class DashTests(unittest.TestCase):
    def test_dashes_inside_a_junction_are_measured(self):
        line = [m(0, 0), m(100, 0)]
        junction = rm.PolygonIndex([square(40, -5, 60, 5)])
        per_km, total = rm.dashes_inside([line], junction.covers)
        self.assertAlmostEqual(total, 100, delta=4)
        self.assertAlmostEqual(per_km, 200, delta=40)

    def test_dashes_near_zebra(self):
        line = [m(0, 0), m(100, 0)]
        zebra = rm.SegmentIndex([[m(50, -5), m(50, 5)]])
        per_km, _ = rm.dashes_inside([line], lambda p: zebra.near(p, 2.0))
        self.assertGreater(per_km, 0)
        self.assertLess(per_km, 80)


class MedianTests(unittest.TestCase):
    def test_median_on_asphalt_is_caught(self):
        median = square(0, -1, 50, 1)
        asphalt = rm.PolygonIndex([square(-10, -10, 60, 10)])
        self.assertEqual(rm.medians_on_asphalt([median], asphalt), 1.0)

    def test_median_between_carriageways_is_fine(self):
        median = square(0, -1, 50, 1)
        asphalt = rm.PolygonIndex([square(-10, 1.2, 60, 10), square(-10, -10, 60, -1.2)])
        self.assertEqual(rm.medians_on_asphalt([median], asphalt), 0.0)


class ShapeTests(unittest.TestCase):
    def test_needle_is_a_spike(self):
        needle = [m(0, 0), m(30, 1), m(0, 2)]
        self.assertTrue(rm.spiky(needle))
        self.assertTrue(rm.thin(needle))

    def test_square_island_is_neither(self):
        self.assertFalse(rm.spiky(square(0, 0, 10, 10)))
        self.assertFalse(rm.thin(square(0, 0, 10, 10)))


class CompareTests(unittest.TestCase):
    def test_worse_metric_stops_publish(self):
        reasons = rm.compare({"dashes_in_junction": 45.0}, {"dashes_in_junction": 80.0})
        self.assertEqual(len(reasons), 1)

    def test_small_noise_does_not(self):
        self.assertEqual(rm.compare({"dashes_on_zebra": 0.0}, {"dashes_on_zebra": 1.5}), [])
        self.assertEqual(rm.compare({"dashes_in_junction": 45.0}, {"dashes_in_junction": 50.0}), [])

    def test_better_is_fine(self):
        self.assertEqual(rm.compare({"medians_on_asphalt": 12.6}, {"medians_on_asphalt": 4.8}), [])


if __name__ == "__main__":
    unittest.main()
