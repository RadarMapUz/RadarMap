"""Деревья в парках и скверах (30.A): рассадка там, где OSM их не перечислил.

У Яндекса парк — это кроны, а у нас до сих пор только те деревья, которые
кто-то поставил в OSM точкой (natural=tree) или рядом (natural=tree_row): в
Ташкенте это 12 тысяч крон, в основном вдоль улиц, а сквер у Анхора или парк
Бабура под наклоном стоял голым газоном. Здесь кроны досаживаются в
многоугольники зелени — парк и сад, небольшой городской лес, крупный газон —
по решётке с шагом PLANT_STEP и сдвигом от координаты: та же сборка даёт те же
деревья, и соседние тайлы не спорят на стыке.

Чего дерево не делает: не встаёт на дорогу и дорожку (оси из того же
экстракта дорог с шириной по классу), на дом (экстракт домов), на воду,
площадку, парковку, фонтан и мощёную площадь, ближе PLANT_EDGE_METERS к краю
зелени (край парка — обычно тротуар) и ближе PLANT_NEAR_TREE к дереву OSM.
Узкий газон (разделительная, обочина) и большой лес за городом не засаживаются
вовсе: первый — не сквер, второй раздул бы тайлы ради того, что видно только
вблизи. На тайл z15 — не больше PLANT_TILE_MAX крон.

Деревья — декор: видны с TREE_3D_FROM (make_style), на ходу их прячет
MapDetailPolicy, на горячем телефоне — hotHiddenLayers. Выход — [(lon, lat)].
"""
import json
import math
import os

# Шаг решётки по виду зелени, м: парк гуще, роща и газон реже. Подобран по
# весу тайлов вырезки Ташкента (30.A: +≈11 % MVT при ~14 тыс. крон), а не по
# ботанике: настоящая роща гуще, но объём крон виден и при таком шаге.
PARK, WOOD, GRASS = "park", "wood", "grass"
PLANT_STEP = {PARK: 18.0, WOOD: 22.0, GRASS: 34.0}
# Сдвиг кроны от узла решётки — доля шага в каждую сторону: ряды не читаются.
PLANT_JITTER = 0.35
RANK = {PARK: 0, WOOD: 1, GRASS: 2}
PLANT_EDGE_METERS = 3.0
PLANT_NEAR_TREE = 6.0
# Крона от оси дороги: половина ширины проезжей части по классу + запас кроны.
ROAD_HALF_METERS = {"motorway": 12.0, "trunk": 11.0, "primary": 9.0, "secondary": 7.0, "tertiary": 6.0,
                    "motorway_link": 5.0, "trunk_link": 5.0, "primary_link": 5.0, "secondary_link": 4.5,
                    "tertiary_link": 4.5, "residential": 4.0, "unclassified": 4.0, "living_street": 3.5,
                    "service": 3.0, "busway": 4.0, "track": 2.5, "raceway": 5.0}
PATH_HALF_METERS = 1.2
PATH_HIGHWAYS = {"footway", "path", "cycleway", "pedestrian", "steps", "bridleway", "corridor", "platform"}
CROWN_CLEAR_METERS = 2.0
HOUSE_CLEAR_METERS = 1.5
# Площади: роща крупнее — уже лес за городом; газон меньше или уже — не сквер.
PARK_MAX_HECTARES = 200.0
WOOD_MAX_HECTARES = 30.0
GRASS_MIN_SQ_METERS = 3000.0
GRASS_MIN_WIDTH_METERS = 8.0
PLANT_TILE_MAX = 200
TILE_ZOOM = 15
# Глобальная решётка — с одним масштабом долготы на всю страну: узлы не
# зависят от того, какой многоугольник их спросил.
LAT_REF = 41.0
M_LAT = 111_320.0
M_LON = M_LAT * math.cos(math.radians(LAT_REF))

GREEN = {("leisure", "park"): PARK, ("leisure", "garden"): PARK, ("natural", "wood"): WOOD,
         ("landuse", "forest"): WOOD, ("landuse", "grass"): GRASS, ("natural", "grass"): GRASS}
BLOCK = {("natural", "water"), ("landuse", "reservoir"), ("landuse", "basin"), ("waterway", "riverbank"),
         ("leisure", "pitch"), ("leisure", "playground"), ("leisure", "track"), ("leisure", "stadium"),
         ("leisure", "swimming_pool"), ("leisure", "sports_centre"), ("amenity", "parking"),
         ("amenity", "fountain"), ("landuse", "cemetery"), ("place", "square"), ("landuse", "construction")}


def _rings_of(geometry):
    """[[внешнее, дыры…], …] в градусах; линии — нет."""
    kind, coords = geometry.get("type"), geometry.get("coordinates") or []
    polygons = coords if kind == "MultiPolygon" else [coords] if kind == "Polygon" else []
    out = []
    for polygon in polygons:
        rings = [[(float(p[0]), float(p[1])) for p in ring] for ring in polygon if ring and len(ring) >= 4]
        if rings:
            out.append(rings)
    return out


def _local(ring, lat0):
    kx = M_LAT * math.cos(math.radians(lat0))
    return [(p[0] * kx, p[1] * M_LAT) for p in ring]


def ring_area(ring):
    lat0 = ring[0][1]
    pts = _local(ring, lat0)
    return abs(sum(pts[k - 1][0] * pts[k][1] - pts[k][0] * pts[k - 1][1] for k in range(len(pts)))) / 2


def ring_length(ring):
    lat0 = ring[0][1]
    pts = _local(ring, lat0)
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))


def inside(rings, lon, lat):
    """Чёт-нечет по всем кольцам: внешнее минус дыры."""
    hit = False
    for ring in rings:
        j = len(ring) - 1
        for k in range(len(ring)):
            xi, yi = ring[k]
            xj, yj = ring[j]
            if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                hit = not hit
            j = k
    return hit


def _segment_distance(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0.0 if length == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def edge_distance(rings, lon, lat):
    """До ближайшего края (любого кольца), м."""
    kx = M_LAT * math.cos(math.radians(lat))
    best = float("inf")
    for ring in rings:
        for a, b in zip(ring, ring[1:] + ring[:1]):
            best = min(best, _segment_distance(lon * kx, lat * M_LAT, a[0] * kx, a[1] * M_LAT,
                                               b[0] * kx, b[1] * M_LAT))
    return best


def _hash(i, j, salt=0):
    key = (i * 73_856_093) ^ (j * 19_349_663) ^ (salt * 83_492_791)
    key = (key ^ (key >> 13)) * 1_274_126_177
    return (key ^ (key >> 16)) & 0xFFFFFFFF


def lattice(kind, box):
    """Узлы решётки вида kind в рамке (w, s, e, n), со сдвигом: [(lon, lat)]."""
    step = PLANT_STEP[kind]
    dlon, dlat = step / M_LON, step / M_LAT
    out = []
    salt = {PARK: 1, WOOD: 2, GRASS: 3}[kind]
    for i in range(math.floor(box[0] / dlon), math.ceil(box[2] / dlon) + 1):
        for j in range(math.floor(box[1] / dlat), math.ceil(box[3] / dlat) + 1):
            h = _hash(i, j, salt)
            jx = ((h & 0xFFFF) / 0xFFFF * 2 - 1) * PLANT_JITTER
            jy = ((h >> 16) / 0xFFFF * 2 - 1) * PLANT_JITTER
            out.append(((i + 0.5 + jx) * dlon, (j + 0.5 + jy) * dlat))
    return out


class Grid:
    """Сетка в метрах: что лежит рядом с точкой."""

    def __init__(self, cell):
        self.cell = cell
        self.items = {}

    def key(self, lon, lat):
        return int(math.floor(lon * M_LON / self.cell)), int(math.floor(lat * M_LAT / self.cell))

    def add_box(self, box, item):
        x0, y0 = self.key(box[0], box[1])
        x1, y1 = self.key(box[2], box[3])
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 40_000:
            return
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                self.items.setdefault((x, y), []).append(item)

    def near(self, lon, lat):
        x, y = self.key(lon, lat)
        seen = []
        for gx in (x - 1, x, x + 1):
            for gy in (y - 1, y, y + 1):
                seen.extend(self.items.get((gx, gy), ()))
        return seen

    def has(self, lon, lat):
        return self.key(lon, lat) in self.items


def _box(rings):
    xs = [p[0] for r in rings for p in r]
    ys = [p[1] for r in rings for p in r]
    return min(xs), min(ys), max(xs), max(ys)


def _features(path):
    if not path or not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue


def green_kind(props):
    for key, value in props.items():
        kind = GREEN.get((key, value))
        if kind:
            return kind
    return None


def is_blocker(props):
    return any((k, v) in BLOCK for k, v in props.items()) or (
        props.get("highway") in ("pedestrian", "footway", "service", "platform") or props.get("area:highway"))


def collect(areas_path):
    """Зелень под рассадку [(вид, кольца, рамка)] и помехи [(кольца, рамка)]."""
    green, blockers = [], []
    for feature in _features(areas_path):
        props = feature.get("properties") or {}
        kind = green_kind(props)
        blocked = is_blocker(props)
        if not kind and not blocked:
            continue
        for rings in _rings_of(feature.get("geometry") or {}):
            box = _box(rings)
            if blocked:
                blockers.append((rings, box))
                continue
            outer = rings[0]
            area = ring_area(outer) - sum(ring_area(r) for r in rings[1:])
            if kind == PARK and area > PARK_MAX_HECTARES * 1e4:
                continue
            if kind == WOOD and area > WOOD_MAX_HECTARES * 1e4:
                continue
            if kind == GRASS and (area < GRASS_MIN_SQ_METERS
                                  or 2 * area / max(ring_length(outer), 1) < GRASS_MIN_WIDTH_METERS):
                continue
            green.append((kind, rings, box))
    green.sort(key=lambda g: (RANK[g[0]], g[2]))
    return green, blockers


def _cover(green, cell):
    """Клетки сетки, задетые зеленью (с запасом в клетку), — фильтр для помех."""
    grid = Grid(cell)
    for _kind, _rings, box in green:
        grid.add_box((box[0] - cell / M_LON, box[1] - cell / M_LAT,
                      box[2] + cell / M_LON, box[3] + cell / M_LAT), True)
    return grid


def road_segments(roads_path, cover):
    """Отрезки осей дорог и дорожек у зелени: Grid → [(a, b, полуширина+запас)]."""
    grid = Grid(25.0)
    for feature in _features(roads_path):
        props = feature.get("properties") or {}
        highway = props.get("highway")
        if highway in PATH_HIGHWAYS:
            half = PATH_HALF_METERS
        elif highway in ROAD_HALF_METERS:
            half = ROAD_HALF_METERS[highway]
        else:
            continue
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "LineString":
            continue
        pts = [(float(p[0]), float(p[1])) for p in geometry.get("coordinates") or []]
        for a, b in zip(pts, pts[1:]):
            if not (cover.has(*a) or cover.has(*b)):
                continue
            box = (min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
            grid.add_box(box, (a, b, half + CROWN_CLEAR_METERS))
    return grid


def house_shapes(houses_path, cover):
    grid = Grid(25.0)
    for feature in _features(houses_path):
        for rings in _rings_of(feature.get("geometry") or {}):
            box = _box(rings)
            if cover.has(box[0], box[1]) or cover.has(box[2], box[3]):
                grid.add_box(box, (rings[:1], box))
    return grid


def _blocked_by_shapes(grid, lon, lat, clear):
    for rings, box in grid.near(lon, lat):
        if box[0] - 1e-4 <= lon <= box[2] + 1e-4 and box[1] - 1e-4 <= lat <= box[3] + 1e-4:
            if inside(rings, lon, lat) or (clear and edge_distance(rings, lon, lat) < clear):
                return True
    return False


def _near_road(grid, lon, lat):
    kx = M_LAT * math.cos(math.radians(lat))
    for a, b, clear in grid.near(lon, lat):
        if _segment_distance(lon * kx, lat * M_LAT, a[0] * kx, a[1] * M_LAT, b[0] * kx, b[1] * M_LAT) < clear:
            return True
    return False


def tile_of(lon, lat, zoom=TILE_ZOOM):
    n = 1 << zoom
    s = math.sin(math.radians(lat))
    return int((lon + 180) / 360 * n), int((0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n)


def plant(green, blockers=(), roads=None, houses=None, existing=(), tile_max=PLANT_TILE_MAX):
    """Досаженные кроны [(lon, lat)] — отсортированы, детерминированы.

    green — [(вид, кольца, рамка)], blockers — [(кольца, рамка)], roads и
    houses — Grid из road_segments / house_shapes (или None), existing —
    деревья OSM [(lon, lat)].
    """
    block_grid = Grid(50.0)
    for rings, box in blockers:
        block_grid.add_box(box, (rings, box))
    taken = Grid(PLANT_NEAR_TREE)
    for lon, lat in existing:
        taken.add_box((lon, lat, lon, lat), (lon, lat, PLANT_NEAR_TREE))
    out = []
    for kind, rings, box in green:
        spacing = PLANT_STEP[kind] * 0.6
        for lon, lat in lattice(kind, box):
            if not (box[0] <= lon <= box[2] and box[1] <= lat <= box[3]) or not inside(rings, lon, lat):
                continue
            if edge_distance(rings, lon, lat) < PLANT_EDGE_METERS:
                continue
            kx = M_LAT * math.cos(math.radians(lat))
            if any(math.hypot((lon - x) * kx, (lat - y) * M_LAT) < min(spacing, near)
                   for x, y, near in _within(taken, lon, lat, spacing)):
                continue
            if _blocked_by_shapes(block_grid, lon, lat, 0.0):
                continue
            if roads is not None and _near_road(roads, lon, lat):
                continue
            if houses is not None and _blocked_by_shapes(houses, lon, lat, HOUSE_CLEAR_METERS):
                continue
            taken.add_box((lon, lat, lon, lat), (lon, lat, spacing))
            out.append((RANK[kind], round(lon, 6), round(lat, 6)))
    # Не больше tile_max на тайл: сначала парк, потом роща, потом газон, а
    # внутри вида лишние снимаются равномерно — по хэшу, а не краем тайла.
    by_tile = {}
    for rank, lon, lat in out:
        by_tile.setdefault(tile_of(lon, lat), []).append((rank, _hash(int(lon * 1e6), int(lat * 1e6), 7), lon, lat))
    kept = []
    for trees in by_tile.values():
        kept.extend((lon, lat) for _r, _h, lon, lat in sorted(trees)[:tile_max])
    return sorted(kept)


def _within(grid, lon, lat, radius):
    """Соседи из сетки taken (клетка PLANT_NEAR_TREE): радиус до двух клеток."""
    x, y = grid.key(lon, lat)
    reach = max(1, math.ceil(radius / grid.cell))
    for gx in range(x - reach, x + reach + 1):
        for gy in range(y - reach, y + reach + 1):
            yield from grid.items.get((gx, gy), ())


def plant_from_files(areas_path, roads_path=None, houses_path=None, existing=()):
    """Полный проход по экстрактам сборки. Пустой список, если зелени нет."""
    green, blockers = collect(areas_path)
    if not green:
        return []
    cover = _cover(green, 25.0)
    roads = road_segments(roads_path, cover) if roads_path else None
    houses = house_shapes(houses_path, cover) if houses_path else None
    return plant(green, blockers, roads, houses, existing)
