#!/usr/bin/env python3
"""Проверка сгенерированной поверхности дорог: полотно, узлы, разделительные.

ЗАЧЕМ. Поверхность (набор «d», слой surface в MVT) — не данные OSM, а наша
геометрия: её строит build_roads из осевых. 27.09.2026 владелец прислал снимок
моста Навои через Анхор: разделительная полоса вывернута «бабочкой», от неё
иглы, край полотна в ступеньках. Данные там верны — кривыми были наши
многоугольники, и до карты они доехали потому, что их никто не проверял.

ПРАВИЛО. Многоугольник, не прошедший проверку, на карту не едет. Полотно всё
равно нарисовано линией своей ширины (слой roads в стиле лежит под
поверхностью), поэтому выброшенный полигон стоит «шва» на перекрёстке, а
оставленный кривой — кляксы, которую видно с первого взгляда.

Проверки — в метрах, в локальной проекции у широты фигуры:
* самопересечение кромки (ровно «бабочка» со снимка);
* игла — острый угол при длинных рёбрах;
* лезвие — средняя ширина 2S/P меньше метра: такая фигура на карте только
  линия-артефакт, а не островок и не полоса.

Запуск по готовым тайлам (отчёт + geojson плохих для глаз):
    python3 server/surface_check.py <каталог тайлов> [--bbox lon1,lat1,lon2,lat2] [--geojson bad.geojson]
"""
import argparse
import json
import math
import os
import sys
from collections import Counter

LAT_METERS = 111_320.0

# Игла: угол при вершине острее этого, и оба ребра при ней длиннее
# SPIKE_MIN_EDGE. Короткое острое ребро — это скругление дуги или стык, его
# на карте не видно; длинное — игла, которую видно с любого зума.
SPIKE_MAX_ANGLE_DEG = 12.0
SPIKE_MIN_EDGE_METERS = 6.0
# Лезвие: средняя ширина фигуры (2·площадь/периметр). Самый узкий настоящий
# островок на съезде — бордюр в полтора-два метра.
SLIVER_MAX_MEAN_WIDTH_METERS = 1.0

REASON_SELF_INTERSECTION = "самопересечение"
REASON_SPIKE = "игла"
REASON_SLIVER = "лезвие"
REASON_DEGENERATE = "вырождена"


def to_meters(ring):
    """[(lon, lat)] → [(x, y)] в метрах у средней широты кольца. Без замыкающей точки."""
    points = list(ring)
    if len(points) > 1 and points[0] == points[-1]:
        points = points[:-1]
    if not points:
        return []
    mid = sum(lat for _lon, lat in points) / len(points)
    kx = LAT_METERS * math.cos(math.radians(mid))
    return [(lon * kx, lat * LAT_METERS) for lon, lat in points]


def area_and_perimeter(xy):
    twice = perimeter = 0.0
    for i, (x1, y1) in enumerate(xy):
        x2, y2 = xy[(i + 1) % len(xy)]
        twice += x1 * y2 - x2 * y1
        perimeter += math.hypot(x2 - x1, y2 - y1)
    return abs(twice) / 2.0, perimeter


def _orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _cross(p1, p2, q1, q2):
    """Пересекаются ли отрезки в ВНУТРЕННИХ точках (касание концами — нет)."""
    d1, d2 = _orient(q1, q2, p1), _orient(q1, q2, p2)
    d3, d4 = _orient(p1, p2, q1), _orient(p1, p2, q2)
    return ((d1 > 0) != (d2 > 0) and d1 != 0 and d2 != 0
            and (d3 > 0) != (d4 > 0) and d3 != 0 and d4 != 0)


def self_intersects(xy):
    """Пересекает ли кромка сама себя. Рамки отсекают почти все пары до
    точного теста; фигуры поверхности — десятки-сотни вершин."""
    n = len(xy)
    if n < 4:
        return False
    edges = []
    for i in range(n):
        a, b = xy[i], xy[(i + 1) % n]
        edges.append((a, b, min(a[0], b[0]), max(a[0], b[0]),
                      min(a[1], b[1]), max(a[1], b[1])))
    order = sorted(range(n), key=lambda i: edges[i][2])
    for position, i in enumerate(order):
        a, b, _x0, x1, y0, y1 = edges[i]
        for j in order[position + 1:]:
            c, d, cx0, _cx1, cy0, cy1 = edges[j]
            if cx0 > x1:
                break
            if cy0 > y1 or cy1 < y0:
                continue
            if abs(i - j) in (1, n - 1):
                continue  # соседние рёбра делят вершину
            if _cross(a, b, c, d):
                return True
    return False


def spike_at(xy):
    """Индекс вершины-иглы или None."""
    n = len(xy)
    for i in range(n):
        prev, here, nxt = xy[i - 1], xy[i], xy[(i + 1) % n]
        ax, ay = prev[0] - here[0], prev[1] - here[1]
        bx, by = nxt[0] - here[0], nxt[1] - here[1]
        la, lb = math.hypot(ax, ay), math.hypot(bx, by)
        if la < SPIKE_MIN_EDGE_METERS or lb < SPIKE_MIN_EDGE_METERS:
            continue
        cosine = max(-1.0, min(1.0, (ax * bx + ay * by) / (la * lb)))
        if math.degrees(math.acos(cosine)) < SPIKE_MAX_ANGLE_DEG:
            return i
    return None


def defect(ring, shape_checks=True):
    """Причина отказа многоугольника поверхности или None, если он годен.

    shape_checks=False — только целостность (вырожденность, самопересечение).
    Так проверяется ПОЛОТНО: короткий кусок улицы шириной в семь метров по
    «средней ширине» похож на лезвие, а торец под прямым углом — не игла.
    Лезвия и иглы ищутся у разделительных и островков, где они и есть брак.
    """
    xy = to_meters(ring)
    if len(xy) < 3:
        return REASON_DEGENERATE
    # Самопересечение — раньше площади: у симметричной «бабочки» доли
    # обхода гасят друг друга, и площадь выходит нулевой.
    if self_intersects(xy):
        return REASON_SELF_INTERSECTION
    area, perimeter = area_and_perimeter(xy)
    if area <= 0.0 or perimeter <= 0.0:
        return REASON_DEGENERATE
    if not shape_checks:
        return None
    if 2.0 * area / perimeter < SLIVER_MAX_MEAN_WIDTH_METERS:
        return REASON_SLIVER
    if spike_at(xy) is not None:
        return REASON_SPIKE
    return None


def defect_of_kind(kind, ring):
    """Проверка по виду поверхности: полотно — целостность, остальное — всё."""
    return defect(ring, shape_checks=(kind != 7))


# --- Отчёт по готовым тайлам ------------------------------------------------

KIND_NAMES = {7: "полотно", 8: "узел", 9: "разделительная/островок", 10: "центр перекрёстка"}


def _inside(ring, bbox):
    if not bbox:
        return True
    lon1, lat1, lon2, lat2 = bbox
    return any(lon1 <= lon <= lon2 and lat1 <= lat <= lat2 for lon, lat in ring)


def scan(tiles_dir, bbox=None):
    """(всего по виду, плохих по (вид, причина), список плохих фигур)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import build_mvt
    total, bad, shapes = Counter(), Counter(), []
    for kind, _flags, ring in build_mvt.written_areas(tiles_dir, "d"):
        if kind not in KIND_NAMES or not _inside(ring, bbox):
            continue
        total[kind] += 1
        reason = defect_of_kind(kind, ring)
        if reason:
            bad[(kind, reason)] += 1
            shapes.append((kind, reason, ring))
    return total, bad, shapes


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("tiles")
    parser.add_argument("--bbox", default=None, help="lon1,lat1,lon2,lat2")
    parser.add_argument("--geojson", default=None)
    args = parser.parse_args()
    bbox = tuple(float(v) for v in args.bbox.split(",")) if args.bbox else None
    total, bad, shapes = scan(args.tiles, bbox)
    for kind, name in KIND_NAMES.items():
        broken = sum(n for (k, _r), n in bad.items() if k == kind)
        share = 100.0 * broken / total[kind] if total[kind] else 0.0
        reasons = ", ".join(f"{r} {n}" for (k, r), n in sorted(bad.items()) if k == kind)
        print(f"{name:26} всего {total[kind]:7d}  плохих {broken:6d} ({share:4.1f}%)  {reasons}")
    if args.geojson:
        features = [{"type": "Feature",
                     "properties": {"kind": KIND_NAMES[k], "reason": r},
                     "geometry": {"type": "Polygon", "coordinates": [[list(p) for p in ring]]}}
                    for k, r, ring in shapes]
        with open(args.geojson, "w") as handle:
            json.dump({"type": "FeatureCollection", "features": features}, handle)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
