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
    @classmethod
    def setUpClass(cls):
        cls.style = make_style.build("https://soulmed.uz/radarmap")

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

    def test_ids_are_unique(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_our_layers_sit_under_the_labels(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        first_label = next(i for i, l in enumerate(self.style["layers"]) if l["type"] == "symbol")
        for ours in ("radar-median", "radar-markings", "radar-crossing", "radar-signals", "building-3d"):
            self.assertLess(ids.index(ours), first_label, ours)

    def test_sources_point_at_our_server_only(self):
        urls = [u for src in self.style["sources"].values() for u in src["tiles"]]
        urls += [self.style["glyphs"], self.style["sprite"]]
        for url in urls:
            self.assertTrue(url.startswith("https://soulmed.uz/radarmap/"), url)


if __name__ == "__main__":
    unittest.main()
