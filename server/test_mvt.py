"""Проверка кодировщика MVT — РАЗБОРОМ, а не сверкой байтов.

Тест, сравнивающий вывод с записанной строкой байтов, доказывает лишь то, что
код не менялся. Здесь свой маленький разборщик: он читает то, что мы написали,
и проверяет, что обратно получилось ровно то же самое. Ошибка в кодировщике
проваливает разбор, а не «отличается от эталона».
"""
import struct
import unittest

import mvt


def read_varint(data, at):
    value, shift = 0, 0
    while True:
        piece = data[at]
        at += 1
        value |= (piece & 0x7F) << shift
        if not piece & 0x80:
            return value, at
        shift += 7


def unzigzag(value):
    return (value >> 1) ^ -(value & 1)


def parse(data):
    """Разобрать тайл в {имя слоя: {...}}."""
    layers, at = {}, 0
    while at < len(data):
        key, at = read_varint(data, at)
        field, wire = key >> 3, key & 7
        assert wire == 2, f"поле {field} пришло не длиной-с-префиксом"
        size, at = read_varint(data, at)
        body, at = data[at:at + size], at + size
        assert field == 3, f"в тайле поле {field}, а слои — поле 3"
        layer = parse_layer(body)
        layers[layer["name"]] = layer
    return layers


def parse_layer(data):
    out = {"name": None, "features": [], "keys": [], "values": [],
           "extent": 4096, "version": None}
    at = 0
    while at < len(data):
        key, at = read_varint(data, at)
        field, wire = key >> 3, key & 7
        if wire == 2:
            size, at = read_varint(data, at)
            body, at = data[at:at + size], at + size
            if field == 1:
                out["name"] = body.decode("utf-8")
            elif field == 2:
                out["features"].append(parse_feature(body))
            elif field == 3:
                out["keys"].append(body.decode("utf-8"))
            elif field == 4:
                out["values"].append(parse_value(body))
        else:
            value, at = read_varint(data, at)
            if field == 5:
                out["extent"] = value
            elif field == 15:
                out["version"] = value
    return out


def parse_value(data):
    key, at = read_varint(data, 0)
    field, wire = key >> 3, key & 7
    if field == 1:
        size, at = read_varint(data, at)
        return data[at:at + size].decode("utf-8")
    if field == 3:
        return struct.unpack("<d", data[at:at + 8])[0]
    if field == 4:
        return read_varint(data, at)[0]
    if field == 6:
        return unzigzag(read_varint(data, at)[0])
    if field == 7:
        return bool(read_varint(data, at)[0])
    raise AssertionError(f"неизвестное поле значения: {field}")


def parse_feature(data):
    out = {"tags": [], "type": 0, "geometry": []}
    at = 0
    while at < len(data):
        key, at = read_varint(data, at)
        field, wire = key >> 3, key & 7
        if wire == 2:
            size, at = read_varint(data, at)
            body, at = data[at:at + size], at + size
            numbers, inner = [], 0
            while inner < len(body):
                number, inner = read_varint(body, inner)
                numbers.append(number)
            out["tags" if field == 2 else "geometry"] = numbers
        else:
            value, at = read_varint(data, at)
            if field == 3:
                out["type"] = value
    return out


def shapes_of(feature):
    """Команды геометрии обратно в списки точек."""
    out, current, x, y = [], [], 0, 0
    numbers, at = feature["geometry"], 0
    while at < len(numbers):
        command = numbers[at]
        at += 1
        kind, count = command & 0x7, command >> 3
        if kind == 7:
            if current:
                out.append(current)
                current = []
            continue
        for _ in range(count):
            x += unzigzag(numbers[at])
            y += unzigzag(numbers[at + 1])
            at += 2
            if kind == 1 and current:
                out.append(current)
                current = []
            current.append((x, y))
    if current:
        out.append(current)
    return out


class EncoderTests(unittest.TestCase):

    def layer_with(self, kind, shapes, props=None, name="проба"):
        layer = mvt.Layer(name)
        layer.add(kind, shapes, props)
        return parse(mvt.tile_bytes([layer]))[name]

    def test_line_survives_the_round_trip(self):
        points = [(10, 20), (300, 400), (500, 450)]
        layer = self.layer_with(mvt.LINESTRING, [points])
        self.assertEqual(layer["version"], 2)
        self.assertEqual(layer["extent"], mvt.EXTENT)
        self.assertEqual(len(layer["features"]), 1)
        self.assertEqual(layer["features"][0]["type"], mvt.LINESTRING)
        self.assertEqual(shapes_of(layer["features"][0]), [points])

    def test_point_survives_the_round_trip(self):
        layer = self.layer_with(mvt.POINT, [[(7, 9)]])
        self.assertEqual(shapes_of(layer["features"][0]), [[(7, 9)]])

    def test_polygon_closes_itself(self):
        ring = [(0, 0), (100, 0), (100, 100), (0, 100)]
        layer = self.layer_with(mvt.POLYGON, [ring])
        got = shapes_of(layer["features"][0])[0]
        self.assertEqual(len(got), 4, "замыкание повторило первую точку")

    def test_repeated_last_point_is_dropped(self):
        ring = [(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)]
        layer = self.layer_with(mvt.POLYGON, [ring])
        self.assertEqual(len(shapes_of(layer["features"][0])[0]), 4)

    def test_outer_ring_goes_clockwise(self):
        # Кольцо не с той стороны читается ДЫРКОЙ, и дом становится вырезом
        # в квартале. Спецификация требует по часовой в экранных координатах.
        counter = [(0, 0), (0, 100), (100, 100), (100, 0)]
        got = shapes_of(self.layer_with(mvt.POLYGON, [counter])["features"][0])[0]
        self.assertTrue(mvt._ring_is_clockwise(got), "внешнее кольцо против часовой")

    def test_properties_travel(self):
        layer = self.layer_with(mvt.LINESTRING, [[(0, 0), (10, 10)]],
                                {"cls": 3, "name": "Навои", "bridge": True,
                                 "width": 11.2})
        feature = layer["features"][0]
        got = {layer["keys"][feature["tags"][i]]: layer["values"][feature["tags"][i + 1]]
               for i in range(0, len(feature["tags"]), 2)}
        self.assertEqual(got["cls"], 3)
        self.assertEqual(got["name"], "Навои")
        self.assertEqual(got["bridge"], True)
        self.assertAlmostEqual(got["width"], 11.2, places=6)

    def test_empty_properties_are_not_written(self):
        layer = self.layer_with(mvt.LINESTRING, [[(0, 0), (10, 10)]],
                                {"name": "", "cls": None})
        self.assertEqual(layer["features"][0]["tags"], [])
        self.assertEqual(layer["keys"], [])

    def test_same_value_is_stored_once(self):
        layer = mvt.Layer("проба")
        for _ in range(5):
            layer.add(mvt.LINESTRING, [[(0, 0), (10, 10)]], {"cls": 3})
        parsed = parse(mvt.tile_bytes([layer]))["проба"]
        self.assertEqual(parsed["values"], [3], "значение записано пять раз")
        self.assertEqual(parsed["keys"], ["cls"])

    def test_empty_layer_is_not_written(self):
        self.assertEqual(mvt.tile_bytes([mvt.Layer("пусто")]), b"")

    def test_several_layers_land_side_by_side(self):
        first, second = mvt.Layer("дороги"), mvt.Layer("дома")
        first.add(mvt.LINESTRING, [[(0, 0), (10, 10)]])
        second.add(mvt.POLYGON, [[(0, 0), (10, 0), (10, 10)]])
        parsed = parse(mvt.tile_bytes([first, second]))
        self.assertEqual(sorted(parsed), ["дома", "дороги"])

    def test_degenerate_shapes_are_skipped(self):
        layer = mvt.Layer("проба")
        layer.add(mvt.LINESTRING, [[(1, 1)]])
        layer.add(mvt.POLYGON, [[(1, 1), (2, 2)]])
        self.assertEqual(mvt.tile_bytes([layer]), b"")


class ProjectionTests(unittest.TestCase):

    def test_point_lands_inside_its_tile(self):
        lat, lon, zoom = 41.311, 69.280, 14
        tx, ty = mvt.tile_of(lat, lon, zoom)
        x, y = mvt.project(lat, lon, zoom, tx, ty)
        self.assertTrue(0 <= x <= mvt.EXTENT, x)
        self.assertTrue(0 <= y <= mvt.EXTENT, y)

    def test_north_is_up(self):
        zoom = 14
        tx, ty = mvt.tile_of(41.311, 69.280, zoom)
        south = mvt.project(41.310, 69.280, zoom, tx, ty)
        north = mvt.project(41.312, 69.280, zoom, tx, ty)
        self.assertLess(north[1], south[1], "север оказался внизу")

    def test_east_is_right(self):
        zoom = 14
        tx, ty = mvt.tile_of(41.311, 69.280, zoom)
        west = mvt.project(41.311, 69.279, zoom, tx, ty)
        east = mvt.project(41.311, 69.281, zoom, tx, ty)
        self.assertLess(west[0], east[0], "восток оказался слева")

    def test_neighbouring_tiles_differ(self):
        zoom = 14
        self.assertNotEqual(mvt.tile_of(41.311, 69.280, zoom),
                            mvt.tile_of(41.311, 69.320, zoom))


if __name__ == "__main__":
    unittest.main()
