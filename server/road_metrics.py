#!/usr/bin/env python3
"""Метрики качества дороги по всей сборке — число, а не впечатление.

    python3 server/road_metrics.py ТАЙЛЫ [--islands area_highway.geojsonl] [--json out.json]

Читает готовую сборку (JSON-поверхность и MVT) и считает классы дефектов,
которые владелец находил на снимках по одному (docs/plan_ml_roads.md §1):

  houses_under_asphalt   доля площади домов под асфальтом — полотно шире жизни
  islands_under_asphalt  доля площади островков (area:highway=traffic_island)
                         под асфальтом — островок залит
  arrows_after_stop      рядов стрелок ПОСЛЕ стоп-линии на 1000 рядов
  dashes_in_junction     метров пунктира в площади узла, на 1 км пунктира
  dashes_on_zebra        метров пунктира ближе 2 м к зебре, на 1 км пунктира
  medians_on_asphalt     разделительных, лежащих на полотне, на 100 полос

Меньше — лучше по всем. Выборка детерминирована (сетка, не случай), чтобы
две сборки сравнивались честно.

Только stdlib, как весь server/.
"""
import argparse
import gzip
import json
import math
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

LAT_M = 111_320.0
SAMPLE_STEP_METERS = 2.0
ZEBRA_NEAR_METERS = 2.0
ARROW_STOP_REACH_METERS = 30.0
ARROW_STOP_LATERAL_METERS = 8.0
MEDIAN_ON_ASPHALT_SHARE = 0.4
JUNCTION_MIN_AREA_M2 = 300.0


# --- геометрия ---------------------------------------------------------------

def inside(point, ring):
    x, y = point
    hit = False
    for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


def bbox(ring):
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    return min(xs), min(ys), max(xs), max(ys)


def polygon_area_m2(ring):
    kx = LAT_M * math.cos(math.radians(ring[0][1]))
    xy = [(x * kx, y * LAT_M) for x, y in ring]
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))) / 2


def grid_points(ring, step=SAMPLE_STEP_METERS):
    """Точки внутри многоугольника по сетке (детерминированно)."""
    x0, y0, x1, y1 = bbox(ring)
    kx = LAT_M * math.cos(math.radians((y0 + y1) / 2))
    dx, dy = step / kx, step / LAT_M
    out = []
    y = y0 + dy / 2
    while y < y1:
        x = x0 + dx / 2
        while x < x1:
            if inside((x, y), ring):
                out.append((x, y))
            x += dx
        y += dy
    return out


def seg_distance_m(p, a, b):
    kx = LAT_M * math.cos(math.radians(p[1]))
    ax, ay = (a[0] - p[0]) * kx, (a[1] - p[1]) * LAT_M
    bx, by = (b[0] - p[0]) * kx, (b[1] - p[1]) * LAT_M
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
    return math.hypot(ax + t * dx, ay + t * dy)


def densify(line, step=SAMPLE_STEP_METERS):
    out = []
    for a, b in zip(line, line[1:]):
        kx = LAT_M * math.cos(math.radians(a[1]))
        length = math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M)
        parts = max(1, int(length / step))
        for i in range(parts):
            out.append((a[0] + (b[0] - a[0]) * i / parts, a[1] + (b[1] - a[1]) * i / parts))
    if line:
        out.append(line[-1])
    return out


class PolygonIndex:
    CELL = 0.001

    def __init__(self, rings):
        self._grid = defaultdict(list)
        for ring in rings:
            if len(ring) < 3:
                continue
            box = bbox(ring)
            for gx in range(int(box[0] / self.CELL), int(box[2] / self.CELL) + 1):
                for gy in range(int(box[1] / self.CELL), int(box[3] / self.CELL) + 1):
                    self._grid[(gx, gy)].append((box, ring))

    def covers(self, p):
        for box, ring in self._grid.get((int(p[0] / self.CELL), int(p[1] / self.CELL)), ()):
            if box[0] <= p[0] <= box[2] and box[1] <= p[1] <= box[3] and inside(p, ring):
                return True
        return False


class SegmentIndex:
    CELL = 0.0005

    def count_near(self, p, meters):
        """Сколько отрезков ближе meters к точке."""
        kx = LAT_M * math.cos(math.radians(p[1]))
        cell = (int(p[0] / self.CELL), int(p[1] / self.CELL))
        seen = 0
        for a, b in self._grid.get(cell, ()):
            ax, ay = (a[0] - p[0]) * kx, (a[1] - p[1]) * LAT_M
            bx, by = (b[0] - p[0]) * kx, (b[1] - p[1]) * LAT_M
            dx, dy = bx - ax, by - ay
            length = dx * dx + dy * dy
            t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
            if math.hypot(ax + t * dx, ay + t * dy) <= meters:
                seen += 1
        return seen

    def __init__(self, lines):
        self._grid = defaultdict(list)
        for line in lines:
            for a, b in zip(line, line[1:]):
                for gx in range(int(min(a[0], b[0]) / self.CELL) - 1, int(max(a[0], b[0]) / self.CELL) + 2):
                    for gy in range(int(min(a[1], b[1]) / self.CELL) - 1, int(max(a[1], b[1]) / self.CELL) + 2):
                        self._grid[(gx, gy)].append((a, b))

    def near(self, p, metres):
        return any(seg_distance_m(p, a, b) <= metres
                   for a, b in self._grid.get((int(p[0] / self.CELL), int(p[1] / self.CELL)), ()))


# --- метрики (чистые) --------------------------------------------------------

def share_under(rings, cover):
    """Доля площади многоугольников, накрытая `cover` (PolygonIndex)."""
    total = hit = 0
    for ring in rings:
        for p in grid_points(ring):
            total += 1
            hit += cover.covers(p)
    return (hit / total) if total else 0.0


class Uncovered:
    """Видимый асфальт: под `cover`, но не под тем, что рисуется сверху."""

    def __init__(self, cover, above):
        self.cover, self.above = cover, above

    def covers(self, p):
        return self.cover.covers(p) and not self.above.covers(p)


def arrows_after_stop(arrows, stop_lines):
    """Доля рядов стрелок, за которыми (против хода) в 30 м стоит стоп-линия.

    arrows — [(lon, lat, bearing)]; stop_lines — [[(lon, lat), (lon, lat)]].
    Ряд стрелок «после стоп-линии», если стоп-линия лежит позади него по ходу.
    """
    if not arrows:
        return 0.0
    index = SegmentIndex(stop_lines)
    bad = 0
    for lon, lat, bearing in arrows:
        kx = LAT_M * math.cos(math.radians(lat))
        fx, fy = math.sin(math.radians(bearing)), math.cos(math.radians(bearing))
        found = False
        for along in range(2, int(ARROW_STOP_REACH_METERS) + 1, 2):
            p = (lon - fx * along / kx, lat - fy * along / LAT_M)
            if index.near(p, 1.5):
                found = True
                break
        bad += found
    return bad / len(arrows)


def zebra_defects(zebras, asphalt):
    """(доля зебр с концом за кромкой, доля зебр-дублей) — на 1 зебру.

    Конец «за кромкой» — точка в 0,5 м от конца внутрь не на асфальте.
    Дубль — центр ближе ZEBRA_DUPLICATE_METERS к центру другой зебры.
    """
    if not zebras:
        return 0.0, 0.0
    overhang = 0
    centres = []
    for line in zebras:
        a, b = line[0], line[-1]
        kx = LAT_M * math.cos(math.radians(a[1]))
        length = math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M)
        if length < 1.0:
            continue
        t = 0.5 / length
        inner = [(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t),
                 (b[0] + (a[0] - b[0]) * t, b[1] + (a[1] - b[1]) * t)]
        if not all(asphalt.covers(p) for p in inner):
            overhang += 1
        centres.append(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2))
    index = SegmentIndex([[c, c] for c in centres])
    duplicates = sum(1 for c in centres if index.count_near(c, ZEBRA_DUPLICATE_METERS) > 1)
    return overhang / len(zebras), duplicates / len(zebras)


def spiky(ring, degrees=None, min_edge=1.0):
    """Есть ли у контура острый угол (игла) между рёбрами длиннее min_edge."""
    degrees = SPIKE_DEGREES if degrees is None else degrees
    lat0 = ring[0][1]
    kx = LAT_M * math.cos(math.radians(lat0))
    pts = [((p[0] - ring[0][0]) * kx, (p[1] - lat0) * LAT_M) for p in ring]
    if pts[0] == pts[-1]:
        pts = pts[:-1]
    n = len(pts)
    if n < 3:
        return False
    for i in range(n):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
        u = (a[0] - b[0], a[1] - b[1])
        v = (c[0] - b[0], c[1] - b[1])
        lu, lv = math.hypot(*u), math.hypot(*v)
        if lu < min_edge or lv < min_edge:
            continue
        cos = (u[0] * v[0] + u[1] * v[1]) / (lu * lv)
        if math.degrees(math.acos(max(-1.0, min(1.0, cos)))) < degrees:
            return True
    return False


def thin(ring, meters=None):
    """Средняя ширина контура (2·площадь/периметр) меньше meters — клин-игла."""
    meters = SLIVER_METERS if meters is None else meters
    lat0 = ring[0][1]
    kx = LAT_M * math.cos(math.radians(lat0))
    perimeter = sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M)
                    for a, b in zip(ring, ring[1:] + ring[:1]))
    return perimeter > 0 and 2 * polygon_area_m2(ring) / perimeter < meters


def dashes_inside(markings, covered):
    """(метров пунктира, где covered(p) истинно, на 1 км, всего метров)."""
    total = hit = 0.0
    for line in markings:
        points = densify(line)
        for p in points:
            total += SAMPLE_STEP_METERS
            if covered(p):
                hit += SAMPLE_STEP_METERS
    return (1000.0 * hit / total) if total else 0.0, total


def medians_on_asphalt(medians, asphalt, examples=None):
    """Доля разделительных, у которых больше MEDIAN_ON_ASPHALT_SHARE площади на полотне."""
    if not medians:
        return 0.0
    bad = 0
    for ring in medians:
        points = grid_points(ring, 1.0)
        if points and sum(asphalt.covers(p) for p in points) / len(points) > MEDIAN_ON_ASPHALT_SHARE:
            bad += 1
            if examples is not None and len(examples) < 10:
                cx = sum(p[0] for p in ring) / len(ring)
                cy = sum(p[1] for p in ring) / len(ring)
                examples.append((round(cy, 5), round(cx, 5)))
    return bad / len(medians)


# --- чтение сборки -----------------------------------------------------------

def _varint(data, at):
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, at
        shift += 7


def _fields(data):
    at = 0
    while at < len(data):
        key, at = _varint(data, at)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, at = _varint(data, at)
        elif wire == 2:
            size, at = _varint(data, at)
            value, at = data[at:at + size], at + size
        elif wire == 5:
            value, at = data[at:at + 4], at + 4
        elif wire == 1:
            value, at = data[at:at + 8], at + 8
        else:
            raise ValueError(f"тип поля {wire}")
        yield field, wire, value


def _packed(data):
    out, at = [], 0
    while at < len(data):
        value, at = _varint(data, at)
        out.append(value)
    return out


def _value(data):
    for field, _wire, value in _fields(data):
        if field == 1:
            return value.decode()
        if field in (4, 5):
            return value
        if field == 6:
            return (value >> 1) ^ -(value & 1)
        if field == 7:
            return bool(value)
        if field in (2, 3):
            import struct
            return struct.unpack("<f" if field == 2 else "<d", value)[0]
    return None


def read_mvt(path, x, y, z):
    """{слой: [(тип, [[(lon, lat)]], свойства)]} одного тайла."""
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    n = 2 ** z
    out = {}
    for field, _w, layer in _fields(raw):
        if field != 3:
            continue
        name, keys, values, features, extent = None, [], [], [], 4096
        for f, _w2, v in _fields(layer):
            if f == 1:
                name = v.decode()
            elif f == 2:
                features.append(v)
            elif f == 3:
                keys.append(v.decode())
            elif f == 4:
                values.append(_value(v))
            elif f == 5:
                extent = v
        parsed = []
        for feature in features:
            tags, gtype, geom = [], 0, []
            for f, _w3, v in _fields(feature):
                if f == 2:
                    tags = _packed(v)
                elif f == 3:
                    gtype = v
                elif f == 4:
                    geom = _packed(v)
            props = {keys[tags[i]]: values[tags[i + 1]] for i in range(0, len(tags) - 1, 2)}
            parts, cur, cx, cy, i = [], [], 0, 0, 0
            while i < len(geom):
                cmd, count = geom[i] & 7, geom[i] >> 3
                i += 1
                if cmd == 7:
                    if cur:
                        parts.append(cur)
                        cur = []
                    continue
                for _ in range(count):
                    dx = (geom[i] >> 1) ^ -(geom[i] & 1)
                    dy = (geom[i + 1] >> 1) ^ -(geom[i + 1] & 1)
                    i += 2
                    cx += dx
                    cy += dy
                    if cmd == 1 and cur:
                        parts.append(cur)
                        cur = []
                    fx, fy = x + cx / extent, y + cy / extent
                    lon = fx / n * 360 - 180
                    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * fy / n))))
                    cur.append((lon, lat))
            if cur:
                parts.append(cur)
            parsed.append((gtype, parts, props))
        out[name] = parsed
    return out


def tile_range(bbox, zoom):
    """(x0, x1, y0, y1) тайлов зума, накрывающих рамку (юг, запад, север, восток)."""
    south, west, north, east = bbox
    n = 2 ** zoom

    def tx(lon):
        return int((lon + 180) / 360 * n)

    def ty(lat):
        return int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n)
    return tx(west), tx(east), ty(north), ty(south)


def load_build(tiles_dir, zoom=15, bbox=None):
    """Слои MVT зума `zoom` сборки (или её рамки), склеенные (дубли по тайлам — по ключу)."""
    layers = defaultdict(list)
    seen = set()
    root = os.path.join(tiles_dir, "mvt", str(zoom))
    limits = tile_range(bbox, zoom) if bbox else None
    for x_name in sorted(os.listdir(root)):
        if limits and not limits[0] <= int(x_name) <= limits[1]:
            continue
        for file_name in sorted(os.listdir(os.path.join(root, x_name))):
            x, y = int(x_name), int(file_name.split(".")[0])
            if limits and not limits[2] <= y <= limits[3]:
                continue
            for layer, features in read_mvt(os.path.join(root, x_name, file_name), x, y, zoom).items():
                for gtype, parts, props in features:
                    key = (layer, gtype, tuple(sorted(props.items())),
                           tuple((round(p[0], 5), round(p[1], 5)) for p in parts[0][:3]) if parts else ())
                    if key in seen:
                        continue
                    seen.add(key)
                    layers[layer].append((gtype, parts, props))
    return layers


def measure(tiles_dir, islands_path=None, bbox=None):
    import build_mvt
    layers = load_build(tiles_dir, bbox=bbox)
    surface = layers.get("surface", [])
    asphalt_rings = [parts[0] for g, parts, props in surface
                     if g == 3 and props.get("kind") in (7, 8, 10, 13) and parts]
    # Настоящие узлы — по площади: заплатки на стыках лент одной улицы (тоже
    # вид 8) пунктир проходит законно.
    junction_rings = [parts[0] for g, parts, props in surface
                      if g == 3 and props.get("kind") in (8, 10) and parts and not props.get("fill")
                      and polygon_area_m2(parts[0]) >= JUNCTION_MIN_AREA_M2]
    # Площадь вдоль одной улицы (разворот, слияние) — не перекрёсток для
    # пунктира: полосы проспекта идут через неё насквозь (как в build_mvt).
    names = build_mvt.StreetNames([(props.get("cls", 9), 0, part, props.get("name", ""))
                                   for g, parts, props in layers.get("roads", []) if g == 2
                                   for part in parts])
    junction_rings = [ring for ring in junction_rings
                      if polygon_area_m2(ring) < build_mvt.BIG_JUNCTION_M2 or len(names.inside(ring)) >= 2]
    medians = [parts[0] for g, parts, props in surface
               if g == 3 and props.get("kind") == 9 and props.get("strip") and parts]
    road_lines = [(parts, props) for g, parts, props in layers.get("roads", []) if g == 2]
    asphalt = PolygonIndex(asphalt_rings)
    junctions = PolygonIndex(junction_rings)
    # Ленты (вид 7) по краям разделительной законно уходят под неё — она
    # рисуется сверху, и это не видно. Видно другое: разделительная на площади
    # узла и разметка, проходящая сквозь неё.
    # Перемычка между направлениями (вид 8, свойство fill) — не узел.
    open_areas = PolygonIndex([parts[0] for g, parts, props in surface
                               if g == 3 and props.get("kind") in (8, 10, 13) and parts
                               and not props.get("fill")])
    median_index = PolygonIndex(medians)
    # Островок, нарисованный поверх асфальта (свойство island), асфальтом не съеден.
    drawn_islands = PolygonIndex([parts[0] for g, parts, props in surface
                                  if g == 3 and props.get("kind") == 9 and props.get("island") and parts])

    paint = layers.get("paint", [])
    zebras = SegmentIndex([part for g, parts, props in paint if props.get("kind") == 12 for part in parts])
    stops = [part for g, parts, props in paint if props.get("kind") in (1, 3) for part in parts]
    arrows = [(parts[0][0][0], parts[0][0][1], props.get("bearing", 0))
              for g, parts, props in layers.get("arrows", []) if parts]
    markings = [part for g, parts, props in layers.get("markings", []) for part in parts]

    houses = []
    for set_name in ("h",):
        for kind, flags, ring in build_mvt.written_areas(tiles_dir, set_name):
            if kind == build_mvt.AREA_HOUSE and flags & 1 and len(ring) > 3:
                if bbox and not (bbox[0] <= ring[0][1] <= bbox[2] and bbox[1] <= ring[0][0] <= bbox[3]):
                    continue
                houses.append(ring)

    islands = []
    if islands_path and os.path.exists(islands_path):
        for line in open(islands_path, encoding="utf-8"):
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            feature = json.loads(line)
            if feature["properties"].get("area:highway") != "traffic_island":
                continue
            geometry = feature["geometry"]
            polygons = ([geometry["coordinates"]] if geometry["type"] == "Polygon"
                        else geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [])
            for polygon in polygons:
                islands.append([tuple(p[:2]) for p in polygon[0]])

    median_examples = []
    # Пунктир эстакады над перекрёстком законен: он на другом уровне.
    bridges = SegmentIndex([part for g, parts, props in layers.get("roads", [])
                            if g == 2 and props.get("bridge") for part in parts])
    in_junction, total = dashes_inside(
        markings, lambda p: junctions.covers(p) and not bridges.near(p, BRIDGE_DECK_METERS))
    on_zebra, _ = dashes_inside(markings, lambda p: zebras.near(p, ZEBRA_NEAR_METERS))
    through_medians, _ = dashes_inside(markings, median_index.covers)
    shapes = [(props.get("kind"), parts[0]) for g, parts, props in surface
              if g == 3 and parts and props.get("kind") in (8, 9, 10, 13) and len(parts[0]) > 3]
    spikes = sum(1 for _kind, ring in shapes if spiky(ring))
    island_rings = [ring for kind, ring in shapes if kind == 9]
    slivers = sum(1 for ring in island_rings if thin(ring))
    zebra_lines = [part for g, parts, props in paint if props.get("kind") == 12 for part in parts]
    zebra_overhang, zebra_duplicates = zebra_defects(zebra_lines, asphalt)
    return {
        "houses_under_asphalt": round(100 * share_under(houses, asphalt), 2),
        "islands_under_asphalt": round(100 * share_under(islands, Uncovered(asphalt, drawn_islands)), 2) if islands else None,
        "arrows_after_stop": round(1000 * arrows_after_stop(arrows, stops), 1),
        "dashes_in_junction": round(in_junction, 1),
        "dashes_on_zebra": round(on_zebra, 1),
        "medians_on_asphalt": round(100 * medians_on_asphalt(medians, open_areas, median_examples), 2),
        "dashes_through_medians": round(through_medians, 1),
        "zebra_overhang": round(100 * zebra_overhang, 2),
        "junction_spikes": round(100 * spikes / len(shapes), 2) if shapes else 0.0,
        "island_slivers": round(100 * slivers / len(island_rings), 2) if island_rings else 0.0,
        "zebra_duplicates": round(100 * zebra_duplicates, 2),
        "_median_examples": median_examples,
        "_counts": {"houses": len(houses), "islands": len(islands), "arrows": len(arrows),
                    "markings_km": round(total / 1000, 1), "zebras": len(zebra_lines), "medians": len(medians),
                    "junctions": len(junction_rings), "road_lines": len(road_lines)},
    }


UNITS = {
    "houses_under_asphalt": "% площади домов",
    "islands_under_asphalt": "% площади островков",
    "arrows_after_stop": "на 1000 рядов",
    "dashes_in_junction": "м на 1 км пунктира",
    "dashes_on_zebra": "м на 1 км пунктира",
    "medians_on_asphalt": "% разделительных",
    "dashes_through_medians": "м на 1 км пунктира",
    "zebra_overhang": "% зебр с концом за кромкой",
    "junction_spikes": "% фигур узла с иглой",
    "island_slivers": "% островков-клиньев",
    "zebra_duplicates": "% зебр-дублей",
}


# Игла: угол контура острее этого. Клин: средняя ширина меньше этого.
SPIKE_DEGREES = 15.0
SLIVER_METERS = 1.5
# Центры зебр ближе этого — одна и та же зебра, нарисованная дважды.
ZEBRA_DUPLICATE_METERS = 5.0
# Полуширина пролёта эстакады: пунктир ближе к её оси — на мосту, не в узле.
BRIDGE_DECK_METERS = 9.0


# Рамка по умолчанию для ворот — Ташкент: по стране метрики считались бы час.
TASHKENT = (41.20, 69.10, 41.40, 69.40)
# Ухудшение больше этого (в разах к опубликованному) останавливает публикацию.
WORSE_FACTOR = 1.2
# Ниже этого значения метрика — шум, её колебание ворот не трогает.
NOISE_FLOOR = {"houses_under_asphalt": 0.2, "islands_under_asphalt": 5.0, "arrows_after_stop": 5.0,
               "dashes_in_junction": 10.0, "dashes_on_zebra": 2.0, "medians_on_asphalt": 2.0,
               "dashes_through_medians": 2.0, "zebra_overhang": 3.0, "zebra_duplicates": 2.0,
               "junction_spikes": 2.0, "island_slivers": 2.0}


def compare(previous, current):
    """Причины остановить публикацию: метрики, ухудшившиеся заметно."""
    reasons = []
    for key in UNITS:
        before, after = previous.get(key), current.get(key)
        if before is None or after is None:
            continue
        if after <= NOISE_FLOOR.get(key, 0.0):
            continue
        if after > max(before, NOISE_FLOOR.get(key, 0.0)) * WORSE_FACTOR:
            reasons.append(f"{key}: {before} → {after} ({UNITS[key]})")
    return reasons


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tiles")
    parser.add_argument("--islands")
    parser.add_argument("--json")
    parser.add_argument("--bbox", help="юг,запад,север,восток; 'tashkent' — рамка ворот")
    parser.add_argument("--compare", help="metrics.json опубликованной сборки: ухудшение — код 1")
    args = parser.parse_args()
    bbox = None
    if args.bbox:
        bbox = TASHKENT if args.bbox == "tashkent" else tuple(float(v) for v in args.bbox.split(","))
    result = measure(args.tiles, args.islands, bbox)
    for key, unit in UNITS.items():
        print(f"  {key:24} {result[key]!s:>8}  {unit}")
    print("  объём:", result["_counts"])
    print("  примеры разделительных на асфальте:", result["_median_examples"][:6])
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=1)
    if args.compare and os.path.exists(args.compare):
        with open(args.compare, encoding="utf-8") as handle:
            reasons = compare(json.load(handle), result)
        for reason in reasons:
            print("  ХУЖЕ:", reason)
        if reasons:
            sys.exit(1)


if __name__ == "__main__":
    main()
