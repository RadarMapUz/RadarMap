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
from build_roads import (AREA_FILLET, AREA_HOUSE, AREA_JUNCTION, AREA_JUNCTION_BOX, AREA_MEDIAN, AREA_ROAD,
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


def lane_arrows(code, flags, point):
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
        along = -ARROW_SETBACK_METERS
        yield ((lon + (math.cos(angle) * across + math.sin(angle) * along)
                / (111_320 * math.cos(math.radians(lat))),
                lat + (-math.sin(angle) * across + math.cos(angle) * along) / 111_320),
               {"turn": turn, "bearing": round(bearing)})


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

    def covers(self, point):
        for box, ring in self._grid.get((int(point[0] / self.CELL), int(point[1] / self.CELL)), ()):
            if box[0] <= point[0] <= box[2] and box[1] <= point[1] <= box[3] and _inside(point, ring):
                return True
        return False

    def clip(self, line, step_meters=MARKING_CLIP_STEP_METERS):
        """Куски линии вне узлов; короче MARKING_MIN_METERS — выбрасываются."""
        if not self._grid or len(line) < 2:
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


def lane_markings(roads, widths=None, mask=None):
    """Разделители подтверждённых односторонних полос вне перекрёстков.

    Вход — сеть ПОСЛЕ generalise: общие узлы уже стали концами сегментов.
    Считаем только концы, не заводим второй индекс всех вершин страны.
    Мосты и тоннели не смешиваются с наземными перекрёстками.
    """
    def key(point, flags):
        return (round(point[0], 6), round(point[1], 6),
                flags & (FLAG_BRIDGE | FLAG_TUNNEL))

    nodes = defaultdict(lambda: [0, 0.0])
    for code, flags, points, _ in roads:
        if len(points) < 2 or code > 7:
            continue
        width = road_width_meters(code, lanes_of(flags))
        for p in (points[0], points[-1]):
            node = nodes[key(p, flags)]
            node[0] += 1
            node[1] = max(node[1], width)

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

    for road in roads:
        code, flags, points = road[0], road[1], road[2]
        lanes = lanes_of(flags)
        if (not flags & FLAG_LANES_TAGGED or not flags & FLAG_ONEWAY
                or not 2 <= lanes <= MAX_MARKED_LANES or code > 7 or len(points) < 2):
            continue
        origin = points[0]
        sx, sy = 111_320 * math.cos(math.radians(origin[1])), 111_320
        metric = [((p[0] - origin[0]) * sx, (p[1] - origin[1]) * sy) for p in points]
        for endpoint in (points[0], points[-1]):
            degree, width = nodes[key(endpoint, flags)]
            metric = trim(metric, width / 2 + JUNCTION_MARKING_MARGIN if degree >= 3 else 0)
            metric.reverse()
        if len(metric) < 2:
            continue
        # Ширина — та же, по которой нарисовано полотно: сужение под
        # разделительную (fit_carriageways) иначе уводило пунктир на неё.
        width = road_width_meters(code, lanes)
        if widths:
            width = min(width, widths.get(id(road)) or width)
        for lane in range(1, lanes):
            offset = width * (lane / lanes - .5)
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
            # Мост и тоннель идут над/под узлом земли — его площадь им не указ.
            if mask is not None and not flags & (FLAG_BRIDGE | FLAG_TUNNEL):
                yield from mask.clip(line)
            else:
                yield line

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


# Зебра рисуется линией шириной 3 м. На изломе такой линии соединение
# заливается сплошь — белый клин посреди перекрёстка (Бунёдкор × Сеул,
# 28.09.2026: переходы OSM ломаются у бордюра). Поэтому линия перехода режется
# на прямые куски без соединений; почти прямой излом кусок не рвёт — иначе
# сбился бы шаг штрихов; огрызок короче метра-двух — не зебра.
ZEBRA_STRAIGHT_DEGREES = 12.0
ZEBRA_MIN_PIECE_METERS = 2.0


def zebra_pieces(line):
    """Прямые куски линии перехода (каждый — отдельная линия, без изломов)."""
    if len(line) < 2:
        return []
    kx = 111_320 * math.cos(math.radians(line[0][1]))

    def heading(a, b):
        return math.degrees(math.atan2((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320))

    def length(a, b):
        return math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)

    pieces, current = [], [line[0]]
    for a, b in zip(line, line[1:]):
        if length(a, b) <= 0:
            continue
        if len(current) >= 2:
            turn = abs((heading(a, b) - heading(current[-2], current[-1]) + 180) % 360 - 180)
            if turn > ZEBRA_STRAIGHT_DEGREES:
                pieces.append(current)
                current = [a]
        current.append(b)
    pieces.append(current)
    return [[piece[0], piece[-1]] for piece in pieces
            if len(piece) >= 2 and length(piece[0], piece[-1]) >= ZEBRA_MIN_PIECE_METERS]


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
                if math.hypot((x - lon) * kx, (y - lat) * 111_320) < own - WAFFLE_OWNER_MARGIN_METERS:
                    return False
    return True


def waffle_zone(box, grid, centres=None):
    """Зона «вафли» для центра перекрёстка или None, если перекрёсток не регулируемый."""
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


def _area_props(kind, flags):
    props = {"kind": kind}
    if kind == AREA_FILLET:
        props["major"] = bool(flags & 2)
    if kind == AREA_ROAD:
        props["cls"] = (flags >> SURFACE_CLASS_SHIFT) & SURFACE_CLASS_MASK
    if kind == AREA_MEDIAN and flags & 2:
        props["strip"] = True
    return props


def _layer_of(kind):
    if kind in (AREA_ROAD, AREA_JUNCTION, AREA_MEDIAN, AREA_JUNCTION_BOX, AREA_FILLET):
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
              crossings=()):
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
            _put(buckets, zoom, _layer_of(kind),
                 mvt.POLYGON if flags & 1 else mvt.LINESTRING,
                 shape, _area_props(kind, flags))

        for kind, flags, shape in areas:
            lay(kind, flags, shape)
        # Дома и поверхность — из уже написанных тайлов: в памяти их нет.
        signals = _signal_grid(points)
        boxes, junction_areas = [], []
        for set_name in written_sets:
            for kind, flags, shape in written_areas(target_dir, set_name):
                if kind == AREA_JUNCTION_BOX:
                    boxes.append(shape)
                if kind in (AREA_JUNCTION, AREA_JUNCTION_BOX) and flags & 1:
                    junction_areas.append(shape)
                lay(kind, flags, shape)
        # Разметка — после узлов: режется их площадью.
        mask = JunctionMask(junction_areas + crossing_cores(roads))
        for line in lane_markings(roads, widths, mask):
            _put(buckets, zoom, LAYER_MARKINGS, mvt.LINESTRING, line, {"verified": True})
        # «Вафли» — после всех центров: светофор отдаётся ближайшему узлу.
        centres = box_centres(boxes)
        waffles = WaffleSet()
        for box in boxes:
            waffle = waffle_zone(box, signals, centres)
            centre = waffles.add(waffle) if waffle else None
            if centre:
                _put(buckets, zoom, LAYER_SURFACE, mvt.POLYGON, waffle, {"kind": KIND_WAFFLE})
                _put(buckets, zoom, LAYER_SURFACE, mvt.POINT, [centre], {"kind": KIND_WAFFLE})
        # Зебры линиями переходов. Линия размечена тегом — или на ней лежит
        # размеченный узел перехода (у Пахтакора линия без тега, а узлы — zebra).
        # Узловая зебра рядом с нарисованной линией — тот же переход, дубль.
        painted_nodes = defaultdict(list)
        for point in points:
            if point[0] == 5 and point[1] & PFLAG_PAINTED:
                lon, lat = point[2][0]
                painted_nodes[(int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))].append((lon, lat))
        crossing_grid = defaultdict(list)
        for line, marked in crossings:
            if not marked and not any(_near_crossing_way(spot, painted_nodes, NODE_ON_WAY_METERS)
                                      for spot in line):
                continue
            for piece in zebra_pieces(line):
                _put(buckets, zoom, LAYER_PAINT, mvt.LINESTRING, piece, {"kind": KIND_ZEBRA_WAY})
            for lon, lat in line:
                crossing_grid[(int(lon / _SIGNAL_CELL), int(lat / _SIGNAL_CELL))].append((lon, lat))
        for point in points:
            code, flags, spot = point[0], point[1], point[2]
            if code == 5 and _near_crossing_way(spot[0], crossing_grid):
                _put(buckets, zoom, LAYER_POINTS, mvt.POINT, list(spot),
                     point_properties(code, flags))
                continue
            _put(buckets, zoom, LAYER_POINTS, mvt.POINT, list(spot),
                 point_properties(code, flags))
            for line in road_paint(code, flags, spot[0]):
                _put(buckets, zoom, LAYER_PAINT, mvt.LINESTRING, line, {"kind": code})
            for arrow, props in lane_arrows(code, flags, spot[0]):
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
