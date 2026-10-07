"""Парковки: площадка асфальта и разметка мест, как у Яндекса.

В OSM парковка — контур amenity=parking, мест в нём обычно нет. Разметку
строим сами: площадка поворачивается по своей длинной стороне, поперёк неё
идут ряды — места вдоль кромки, проезд, двойной ряд, проезд… Место — черта
длиной STALL_DEPTH через STALL_WIDTH. Черта рисуется, только если целиком
внутри контура и не на проезде (оси дорог из сети). Подземные и многоэтажные
не размечаем — сверху их мест не видно. Чистый stdlib.
"""
import json
import math
import os

STALL_WIDTH = 2.6
STALL_DEPTH = 5.0
AISLE_WIDTH = 6.5
MIN_AREA_M2 = 350.0
MIN_SIDE_M = 11.0
ROAD_CLEAR_M = 4.0
SKIP_KINDS = {"underground", "multi-storey", "rooftop"}
LAT_M = 111_320.0


def collect_parking(source_path):
    """[(кольцо lon/lat, тип)] из экстракта местности (amenity=parking)."""
    out = []
    if not source_path or not os.path.exists(source_path):
        return out
    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            if "parking" not in line:
                continue
            line = line.lstrip("\x1e").strip()
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            props = feature.get("properties") or {}
            if props.get("amenity") != "parking":
                continue
            geometry = feature.get("geometry") or {}
            polygons = ([geometry.get("coordinates")] if geometry.get("type") == "Polygon"
                        else geometry.get("coordinates") or [] if geometry.get("type") == "MultiPolygon" else [])
            for polygon in polygons:
                if polygon and len(polygon[0]) >= 4:
                    ring = [tuple(p[:2]) for p in polygon[0]]
                    if ring[0] == ring[-1]:
                        ring = ring[:-1]
                    out.append((ring, props.get("parking", "")))
    return out


def _inside(p, ring):
    x, y = p
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def _area(xy):
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))) / 2


def _hull(points):
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def _orientation(xy):
    """Угол длинной стороны прямоугольника наименьшей площади вокруг контура."""
    hull = _hull(xy)
    best = None
    for a, b in zip(hull, hull[1:] + hull[:1]):
        angle = math.atan2(b[1] - a[1], b[0] - a[0])
        c, s = math.cos(angle), math.sin(angle)
        us = [p[0] * c + p[1] * s for p in hull]
        vs = [-p[0] * s + p[1] * c for p in hull]
        w, h = max(us) - min(us), max(vs) - min(vs)
        if best is None or w * h < best[0]:
            best = (w * h, angle if w >= h else angle + math.pi / 2)
    return best[1] if best else 0.0


AISLE_STALL_FROM = 3.3      # м от оси проезда до начала места
AISLE_CLEAR_M = 3.0


def aisle_stalls(ring, aisles, near_road=None):
    """Места по обе стороны проездов площадки (service внутри контура) — так
    размечены настоящие парковки: проезд, по бокам ряды мест поперёк него."""
    lat0 = sum(p[1] for p in ring) / len(ring)
    lon0 = sum(p[0] for p in ring) / len(ring)
    kx = LAT_M * math.cos(math.radians(lat0))

    def xy(p):
        return ((p[0] - lon0) * kx, (p[1] - lat0) * LAT_M)

    def back(x, y):
        return (lon0 + x / kx, lat0 + y / LAT_M)
    poly = [xy(p) for p in ring]
    out = []
    placed = {}                       # клетка 2 м → середины уже поставленных мест

    def crowded(q):
        cx, cy = int(q[0] // 2), int(q[1] // 2)
        return any(math.hypot(q[0] - m[0], q[1] - m[1]) < STALL_WIDTH * 0.8
                   for gx in (cx - 1, cx, cx + 1) for gy in (cy - 1, cy, cy + 1)
                   for m in placed.get((gx, gy), ()))
    # Длинные проезды — первыми: ряды встают вдоль главных, а короткая
    # поперечная перемычка не перечёркивает их своими местами.
    aisles = sorted(aisles, key=lambda ab: -math.hypot((ab[1][0] - ab[0][0]) * kx,
                                                        (ab[1][1] - ab[0][1]) * LAT_M))
    for a, b in aisles:
        ax, ay = xy(a)
        bx, by = xy(b)
        length = math.hypot(bx - ax, by - ay)
        if length < STALL_WIDTH * 2:
            continue
        fx, fy = (bx - ax) / length, (by - ay) / length
        nx, ny = -fy, fx
        t = STALL_WIDTH
        while t <= length - STALL_WIDTH:
            px, py = ax + fx * t, ay + fy * t
            for side in (1, -1):
                near = (px + nx * side * AISLE_STALL_FROM, py + ny * side * AISLE_STALL_FROM)
                far = (px + nx * side * (AISLE_STALL_FROM + STALL_DEPTH),
                       py + ny * side * (AISLE_STALL_FROM + STALL_DEPTH))
                mid = ((near[0] + far[0]) / 2, (near[1] + far[1]) / 2)
                if not all(_inside(q, poly) for q in (near, mid, far)):
                    continue
                if near_road is not None and any(near_road(back(*q), AISLE_CLEAR_M) for q in (mid, far)):
                    continue
                if crowded(mid) or crowded(near) or crowded(far):
                    continue
                for q in (near, mid, far):
                    placed.setdefault((int(q[0] // 2), int(q[1] // 2)), []).append(q)
                out.append([back(*near), back(*far)])
            t += STALL_WIDTH
    return out


def stall_lines(ring, near_road=None, aisles=()):
    """Черты мест парковки (lon/lat-отрезки): по проездам, если они есть,
    иначе рядами по длинной стороне площадки."""
    if aisles:
        found = aisle_stalls(ring, aisles, near_road)
        if found:
            return found
    lat0 = sum(p[1] for p in ring) / len(ring)
    lon0 = sum(p[0] for p in ring) / len(ring)
    kx = LAT_M * math.cos(math.radians(lat0))
    xy = [((p[0] - lon0) * kx, (p[1] - lat0) * LAT_M) for p in ring]
    if _area(xy) < MIN_AREA_M2:
        return []
    angle = _orientation(xy)
    c, s = math.cos(angle), math.sin(angle)
    uv = [(p[0] * c + p[1] * s, -p[0] * s + p[1] * c) for p in xy]
    u0, u1 = min(p[0] for p in uv), max(p[0] for p in uv)
    v0, v1 = min(p[1] for p in uv), max(p[1] for p in uv)
    if v1 - v0 < MIN_SIDE_M or u1 - u0 < MIN_SIDE_M:
        return []

    def back(u, v):
        x, y = u * c - v * s, u * s + v * c
        return (lon0 + x / kx, lat0 + y / LAT_M)

    def ok(u, v):
        return _inside((u, v), uv) and (near_road is None or not near_road(back(u, v), ROAD_CLEAR_M))

    # Ряды поперёк короткой стороны: место у кромки, проезд, двойной ряд, …
    bands = []
    v = v0 + 0.6
    bands.append((v, v + STALL_DEPTH))
    v += STALL_DEPTH + AISLE_WIDTH
    while v + 2 * STALL_DEPTH <= v1 - 0.6:
        bands.append((v, v + STALL_DEPTH))
        bands.append((v + STALL_DEPTH, v + 2 * STALL_DEPTH))
        v += 2 * STALL_DEPTH + AISLE_WIDTH
    if v + STALL_DEPTH <= v1 - 0.6:
        bands.append((v, v + STALL_DEPTH))
    out = []
    for low, high in bands:
        u = u0 + 1.0
        while u <= u1 - 1.0:
            if ok(u, low + 0.3) and ok(u, high - 0.3) and ok(u, (low + high) / 2):
                out.append([back(u, low), back(u, high)])
            u += STALL_WIDTH
    return out
