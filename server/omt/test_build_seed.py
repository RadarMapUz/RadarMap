#!/usr/bin/env python3
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_seed  # noqa: E402


class SeedSelection(unittest.TestCase):
    def test_country_is_whole_up_to_nine(self):
        self.assertTrue(build_seed.wanted(9, 0, 0))
        self.assertTrue(build_seed.wanted(5, 31, 11))

    def test_city_zooms_only_inside_tashkent(self):
        x0, y0, x1, y1 = build_seed.tile_range(build_seed.CITY_BBOX, 12)
        self.assertTrue(build_seed.wanted(12, x0, y0))
        self.assertTrue(build_seed.wanted(12, x1, y1))
        self.assertFalse(build_seed.wanted(12, x1 + 1, y0))
        # Самарканд на z11 — не Ташкент.
        sx, sy, _, _ = build_seed.tile_range((66.97, 39.65, 66.98, 39.66), 11)
        self.assertFalse(build_seed.wanted(11, sx, sy))

    def test_nothing_above_city_zooms(self):
        x0, y0, _, _ = build_seed.tile_range(build_seed.CITY_BBOX, 13)
        self.assertFalse(build_seed.wanted(13, x0, y0))

    def test_tile_range_covers_centre(self):
        # Центр Ташкента (41,31; 69,28) на z10 — тайл x 708, y 382 (сетка XYZ).
        x0, y0, x1, y1 = build_seed.tile_range(build_seed.CITY_BBOX, 10)
        self.assertTrue(x0 <= 708 <= x1 and y0 <= 382 <= y1)

    def test_select_reads_tms_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = sqlite3.connect(os.path.join(tmp, "t.mbtiles"))
            db.execute("CREATE TABLE tiles (zoom_level, tile_column, tile_row, tile_data)")
            x0, y0, _, _ = build_seed.tile_range(build_seed.CITY_BBOX, 12)
            db.execute("INSERT INTO tiles VALUES (12, ?, ?, ?)", (x0, (1 << 12) - 1 - y0, b"a"))
            db.execute("INSERT INTO tiles VALUES (13, ?, ?, ?)", (x0 * 2, 0, b"b"))
            tiles = build_seed.select(db)
            self.assertEqual(tiles, {(12, x0, y0): b"a"})


if __name__ == "__main__":
    unittest.main()
