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


class LaneArrowTests(unittest.TestCase):
    """Стрелка — посередине своей полосы между линиями разметки (снимок владельца 23.10.2026)."""

    def setUp(self):
        # Односторонняя лента на восток, три полосы по 3,5 м, линии на ±1,75 м.
        road = ([m(-60, 0), m(60, 0)], {"cls": 3, "width": 10.5, "oneway": True})
        lines = [([m(-60, y), m(60, y)], {"verified": True}) for y in (-1.75, 1.75)]
        self.roads, self.lines = rm.lane_index([road], lines)

    def check(self, dy, lw=3.5):
        lon, lat = m(0, dy)
        return rm.arrow_in_lane((lon, lat, 90, lw), self.roads, self.lines)

    def test_arrow_in_lane_middle_is_fine(self):
        self.assertIsNone(self.check(0.0))
        self.assertIsNone(self.check(3.5))     # левая полоса (север — слева по ходу на восток)

    def test_arrow_on_lane_line_is_caught(self):
        self.assertEqual(self.check(1.6)[0], "off_centre")

    def test_arrow_past_kerb_is_caught(self):
        self.assertEqual(self.check(6.5)[0], "off_road")

    def test_icon_wider_than_lane_is_caught(self):
        self.assertEqual(self.check(0.0, lw=5.3)[0], "icon_size")

    def test_arrow_off_any_road(self):
        self.assertEqual(self.check(30.0)[0], "no_road")

    def test_two_way_arrows_live_on_the_right_half(self):
        road = ([m(-60, 0), m(60, 0)], {"cls": 5, "width": 7.0})
        roads, lines = rm.lane_index([road], [([m(-60, 0), m(60, 0)], {"centre": 1})])
        lon, lat = m(0, -1.75)                  # правая половина при езде на восток
        self.assertIsNone(rm.arrow_in_lane((lon, lat, 90, 3.5), roads, lines))
        lon, lat = m(0, 1.75)                   # встречная половина
        self.assertEqual(rm.arrow_in_lane((lon, lat, 90, 3.5), roads, lines)[0], "off_road")

    def test_counts_by_kind(self):
        arrows = [(*m(0, 0), 90, 3.5), (*m(0, 1.6), 90, 3.5)]
        self.assertEqual(rm.lane_arrow_defects(arrows, self.roads, self.lines), {"off_centre": 1})


class MarkingsOffRoadTests(unittest.TestCase):
    def test_line_inside_ribbon_is_fine(self):
        road = ([m(-60, 0), m(60, 0)], {"cls": 3, "width": 10.5, "oneway": True})
        roads, _ = rm.lane_index([road], [])
        self.assertEqual(rm.markings_off_road([([m(-50, 1.75), m(50, 1.75)], {})], roads, None), 0.0)

    def test_line_past_kerb_is_measured(self):
        road = ([m(-60, 0), m(60, 0)], {"cls": 3, "width": 10.5, "oneway": True})
        roads, _ = rm.lane_index([road], [])
        self.assertAlmostEqual(rm.markings_off_road([([m(-50, 6.5), m(50, 6.5)], {})], roads, None),
                               1000.0, delta=30)


class ArrowAngleTests(unittest.TestCase):
    def setUp(self):
        road = ([m(-60, 0), m(60, 0)], {"cls": 3, "width": 10.5, "oneway": True})
        self.roads, _ = rm.lane_index([road], [])

    def test_arrow_along_the_ribbon(self):
        self.assertAlmostEqual(rm.arrow_axis_angle((*m(0, 0), 90), self.roads), 0.0, delta=0.1)

    def test_tilted_arrow_is_measured(self):
        self.assertAlmostEqual(rm.arrow_axis_angle((*m(0, 0), 95), self.roads), 5.0, delta=0.1)

    def test_ceiling_stops_publish_even_if_it_was_as_bad(self):
        self.assertTrue(rm.compare({"arrows_angle_max": 5.0}, {"arrows_angle_max": 5.0}))
        self.assertFalse(rm.compare({"arrows_angle_max": 1.0}, {"arrows_angle_max": 1.5}))


class MarkingJumpTests(unittest.TestCase):
    def test_line_continued_sideways_is_a_jump(self):
        lines = [([m(-50, 1.75), m(0, 1.75)], {}), ([m(0.5, 3.0), m(50, 3.0)], {})]
        rate, worst = rm.marking_jumps(lines)
        self.assertGreater(rate, 0)
        self.assertAlmostEqual(worst, 1.25, delta=0.05)

    def test_straight_continuation_is_not(self):
        lines = [([m(-50, 1.75), m(0, 1.75)], {}), ([m(0.5, 1.75), m(50, 1.75)], {})]
        self.assertEqual(rm.marking_jumps(lines), (0.0, 0.0))

    def test_neighbouring_lanes_side_by_side_are_not(self):
        lines = [([m(-50, 0), m(50, 0)], {}), ([m(-50, 3.5), m(50, 3.5)], {})]
        self.assertEqual(rm.marking_jumps(lines)[0], 0.0)


class JunctionColourTests(unittest.TestCase):
    def setUp(self):
        self.roads = [([m(-80, 0), m(80, 0)], {"cls": 2, "width": 14.0}),
                      ([m(0, -80), m(0, 80)], {"cls": 6, "width": 6.0})]
        self.ring = square(-8, -8, 8, 8)

    def test_trunk_junction_in_trunk_colour_is_fine(self):
        self.assertEqual(rm.junction_colour_mismatch([(self.ring, {"kind": 8, "cls": 2})], self.roads), 0.0)

    def test_unclassed_junction_on_a_trunk_is_a_patch(self):
        trunk_only = [self.roads[0], ([m(0, -80), m(0, 80)], {"cls": 2, "width": 14.0})]
        self.assertEqual(rm.junction_colour_mismatch([(self.ring, {"kind": 8})], trunk_only), 100.0)

    def test_mixed_junction_is_not_judged(self):
        self.assertEqual(rm.junction_colour_mismatch([(self.ring, {"kind": 8})], self.roads), 0.0)

    def test_trunk_coloured_blot_on_white_streets(self):
        white = [([m(-80, 0), m(80, 0)], {"cls": 4, "width": 14.0}),
                 ([m(0, -80), m(0, 80)], {"cls": 4, "width": 14.0})]
        examples = []
        self.assertEqual(rm.junction_colour_blots([(self.ring, {"kind": 8, "cls": 2})], white, examples), 1)
        self.assertEqual(len(examples), 1)
        self.assertEqual(rm.junction_colour_blots([(self.ring, {"kind": 8, "cls": 4})], white), 0)


class BridgeSeamTests(unittest.TestCase):
    def test_two_bridge_pieces_end_to_end_make_a_seam(self):
        roads = [([m(-50, 0), m(0, 0)], {"bridge": True}), ([m(0, 0), m(50, 0)], {"bridge": True})]
        self.assertAlmostEqual(rm.bridge_seams(roads), 10.0, delta=0.5)

    def test_one_line_bridge_has_none(self):
        self.assertEqual(rm.bridge_seams([([m(-50, 0), m(50, 0)], {"bridge": True})]), 0.0)


class UnmarkedAvenueTests(unittest.TestCase):
    def test_avenue_without_lines_is_measured(self):
        road = ([m(-60, 0), m(60, 0)], {"cls": 3, "width": 10.5, "oneway": True})
        roads, lines = rm.lane_index([road], [])
        self.assertEqual(rm.unmarked_avenues([road], lines), 100.0)
        roads, lines = rm.lane_index([road], [([m(-60, 1.75), m(60, 1.75)], {"verified": True})])
        self.assertEqual(rm.unmarked_avenues([road], lines), 0.0)


class ZebraStepMetricTests(unittest.TestCase):
    def test_side_by_side_zebras_shifted_along_are_a_step(self):
        # Проспект на восток, две ленты: зебры поперёк (по долготе 0 и 5 м).
        zebras = [[m(0, 1), m(0, 8)], [m(5, -8), m(5, -1)]]
        self.assertEqual(rm.zebra_steps(zebras), 100.0)

    def test_aligned_or_consecutive_zebras_are_fine(self):
        self.assertEqual(rm.zebra_steps([[m(0, 1), m(0, 8)], [m(0, -8), m(0, -1)]]), 0.0)
        self.assertEqual(rm.zebra_steps([[m(0, -3), m(0, 3)], [m(8, -3), m(8, 3)]]), 0.0)


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
