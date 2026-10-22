"""Варианты палитры карты (27.C) — под замером, как PaletteTests приложения.

Каждый вариант обязан пройти правила плана: камеры заметнее всего, линия
маршрута держится на любом асфальте, пробка ≠ маршрут ≠ камера, зелень, вода
и дома тише дорог, подписи читаются, при дейтеранопии ничего не сливается.
Копия цветов приложения в palette_check сверяется с исходниками на Swift.
"""
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_style  # noqa: E402
import palette_check  # noqa: E402

ROOT = os.path.join(HERE, "..", "..")


def _swift(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


class VariantRules(unittest.TestCase):

    def test_every_variant_passes_every_rule(self):
        for variant in make_style.PALETTE_VARIANTS:
            for theme in ("light", "dark"):
                _, failures = palette_check.measure(theme, variant)
                self.assertEqual(failures, [], f"{variant}/{theme}")

    def test_formulas_match_known_values(self):
        # Чёрный на белом — 21:1, одинаковые цвета — 1:1 и ΔE 0.
        self.assertAlmostEqual(palette_check.contrast("#000000", "#ffffff"), 21, places=3)
        self.assertAlmostEqual(palette_check.contrast("#777777", "#777777"), 1)
        self.assertAlmostEqual(palette_check.delta_e("#2a6ff0", "#2a6ff0"), 0)
        # Красный и зелёный при дейтеранопии ближе, чем при обычном зрении.
        self.assertLess(palette_check.delta_e("#d93025", "#2ba84a", True),
                        palette_check.delta_e("#d93025", "#2ba84a"))

    def test_camera_rule_catches_a_camera_lost_on_the_road(self):
        # Жёлтый радар на светло-жёлтой земле: белое кольцо светлую землю не
        # отделяет, цвет тот же — не виден ни яркостью, ни цветом.
        self.assertFalse(palette_check._camera_visible("#f2b200", "#f0c020"))
        self.assertTrue(palette_check._camera_visible("#d93025", "#b4bccb"))


class AppColoursInSync(unittest.TestCase):
    """Копия цветов приложения не расходится с Theme.swift и EngineMapView."""

    def test_route_and_traffic(self):
        theme = _swift("RadarMap/DesignSystem/Theme.swift")
        pairs = dict(re.findall(r"static let (\w+): Pair = \((0x[0-9A-Fa-f]{6}, 0x[0-9A-Fa-f]{6})\)", theme))

        def pair(name):
            day, night = pairs[name].split(", ")
            return {"light": "#" + day[2:].lower(), "dark": "#" + night[2:].lower()}
        for theme_name in ("light", "dark"):
            self.assertEqual(palette_check.ROUTE[theme_name]["body"], pair("body")[theme_name])
            self.assertEqual(palette_check.ROUTE[theme_name]["casing"], pair("casing")[theme_name])
            for state in ("free", "slow", "jam"):
                self.assertEqual(palette_check.TRAFFIC[theme_name][state], pair(state)[theme_name], state)

    def test_camera_types(self):
        theme = _swift("RadarMap/DesignSystem/Theme.swift")
        for name, hex_ in palette_check.CAMERA_TYPES.items():
            found = re.search(rf"static let {name}\s*= Color\(uiColor: rgb\(0x([0-9A-Fa-f]{{6}})\)\)", theme)
            self.assertIsNotNone(found, name)
            self.assertEqual(hex_, "#" + found.group(1).lower(), name)

    def test_calm_markers(self):
        view = _swift("RadarMap/Features/Map/Engine/EngineMapView.swift")
        for suffix, theme in (("-calm-d", "light"), ("-calm-n", "dark")):
            found = re.search(rf'suffix: "{suffix}".*?ring: 0x([0-9A-Fa-f]{{6}}),\s*fill: 0x([0-9A-Fa-f]{{6}})',
                              view, re.S)
            self.assertIsNotNone(found, suffix)
            self.assertEqual(palette_check.CALM[theme]["ring"], "#" + found.group(1).lower(), suffix)
            self.assertEqual(palette_check.CALM[theme]["fill"], "#" + found.group(2).lower(), suffix)


if __name__ == "__main__":
    unittest.main()
