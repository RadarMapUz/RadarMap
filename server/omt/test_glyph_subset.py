"""Подмножество шрифтов: узбекская латиница и кириллица обязаны быть покрыты."""

import os
import tempfile
import unittest

import glyph_subset as gs


class CoverageTests(unittest.TestCase):
    def test_uzbek_latin_and_cyrillic_are_covered(self):
        for name in ("Oʻzbekiston koʻchasi", "Gʻafur Gʻulom", "Ўзбекистон кўчаси",
                     "Қорақалпоғистон", "Ҳамза", "Navoiy ‘Bunyodkor’ – 5", "Maktab № 5"):
            self.assertEqual(gs.uncovered([name]), {}, name)

    def test_arabic_is_reported_not_silently_dropped(self):
        self.assertIn("ا", gs.uncovered(["مسجد ا"]))


class ExportTests(unittest.TestCase):
    def test_missing_range_fails_loudly(self):
        with tempfile.TemporaryDirectory() as glyphs, tempfile.TemporaryDirectory() as out:
            os.makedirs(os.path.join(glyphs, gs.FONTS[0]))
            with self.assertRaises(FileNotFoundError):
                gs.export(glyphs, out)

    def test_exports_every_font_and_range(self):
        with tempfile.TemporaryDirectory() as glyphs, tempfile.TemporaryDirectory() as out:
            for font in gs.FONTS:
                os.makedirs(os.path.join(glyphs, font))
                for start, end in gs.RANGES:
                    with open(os.path.join(glyphs, font, gs.range_name(start, end)), "wb") as handle:
                        handle.write(b"x" * 10)
            self.assertEqual(gs.export(glyphs, out), 10 * len(gs.FONTS) * len(gs.RANGES))
            for font in gs.FONTS:
                self.assertEqual(len(os.listdir(os.path.join(out, font))), len(gs.RANGES))


if __name__ == "__main__":
    unittest.main()
