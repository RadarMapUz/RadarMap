"""Тесты парковок: места по обе стороны проезда, не на проезде, не за контуром."""
import math
import unittest

import parking

LAT, LON = 41.31, 69.28
KX = 111_320 * math.cos(math.radians(LAT))


def m(dx, dy):
    return (LON + dx / KX, LAT + dy / 111_320)


class AisleTests(unittest.TestCase):
    def test_stalls_on_both_sides_of_an_aisle(self):
        lot = [m(0, 0), m(60, 0), m(60, 20), m(0, 20)]
        aisle = (m(2, 10), m(58, 10))
        stalls = parking.stall_lines(lot, None, [aisle])
        sides = {round((s[0][1] - LAT) * 111_320 - 10) > 0 for s in stalls}
        self.assertEqual(sides, {True, False})
        self.assertGreater(len(stalls), 30)

    def test_stall_never_leaves_the_lot(self):
        lot = [m(0, 0), m(60, 0), m(60, 12), m(0, 12)]
        aisle = (m(2, 6), m(58, 6))
        for a, b in parking.stall_lines(lot, None, [aisle]):
            for p in (a, b):
                self.assertTrue(-0.01 <= (p[1] - LAT) * 111_320 <= 12.01)

    def test_small_lot_without_aisles_has_no_stalls(self):
        self.assertEqual(parking.stall_lines([m(0, 0), m(10, 0), m(10, 10), m(0, 10)]), [])


if __name__ == "__main__":
    unittest.main()
