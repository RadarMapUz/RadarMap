import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import building_use as bu  # noqa: E402


def square(x, y, side, clockwise=True):
    """Кольцо квадрата в координатах тайла: по часовой на экране — внешнее."""
    ring = [(x, y), (x + side, y), (x + side, y + side), (x, y + side)]
    return ring if clockwise else ring[::-1]


def value(text_or_int):
    if isinstance(text_or_int, str):
        return bu._bytes_field(1, text_or_int.encode())
    return bu._put_varint((5 << 3) | 0) + bu._put_varint(text_or_int)


def layer(name, features):
    """features: [(тип, {свойства}, геометрия-команды)] → байты слоя."""
    out = bu.Layer(b"")
    out.name = name
    keys, values = {}, {}
    built = []
    for kind, props, geometry in features:
        feature = bu.Feature(b"")
        feature.type = kind
        for key, val in props.items():
            if key not in keys:
                keys[key] = len(out.keys)
                out.keys.append(key)
            if (key, val) not in values:
                values[(key, val)] = len(out.values)
                out.values.append(value(val))
            feature.tags += [keys[key], values[(key, val)]]
        feature.geometry = geometry
        built.append(feature)
    return out.to_bytes(built)


def points(*pts):
    cmd = [(len(pts) << 3) | 1]
    cx = cy = 0
    for x, y in pts:
        cmd += [bu._zigzag(x - cx), bu._zigzag(y - cy)]
        cx, cy = x, y
    return cmd


def tile(*layers):
    return b"".join(bu._bytes_field(3, body) for body in layers)


def buildings_of(body):
    """{use: [многоугольники]} и всё кольца слоя домов."""
    for field, _w, data, _raw in bu._fields(body):
        if field == 3 and bu.Layer(data).name == "building":
            lay = bu.Layer(data)
            out = {}
            for feature in lay.decoded():
                use = lay.props(feature).get("use")
                out.setdefault(use, []).extend(bu.polygons_of(bu.rings(feature.geometry)))
            return out, lay
    return {}, None


A, B, C = square(100, 100, 200), square(1000, 1000, 200), square(2000, 2000, 300)
HOLE = square(2100, 2100, 100, clockwise=False)
HOUSES = layer("building", [(3, {"render_height": 5}, bu.encode_polygons([[A], [B], [C, HOLE]]))])


class TagTileTests(unittest.TestCase):
    def test_poi_inside_and_territory_under_give_the_use(self):
        body = tile(HOUSES,
                    layer("poi", [(1, {"class": "hospital", "subclass": "clinic"}, points((200, 200)))]),
                    layer("landuse", [(3, {"class": "school"},
                                       bu.encode_polygons([[square(900, 900, 500)]]))]))
        uses, lay = buildings_of(bu.tag_tile(body, 0, 0))
        self.assertEqual(uses["health"], [[A]])
        self.assertEqual(uses["education"], [[B]])
        self.assertEqual(uses[None], [[C, HOLE]], "дом с двором (дырой) остаётся с двором")
        # Свойства исходного объекта (высота) переходят на дом с назначением.
        for feature in lay.decoded():
            self.assertEqual(lay.props(feature)["render_height"], 5)

    def test_every_vertex_survives(self):
        body = tile(HOUSES, layer("landuse", [(3, {"class": "industrial"},
                                               bu.encode_polygons([[square(0, 0, 4096)]]))]))
        before = sorted(map(tuple, bu.rings(bu.Feature(bu.Layer(HOUSES).features[0]).geometry)))
        uses, lay = buildings_of(bu.tag_tile(body, 0, 0))
        after = sorted(tuple(r) for f in lay.decoded() for r in bu.rings(f.geometry))
        self.assertEqual(before, after)
        self.assertEqual(set(uses), {"industrial"})

    def test_shop_on_the_ground_floor_does_not_make_a_shop(self):
        # Аптека и магазин у дома — на первых этажах жилых домов.
        body = tile(HOUSES, layer("poi", [(1, {"class": "pharmacy", "subclass": "pharmacy"}, points((200, 200))),
                                          (1, {"class": "shop", "subclass": "convenience"}, points((1100, 1100)))]))
        self.assertEqual(bu.tag_tile(body, 0, 0), body, "без доводов тайл тот же байт в байт")

    def test_hospital_beats_the_industrial_zone(self):
        body = tile(HOUSES,
                    layer("poi", [(1, {"class": "hospital", "subclass": "hospital"}, points((150, 150)))]),
                    layer("landuse", [(3, {"class": "industrial"}, bu.encode_polygons([[square(0, 0, 600)]]))]))
        uses, _ = buildings_of(bu.tag_tile(body, 0, 0))
        self.assertEqual(uses["health"], [[A]])

    def test_offices_are_not_shops(self):
        body = tile(HOUSES, layer("landuse", [(3, {"class": "commercial"},
                                               bu.encode_polygons([[square(0, 0, 4096)]]))]))
        self.assertEqual(bu.tag_tile(body, 0, 0), body)

    def test_not_a_tile_or_no_buildings_is_passed_through(self):
        self.assertEqual(bu.tag_tile(b"tile", 0, 0), b"tile")
        roads = tile(layer("transportation", [(2, {"class": "primary"}, points((0, 0)))]))
        self.assertEqual(bu.tag_tile(roads, 0, 0), roads)

    def test_already_tagged_tile_is_left_alone(self):
        body = tile(HOUSES, layer("landuse", [(3, {"class": "school"},
                                               bu.encode_polygons([[square(0, 0, 4096)]]))]))
        once = bu.tag_tile(body, 0, 0)
        self.assertEqual(bu.tag_tile(once, 0, 0), once)

    def test_other_layers_are_copied_byte_for_byte(self):
        poi = layer("poi", [(1, {"class": "school", "subclass": "school"}, points((200, 200)))])
        body = tile(HOUSES, poi)
        tagged = bu.tag_tile(body, 0, 0)
        self.assertNotEqual(tagged, body)
        self.assertTrue(tagged.endswith(bu._bytes_field(3, poi)))


class FootprintTests(unittest.TestCase):
    """Теги самого здания из экстракта домов — в координатах lon/lat."""

    def footprints(self, use, ring_tile, x=11344, y=6123):
        out = bu.Footprints()
        # Обратно из координат тайла в градусы: линейно внутри тайла хватает.
        import math

        def lonlat(px, py):
            n = 1 << bu.ZOOM
            lon = (x + px / 4096) / n * 360 - 180
            lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + py / 4096) / n))))
            return lon, lat
        out.add(use, [lonlat(px, py) for px, py in ring_tile])
        return out

    def test_building_tag_alone_gives_the_use(self):
        body = tile(HOUSES, layer("poi", []))
        uses, _ = buildings_of(bu.tag_tile(body, 11344, 6123, self.footprints("retail", square(950, 950, 300))))
        self.assertEqual(uses["retail"], [[B]])

    def test_residential_building_keeps_its_grey_in_a_school_yard(self):
        body = tile(HOUSES, layer("landuse", [(3, {"class": "school"},
                                               bu.encode_polygons([[square(0, 0, 4096)]]))]))
        uses, _ = buildings_of(bu.tag_tile(body, 11344, 6123,
                                           self.footprints("residential", square(950, 950, 300))))
        self.assertEqual(uses[None], [[B]])
        self.assertEqual(len(uses["education"]), 2)


class TagsTests(unittest.TestCase):
    def test_osm_tags(self):
        self.assertEqual(bu.tags_use({"building": "school"}), "education")
        self.assertEqual(bu.tags_use({"building": "yes", "amenity": "hospital"}), "health")
        self.assertEqual(bu.tags_use({"building": "yes", "shop": "mall"}), "retail")
        self.assertEqual(bu.tags_use({"building": "warehouse"}), "industrial")
        self.assertEqual(bu.tags_use({"building": "mosque"}), "religious")
        self.assertEqual(bu.tags_use({"building": "apartments"}), "residential")
        self.assertIsNone(bu.tags_use({"building": "yes"}))
        self.assertIsNone(bu.tags_use({"building": "commercial"}), "офисы — не магазин")
        # Поликлиника в торговом центре — поликлиника.
        self.assertEqual(bu.tags_use({"building": "retail", "amenity": "clinic"}), "health")

    def test_uses_match_the_style(self):
        import make_style
        self.assertEqual(set(bu.PRIORITY), set(make_style.BUILDING_USES))
        for theme in make_style.PALETTES.values():
            self.assertEqual(set(theme["building_use"]), set(bu.PRIORITY))
            self.assertEqual(set(theme["drive_building_use"]), set(bu.PRIORITY))


class GeometryTests(unittest.TestCase):
    def test_inner_point_of_an_l_shape_is_inside(self):
        ell = [(0, 0), (300, 0), (300, 100), (100, 100), (100, 300), (0, 300)]
        x, y = bu.inner_point([ell])
        self.assertTrue(bu.contains([ell], x, y))

    def test_directory_pass_counts_and_rewrites(self):
        root = tempfile.mkdtemp()
        folder = os.path.join(root, "14", "5")
        os.makedirs(folder)
        body = tile(HOUSES, layer("landuse", [(3, {"class": "school"},
                                               bu.encode_polygons([[square(0, 0, 4096)]]))]))
        with open(os.path.join(folder, "7.pbf"), "wb") as handle:
            handle.write(body)
        seen, changed, before, after = bu.tag_directory(root)
        self.assertEqual((seen, changed, before), (1, 1, len(body)))
        self.assertGreater(after, before)


if __name__ == "__main__":
    unittest.main()
