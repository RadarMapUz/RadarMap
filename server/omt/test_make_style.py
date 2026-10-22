"""Стиль, который уронит MapLibre, не должен выйти из сборки.

MapLibre отвергает стиль ЦЕЛИКОМ из-за одного свойства не того типа слоя —
экран пуст. Ровно так упал первый прототип: «line-color» у подписи реки.
"""
import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_style

PREFIX = {"line": ("line-",), "fill": ("fill-",), "symbol": ("text-", "icon-"), "circle": ("circle-",),
          "background": ("background-",), "fill-extrusion": ("fill-extrusion-",), "raster": ("raster-",),
          "heatmap": ("heatmap-",), "hillshade": ("hillshade-",)}
SHIPPED_FONTS = {"Noto Sans Regular", "Noto Sans Bold", "Noto Sans Italic"}


class StyleTests(unittest.TestCase):
    """Проверки общие для всех тем и режимов: подкласс задаёт сочетание."""
    theme, mode = "light", "full"
    variant = None      # вариант палитры 27.C: те же проверки и для него

    @classmethod
    def setUpClass(cls):
        cls.style = make_style.build("https://soulmed.uz/radarmap", cls.theme, cls.mode, variant=cls.variant)

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

    def test_trees_and_yellow_kerbs_like_yandex(self):
        import json as _json
        sprite = _json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprite", "sprite.json")))
        layers = {l["id"]: l for l in self.style["layers"]}
        ids = [l["id"] for l in self.style["layers"]]
        self.assertIn(layers["trees"]["paint"]["fill-pattern"], sprite)
        self.assertLess(ids.index("trees"), ids.index("radar-roads-case"), "деревья под дорогой")
        case = layers["radar-roads-case"]["paint"]["line-color"]
        self.assertIn(make_style.palette(self.theme, self.variant)["kerb"], case)

    def test_tunnels_under_ground_roads_bridges_with_shadow(self):
        ids = [l["id"] for l in self.style["layers"]]
        layers = {l["id"]: l for l in self.style["layers"]}
        self.assertLess(ids.index("radar-tunnel"), ids.index("radar-roads-case"), "тоннель под землёй")
        self.assertIn(["!", ["has", "tunnel"]], layers["radar-roads"]["filter"])
        self.assertLess(ids.index("radar-bridge-shadow"), ids.index("radar-bridge-case"))
        self.assertLess(ids.index("radar-bridge-case"), ids.index("radar-bridge"))

    def test_osm_trees_drawn_as_crowns_under_roads(self):
        ids = [l["id"] for l in self.style["layers"]]
        self.assertLess(ids.index("radar-tree-shadow"), ids.index("radar-tree"))
        self.assertLess(ids.index("radar-tree"), ids.index("radar-roads-case"))

    def test_signal_icons_are_per_approach_points(self):
        import json as _json
        sprite = _json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprite", "sprite.json")))
        icon = next(l for l in self.style["layers"] if l["id"] == "radar-signal-icon")
        self.assertIn(icon["layout"]["icon-image"], sprite)
        self.assertIn(["==", ["geometry-type"], "Point"], icon["filter"])
        self.assertIn(["==", ["get", "kind"], 14], icon["filter"])
        # Жёлтой «вафли» нет — как у Яндекса.
        ids = [l["id"] for l in self.style["layers"]]
        self.assertNotIn("radar-waffle", ids)

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

    def test_junction_kerb_continues_the_ribbon_kerb_round_the_corner(self):
        # Бордюр угла (вид 16) поверх площади узла — иначе её заливка его
        # накрыла бы; под разметкой. Снаружи кромки, той же толщины, что
        # кайма ленты: жёлтая кромка проспекта идёт по углу без ступеньки.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        ids = [layer["id"] for layer in self.style["layers"]]
        kerb = layers["radar-junction-kerb"]
        self.assertEqual(kerb["type"], "line")
        self.assertIn(["==", ["get", "kind"], 16], kerb["filter"])
        self.assertLess(ids.index("radar-junction"), ids.index("radar-junction-kerb"))
        self.assertLess(ids.index("radar-junction-kerb"), ids.index("radar-markings"))
        self.assertEqual(kerb["paint"]["line-width"], make_style.ROAD_KERB_EXTRA_PX / 2)
        self.assertEqual(kerb["paint"]["line-offset"], kerb["paint"]["line-width"] / 2)
        self.assertEqual(layers["radar-roads-case"]["paint"]["line-width"],
                         make_style.measured(make_style.ROAD_KERB_EXTRA_PX))

    def test_roads_lie_under_3d_buildings(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        if "building-3d" in ids:
            self.assertLess(ids.index("radar-roads"), ids.index("building-3d"))
            self.assertLess(ids.index("radar-arrows"), ids.index("building-3d"))

    def test_buildings_rise_for_the_drive_and_go_flat_when_hot(self):
        # 25.D: объём с z16 (в пути под наклоном), по высоте из тайла, без неё
        # — 10 м; плоский слой — запасной для горячего телефона, по умолчанию
        # выключен (его включает приложение, гася объём).
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        if "building-3d" not in layers:
            return
        height = layers["building-3d"]["paint"]["fill-extrusion-height"]
        self.assertEqual(height[:5], ["interpolate", ["linear"], ["zoom"], 15, 0])
        self.assertEqual(height[5], 16)
        self.assertEqual(height[6], ["coalesce", ["get", "render_height"], 10])
        flat = layers["building-flat"]
        self.assertEqual(flat["type"], "fill")
        self.assertEqual(flat["layout"]["visibility"], "none")
        self.assertEqual(flat["paint"]["fill-color"], layers["building-3d"]["paint"]["fill-extrusion-color"])

    def test_ground_paint_lies_under_bridges(self):
        ids = [layer["id"] for layer in self.style["layers"]]
        deck = ids.index("radar-bridge")
        for ground in ("radar-markings", "radar-zebra", "radar-stop-line", "radar-arrows"):
            self.assertLess(ids.index(ground), ids.index("radar-bridge-shadow"), ground)
        self.assertGreater(ids.index("radar-markings-bridge"), deck)

    def test_centre_lines_have_their_own_layers(self):
        layers = {l["id"]: l for l in self.style["layers"]}
        self.assertIn(["!", ["has", "centre"]], layers["radar-markings"]["filter"])
        self.assertNotIn("line-dasharray", layers["radar-markings-solid"]["paint"])
        self.assertIn("line-dasharray", layers["radar-centre-dashed"]["paint"])
        self.assertNotIn("line-dasharray", layers["radar-centre-solid"]["paint"])

    def test_minor_streets_are_asphalt_not_footpaths(self):
        # Вблизи двор — асфальт, как у Яндекса (снимок Навои × Фурката,
        # 07.10.2026); белая — дорожка. Белой улица бывает только на обзоре.
        def lightness(colour):
            colour = colour.lstrip("#")
            return sum(int(colour[i:i + 2], 16) for i in (0, 2, 4)) / 3
        light, dark = make_style.palette("light", self.variant), make_style.palette("dark", self.variant)
        for theme in (light, dark):
            self.assertNotEqual(theme["minor"], theme["path"])
        if light.get("class_roads"):
            # Дороги цветом (27.C «Премиум»): двор белый с серой кромкой, как у
            # Яндекса на обзоре, — а дорожка тёплая бежевая, не белая.
            self.assertGreater(lightness(light["minor"]), lightness(light["path"]) + 10)
            self.assertLess(lightness(light["minor_edge"]), lightness(light["bg"]))
            return
        low, high = sorted((lightness(light["road"]), lightness(light["bg"])))
        self.assertTrue(low < lightness(light["minor"]) < high)

    def test_street_names_abbreviated_like_yandex(self):
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        field = json.dumps(layers["highway-name-major"]["layout"]["text-field"], ensure_ascii=False)
        self.assertIn('"ул."', field)
        self.assertIn('" улица"', field, "тип в конце имени — «Фуркат улица»")
        # Длины — только движком: на телефоне строка меряется в байтах UTF-8.
        self.assertIn('"index-of"', field)
        self.assertNotIn('"slice", ["var", "n"], ["-"', field)
        # Обычным регистром: капс с разрядкой был длиннее на треть (13.10.2026).
        self.assertEqual(layers["highway-name-major"]["layout"]["text-transform"], "none")

    def test_street_label_halo_is_the_asphalt(self):
        # Ореол цвета фона ночью лежал чёрной наклейкой поверх разметки
        # (снимок CarPlay 13.10.2026): вблизи ореол — цвет полотна.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        palette = make_style.palette(self.theme, self.variant)
        for layer_id in ("highway-name-major", "highway-name-minor"):
            halo = layers[layer_id]["paint"]["text-halo-color"]
            self.assertEqual(halo[0], "interpolate", layer_id)
            near = make_style.class_asphalt(palette, "class") if palette.get("class_roads") else palette["road"]
            self.assertEqual(halo[-1], near, "вблизи — асфальт, как у полотна")
            self.assertEqual(halo[4], palette["halo"], "до нашего полотна — фон")

    def test_waterway_in_a_pipe_is_not_labelled(self):
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        if "waterway-name" in layers:
            self.assertIn(["!=", "brunnel", "tunnel"], layers["waterway-name"]["filter"])

    def test_lane_arrow_fits_its_lane(self):
        # Значок стрелки при свойстве lw — не шире своей полосы на любом зуме.
        arrows = next(l for l in self.style["layers"] if l["id"] == "radar-arrows")
        size = arrows["layout"]["icon-size"]
        self.assertEqual(size[:3], ["interpolate", ["exponential", 2], ["zoom"]])
        for zoom, stop in zip(size[3::2], size[4::2]):
            self.assertEqual(stop[0], "case")
            factor = stop[2][2]
            lane = 3.0
            icon_points = factor * lane * make_style.ARROW_ICON_POINTS
            lane_points = lane * (2 ** zoom) * make_style.M
            self.assertLessEqual(icon_points, lane_points + 1e-9, f"z{zoom}")

    def test_poi_labels_coloured_by_kind(self):
        layers = {layer["id"]: layer for layer in self.style["layers"] if layer["id"].startswith("poi-level")}
        for layer in layers.values():
            self.assertEqual(layer["paint"]["text-color"][0], "match", layer["id"])

    def test_roads_are_lighter_than_blocks_at_night(self):
        # Ночью двор был темнее домов и пропадал (07.10.2026).
        def lightness(colour):
            colour = colour.lstrip("#")
            return sum(int(colour[i:i + 2], 16) for i in (0, 2, 4)) / 3
        dark = make_style.palette("dark", self.variant)
        for key in ("minor", "road", "road_tertiary"):
            self.assertGreater(lightness(dark[key]), lightness(dark["building"]), key)

    def test_overview_roads_ranked_by_colour(self):
        # Обзор: магистраль насыщеннее улицы, а не одна жёлтая сетка.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        colour = layers["highway-primary"]["paint"]["line-color"]
        self.assertEqual(colour[0], "interpolate")
        self.assertEqual(colour[4][0], "match", "цвет на обзоре зависит от класса")

    def test_labels_in_one_language(self):
        # Ни одной двуязычной подписи и ни одной автотранслитерации.
        for layer in self.style["layers"]:
            field = json.dumps(layer.get("layout", {}).get("text-field", ""), ensure_ascii=False)
            self.assertNotIn("name:latin", field, layer["id"])
            self.assertNotIn("name:nonlatin", field, layer["id"])

    def test_oneway_arrows_only_on_streets(self):
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        arrows = layers["radar-oneway"]
        self.assertIn([">=", ["get", "cls"], 5], arrows["filter"], "на проспектах-дублёрах стрелки — шум")
        self.assertEqual(arrows["layout"]["symbol-placement"], "line")

    def test_lane_markings_wait_for_close_zoom(self):
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        for layer_id in ("radar-markings", "radar-markings-solid"):
            self.assertGreaterEqual(layers[layer_id]["minzoom"], make_style.LANE_MARKINGS_FROM)

    def test_base_roads_stay_under_ours_as_fallback(self):
        # Нет нашего тайла (офлайн, район вне сборки) — дорога не исчезает.
        ids = [l["id"] for l in self.style["layers"]]
        first_ours = ids.index("radar-roads-case")
        roads = [l for l in self.style["layers"]
                 if l.get("source-layer") == "transportation" and l["type"] == "line"
                 and l["id"].startswith("highway-") and "path" not in l["id"]
                 and "construction" not in l["id"]]
        self.assertTrue(roads)
        fills = [l for l in roads if not l["id"].endswith("-casing")]
        self.assertTrue(fills)
        for layer in fills:
            self.assertNotIn("maxzoom", layer, layer["id"])
            self.assertLess(ids.index(layer["id"]), first_ours, "под нашими слоями")
            # С 15-го — узкая, чтобы не торчать зубцами из-под нашей ленты.
            width = layer["paint"]["line-width"]
            self.assertIn(make_style.OUR_ROADS_FROM, width, layer["id"])
        for layer in roads:
            if layer["id"].endswith("-casing"):
                self.assertEqual(layer.get("maxzoom"), make_style.OUR_ROADS_FROM, layer["id"])

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


# Варианты палитры (27.C): каждый проходит все проверки своей темы.
for _variant in make_style.PALETTE_VARIANTS:
    for _base in (StyleTests, DarkFull):
        _name = f"{'Light' if _base is StyleTests else 'Dark'}Variant{_variant.upper()}"
        globals()[_name] = type(_name, (_base,), {"variant": _variant})


class AppResourceTests(unittest.TestCase):
    """Стиль в бандле приложения обязан совпадать с генератором: забыть
    перегенерировать — красный тест, а не старая карта у водителя."""

    def test_bundled_styles_match_the_generator(self):
        for name, text in make_style.app_styles().items():
            path = os.path.join(make_style.APP_STYLE_DIR, name)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), text,
                                 f"{name} устарел: python3 server/omt/make_style.py --app")

    def test_bundled_variants_match_the_generator(self):
        expected = make_style.app_variant_styles()
        self.assertEqual(sorted(os.listdir(make_style.APP_VARIANT_DIR)), sorted(expected),
                         "лишний или пропавший вариант: python3 server/omt/make_style.py --app")
        for name, text in expected.items():
            with open(os.path.join(make_style.APP_VARIANT_DIR, name), encoding="utf-8") as handle:
                self.assertEqual(handle.read(), text,
                                 f"{name} устарел: python3 server/omt/make_style.py --app")

    def test_app_tiles_come_from_the_release(self):
        style = make_style.build(make_style.APP_BASE, "light", "full", tileset=make_style.APP_TILESET)
        for source in style["sources"].values():
            for url in source["tiles"]:
                self.assertTrue(url.startswith("{{BASE}}/v/{{TILESET}}/"), url)
        self.assertTrue(style["glyphs"].startswith("{{BASE}}/glyphs/"))


class PaletteTests(unittest.TestCase):
    def test_themes_define_the_same_colours(self):
        light, dark = make_style.PALETTES["light"], make_style.PALETTES["dark"]
        self.assertEqual(set(light), set(dark))

    def test_variants_change_only_known_colours(self):
        # Вариант — правки поверх палитры: ни нового ключа, ни пропуска темы.
        for name, variant in make_style.PALETTE_VARIANTS.items():
            self.assertTrue(variant["title"], name)
            for theme in ("light", "dark"):
                self.assertLessEqual(set(variant[theme]), set(make_style.PALETTES[theme]) | make_style.OPTIONAL_KEYS,
                                     f"{name}/{theme}")
                if variant[theme].get("class_roads"):
                    self.assertIn("road_secondary", variant[theme], f"{name}/{theme}")

    def test_default_palette_is_untouched_by_variants(self):
        self.assertIs(make_style.palette("light"), make_style.PALETTES["light"])
        with self.assertRaises(ValueError):
            make_style.palette("light", "v9")

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
