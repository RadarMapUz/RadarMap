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


# --- стрелки в своих полосах -------------------------------------------------
#
# Жалоба владельца (снимок с телефона, 23.10.2026): «стрелка лежит на линии
# разметки, ряд стрелок не совпадает с пунктирами». Глазами такое находили по
# одному месту; здесь — по всей сборке: где центр каждой стрелки относительно
# нарисованных кромок ленты и линий полос рядом с ней.

# Лента под стрелкой: идёт вдоль хода (до 35°), стрелка на её полотне с запасом.
LANE_ROAD_COS = math.cos(math.radians(35))
LANE_ROAD_SLACK_METERS = 1.5
# Линия полосы рядом со стрелкой: параллельна ходу (до 20°), ближе этого вбок
# и вдоль — под стрелкой или кончается не дальше этого от неё: глаз продолжает
# линию, оборванную у узла, и стрелка на её продолжении читается «на линии».
LANE_LINE_COS = math.cos(math.radians(20))
LANE_LINE_REACH_METERS = 9.0
LANE_LINE_ALONG_SLACK_METERS = 6.0
# Стрелка «посередине своей полосы», если до ближайшей границы полосы не
# меньше этой доли её ширины: 0,25 — центр стрелки в средней половине полосы.
LANE_CENTRE_SHARE = 0.25
# Линии ближе этого друг к другу — одна граница (осевая у кромки и т. п.).
LANE_MERGE_METERS = 0.6
# Значок стрелки (lw) не шире и не уже своей полосы больше чем на эту долю.
LANE_ICON_SHARE = 0.3
# Линия разметки «на полотне»: от оси ленты не дальше полуширины минус это.
MARKING_EDGE_MARGIN_METERS = 0.2


class _Segments:
    """Отрезки с полезной нагрузкой по клеткам ~55 м (дороги, линии разметки)."""

    CELL = 0.0005

    def __init__(self):
        self._grid = defaultdict(list)

    def add(self, a, b, payload, pad_m=0.0):
        pad = pad_m / 80_000
        for gx in range(int((min(a[0], b[0]) - pad) / self.CELL) - 1, int((max(a[0], b[0]) + pad) / self.CELL) + 2):
            for gy in range(int((min(a[1], b[1]) - pad) / self.CELL) - 1, int((max(a[1], b[1]) + pad) / self.CELL) + 2):
                self._grid[(gx, gy)].append((a, b, payload))

    def near(self, p):
        return self._grid.get((int(p[0] / self.CELL), int(p[1] / self.CELL)), ())


def _local(p, a, b):
    """(вектор отрезка в метрах, длина, t проекции p без обрезки, точка проекции − p в метрах)."""
    kx = LAT_M * math.cos(math.radians(p[1]))
    ax, ay = (a[0] - p[0]) * kx, (a[1] - p[1]) * LAT_M
    bx, by = (b[0] - p[0]) * kx, (b[1] - p[1]) * LAT_M
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    if length == 0:
        return (0.0, 0.0), 0.0, 0.0, (ax, ay)
    t = -(ax * dx + ay * dy) / (length * length)
    tc = max(0.0, min(1.0, t))
    return (dx / length, dy / length), length, t, (ax + tc * dx, ay + tc * dy)


def lane_index(roads, markings):
    """roads — [(линия, свойства слоя roads)], markings — [(линия, свойства)].

    Только наземные: стрелки ставятся на землю, а эстакада над узлом со своими
    полосами — другой уровень.
    """
    road_index, line_index = _Segments(), _Segments()
    for line, props in roads:
        if props.get("tunnel") or props.get("bridge") or props.get("cls", 9) > 7:
            continue
        half = float(props.get("width") or 0) / 2.0
        if half <= 0:
            continue
        for i, (a, b) in enumerate(zip(line, line[1:])):
            road_index.add(a, b, (half, bool(props.get("oneway")), line, i), pad_m=half + LANE_ROAD_SLACK_METERS)
    for line, props in markings:
        if props.get("bridge"):
            continue
        for a, b in zip(line, line[1:]):
            line_index.add(a, b, props.get("centre", 0), pad_m=LANE_LINE_REACH_METERS)
    return road_index, line_index


def row_centres(arrows):
    """Центр ряда для каждой стрелки: ряд — стрелки с тем же азимутом и lw в пределах 12 м.

    Ленту под рядом сборка выбирает по его центру (OverlapIndex.carriageway);
    крайняя стрелка бывает ближе к оси соседней ленты (съезд вдоль подхода),
    и проверка по одной стрелке выбрала бы не ту ленту.
    """
    cells = defaultdict(list)
    for index, arrow in enumerate(arrows):
        cells[(int(arrow[0] / 0.0002), int(arrow[1] / 0.0002))].append(index)
    out = []
    for arrow in arrows:
        kx = LAT_M * math.cos(math.radians(arrow[1]))
        cx, cy = int(arrow[0] / 0.0002), int(arrow[1] / 0.0002)
        mates = [arrows[j] for gx in (-1, 0, 1) for gy in (-1, 0, 1) for j in cells.get((cx + gx, cy + gy), ())
                 if arrows[j][2] == arrow[2] and arrows[j][3] == arrow[3]
                 and math.hypot((arrows[j][0] - arrow[0]) * kx, (arrows[j][1] - arrow[1]) * LAT_M) <= 12.0]
        out.append((sum(m[0] for m in mates) / len(mates), sum(m[1] for m in mates) / len(mates)))
    return out


def arrow_in_lane(arrow, road_index, line_index, centre=None):
    """Разбор одной стрелки: None — всё хорошо, иначе (вид брака, подробности).

    arrow — (lon, lat, азимут, lw). Виды брака:
      no_road    — под стрелкой нет ленты по ходу (стрелка на газоне/в узле);
      off_road   — центр стрелки за кромкой своей ленты;
      off_centre — центр ближе LANE_CENTRE_SHARE ширины полосы к её границе
                   (линии разметки или кромке): «стрелка на линии»;
      icon_size  — ширина значка (lw) не по полосе между линиями.
    """
    lon, lat, bearing, lw = arrow
    p = (lon, lat)
    fx, fy = math.sin(math.radians(bearing)), math.cos(math.radians(bearing))
    rx, ry = fy, -fx                                   # вправо от хода
    found = _ribbon_under(centre or p, bearing, road_index)
    if found is None:
        return ("no_road", {})
    a, b, half, oneway = found[0], found[1], found[2], found[3]
    (_u, _v), _length, _t, (px, py) = _local(p, a, b)
    # Отрезок оси — бесконечной прямой: стрелка у конца отрезка меряется поперёк.
    (ux, uy) = _u, _v
    ax, ay = (a[0] - lon) * LAT_M * math.cos(math.radians(lat)), (a[1] - lat) * LAT_M
    s = -((ax - (ax * ux + ay * uy) * ux) * rx + (ay - (ax * ux + ay * uy) * uy) * ry)
    low, high = (-half, half) if oneway else (0.0, half)
    if not low - 0.05 <= s <= high + 0.05:
        return ("off_road", {"s": round(s, 2), "half": round(half, 2)})
    bounds = [low, high]
    dividers = 0
    for a, b, _centre in line_index.near(p):
        (ux, uy), length, t, (px, py) = _local(p, a, b)
        if length == 0 or abs(ux * fx + uy * fy) < LANE_LINE_COS:
            continue
        slack = LANE_LINE_ALONG_SLACK_METERS / length
        if not -slack <= t <= 1 + slack:
            continue
        across = px * rx + py * ry                     # линия правее стрелки на столько
        if abs(across) > LANE_LINE_REACH_METERS:
            continue
        at = s + across
        if low + LANE_MERGE_METERS < at < high - LANE_MERGE_METERS:
            bounds.append(at)
            dividers += 1
    bounds.sort()
    merged = [bounds[0]]
    for value in bounds[1:]:
        if value - merged[-1] >= LANE_MERGE_METERS:
            merged.append(value)
        else:
            merged[-1] = (merged[-1] + value) / 2
    for left, right in zip(merged, merged[1:]):
        if left <= s <= right:
            width = right - left
            gap = min(s - left, right - s)
            detail = {"s": round(s, 2), "lane": round(width, 2), "gap": round(gap, 2),
                      "lines": dividers, "lw": lw}
            if not dividers and lw:
                # Линий рядом нет — полосы задаёт сам ряд: стрелка должна
                # стоять посередине своей клетки шириной lw от кромки.
                cell = (s - low) / lw
                if abs(cell - math.floor(cell) - 0.5) > 0.5 - LANE_CENTRE_SHARE or s - low < lw * LANE_CENTRE_SHARE \
                        or high - s < lw * LANE_CENTRE_SHARE:
                    return ("off_centre", detail)
                return None
            if gap < LANE_CENTRE_SHARE * width:
                return ("off_centre", detail)
            if dividers and lw and abs(lw - width) > LANE_ICON_SHARE * width:
                return ("icon_size", detail)
            return None
    return ("off_road", {"s": round(s, 2), "half": round(half, 2)})


# Ось ленты под стрелкой — хордой на столько метров назад и вперёд по ломаной:
# направление одного отрезка тайла шумит от квантования координат (шаг ~0,3 м).
ARROW_AXIS_CHORD_METERS = 8.0
# Стрелка повёрнута относительно ленты больше этого — видно глазом рядом с
# пунктиром (Навои × Рашидов, 5°, 23.10.2026).
ARROW_ANGLE_LIMIT_DEGREES = 2.0


def _along(line, i, t, metres):
    """Точка на ломаной в metres от точки (отрезок i, доля t) — вперёд (>0) или назад."""
    a, b = line[i], line[i + 1]
    point = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    kx = LAT_M * math.cos(math.radians(point[1]))
    step = 1 if metres > 0 else -1
    left = abs(metres)
    j = i + 1 if step > 0 else i
    while 0 <= j < len(line):
        nxt = line[j]
        d = math.hypot((nxt[0] - point[0]) * kx, (nxt[1] - point[1]) * LAT_M)
        if d >= left and d > 0:
            f = left / d
            return (point[0] + (nxt[0] - point[0]) * f, point[1] + (nxt[1] - point[1]) * f)
        left -= d
        point = nxt
        j += step
    return point


def _ribbon_under(p, bearing, road_index):
    """(a, b, полуширина, односторонняя?, ломаная, номер отрезка, t, cos) ближайшей ленты по ходу."""
    fx, fy = math.sin(math.radians(bearing)), math.cos(math.radians(bearing))
    best = None
    for a, b, (half, oneway, line, i) in road_index.near(p):
        (ux, uy), length, t, (px, py) = _local(p, a, b)
        if length == 0:
            continue
        cos = ux * fx + uy * fy
        if (cos if oneway else abs(cos)) < LANE_ROAD_COS:
            continue
        lateral = math.hypot(px, py)
        if lateral > half + LANE_ROAD_SLACK_METERS:
            continue
        if best is None or lateral < best[0]:
            best = (lateral, (a, b, half, oneway, line, i, max(0.0, min(1.0, t)), cos))
    return None if best is None else best[1]


def arrow_axis_angle(arrow, road_index, centre=None):
    """На сколько градусов стрелка повёрнута относительно оси своей ленты; None — ленты нет."""
    lon, lat, bearing = arrow[0], arrow[1], arrow[2]
    found = _ribbon_under(centre or (lon, lat), bearing, road_index)
    if found is None:
        return None
    line, i, t, cos = found[4], found[5], found[6], found[7]
    back = _along(line, i, t, -ARROW_AXIS_CHORD_METERS)
    ahead = _along(line, i, t, ARROW_AXIS_CHORD_METERS)
    kx = LAT_M * math.cos(math.radians(lat))
    axis = math.degrees(math.atan2((ahead[0] - back[0]) * kx, (ahead[1] - back[1]) * LAT_M))
    if cos < 0:
        axis += 180
    return abs((bearing - axis + 180) % 360 - 180)


# Ступенька пунктира: линия кончается, а рядом начинается другая, сдвинутая
# вбок на столько — на стыке кусков с разным числом полос (Навои, 4 → 5).
JUMP_REACH_METERS = 3.0
JUMP_MIN_METERS = 0.3
JUMP_MAX_METERS = 2.5


def marking_jumps(markings, examples=None):
    """(ступенек на 100 км разметки, наибольший сдвиг, м) — концы линий, продолженные вбок."""
    ends = SegmentIndex([])
    grid = defaultdict(list)
    total = 0.0
    for index, (line, props) in enumerate(markings):
        if len(line) < 2:
            continue
        kx = LAT_M * math.cos(math.radians(line[0][1]))
        total += sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M) for a, b in zip(line, line[1:]))
        for end, inner in ((line[0], line[1]), (line[-1], line[-2])):
            dx, dy = (end[0] - inner[0]) * kx, (end[1] - inner[1]) * LAT_M
            norm = math.hypot(dx, dy)
            if norm == 0:
                continue
            grid[(int(end[0] / ends.CELL), int(end[1] / ends.CELL))].append(
                (index, end, (dx / norm, dy / norm), bool(props.get("bridge"))))
    jumps, worst = 0, 0.0
    for cell, items in grid.items():
        near = [item for gx in (-1, 0, 1) for gy in (-1, 0, 1) for item in grid.get((cell[0] + gx, cell[1] + gy), ())]
        for index, end, (ux, uy), bridge in items:
            kx = LAT_M * math.cos(math.radians(end[1]))
            closest = None
            for other, point, (vx, vy), other_bridge in near:
                if other == index or bridge != other_bridge:
                    continue
                # Продолжение — встречные концы: наш смотрит туда, их — к нам.
                if ux * vx + uy * vy > -LANE_LINE_COS:
                    continue
                dx, dy = (point[0] - end[0]) * kx, (point[1] - end[1]) * LAT_M
                along = dx * ux + dy * uy
                across = abs(dx * uy - dy * ux)
                if abs(along) > JUMP_REACH_METERS or across > JUMP_MAX_METERS:
                    continue
                closest = across if closest is None else min(closest, across)
            # Ступенька — продолжение есть только сдвинутое вбок; продолжение
            # без сдвига (соседняя полоса рядом не в счёт) — линия цела.
            if closest is not None and closest >= JUMP_MIN_METERS:
                jumps += 1
                worst = max(worst, closest)
                if examples is not None:
                    examples.append((round(end[1], 5), round(end[0], 5), round(closest, 2)))
    return (100_000.0 * jumps / total if total else 0.0), round(worst, 2)


# Зебра ступенькой: две зебры одного перехода на соседних лентах проспекта
# стоят со сдвигом вдоль улицы (Нурафшон × Фаробий, Навои × Лабзак).
ZEBRA_STEP_MIN_METERS = 1.0
ZEBRA_STEP_MAX_METERS = 10.0
ZEBRA_STEP_GAP_METERS = 8.0


def zebra_steps(zebras, examples=None):
    """Зебр-ступенек на 100 зебр: параллельная соседка, конец к концу не дальше
    ZEBRA_STEP_GAP_METERS, но сдвинута вдоль улицы на 1–10 м."""
    items = []
    for line in zebras:
        if len(line) < 2:
            continue
        a, b = line[0], line[-1]
        kx = LAT_M * math.cos(math.radians(a[1]))
        dx, dy = (b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M
        length = math.hypot(dx, dy)
        if length == 0:
            continue
        items.append((a, b, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), (dx / length, dy / length)))
    grid = defaultdict(list)
    for index, item in enumerate(items):
        grid[(int(item[2][0] / 0.0005), int(item[2][1] / 0.0005))].append(index)
    stepped = set()
    for index, (a, b, centre, (ux, uy)) in enumerate(items):
        kx = LAT_M * math.cos(math.radians(centre[1]))
        cell = (int(centre[0] / 0.0005), int(centre[1] / 0.0005))
        for gx in (-1, 0, 1):
            for gy in (-1, 0, 1):
                for other in grid.get((cell[0] + gx, cell[1] + gy), ()):
                    if other <= index:
                        continue
                    oa, ob, oc, (vx, vy) = items[other]
                    if abs(ux * vx + uy * vy) < 0.97:
                        continue
                    gap = min(math.hypot((p[0] - q[0]) * kx, (p[1] - q[1]) * LAT_M)
                              for p in (a, b) for q in (oa, ob))
                    if gap > ZEBRA_STEP_GAP_METERS:
                        continue
                    dx, dy = (oc[0] - centre[0]) * kx, (oc[1] - centre[1]) * LAT_M
                    along = abs(dx * uy - dy * ux)          # вдоль улицы = поперёк зебры
                    beside = abs(dx * ux + dy * uy)         # бок о бок — вдоль зебры
                    shorter = min(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M),
                                  math.hypot((ob[0] - oa[0]) * kx, (ob[1] - oa[1]) * LAT_M))
                    # Ступенька — соседки бок о бок (на соседних лентах); зебры
                    # друг за другом вдоль одной ленты — это разные переходы.
                    if beside < 0.6 * shorter:
                        continue
                    if ZEBRA_STEP_MIN_METERS <= along <= ZEBRA_STEP_MAX_METERS:
                        stepped.update((index, other))
                        if examples is not None:
                            examples.append((round(centre[1], 5), round(centre[0], 5), round(along, 1)))
    return 100.0 * len(stepped) / len(items) if items else 0.0


UNMARKED_MIN_WIDTH_METERS = 6.5
UNMARKED_STEP_METERS = 10.0


def unmarked_avenues(roads, line_index, examples=None):
    """% длины односторонних лент проспекта и выше (шире 6,5 м) без единой
    линии полос рядом — «то есть разметка, то нет» (аудит 28.G, №9)."""
    total = bare = 0.0
    for line, props in roads:
        if (not props.get("oneway") or props.get("cls", 9) > 3 or props.get("tunnel")
                or float(props.get("width") or 0) < UNMARKED_MIN_WIDTH_METERS):
            continue
        half = float(props["width"]) / 2.0
        for p in densify(line, UNMARKED_STEP_METERS)[1:-1]:
            total += UNMARKED_STEP_METERS
            marked = False
            for a, b, _centre in line_index.near(p):
                if seg_distance_m(p, a, b) <= half - 0.3:
                    marked = True
                    break
            if not marked:
                bare += UNMARKED_STEP_METERS
                if examples is not None and len(examples) < 200:
                    examples.append((round(p[1], 5), round(p[0], 5)))
    return 100.0 * bare / total if total else 0.0


def bridge_seams(roads, examples=None):
    """Стыков кусков моста на 1 км настила: два конца лент моста в одной точке,
    одна продолжает другую. Каждый такой стык — поперечный шов на настиле
    (прямые торцы под углом, аудит 28.G, №2)."""
    grid = defaultdict(list)
    total = 0.0
    for index, (line, props) in enumerate(roads):
        if not props.get("bridge") or len(line) < 2:
            continue
        kx = LAT_M * math.cos(math.radians(line[0][1]))
        total += sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * LAT_M) for a, b in zip(line, line[1:]))
        for end in (line[0], line[-1]):
            grid[(round(end[0], 5), round(end[1], 5))].append(index)
    seams = 0
    for spot, items in grid.items():
        if len(set(items)) == 2:
            seams += 1
            if examples is not None:
                examples.append((spot[1], spot[0]))
    return 1000.0 * seams / total if total else 0.0


def _colour_group(cls):
    """Группа цвета асфальта класса — как make_style.class_asphalt."""
    if cls in (1, 2):
        return 1
    return cls if cls in (3, 4, 5) else 6


def junction_colour_mismatch(junctions, roads, examples=None):
    """Доля (%) площадей узла, чей цвет не совпадает с цветом самой широкой ленты на них.

    junctions — [(кольцо, свойства)], roads — [(линия, свойства)]. Узел без
    класса красится цветом проспекта: на магистрали это белая заплатка у
    торца эстакады (аудит 28.G, №3). Мерится в центре площади: под ним —
    лента, старшая по классу.
    """
    index = _Segments()
    for line, props in roads:
        half = float(props.get("width") or 0) / 2.0
        # Узел — на земле: эстакада над ним (и тоннель под ним) — не его лента.
        if half <= 0 or props.get("tunnel") or props.get("bridge") or props.get("cls", 9) > 7:
            continue
        for a, b in zip(line, line[1:]):
            index.add(a, b, (half, props.get("cls", 9)), pad_m=half)
    checked = bad = 0
    for ring, props in junctions:
        cx = sum(p[0] for p in ring) / len(ring)
        cy = sum(p[1] for p in ring) / len(ring)
        # Ленты, на которых лежит узел: под центром или у любой вершины контура
        # (у Т-образного узла центр — на младшей улице, старшая — у края).
        under = [(-half, cls) for q in [(cx, cy)] + list(ring) for a, b, (half, cls) in index.near(q)
                 if seg_distance_m(q, a, b) <= half + 0.5]
        if not under:
            continue
        checked += 1
        drawn = props.get("cls", 3)          # без класса — цвет проспекта
        widest = min(under)[1]               # самая широкая лента, при равных — старшая
        if _colour_group(drawn) != _colour_group(widest):
            bad += 1
            if examples is not None:
                examples.append((round(cy, 5), round(cx, 5), drawn, widest))
    return 100.0 * bad / checked if checked else 0.0


def lane_arrow_defects(arrows, road_index, line_index, examples=None):
    """{вид брака: число} по всем стрелкам; examples — [(вид, lon, lat, подробности)]."""
    counts = defaultdict(int)
    for arrow, centre in zip(arrows, row_centres(arrows)):
        found = arrow_in_lane(arrow, road_index, line_index, centre)
        if found is None:
            continue
        kind, detail = found
        counts[kind] += 1
        if examples is not None:
            examples.append((kind, round(arrow[1], 5), round(arrow[0], 5), detail))
    return dict(counts)


def markings_off_road(markings, road_index, asphalt, examples=None):
    """Метров наземной разметки за кромкой полотна на 1 км разметки.

    «На полотне» — ближе полуширины минус MARKING_EDGE_MARGIN_METERS к оси
    любой наземной ленты или на площади асфальта (узел, скругление угла).
    """
    total = off = 0.0
    for line, props in markings:
        if props.get("bridge"):
            continue
        for q in densify(line):
            total += SAMPLE_STEP_METERS
            ok = asphalt is not None and asphalt.covers(q)
            if not ok:
                for a, b, (half, _oneway, _line, _i) in road_index.near(q):
                    if seg_distance_m(q, a, b) <= half - MARKING_EDGE_MARGIN_METERS:
                        ok = True
                        break
            if not ok:
                off += SAMPLE_STEP_METERS
                if examples is not None:
                    examples.append((round(q[1], 5), round(q[0], 5)))
    return (1000.0 * off / total) if total else 0.0


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
    marking_lines = [(part, props) for g, parts, props in layers.get("markings", []) if g == 2 for part in parts]
    road_index, line_index = lane_index([(part, props) for parts, props in road_lines for part in parts],
                                        marking_lines)
    lane_arrows = [(parts[0][0][0], parts[0][0][1], props.get("bearing", 0), props.get("lw"))
                   for g, parts, props in layers.get("arrows", []) if parts]
    lane_examples = []
    lane_counts = lane_arrow_defects(lane_arrows, road_index, line_index, lane_examples)
    off_road_examples = []
    marking_off = markings_off_road(marking_lines, road_index, open_areas, off_road_examples)
    angles = [(arrow_axis_angle(arrow, road_index, centre), arrow)
              for arrow, centre in zip(lane_arrows, row_centres(lane_arrows))]
    angles = [(angle, arrow) for angle, arrow in angles if angle is not None]
    tilted = sorted(((angle, arrow) for angle, arrow in angles if angle > ARROW_ANGLE_LIMIT_DEGREES),
                    reverse=True)
    jump_examples = []
    jumps, jump_worst = marking_jumps(marking_lines, jump_examples)
    bare_examples = []
    bare = unmarked_avenues([(part, props) for parts, props in road_lines for part in parts], line_index,
                            bare_examples)
    step_examples = []
    steps = zebra_steps([part for g, parts, props in paint if props.get("kind") == 12 for part in parts],
                        step_examples)
    seam_examples = []
    seams = bridge_seams([(part, props) for parts, props in road_lines for part in parts], seam_examples)
    colour_examples = []
    colour_mismatch = junction_colour_mismatch(
        [(parts[0], props) for g, parts, props in surface if g == 3 and props.get("kind") == 8 and parts],
        [(part, props) for parts, props in road_lines for part in parts], colour_examples)

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
    # Раздутый узел: площадь узла больше BLOATED_JUNCTION_M2 — клякса вдоль
    # улицы вместо компактного перекрёстка (Навои × Фуркат, 06.10.2026).
    junction_all = [parts[0] for g, parts, props in surface
                    if g == 3 and props.get("kind") in (8, 10) and parts and not props.get("fill")
                    and polygon_area_m2(parts[0]) >= JUNCTION_MIN_AREA_M2]
    bloated = sum(1 for ring in junction_all if polygon_area_m2(ring) > BLOATED_JUNCTION_M2)
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
        "junction_bloat": round(100 * bloated / len(junction_all), 2) if junction_all else 0.0,
        "junction_spikes": round(100 * spikes / len(shapes), 2) if shapes else 0.0,
        "island_slivers": round(100 * slivers / len(island_rings), 2) if island_rings else 0.0,
        "zebra_duplicates": round(100 * zebra_duplicates, 2),
        "arrows_off_lane": round(1000 * sum(lane_counts.get(k, 0) for k in ("off_centre", "off_road", "no_road"))
                                 / len(lane_arrows), 1) if lane_arrows else 0.0,
        "arrows_icon_size": round(1000 * lane_counts.get("icon_size", 0) / len(lane_arrows), 1) if lane_arrows else 0.0,
        "markings_off_road": round(marking_off, 1),
        "arrows_angle_max": round(max((a for a, _ in angles), default=0.0), 1),
        "arrows_tilted": round(1000 * len(tilted) / len(lane_arrows), 1) if lane_arrows else 0.0,
        "marking_jumps": round(jumps, 1),
        "junction_colour_mismatch": round(colour_mismatch, 2),
        "bridge_seams": round(seams, 2),
        "zebra_steps": round(steps, 2),
        "avenues_unmarked": round(bare, 1),
        "_unmarked_examples": bare_examples[:30],
        "_zebra_step_examples": step_examples[:30],
        "_seam_examples": seam_examples[:30],
        "_colour_examples": colour_examples[:30],
        "_marking_jump_worst": jump_worst,
        "_tilted_examples": [(round(a, 1), round(arrow[1], 5), round(arrow[0], 5)) for a, arrow in tilted[:30]],
        "_jump_examples": sorted(jump_examples, key=lambda e: -e[2])[:30],
        "_lane_counts": lane_counts,
        "_lane_examples": lane_examples,
        "_marking_off_examples": off_road_examples,
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
    "junction_bloat": "% раздутых узлов",
    "junction_spikes": "% фигур узла с иглой",
    "island_slivers": "% островков-клиньев",
    "zebra_duplicates": "% зебр-дублей",
    "arrows_off_lane": "на 1000 стрелок не посередине полосы",
    "arrows_icon_size": "на 1000 стрелок значок не по полосе",
    "markings_off_road": "м разметки за кромкой на 1 км",
    "arrows_angle_max": "° наибольший поворот стрелки к оси ленты",
    "arrows_tilted": f"на 1000 стрелок повёрнуты больше {ARROW_ANGLE_LIMIT_DEGREES:g}°",
    "marking_jumps": "ступенек пунктира на 100 км",
    "junction_colour_mismatch": "% узлов не цвета самой широкой ленты",
    "bridge_seams": "швов на 1 км настила мостов",
    "zebra_steps": "% зебр ступенькой к соседке",
    "avenues_unmarked": "% длины проспектов без линий полос",
}

# Потолки, выше которых публикация останавливается независимо от прошлой
# сборки (ворота «хуже, чем было» их не ловят, если было так же плохо).
CEILINGS = {"arrows_angle_max": ARROW_ANGLE_LIMIT_DEGREES}


# Площадь узла больше этого — раздут (крупнейшие настоящие узлы Ташкента
# между стоп-линиями — около 60 × 60 м).
BLOATED_JUNCTION_M2 = 3500.0
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
               "junction_spikes": 2.0, "island_slivers": 2.0, "junction_bloat": 2.0,
               "arrows_off_lane": 5.0, "arrows_icon_size": 5.0, "markings_off_road": 2.0,
               "arrows_tilted": 5.0, "marking_jumps": 5.0, "junction_colour_mismatch": 1.0, "bridge_seams": 1.0, "zebra_steps": 1.0, "avenues_unmarked": 5.0, "arrows_angle_max": ARROW_ANGLE_LIMIT_DEGREES}


def compare(previous, current):
    """Причины остановить публикацию: метрики, ухудшившиеся заметно."""
    reasons = [f"{key}: {current[key]} выше потолка {limit} ({UNITS[key]})"
               for key, limit in CEILINGS.items()
               if current.get(key) is not None and current[key] > limit]
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
    parser.add_argument("--worst", type=int, default=12, help="сколько худших мест печатать")
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
    print("  стрелки по видам брака:", result["_lane_counts"])
    for kind, lat, lon, detail in result["_lane_examples"][:args.worst]:
        print(f"    {kind:10} {lat},{lon}  {detail}")
    print("  разметка за кромкой (точки):", result["_marking_off_examples"][:args.worst])
    print("  повёрнутые стрелки (°, широта, долгота):", result["_tilted_examples"][:args.worst])
    print("  ступеньки пунктира (широта, долгота, сдвиг м), худшая", result["_marking_jump_worst"], ":",
          result["_jump_examples"][:args.worst])
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
