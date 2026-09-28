"""Стиль, который уронит MapLibre, не должен выйти из сборки.

MapLibre отвергает стиль ЦЕЛИКОМ из-за одного свойства не того типа слоя —
экран пуст. Ровно так упал первый прототип: «line-color» у подписи реки.
"""
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_style

PREFIX = {"line": ("line-",), "fill": ("fill-",), "symbol": ("text-", "icon-"), "circle": ("circle-",),
          "background": ("background-",), "fill-extrusion": ("fill-extrusion-",), "raster": ("raster-",),
          "heatmap": ("heatmap-",), "hillshade": ("hillshade-",)}
SHIPPED_FONTS = {"Noto Sans Regular", "Noto Sans Bold", "Noto Sans Italic"}


class StyleTests(unittest.TestCase):
    """Проверки общие для всех тем и режимов: подкласс задаёт сочетание."""
    theme, mode = "light", "full"

    @classmethod
    def setUpClass(cls):
        cls.style = make_style.build("https://soulmed.uz/radarmap", cls.theme, cls.mode)

    def test_every_paint_and_layout_key_belongs_to_its_layer_type(self):
        for layer in self.style["layers"]:
            allowed = PREFIX[layer["type"]]
            for key in layer.get("paint", {}):
                self.assertTrue(key.startswith(allowed), f"{layer['id']}: {key}")
            for key in layer.get("layout", {}):
                if key in ("visibility",) or key.startswith("symbol-") or key.startswith("text-") \
                        or key.startswith("icon-") or key.startswith("line-") or key.startswith("fill-"):
                    if layer["type"] != "symbol":
                        self.assertFalse(key.startswith(("text-", "icon-", "symbol-")), f"{layer['id']}: {key}")

    def test_every_layer_uses_a_declared_source(self):
        for layer in self.style["layers"]:
            if layer["type"] != "background":
                self.assertIn(layer["source"], self.style["sources"], layer["id"])

    def test_only_shipped_fonts(self):
        for layer in self.style["layers"]:
            fonts = layer.get("layout", {}).get("text-font")
            if isinstance(fonts, list) and all(isinstance(f, str) for f in fonts):
                self.assertTrue(set(fonts) <= SHIPPED_FONTS, f"{layer['id']}: {fonts}")

    def test_every_lane_arrow_has_an_icon_in_the_sprite(self):
        import json as _json
        sprite = _json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprite", "sprite.json")))
        layer = next(l for l in self.style["layers"] if l["id"] == "radar-arrows")
        names = [v for v in layer["layout"]["icon-image"][2:-1] if isinstance(v, str)]
        self.assertEqual(len(names), 9)
        for name in names:
            self.assertIn(name, sprite)

    def test_waffle_pattern_is_in_the_sprite(self):
        import json as _json
        sprite = _json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprite", "sprite.json")))
        layer = next(l for l in self.style["layers"] if l["id"] == "radar-waffle")
        self.assertIn(layer["paint"]["fill-pattern"], sprite)
        icon = next(l for l in self.style["layers"] if l["id"] == "radar-signal-icon")
        self.assertIn(icon["layout"]["icon-image"], sprite)
        # По точке центра: по полигону MapLibre ставит значок в каждом тайле.
        self.assertIn(["==", ["geometry-type"], "Point"], icon["filter"])

    def test_median_strips_over_the_roads_islands_under(self):
        # Узкий разделитель под каймой лент исчезал (Мукими); островок из осей
        # поверх полотна ложился треугольником на полосы (Навои × Абая).
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertLess(ids.index("radar-roads"), ids.index("radar-median-strip"))
        self.assertLess(ids.index("radar-median-strip"), ids.index("radar-median-kerb"))
        self.assertLess(ids.index("radar-median"), ids.index("radar-roads-case"))
        self.assertLess(ids.index("radar-median-kerb"), ids.index("radar-markings"))
        # Нос у перехода лежит на асфальте узла, а не под ним.
        self.assertLess(ids.index("radar-junction"), ids.index("radar-median-strip"))

    def test_centre_lines_have_their_own_layers(self):
        layers = {l["id"]: l for l in self.style["layers"]}
        self.assertEqual(layers["radar-markings"]["filter"], ["!", ["has", "centre"]])
        self.assertIn("line-dasharray", layers["radar-centre-dashed"]["paint"])
        self.assertNotIn("line-dasharray", layers["radar-centre-solid"]["paint"])

    def test_minor_streets_are_asphalt_not_footpaths(self):
        # Двор цветом дорожки читался тропинкой; улица — асфальт, светлее магистрали.
        def lightness(colour):
            colour = colour.lstrip("#")
            return sum(int(colour[i:i + 2], 16) for i in (0, 2, 4)) / 3
        for theme in make_style.PALETTES.values():
            self.assertNotEqual(theme["minor"], theme["path"])
            low, high = sorted((lightness(theme["road"]), lightness(theme["bg"])))
            self.assertTrue(low < lightness(theme["minor"]) < high or theme is make_style.PALETTES["dark"])

    def test_bridges_cover_the_waffle(self):
        # Эстакада Фурката над перекрёстком Навои: «вафля» нижнего уровня — под мостом.
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertLess(ids.index("radar-waffle"), ids.index("radar-bridge"))

    def test_fillets_lie_over_the_roads_and_under_the_paint(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertGreater(ids.index("radar-fillet"), ids.index("radar-roads"))
        self.assertLess(ids.index("radar-fillet"), ids.index("radar-markings"))

    def test_medians_and_islands_lie_under_the_roads(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertLess(ids.index("radar-median"), ids.index("radar-roads-case"))

    def test_ids_are_unique(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_our_layers_sit_under_the_labels(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        # Подписи ПОДЛОЖКИ: наши стрелки — тоже символы, но лежат вместе с краской.
        first_label = next(i for i, l in enumerate(self.style["layers"])
                           if l["type"] == "symbol" and l.get("source") == "openmaptiles")
        wanted = ["radar-median", "radar-markings", "radar-crossing", "radar-signal-icon"]
        if self.mode == "full":
            wanted.append("building-3d")       # в режиме «только дорога» домов нет
        for ours in wanted:
            self.assertLess(ids.index(ours), first_label, ours)

    def test_sources_point_at_our_server_only(self):
        urls = [u for src in self.style["sources"].values() for u in src["tiles"]]
        urls += [self.style["glyphs"], self.style["sprite"]]
        for url in urls:
            self.assertTrue(url.startswith("https://soulmed.uz/radarmap/"), url)


class DarkFull(StyleTests):
    theme, mode = "dark", "full"

    def test_no_light_fills_left_on_dark(self):
        # Любая заливка светлее 60 % яркости на тёмной теме — пятно (Аллея парадов).
        def light(colour):
            if isinstance(colour, dict):                      # {"stops": [[z, цвет], …]}
                return any(light(stop[1]) for stop in colour.get("stops", []))
            if not isinstance(colour, str):
                return False
            if colour.startswith("#") and len(colour) in (4, 7):
                full = colour if len(colour) == 7 else "#" + "".join(c * 2 for c in colour[1:])
                r, g, b = (int(full[k:k + 2], 16) for k in (1, 3, 5))
                return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.6
            if colour.startswith(("hsl(", "hsla(")):
                lightness = float(colour.split(",")[2].strip().rstrip("%)").split("%")[0])
                return lightness > 60
            return colour in ("#fff", "white")
        for layer in self.style["layers"]:
            if layer["type"] in ("fill", "background"):
                for key in ("fill-color", "background-color"):
                    self.assertFalse(light(layer.get("paint", {}).get(key)), f"{layer['id']}: {key}")


class LightRoads(StyleTests):
    theme, mode = "light", "roads"

    def test_only_the_road_is_left(self):
        # Просьба владельца 28.09.2026: дорога красиво, остальное не нужно.
        for layer in self.style["layers"]:
            self.assertNotIn(layer.get("source-layer"), ("poi", "building", "housenumber", "aeroway",
                                                         "boundary", "aerodrome_label"), layer["id"])
        self.assertNotIn("building-3d", [layer["id"] for layer in self.style["layers"]])


class DarkRoads(LightRoads):
    theme, mode = "dark", "roads"


class PaletteTests(unittest.TestCase):
    def test_themes_define_the_same_colours(self):
        light, dark = make_style.PALETTES["light"], make_style.PALETTES["dark"]
        self.assertEqual(set(light), set(dark))

    def test_unknown_theme_is_refused(self):
        with self.assertRaises(ValueError):
            make_style.build("https://soulmed.uz/radarmap", "sepia")

    def test_oneway_ribbon_is_narrower(self):
        # Раньше вложенная копия width() без oneway подменяла эту — проспект сливался.
        stop = make_style.class_width(24)[10]      # зум 20: обе ширины выше минимума
        self.assertEqual(stop[0], "case")
        self.assertLess(stop[2], stop[3])


if __name__ == "__main__":
    unittest.main()
