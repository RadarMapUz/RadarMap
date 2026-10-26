#!/usr/bin/env python3
"""Назначение дома в тайлах основы: больница, школа, магазин, промзона, храм (30.A).

Яндекс красит дома по назначению мягкими оттенками — больницу розоватым, школу
жёлтым, торговый центр сиреневым, — и город читается с одного взгляда: где
поликлиника, где школа у дома. В OpenMapTiles у слоя building такого свойства
нет (только высоты и colour), а Planetiler на z14 ещё и склеивает все дома
одной высоты в один мультиполигон — свойство «на дом» туда не положить.

Поэтому назначение дописывается в готовый тайл z14 при выгрузке
(export_mbtiles): мультиполигон режется на дома, каждый дом получает
`use` по тому, что о нём известно, и дома с одинаковыми свойствами снова
собираются в один объект. Геометрия та же, байт в байт по вершинам: дубль
дома в нашем слое лёг бы стена в стену с домом основы и мерцал бы (z-fighting),
а весил бы как второй слой домов.

Откуда назначение, по убыванию доверия:
1. теги самого здания OSM (`building=school`, `amenity=hospital` на контуре) —
   из экстракта домов (`houses.geojsonl`, тот же, что у сборки дорог); без него
   этот шаг просто пропускается;
2. точка заведения ВНУТРИ контура (слой poi того же тайла): больница,
   поликлиника, школа, детсад, вуз, рынок, торговый центр, храм. Магазин у
   дороги и аптека — нет: в Ташкенте они на первых этажах жилых домов, и
   девятиэтажка с аптекой стала бы «больницей»;
3. территория, на которой стоит дом (слой landuse того же тайла): больничный
   городок, школьный двор, рынок, промзона. Явно жилой дом (`house`,
   `apartments`, …) территорией не перекрашивается — дома махалли у
   небрежно обведённого завода остаются домами.

Чего нет: красного (красный на карте — только камеры, см. make_style),
офисов (`landuse=commercial` — это офисы, не магазины) и неизвестного —
без доказательства дом остаётся обычным серым.

    python3 server/omt/building_use.py <каталог omt> [--houses houses.geojsonl] [--bbox w,s,e,n]
"""
import json
import math
import os
import struct
import sys

# Значения свойства `use` — контракт со стилем (make_style.BUILDING_USES).
HEALTH, EDUCATION, RETAIL, INDUSTRIAL, RELIGIOUS = "health", "education", "retail", "industrial", "religious"
# Порядок важности, когда доводов несколько: больница в торговом центре — больница.
PRIORITY = (HEALTH, EDUCATION, RELIGIOUS, RETAIL, INDUSTRIAL)
USE_KEY = "use"
ZOOM = 14

# Теги здания OSM → назначение.
BUILDING_TAGS = {
    "hospital": HEALTH, "clinic": HEALTH,
    "school": EDUCATION, "kindergarten": EDUCATION, "university": EDUCATION, "college": EDUCATION,
    "retail": RETAIL, "store": RETAIL, "supermarket": RETAIL, "kiosk": RETAIL, "mall": RETAIL,
    "industrial": INDUSTRIAL, "warehouse": INDUSTRIAL, "factory": INDUSTRIAL, "manufacture": INDUSTRIAL,
    "hangar": INDUSTRIAL,
    "mosque": RELIGIOUS, "church": RELIGIOUS, "cathedral": RELIGIOUS, "chapel": RELIGIOUS,
    "synagogue": RELIGIOUS, "temple": RELIGIOUS, "religious": RELIGIOUS, "shrine": RELIGIOUS,
}
AMENITY_TAGS = {"hospital": HEALTH, "clinic": HEALTH, "school": EDUCATION, "kindergarten": EDUCATION,
                "university": EDUCATION, "college": EDUCATION, "marketplace": RETAIL,
                "place_of_worship": RELIGIOUS}
SHOP_TAGS = {"mall": RETAIL, "department_store": RETAIL, "supermarket": RETAIL, "wholesale": RETAIL}
HEALTHCARE_TAGS = {"hospital": HEALTH, "clinic": HEALTH}
# Явно жилые: их территория не перекрашивает (шаг 3), а точка внутри — да
# (поликлиника на первом этаже в OSM обычно своей точкой, но и пусть).
RESIDENTIAL = {"house", "apartments", "residential", "detached", "semidetached_house", "terrace",
               "bungalow", "dormitory", "garage", "garages", "carport"}
# Точки заведений OpenMapTiles (class, subclass) → назначение. Подкласс None —
# любой подкласс класса.
POI_USES = {("hospital", "hospital"): HEALTH, ("hospital", "clinic"): HEALTH,
            ("school", "school"): EDUCATION, ("school", "kindergarten"): EDUCATION,
            ("college", "college"): EDUCATION, ("college", "university"): EDUCATION,
            ("grocery", "marketplace"): RETAIL, ("shop", "mall"): RETAIL,
            ("grocery", "department_store"): RETAIL, ("shop", "department_store"): RETAIL,
            ("place_of_worship", None): RELIGIOUS}
# Территории OpenMapTiles (landuse.class) → назначение.
LANDUSE_USES = {"hospital": HEALTH, "school": EDUCATION, "kindergarten": EDUCATION,
                "college": EDUCATION, "university": EDUCATION, "education": EDUCATION,
                "retail": RETAIL, "industrial": INDUSTRIAL}


def tags_use(props):
    """Назначение по тегам здания OSM; RESIDENTIAL — «явно жилой»; None — не знаем."""
    building = str(props.get("building") or "").split(";")[0].strip()
    found = [BUILDING_TAGS.get(building), AMENITY_TAGS.get(props.get("amenity")),
             SHOP_TAGS.get(props.get("shop")), HEALTHCARE_TAGS.get(props.get("healthcare"))]
    found = [u for u in found if u]
    if found:
        return min(found, key=PRIORITY.index)
    if building in RESIDENTIAL:
        return "residential"
    return None


# --- protobuf / MVT ---------------------------------------------------------
# Чтение ровно того, что нужно: слои, объекты, ключи и значения. Остальное в
# тайле переносится как было — нетронутые слои копируются байтами.

def _varint(data, i):
    out = shift = 0
    while True:
        byte = data[i]
        i += 1
        out |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return out, i


def _fields(data):
    i, n = 0, len(data)
    while i < n:
        start = i
        key, i = _varint(data, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(data, i)
        elif wire == 2:
            size, i = _varint(data, i)
            value = data[i:i + size]
            i += size
        elif wire == 1:
            value = data[i:i + 8]
            i += 8
        elif wire == 5:
            value = data[i:i + 4]
            i += 4
        else:
            raise ValueError(f"тип поля {wire}")
        if i > n:
            raise ValueError("обрезанное поле")
        yield field, wire, value, data[start:i]


def _put_varint(value):
    out = bytearray()
    while True:
        piece = value & 0x7F
        value >>= 7
        if value:
            out.append(piece | 0x80)
        else:
            out.append(piece)
            return bytes(out)


def _bytes_field(field, payload):
    return _put_varint((field << 3) | 2) + _put_varint(len(payload)) + payload


def _packed_field(field, numbers):
    return _bytes_field(field, b"".join(_put_varint(n) for n in numbers))


def _unpack(data):
    out, i = [], 0
    while i < len(data):
        value, i = _varint(data, i)
        out.append(value)
    return out


def _value(data):
    for field, _wire, value, _raw in _fields(data):
        if field == 1:
            return value.decode("utf-8")
        if field == 2:
            return struct.unpack("<f", value)[0]
        if field == 3:
            return struct.unpack("<d", value)[0]
        if field in (4, 5):
            return value
        if field == 6:
            return (value >> 1) ^ -(value & 1)
        if field == 7:
            return bool(value)
    return None


class Feature:
    __slots__ = ("id", "tags", "type", "geometry")

    def __init__(self, data):
        self.id, self.tags, self.type, self.geometry = None, [], 0, []
        for field, _wire, value, _raw in _fields(data):
            if field == 1:
                self.id = value
            elif field == 2:
                self.tags = _unpack(value)
            elif field == 3:
                self.type = value
            elif field == 4:
                self.geometry = _unpack(value)

    def to_bytes(self):
        out = b""
        if self.id is not None:
            out += _put_varint(1 << 3) + _put_varint(self.id)
        if self.tags:
            out += _packed_field(2, self.tags)
        out += _put_varint(3 << 3) + _put_varint(self.type)
        out += _packed_field(4, self.geometry)
        return out


class Layer:
    """Слой тайла: имя, объекты, ключи, значения (сырые байты значений)."""

    def __init__(self, data):
        self.name, self.extent, self.version = "", 4096, 2
        self.features, self.keys, self.values = [], [], []
        for field, _wire, value, _raw in _fields(data):
            if field == 1:
                self.name = value.decode("utf-8")
            elif field == 2:
                self.features.append(value)
            elif field == 3:
                self.keys.append(value.decode("utf-8"))
            elif field == 4:
                self.values.append(value)
            elif field == 5:
                self.extent = value
            elif field == 15:
                self.version = value

    def decoded(self):
        return [Feature(f) for f in self.features]

    def props(self, feature):
        t = feature.tags
        return {self.keys[t[k]]: _value(self.values[t[k + 1]]) for k in range(0, len(t) - 1, 2)}

    def to_bytes(self, features):
        body = _bytes_field(1, self.name.encode("utf-8"))
        for feature in features:
            body += _bytes_field(2, feature.to_bytes())
        for key in self.keys:
            body += _bytes_field(3, key.encode("utf-8"))
        for value in self.values:
            body += _bytes_field(4, value)
        body += _put_varint(5 << 3) + _put_varint(self.extent)
        body += _put_varint(15 << 3) + _put_varint(self.version)
        return body


def _zz(n):
    return (n >> 1) ^ -(n & 1)


def _zigzag(n):
    return (n << 1) ^ (n >> 63)


def rings(geometry):
    """Команды геометрии → [[(x, y), …]] без повторной точки замыкания."""
    out, cur, x, y, i = [], None, 0, 0, 0
    while i < len(geometry):
        command, count = geometry[i] & 7, geometry[i] >> 3
        i += 1
        if command == 7:
            if cur:
                out.append(cur)
            cur = None
            continue
        for _ in range(count):
            x += _zz(geometry[i])
            y += _zz(geometry[i + 1])
            i += 2
            if command == 1:
                if cur:
                    out.append(cur)
                cur = [(x, y)]
            else:
                cur.append((x, y))
    if cur:
        out.append(cur)
    return out


def encode_polygons(polygons):
    """[[кольцо, …], …] → команды; курсор продолжается между кольцами."""
    out, cx, cy = [], 0, 0
    for polygon in polygons:
        for ring in polygon:
            out.append((1 << 3) | 1)
            out += [_zigzag(ring[0][0] - cx), _zigzag(ring[0][1] - cy)]
            cx, cy = ring[0]
            out.append(((len(ring) - 1) << 3) | 2)
            for px, py in ring[1:]:
                out += [_zigzag(px - cx), _zigzag(py - cy)]
                cx, cy = px, py
            out.append((1 << 3) | 7)
    return out


def signed_area(ring):
    return sum(ring[k][0] * ring[k - 1][1] - ring[k - 1][0] * ring[k][1] for k in range(len(ring))) / -2.0


def polygons_of(rings_):
    """Кольца мультиполигона → многоугольники: внешнее (площадь > 0 в
    экранных координатах MVT) и его дыры следом."""
    out = []
    for ring in rings_:
        if len(ring) < 3:
            continue
        if signed_area(ring) > 0 or not out:
            out.append([ring])
        else:
            out[-1].append(ring)
    return out


def contains(rings_, x, y):
    """Точка внутри фигуры по правилу чёт-нечет по всем кольцам."""
    inside = False
    for ring in rings_:
        j = len(ring) - 1
        for k in range(len(ring)):
            xi, yi = ring[k]
            xj, yj = ring[j]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                inside = not inside
            j = k
    return inside


def bbox(rings_):
    xs = [p[0] for r in rings_ for p in r]
    ys = [p[1] for r in rings_ for p in r]
    return min(xs), min(ys), max(xs), max(ys)


def inner_point(polygon):
    """Точка внутри дома: центр тяжести внешнего кольца, а если он снаружи
    (дом «буквой Г») — середина самого широкого отрезка сечения на его высоте."""
    outer = polygon[0]
    area = 0.0
    cx = cy = 0.0
    for k in range(len(outer)):
        x0, y0 = outer[k - 1]
        x1, y1 = outer[k]
        cross = x0 * y1 - x1 * y0
        area += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if area:
        cx, cy = cx / (3 * area), cy / (3 * area)
    else:
        cx = sum(p[0] for p in outer) / len(outer)
        cy = sum(p[1] for p in outer) / len(outer)
    if contains(polygon, cx, cy):
        return cx, cy
    y = cy
    if any(p[1] == y for r in polygon for p in r):
        y += 0.25
    crossings = sorted(
        (xj - xi) * (y - yi) / (yj - yi) + xi
        for r in polygon for (xi, yi), (xj, yj) in zip(r, r[1:] + r[:1]) if (yi > y) != (yj > y))
    best = max(((b - a, (a + b) / 2) for a, b in zip(crossings[0::2], crossings[1::2])), default=None)
    return (best[1], y) if best else outer[0]


# --- проекция ---------------------------------------------------------------

def tile_point(lon, lat, x, y, extent=4096, zoom=ZOOM):
    n = 1 << zoom
    px = ((lon + 180.0) / 360.0 * n - x) * extent
    s = math.sin(math.radians(lat))
    py = ((0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n - y) * extent
    return px, py


def tile_of(lon, lat, zoom=ZOOM):
    px, py = tile_point(lon, lat, 0, 0, 1, zoom)
    return int(px), int(py)


class Footprints:
    """Контуры зданий OSM с назначением (или «явно жилой»), разложенные по тайлам z14."""

    def __init__(self):
        self.by_tile = {}
        self.count = 0

    def add(self, use, ring):
        lons = [p[0] for p in ring]
        lats = [p[1] for p in ring]
        x0, y0 = tile_of(min(lons), max(lats))
        x1, y1 = tile_of(max(lons), min(lats))
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 16:
            return                       # контур на полрайона — не дом
        item = (use, ring, (min(lons), min(lats), max(lons), max(lats)))
        for tx in range(x0, x1 + 1):
            for ty in range(y0, y1 + 1):
                self.by_tile.setdefault((tx, ty), []).append(item)
        self.count += 1

    def in_tile(self, x, y, extent):
        out = []
        for use, ring, _box in self.by_tile.get((x, y), ()):
            pts = [tile_point(lon, lat, x, y, extent) for lon, lat in ring]
            out.append((use, pts, bbox([pts])))
        return out


def load_footprints(path, area=None):
    """houses.geojsonl → Footprints: только дома с назначением и явно жилые."""
    out = Footprints()
    if not path or not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            use = tags_use(feature.get("properties") or {})
            if use is None:
                continue
            geometry = feature.get("geometry") or {}
            coords = geometry.get("coordinates") or []
            if geometry.get("type") == "Polygon":
                outer = coords[0] if coords else []
            elif geometry.get("type") == "MultiPolygon":
                outer = coords[0][0] if coords and coords[0] else []
            else:
                continue
            ring = [(float(p[0]), float(p[1])) for p in outer]
            if len(ring) < 4:
                continue
            if area and not (area[0] <= ring[0][0] <= area[2] and area[1] <= ring[0][1] <= area[3]):
                continue
            out.add(use, ring[:-1] if ring[0] == ring[-1] else ring)
    return out


# --- назначение дома в тайле ------------------------------------------------

def _poi_use(props):
    cls = props.get("class")
    return POI_USES.get((cls, props.get("subclass"))) or POI_USES.get((cls, None))


def _best(uses):
    uses = [u for u in uses if u in PRIORITY]
    return min(uses, key=PRIORITY.index) if uses else None


def classify(polygons, pois, territories, footprints=()):
    """Назначение каждого дома: [use | None] по порядку многоугольников.

    pois — [(x, y, use)], territories — [(use, кольца, рамка)],
    footprints — [(use | "residential", кольца-точки, рамка)].
    """
    out = []
    for polygon in polygons:
        box = bbox(polygon)
        px, py = inner_point(polygon)
        own = [u for u, ring, b in footprints
               if b[0] <= px <= b[2] and b[1] <= py <= b[3] and contains([ring], px, py)]
        use = _best(own)
        if use is None:
            use = _best([u for x, y, u in pois
                         if box[0] <= x <= box[2] and box[1] <= y <= box[3] and contains(polygon, x, y)])
        if use is None and "residential" not in own:
            use = _best([u for u, rs, b in territories
                         if b[0] <= px <= b[2] and b[1] <= py <= b[3] and contains(rs, px, py)])
        out.append(use)
    return out


def tag_tile(body, x, y, footprints=None):
    """Тело тайла z14 → тело с `use` у домов. Тайл без домов с назначением,
    без слоя домов или не MVT возвращается как был, байт в байт."""
    try:
        parts = list(_fields(body))
        layers = {}
        for field, _wire, value, _raw in parts:
            if field == 3:
                layer = Layer(value)
                layers.setdefault(layer.name, layer)
    except (ValueError, IndexError, UnicodeDecodeError, struct.error):
        return body
    building = layers.get("building")
    if building is None or USE_KEY in building.keys:
        return body
    extent = building.extent
    pois = []
    if "poi" in layers:
        layer = layers["poi"]
        for feature in layer.decoded():
            if feature.type != 1:
                continue
            use = _poi_use(layer.props(feature))
            if use:
                pois += [(px, py, use) for r in rings(feature.geometry) for px, py in r]
    territories = []
    if "landuse" in layers:
        layer = layers["landuse"]
        for feature in layer.decoded():
            use = LANDUSE_USES.get(layer.props(feature).get("class"))
            if use and feature.type == 3:
                rs = [r for r in rings(feature.geometry) if len(r) >= 3]
                if rs:
                    territories.append((use, rs, bbox(rs)))
    own = footprints.in_tile(x, y, extent) if footprints else []
    if not (pois or territories or [o for o in own if o[0] != "residential"]):
        return body
    features = building.decoded()
    out, changed = [], False
    groups = {}
    for feature in features:
        if feature.type != 3:
            out.append(feature)
            continue
        polygons = polygons_of(rings(feature.geometry))
        uses = classify(polygons, pois, territories, own)
        if not any(uses):
            out.append(feature)
            continue
        changed = True
        plain = [p for p, u in zip(polygons, uses) if u is None]
        if plain:
            feature.geometry = encode_polygons(plain)
            out.append(feature)
        for polygon, use in zip(polygons, uses):
            if use is not None:
                groups.setdefault((tuple(feature.tags), use), []).append(polygon)
    if not changed:
        return body
    key_index = len(building.keys)
    building.keys.append(USE_KEY)
    value_index = {}
    for (tags, use), polygons in sorted(groups.items(), key=lambda g: (PRIORITY.index(g[0][1]), g[0][0])):
        if use not in value_index:
            value_index[use] = len(building.values)
            building.values.append(_bytes_field(1, use.encode("utf-8")))
        extra = Feature(b"")
        extra.type = 3
        extra.tags = list(tags) + [key_index, value_index[use]]
        extra.geometry = encode_polygons(polygons)
        out.append(extra)
    rebuilt = building.to_bytes(out)
    pieces, done = [], False
    for field, _wire, value, raw in parts:
        if field == 3 and not done and Layer(value).name == "building":
            pieces.append(_bytes_field(3, rebuilt))
            done = True
        else:
            pieces.append(raw)
    return b"".join(pieces)


def tag_directory(root, footprints=None, area=None):
    """Каталог omt/z/x/y.pbf: дописать назначение в тайлы z14 на месте.
    Возвращает (тайлов просмотрено, изменено, байт до, байт после)."""
    seen = changed = before = after = 0
    folder = os.path.join(root, str(ZOOM))
    if area:
        x0, y0 = tile_of(area[0], area[3])
        x1, y1 = tile_of(area[2], area[1])
    for column in sorted(os.listdir(folder)) if os.path.isdir(folder) else ():
        if not column.isdigit():
            continue
        x = int(column)
        if area and not x0 <= x <= x1:
            continue
        for name in sorted(os.listdir(os.path.join(folder, column))):
            if not name.endswith(".pbf"):
                continue
            y = int(name[:-4])
            if area and not y0 <= y <= y1:
                continue
            path = os.path.join(folder, column, name)
            with open(path, "rb") as handle:
                body = handle.read()
            new = tag_tile(body, x, y, footprints)
            seen += 1
            before += len(body)
            after += len(new)
            if new != body:
                changed += 1
                with open(path, "wb") as handle:
                    handle.write(new)
    return seen, changed, before, after


def main(argv):
    root = argv[1]
    houses = argv[argv.index("--houses") + 1] if "--houses" in argv else None
    area = tuple(float(v) for v in argv[argv.index("--bbox") + 1].split(",")) if "--bbox" in argv else None
    footprints = load_footprints(houses, area)
    seen, changed, before, after = tag_directory(root, footprints, area)
    print(f"контуров с назначением: {footprints.count}; тайлов z{ZOOM}: {seen}, изменено {changed}; "
          f"{before / 1e6:.2f} → {after / 1e6:.2f} МБ ({(after - before) / max(before, 1) * 100:+.2f} %)")


if __name__ == "__main__":
    main(sys.argv)
