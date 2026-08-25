#!/usr/bin/env python3
"""Сборка дорожных тайлов для схемы на приборке.

Зачем. Приложение чертит окрестные дороги само, без карты и без сети: приборка
это режим «телефон в держателе», и она обязана быть самым дешёвым экраном, а
не самым дорогим. Первым источником служил индекс лимитов скорости — он уже на
телефоне и несёт настоящую геометрию, но НЕ ЗНАЕТ ни класса дороги, ни моста,
ни односторонности, ни дворов. Всё это есть в OSM, и этот скрипт достаёт
именно их.

Вход:  roads.geojsonl — выгрузка OSM в формате GeoJSON Text Sequence
       (RFC 8142: каждая запись начинается с байта 0x1E — обычный json.loads
       по строке на нём падает, и это первое, обо что тут спотыкаешься).
Выход: каталог тайлов по 0.5° (~55 км) + index_payload.json.

Тайлы, а не один файл: вся страна — десятки мегабайт, а телефону нужна
окрестность. Дорога, задевшая несколько тайлов, кладётся в КАЖДЫЙ из них
целиком — дубль на границе стоит килобайты, а склейка по границам стоила бы
клиенту кода и ошибок.

Целостность: index_payload.json несёт sha256 каждого тайла. Владелец
подписывает ЕГО (publish_roads.sh, Ed25519-ключ живёт только у владельца) —
и подпись индекса накрывает все тайлы разом: подменённый на сервере или по
дороге тайл не сойдётся по хэшу и будет отброшен телефоном.

Формат тайла (экономия важнее читаемости — файл едет на телефоны):

    {"version": 1, "roads": [[cls, flags, [lat, lon, dlat, dlon, …]], …]}

    cls    — код класса дороги (см. CLASS_CODES)
    flags  — биты: 1 = одностороннее, 2 = мост, 4 = тоннель
    коорды — первая точка абсолютная в 1e-5°, дальше ДЕЛЬТЫ в тех же единицах.
             1e-5° ≈ 1,1 м: мельче для схемы бессмысленно, а дельты в целых
             жмутся gzip в разы лучше, чем полные числа с плавающей точкой.

Индекс по сетке строит уже приложение при загрузке — так же, как для лимитов.
Дублировать его в файле значило бы возить одно и то же дважды.

Запуск на VPS (обычно через publish_roads.sh с локальной машины владельца):
    python3 build_roads.py --in /opt/radarmap/work/roads.geojsonl \\
                          --tiles /opt/radarmap/work/roads_tiles
"""
import argparse
import hashlib
import json
import math
import os
import sys
from collections import Counter, defaultdict

# Что рисуем. Пешеходное, тропы и велодорожки не берём: схема про то, где
# едет машина, а лишние линии превращают её в паутину.
CLASS_CODES = {
    "motorway": 1, "motorway_link": 1,
    "trunk": 2, "trunk_link": 2,
    "primary": 3, "primary_link": 3,
    "secondary": 4, "secondary_link": 4,
    "tertiary": 5, "tertiary_link": 5,
    "residential": 6, "unclassified": 6, "living_street": 6,
    "service": 7,
}

FLAG_ONEWAY, FLAG_BRIDGE, FLAG_TUNNEL = 1, 2, 4
# Замкнутая дорога: кольцевая развязка или круговой проезд. Клиент замыкает
# контур и не рисует на ней шевроны — стрелки по кругу читаются как ошибка.
FLAG_RING = 8

# У кого возим имя. Ниже tertiary имя либо отсутствует, либо не нужно ни для
# подписи под курсором, ни для схлопывания раздельных проезжих.
NAMED_MAX_CLASS = 5

# Упрощение: 4 м — на схеме шириной в пару сотен метров разницы не видно,
# а точек становится в разы меньше.
SIMPLIFY_METERS = 4.0
SCALE = 1e5   # 1e-5° ≈ 1,1 м

# Тайл 0.2° ≈ 22 км. Было 0.5° (55 км), и это оказалось главной статьёй
# расхода на телефоне: схема показывает МАКСИМУМ 700 метров, а чтобы нарисовать
# их, телефон скачивал, разбирал и держал в памяти тайл Ташкента на 2,74 МБ —
# и так девять штук покрытия 3×3, около 4,6 МБ на въезде в город.
# Несоразмерность в восемьдесят раз. При 0.2° тот же Ташкент раскладывается на
# файлы в сотни килобайт, а индекс растёт с 210 записей до ~840 — он приезжает
# раз в неделю и остаётся мелким.
TILE_DEGREES = 0.5
# Сетка НОВОГО формата. 0.05° ≈ 6 км. Замер на живом тайле Ташкента
# (71 595 дорог, 2,74 МБ) объясняет, почему так мелко:
#
#   сетка   макс тайл   худшее окно 3×3   индекс страны
#   0.5°     2.54 МБ        2.56 МБ           20 КБ
#   0.2°     1.38 МБ        2.60 МБ           43 КБ   ← город целиком в ячейке
#   0.1°     0.47 МБ        1.96 МБ          114 КБ
#   0.05°    0.15 МБ        0.98 МБ          356 КБ
#
# 0.2° почти ничего не дало: Ташкент шириной около двадцати километров
# укладывается в одну ячейку в двадцать два. Выигрыш начинается там, где
# ячейка меньше города. Индекс в 356 КБ приезжает раз в неделю — это цена,
# которую платят один раз, а разбор тайла телефон платит на каждом въезде.
TILE_DEGREES_V2 = 0.05

# --- Генерализация -----------------------------------------------------------
#
# Всё, что ниже, раньше считал ТЕЛЕФОН на каждой пересборке растра — то есть
# каждые несколько сотен метров, у каждого пользователя, заново. Здесь это
# считается один раз на всю страну.
#
# Порядок шагов не переставляется: склейка обязана идти до отсева обрубков
# (цепочка из пяти двадцатиметровых кусков — это стометровая улица), а
# сглаживание — после упрощения (иначе оно вдвое дороже при том же результате).

# Обрубок короче этого — не дорога, а хвост геометрии. Меряется ПОСЛЕ склейки.
STUB_METERS = 20.0
# Дальний набор: костяк района, где раздельные проезжие сведены в одну ось.
FAR_MIN_CLASS = 5          # до tertiary включительно
FAR_STUB_METERS = 70.0
FAR_SIMPLIFY_METERS = 12.0
FAR_COLLAPSE_METERS = 45.0

LAT_METERS = 111_320.0


def _node(point):
    """Узел в тех же целых 1e-5°, в которых дорога поедет на телефон: ways в
    OSM делят общие вершины, и после квантования они обязаны совпасть точно."""
    lon, lat = point
    return (round(lat * SCALE), round(lon * SCALE))


def meters_between(a, b):
    """Расстояние между точками [lon, lat] в метрах."""
    lon_scale = math.cos(math.radians((a[1] + b[1]) / 2))
    return math.hypot((b[1] - a[1]) * LAT_METERS,
                      (b[0] - a[0]) * LAT_METERS * lon_scale)


def polyline_meters(points):
    return sum(meters_between(points[i - 1], points[i]) for i in range(1, len(points)))


def split_at_junctions(roads):
    """Разрезать ways по общим вершинам — построить настоящий граф.

    Зачем. В OSM топология УЗЛОВАЯ, а не концевая: проспект проходит СКВОЗЬ
    перекрёсток одной линией, а боковая улица в него упирается. Общий узел при
    этом — внутренняя вершина одной линии и конец другой. `osmium export`
    отдаёт ways как есть, и на выходе получается не граф, а пучок отрезков.

    Замер на живом тайле Ташкента (71 595 дорог) до этой функции:
        вершин уникальных            175 228
        общих для двух и более линий  33 112   ← настоящие узлы
        видны как стык КОНЦОВ         21 283
        концов внутри чужой линии     12 158   ← треть узлов невидима
        узлов степени 1 по концам     90 036 (81%)

    Из-за этого склейка находила лишь пятую часть стыков, заглушки узлов
    закрывали две трети, а грани графа (кварталы) не считались вовсе: формула
    Эйлера на таком «графе» даёт отрицательное число.

    Память: словарь на все уникальные вершины страны, порядка полутора
    миллионов записей. Это единственное место в сборке, где счёт идёт на сотни
    мегабайт, и оно того стоит — без графа не работает ничего дальше.
    """
    # Два множества вместо счётчика: нам нужен факт «вершина встречается у
    # двух и более линий», а не число. На стране это разница между словарём на
    # миллионы записей и одним множеством, которое сразу после разрезки
    # выбрасывается.
    #
    # Внутри одной линии вершина может повторяться (кольцо, разворот) — без
    # дедупликации такая петля объявила бы сама себя перекрёстком.
    seen, junctions = set(), set()
    for road in roads:
        points = road[2]
        for node in {_node(point) for point in points}:
            if node in seen:
                junctions.add(node)
            else:
                seen.add(node)
    del seen

    out = []
    for code, flags, points, name in roads:
        start = 0
        for index in range(1, len(points) - 1):
            if _node(points[index]) in junctions:
                piece = points[start:index + 1]
                if len(piece) >= 2:
                    out.append((code, flags, piece, name))
                start = index
        tail = points[start:]
        if len(tail) >= 2:
            out.append((code, flags, tail, name))
    return out


def merge_ways(roads):
    """Сшить ways с общим концом в непрерывные улицы.

    roads: список (code, flags, points). Сшиваются только линии одного
    характера — класс и флаги (уровень и односторонность сидят во флагах).
    Односторонние не разворачиваются: у них есть направление, и перевёрнутый
    кусок пустил бы стрелки против движения.

    Узел степени ровно два — стык двух кусков одной улицы. Всё остальное
    перекрёсток, и сшивать через него нельзя: получилась бы «улица», идущая
    из одной ветки развилки в другую мимо главной. Степень считается заранее
    по всем линиям, иначе правило зависело бы от порядка входа.
    """
    degree = Counter()
    starts, ends = defaultdict(list), defaultdict(list)
    for index, road in enumerate(roads):
        points = road[2]
        first, last = _node(points[0]), _node(points[-1])
        degree[first] += 1
        degree[last] += 1
        starts[first].append(index)
        ends[last].append(index)

    used = [False] * len(roads)
    out = []
    for index, (code, flags, points, name) in enumerate(roads):
        if used[index]:
            continue
        used[index] = True
        chain = list(points)
        one_way = bool(flags & FLAG_ONEWAY)

        def step(node, forward):
            if degree[node] != 2:
                return None
            # Имя — часть характера линии. Две улицы, сходящиеся в узле
            # степени два, склеивать нельзя: получилась бы «улица», у которой
            # два названия, и подпись под курсором врала бы на половине пути.
            def suits(j):
                return (not used[j] and roads[j][0] == code
                        and roads[j][1] == flags and roads[j][3] == name)
            same = [j for j in (starts if forward else ends)[node] if suits(j)]
            back = [] if one_way else [
                j for j in (ends if forward else starts)[node] if suits(j)]
            if len(same) + len(back) != 1:
                return None
            return (same[0], False) if same else (back[0], True)

        while True:
            found = step(_node(chain[-1]), True)
            if not found:
                break
            j, reverse = found
            used[j] = True
            tail = list(reversed(roads[j][2])) if reverse else roads[j][2]
            chain.extend(tail[1:])
        while not one_way:
            found = step(_node(chain[0]), False)
            if not found:
                break
            j, reverse = found
            used[j] = True
            head = roads[j][2] if reverse else list(reversed(roads[j][2]))
            chain = head[:-1] + chain
        out.append((code, flags, chain, name))
    return out


def drop_stubs(roads, meters):
    """Убрать то, что после склейки осталось короче порога."""
    return [r for r in roads if polyline_meters(r[2]) >= meters]


def chaikin(points, passes=1):
    """Срезать каждый угол на четверть с обеих сторон.

    После упрощения дорога состоит из палок, и повороты у неё угловатые — в
    жизни у дороги есть радиус, и глаз это знает. Концы держим на месте: они
    лежат в узлах, общих с соседними улицами, и сдвинуть их значило бы
    расцепить перекрёсток.
    """
    if len(points) < 3 or passes <= 0:
        return points
    current = points
    for _ in range(passes):
        nxt = [current[0]]
        for i in range(len(current) - 1):
            a, b = current[i], current[i + 1]
            nxt.append((a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25))
            nxt.append((a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75))
        nxt.append(current[-1])
        current = nxt
    return current


def _bearing(points):
    first, last = points[0], points[-1]
    lon_scale = math.cos(math.radians(first[1]))
    angle = math.degrees(math.atan2((last[0] - first[0]) * lon_scale,
                                    last[1] - first[1]))
    return angle + 360 if angle < 0 else angle


def _point_to_polyline(point, line):
    best = float("inf")
    for i in range(1, len(line)):
        a, b = line[i - 1], line[i]
        lon_scale = math.cos(math.radians(a[1]))
        ax, ay = 0.0, 0.0
        bx, by = (b[0] - a[0]) * LAT_METERS * lon_scale, (b[1] - a[1]) * LAT_METERS
        px, py = (point[0] - a[0]) * LAT_METERS * lon_scale, (point[1] - a[1]) * LAT_METERS
        norm = bx * bx + by * by
        t = max(0.0, min(1.0, (px * bx + py * by) / norm)) if norm else 0.0
        best = min(best, math.hypot(px - bx * t, py - by * t))
    return best


def collapse_dual(roads, max_separation):
    """Свести раздельные проезжие в одну ось.

    В данных проспект честно две проезжие части, и на охвате района две
    параллельные полосы со встречными стрелками читаются ошибкой рендера.
    Так же поступает любая настоящая карта при отдалении.

    Кандидаты ищутся по сетке, а не перебором пар: на костяке страны пар
    сотни тысяч, и квадрат от них не считается ни за какое время.
    """
    if max_separation <= 0 or len(roads) < 2:
        return roads
    cell = max(max_separation * 4 / LAT_METERS, 1e-4)
    grid = defaultdict(list)
    meta = []
    for index, road in enumerate(roads):
        points = road[2]
        meta.append((_bearing(points), polyline_meters(points)))
        seen = set()
        for lon, lat in points:
            key = (int(lat / cell), int(lon / cell))
            if key not in seen:
                seen.add(key)
                grid[key].append(index)

    used = [False] * len(roads)
    order = sorted(range(len(roads)), key=lambda i: -meta[i][1])
    out = []
    for index in order:
        if used[index]:
            continue
        code, flags, points, name = roads[index]
        used[index] = True
        if flags & FLAG_RING or not (flags & FLAG_ONEWAY) or meta[index][1] < 45:
            out.append(roads[index])
            continue

        nearby = set()
        for lon, lat in points:
            base = (int(lat / cell), int(lon / cell))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nearby.update(grid.get((base[0] + dy, base[1] + dx), ()))
        partners = []
        for other in nearby:
            if other == index or used[other]:
                continue
            ocode, oflags, opoints, oname = roads[other]
            if ocode != code or oflags != flags or meta[other][1] < 22:
                continue
            # Имя надёжнее любой геометрии: две проезжие части одного проспекта
            # называются одинаково, а съезд вдоль него — иначе. Когда имена
            # известны обе и разные — это разные дороги, и точка.
            if name and oname and name != oname:
                continue
            delta = abs((meta[index][0] - meta[other][0]) % 360)
            delta = 360 - delta if delta > 180 else delta
            if abs(delta - 180) > 25:
                continue
            step = max(1, len(opoints) // 5)
            if any(_point_to_polyline(opoints[i], points) > max_separation
                   for i in range(0, len(opoints), step)):
                continue
            partners.append(other)
            used[other] = True
        if not partners:
            out.append(roads[index])
            continue

        axis = []
        for point in points:
            best, best_distance = None, max_separation * 1.5
            for partner in partners:
                near = _nearest_on(point, roads[partner][2])
                distance = meters_between(point, near)
                if distance < best_distance:
                    best, best_distance = near, distance
            axis.append(point if best is None
                        else ((point[0] + best[0]) / 2, (point[1] + best[1]) / 2))
        out.append((code, flags & ~FLAG_ONEWAY, axis, name))
    return out


def _nearest_on(point, line):
    best, best_distance = line[0], float("inf")
    for i in range(1, len(line)):
        a, b = line[i - 1], line[i]
        lon_scale = math.cos(math.radians(a[1]))
        bx, by = (b[0] - a[0]) * LAT_METERS * lon_scale, (b[1] - a[1]) * LAT_METERS
        px, py = (point[0] - a[0]) * LAT_METERS * lon_scale, (point[1] - a[1]) * LAT_METERS
        norm = bx * bx + by * by
        t = max(0.0, min(1.0, (px * bx + py * by) / norm)) if norm else 0.0
        candidate = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        distance = meters_between(point, candidate)
        if distance < best_distance:
            best, best_distance = candidate, distance
    return best


def tile_key(lat, lon, degrees=TILE_DEGREES):
    """Ключ тайла: смещаем в положительные, чтобы не спорить об округлении
    отрицательных (и клиент делает ровно то же самое)."""
    return f"{int(math.floor((lat + 90) / degrees))}_{int(math.floor((lon + 180) / degrees))}"


def tile_keys_of(points, degrees=TILE_DEGREES):
    """Все тайлы, которых касается дорога (GeoJSON: [lon, lat])."""
    return {tile_key(lat, lon, degrees) for lon, lat in points}


def perpendicular_distance(point, start, end):
    """Расстояние от точки до отрезка в градусах, с поправкой на широту."""
    lat_scale = math.cos(math.radians(point[1]))
    px, py = (point[0] - start[0]) * lat_scale, point[1] - start[1]
    ex, ey = (end[0] - start[0]) * lat_scale, end[1] - start[1]
    norm = ex * ex + ey * ey
    if norm == 0:
        return math.hypot(px, py)
    t = max(0.0, min(1.0, (px * ex + py * ey) / norm))
    return math.hypot(px - ex * t, py - ey * t)


def simplify(points, tolerance_deg):
    """Дуглас-Пекер, итеративно (рекурсия на длинных трассах упирается в лимит)."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        worst, worst_index = 0.0, -1
        for i in range(lo + 1, hi):
            d = perpendicular_distance(points[i], points[lo], points[hi])
            if d > worst:
                worst, worst_index = d, i
        if worst > tolerance_deg and worst_index > 0:
            keep[worst_index] = True
            stack.append((lo, worst_index))
            stack.append((worst_index, hi))
    return [p for p, k in zip(points, keep) if k]


def encode(points):
    """Первая точка абсолютная, дальше дельты — всё в целых 1e-5°."""
    out = []
    previous_lat = previous_lon = None
    for lon, lat in points:   # GeoJSON: [lon, lat]
        ilat, ilon = round(lat * SCALE), round(lon * SCALE)
        if previous_lat is None:
            out.extend((ilat, ilon))
        else:
            # Нулевые дельты выбрасываем: после квантования соседние точки
            # часто совпадают, и это чистый мусор в файле.
            if ilat == previous_lat and ilon == previous_lon:
                continue
            out.extend((ilat - previous_lat, ilon - previous_lon))
        previous_lat, previous_lon = ilat, ilon
    return out


def flags_of(properties, points=None):
    flags = 0
    # Кольцо распознаём и по тегу, и по геометрии: в OSM встречается и то, и
    # другое, а рисуются они одинаково.
    if properties.get("junction") in ("roundabout", "circular"):
        flags |= FLAG_RING
    elif points and len(points) > 3 and points[0] == points[-1]:
        flags |= FLAG_RING
    oneway = properties.get("oneway")
    if oneway in ("yes", "1", "true", "-1"):
        flags |= FLAG_ONEWAY
    if properties.get("bridge") not in (None, "no"):
        flags |= FLAG_BRIDGE
    if properties.get("tunnel") not in (None, "no"):
        flags |= FLAG_TUNNEL
    return flags


def oriented(points, properties):
    """Геометрия по ходу движения. oneway=-1 в OSM значит «односторонняя
    ПРОТИВ порядка точек» — разворачиваем здесь, чтобы телефон рисовал
    стрелки направления по порядку точек и никогда не думал об этом сам:
    стрелка в обратную сторону хуже, чем никакой."""
    if properties.get("oneway") == "-1":
        return list(reversed(points))
    return points


def area_kind(properties):
    """Вид местности по тегам. None — не наш слой."""
    for key, value in properties.items():
        if (key, value) in WATER_TAGS:
            return AREA_WATER
        if (key, value) in GREEN_TAGS:
            return AREA_GREEN
        if (key, value) in RAIL_TAGS:
            return AREA_RAIL
    return None


def collect_areas(source_path, tolerance_deg):
    """Прочитать geojsonl местности → список (kind, flags, points).

    Полигоны и линии в одном списке: река бывает и лентой, и линией, и рельсы
    — всегда линия. Различает их бит AREA_FLAG_CLOSED, а рисуются они одним
    слоем, потому что отвечают на один вопрос: что здесь, кроме дорог.

    Упрощаем сразу и грубее дорог: контур пруда не несёт геометрии, по которой
    принимают решения за рулём, — он несёт факт «здесь вода».
    """
    areas = []
    if not source_path or not os.path.exists(source_path):
        return areas
    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            properties = feature.get("properties") or {}
            kind = area_kind(properties)
            if kind is None:
                continue
            geometry = feature.get("geometry") or {}
            shape = geometry.get("type")
            if shape == "Polygon":
                rings = geometry.get("coordinates") or []
                points = rings[0] if rings else []
                closed = True
            elif shape == "LineString":
                points = geometry.get("coordinates") or []
                closed = False
            else:
                continue
            if len(points) < 3 if closed else len(points) < 2:
                continue
            points = simplify(points, tolerance_deg)
            if len(points) < (3 if closed else 2):
                continue
            if extent_meters(points) < MIN_AREA_METERS:
                continue
            areas.append((kind, AREA_FLAG_CLOSED if closed else 0, points))
    return areas


def extent_meters(points):
    """Наибольший размер по рамке — им и отсеиваем мелочь."""
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    lon_scale = math.cos(math.radians(lats[0]))
    return max((max(lats) - min(lats)) * LAT_METERS,
               (max(lons) - min(lons)) * LAT_METERS * lon_scale)


def collect(source_path):
    """Прочитать geojsonl → список (code, flags, encoded, tile_keys)."""
    roads = []
    classes, flag_counts = Counter(), Counter()
    read = skipped = 0

    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            # RFC 8142: запись начинается с разделителя 0x1E.
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                skipped += 1
                continue
            read += 1
            properties = feature.get("properties") or {}
            code = CLASS_CODES.get(properties.get("highway"))
            if code is None:
                continue
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "LineString":
                continue
            points = geometry.get("coordinates") or []
            if len(points) < 2:
                continue

            # БЕЗ упрощения. Оно здесь и стояло, и именно оно ломало топологию:
            # Дуглас—Пекер держит концы, но выбрасывает внутренние вершины — в
            # том числе узлы перекрёстков. Замер на живом тайле: 20% концов
            # лежали на ОТРЕЗКЕ чужой линии, а не на её вершине, то есть узел
            # был стёрт раньше, чем из него успели построить граф.
            # Упрощение теперь в generalise(), после разрезки и склейки.
            points = oriented(points, properties)
            if len(points) < 2:
                continue
            # Имя — только у крупных классов. У дворового проезда его либо нет,
            # либо оно не нужно ни для подписи под курсором, ни для склейки, а
            # весит столько же, сколько у проспекта.
            name = properties.get("name", "") if code <= NAMED_MAX_CLASS else ""
            roads.append((code, flags_of(properties, points), points, name))
            classes[properties["highway"]] += 1
            flag_counts[roads[-1][1]] += 1

    return roads, classes, flag_counts, read, skipped


def sort_key(road):
    """Устойчивый порядок. Не ради красоты: недетерминированная сборка меняет
    sha256 ВСЕХ тайлов каждую неделю, и каждый телефон перекачивает свои
    девять штук на ровном месте — при том что в дорогах не изменилось ничего.
    """
    code, flags, points = road[0], road[1], road[2]
    name = road[3] if len(road) > 3 else ""
    return (code, flags, round(points[0][1] * SCALE), round(points[0][0] * SCALE),
            len(points), name)


def generalise(roads, tolerance_deg):
    """Глобальный проход: граф, склейка, отсев обрубков, упрощение.

    Порядок не переставляется, и каждый шаг стоит на предыдущем:

      разрезка   — без неё нет узлов, а значит нет и графа;
      склейка    — работает по узлам, поэтому только после разрезки;
      отсев      — только после склейки: цепочка из пяти двадцатиметровых
                   кусков это стометровая улица, и отсев по длине КУСКА убил
                   бы её целиком;
      упрощение  — последним. Раньше оно стояло ПЕРВЫМ, на сырых ways, и
                   стирало узлы перекрёстков до того, как из них строился
                   граф. Теперь узлы уже стали концами линий, а концы Дуглас—
                   Пекер не трогает по определению.

    Всё глобально: улица не обязана лежать внутри одного тайла.
    """
    solid = drop_stubs(merge_ways(split_at_junctions(roads)), STUB_METERS)
    return [(code, flags, simplify(points, tolerance_deg), name)
            for code, flags, points, name in solid]


def build_far(roads):
    """Костяк района: только крупные классы, раздельные проезжие сведены в одну
    ось, упрощение грубее. Отдельным набором, а не подмножеством ближнего:
    схлопывание даёт ДРУГУЮ геометрию, а не выборку из той же.
    """
    backbone = [r for r in roads if r[0] <= FAR_MIN_CLASS]
    collapsed = collapse_dual(backbone, FAR_COLLAPSE_METERS)
    coarse = [(code, flags, simplify(points, FAR_SIMPLIFY_METERS / LAT_METERS), name)
              for code, flags, points, name in collapsed]
    return drop_stubs(coarse, FAR_STUB_METERS)


SET_FAR, SET_STREETS, SET_YARDS = "f", "s", "y"
# Слои местности. Живут своими файлами по тому же закону, что дворовые
# проезды: слой, невидимый на текущем охвате, не качается и не разбирается.
SET_WATER, SET_GREEN, SET_RAIL, SET_BLOCKS = "w", "g", "r", "b"

# Коды видов местности — контракт с клиентом (SketchArea.Kind).
AREA_WATER, AREA_GREEN, AREA_RAIL, AREA_BLOCK = 1, 2, 3, 4
AREA_FLAG_CLOSED = 1

# Что считаем водой, зеленью и рельсами. Списки нарочно короткие: на приборке
# нужны ориентиры, а не полнота справочника. Вода — единственный не-серый цвет
# на тёмной схеме, и именно она отличает местность от чертежа.
WATER_TAGS = {("natural", "water"), ("landuse", "reservoir"),
              ("waterway", "riverbank"), ("waterway", "river"),
              ("waterway", "canal")}
GREEN_TAGS = {("leisure", "park"), ("landuse", "forest"), ("landuse", "grass"),
              ("landuse", "cemetery"), ("natural", "wood")}
RAIL_TAGS = {("railway", "rail")}

# Мелочь на охвате схемы неразличима, а весит столько же, сколько крупное.
MIN_AREA_METERS = 60.0


def split_sets(roads, far):
    """Разложить дороги по файлам, которые телефон качает ПОРОЗНЬ.

    Дворовые проезды — половина всех дорог (в Ташкенте 29 224 из 59 148), а
    видны они только на ближнем плане, когда мы сами во дворе. Возить их в
    одном файле с улицами значит заставлять телефон скачивать и разбирать
    вдвое больше данных всю дорогу ради случая, который наступает под конец
    поездки. В отдельном файле они просто не качаются, пока не понадобятся:
    обычная езда по городу — 0.43 МБ на окно 3×3 вместо 2.56 МБ сегодня.
    """
    return {SET_FAR: far,
            SET_STREETS: [r for r in roads if r[0] <= 6],
            SET_YARDS: [r for r in roads if r[0] == 7]}


# --- Кварталы: грани планарного графа --------------------------------------

# Меньше этого квартал на схеме — пятно, больше — уже не квартал, а внешняя
# область за пределами сети (или дыра в данных, которую нельзя выдавать за
# застройку).
BLOCK_MIN_AREA = 400.0        # м², примерно один двор
BLOCK_MAX_AREA = 500_000.0    # м², половина квадратного километра


def _bearing_from(node_point, next_point):
    lon_scale = math.cos(math.radians(node_point[1]))
    angle = math.degrees(math.atan2((next_point[0] - node_point[0]) * lon_scale,
                                    next_point[1] - node_point[1]))
    return angle + 360 if angle < 0 else angle


def signed_area_meters(points):
    """Площадь по формуле шнурков, в метрах. Знак говорит об обходе."""
    if len(points) < 3:
        return 0.0
    lat0 = sum(p[1] for p in points) / len(points)
    lon_scale = math.cos(math.radians(lat0)) * LAT_METERS
    total = 0.0
    for i in range(len(points)):
        x1, y1 = points[i][0] * lon_scale, points[i][1] * LAT_METERS
        x2, y2 = points[(i + 1) % len(points)][0] * lon_scale, \
                 points[(i + 1) % len(points)][1] * LAT_METERS
        total += x1 * y2 - x2 * y1
    return total / 2


def build_blocks(roads, min_area=BLOCK_MIN_AREA, max_area=BLOCK_MAX_AREA):
    """Кварталы как замкнутые грани дорожного графа.

    Контур квартала СЛЕДУЕТ из измеренных дорог — он не берётся ниоткуда и не
    дорисовывается. Это то же правило, по которому живёт вся схема: чертим
    только измеренное. Зато чёрные пустоты между улицами перестают быть
    пустотами, и картинка становится картой, не требуя ни контуров домов, ни
    единого нового байта данных.

    Работает ТОЛЬКО после split_at_junctions: обход граней идёт по узлам, а до
    разрезки узлов нет — есть висящие концы, и формула Эйлера на таком графе
    даёт отрицательное число.

    Алгоритм классический: в каждом узле полурёбра сортируются по азимуту, и
    обход всё время сворачивает в «следующее по часовой» — так замыкается
    ровно одна грань. Внешняя грань отличается знаком площади, вырожденные
    заезды по тупику дают почти нулевую площадь и отсеиваются порогом.
    """
    # Полурёбра: каждая линия даёт два направленных ребра.
    half = []            # (from_node, to_node, points)
    for road in roads:
        points = road[2]
        if len(points) < 2:
            continue
        half.append((_node(points[0]), _node(points[-1]), points))
        half.append((_node(points[-1]), _node(points[0]), list(reversed(points))))

    outgoing = defaultdict(list)
    for index, (start, _, points) in enumerate(half):
        outgoing[start].append((_bearing_from(points[0], points[1]), index))
    for node in outgoing:
        outgoing[node].sort()

    # Индекс полуребра, обратного данному: они идут парами.
    def twin(index):
        return index ^ 1

    def next_in_face(index):
        """Следующее полуребро грани: в узле прибытия берём соседнее ПЕРЕД
        обратным по часовой стрелке. Это и замыкает грань."""
        _, end, points = half[index]
        back = _bearing_from(points[-1], points[-2])
        edges = outgoing[end]
        if not edges:
            return None
        # Ближайшее строго меньшее по азимуту, иначе последнее (обход круга).
        chosen = edges[-1]
        for bearing, candidate in edges:
            if bearing < back:
                chosen = (bearing, candidate)
            else:
                break
        return chosen[1]

    visited = [False] * len(half)
    blocks = []
    for start in range(len(half)):
        if visited[start]:
            continue
        cycle, index, guard = [], start, 0
        while not visited[index] and guard <= len(half):
            visited[index] = True
            cycle.append(index)
            nxt = next_in_face(index)
            if nxt is None:
                break
            index = nxt
            guard += 1
            if index == start:
                break
        if index != start or len(cycle) < 3:
            continue
        ring = []
        for edge in cycle:
            ring.extend(half[edge][2][:-1])
        if len(ring) < 3:
            continue
        area = signed_area_meters(ring)
        # Внешняя грань обходится в другую сторону — её знак противоположен.
        if area >= 0:
            continue
        if not (min_area <= -area <= max_area):
            continue
        blocks.append((AREA_BLOCK, AREA_FLAG_CLOSED, ring))
    return blocks


def write_tiles(roads, target_dir, degrees=TILE_DEGREES_V2, areas=()):
    """Разложить дороги по тайлам и собрать индексы v1 и v2.

    Дорога, задевшая несколько тайлов, попадает в каждый целиком: дубль на
    границе дешевле, чем склейка на клиенте.

    Пишем ОБА формата. Клиент отбрасывает индекс чужой версии обеими точками
    загрузки, то есть выкатить только v2 значило бы оставить все установленные
    сборки без дорог совсем. v1 убирается, когда в проде не останется старых.
    """
    os.makedirs(target_dir, exist_ok=True)
    far = build_far(roads)

    def encoded(items):
        """Запись тайла: код, биты, дельты — и имя четвёртым, если оно есть.

        Четвёртый элемент необязателен намеренно: имя есть у одной дороги из
        семи, и писать пустую строку каждой остальной значило бы платить за
        неё местом у всех.
        """
        out = []
        for item in sorted(items, key=sort_key):
            entry = [item[0], item[1], encode(item[2])]
            if len(item) > 3 and item[3]:
                entry.append(item[3])
            out.append(entry)
        return out

    def tile(items, step):
        by_key = defaultdict(list)
        for road in items:
            for key in tile_keys_of(road[2], step):
                by_key[key].append(road)
        return by_key

    # --- Старый формат: та же сетка 0.5°, один файл, всё вместе.
    # Клиент отбрасывает индекс чужой версии обеими точками загрузки, то есть
    # выкатить только v2 значило бы оставить все установленные сборки без
    # дорог совсем. Убирается, когда в проде не останется старых.
    index_v1 = {}
    for key, items in sorted(tile(roads, TILE_DEGREES).items()):
        blob = json.dumps({"version": 1, "roads": encoded(items)},
                          separators=(",", ":")).encode()
        with open(os.path.join(target_dir, f"tile_{key}.json"), "wb") as handle:
            handle.write(blob)
        index_v1[key] = {"sha256": hashlib.sha256(blob).hexdigest(),
                         "bytes": len(blob)}

    # --- Слои местности: вода, зелень, рельсы. Каждый своим файлом.
    area_sets = {SET_WATER: [], SET_GREEN: [], SET_RAIL: [], SET_BLOCKS: []}
    by_code = {AREA_WATER: SET_WATER, AREA_GREEN: SET_GREEN,
               AREA_RAIL: SET_RAIL, AREA_BLOCK: SET_BLOCKS}
    for kind, flags, points in areas:
        area_sets[by_code[kind]].append((kind, flags, points))
    # Кварталы считаются из САМОЙ сети, а не приходят из OSM.
    area_sets[SET_BLOCKS].extend(build_blocks(roads))

    # --- Новый формат: мелкая сетка, файлы по наборам.
    # Ключ индекса — СОСТАВНОЙ: «тайл_набор». Не вложенный словарь, и это
    # ради клиента: у него уже есть разобранный и проверенный индекс вида
    # «ключ → sha256», и плоские ключи ложатся в него без единой правки
    # структуры. Телефон просто просит на три ключа больше.
    sets = split_sets(roads, far)
    sets.update(area_sets)
    tiled = {name: tile(items, degrees) for name, items in sets.items()}
    index_v2 = {}
    for name, by_key in sorted(tiled.items()):
        for key, items in sorted(by_key.items()):
            if not items:
                continue
            blob = json.dumps({"version": 2, "roads": encoded(items)},
                              separators=(",", ":")).encode()
            composite = f"{key}_{name}"
            path = os.path.join(target_dir, f"road2_{composite}.json")
            with open(path, "wb") as handle:
                handle.write(blob)
            index_v2[composite] = {"sha256": hashlib.sha256(blob).hexdigest(),
                                   "bytes": len(blob)}

    # Байты индекса подписывает владелец (publish_roads.sh): подпись индекса
    # накрывает все тайлы разом через их sha256.
    for version, index, step, name in (
            (1, index_v1, TILE_DEGREES, "index_payload.json"),
            (2, index_v2, degrees, "index_payload_v2.json")):
        payload = json.dumps({"version": version, "tileDegrees": step,
                              "tiles": index},
                             separators=(",", ":")).encode()
        with open(os.path.join(target_dir, name), "wb") as handle:
            handle.write(payload)
    return index_v1, index_v2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="source", required=True)
    parser.add_argument("--tiles", dest="tiles_dir", required=True,
                        help="каталог, куда положить tile_*.json и index_payload.json")
    parser.add_argument("--tolerance", type=float, default=SIMPLIFY_METERS)
    parser.add_argument("--grid", type=float, default=TILE_DEGREES_V2,
                        help="шаг сетки тайлов в градусах")
    parser.add_argument("--areas", dest="areas", default=None,
                        help="geojsonl с водой, зеленью и рельсами (необязателен)")
    args = parser.parse_args()

    raw, classes, flag_counts, read, skipped = collect(args.source)
    roads = generalise(raw, args.tolerance / 111_320.0)
    # Местность упрощаем грубее дорог: контур пруда не несёт геометрии, по
    # которой принимают решения за рулём.
    areas = collect_areas(args.areas, args.tolerance * 3 / 111_320.0)
    index, index_v2 = write_tiles(roads, args.tiles_dir, args.grid, areas)

    points_total = sum(len(r[2]) for r in roads)
    print(f"склейка и отсев: {len(raw)} → {len(roads)} дорог")
    total_bytes = sum(meta["bytes"] for meta in index.values())
    biggest = max(index.items(), key=lambda kv: kv[1]["bytes"], default=None)
    print(f"прочитано объектов: {read} (не разобрано: {skipped})")
    print(f"дорог: {len(roads)}, точек: {points_total}, тайлов: {len(index)}")
    print(f"суммарно: {total_bytes / 1e6:.1f} МБ (в gzip будет в разы меньше)")
    if biggest:
        print(f"самый тяжёлый тайл: {biggest[0]} — {biggest[1]['bytes'] / 1e6:.1f} МБ")
    v2_bytes = sum(meta["bytes"] for meta in index_v2.values())
    print(f"формат v2: файлов {len(index_v2)}, суммарно {v2_bytes / 1e6:.1f} МБ, сетка {args.grid}°")
    if areas:
        counts = Counter(kind for kind, _, _ in areas)
        print(f"местность: вода {counts[AREA_WATER]}, зелень {counts[AREA_GREEN]}, "
              f"рельсы {counts[AREA_RAIL]}")
    print("классы:", classes.most_common(10))
    bridges = sum(n for f, n in flag_counts.items() if f & FLAG_BRIDGE)
    tunnels = sum(n for f, n in flag_counts.items() if f & FLAG_TUNNEL)
    oneways = sum(n for f, n in flag_counts.items() if f & FLAG_ONEWAY)
    print(f"односторонних: {oneways}, мостов: {bridges}, тоннелей: {tunnels}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
