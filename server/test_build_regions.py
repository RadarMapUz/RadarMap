"""Нарезка офлайн-регионов: каждая клетка — ровно в одном регионе, город не теряется."""

import unittest

import build_regions as br


def square(west, south, east, north):
    return {"type": "Polygon", "coordinates": [[[west, south], [east, south], [east, north],
                                               [west, north], [west, south]]]}


def cell_at(lon, lat):
    import math
    n = 1 << br.CELL_ZOOM
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


class GeometryTests(unittest.TestCase):
    def test_point_in_polygon_with_hole(self):
        ring = square(0, 0, 10, 10)["coordinates"][0]
        hole = square(4, 4, 6, 6)["coordinates"][0]
        geometry = {"type": "Polygon", "coordinates": [ring, hole]}
        self.assertTrue(br.in_geometry(1, 1, geometry))
        self.assertFalse(br.in_geometry(5, 5, geometry))
        self.assertFalse(br.in_geometry(11, 5, geometry))

    def test_multipolygon(self):
        geometry = {"type": "MultiPolygon", "coordinates": [square(0, 0, 1, 1)["coordinates"],
                                                             square(5, 5, 6, 6)["coordinates"]]}
        self.assertTrue(br.in_geometry(5.5, 5.5, geometry))


class AssignTests(unittest.TestCase):
    def test_city_inside_province_keeps_its_own_cells(self):
        # Город раньше области в порядке кодов и лежит внутри её рамки — его
        # клетки обязаны остаться за городом (так пропадал Ташкент на z10).
        regions = {"UZ-TK": {"geometry": square(69.15, 41.2, 69.4, 41.4)},
                   "UZ-TO": {"geometry": square(68.6, 40.7, 70.9, 41.95)}}
        city = cell_at(69.27, 41.31)
        province = cell_at(70.5, 41.0)
        owner = br.assign_cells({city, province}, regions)
        self.assertEqual(owner[city], "UZ-TK")
        self.assertEqual(owner[province], "UZ-TO")

    def test_fallback_box_takes_only_unclaimed_cells(self):
        regions = {"UZ-AN": {"geometry": square(72.0, 40.4, 73.2, 41.0)}}
        fergana = cell_at(71.78, 40.38)
        andijan = cell_at(72.34, 40.78)
        owner = br.assign_cells({fergana, andijan}, regions)
        self.assertEqual(owner[fergana], "UZ-FA")
        self.assertEqual(owner[andijan], "UZ-AN")

    def test_fringe_goes_to_neighbour_far_cells_are_dropped(self):
        regions = {"UZ-SA": {"geometry": square(66.0, 39.0, 67.5, 40.0)}}
        inside = cell_at(66.9, 39.6)
        edge = cell_at(67.45, 39.6)
        fringe = (edge[0] + 3, edge[1])
        far = (inside[0] + 400, inside[1])
        owner = br.assign_cells({inside, edge, fringe, far}, regions)
        self.assertEqual(owner[fringe], "UZ-SA")
        self.assertNotIn(far, owner)

    def test_every_cell_has_at_most_one_owner(self):
        regions = {"A": {"geometry": square(60, 40, 61, 41)}, "B": {"geometry": square(60.5, 40, 62, 41)}}
        cells = {cell_at(60 + i * 0.05, 40.5) for i in range(40)}
        owner = br.assign_cells(cells, regions)
        self.assertTrue(set(owner) <= cells)


class RowsTests(unittest.TestCase):
    def test_rows_roundtrip(self):
        cells = {(5, 1), (6, 1), (7, 1), (9, 1), (5, 2)}
        rows = br.cell_rows(cells)
        self.assertEqual(rows, [[1, 5, 7], [1, 9, 9], [2, 5, 5]])
        back = {(x, y) for y, a, b in rows for x in range(a, b + 1)}
        self.assertEqual(back, cells)


class TileTests(unittest.TestCase):
    def test_cell_of_and_ancestors(self):
        z = br.CELL_ZOOM
        self.assertEqual(br.cell_of(15, 22686, 12246), (22686 >> (15 - z), 12246 >> (15 - z)))
        self.assertIsNone(br.cell_of(z - 1, 0, 0))
        low = br.ancestors({(2835, 1530)})
        self.assertIn((0, 0, 0), low)
        self.assertIn((z - 1, 2835 >> 1, 1530 >> 1), low)
        self.assertEqual(len(low), z)


if __name__ == "__main__":
    unittest.main()
