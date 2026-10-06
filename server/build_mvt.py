"""Тайлы MVT рядом с нашим форматом.

Наш JSON остаётся: его читают телефон и панель, и переход идёт параллельно, а
не заменой. MVT пишется из ТЕХ ЖЕ данных одним лишним шагом кодирования — это
не вторая копия карты, а второй вывод одной сборки.

Раскладка потоком, а не списком, и это не запас прочности: сборка страны уже
дважды была убита ядром по памяти, и оба слоя, которые её убивали, теперь
пишут файл сразу. Здесь тот же приём с самого начала.
"""
import gzip
import hashlib
import json
import math
import os
import shutil
from collections import OrderedDict, defaultdict

import mvt
from build_roads import (AREA_DIVIDER, FLAG_LANES_INFERRED, AREA_FILLET, AREA_HOUSE, AREA_JUNCTION, AREA_JUNCTION_BOX, AREA_MEDIAN, AREA_ROAD,
                         clip_ring,
                         FLAG_BRIDGE,
                         FLAG_LANES_TAGGED, FLAG_ONEWAY, FLAG_TUNNEL,
                         PFLAG_PAINTED, PFLAG_ONEWAY, point_azimuth, point_width,
                         SURFACE_CLASS_MASK, SURFACE_CLASS_SHIFT, lanes_of,
                         road_width_meters, POINT_LANE_ARROWS, MAX_ARROW_LANES,
                         unpack_turns)

# Зумы. Два, а не десять.
#
# Детальный — 15: в нём тайл около полутора километров по широте Ташкента, то
# есть примерно то, что видно на рабочем экране конструктора. Обзорный — 11:
# на нём рисуется костяк района, и подробная сеть там не нужна ни глазу, ни
# каналу. Промежуточные зумы клиент берёт растягиванием — так делают все, и
# писать их значило бы платить местом за то, что и так получается.
ZOOM_DETAIL = 15
ZOOM_FAR = 11

LAYER_ROADS = "roads"
LAYER_SURFACE = "surface"
LAYER_LAND = "land"
LAYER_HOUSES = "houses"
LAYER_POINTS = "points"
LAYER_MARKINGS = "markings"
LAYER_PAINT = "paint"
# Населённые пункты и районы: точка с именем и рангом (build_roads.PLACE_RANKS).
# Контракт с клиентом: слой «places», свойства name (строка) и rank (1 город,
# 2 посёлок, 3 кишлак, 4 хутор, 5 район, 6 квартал).
LAYER_PLACES = "places"
# Деревья из OSM (build_roads.collect_trees): точка на крону, без свойств.
LAYER_TREES = "trees"
# Стрелки полос: одна точка на ПОЛОСУ, свойства turn (код build_roads.TURN_*)
# и bearing (куда смотрит стрелка, градусы по часовой от севера).
LAYER_ARROWS = "arrows"
# Стрелку рисуют перед стоп-линией, а не на ней: на сколько метров отступить
# от точки подхода против движения.
ARROW_SETBACK_METERS = 15.0


def point_properties(code, flags):
    """Знак обязательной остановки не доказывает наличие нарисованной линии."""
    return {"kind": 7 if code == 3 and not flags & PFLAG_PAINTED else code,
            "flags": flags, "bearing": point_azimuth(flags), "width": point_width(flags),
            "painted": bool(flags & PFLAG_PAINTED)}


# Стрелки — ВСЕГДА до стоп-линии. Отступ от конца участка с turn:lanes
# (обычно — центр перекрёстка) ставил их МЕЖДУ стоп-линией у светофора и
# зеброй (Каратош × Бешёгоч, 05.10.2026). Если на том же подходе есть
# светофор, стрелки встают на ARROW_BEFORE_STOP метров перед его стоп-линией.
ARROW_SIGNAL_REACH_METERS = 60.0
ARROW_SIGNAL_DEGREES = 30.0
ARROW_BEFORE_STOP_METERS = 11.0


def arrow_setback(flags, point, signals):
    """Сколько метров назад от точки стрелок ставить их ряд (по светофору подхода)."""
    if not signals:
        return ARROW_SETBACK_METERS
    lon, lat = point
    kx = 111_320 * math.cos(math.radians(lat))
    bearing = point_azimuth(flags)
    forward = (math.sin(math.radians(bearing)), math.cos(math.radians(bearing)))
    best = None
    cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
    for gx in range(cell[0] - 1, cell[0] + 2):
        for gy in range(cell[1] - 1, cell[1] + 2):
            for slon, slat, sbearing in signals.get((gx, gy), ()):
                if sbearing is not None:
                    off = abs((sbearing - bearing + 180) % 360 - 180)
                    if min(off, 180 - off) > ARROW_SIGNAL_DEGREES:
                        continue
                dx, dy = (slon - lon) * kx, (slat - lat) * 111_320
                along = dx * forward[0] + dy * forward[1]
                lateral = abs(dx * forward[1] - dy * forward[0])
                if abs(along) > ARROW_SIGNAL_REACH_METERS or lateral > max(point_width(flags), 8.0):
                    continue
                if best is None or abs(along) < abs(best):
                    best = along
    if best is None:
        return ARROW_SETBACK_METERS
    stop_line = best - SIGNAL_STOP_SETBACK         # стоп-линия, м вдоль хода
    return max(ARROW_SETBACK_METERS, -(stop_line - ARROW_BEFORE_STOP_METERS)) \
        if stop_line - ARROW_BEFORE_STOP_METERS < -ARROW_SETBACK_METERS else ARROW_SETBACK_METERS


def lane_arrows(code, flags, point, setback=None):
    """Стрелки полос по одной на полосу, поперёк проезжей части.

    turn:lanes в OSM перечисляет полосы слева направо по ходу движения, поэтому
    первая стрелка — у левой кромки. Полос столько, сколько записано до
    последней непустой: хвост «без стрелки» справа ничего не рисует.
    """
    if code != POINT_LANE_ARROWS:
        return
    width = point_width(flags)
    turns = unpack_turns(flags, MAX_ARROW_LANES)
    used = max((i + 1 for i, turn in enumerate(turns) if turn), default=0)
    if width <= 0 or used == 0:
        return
    bearing = point_azimuth(flags)
    angle = math.radians(bearing)
    lon, lat = point
    lane = width / used
    for index, turn in enumerate(turns[:used]):
        if not turn:
            continue
        across = -width / 2 + lane * (index + 0.5)
        along = -(ARROW_SETBACK_METERS if setback is None else setback)
        yield ((lon + (math.cos(angle) * across + math.sin(angle) * along)
                / (111_320 * math.cos(math.radians(lat))),
                lat + (-math.sin(angle) * across + math.cos(angle) * along) / 111_320),
               {"turn": turn, "bearing": round(bearing)})


# Ряд стрелок, упавший в площадь перекрёстка или на зебру, отодвигается назад
# по подходу шагами; не нашёл места — не рисуется. Стрелка вне асфальта не
# рисуется никогда: на Шота Руставели (05.10.2026) ширина записи шире полотна,
# и крайние стрелки ложились на газон.
ARROW_PULLBACK_STEP_METERS = 4.0
ARROW_PULLBACK_MAX_METERS = 32.0


ARROW_HALF_LENGTH_METERS = 2.5


def _arrow_body(arrow, bearing):
    """Центр и концы значка стрелки: зебру задевает весь значок, а не центр."""
    lon, lat = arrow
    kx = 111_320 * math.cos(math.radians(lat))
    fx, fy = math.sin(math.radians(bearing)), math.cos(math.radians(bearing))
    return [(lon + fx * d / kx, lat + fy * d / 111_320)
            for d in (-ARROW_HALF_LENGTH_METERS, 0.0, ARROW_HALF_LENGTH_METERS)]


def placed_arrows(code, flags, point, setback, mask=None, asphalt=None):
    """Стрелки ряда, поставленные до перекрёстка и только на полотно.

    Сначала ищется место, где ряд целиком на асфальте и не задевает узел.
    Нет такого — ряд на своём месте без стрелок за кромкой (запись шире
    полотна), но только если он не в узле; иначе ряда нет.
    """
    base = ARROW_SETBACK_METERS if setback is None else setback
    bearing = point_azimuth(flags)

    def clear(arrow):
        return mask is None or not any(mask.covers(p) for p in _arrow_body(arrow, bearing))

    def paved(arrow):
        return asphalt is None or asphalt.covers(arrow)

    first = list(lane_arrows(code, flags, point, base))
    extra = 0.0
    while extra <= ARROW_PULLBACK_MAX_METERS:
        row = first if extra == 0.0 else list(lane_arrows(code, flags, point, base + extra))
        if all(clear(arrow) and paved(arrow) for arrow, _props in row):
            return row
        extra += ARROW_PULLBACK_STEP_METERS
    if all(clear(arrow) for arrow, _props in first):
        return [(arrow, props) for arrow, props in first if paved(arrow)]
    return []


def arrow_cells(points, cell):
    """Клетки сетки вокруг рядов стрелок — асфальт нужен только там."""
    cells = set()
    for point in points:
        if point[0] != POINT_LANE_ARROWS:
            continue
        lon, lat = point[2][0]
        gx, gy = int(lon / cell), int(lat / cell)
        cells.update((gx + dx, gy + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1))
    return cells


def near_cells(ring, cells, cell):
    lons = [p[0] for p in ring]
    lats = [p[1] for p in ring]
    return any((gx, gy) in cells
               for gx in range(int(min(lons) / cell), int(max(lons) / cell) + 1)
               for gy in range(int(min(lats) / cell), int(max(lats) / cell) + 1))


# Ряды стрелок на одном подходе. turn:lanes стоит на каждом куске ленты перед
# перекрёстком, и каждый кусок давал свой ряд: на Навои × Рашидов (снимок
# 28.09.2026) — по 2–3 ряда подряд. Рядом стоящие ряды одного направления на
# одной ленте — один подход; остаётся ближний к перекрёстку (самый передний).
ARROW_GROUP_METERS = 40.0
ARROW_SAME_BEARING_DEGREES = 20.0


def arrow_leaders(points):
    """Индексы точек стрелок, которые рисуются: по одной на подход."""
    arrows = [(i, p) for i, p in enumerate(points) if p[0] == POINT_LANE_ARROWS]
    grid = defaultdict(list)
    for i, p in arrows:
        lon, lat = p[2][0]
        grid[(int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))].append((i, p))
    keep = set()
    for i, p in arrows:
        lon, lat = p[2][0]
        bearing = point_azimuth(p[1])
        half = point_width(p[1]) / 2.0
        kx = 111_320 * math.cos(math.radians(lat))
        forward = (math.sin(math.radians(bearing)), math.cos(math.radians(bearing)))
        behind = False
        cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
        for gx in range(cell[0] - 1, cell[0] + 2):
            for gy in range(cell[1] - 1, cell[1] + 2):
                for j, q in grid.get((gx, gy), ()):
                    if j == i:
                        continue
                    turn = abs((point_azimuth(q[1]) - bearing + 180) % 360 - 180)
                    if turn > ARROW_SAME_BEARING_DEGREES:
                        continue
                    dx = (q[2][0][0] - lon) * kx
                    dy = (q[2][0][1] - lat) * 111_320
                    along = dx * forward[0] + dy * forward[1]
                    lateral = abs(dx * forward[1] - dy * forward[0])
                    if (1.0 < along <= ARROW_GROUP_METERS
                            and lateral <= max(half, point_width(q[1]) / 2.0)):
                        behind = True
                        break
                if behind:
                    break
            if behind:
                break
        if not behind:
            keep.add(i)
    return keep


# Стоп-линия у светофора на ДВУСТОРОННЕЙ дороге: только на своей, правой
# половине — с какой стороны подъезд, говорит ближайший перекрёсток впереди
# по оси (правостороннее движение). Без перекрёстка в пределах досягаемости
# направление неизвестно — не рисуем.
TWO_WAY_STOP_REACH_METERS = 50.0
TWO_WAY_STOP_AXIS_DEGREES = 35.0


def two_way_stop_line(flags, point, centres):
    """Стоп-линия поперёк правой половины двусторонней дороги или None."""
    width = point_width(flags)
    if width <= 0 or flags & PFLAG_ONEWAY or not centres:
        return None
    lon, lat = point
    kx = 111_320 * math.cos(math.radians(lat))
    bearing = point_azimuth(flags)
    best = None
    cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
    for gx in range(cell[0] - 1, cell[0] + 2):
        for gy in range(cell[1] - 1, cell[1] + 2):
            for cx, cy in centres.get((gx, gy), ()):
                dx, dy = (cx - lon) * kx, (cy - lat) * 111_320
                distance = math.hypot(dx, dy)
                if distance < 3.0 or distance > TWO_WAY_STOP_REACH_METERS:
                    continue
                to_centre = math.degrees(math.atan2(dx, dy)) % 360
                for heading in (bearing, (bearing + 180) % 360):
                    off = abs((to_centre - heading + 180) % 360 - 180)
                    if off <= TWO_WAY_STOP_AXIS_DEGREES and (best is None or distance < best[0]):
                        best = (distance, heading)
    if best is None:
        return None
    angle = math.radians(best[1])
    back = -SIGNAL_STOP_SETBACK

    def at(across):
        return (lon + (math.cos(angle) * across + math.sin(angle) * back) / kx,
                lat + (-math.sin(angle) * across + math.cos(angle) * back) / 111_320)
    # От оси (с зазором под осевую) до правой кромки.
    return [at(0.3), at(width / 2)]


def road_paint(code, flags, point):
    """Краска в географических координатах, только при подтверждённой разметке.

    Стоп-линию поперёк двух направлений не рисуем: в данных нет её длины.
    """
    width = point_width(flags)
    if width <= 0:
        return
    # Стоп-линия у светофора: регулируемый подъезд размечен всегда, но длину
    # линии мы знаем только у односторонней ленты — у проспекта с раздельными
    # направлениями. Там и рисуем, за SIGNAL_STOP_SETBACK до светофора.
    if code == 1:
        if flags & PFLAG_ONEWAY:
            lon, lat = point
            angle = math.radians(point_azimuth(flags))
            back = -SIGNAL_STOP_SETBACK

            def at_signal(across):
                return (lon + (math.cos(angle) * across + math.sin(angle) * back)
                        / (111_320 * math.cos(math.radians(lat))),
                        lat + (-math.sin(angle) * across + math.cos(angle) * back) / 111_320)
            yield [at_signal(-width / 2), at_signal(width / 2)]
        return
    if code not in (3, 5) or not flags & PFLAG_PAINTED:
        return
    if code == 3 and not flags & PFLAG_ONEWAY:
        return
    lon, lat = point
    angle = math.radians(point_azimuth(flags))
    def at(across, along):
        return (lon + (math.cos(angle) * across + math.sin(angle) * along)
                / (111_320 * math.cos(math.radians(lat))),
                lat + (-math.sin(angle) * across + math.cos(angle) * along) / 111_320)
    if code == 3:
        yield [at(-width / 2, 0), at(width / 2, 0)]
    else:
        # Полосы зебры идут вдоль движения, а ряд — поперёк проезжей части.
        for index in range(max(1, int(width))):
            offset = -width / 2 + index + .5
            yield [at(offset, -1.5), at(offset, 1.5)]

# Стоп-линия у светофора — на столько метров раньше точки светофора.
SIGNAL_STOP_SETBACK = 2.0

# Разметка готовится один раз при сборке. Ограничение защищает от испорченного
# тега lanes; двусторонние дороги без lanes:forward/backward не угадываем.
MAX_MARKED_LANES = 8
JUNCTION_MARKING_MARGIN = 4.0


# Шаг проверки линии разметки против узлов и самый короткий кусок, который
# ещё читается пунктиром (штрих 4 + пробел 5 ширин линии — меньше это точка).
MARKING_CLIP_STEP_METERS = 2.0
MARKING_MIN_METERS = 8.0


class JunctionMask:
    """Площади узлов (виды 8 и 10), сквозь которые разметка полос не идёт.

    Обрезки по «степени» конца линии мало: у двойных проезжих, дублёров и
    узлов из нескольких точек OSM конец сегмента не совпадает с узлом, и
    пунктир шёл сеткой через весь перекрёсток (Мукими × Бунёдкор, 28.09.2026).
    Площадь узла — то, что на карте и есть перекрёсток; режем по ней.
    """

    CELL = 0.001   # ~100 м

    def __init__(self, polygons=()):
        self._grid = defaultdict(list)
        for ring in polygons:
            if len(ring) < 3:
                continue
            lons = [p[0] for p in ring]
            lats = [p[1] for p in ring]
            box = (min(lons), min(lats), max(lons), max(lats))
            for gx in range(int(box[0] / self.CELL), int(box[2] / self.CELL) + 1):
                for gy in range(int(box[1] / self.CELL), int(box[3] / self.CELL) + 1):
                    self._grid[(gx, gy)].append((box, ring))

    ZEBRA_CLEAR_METERS = 2.5

    def add_zebras(self, lines):
        """Полоса ±ZEBRA_CLEAR_METERS вокруг линий переходов — тоже «занято»."""
        self._zebras = defaultdict(list)
        for line in lines:
            for a, b in zip(line, line[1:]):
                for gx in range(int(min(a[0], b[0]) / self.CELL) - 1, int(max(a[0], b[0]) / self.CELL) + 2):
                    for gy in range(int(min(a[1], b[1]) / self.CELL) - 1, int(max(a[1], b[1]) / self.CELL) + 2):
                        self._zebras[(gx, gy)].append((a, b))

    def _on_zebra(self, point):
        zebras = getattr(self, "_zebras", None)
        if not zebras:
            return False
        kx = 111_320 * math.cos(math.radians(point[1]))
        for a, b in zebras.get((int(point[0] / self.CELL), int(point[1] / self.CELL)), ()):
            ax, ay = (a[0] - point[0]) * kx, (a[1] - point[1]) * 111_320
            bx, by = (b[0] - point[0]) * kx, (b[1] - point[1]) * 111_320
            dx, dy = bx - ax, by - ay
            length = dx * dx + dy * dy
            t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
            if math.hypot(ax + t * dx, ay + t * dy) <= self.ZEBRA_CLEAR_METERS:
                return True
        return False

    def covers(self, point):
        if self._on_zebra(point):
            return True
        return self._covers_area(point)

    def zebras_only(self):
        """Та же маска без площадей узлов: ряд стрелок перед стоп-линией
        законно лежит на раздутой площади узла, но не на зебре."""
        only = JunctionMask()
        only._zebras = getattr(self, "_zebras", None)
        return only

    def _covers_area(self, point):
        for box, ring in self._grid.get((int(point[0] / self.CELL), int(point[1] / self.CELL)), ()):
            if box[0] <= point[0] <= box[2] and box[1] <= point[1] <= box[3] and _inside(point, ring):
                return True
        return False

    def clip(self, line, step_meters=MARKING_CLIP_STEP_METERS):
        """Куски линии вне узлов; короче MARKING_MIN_METERS — выбрасываются."""
        if (not self._grid and not getattr(self, "_zebras", None)) or len(line) < 2:
            return [line] if len(line) >= 2 else []
        kx = 111_320 * math.cos(math.radians(line[0][1]))
        dense = [line[0]]
        for a, b in zip(line, line[1:]):
            length = math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)
            parts = max(1, int(length / step_meters))
            dense.extend((a[0] + (b[0] - a[0]) * i / parts, a[1] + (b[1] - a[1]) * i / parts)
                         for i in range(1, parts + 1))
        runs, current = [], []
        for point in dense:
            if self.covers(point):
                runs.append(current)
                current = []
            else:
                current.append(point)
        runs.append(current)
        out = []
        for run in runs:
            if len(run) < 2:
                continue
            length = sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)
                         for a, b in zip(run, run[1:]))
            if length >= MARKING_MIN_METERS:
                out.append(_simplify_straight(run))
        return out


# Пунктир прерывается в узле, где сходятся минимум две РАЗНЫЕ улицы этого
# класса и выше (tertiary); дворы и проезды его не рвут.
MARKING_BREAK_MAX_CLASS = 5


# Точки пересечения РАЗНЫХ улиц ближе этого — один перекрёсток (у двух
# проспектов с раздельными проезжими это четыре точки по углам квадрата 20–40 м).
CROSSING_CORE_METERS = 45.0


def crossing_cores(roads):
    """Ядра перекрёстков двух проспектов: оболочка точек, где сходятся улицы
    с разными именами.

    Площадь узла строится у каждой точки отдельно, а квадрат между четырьмя
    проезжими (Мукими × Бунёдкор, 28.09.2026) ничем не закрыт — пунктир шёл
    через него насквозь. Развороты и съезды одной улицы (безымянная связка или
    то же имя) в ядро не входят: иначе оно растянулось бы вдоль проспекта.
    """
    names = defaultdict(set)
    for road in roads:
        code, flags, points = road[0], road[1], road[2]
        name = road[3] if len(road) > 3 else ""
        if code > 7 or len(points) < 2 or flags & (FLAG_BRIDGE | FLAG_TUNNEL):
            continue
        for p in (points[0], points[-1]):
            key = (round(p[0], 6), round(p[1], 6))
            names[key].add(name or "")
    spots = [key for key, found in names.items() if len(found - {""}) >= 2]
    if not spots:
        return []
    # Объединение ближних точек (клетки ~100 м, сосед — в своей и соседних).
    parent = list(range(len(spots)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    cell = 0.001
    grid = defaultdict(list)
    for i, (lon, lat) in enumerate(spots):
        grid[(int(lon / cell), int(lat / cell))].append(i)
    for i, (lon, lat) in enumerate(spots):
        kx = 111_320 * math.cos(math.radians(lat))
        gx, gy = int(lon / cell), int(lat / cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((gx + dx, gy + dy), ()):
                    if j > i and math.hypot((spots[j][0] - lon) * kx,
                                            (spots[j][1] - lat) * 111_320) <= CROSSING_CORE_METERS:
                        parent[root(j)] = root(i)
    groups = defaultdict(list)
    for i, spot in enumerate(spots):
        groups[root(i)].append(spot)
    cores = []
    for members in groups.values():
        hull = _convex_hull(members)
        if len(hull) >= 3:
            cores.append(hull)
    return cores


CROSSING_AREA_REACH_METERS = 40.0


class StreetNames:
    """Имена улиц по клеткам: какие улицы проходят через фигуру."""

    CELL = 0.001
    STEP_METERS = 5.0

    def __init__(self, roads):
        self._grid = defaultdict(list)
        for road in roads:
            code, flags, points = road[0], road[1], road[2]
            name = road[3] if len(road) > 3 else ""
            if not name or code > 7 or len(points) < 2 or flags & (FLAG_BRIDGE | FLAG_TUNNEL):
                continue
            # Точки вдоль отрезков, а не одни вершины: прямая улица проходит
            # через узел без единой вершины внутри него.
            kx = 111_320 * math.cos(math.radians(points[0][1]))
            for a, b in zip(points, points[1:]):
                steps = max(1, int(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)
                                   / self.STEP_METERS))
                for i in range(steps + 1):
                    p = (a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps)
                    self._grid[(int(p[0] / self.CELL), int(p[1] / self.CELL))].append((p, name))

    def inside(self, ring):
        lons = [p[0] for p in ring]
        lats = [p[1] for p in ring]
        names = set()
        for gx in range(int(min(lons) / self.CELL), int(max(lons) / self.CELL) + 1):
            for gy in range(int(min(lats) / self.CELL), int(max(lats) / self.CELL) + 1):
                for p, name in self._grid.get((gx, gy), ()):
                    if name not in names and _inside(p, ring):
                        names.add(name)
        return names


def crossing_areas(areas, centres_of):
    """Площади узлов, чей центр рядом с ядром перекрёстка или серединой узла."""
    grid = defaultdict(list)
    for ring in centres_of:
        cx, cy = _box_centre(ring)
        grid[(int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))].append((cx, cy))
    out = []
    for ring in areas:
        cx, cy = _box_centre(ring)
        kx = 111_320 * math.cos(math.radians(cy))
        cell = (int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))
        if any(math.hypot((x - cx) * kx, (y - cy) * 111_320) <= CROSSING_AREA_REACH_METERS
               for gx in range(cell[0] - 1, cell[0] + 2) for gy in range(cell[1] - 1, cell[1] + 2)
               for x, y in grid.get((gx, gy), ())):
            out.append(ring)
    return out


def _ring_area(ring):
    kx = 111_320 * math.cos(math.radians(ring[0][1]))
    xy = [(x * kx, y * 111_320) for x, y in ring]
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))) / 2


def drop_overlapping_strips(items):
    """Убрать разделительные, чей центр внутри уже оставленной (бо́льшей).

    items — [(вид, флаги, фигура)]; линии (не разделительные) проходят как есть.
    """
    strips = [it for it in items if it[0] == AREA_MEDIAN]
    others = [it for it in items if it[0] != AREA_MEDIAN]
    kept, grid = [], defaultdict(list)
    for item in sorted(strips, key=lambda it: -_ring_area(it[2])):
        ring = item[2]
        cx, cy = _box_centre(ring)
        cell = (int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))
        covered = any(_inside((cx, cy), other) or _inside(waffle_centre(ring), other)
                      for gx in range(cell[0] - 1, cell[0] + 2)
                      for gy in range(cell[1] - 1, cell[1] + 2)
                      for other in grid.get((gx, gy), ()))
        if covered:
            continue
        kept.append(item)
        grid[cell].append(ring)
    return kept + others


BIG_JUNCTION_M2 = 600.0
STRIP_IN_JUNCTION_SHARE = 0.4


def strip_outside_junction(ring, mask):
    """Разделительная проспекта, а не обрывок внутри перекрёстка.

    Выбрасывается, если в узле её центр или больше STRIP_IN_JUNCTION_SHARE её
    площади: обрывок в зоне слияния лент лежал наполовину на площади узла,
    а проверка одного центра его пропускала (метрика medians_on_asphalt).
    """
    if mask.covers(_box_centre(ring)) and mask.covers(waffle_centre(ring)):
        return False
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    samples = inside_points(ring, 12)
    if samples and sum(mask._covers_area(p) for p in samples) / len(samples) > STRIP_IN_JUNCTION_SHARE:
        return False
    return True


def inside_points(ring, per_side):
    """До per_side² точек сетки внутри многоугольника."""
    x0, x1 = min(p[0] for p in ring), max(p[0] for p in ring)
    y0, y1 = min(p[1] for p in ring), max(p[1] for p in ring)
    out = []
    for i in range(per_side):
        for j in range(per_side):
            p = (x0 + (x1 - x0) * (i + 0.5) / per_side, y0 + (y1 - y0) * (j + 0.5) / per_side)
            if _inside(p, ring):
                out.append(p)
    return out


def _simplify_straight(run):
    """Выбросить промежуточные точки уплотнения, лежащие на прямой."""
    if len(run) <= 2:
        return run
    out = [run[0]]
    for prev, here, nxt in zip(run, run[1:], run[2:]):
        cross = (here[0] - prev[0]) * (nxt[1] - here[1]) - (here[1] - prev[1]) * (nxt[0] - here[0])
        if abs(cross) > 1e-14:
            out.append(here)
    out.append(run[-1])
    return out


# Осевая двусторонней дороги. Двусторонняя улица по определению делится на два
# направления, поэтому осевая — не догадка о полосах, а сама суть дороги; у
# Яндекса она есть везде, у нас её не было нигде: пунктир рисовался только на
# односторонних лентах с тегом lanes, а двусторонних — 72 % километров tertiary
# и 95 % жилых улиц Ташкента (замер 28.09.2026). Жилые не размечаем: узкий двор
# с осевой читается проспектом. Сплошная — на дороге с подтверждёнными четырьмя
# полосами и больше: там по ПДД разделяет сплошная; иначе — прерывистая.
CENTRE_MAX_CLASS = 5
CENTRE_MIN_WIDTH_METERS = 6.0
CENTRE_SOLID_WIDTH_METERS = 13.0
CENTRE_DASHED, CENTRE_SOLID = 1, 2


class OverlapIndex:
    """Оси лент по клеткам: лежит ли точка разметки на ЧУЖОЙ ленте того же уровня."""

    CELL = 0.0006   # ~60 м
    MARGIN_METERS = 0.3

    def __init__(self, roads, widths=None):
        widths = widths or {}
        self._grid = defaultdict(list)
        # Концы лент: продолжение той же ленты и перекрёсток сходятся с нашей
        # в общей точке — это не «чужая лента поверх», у узла разметку и так
        # режет его площадь.
        #
        # Но только продолжение (в точке сходятся ДВА конца). Где концов три и
        # больше, это узел, и съезд, вливающийся в проспект под малым углом,
        # клал свой пунктир поверх его полос паутиной (41.290, 69.301;
        # 05.10.2026). Там разметку младшей ленты режет старшая — не наоборот,
        # иначе дырка была бы в пунктире проспекта.
        self._ends = {}
        self._rank = {}
        degree = defaultdict(int)
        for road in roads:
            if len(road[2]) >= 2:
                ends = {(round(p[0], 6), round(p[1], 6)) for p in (road[2][0], road[2][-1])}
                self._ends[id(road)] = ends
                for end in ends:
                    degree[end] += 1
                width = widths.get(id(road)) or road_width_meters(road[0], lanes_of(road[1]))
                self._rank[id(road)] = (road[0], -width)
        self._junction_ends = {end for end, count in degree.items() if count >= 3}
        for road in roads:
            code, flags, points = road[0], road[1], road[2]
            if code > 7 or len(points) < 2:
                continue
            half = (widths.get(id(road)) or road_width_meters(code, lanes_of(flags))) / 2.0
            level = flags & (FLAG_BRIDGE | FLAG_TUNNEL)
            pad = (half + 2.0) / 111_320
            for a, b in zip(points, points[1:]):
                x0, x1 = sorted((a[0], b[0]))
                y0, y1 = sorted((a[1], b[1]))
                for gx in range(int((x0 - pad * 1.4) / self.CELL), int((x1 + pad * 1.4) / self.CELL) + 1):
                    for gy in range(int((y0 - pad) / self.CELL), int((y1 + pad) / self.CELL) + 1):
                        self._grid[(gx, gy)].append((id(road), level, a, b, half))

    def foreign(self, point, road):
        level = road[1] & (FLAG_BRIDGE | FLAG_TUNNEL)
        own_ends = self._ends.get(id(road), set())
        own_rank = self._rank.get(id(road))
        kx = 111_320 * math.cos(math.radians(point[1]))
        for key, lvl, a, b, half in self._grid.get((int(point[0] / self.CELL), int(point[1] / self.CELL)), ()):
            if key == id(road) or lvl != level:
                continue
            shared = own_ends & self._ends.get(key, set())
            if shared and not (shared & self._junction_ends and self._rank.get(key) < own_rank):
                continue
            ax, ay = (a[0] - point[0]) * kx, (a[1] - point[1]) * 111_320
            bx, by = (b[0] - point[0]) * kx, (b[1] - point[1]) * 111_320
            dx, dy = bx - ax, by - ay
            length = dx * dx + dy * dy
            t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
            if math.hypot(ax + t * dx, ay + t * dy) < half - self.MARGIN_METERS:
                return True
        return False

    def clip(self, line, road, step_meters=MARKING_CLIP_STEP_METERS):
        """Куски линии вне чужих лент; короче MARKING_MIN_METERS — выбрасываются."""
        if len(line) < 2:
            return []
        kx = 111_320 * math.cos(math.radians(line[0][1]))
        dense = [line[0]]
        for a, b in zip(line, line[1:]):
            length = math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)
            parts = max(1, int(length / step_meters))
            dense.extend((a[0] + (b[0] - a[0]) * i / parts, a[1] + (b[1] - a[1]) * i / parts)
                         for i in range(1, parts + 1))
        flags = [self.foreign(p, road) for p in dense]
        if not any(flags):
            return [line]
        runs, current = [], []
        for point, bad in zip(dense, flags):
            if bad:
                runs.append(current)
                current = []
            else:
                current.append(point)
        runs.append(current)
        out = []
        for run in runs:
            if len(run) < 2:
                continue
            length = sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320) for a, b in zip(run, run[1:]))
            if length >= MARKING_MIN_METERS:
                out.append(_simplify_straight(run))
        return out


def _markings(roads, widths=None, mask=None):
    """(линия, осевая: 0 / CENTRE_DASHED / CENTRE_SOLID) вне перекрёстков.

    Вход — сеть ПОСЛЕ generalise: общие узлы уже стали концами сегментов.
    Считаем только концы, не заводим второй индекс всех вершин страны.
    Мосты и тоннели не смешиваются с наземными перекрёстками.
    """
    def key(point, flags):
        return (round(point[0], 6), round(point[1], 6),
                flags & (FLAG_BRIDGE | FLAG_TUNNEL))

    # Узел: [степень, ширина самой широкой, имена улиц tertiary+].
    nodes = defaultdict(lambda: [0, 0.0, set()])
    for road in roads:
        code, flags, points = road[0], road[1], road[2]
        if len(points) < 2 or code > 7:
            continue
        width = road_width_meters(code, lanes_of(flags))
        name = (road[3] if len(road) > 3 else "") or ""
        for p in (points[0], points[-1]):
            node = nodes[key(p, flags)]
            node[0] += 1
            node[1] = max(node[1], width)
            if code <= MARKING_BREAK_MAX_CLASS:
                node[2].add(name or id(road))

    def trim(points, distance):
        result = list(points)
        while len(result) > 1 and distance > 0:
            a, b = result[:2]
            length = math.dist(a, b)
            if length > distance:
                t = distance / length
                result[0] = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
                break
            distance -= length
            result.pop(0)
        return result

    overlap = OverlapIndex(roads, widths)
    for road in roads:
        code, flags, points = road[0], road[1], road[2]
        # В тоннеле разметку не рисуем: он под землёй и показан полупрозрачным,
        # пунктир поверх читался бы наземной дорогой.
        if code > 7 or len(points) < 2 or flags & FLAG_TUNNEL:
            continue
        lanes = lanes_of(flags)
        confirmed = flags & FLAG_LANES_TAGGED and 2 <= lanes <= MAX_MARKED_LANES
        # Угаданные полосы (lane_inference) — тоже пунктир: 97,5 % угадано на
        # спрятанных. Но не сплошная осевая: она запрещает поворот, и по
        # догадке её не рисуем.
        tagged = (flags & (FLAG_LANES_TAGGED | FLAG_LANES_INFERRED)
                  and 2 <= lanes <= MAX_MARKED_LANES)
        # Ширина — та же, по которой нарисовано полотно: сужение под
        # разделительную (fit_carriageways) иначе уводило пунктир на неё.
        width = road_width_meters(code, lanes)
        if widths:
            width = min(width, widths.get(id(road)) or width)
        offsets = []
        if flags & FLAG_ONEWAY:
            if tagged:
                offsets = [(width * (lane / lanes - .5), 0) for lane in range(1, lanes)]
        elif code <= CENTRE_MAX_CLASS and width >= CENTRE_MIN_WIDTH_METERS:
            # Сплошная — только по ПОДТВЕРЖДЁННЫМ полосам: ширина без тега
            # lanes — догадка по классу (у tertiary 14 м), и сплошная по
            # догадке запрещала бы на карте поворот, разрешённый в жизни.
            wide = confirmed and lanes >= 4 and width >= CENTRE_SOLID_WIDTH_METERS
            centre = CENTRE_SOLID if wide else CENTRE_DASHED
            offsets = [(0.0, centre)]
            # Полосы по сторонам — только при чётном lanes: делим поровну, а
            # нечётное число (средняя реверсивная?) не угадываем.
            if tagged and lanes >= 4 and lanes % 2 == 0:
                offsets += [(width * (lane / lanes - .5), 0)
                            for lane in range(1, lanes) if lane * 2 != lanes]
        if not offsets:
            continue
        origin = points[0]
        sx, sy = 111_320 * math.cos(math.radians(origin[1])), 111_320
        metric = [((p[0] - origin[0]) * sx, (p[1] - origin[1]) * sy) for p in points]
        at_crossing = []
        for endpoint in (points[0], points[-1]):
            degree, node_width, streets = nodes[key(endpoint, flags)]
            # Рвём пунктир только на перекрёстке улиц: двор или проезд,
            # примкнувший к проспекту, его не прерывает — как у Яндекса.
            # Раньше рвал каждый, и от Беруни оставались обрывки (05.10.2026).
            crossing = degree >= 3 and len(streets) >= 2
            at_crossing.append(crossing)
            metric = trim(metric, node_width / 2 + JUNCTION_MARKING_MARGIN if crossing else 0)
            metric.reverse()
        if len(metric) < 2:
            continue
        for offset, centre in offsets:
            line = []
            for i, p in enumerate(metric):
                a, b = metric[max(0, i - 1)], metric[min(len(metric) - 1, i + 1)]
                length = math.dist(a, b)
                if length == 0:
                    continue
                x, y = p[0] - (b[1] - a[1]) / length * offset, p[1] + (b[0] - a[0]) / length * offset
                line.append((origin[0] + x / sx, origin[1] + y / sy))
            if len(line) < 2:
                continue
            # Перед перекрёстком улиц — сплошная: у односторонней ленты на
            # подходе (её конец по ходу), у осевой двусторонней — с обоих
            # концов. Так размечен подход в жизни и у Яндекса (снимок
            # 05.10.2026); двор и примыкание ничего не меняют.
            ends = ((False, at_crossing[1]) if flags & FLAG_ONEWAY and not centre
                    else (at_crossing[0], at_crossing[1]) if centre
                    else (False, False))
            for part, solid in split_approaches(line, ends):
                kind = (CENTRE_SOLID if solid else centre) if centre else 0
                # Мост и тоннель идут над/под узлом земли — его площадь им не указ.
                if mask is not None and not flags & (FLAG_BRIDGE | FLAG_TUNNEL):
                    pieces = mask.clip(part)
                else:
                    pieces = [part]
                # Пунктир не ложится на чужую ленту: там, где пандус вливается
                # в проспект, разметка двух лент шла сеткой (Фурката, 05.10.2026).
                on_bridge = bool(flags & FLAG_BRIDGE)
                for piece in pieces:
                    for clean in overlap.clip(piece, road):
                        yield clean, kind, solid, on_bridge


# Сплошная перед перекрёстком: столько метров до края узла.
APPROACH_SOLID_METERS = 25.0


def split_approaches(line, ends):
    """[(кусок, сплошной?)]: от начала/конца, отмеченных в ends, отрезается
    APPROACH_SOLID_METERS сплошной; остальное — как было."""
    if not any(ends) or len(line) < 2:
        return [(line, False)]
    kx = 111_320 * math.cos(math.radians(line[0][1]))
    lengths = [math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320) for a, b in zip(line, line[1:])]
    total = sum(lengths)
    head = APPROACH_SOLID_METERS if ends[0] else 0.0
    tail = APPROACH_SOLID_METERS if ends[1] else 0.0
    if head + tail >= total:
        return [(line, True)]

    def cut(at):
        travelled = 0.0
        for (a, b), piece in zip(zip(line, line[1:]), lengths):
            if piece > 0 and travelled + piece >= at:
                t = (at - travelled) / piece
                return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            travelled += piece
        return line[-1]

    def between(start, end):
        out = [cut(start)]
        travelled = 0.0
        for point, piece in zip(line[1:], lengths):
            travelled += piece
            if start < travelled < end:
                out.append(point)
        out.append(cut(end))
        return out

    parts = []
    if head:
        parts.append((between(0.0, head), True))
    parts.append((between(head, total - tail), False))
    if tail:
        parts.append((between(total - tail, total), True))
    return [(p, solid) for p, solid in parts if len(p) >= 2]


def lane_markings(roads, widths=None, mask=None):
    """Разделители полос (без осевых) вне перекрёстков."""
    for line, centre, _solid, _bridge in _markings(roads, widths, mask):
        if not centre:
            yield line


def centre_lines(roads, widths=None, mask=None):
    """Осевые двусторонних дорог: (линия, CENTRE_DASHED | CENTRE_SOLID)."""
    for line, centre, _solid, _bridge in _markings(roads, widths, mask):
        if centre:
            yield line, centre

# Кому какой зум. Слой, невидимый на обзоре, туда и не едет — тот же закон,
# по которому телефон не качает дворовые проезды на охвате района.
#
# Местность и места на обзоре появились 27.09.2026: до того ниже 14.6 карта
# была сетью линий без единого ориентира. Местность туда идёт отдельным,
# огрублённым списком (build_roads.build_far_areas), а не подробными полигонами.
FAR_LAYERS = {LAYER_ROADS, LAYER_LAND, LAYER_PLACES}

# Какие места подписывать на обзоре: города, посёлки, кишлаки и районы
# города. Хутор и квартал на охвате в двадцать километров — шум поверх
# названий, ради которых обзор и смотрят.
FAR_PLACE_RANKS = {1, 2, 3, 5}


STUB_WIDTHS = 1.5


def _length_m(points):
    total = 0.0
    for (lon1, lat1), (lon2, lat2) in zip(points, points[1:]):
        kx = 111_320 * math.cos(math.radians((lat1 + lat2) / 2))
        total += math.hypot((lon2 - lon1) * kx, (lat2 - lat1) * 111_320)
    return total


def _road_props(road, width=None):
    """`width` — ширина всей непрерывной ленты (build_roads.street_chains).

    Своя ширина куска давала на карте ступеньки: соседние куски одной улицы
    бывают с полосами из тега и без, и линия скачет на пару метров ровно на
    стыке. Полотно (набор d) давно считается «одна ширина на ленту» — линии
    теперь по тому же правилу, и край проспекта ровный.
    """
    code, flags = road[0], road[1]
    name = road[3] if len(road) > 3 else ""
    lanes = lanes_of(flags)
    if width is None:
        width = road_width_meters(code, lanes)
    props = {"cls": code, "width": round(width, 1)}
    # Кусок короче полутора своих ширин — скруглённый конец превращает его в
    # «шар» шире соседей (Олмазор у Пахтакора: 17 м между двумя развилками).
    # Такой кусок стиль рисует с прямыми концами.
    if _length_m(road[2]) < STUB_WIDTHS * width:
        props["stub"] = True
    if name:
        props["name"] = name
    if flags & FLAG_ONEWAY:
        props["oneway"] = True
    if flags & FLAG_BRIDGE:
        props["bridge"] = True
    if flags & FLAG_TUNNEL:
        props["tunnel"] = True
    if flags & FLAG_LANES_TAGGED:
        props["lanes"] = lanes
        props["measured"] = True
    return props


def place_properties(place):
    """(ранг, биты, [(lon, lat)], имя) из build_roads.collect_places → свойства.

    None — записи не место: без имени подписывать нечем, без точки — негде.
    """
    rank, _flags, spots, name = place[0], place[1], place[2], place[3]
    name = (name or "").strip()
    if not name or not spots or rank not in range(1, 7):
        return None
    return {"name": name, "rank": rank}


# Зебра линией перехода (OSM footway=crossing) — в слое paint, вид 12. Узловую
# зебру (вид 5) ближе этого к линии перехода не рисуем: это тот же переход.
KIND_ZEBRA_WAY = 12
ZEBRA_WAY_NEAR_METERS = 10.0
# Узел перехода «лежит на линии», если совпадает с её вершиной с точностью до
# посадки на ось (точки садятся на нарисованную ось — сдвиг до пары метров).
NODE_ON_WAY_METERS = 4.0


# Зебра — по ПОДХОДУ, а не по линии OSM. Линию перехода в OSM рисуют от
# бордюра до бордюра как придётся: наискось через середину узла, ломаной
# через островок, двумя кусками на одном подходе. Нарисованная как есть, она
# давала «ромб» зебр посреди Чорсу, зебры за кромкой и по две на подход
# (06.10.2026). Теперь линия OSM только говорит, ГДЕ переход: в точке, где она
# пересекает ось проезжей, зебра встаёт строго поперёк этой оси, длиной в
# ширину полотна. Через двойную проезжую — две зебры, с разрывом на
# разделительной, как в жизни.
ZEBRA_EDGE_INSET_METERS = 0.3
ZEBRA_SAME_APPROACH_METERS = 8.0
ZEBRA_REACH_METERS = 1.5        # линия OSM, не дотянутая до оси на столько, всё ещё её пересекает
ZEBRA_ROAD_MAX_CODE = 7


class ZebraFitter:
    """Оси проезжих по клеткам: где линия перехода их пересекает."""

    CELL = 0.0005   # ~50 м

    def __init__(self, roads, widths=None):
        widths = widths or {}
        self._grid = defaultdict(list)
        for road in roads:
            code, flags, points = road[0], road[1], road[2]
            if code > ZEBRA_ROAD_MAX_CODE or len(points) < 2 or flags & (FLAG_BRIDGE | FLAG_TUNNEL):
                continue
            half = (widths.get(id(road)) or road_width_meters(code, lanes_of(flags))) / 2.0
            for a, b in zip(points, points[1:]):
                for gx in range(int(min(a[0], b[0]) / self.CELL) - 1, int(max(a[0], b[0]) / self.CELL) + 2):
                    for gy in range(int(min(a[1], b[1]) / self.CELL) - 1, int(max(a[1], b[1]) / self.CELL) + 2):
                        self._grid[(gx, gy)].append((id(road), a, b, half))

    def hits(self, a, b):
        """[(id дороги, точка пересечения, азимут оси в радианах, полуширина, синус угла)]."""
        lat0 = (a[1] + b[1]) / 2
        kx = 111_320 * math.cos(math.radians(lat0))

        def xy(p):
            return ((p[0] - a[0]) * kx, (p[1] - a[1]) * 111_320)

        bx, by = xy(b)
        length = math.hypot(bx, by)
        if length <= 0:
            return []
        reach = ZEBRA_REACH_METERS / length
        seen, out = set(), []
        cells = {(gx, gy)
                 for gx in range(int(min(a[0], b[0]) / self.CELL), int(max(a[0], b[0]) / self.CELL) + 1)
                 for gy in range(int(min(a[1], b[1]) / self.CELL), int(max(a[1], b[1]) / self.CELL) + 1)}
        for cell in sorted(cells):
            for key, p, q, half in self._grid.get(cell, ()):
                mark = (key, p[0], p[1], q[0], q[1])
                if mark in seen:
                    continue
                seen.add(mark)
                px, py = xy(p)
                qx, qy = xy(q)
                rx, ry = qx - px, qy - py
                denom = bx * ry - by * rx
                if abs(denom) < 1e-9:
                    continue
                t = (px * ry - py * rx) / denom          # вдоль перехода
                u = (px * by - py * bx) / denom          # вдоль оси дороги
                if not (-reach <= t <= 1 + reach and 0.0 <= u <= 1.0):
                    continue
                road_len = math.hypot(rx, ry)
                sine = abs(denom) / (length * road_len)
                point = (a[0] + bx * t / kx, a[1] + by * t / 111_320)
                out.append((key, point, math.atan2(rx, ry), half, sine))
        return out


# Стоп-линия — от той же оси, что и зебра. Светофор в OSM стоит где придётся
# (на тротуаре, на островке, посреди узла), и линия по его азимуту и ширине
# записи выходила косой, через островок и за кромку (Чорсу, 06.10.2026).
# Теперь она строго поперёк своей проезжей, по её полотну, и если впереди по
# ходу есть зебра, — за STOP_BEFORE_ZEBRA_METERS до её ближнего края.
STOP_AXIS_REACH_METERS = 8.0
STOP_AXIS_DEGREES = 40.0
ZEBRA_DEPTH_METERS = 3.0
STOP_BEFORE_ZEBRA_METERS = 1.5
STOP_ZEBRA_BEHIND_METERS = 8.0
STOP_ZEBRA_AHEAD_METERS = 12.0


def _nearest_axis(fitter, point, bearing):
    """(точка на оси, азимут хода в радианах, полуширина) ближайшей попутной оси."""
    kx = 111_320 * math.cos(math.radians(point[1]))
    cell = (int(point[0] / fitter.CELL), int(point[1] / fitter.CELL))
    best = None
    for gx in range(cell[0] - 1, cell[0] + 2):
        for gy in range(cell[1] - 1, cell[1] + 2):
            for _key, a, b, half in fitter._grid.get((gx, gy), ()):
                ax, ay = (a[0] - point[0]) * kx, (a[1] - point[1]) * 111_320
                bx, by = (b[0] - point[0]) * kx, (b[1] - point[1]) * 111_320
                dx, dy = bx - ax, by - ay
                length = dx * dx + dy * dy
                if length == 0:
                    continue
                heading = math.degrees(math.atan2(dx, dy)) % 360
                off = abs((heading - bearing + 180) % 360 - 180)
                if off > 90:
                    heading = (heading + 180) % 360
                    off = 180 - off
                if off > STOP_AXIS_DEGREES:
                    continue
                t = max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
                fx, fy = ax + t * dx, ay + t * dy
                distance = math.hypot(fx, fy)
                # Светофор стоит у кромки или на тротуаре: до оси широкой ленты
                # от него больше полуширины.
                if distance > max(STOP_AXIS_REACH_METERS, half + 3.0) or (best and best[0] <= distance):
                    continue
                best = (distance, (point[0] + fx / kx, point[1] + fy / 111_320),
                        math.radians(heading), half)
    return best[1:] if best else None


def fit_stop_line(line, bearing, fitter, zebra_centres, two_way=False):
    """Стоп-линия поперёк своей оси и перед зеброй; не нашлась ось — None (не рисуем:
    линия по одному азимуту светофора и выходила косой через узел)."""
    centre = ((line[0][0] + line[-1][0]) / 2, (line[0][1] + line[-1][1]) / 2)
    axis = _nearest_axis(fitter, centre, bearing)
    if axis is None:
        return None
    (lon, lat), heading, half = axis
    kx = 111_320 * math.cos(math.radians(lat))
    fx, fy = math.sin(heading), math.cos(heading)          # по ходу
    rx, ry = math.cos(heading), -math.sin(heading)          # вправо
    best = None
    cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
    for gx in range(cell[0] - 1, cell[0] + 2):
        for gy in range(cell[1] - 1, cell[1] + 2):
            for zx, zy in zebra_centres.get((gx, gy), ()):
                dx, dy = (zx - lon) * kx, (zy - lat) * 111_320
                along = dx * fx + dy * fy
                lateral = abs(dx * rx + dy * ry)
                if (-STOP_ZEBRA_BEHIND_METERS < along < STOP_ZEBRA_AHEAD_METERS
                        and lateral <= half + 1.0 and (best is None or along < best)):
                    best = along
    shift = 0.0
    if best is not None:
        shift = best - ZEBRA_DEPTH_METERS / 2 - STOP_BEFORE_ZEBRA_METERS
    reach = max(1.0, half - ZEBRA_EDGE_INSET_METERS)
    start = ZEBRA_EDGE_INSET_METERS if two_way else -reach

    def at(across):
        return (lon + (fx * shift + rx * across) / kx, lat + (fy * shift + ry * across) / 111_320)
    return [at(start), at(reach)]


def _line_bearing(line, flags):
    """Ход у стоп-линии двусторонней дороги: линия идёт от оси вправо по ходу."""
    a, b = line[0], line[-1]
    kx = 111_320 * math.cos(math.radians(a[1]))
    across = math.degrees(math.atan2((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320))
    return (across - 90) % 360


class StopIndex:
    """Стоп-линии по клеткам: где впереди по ходу стоп-линия своего подхода."""

    def __init__(self, lines):
        self._grid = defaultdict(list)
        for line in lines:
            cx, cy = (line[0][0] + line[-1][0]) / 2, (line[0][1] + line[-1][1]) / 2
            self._grid[(int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))].append(line)

    def ahead(self, point, bearing, width):
        """Метров по ходу до стоп-линии своего подхода (отрицательное — позади), или None.

        Точка turn:lanes в OSM обычно стоит в самом узле, уже за стоп-линией
        своего подхода. Поэтому первой ищется ближайшая линия ПОЗАДИ точки, и
        только если её нет — впереди: иначе ловилась стоп-линия встречного
        подхода через перекрёсток, и ряд уезжал в его середину (06.10.2026).
        """
        lon, lat = point
        kx = 111_320 * math.cos(math.radians(lat))
        fx, fy = math.sin(math.radians(bearing)), math.cos(math.radians(bearing))
        behind = ahead = None
        cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
        for gx in range(cell[0] - 1, cell[0] + 2):
            for gy in range(cell[1] - 1, cell[1] + 2):
                for a, b in self._grid.get((gx, gy), ()):
                    ax, ay = (a[0] - lon) * kx, (a[1] - lat) * 111_320
                    bx, by = (b[0] - lon) * kx, (b[1] - lat) * 111_320
                    # Линия поперёк хода: её направление почти перпендикулярно.
                    lx, ly = bx - ax, by - ay
                    length = math.hypot(lx, ly)
                    if length == 0 or abs(lx * fx + ly * fy) / length > 0.5:
                        continue
                    along = ((ax + bx) / 2) * fx + ((ay + by) / 2) * fy
                    if not -ARROW_STOP_BEHIND_METERS <= along <= ARROW_STOP_REACH_METERS:
                        continue
                    # Ось ряда пересекает линию (с запасом на ширину ряда).
                    la = ax * fy - ay * fx
                    lb = bx * fy - by * fx
                    if min(la, lb) > width / 2 + 1.0 or max(la, lb) < -width / 2 - 1.0:
                        continue
                    if along <= ARROW_STOP_SAME_POINT_METERS:
                        if behind is None or along > behind:
                            behind = along
                    elif ahead is None or along < ahead:
                        ahead = along
        return behind if behind is not None else ahead


ARROW_STOP_REACH_METERS = 60.0
ARROW_STOP_BEHIND_METERS = 40.0
ARROW_STOP_SAME_POINT_METERS = 3.0


TREE_SIZES = 4


def tree_size(point):
    """Класс размера кроны 0…3 — от координаты, одинаково при каждой сборке."""
    key = int(round(point[0] * 1e6)) * 73_856_093 ^ int(round(point[1] * 1e6)) * 19_349_663
    return key % TREE_SIZES


def node_zebra_line(flags, point):
    """Поперечная линия зебры-узла — по его азимуту и ширине (как road_paint)."""
    lon, lat = point
    width = point_width(flags)
    angle = math.radians(point_azimuth(flags))
    kx = 111_320 * math.cos(math.radians(lat))
    return [(lon - math.cos(angle) * width / 2 / kx, lat + math.sin(angle) * width / 2 / 111_320),
            (lon + math.cos(angle) * width / 2 / kx, lat - math.sin(angle) * width / 2 / 111_320)]


TREE_CROWN_RADII = (1.9, 2.3, 2.7, 3.1)
TREE_CROWN_SIDES = 10


def tree_crown(point, size, share=1.0, radius=None, sides=TREE_CROWN_SIDES):
    """Кольцо вокруг точки дерева: радиус кроны по классу размера (× share), метры."""
    lon, lat = point
    if radius is None:
        radius = TREE_CROWN_RADII[size % len(TREE_CROWN_RADII)] * share
    kx = 111_320 * math.cos(math.radians(lat))
    ring = [(lon + radius * math.cos(2 * math.pi * i / sides) / kx,
             lat + radius * math.sin(2 * math.pi * i / sides) / 111_320)
            for i in range(sides)]
    return ring + ring[:1]


TREE_TRUNK_METERS = 2.2
TREE_TRUNK_RADIUS = 0.25
TREE_CROWN_HEIGHTS = (4.5, 5.5, 6.5, 7.5)
# Ярус кроны: (доля радиуса, низ и верх в долях высоты кроны).
TREE_TIERS = ((0.72, 0.0, 0.22), (1.0, 0.22, 0.62), (0.78, 0.62, 0.84), (0.42, 0.84, 1.0))


def tree_tiers(point, size):
    """[(кольцо, свойства)] — ствол и ярусы кроны с высотами в метрах."""
    crown = TREE_CROWN_HEIGHTS[size % len(TREE_CROWN_HEIGHTS)]
    out = [(tree_crown(point, size, radius=TREE_TRUNK_RADIUS, sides=6),
            {"crown": True, "trunk": True, "base": 0.0, "top": TREE_TRUNK_METERS + 0.3})]
    for share, low, high in TREE_TIERS:
        out.append((tree_crown(point, size, share),
                    {"crown": True, "base": round(TREE_TRUNK_METERS + low * crown, 2),
                     "top": round(TREE_TRUNK_METERS + high * crown, 2)}))
    return out


def zebra_centre_grid(zebras):
    grid = defaultdict(list)
    for line, _marked in zebras:
        cx, cy = (line[0][0] + line[-1][0]) / 2, (line[0][1] + line[-1][1]) / 2
        grid[(int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))].append((cx, cy))
    return grid


def fit_zebras(crossings, fitter):
    """Зебры поперёк проезжих: [((точка, точка), размечена ли)]."""
    candidates = []
    for group, (line, marked) in enumerate(crossings):
        for a, b in zip(line, line[1:]):
            for key, point, heading, half, sine in fitter.hits(a, b):
                candidates.append((key, point, heading, half, sine, bool(marked), group))
    # На одном подходе один переход: размеченный и самый поперечный — первым.
    candidates.sort(key=lambda c: (not c[5], -c[4], c[1][0], c[1][1]))
    # Переход через двойную проезжую — одна полоса зебры: куски одной линии
    # OSM на параллельных лентах выстраиваются поперёк первой. Наискосок
    # проведённая линия давала две зебры со сдвигом, и двойная жёлтая шла
    # между ними насквозь (Беруни у Чорсу, 06.10.2026).
    anchors = {}
    aligned = []
    for key, point, heading, half, sine, marked, group in candidates:
        anchor = anchors.get(group)
        if anchor is None:
            anchors[group] = (point, heading)
        elif abs(math.sin(heading - anchor[1])) < ZEBRA_PARALLEL_SINE:
            kx = 111_320 * math.cos(math.radians(point[1]))
            fx, fy = math.sin(heading), math.cos(heading)
            shift = (anchor[0][0] - point[0]) * kx * fx + (anchor[0][1] - point[1]) * 111_320 * fy
            point = (point[0] + fx * shift / kx, point[1] + fy * shift / 111_320)
        aligned.append((key, point, heading, half, sine, marked))
    kept = []
    for key, point, heading, half, sine, marked in aligned:
        kx = 111_320 * math.cos(math.radians(point[1]))
        if any(other[0] == key and math.hypot((other[1][0] - point[0]) * kx,
                                              (other[1][1] - point[1]) * 111_320) < ZEBRA_SAME_APPROACH_METERS
               for other in kept):
            continue
        # Наложенные ленты (поворотная полоса поверх проспекта, связка внутри
        # узла) пересекаются той же линией в одном месте: зебра, чей центр
        # лежит на теле уже поставленной, — дубль (11 % зебр Ташкента).
        line = _zebra_line(point, heading, half)
        if any(_point_segment_m(point, other[6][0], other[6][1]) < ZEBRA_BODY_CLEAR_METERS
               or _point_segment_m(other[1], line[0], line[1]) < ZEBRA_BODY_CLEAR_METERS
               for other in kept):
            continue
        kept.append((key, point, heading, half, sine, marked, line))
    return [(other[6], other[5]) for other in kept]


ZEBRA_BODY_CLEAR_METERS = 3.0
ZEBRA_PARALLEL_SINE = 0.26      # ленты параллельны в пределах 15°


def _zebra_line(point, heading, half):
    """Отрезок поперёк оси (азимут + 90°) длиной в полотно без отступа у кромок."""
    reach = max(1.0, half - ZEBRA_EDGE_INSET_METERS)
    kx = 111_320 * math.cos(math.radians(point[1]))
    dx, dy = math.cos(heading), -math.sin(heading)
    return [(point[0] - dx * reach / kx, point[1] - dy * reach / 111_320),
            (point[0] + dx * reach / kx, point[1] + dy * reach / 111_320)]


def _point_segment_m(p, a, b):
    kx = 111_320 * math.cos(math.radians(p[1]))
    ax, ay = (a[0] - p[0]) * kx, (a[1] - p[1]) * 111_320
    bx, by = (b[0] - p[0]) * kx, (b[1] - p[1]) * 111_320
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
    return math.hypot(ax + t * dx, ay + t * dy)


def _near_crossing_way(point, grid, reach=ZEBRA_WAY_NEAR_METERS):
    lon, lat = point
    kx = 111_320 * math.cos(math.radians(lat))
    cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for x, y in grid.get((cell[0] + dx, cell[1] + dy), ()):
                if math.hypot((x - lon) * kx, (y - lat) * 111_320) <= reach:
                    return True
    return False


# «Вафля» регулируемого перекрёстка — как у Яндекса: зона пересечения между
# стоп-линиями. Её очерчивают сами светофоры подходов (в OSM они стоят у
# стоп-линий), поэтому зона — выпуклая оболочка светофоров вокруг центра
# перекрёстка (вид 10), стянутая к центру, чтобы не наезжать на зебры.
KIND_WAFFLE = 11
WAFFLE_SIGNAL_REACH_METERS = 60.0
WAFFLE_MIN_SIGNALS = 3
WAFFLE_SHRINK = 0.75
# Светофор принадлежит перекрёстку, если его подход ведёт В центр: направление
# движения (азимут точки) отличается от направления на центр не больше чем на
# столько. Светофоры эстакады и боковых съездов смотрят мимо — их отсекает
# это, а не радиус (45 м терял настоящие светофоры Навои × Рашидов в 42–52 м).
WAFFLE_FACING_DEGREES = 40.0
# Зона перекрёстка — почти квадрат или ромб. Вытянутый треугольник (Навои ×
# Фурката, 28.09.2026: светофоры эстакады и съездов) — не перекрёсток, а
# случайная выборка светофоров; такую «вафлю» не рисуем.
WAFFLE_MIN_COMPACTNESS = 0.4
_SIGNAL_CELL = 0.002   # ~200 м


def _signal_grid(points):
    """Светофоры по клеткам: (lon, lat, азимут подхода или None)."""
    grid = defaultdict(list)
    for point in points:
        if point[0] == 1:
            lon, lat = point[2][0]
            bearing = point_azimuth(point[1]) if point_width(point[1]) > 0 else None
            grid[(int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))].append((lon, lat, bearing))
    return grid


def _faces(lon, lat, bearing, cx, cy):
    """Ведёт ли подход светофора в центр перекрёстка (азимут неизвестен — да)."""
    if bearing is None:
        return True
    kx = 111_320 * math.cos(math.radians(lat))
    to_centre = math.degrees(math.atan2((cx - lon) * kx, (cy - lat) * 111_320)) % 360
    # Ось, а не направление: у двусторонней дороги азимут точки идёт по
    # направлению линии в OSM и может смотреть «от» центра.
    diff = abs((bearing - to_centre + 180) % 360 - 180)
    return min(diff, 180 - diff) <= WAFFLE_FACING_DEGREES


def _convex_hull(points):
    """Выпуклая оболочка (монотонная цепь Эндрю)."""
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


def _box_centre(box):
    return (sum(p[0] for p in box) / len(box), sum(p[1] for p in box) / len(box))


def box_centres(boxes):
    """Центры перекрёстков (вид 10) по клеткам — для «чей это светофор»."""
    grid = defaultdict(list)
    for box in boxes:
        cx, cy = _box_centre(box)
        grid[(int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))].append((cx, cy))
    return grid


# Светофор чужой, только если другой центр ближе заметно: центры одного узла
# из соседних тайлов стоят в метре друг от друга.
WAFFLE_OWNER_MARGIN_METERS = 3.0


def _owned_by(lon, lat, cx, cy, centres):
    """Светофор принадлежит ближайшему центру перекрёстка.

    Бунёдкор × Сеул (28.09.2026): в 60 м от центра стоят светофоры дублёра и
    соседнего узла за каналом — оболочка по ним легла на воду. Каждый светофор
    отдаётся одному, ближайшему узлу (разбиение Вороного), и чужие зону не тянут.
    Без сетки центров — ничего не отсекаем.
    """
    if not centres:
        return True
    kx = 111_320 * math.cos(math.radians(lat))
    own = math.hypot((cx - lon) * kx, (cy - lat) * 111_320)
    cell = (int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))
    for gx in range(cell[0] - 1, cell[0] + 2):
        for gy in range(cell[1] - 1, cell[1] + 2):
            for x, y in centres.get((gx, gy), ()):
                # Центр того же перекрёстка (середина узла и ядро пересечения
                # лежат рядом) светофор не отбирает: иначе четыре светофора
                # Беруни × Сакичмон расходились по трём центрам, и ни у одного
                # не набиралось трёх (05.10.2026).
                if math.hypot((x - cx) * kx, (y - cy) * 111_320) <= SAME_JUNCTION_METERS:
                    continue
                if math.hypot((x - lon) * kx, (y - lat) * 111_320) < own - WAFFLE_OWNER_MARGIN_METERS:
                    return False
    return True


# Два центра ближе этого — один перекрёсток (как JUNCTION_CLUSTER_METERS сборки).
SAME_JUNCTION_METERS = 35.0


def _junction_signals(box, grid, centres=None):
    """Светофоры подходов этого перекрёстка: [(lon, lat)]."""
    cx, cy = _box_centre(box)
    kx = 111_320 * math.cos(math.radians(cy))
    reach_lat = WAFFLE_SIGNAL_REACH_METERS / 111_320
    reach_lon = WAFFLE_SIGNAL_REACH_METERS / kx
    near = []
    for gx in range(int((cx - reach_lon) / _SIGNAL_CELL), int((cx + reach_lon) / _SIGNAL_CELL) + 1):
        for gy in range(int((cy - reach_lat) / _SIGNAL_CELL), int((cy + reach_lat) / _SIGNAL_CELL) + 1):
            for lon, lat, bearing in grid.get((gx, gy), ()):
                if math.hypot((lon - cx) * kx, (lat - cy) * 111_320) <= WAFFLE_SIGNAL_REACH_METERS \
                        and _faces(lon, lat, bearing, cx, cy) \
                        and _owned_by(lon, lat, cx, cy, centres):
                    near.append((lon, lat))
    return near


# Светофоры как у Яндекса (снимок владельца 05.10.2026, Беруни × Сакичмон):
# не жёлтая сетка и не один значок, а по светофору на каждый ПОДХОД — ромбом
# вокруг центра перекрёстка, со стороны, откуда этот подход приходит.
# Подходы — светофоры, сгруппированные по направлению из центра; значок —
# на доле расстояния до них, но не дальше LIGHT_MAX_METERS: иначе на широком
# перекрёстке он уезжал бы на зебру.
KIND_APPROACH_LIGHT = 14
LIGHT_APPROACH_DEGREES = 35.0
LIGHT_SHARE = 0.35
LIGHT_MIN_METERS = 5.0
LIGHT_MAX_METERS = 14.0


def approach_lights(zone, signals):
    """Точки значков светофоров, по одной на подход: [(lon, lat)]."""
    cx, cy = waffle_centre(zone)
    kx = 111_320 * math.cos(math.radians(cy))
    rays = []
    for lon, lat in signals:
        dx, dy = (lon - cx) * kx, (lat - cy) * 111_320
        distance = math.hypot(dx, dy)
        if distance > 1.0:
            rays.append((math.degrees(math.atan2(dx, dy)) % 360, dx / distance, dy / distance, distance))
    groups = []
    for ray in sorted(rays):
        for group in groups:
            mean = math.degrees(math.atan2(sum(r[1] for r in group), sum(r[2] for r in group))) % 360
            if abs((ray[0] - mean + 180) % 360 - 180) <= LIGHT_APPROACH_DEGREES:
                group.append(ray)
                break
        else:
            groups.append([ray])
    out = []
    for group in groups:
        ux, uy = sum(r[1] for r in group), sum(r[2] for r in group)
        norm = math.hypot(ux, uy) or 1.0
        reach = sum(r[3] for r in group) / len(group) * LIGHT_SHARE
        reach = max(LIGHT_MIN_METERS, min(LIGHT_MAX_METERS, reach))
        out.append((cx + ux / norm * reach / kx, cy + uy / norm * reach / 111_320))
    return out


def waffle_zone(box, grid, centres=None):
    """Зона регулируемого перекрёстка (между светофорами подходов) или None."""
    if not grid:
        return None
    cx, cy = _box_centre(box)
    kx = 111_320 * math.cos(math.radians(cy))
    reach_lat = WAFFLE_SIGNAL_REACH_METERS / 111_320
    reach_lon = WAFFLE_SIGNAL_REACH_METERS / kx
    near = []
    for gx in range(int((cx - reach_lon) / _SIGNAL_CELL), int((cx + reach_lon) / _SIGNAL_CELL) + 1):
        for gy in range(int((cy - reach_lat) / _SIGNAL_CELL), int((cy + reach_lat) / _SIGNAL_CELL) + 1):
            for lon, lat, bearing in grid.get((gx, gy), ()):
                if math.hypot((lon - cx) * kx, (lat - cy) * 111_320) <= WAFFLE_SIGNAL_REACH_METERS \
                        and _faces(lon, lat, bearing, cx, cy) \
                        and _owned_by(lon, lat, cx, cy, centres):
                    near.append((lon, lat))
    if len(near) < WAFFLE_MIN_SIGNALS:
        return None
    hull = _convex_hull(near)
    if len(hull) < 3:
        return None
    metres = [((x - cx) * kx, (y - cy) * 111_320) for x, y in hull]
    area = abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(metres, metres[1:] + metres[:1]))) / 2
    perimeter = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(metres, metres[1:] + metres[:1]))
    if perimeter <= 0 or 4 * math.pi * area / perimeter ** 2 < WAFFLE_MIN_COMPACTNESS:
        return None
    hx = sum(p[0] for p in hull) / len(hull)
    hy = sum(p[1] for p in hull) / len(hull)
    return [(hx + (x - hx) * WAFFLE_SHRINK, hy + (y - hy) * WAFFLE_SHRINK) for x, y in hull]


def _waffle_key(ring):
    """Одна зона на перекрёсток: центр перекрёстка бывает в двух соседних тайлах."""
    return tuple(sorted((round(x, 5), round(y, 5)) for x, y in ring))


def waffle_centre(ring):
    """Центр тяжести зоны — точка для значка светофора.

    Значок по самому полигону MapLibre ставит в каждом тайле, куда полигон
    попал целиком (_put кладёт фигуру во все задетые тайлы): на стыке трёх
    тайлов — три светофора в одной «вафле». Точка лежит в одном тайле.
    """
    # От первой вершины: произведения градусов порядка 69 × 41 съедают точность
    # до пары метров.
    ox, oy = ring[0]
    local = [(x - ox, y - oy) for x, y in ring]
    twice = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(local, local[1:] + local[:1]):
        cross = x0 * y1 - x1 * y0
        twice += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if abs(twice) < 1e-18:
        return _box_centre(ring)
    return (ox + cx / (3 * twice), oy + cy / (3 * twice))


def _inside(point, ring):
    x, y = point
    hit = False
    for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


class WaffleSet:
    """Уже поставленные «вафли».

    Соседние центры одного перекрёстка дают почти ту же оболочку светофоров с
    чуть другим набором вершин — это дубль, а не вторая зона. Новая зона
    отбрасывается, если её центр внутри уже стоящей или центр стоящей — внутри неё.
    """

    def __init__(self):
        self._grid = defaultdict(list)

    def add(self, ring):
        """Центр новой зоны или None, если это дубль уже поставленной."""
        centre = waffle_centre(ring)
        cell = (int(centre[0] / _SIGNAL_CELL), int(centre[1] / _SIGNAL_CELL))
        for gx in range(cell[0] - 1, cell[0] + 2):
            for gy in range(cell[1] - 1, cell[1] + 2):
                for other, other_centre in self._grid.get((gx, gy), ()):
                    if _inside(centre, other) or _inside(other_centre, ring):
                        return None
        self._grid[cell].append((ring, centre))
        return centre


def _has_signal(shape, grid):
    """Совместимость: есть ли у центра перекрёстка своя «вафля»."""
    return waffle_zone(shape, grid) is not None


# Бетон, а не газон: узкая разделительная (средняя ширина меньше этого) и
# островок у перекрёстка из OSM — как у Яндекса на Навои. Широкая
# разделительная остаётся зелёной (Чиланзар, Бунёдкор).
CONCRETE_MAX_METERS = 4.0


def is_concrete(flags, ring):
    if flags & 4:                    # островок, нарисованный в OSM
        return True
    if not flags & 2 or len(ring) < 3:
        return False
    kx = 111_320 * math.cos(math.radians(ring[0][1]))
    perimeter = sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)
                    for a, b in zip(ring, ring[1:] + ring[:1]))
    return perimeter > 0 and 2 * _ring_area(ring) / perimeter < CONCRETE_MAX_METERS


def _area_props(kind, flags):
    props = {"kind": kind}
    if kind == AREA_FILLET:
        props["major"] = bool(flags & 2)
    if kind == AREA_ROAD:
        props["cls"] = (flags >> SURFACE_CLASS_SHIFT) & SURFACE_CLASS_MASK
    if kind == AREA_MEDIAN and flags & 2:
        props["strip"] = True
    if kind == AREA_JUNCTION and flags & 2:
        props["fill"] = True
    if kind == AREA_MEDIAN and flags & 4:
        props["island"] = True
    return props


def _layer_of(kind):
    if kind in (AREA_ROAD, AREA_JUNCTION, AREA_MEDIAN, AREA_JUNCTION_BOX, AREA_FILLET, AREA_DIVIDER):
        return LAYER_SURFACE
    if kind == AREA_HOUSE:
        return LAYER_HOUSES
    return LAYER_LAND


class _Buckets:
    """Черновики тайлов на диске. В памяти — один объект и до `handles` файлов.

    Черновики СЖАТЫ, и это не микрооптимизация. Компромисс здесь изначально
    верный — платить диском вместо памяти, на сервере её два гигабайта, — но
    расплата вышла несоразмерной: JSON-текст черновиков занял 17 ГБ против
    1,7 ГБ готового protobuf, забил диск до нуля и едва не уронил живой api,
    который пишет свою базу на тот же том.

    Gzip уровня 1 возвращает соразмерность: тот же текст ужимается примерно
    вдесятеро, пик диска падает с 17 ГБ до двух, а цена — доли процента
    времени сборки, потому что уровень 1 быстрый, а черновик всё равно
    выбрасывается. Дописывание в gzip создаёт несколько членов в файле, и
    читатель разбирает их прозрачно — поведение не меняется.
    """

    def __init__(self, work, handles=64):
        self.work = work
        self.handles = handles
        self.open = OrderedDict()
        self.keys = set()
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, exist_ok=True)

    def sink(self, key):
        handle = self.open.get(key)
        if handle is not None:
            self.open.move_to_end(key)
            return handle
        while len(self.open) >= self.handles:
            self.open.popitem(last=False)[1].close()
        handle = gzip.open(os.path.join(self.work, key + ".jsonl.gz"), "at",
                           encoding="utf-8", compresslevel=1)
        self.open[key] = handle
        self.keys.add(key)
        return handle

    def close(self):
        for handle in self.open.values():
            handle.close()
        self.open.clear()


def _put(buckets, zoom, layer, geom_kind, points, props):
    """Разложить одну фигуру по тайлам зума.

    Фигура, задевшая несколько тайлов, попадает в каждый ЦЕЛИКОМ — как у нас в
    JSON. Резать её по границе было бы правильнее по трафику и опаснее по
    смыслу: обрезанная улица теряет имя и направление на стыке, а координаты
    за пределами тайла спецификация разрешает, и клиент режет их сам.
    """
    if not points:
        return
    # Work in projected tile coordinates. Vertex-only assignment drops every
    # intermediate tile of a long segment and the interior of large polygons.
    projected = [mvt.project(lat, lon, zoom, 0, 0) for lon, lat in points]
    seen = set()

    def cover(a, b, buffer=0):
        low_x = max(0, math.floor((min(a[0], b[0]) - buffer) / mvt.EXTENT))
        high_x = min((1 << zoom) - 1,
                     math.floor((max(a[0], b[0]) + buffer) / mvt.EXTENT))
        low_y = max(0, math.floor((min(a[1], b[1]) - buffer) / mvt.EXTENT))
        high_y = min((1 << zoom) - 1,
                     math.floor((max(a[1], b[1]) + buffer) / mvt.EXTENT))
        seen.update((x, y) for x in range(low_x, high_x + 1)
                    for y in range(low_y, high_y + 1))

    if geom_kind == mvt.POLYGON:
        # Include interior tiles even when no polygon vertex lies inside them.
        cover((min(x for x, y in projected), min(y for x, y in projected)),
              (max(x for x, y in projected), max(y for x, y in projected)))
    elif geom_kind == mvt.LINESTRING:
        # A small buffer carries road edges over a tile boundary too. Splitting
        # long diagonals bounds duplication to a corridor, not a huge rectangle.
        buffer = 128
        for a, b in zip(projected, projected[1:]):
            steps = max(1, math.ceil(max(abs(b[0] - a[0]), abs(b[1] - a[1]))
                                     / (mvt.EXTENT / 2)))
            previous = a
            for step in range(1, steps + 1):
                t = step / steps
                current = (a[0] + (b[0] - a[0]) * t,
                           a[1] + (b[1] - a[1]) * t)
                cover(previous, current, buffer)
                previous = current
    else:
        for point in projected:
            cover(point, point)
    for tile_x, tile_y in sorted(seen):
        shape = [mvt.project(lat, lon, zoom, tile_x, tile_y)
                 for lon, lat in points]
        if geom_kind == mvt.POLYGON:
            # Полигон режется по своему тайлу, а линия — нет, и это не
            # непоследовательность.
            #
            # Довод «резать опаснее по смыслу» написан про УЛИЦУ: обрезанная,
            # она теряет имя и направление на стыке, а вершин у неё десяток.
            # У площади такого довода нет, зато есть цена: покрытие
            # внутренними тайлами заставило каждое озеро и каждый квартал
            # копироваться ЦЕЛИКОМ в каждый накрытый тайл. Замер на боевой
            # стране: 349 919 тайлов и 9,8 ГБ против 118 439 и 1,7 ГБ — втрое
            # больше тайлов и вшестеро байт.
            #
            # Ровно это уже проходили в дорожных тайлах, и там же лежит
            # лекарство: clip_ring с комментарием про «1,3 миллиона копий
            # вершин ради одного озера». Переиспользуем его — в координатах
            # тайла прямоугольник отсечения тривиален.
            shape = clip_ring(shape, (0, 0, mvt.EXTENT, mvt.EXTENT), CLIP_MARGIN)
            if len(shape) < 3:
                continue
            # Срез даёт дробную точку пересечения, а геометрия MVT
            # целочисленная по спецификации — округляем обратно.
            shape = [(int(round(x)), int(round(y))) for x, y in shape]
        row = json.dumps([layer, geom_kind, shape, props], separators=(",", ":"))
        buckets.sink(f"{zoom}_{tile_x}_{tile_y}").write(row + "\n")


SCALE = 1e5   # шаг координат в тайле, тот же что в build_roads

# Запас вокруг тайла при отсечении полигонов, в координатах тайла.
# Нужен, чтобы обводка фигуры не обрывалась ровно по шву: клиент рисует
# толстую линию, и срез впритык виден глазом.
CLIP_MARGIN = 128


def written_areas(target_dir, set_name):
    """Читать обратно то, что уже написано в тайлы: дома и поверхность.

    Оба слоя пишутся ПОТОКОМ, прямо в файлы тайлов, и в списке `areas` их нет
    вовсе — иначе сборка страны не поместилась бы в память. Значит и в MVT их
    неоткуда взять, кроме как перечитав написанное.

    Это не обходной путь, а следствие: слой, который не влезает в память при
    записи, не влезет в неё и при перекодировании. Читаем по одному тайлу.
    """
    if not os.path.isdir(target_dir):
        return
    tail = f"_{set_name}.json"
    for name in sorted(os.listdir(target_dir)):
        if not name.startswith("road2_") or not name.endswith(tail):
            continue
        try:
            with open(os.path.join(target_dir, name), encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            continue
        for entry in payload.get("roads") or []:
            if len(entry) < 3:
                continue
            kind, flags, flat = entry[0], entry[1], entry[2]
            if len(flat) < 4 or len(flat) % 2:
                continue
            points, lat, lon = [], 0, 0
            for i in range(0, len(flat), 2):
                if i == 0:
                    lat, lon = flat[0], flat[1]
                else:
                    lat += flat[i]
                    lon += flat[i + 1]
                points.append((lon / SCALE, lat / SCALE))
            yield kind, flags, points


def build_mvt(roads, target_dir, areas=(), points=(), far=(),
              zoom=ZOOM_DETAIL, far_zoom=ZOOM_FAR, handles=64,
              written_sets=("h", "d"), far_areas=(), places=(), widths=None,
              crossings=(), trees=()):
    """Написать .mvt под target_dir/mvt/<z>/<x>/<y>.mvt. Возвращает {путь: байты}."""
    work = os.path.join(target_dir, "_mvt")
    buckets = _Buckets(work, handles)
    try:
        widths = widths or {}
        for road in roads:
            _put(buckets, zoom, LAYER_ROADS, mvt.LINESTRING, road[2],
                 _road_props(road, widths.get(id(road))))
        for road in far:
            _put(buckets, far_zoom, LAYER_ROADS, mvt.LINESTRING, road[2],
                 _road_props(road))
        for kind, flags, shape in far_areas:
            _put(buckets, far_zoom, LAYER_LAND, mvt.POLYGON, shape,
                 _area_props(kind, flags))
        for place in places:
            props = place_properties(place)
            if props is None:
                continue
            spot = list(place[2][:1])
            _put(buckets, zoom, LAYER_PLACES, mvt.POINT, spot, props)
            if props["rank"] in FAR_PLACE_RANKS:
                _put(buckets, far_zoom, LAYER_PLACES, mvt.POINT, spot, props)
        def lay(kind, flags, shape):
            props = _area_props(kind, flags)
            if kind == AREA_MEDIAN and flags & 1 and is_concrete(flags, shape):
                props["concrete"] = True
            _put(buckets, zoom, _layer_of(kind),
                 mvt.POLYGON if flags & 1 else mvt.LINESTRING, shape, props)

        for kind, flags, shape in areas:
            lay(kind, flags, shape)
        # Дома и поверхность — из уже написанных тайлов: в памяти их нет.
        signals = _signal_grid(points)
        boxes, junction_areas, strips, drawn_islands = [], [], [], []
        # Полотно — только у стрелок: вся страна в память не влезет.
        arrow_area = arrow_cells(points, _SIGNAL_CELL)
        tree_area = {(int(t[0] / JunctionMask.CELL), int(t[1] / JunctionMask.CELL)) for t in trees}
        asphalt_rings, tree_asphalt = [], []
        for set_name in written_sets:
            for kind, flags, shape in written_areas(target_dir, set_name):
                if kind in (AREA_ROAD, AREA_JUNCTION, AREA_JUNCTION_BOX, AREA_FILLET) and flags & 1:
                    if near_cells(shape, arrow_area, _SIGNAL_CELL):
                        asphalt_rings.append(shape)
                    if tree_area and near_cells(shape, tree_area, JunctionMask.CELL):
                        tree_asphalt.append(shape)
                if kind == AREA_JUNCTION_BOX:
                    boxes.append(shape)
                # Перемычка между двумя направлениями одной улицы (вид 8 с
                # флагом полосы) — не перекрёсток. Попадая в маску больших
                # узлов, она стирала пунктир на 150–200 м магистрали подряд
                # (Малая кольцевая, 06.10.2026), а в центрах узлов — сбивала
                # стоп-линии двусторонних дорог.
                if kind in (AREA_JUNCTION, AREA_JUNCTION_BOX) and flags & 1 and not (
                        kind == AREA_JUNCTION and flags & 2):
                    junction_areas.append(shape)
                if kind == AREA_MEDIAN and flags & 4:
                    drawn_islands.append(shape)
                if (kind == AREA_MEDIAN and flags & 2) or kind == AREA_DIVIDER:
                    strips.append((kind, flags, shape))
                    continue
                lay(kind, flags, shape)
        # Разметка — после узлов: режется их площадью.
        # Маска разметки — только настоящие перекрёстки: ядра пересечений
        # улиц, середины узлов и площади узлов рядом с ними. Площадь узла у
        # примыкания двора (46–59 м поперёк проспекта) резала пунктир Беруни
        # через каждые 80 м.
        cores = crossing_cores(roads)
        # Плюс любая БОЛЬШАЯ площадь узла: там, где поворотные полосы начерчены
        # отдельными лентами, их пунктир шёл паутиной через весь перекрёсток
        # (41.281, 69.195; метрика dashes_in_junction — 146 м на 1 км).
        # Заплатки на стыках лент одной улицы меньше BIG_JUNCTION_M2.
        big = [ring for ring in junction_areas if _ring_area(ring) >= BIG_JUNCTION_M2]
        # Островок из OSM — бордюр: пунктир сквозь него не идёт.
        near_cores = crossing_areas(junction_areas, cores + boxes)
        mask = JunctionMask(cores + boxes + big + drawn_islands + near_cores)
        # Пунктир полос режется только там, где сходятся РАЗНЫЕ улицы. Большая
        # площадь вдоль одной улицы — разворот между её направлениями, слияние
        # съезда — прерывает разделительную, но не полосы: проспект идёт через
        # неё насквозь, а пунктир пропадал на 100–150 м (Малая кольцевая,
        # 06.10.2026). Разделительные, стрелки и двойная — по полной маске.
        street_names = StreetNames(roads)
        marks_mask = JunctionMask(cores + boxes + drawn_islands + near_cores
                                  + [ring for ring in big if len(street_names.inside(ring)) >= 2])
        # Зебры, которые рисуются, — до разметки: пунктир не идёт сквозь
        # переход (Зарканар, 05.10.2026).
        zebra_nodes = defaultdict(list)
        for point in points:
            if point[0] == 5 and point[1] & PFLAG_PAINTED:
                lon, lat = point[2][0]
                zebra_nodes[(int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))].append((lon, lat))
        drawn_crossings = [(line, marked) for line, marked in crossings
                           if marked or any(_near_crossing_way(spot, zebra_nodes, NODE_ON_WAY_METERS)
                                            for spot in line)]
        # Зебра-узел (переход в OSM точкой, без линии) — та же подгонка, что
        # у линий: поперёк оси, слияние дублей, выравнивание по лентам. Сама по
        # себе она рисовалась штрихами по своему азимуту, и две точки в 3 м
        # друг от друга давали двойную зебру (Беруни у Чорсу, 06.10.2026).
        drawn_way_spots = defaultdict(list)
        for line, _marked in drawn_crossings:
            for lon, lat in line:
                drawn_way_spots[(int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))].append((lon, lat))
        drawn_crossings += [(node_zebra_line(point[1], point[2][0]), True) for point in points
                            if point[0] == 5 and point[1] & PFLAG_PAINTED and point_width(point[1]) > 0
                            and not _near_crossing_way(point[2][0], drawn_way_spots)]
        zebra_fitter = ZebraFitter(roads, widths)
        fitted_zebras = fit_zebras(drawn_crossings, zebra_fitter)
        zebra_centres = zebra_centre_grid(fitted_zebras)
        mask.add_zebras([line for line, _marked in fitted_zebras])
        marks_mask.add_zebras([line for line, _marked in fitted_zebras])
        # Разделительная полоса лежит ПОВЕРХ площади узла (ради носа у
        # перехода), и обрывок полосы между лентами поворотов внутри
        # перекрёстка вылез зелёной кляксой в его середине (28.09.2026).
        # Полоса, чей центр внутри узла, — не разделительная проспекта.
        # Перекрывающиеся разделительные одной улицы (основной ход и дублёр
        # дают несколько пар встречных лент) рисовали поверх друг друга
        # бордюры и носы — жёлтые петли на эстакаде Ахмада Дониша
        # (05.10.2026). Из накрывающих друг друга остаётся бо́льшая.
        strips = drop_overlapping_strips(strips)
        for kind, flags, shape in strips:
            if kind == AREA_DIVIDER:
                # Двойная линия — как пунктир: режется площадью перекрёстка.
                for piece in mask.clip(shape):
                    lay(kind, flags, piece)
            elif strip_outside_junction(shape, mask):
                lay(kind, flags, shape)
        for line, centre, solid, on_bridge in _markings(roads, widths, marks_mask):
            props = {"centre": centre} if centre else {"verified": True}
            if solid and not centre:
                props["solid"] = True
            if on_bridge:
                props["bridge"] = True
            _put(buckets, zoom, LAYER_MARKINGS, mvt.LINESTRING, line, props)
        # Регулируемые перекрёстки — после всех центров: светофор отдаётся
        # ближайшему узлу. Центры — и «середины узла» (вид 10), и ядра
        # перекрёстков двух улиц: середины узла у многих перекрёстков нет вовсе
        # (Беруни × Сакичмон, 05.10.2026), и светофоры там не появлялись.
        candidates = boxes + crossing_cores(roads)
        centres = box_centres(candidates)
        waffles = WaffleSet()
        for box in candidates:
            waffle = waffle_zone(box, signals, centres)
            centre = waffles.add(waffle) if waffle else None
            if centre:
                # Жёлтой сетки нет (у Яндекса её нет): зона только решает,
                # регулируемый ли перекрёсток и где его центр.
                for light in approach_lights(waffle, _junction_signals(box, signals, centres)):
                    _put(buckets, zoom, LAYER_SURFACE, mvt.POINT, [light], {"kind": KIND_APPROACH_LIGHT})
        # Зебры — подогнанные к подходам (fit_zebras): и линии переходов, и
        # размеченные узлы, одним слоем.
        for line, _marked in fitted_zebras:
            _put(buckets, zoom, LAYER_PAINT, mvt.LINESTRING, line, {"kind": KIND_ZEBRA_WAY})
        # Деревья — после полотна: на проезжей части крону не рисуем (в OSM
        # точку дерева ставят и на кромке, и на осевой). У каждой кроны свой
        # размер — одинаковые круги читались «мячиками» (Чорсу, 06.10.2026).
        on_road = JunctionMask(tree_asphalt)
        del tree_asphalt
        for tree in trees:
            if on_road.covers(tree):
                continue
            size = tree_size(tree)
            _put(buckets, zoom, LAYER_TREES, mvt.POINT, [tree], {"size": size})
            # Объёмное дерево: ствол и крона ярусами (узкий низ, широкая
            # середина, сужающийся верх). Один цилиндр в наклоне читался
            # зелёной банкой (06.10.2026); ярусы дают округлый силуэт.
            for ring, props in tree_tiers(tree, size):
                _put(buckets, zoom, LAYER_TREES, mvt.POLYGON, ring, props)
        leaders = arrow_leaders(points)
        asphalt = JunctionMask(asphalt_rings)
        del asphalt_rings
        junction_centres = defaultdict(list)
        for ring in junction_areas:
            cx, cy = _box_centre(ring)
            junction_centres[(int(cx / _SIGNAL_CELL), int(cy / _SIGNAL_CELL))].append((cx, cy))
        # Стоп-линии — до стрелок: стрелки встают от них.
        stop_lines = {}
        for index, point in enumerate(points):
            code, flags, spot = point[0], point[1], point[2]
            lines = []
            if code == 1 and not flags & PFLAG_ONEWAY:
                line = two_way_stop_line(flags, spot[0], junction_centres)
                if line:
                    lines.append((fit_stop_line(line, _line_bearing(line, flags), zebra_fitter,
                                                zebra_centres, True), 1))
            if code in (1, 3):
                lines.extend((fit_stop_line(line, point_azimuth(flags), zebra_fitter, zebra_centres), code)
                             for line in road_paint(code, flags, spot[0]))
            lines = [(line, kind) for line, kind in lines if line]
            if lines:
                stop_lines[index] = lines
        stops = StopIndex(line for lines in stop_lines.values() for line, _code in lines)
        for index, point in enumerate(points):
            code, flags, spot = point[0], point[1], point[2]
            for line, kind in stop_lines.get(index, ()):
                _put(buckets, zoom, LAYER_PAINT, mvt.LINESTRING, line, {"kind": kind})
            if code == 5:
                # Краска перехода — в fit_zebras; точка остаётся приложению.
                _put(buckets, zoom, LAYER_POINTS, mvt.POINT, list(spot),
                     point_properties(code, flags))
                continue
            _put(buckets, zoom, LAYER_POINTS, mvt.POINT, list(spot),
                 point_properties(code, flags))
            if code not in (1, 3):
                for line in road_paint(code, flags, spot[0]):
                    _put(buckets, zoom, LAYER_PAINT, mvt.LINESTRING, line, {"kind": code})
            if code == POINT_LANE_ARROWS and index not in leaders:
                continue          # тот же подход, ряд ближе к перекрёстку уже есть
            if code != POINT_LANE_ARROWS:
                continue
            # Ряд — от стоп-линии своего подхода; нет её — по светофору, как раньше.
            ahead = stops.ahead(spot[0], point_azimuth(flags), point_width(flags))
            if ahead is not None:
                row = placed_arrows(code, flags, spot[0], ARROW_BEFORE_STOP_METERS - ahead,
                                    mask.zebras_only(), asphalt)
            else:
                row = placed_arrows(code, flags, spot[0], arrow_setback(flags, spot[0], signals),
                                    mask, asphalt)
            for arrow, props in row:
                _put(buckets, zoom, LAYER_ARROWS, mvt.POINT, [arrow], props)
    finally:
        buckets.close()

    written = {}
    root = os.path.join(target_dir, "mvt")
    for key in sorted(buckets.keys):
        zoom_at, tile_x, tile_y = key.split("_")
        layers = OrderedDict()
        draft = os.path.join(work, key + ".jsonl.gz")
        with gzip.open(draft, "rt", encoding="utf-8") as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
        # Черновик больше не нужен — сносим сразу, не дожидаясь конца обхода.
        # Иначе весь набор черновиков доживал бы до последнего тайла, и пик
        # диска складывался бы из них ПЛЮС растущего готового набора.
        os.remove(draft)
        # Порядок внутри тайла УСТОЙЧИВЫЙ: иначе те же данные дают разные
        # байты каждую неделю, и всё, что кэшируется по хэшу, качается заново.
        rows.sort(key=lambda row: (row[0], row[1], row[2][0], len(row[2])))
        for layer_name, geom_kind, shape, props in rows:
            layer = layers.get(layer_name)
            if layer is None:
                layer = layers[layer_name] = mvt.Layer(layer_name)
            layer.add(geom_kind, [[tuple(p) for p in shape]], props)
        blob = mvt.tile_bytes(list(layers.values()))
        if not blob:
            continue
        folder = os.path.join(root, zoom_at, tile_x)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"{tile_y}.mvt")
        with open(path, "wb") as out:
            out.write(blob)
        written[f"{zoom_at}/{tile_x}/{tile_y}"] = {
            "sha256": hashlib.sha256(blob).hexdigest(),
            "bytes": len(blob),
        }
    shutil.rmtree(work, ignore_errors=True)
    # Индекс MVT — рядом с тайлами и по той же форме, что у нашего формата.
    #
    # Раньше дерево MVT ехало без подписи, и это было записано осознанно:
    # «MVT читает панель, а она за входом». В день, когда его начинает читать
    # ТЕЛЕФОН, посылка становится ложной: геометрия дорог у водителя обязана
    # приходить только от владельца ключа, иначе взломанный сервер рисует
    # человеку свои дороги. Правило 19 из ARCHITECTURE.md не смягчается —
    # подпись накрывает все тайлы разом через их sha256.
    payload = json.dumps({"version": 1, "tiles": written},
                         separators=(",", ":")).encode()
    with open(os.path.join(target_dir, "mvt_index_payload.json"), "wb") as handle:
        handle.write(payload)
    return written
