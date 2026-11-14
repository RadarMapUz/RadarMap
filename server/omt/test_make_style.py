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

    def test_trees_and_class_kerbs(self):
        import json as _json
        sprite = _json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprite", "sprite.json")))
        layers = {l["id"]: l for l in self.style["layers"]}
        ids = [l["id"] for l in self.style["layers"]]
        self.assertIn(layers["trees"]["paint"]["fill-pattern"], sprite)
        self.assertLess(ids.index("trees"), ids.index("radar-roads-case"), "деревья под дорогой")
        case = layers["radar-roads-case"]["paint"]["line-color"]
        self.assertIn(make_style.PALETTES[self.theme]["kerb"], case)
        self.assertIn(make_style.PALETTES[self.theme]["kerb_trunk"], case)

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
        # Бордюр угла (вид 16) — ПОД площадью узла (над лентами): он лежит
        # снаружи её кромки и виден, а его куски, прошедшие через узел от
        # устья внутри кластера, заливка накрывает — без «паутины» по
        # асфальту (Дурмон йули × Зиёлилар, 23.10.2026). Той же толщины, что
        # кайма ленты: жёлтая кромка проспекта идёт по углу без ступеньки.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        ids = [layer["id"] for layer in self.style["layers"]]
        kerb = layers["radar-junction-kerb"]
        self.assertEqual(kerb["type"], "line")
        self.assertIn(["==", ["get", "kind"], 16], kerb["filter"])
        self.assertLess(ids.index("radar-junction-kerb"), ids.index("radar-junction"))
        self.assertLess(ids.index("radar-roads"), ids.index("radar-junction-kerb"))
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
        light, dark = make_style.PALETTES["light"], make_style.PALETTES["dark"]
        for theme in (light, dark):
            self.assertNotEqual(theme["minor"], theme["path"])
        # Двор белый с серой кромкой (27.C, 28.A), а дорожка серее земли, не
        # белая: с двором её не спутать.
        self.assertGreater(lightness(light["minor"]), lightness(light["path"]) + 10)
        self.assertLess(lightness(light["minor_edge"]), lightness(light["bg"]))

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
        palette = make_style.PALETTES[self.theme]
        for layer_id in ("highway-name-major", "highway-name-minor"):
            halo = layers[layer_id]["paint"]["text-halo-color"]
            self.assertEqual(halo[0], "interpolate", layer_id)
            # Вблизи — асфальт класса: днём с 28.L тот, что под разметкой.
            near = make_style.class_asphalt(make_style.near_palette(palette), "class")
            self.assertEqual(halo[-1], near, "вблизи — асфальт класса")
            self.assertEqual(halo[4], palette["halo"], "до нашего полотна — фон")

    def test_asphalt_turns_lane_grey_by_zoom(self):
        # 28.L: днём полотно улиц с OUR_ROADS_FROM плавно уходит к серому
        # асфальту под белой разметкой; ночью цвет как был — без зума.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        palette = make_style.PALETTES[self.theme]
        near = make_style.near_palette(palette)
        changes = palette != near
        for layer_id, prop in (("radar-roads", "line-color"), ("radar-roads-stub", "line-color"),
                               ("radar-bridge", "line-color"), ("radar-junction", "fill-color"),
                               ("radar-fillet", "fill-color"), ("radar-median", "fill-color")):
            colour = layers[layer_id]["paint"][prop]
            if not changes:
                self.assertNotIn("zoom", json.dumps(colour), layer_id)
                continue
            self.assertEqual(colour[:3], ["interpolate", ["linear"], ["zoom"]], layer_id)
            self.assertEqual(colour[3::2], list(make_style.ASPHALT_NEAR), layer_id)
            # Зум — только на верхнем уровне: вложенный движок отвергает.
            self.assertNotIn("zoom", json.dumps(colour[4:]), layer_id)
        # Полотно доходит до серого раньше первой разметки.
        self.assertLessEqual(make_style.ASPHALT_NEAR[1], layers["radar-zebra"]["minzoom"])
        self.assertLessEqual(make_style.ASPHALT_NEAR[1], make_style.LANE_MARKINGS_FROM)
        self.assertEqual(make_style.ASPHALT_NEAR[0], make_style.OUR_ROADS_FROM)

    def test_paint_is_one_colour_parking_stalls_their_own(self):
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        palette = make_style.PALETTES[self.theme]
        for layer_id in ("radar-markings", "radar-markings-solid", "radar-centre-dashed", "radar-centre-solid",
                         "radar-zebra", "radar-stop-line", "radar-crossing"):
            self.assertEqual(layers[layer_id]["paint"]["line-color"], palette["paint"], layer_id)
        self.assertEqual(layers["radar-parking-stall"]["paint"]["line-color"], palette["stall"])

    def test_junction_has_no_outline_layer(self):
        # 23.10: обводка площадей узла (аудит, №1) лежала под заливкой, но
        # узел склеен из многих кусков, и в волосяных швах между ними она
        # проступала «паутиной» поперёк перекрёстка (снимки владельца,
        # Дурмень йули × Зиёлилар, Муминова). Край узла — задача контура.
        ids = [layer["id"] for layer in self.style["layers"]]
        self.assertNotIn("radar-junction-edge", ids)

    def test_bridge_deck_has_round_ends(self):
        # Аудит 23.10, №2: прямые торцы кусков настила давали поперечные швы.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        self.assertEqual(layers["radar-bridge"]["layout"]["line-cap"], "round")

    def test_street_labels_do_not_bend_through_junctions(self):
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        for layer_id in ("highway-name-major", "highway-name-minor"):
            self.assertEqual(layers[layer_id]["layout"]["text-max-angle"], make_style.STREET_LABEL_MAX_ANGLE)
        self.assertLess(make_style.STREET_LABEL_MAX_ANGLE, 45)

    def test_base_casing_fades_into_ours(self):
        # Аудит 23.10, №5: кайма основы обрывалась на 15-м — дорога на
        # автозуме вдруг светлела. Теперь гаснет с CASING_FADE_FROM; у мелочи
        # на 12–13 каймы нет вовсе (№4).
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        major, minor = layers["highway-primary-casing"], layers["highway-minor-casing"]
        for layer in (major, minor):
            opacity = layer["paint"]["line-opacity"]
            self.assertEqual(opacity[-4:], [make_style.CASING_FADE_FROM, 1, make_style.OUR_ROADS_FROM, 0])
        self.assertEqual(minor["paint"]["line-opacity"][3:5], [13.5, 0])

    def test_primary_wider_than_streets_on_the_overview(self):
        self.assertGreater(make_style.CLASS_M["primary"], make_style.CLASS_M["secondary-tertiary"])
        palette = make_style.PALETTES[self.theme]
        if self.theme == "light":
            # Белую дорогу на светлой земле несёт кайма: у проспекта темнее.
            def lightness(colour):
                colour = colour.lstrip("#")
                return sum(int(colour[i:i + 2], 16) for i in (0, 2, 4)) / 3
            self.assertLess(lightness(palette["far_primary_edge"]), lightness(palette["far_secondary_edge"]))
            self.assertLess(lightness(palette["far_secondary_edge"]), lightness(palette["far_tertiary_edge"]))

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
        dark = make_style.PALETTES["dark"]
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
        # Телефон: полосы прозрачны до LANE_MARKINGS_FROM (на 16-м рябь); слой
        # стоит с порога машины, чтобы её разница включала его раньше.
        layers = {layer["id"]: layer for layer in self.style["layers"]}
        for layer_id in ("radar-markings", "radar-markings-solid"):
            self.assertGreaterEqual(layers[layer_id]["minzoom"], make_style.CAR_LANE_MARKINGS_FROM)
            stops = layers[layer_id]["paint"]["line-opacity"][3:]
            for zoom, value in zip(stops[::2], stops[1::2]):
                if zoom <= make_style.LANE_MARKINGS_FROM:
                    self.assertEqual(value, 0, (layer_id, zoom))

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


class AppResourceTests(unittest.TestCase):
    """Стиль в бандле приложения обязан совпадать с генератором: забыть
    перегенерировать — красный тест, а не старая карта у водителя."""

    def test_bundled_styles_match_the_generator(self):
        for name, text in make_style.app_styles().items():
            path = os.path.join(make_style.APP_STYLE_DIR, name)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), text,
                                 f"{name} устарел: python3 server/omt/make_style.py --app")


    def test_app_tiles_come_from_the_release(self):
        style = make_style.build(make_style.APP_BASE, "light", "full", tileset=make_style.APP_TILESET)
        for source in style["sources"].values():
            for url in source["tiles"]:
                self.assertTrue(url.startswith("{{BASE}}/v/{{TILESET}}/"), url)
        self.assertTrue(style["glyphs"].startswith("{{BASE}}/glyphs/"))


class DriveAsphaltTests(unittest.TestCase):
    """Асфальт поездки (29.B) — разница свойствами слоёв, без перезагрузки стиля."""

    @classmethod
    def setUpClass(cls):
        cls.style = make_style.build(make_style.APP_BASE, "light", "full", tileset=make_style.APP_TILESET)
        cls.drive = make_style.drive_overrides("light")

    def test_only_colours_of_existing_layers_change(self):
        layers = {l["id"]: l for l in self.style["layers"]}
        for layer_id, props in self.drive.items():
            self.assertIn(layer_id, layers)
            for prop in props:
                self.assertIn(prop, make_style.DRIVE_COLOUR_PROPS)
                self.assertTrue(prop.startswith(PREFIX[layers[layer_id]["type"]]), (layer_id, prop))

    def test_road_ribbon_kerbs_paint_base_and_street_halo_follow(self):
        for layer_id in ("radar-roads", "radar-roads-case", "radar-junction", "radar-zebra-base",
                         "radar-bridge", "highway-name-major"):
            self.assertIn(layer_id, self.drive)
        self.assertIn("text-halo-color", self.drive["highway-name-major"])

    def test_below_the_drive_zoom_nothing_changes(self):
        # Ниже DRIVE_ASPHALT[0] выражение поездки отдаёт тот же цвет, что обычное:
        # вне крупных зумов поездка карту не перекрашивает.
        start, end = make_style.DRIVE_ASPHALT
        layers = {l["id"]: l for l in self.style["layers"]}
        for layer_id, props in self.drive.items():
            for prop, value in props.items():
                normal = layers[layer_id]["paint"][prop]
                if value[0] == "step":
                    self.assertEqual(value[2], normal)
                    self.assertTrue(start < value[3] < end)
                    continue
                stops = value[3:]
                self.assertEqual(stops[-2], end)
                head = stops[:-2]
                self.assertEqual(head[-2], start)
                own = make_style._zoom_stops(normal)
                if own is None:
                    self.assertEqual(head, [start, normal])
                    continue
                kept = [x for z, v in zip(own[0::2], own[1::2]) if z <= start for x in (z, v)]
                self.assertEqual(head[:len(kept)], kept)

    def test_drive_colour_is_reached_at_the_end_zoom(self):
        roads = self.drive["radar-roads"]["line-color"]
        self.assertEqual(roads[-1][5], make_style.PALETTES["light"]["drive_primary"])

    def test_night_drive_is_the_night_style(self):
        # Ночью асфальт и так графитовый: разницы нет, перекрашивать нечего.
        self.assertEqual(make_style.drive_overrides("dark"), {})

    def test_nested_zoom_is_refused(self):
        with self.assertRaises(ValueError):
            make_style.drive_value("line-color", "#ffffff",
                                   ["match", ["get", "c"], 1, ["interpolate", ["linear"], ["zoom"], 1, "#000", 2, "#fff"],
                                    "#000"])


class CarStyleTests(unittest.TestCase):
    """Карта машины (40J): своя разница поездки — map_car_*.json."""

    @classmethod
    def setUpClass(cls):
        cls.normal = {theme: {l["id"]: l for l in make_style.build(make_style.APP_BASE, theme, "full",
                                                                   tileset=make_style.APP_TILESET)["layers"]}
                      for theme in ("light", "dark")}
        cls.car = {(theme, variant): make_style.car_overrides(theme, variant)
                   for _, theme, variant in make_style.CAR_FILES}
        # Постоянная палитра машины: с неё начинается окно асфальта.
        cls.fixed = {(theme, variant): {l["id"]: l for l in make_style.build(
            make_style.APP_BASE, theme, "full", tileset=make_style.APP_TILESET,
            palette=make_style.car_palettes(theme, variant)[0])["layers"]}
            for _, theme, variant in make_style.CAR_FILES}

    def test_only_known_properties_of_existing_layers_change(self):
        for (theme, variant), diff in self.car.items():
            layers = self.normal[theme]
            self.assertTrue(set(diff) <= {"layers", "light"})
            for layer_id, props in diff["layers"].items():
                self.assertIn(layer_id, layers, (theme, variant))
                for prop in props:
                    self.assertIn(prop, make_style.CAR_PROPS)
                    self.assertTrue(prop.startswith(PREFIX[layers[layer_id]["type"]]), (layer_id, prop))
                self.assertFalse(layer_id.startswith(("camera", "route", "traffic")), layer_id)

    def test_bare_strings_are_only_hex_colours(self):
        # Приложение превращает голый «#rrggbb» в цвет (DriveAsphalt.colourHex);
        # другая строка дошла бы до движка строкой и уронила бы его.
        import re
        for diff in self.car.values():
            for layer_id, props in diff["layers"].items():
                for prop, value in props.items():
                    if isinstance(value, str):
                        self.assertRegex(value, re.compile(r"^#[0-9a-f]{6}$"), (layer_id, prop))

    def test_day_a_asphalt_is_dark_from_15(self):
        roads = self.car[("light", "A")]["layers"]["radar-roads"]["line-color"]
        self.assertEqual(roads[-2], make_style.CAR_DRIVE_ASPHALT[1])
        self.assertEqual(roads[-1][5], make_style.PALETTES["light"]["drive_primary"])
        self.assertEqual(roads[-1][3], make_style.CAR_WARM_TRUNK, "магистраль машины — тёплый графит")
        # До окна — постоянный цвет машины (обзор, двор спокойнее белого).
        fixed = self.fixed[("light", "A")]["radar-roads"]["paint"]["line-color"]
        self.assertEqual(roads[3:5], [make_style.CAR_DRIVE_ASPHALT[0], fixed[4]])
        name = self.car[("light", "A")]["layers"]["highway-name-major"]["text-color"]
        self.assertEqual(name[0], "step")
        self.assertTrue(make_style.CAR_DRIVE_ASPHALT[0] < name[3] < make_style.CAR_DRIVE_ASPHALT[1])

    def test_windowed_values_keep_the_normal_stops_before_the_window(self):
        start, end = make_style.CAR_DRIVE_ASPHALT
        for (theme, variant), diff in self.car.items():
            for layer_id, props in diff["layers"].items():
                for prop, value in props.items():
                    normal = self.fixed[(theme, variant)][layer_id]["paint"].get(prop)
                    stops = make_style._zoom_stops(value)
                    if not stops or stops[-2] != end or value == normal:
                        continue
                    own = make_style._zoom_stops(normal)
                    kept = stops[:-2]
                    if own is None or kept[:2] == [start, own[1]]:
                        continue
                    self.assertEqual(kept, own[:len(kept)], (theme, variant, layer_id, prop))

    def test_houses_lower_plain_and_softer_lit(self):
        day = self.car[("light", "A")]
        height = day["layers"]["building-3d"]["fill-extrusion-height"]
        self.assertEqual(height[-1][:2], ["*", 0.75])
        self.assertEqual(day["light"], {"intensity": 0.45})
        colour = day["layers"]["building-3d"]["fill-extrusion-color"]
        self.assertEqual(colour[-1], "#f4f5f7")
        self.assertNotIn("match", json.dumps(colour[-1]), "без оттенков назначения")
        b = self.car[("light", "B")]["layers"]["building-3d"]["fill-extrusion-height"]
        self.assertEqual(b[-1][:2], ["*", 0.4])

    def test_night_n1_dims_labels_and_drops_the_trunk_glow(self):
        night = self.car[("dark", "A")]["layers"]
        self.assertEqual(night["radar-trunk-glow"]["line-opacity"], 0)
        self.assertEqual(night["highway-name-major"]["text-color"], "#bfc5ce")
        self.assertEqual(night["place-city"]["text-color"], "#a9afb9")
        self.assertEqual(night["background"]["background-color"], "#141619")

    def test_light_variant_has_no_dark_asphalt(self):
        roads = self.car[("light", "B")]["layers"]["radar-roads"]["line-color"]
        self.assertNotIn(make_style.PALETTES["light"]["drive_primary"], json.dumps(roads))

    def test_phone_drive_is_untouched_by_the_car(self):
        self.assertEqual(make_style.DRIVE_ASPHALT, (15, 16))
        self.assertEqual(make_style.drive_overrides("dark"), {})

    def test_file_names_match_the_app(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
        with open(os.path.join(root, "RadarMap", "Models", "CarMapStyle.swift"), encoding="utf-8") as handle:
            swift = handle.read()
        for name, _, _ in make_style.CAR_FILES:
            self.assertIn('"' + name[:-len(".json")] + '"', swift, name)


class Drive3DStyleTests(unittest.TestCase):
    """«Вождение 3D» (43): одна разница на тему, только известные свойства,
    объём ниже и не выше 15 м, ночью — без свечения магистрали."""

    @classmethod
    def setUpClass(cls):
        cls.diff = {theme: make_style.drive3d_overrides(theme) for theme in ("light", "dark")}

    def test_only_known_properties(self):
        for theme, diff in self.diff.items():
            self.assertLessEqual(set(diff), {"layers", "light"}, theme)
            self.assertEqual(set(diff.get("light", {})) - {"intensity"}, set(), theme)
            for layer_id, props in diff["layers"].items():
                self.assertLessEqual(set(props), set(make_style.CAR_PROPS), (theme, layer_id))

    def test_grey_asphalt_and_white_paint_and_kerbs(self):
        day = self.diff["light"]["layers"]
        self.assertIn(make_style.D3_LIGHT_ASPHALT, json.dumps(day["radar-roads"]["line-color"]))
        self.assertIn("#ffffff", json.dumps(day["radar-roads-case"]["line-color"]))
        self.assertNotIn("radar-markings", day, "разметка днём и так белая")
        night = self.diff["dark"]["layers"]
        self.assertEqual(night["radar-markings"]["line-color"], "#cbd1d9")

    def test_low_houses_softer_light(self):
        for theme, intensity in (("light", 0.55), ("dark", 0.3)):
            diff = self.diff[theme]
            height = json.dumps(diff["layers"]["building-3d"]["fill-extrusion-height"])
            self.assertIn('["min", 15, ["*", 0.45', height, theme)
            self.assertEqual(diff["light"], {"intensity": intensity}, theme)

    def test_night_has_no_trunk_glow(self):
        self.assertEqual(self.diff["dark"]["layers"]["radar-trunk-glow"]["line-opacity"], 0)

    def test_camera_and_route_layers_untouched(self):
        for theme, diff in self.diff.items():
            for layer_id in diff["layers"]:
                self.assertFalse(layer_id.startswith(("camera", "route", "traffic")), (theme, layer_id))

    def test_normal_palettes_unchanged(self):
        # Ключ потолка домов есть только у 3D: обычный стиль без него.
        for theme in ("light", "dark"):
            self.assertNotIn("building_height_max", make_style.PALETTES[theme])

    def test_file_names_match_the_app(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
        with open(os.path.join(root, "RadarMap", "Models", "Drive3D.swift"), encoding="utf-8") as handle:
            swift = handle.read()
        for name, _ in make_style.D3_FILES:
            self.assertIn('"' + name[:-len(".json")] + '"', swift, name)


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



class CarLaneMarkings(unittest.TestCase):
    def test_car_shows_lanes_at_its_driving_zoom(self):
        # Машина на ходу держит z16,0–17,2 (DriveCamera.carPitched): полосы
        # видны к 16,7, а не с 17,4, как у телефона.
        for theme, variant in (("light", "A"), ("dark", "A"), ("light", "B")):
            diff = make_style.car_overrides(theme, variant)["layers"]
            for layer_id in ("radar-markings", "radar-markings-solid"):
                ramp = diff[layer_id]["line-opacity"]
                self.assertEqual(ramp[3], make_style.CAR_LANE_MARKINGS_FROM)
                self.assertLessEqual(ramp[-2], 16.8, (theme, variant, layer_id))
                self.assertEqual(ramp[-1], 1)


if __name__ == "__main__":
    unittest.main()
