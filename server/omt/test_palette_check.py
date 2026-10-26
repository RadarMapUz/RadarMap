"""Палитра карты (27.C, с 28.A — «Б — Чистый») — под замером, как PaletteTests приложения.

Палитра обязана пройти правила плана: камеры заметнее всего, линия
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


class PaletteRules(unittest.TestCase):

    def test_palette_passes_every_rule(self):
        for theme in ("light", "dark"):
            _, failures = palette_check.measure(theme)
            self.assertEqual(failures, [], theme)

    def test_drive_asphalt_passes_every_rule(self):
        # 29.B: тёмное полотно поездки — белая разметка, светлое имя улицы,
        # ночной маршрут, камеры и пробки на нём читаются.
        for theme in ("light", "dark"):
            _, failures = palette_check.measure_drive(theme)
            self.assertEqual(failures, [], theme)

    def test_drive_rules_catch_asphalt_in_the_route_dead_band(self):
        # Асфальт поездки светлее 0,087 — светлое тело ночного маршрута на
        # нём теряет 3:1, а тёмной кайме ещё не хватает светлоты.
        p = dict(make_style.PALETTES["light"], drive_primary="#5b6476")
        _, failures = palette_check.measure_drive("light", p)
        self.assertIn("поездка: линия маршрута < 3:1", failures)

    def test_drive_rules_catch_a_dark_street_name(self):
        # Тёмное имя улицы дневной палитры на тёмном полотне — нарушение.
        p = dict(make_style.PALETTES["light"], drive_street_label=make_style.PALETTES["light"]["street_label"])
        _, failures = palette_check.measure_drive("light", p)
        self.assertIn("поездка: имя улицы на асфальте < 4,5:1", failures)

    def test_rules_catch_a_road_lost_in_the_ground(self):
        # Двор цвета земли без кромки — нарушение, а не «все правила соблюдены».
        p = dict(make_style.PALETTES["light"], minor=make_style.PALETTES["light"]["bg"],
                 minor_edge=make_style.PALETTES["light"]["bg"])
        _, failures = palette_check.measure("light", p)
        self.assertIn("дом заметнее двора", failures)

    def test_rules_catch_a_label_lost_on_the_trunk(self):
        # Ночью магистраль светлая (0,14): тусклая подпись места на ней
        # падает ниже 4,5:1 — это нарушение, а не «на ореоле прочтут».
        p = dict(make_style.PALETTES["dark"], label="#c9ced6")
        _, failures = palette_check.measure("dark", p)
        self.assertIn("подпись места на асфальте < 4,5:1", failures)

    def test_rules_catch_a_yellow_avenue(self):
        # «Чистый»: тёплая только магистраль. Проспект цвета магистрали —
        # иерархия классов пропала.
        p = dict(make_style.PALETTES["light"], road=make_style.PALETTES["light"]["road_trunk"],
                 far_primary=make_style.PALETTES["light"]["far_trunk"])
        _, failures = palette_check.measure("light", p)
        self.assertIn("магистраль не отличить от проспекта", failures)

    def test_rules_catch_ground_lighter_than_the_street(self):
        p = dict(make_style.PALETTES["light"], building="#ffffff")
        _, failures = palette_check.measure("light", p)
        self.assertIn("земля светлее улицы", failures)

    def test_night_asphalt_keeps_out_of_the_route_dead_band(self):
        # Светлота 0,083–0,133: линия маршрута не держит 3:1 ни телом, ни
        # каймой (#5a606c со схемы владельца — 0,116).
        p = dict(make_style.PALETTES["dark"], road_trunk="#5a606c")
        _, failures = palette_check.measure("dark", p)
        self.assertIn("линия маршрута на асфальте < 3:1", failures)

    def test_rules_catch_grey_paint_on_a_white_street(self):
        # До 28.L: серая краска #c4c9d1 на белом полотне — по яркости 1,66:1,
        # но краска темнее асфальта читалась швом, а не разметкой.
        light = make_style.PALETTES["light"]
        white = {k: "#ffffff" for k in palette_check.MARKED_KEYS}
        p = dict(light, paint="#c4c9d1", zebra_base="#ffffff", **white)
        _, failures = palette_check.measure("light", p)
        self.assertIn("разметка темнее асфальта", failures)

    def test_rules_catch_lane_paint_lost_on_pale_asphalt(self):
        # Тон #dfe2e7 — белая краска 1,30:1, пунктир растворяется.
        p = dict(make_style.PALETTES["light"], near_primary="#dfe2e7")
        _, failures = palette_check.measure("light", p)
        self.assertIn("разметка на асфальте < 1,4:1", failures)

    def test_rules_catch_asphalt_lost_among_houses(self):
        p = dict(make_style.PALETTES["light"], near_tertiary=make_style.PALETTES["light"]["building"])
        _, failures = palette_check.measure("light", p)
        self.assertIn("асфальт вблизи сливается с домами", failures)

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
            for name in ("alternative", "alternativeCasing"):
                self.assertEqual(palette_check.ROUTE[theme_name][name], pair(name)[theme_name], name)
            for state in ("free", "slow", "jam"):
                self.assertEqual(palette_check.TRAFFIC[theme_name][state], pair(state)[theme_name], state)

    def test_camera_types(self):
        theme = _swift("RadarMap/DesignSystem/Theme.swift")
        for name, hex_ in palette_check.CAMERA_TYPES.items():
            found = re.search(rf"static let {name}\s*= Color\(uiColor: rgb\(0x([0-9A-Fa-f]{{6}})\)\)", theme)
            self.assertIsNotNone(found, name)
            self.assertEqual(hex_, "#" + found.group(1).lower(), name)

    def test_asphalt_copy_in_palette_tests(self):
        # PaletteTests.asphalt держит копию полотна по классам и фона.
        tests = _swift("RadarMapTests/PaletteTests.swift")
        found = re.search(r'theme == "днём"\s*\?\s*\[([^\]]+)\]\s*:\s*\[([^\]]+)\]', tests)
        self.assertIsNotNone(found)
        keys = palette_check.ASPHALT_KEYS + ("bg",)
        for theme, group in (("light", 1), ("dark", 2)):
            copy = ["#" + h.strip()[2:].lower() for h in found.group(group).split(",")]
            self.assertEqual(copy, [make_style.PALETTES[theme][k] for k in keys], theme)

    def test_hatch_alpha_matches_the_sprite(self):
        with open(os.path.join(HERE, "make_arrows.py"), encoding="utf-8") as handle:
            source = handle.read()
        hatch = source[source.index("def hatch("):]
        alpha = int(re.search(r"fill=\(255, 255, 255, (\d+)\)", hatch).group(1))
        self.assertAlmostEqual(palette_check.HATCH_ALPHA, alpha / 255)

    def test_camera_label_uses_the_map_label_and_halo(self):
        style = _swift("RadarMap/Features/Map/Engine/EngineModernStyle.swift")
        for name, key in (("labelHex", "label"), ("haloHex", "halo")):
            found = re.search(rf'static let {name} = \(day: "(#[0-9a-f]{{6}})", night: "(#[0-9a-f]{{6}})"\)', style)
            self.assertIsNotNone(found, name)
            self.assertEqual(found.group(1), make_style.PALETTES["light"][key], name)
            self.assertEqual(found.group(2), make_style.PALETTES["dark"][key], name)

    def test_calm_markers(self):
        # С 29.C («Монета») спокойные значки описаны в CameraMarkerLook:
        # заливка и кант — именованные константы, растры ссылаются на них.
        look = _swift("RadarMap/Models/CameraMarkerLook.swift")

        def rgb(name):
            found = re.search(rf"static let {name}: UInt32 = 0x([0-9A-Fa-f]{{6}})", look)
            self.assertIsNotNone(found, name)
            return "#" + found.group(1).lower()

        for suffix, theme, fill, rim in (("-calm-d", "light", "neutralDayRGB", None),
                                         ("-calm-n", "dark", "neutralNightRGB", "calmNightInkRGB")):
            raster = re.search(rf'Raster\(suffix: "{suffix}".*?fill: (\w+),.*?rim: (\w+)\)', look)
            self.assertIsNotNone(raster, suffix)
            self.assertEqual(raster.group(1), fill, suffix)
            self.assertEqual(palette_check.CALM[theme]["fill"], rgb(fill), suffix)
            ring = "#ffffff" if raster.group(2) == "0xFFFFFF" else rgb(raster.group(2))
            if rim:
                self.assertEqual(raster.group(2), rim, suffix)
            self.assertEqual(palette_check.CALM[theme]["ring"], ring, suffix)


if __name__ == "__main__":
    unittest.main()
