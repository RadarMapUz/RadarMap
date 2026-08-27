"""MVT: тайл в стандартном векторном формате, рядом с нашим.

Зачем. Наш JSON читают телефон и панель, и он останется — переход идёт
параллельно, а не заменой. Но всё, что умеет рисовать векторные карты в
браузере (MapLibre, deck.gl, любой стандартный стек), говорит на MVT. Пока мы
пишем только свой формат, переход на другой движок — это переписывание
конвейера; когда MVT лежит рядом, это подключение читателя.

Почему без библиотек. В проекте намеренно нет сборочного конвейера и нет
зависимостей у сервера: он поднимается на голой стандартной библиотеке Python
на машине с двумя гигабайтами. Тянуть protobuf-компилятор ради формата, у
которого вся схема — четыре сообщения, значило бы платить конвейером за
экономию двухсот строк.

Формат описан в спецификации Mapbox Vector Tile 2.1. Здесь ровно то, что нужно
для записи: варинты, зигзаг, три типа геометрии и команды MoveTo/LineTo/
ClosePath. Читать MVT мы не умеем и не должны — читатели у него чужие.
"""
import math
import struct

# Сторона тайла во внутренних координатах. 4096 — значение по умолчанию в
# спецификации: при нём шаг сетки на зуме 14 около полуметра, то есть мельче,
# чем наши координаты в тайле (1e-5° ≈ 1,1 м).
EXTENT = 4096

POINT, LINESTRING, POLYGON = 1, 2, 3

_MOVE_TO, _LINE_TO, _CLOSE_PATH = 1, 2, 7


def varint(value):
    out = bytearray()
    while True:
        piece = value & 0x7F
        value >>= 7
        if value:
            out.append(piece | 0x80)
        else:
            out.append(piece)
            return bytes(out)


def zigzag(value):
    return (value << 1) ^ (value >> 31) if value >= 0 else ((-value) << 1) - 1


def _key(field, wire):
    return varint((field << 3) | wire)


def _bytes_field(field, payload):
    return _key(field, 2) + varint(len(payload)) + payload


def _varint_field(field, value):
    return _key(field, 0) + varint(value)


def _packed(field, numbers):
    body = b"".join(varint(n) for n in numbers)
    return _bytes_field(field, body)


def _command(kind, count):
    return (kind & 0x7) | (count << 3)


def tile_of(lat, lon, zoom):
    """Номер тайла web-mercator, в котором лежит точка."""
    scale = 1 << zoom
    x = (lon + 180.0) / 360.0 * scale
    sin = math.sin(math.radians(lat))
    sin = min(max(sin, -0.9999), 0.9999)
    y = (0.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * scale
    return int(x), int(y)


def project(lat, lon, zoom, tile_x, tile_y, extent=EXTENT):
    """Точка в координатах тайла. За краями значения выходят за 0..extent —
    так и должно быть: спецификация это разрешает, а клиент режет сам."""
    scale = 1 << zoom
    x = (lon + 180.0) / 360.0 * scale
    sin = math.sin(math.radians(lat))
    sin = min(max(sin, -0.9999), 0.9999)
    y = (0.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * scale
    return (int(round((x - tile_x) * extent)),
            int(round((y - tile_y) * extent)))


def _ring_is_clockwise(points):
    """Площадь по формуле шнурков в ЭКРАННЫХ координатах (y вниз).

    Спецификация требует: внешнее кольцо обходится по часовой стрелке,
    дырка — против. Кольцо не с той стороны читается дыркой, и дом
    превращается в вырез в квартале.
    """
    total = 0
    for i in range(len(points)):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % len(points)]
        total += (x2 - x1) * (y2 + y1)
    return total > 0


def encode_geometry(kind, shapes):
    """Команды геометрии: последовательность MoveTo/LineTo/ClosePath."""
    out, cx, cy = [], 0, 0
    for points in shapes:
        if not points:
            continue
        if kind == POINT:
            out.append(_command(_MOVE_TO, len(points)))
            for x, y in points:
                out.extend([zigzag(x - cx), zigzag(y - cy)])
                cx, cy = x, y
            continue
        ring = list(points)
        if kind == POLYGON:
            # Замыкание — командой ClosePath, а не повтором первой точки:
            # лишняя вершина в кольце для читателя ошибка формата.
            if len(ring) > 1 and ring[0] == ring[-1]:
                ring = ring[:-1]
            if len(ring) < 3:
                continue
            if not _ring_is_clockwise(ring):
                ring.reverse()
        if len(ring) < 2:
            continue
        first = ring[0]
        out.append(_command(_MOVE_TO, 1))
        out.extend([zigzag(first[0] - cx), zigzag(first[1] - cy)])
        cx, cy = first
        rest = ring[1:]
        out.append(_command(_LINE_TO, len(rest)))
        for x, y in rest:
            out.extend([zigzag(x - cx), zigzag(y - cy)])
            cx, cy = x, y
        if kind == POLYGON:
            out.append(_command(_CLOSE_PATH, 1))
    return out


class Layer:
    """Слой тайла: имя, свойства и фигуры одного вида."""

    def __init__(self, name, extent=EXTENT):
        self.name = name
        self.extent = extent
        self.keys = []
        self._key_at = {}
        self.values = []
        self._value_at = {}
        self.features = []

    def _tag_pair(self, key, value):
        if key not in self._key_at:
            self._key_at[key] = len(self.keys)
            self.keys.append(key)
        mark = (type(value).__name__, value)
        if mark not in self._value_at:
            self._value_at[mark] = len(self.values)
            self.values.append(value)
        return self._key_at[key], self._value_at[mark]

    def add(self, kind, shapes, props=None):
        tags = []
        for key, value in sorted((props or {}).items()):
            if value is None or value == "":
                continue
            k, v = self._tag_pair(key, value)
            tags.extend([k, v])
        geometry = encode_geometry(kind, shapes)
        if not geometry:
            return
        self.features.append((kind, tags, geometry))

    def _value_bytes(self, value):
        if isinstance(value, bool):
            return _varint_field(7, 1 if value else 0)
        if isinstance(value, int):
            return _varint_field(4, value) if value >= 0 else \
                _key(6, 0) + varint(zigzag(value))
        if isinstance(value, float):
            return _key(3, 1) + struct.pack("<d", value)
        return _bytes_field(1, str(value).encode("utf-8"))

    def to_bytes(self):
        body = _bytes_field(1, self.name.encode("utf-8"))
        for kind, tags, geometry in self.features:
            feature = b""
            if tags:
                feature += _packed(2, tags)
            feature += _varint_field(3, kind)
            feature += _packed(4, geometry)
            body += _bytes_field(2, feature)
        for key in self.keys:
            body += _bytes_field(3, key.encode("utf-8"))
        for value in self.values:
            body += _bytes_field(4, self._value_bytes(value))
        body += _varint_field(5, self.extent)
        body += _varint_field(15, 2)
        return body


def tile_bytes(layers):
    """Готовый .mvt: слои подряд, каждый — поле 3 сообщения Tile."""
    return b"".join(_bytes_field(3, layer.to_bytes())
                    for layer in layers if layer.features)
