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

# --- Полосы: СТАРШИЕ БИТЫ ТОГО ЖЕ ПОЛЯ, а не пятый элемент записи.
#
# Пятый элемент выглядит очевидным решением и уронил бы разбор ЦЕЛОГО тайла у
# каждой установленной сборки: RoadTiles.swift принимает записи длиной 3 или 4
# и на пятом возвращает nil на весь квадрат — телефон потерял бы не одну
# дорогу, а весь регион. Старших битов старый клиент не видит вовсе: он читает
# flags масками (& 1, & 2, & 4, & 8), и лишние единицы для него ничто.
FLAG_LANES_SHIFT = 4
FLAG_LANES_MASK = 0b1111 << FLAG_LANES_SHIFT
MAX_LANES = 15
# Полосы ЗНАЕМ, а не предположили по классу.
#
# Без этого бита по тайлу нельзя отличить измеренное от подставленного: у
# дороги без тега lanes стоит дефолт класса, и выглядит он ровно так же, как
# настоящее число. Панели это нужно, чтобы показать, ГДЕ работать: очередь
# конструктора — это как раз дороги, о полосах которых OSM молчит.
#
# Телефон бит не читает и читать не должен: ему всё равно, откуда взялась
# ширина, — он рисует то, что приехало. Ровно поэтому бит и можно завести, не
# трогая формат: старшие биты установленная сборка не видит.
FLAG_LANES_TAGGED = 1 << 8
# Нарисовано руками, а не приехало из OSM.
#
# Телефону этот бит не нужен и он его не читает: ему всё равно, откуда взялась
# дорога, он рисует то, что приехало. Нужен он панели — отличать своё от чужого
# в очереди изменений: только у своей геометрии есть срок пересмотра и только
# её надо снимать, когда OSM догонит.
FLAG_HAND_DRAWN = 1 << 9

# Своя дорога короче этого — не дорога, а дрожь мыши.
MIN_DRAWN_METERS = 20.0
# Вершин больше этого в одной линии не бывает: столько щелчков подряд человек
# не делает, а вот зажатая кнопка делает.
MAX_DRAWN_VERTICES = 200
# Отрезок длиннее этого — почти наверняка промах через полгорода: щёлкнули,
# отвлеклись, щёлкнули снова.
MAX_DRAWN_SEGMENT_METERS = 2000.0
# Биты ХАРАКТЕРА линии. Только они участвуют в склейке и сведении проезжих:
# две половины одной улицы, у которых в OSM разное число полос, — по-прежнему
# одна улица, и разойтись они не должны из-за поля, которого раньше не было.
FLAG_TOPO_MASK = FLAG_ONEWAY | FLAG_BRIDGE | FLAG_TUNNEL | FLAG_RING

# Сколько полос считать, когда OSM молчит (а он молчит у 91 % дорог центра
# Ташкента: 769 тегов lanes на 8 455 дорог). Числа ПОЛНЫЕ, как в самом теге:
# у двусторонней дороги это сумма обоих направлений.
DEFAULT_LANES = {1: (3, 6), 2: (3, 6), 3: (3, 6),
                 4: (2, 4), 5: (2, 4), 6: (1, 2), 7: (1, 1)}
# Ширина полосы по классу. Проспект шире улицы не только числом полос, но и
# самой полосой. Дворовый проезд считается одной полосой, но 3.5 м для него
# мало: разъезд в кармане — это те же 4.5, что и в натуре.
LANE_METERS = {1: 3.75, 2: 3.75, 3: 3.75, 4: 3.5, 5: 3.5, 6: 3.5, 7: 4.5}
# Потолок полос по классу. Не косметика: без него дворовый проезд с ошибочным
# lanes=15 рисовался бы асфальтом в 67 м — шире, чем ворота вообще пускают, —
# и одна опечатка в OSM залила бы квартал серым. Класс знает свой предел:
# восьмиполосных дворов не бывает, как не бывает двухполосных магистралей,
# у которых восемь полос указаны ошибкой.
MAX_LANES_BY_CLASS = {1: 15, 2: 15, 3: 12, 4: 8, 5: 8, 6: 4, 7: 2}
# Шире этого проезжей части не бывает: восемь полос по 3.75 — 30 м, запас
# вдвое. Всё, что толще, — опечатка в теге lanes, и её ловят ворота.
MAX_WIDTH_METERS = 60.0


def clamp_lanes(code, lanes):
    """Полосы в пределах, отпущенных классу и четырьмя битами."""
    return max(0, min(int(lanes), MAX_LANES_BY_CLASS.get(code, 8), MAX_LANES))


def lanes_of(flags):
    """Число полос, зашитое в старшие биты. 0 — «OSM молчал»."""
    return (flags & FLAG_LANES_MASK) >> FLAG_LANES_SHIFT


def with_lanes(flags, lanes):
    """Поставить число полос, не тронув биты характера."""
    lanes = max(0, min(MAX_LANES, int(lanes)))
    return (flags & ~FLAG_LANES_MASK) | (lanes << FLAG_LANES_SHIFT)


def topo(flags):
    """Только биты характера: по ним склеивают и сводят."""
    return flags & FLAG_TOPO_MASK


def tagged_lanes(properties):
    """Сказал ли OSM про полосы что-то правдоподобное.

    Мусор в теге — то же, что молчание, и здесь тоже: «99» не делает дорогу
    измеренной, он делает её ошибочно размеченной. Панель обязана предложить
    такую дорогу к правке наравне с молчащей.
    """
    raw = properties.get("lanes")
    if raw is None:
        return False
    try:
        value = int(float(str(raw).split(";")[0].strip()))
    except (TypeError, ValueError):
        return False
    return 1 <= value <= MAX_LANES


def road_lanes(properties, code, oneway):
    """Полосы дороги: из тега, если он есть и правдоподобен, иначе по классу.

    Тег бывает списком через точку с запятой («2;3» на участке с карманом) —
    берём первое число, а не падаем: дорога важнее точности на полполосы.
    """
    raw = properties.get("lanes")
    if raw is not None:
        try:
            value = int(float(str(raw).split(";")[0].strip()))
        except (TypeError, ValueError):
            value = 0
        # Тег принимается, только если он вообще правдоподобен. 99 — это не
        # «очень широкая дорога», это мусор, и подтягивать его к потолку
        # класса значило бы выдумать данные из опечатки. Мусор — то же, что
        # молчание: считаем по классу.
        if 1 <= value <= MAX_LANES:
            return clamp_lanes(code, value)
    single, both = DEFAULT_LANES.get(code, (1, 2))
    return clamp_lanes(code, single if oneway else both)


def road_width_meters(code, lanes):
    """Ширина проезжей части в метрах. Ровно эту формулу считает клиент —
    сервер не возит ширину, он возит полосы (§5.1 плана конструктора)."""
    if not lanes:
        lanes = DEFAULT_LANES.get(code, (1, 2))[1]
    return lanes * LANE_METERS.get(code, 3.5)

# Острее этого угла склейка не идёт: улица не разворачивается на себя в узле.
MAX_MERGE_TURN = 150.0


def _turn_degrees(before, at, after):
    """Угол поворота в вершине, градусы. 0 — прямо, 180 — разворот."""
    lon_scale = math.cos(math.radians(at[1]))
    ax = (at[0] - before[0]) * lon_scale
    ay = at[1] - before[1]
    bx = (after[0] - at[0]) * lon_scale
    by = after[1] - at[1]
    na, nb = math.hypot(ax, ay), math.hypot(bx, by)
    if na == 0 or nb == 0:
        return 0.0
    cos = max(-1.0, min(1.0, (ax * bx + ay * by) / (na * nb)))
    return math.degrees(math.acos(cos))


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
        # Полос у склеенной улицы — максимум по участкам. Не среднее: ширина
        # рисуется одна на всю линию, и занизить её значит провести асфальт
        # уже перекрёстка, к которому улица расширялась.
        chain_lanes = lanes_of(flags)
        one_way = bool(flags & FLAG_ONEWAY)

        def step(node, forward):
            if degree[node] != 2:
                return None
            # Имя — часть характера линии. Две улицы, сходящиеся в узле
            # степени два, склеивать нельзя: получилась бы «улица», у которой
            # два названия, и подпись под курсором врала бы на половине пути.
            # Сравниваем ТОЛЬКО биты характера. Полосы в старших битах —
            # свойство участка, а не линии: улица, у которой перед
            # перекрёстком добавили карман, не перестаёт быть одной улицей, а
            # сравнение всего поля разорвало бы её надвое ровно там, где в OSM
            # проставлен тег lanes.
            def suits(j):
                return (not used[j] and roads[j][0] == code
                        and topo(roads[j][1]) == topo(flags)
                        and roads[j][3] == name)
            same = [j for j in (starts if forward else ends)[node] if suits(j)]
            back = [] if one_way else [
                j for j in (ends if forward else starts)[node] if suits(j)]
            if len(same) + len(back) != 1:
                return None
            found = (same[0], False) if same else (back[0], True)

            # Шпильку не сшиваем. Улица не разворачивается на себя в узле: если
            # продолжение уходит почти туда же, откуда мы пришли, это не одна
            # улица с поворотом, а две, встретившиеся в тупике. Склеенная
            # шпилька рисуется штрихом, идущим туда и обратно, — на экране это
            # шип, торчащий из дороги, и именно он приехал в симулятор.
            tail = roads[found[0]][2]
            outgoing = list(reversed(tail)) if found[1] else tail
            here = chain[-1] if forward else chain[0]
            incoming = chain[-2] if forward else chain[1]
            if _turn_degrees(incoming, here, outgoing[1]) > MAX_MERGE_TURN:
                return None
            return found

        while True:
            found = step(_node(chain[-1]), True)
            if not found:
                break
            j, reverse = found
            used[j] = True
            chain_lanes = max(chain_lanes, lanes_of(roads[j][1]))
            tail = list(reversed(roads[j][2])) if reverse else roads[j][2]
            chain.extend(tail[1:])
        while not one_way:
            found = step(_node(chain[0]), False)
            if not found:
                break
            j, reverse = found
            used[j] = True
            chain_lanes = max(chain_lanes, lanes_of(roads[j][1]))
            head = roads[j][2] if reverse else list(reversed(roads[j][2]))
            chain = head[:-1] + chain
        out.append((code, with_lanes(flags, chain_lanes), chain, name))
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
            # Опять только характер: у двух проезжих одного проспекта число
            # полос часто разное (справа карман под правый поворот), и парой
            # они от этого быть не перестают.
            if (ocode != code or topo(oflags) != topo(flags)
                    or meta[other][1] < 22):
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

        axis = collapsed_axis(points, [roads[i][2] for i in partners], max_separation)
        # Полос у сведённой оси — СУММА проезжих. Костяк рисуется той же
        # толщиной в метрах, что и детальная сеть, и взять полосы одной
        # половины значило бы нарисовать проспект вдвое уже, чем он есть,
        # ровно на том охвате, где он и должен читаться проспектом.
        axis_lanes = clamp_lanes(
            code, lanes_of(flags) + sum(lanes_of(roads[i][1]) for i in partners))
        out.append((code, with_lanes(flags & ~FLAG_ONEWAY, axis_lanes), axis, name))
    return out


# Насколько плавно сдвиг оси сходит на нет там, где встречная проезжая часть
# кончилась. Ниже двадцати метров переход виден изломом.
AXIS_TAPER_METERS = 28.0


def collapsed_axis(points, partners, max_separation):
    """Ось между проезжими частями, сходящая на нет за их пределами.

    Прямолинейное «есть пара — середина, нет пары — своё место» даёт на экране
    ШАГ ВБОК ровно там, где встречная часть кончилась: дорога прыгает на
    половину разноса и обратно. В жизни так не бывает, и глаз читает это
    изломом асфальта, а не концом данных.

    Поэтому сдвиг считается отдельно от точек и затухает вдоль дороги: на
    участке с парой он полный, дальше линейно сходит к нулю за
    AXIS_TAPER_METERS. Плюс сглаживание по трём соседям — оно снимает дрожь
    там, где пара то находится, то теряется на соседних вершинах.

    Ровно то же самое делает RoadGeneralise.collapsedAxis на клиенте. Две
    реализации одного правила — цена переноса генерализации на сервер, и
    расходиться им нельзя: клиент считает по запасному источнику там, где
    тайлов нет.
    """
    if len(points) < 2 or not partners:
        return points

    # 1. Сдвиг там, где пара есть.
    shift = []
    for point in points:
        best, best_distance = None, max_separation * 1.5
        for partner in partners:
            near = _nearest_on(point, partner)
            distance = meters_between(point, near)
            if distance < best_distance:
                best, best_distance = near, distance
        shift.append(None if best is None
                     else ((best[0] - point[0]) / 2, (best[1] - point[1]) / 2))

    # 2. Расстояние вдоль дороги — по нему и затухаем.
    along = [0.0]
    for index in range(1, len(points)):
        along.append(along[-1] + meters_between(points[index - 1], points[index]))

    known = [i for i, value in enumerate(shift) if value is not None]
    if not known:
        return points

    # 3. Пропуски: ближайший известный сдвиг, погашенный по расстоянию до него.
    for index in range(len(shift)):
        if shift[index] is not None:
            continue
        nearest = min(known, key=lambda k: abs(along[k] - along[index]))
        gap = abs(along[nearest] - along[index])
        if gap >= AXIS_TAPER_METERS:
            shift[index] = (0.0, 0.0)
        else:
            fade = 1 - gap / AXIS_TAPER_METERS
            source = shift[nearest]
            shift[index] = (source[0] * fade, source[1] * fade)

    # 4. Сглаживание по трём соседям.
    axis = []
    for index, point in enumerate(points):
        previous = shift[max(0, index - 1)]
        current = shift[index]
        following = shift[min(len(shift) - 1, index + 1)]
        dx = (previous[0] + current[0] * 2 + following[0]) / 4
        dy = (previous[1] + current[1] * 2 + following[1]) / 4
        axis.append((point[0] + dx, point[1] + dy))
    return axis


def _nearest_on(point, line):
    """Ближайшая точка на ломаной. Совместимость: возвращает только точку."""
    return _nearest_segment_on(point, line)[0]


def _nearest_segment_on(point, line):
    """Ближайшая точка на ломаной И азимут ТОГО САМОГО сегмента.

    Азимут берётся у сегмента, а не у линии целиком (_bearing по концам):
    улица после склейки бывает длиной в километр с поворотами, и её общее
    направление к месту, где стоит зебра, отношения не имеет.
    """
    best, best_distance, best_bearing = line[0], float("inf"), 0.0
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
            best_bearing = _bearing_from(a, b)
    return best, best_bearing


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


def flags_of(properties, points=None, code=None):
    """Биты записи. code передаётся, когда класс уже известен: без него полосы
    считать не из чего, и старшие биты остаются нулём — «не задано»."""
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
    if code is not None:
        flags = with_lanes(flags, road_lanes(properties, code,
                                             bool(flags & FLAG_ONEWAY)))
        if tagged_lanes(properties):
            flags |= FLAG_LANES_TAGGED
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
    # Сколько дорог принесли полосы тегом, а не получили их по классу. Число
    # честное и неприятное — в центре Ташкента это 9 %, — и печатать его надо
    # каждую сборку: как только оно начнёт расти, приближение по классу можно
    # будет ужимать.
    lanes_tagged = 0
    sidewalks = []
    arrows = []
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
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "LineString":
                continue
            points = geometry.get("coordinates") or []
            if len(points) < 2:
                continue
            # Тротуары лежат в ТОМ ЖЕ файле: фильтр osmium берёт w/highway
            # целиком, а отсеивает их уже CLASS_CODES. Читать экстракт второй
            # раз ради них незачем — забираем попутно.
            if code is None:
                if properties.get("highway") in SIDEWALK_HIGHWAYS:
                    sidewalks.append([(float(x), float(y)) for x, y in points])
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
            if properties.get("lanes") is not None:
                lanes_tagged += 1
            turns = parse_turn_lanes(properties.get("turn:lanes"))
            if turns:
                # Стрелки стоят ПЕРЕД перекрёстком, а не в нём: решение о
                # полосе принимают на подъезде. Отступаем от конца пути на
                # длину стоп-линии с запасом.
                spot = _step_back(points, ARROW_SETBACK_METERS)
                if spot is not None:
                    arrows.append((spot, turns))
            roads.append((code, flags_of(properties, points, code), points, name))
            classes[properties["highway"]] += 1
            flag_counts[roads[-1][1]] += 1

    return (roads, classes, flag_counts, read, skipped, lanes_tagged,
            sidewalks, arrows)


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


def apply_edits(roads, edits, meters=25.0):
    """Наложить правки панели на сеть → (сеть, наложено, промахнулось).

    Запекаем В ТАЙЛЫ, а не возим отдельным файлом. Отдельный edits.json
    пришлось бы качать, разбирать и СЛИВАТЬ С ДОРОГАМИ НА ТЕЛЕФОНЕ — то есть
    вернуть туда работу, которую только что убрали. Запечённая правка не стоит
    телефону ничего: он получает готовый тайл.

    Правка ищет свою дорогу по МЕСТУ, а не по id: id ведёт в OSM и не переживает
    воскресной пересборки — у той же улицы назавтра другой way.

    Промахи возвращаются, а не глотаются. Правка, не нашедшая дороги, — это
    сигнал для очереди изменений (§9 плана), а не мелочь для лога.
    """
    if not edits:
        return roads, 0, 0
    cells = defaultdict(list)
    for index, road in enumerate(roads):
        for key in _cells_of(road[2], POINT_GRID_DEGREES):
            cells[key].append(index)

    lanes_by_index = {}
    missed = []
    for edit in edits:
        if edit.get("kind") != "lanes":
            continue
        lanes = (edit.get("props") or {}).get("lanes")
        geometry = edit.get("geom") or []
        if not isinstance(lanes, int) or len(geometry) < 2:
            missed.append(edit)
            continue
        origin = (float(geometry[0]), float(geometry[1]))
        best, best_distance, seen = None, meters, set()
        for key in _neighbourhood(origin, POINT_GRID_DEGREES):
            for index in cells.get(key, ()):
                if index in seen:
                    continue
                seen.add(index)
                candidate = _nearest_on(origin, roads[index][2])
                distance = meters_between(origin, candidate)
                if distance < best_distance:
                    best, best_distance = index, distance
        if best is None:
            missed.append(edit)
            continue
        # Рука старше автоматики — но не старше физики: потолок класса стоит
        # и здесь. Опечатка модератора не должна залить квартал асфальтом.
        lanes_by_index[best] = clamp_lanes(roads[best][0], lanes)

    if not lanes_by_index:
        return roads, 0, len(missed)
    patched = list(roads)
    for index, lanes in lanes_by_index.items():
        code, flags, points, name = patched[index]
        # Правка делает дорогу ИЗМЕРЕННОЙ: модератор смотрел на спутник, и в
        # очереди конструктора ей больше делать нечего.
        patched[index] = (code, with_lanes(flags, lanes) | FLAG_LANES_TAGGED,
                          points, name)
    return patched, len(lanes_by_index), len(missed)


def drawn(edits):
    """Нарисованные руками дороги → записи сети, как из OSM.

    ДОБАВЛЯЮТСЯ в сеть, а не накладываются на неё, и делается это ДО
    генерализации: своя дорога должна пройти ту же разрезку на узлах, склейку и
    упрощение, что и всё остальное. Иначе она ляжет поверх сети, а не внутрь
    неё, и узлов на стыках не появится — маршрут по такой дороге не пройдёт, а
    на схеме она будет тупиком рядом с настоящей улицей.

    Отбрасываем молча только то, что нарисовать нельзя вовсе (нет двух точек).
    Всё остальное — дело ворот: они умеют объяснить, а здесь объяснять некому.
    """
    out = []
    for edit in edits:
        if edit.get("kind") != "geometry":
            continue
        line = edit.get("geom") or []
        if len(line) < 2 or not isinstance(line[0], (list, tuple)):
            continue
        points = []
        for pair in line:
            try:
                points.append((float(pair[0]), float(pair[1])))
            except (TypeError, ValueError, IndexError):
                points = []
                break
        if len(points) < 2:
            continue
        props = edit.get("props") or {}
        code = props.get("cls")
        if code not in CLASS_CODES.values():
            code = 6
        flags = FLAG_HAND_DRAWN
        if props.get("oneway"):
            flags |= FLAG_ONEWAY
        if props.get("bridge"):
            flags |= FLAG_BRIDGE
        if props.get("tunnel"):
            flags |= FLAG_TUNNEL
        lanes = props.get("lanes")
        if isinstance(lanes, int) and lanes >= 1:
            flags = with_lanes(flags, clamp_lanes(code, lanes)) | FLAG_LANES_TAGGED
        else:
            flags = with_lanes(flags, road_lanes({}, code, bool(flags & FLAG_ONEWAY)))
        out.append((code, flags, points, str(props.get("name") or "")))
    return out


# Насколько близко конец нарисованной дороги должен подойти к чужой оси, чтобы
# считаться примкнувшим. Полтора метра: магнит панели сажает конец НА ось, и
# расхождение может дать только округление координат в тайле (1e-5° ≈ 1.1 м).
GRAFT_METERS = 1.5

# Насколько близко чужая дорога должна лежать к нарисованной, чтобы считаться
# заменённой ею. Восемь метров — половина обычной улицы: ближе этого две линии
# на схеме сливаются в одну толстую, и держать обе бессмысленно.
REPLACE_METERS = 8.0
# И какая её доля должна попасть в эту полосу. Половина, а не вся: у чужой
# дороги может быть хвост за пределами перерисованного куска, и требовать
# совпадения целиком значило бы не заменить почти ничего.
REPLACE_SHARE = 0.5


def graft(roads, hand):
    """Врезать концы нарисованных дорог в чужие линии → новая сеть.

    Без этого нарисованное — декорация. Разрезка на перекрёстках работает по
    общим ВЕРШИНАМ, а конец своей дороги упирается в чужую линию посреди
    отрезка, где вершины нет: узел не образуется, маршрут по такой дороге не
    пройдёт, и на схеме она останется тупиком в полуметре от настоящей улицы.

    Поэтому в чужую линию вставляется вершина ровно там, куда пришёл конец.
    Геометрия от этого не меняется — точка и так лежит на отрезке, — меняется
    только топология, ради которой всё и делается.
    """
    if not hand:
        return roads
    ends = []
    for _, _, points, _ in hand:
        ends.append(points[0])
        ends.append(points[-1])

    out = []
    for road in roads:
        code, flags, points, name = road
        patched = list(points)
        for end in ends:
            best_index, best_distance = None, GRAFT_METERS
            for i in range(1, len(patched)):
                a, b = patched[i - 1], patched[i]
                if meters_between(end, a) <= GRAFT_METERS or \
                        meters_between(end, b) <= GRAFT_METERS:
                    best_index = None
                    break  # вершина уже есть — врезать нечего
                candidate = _nearest_on(end, [a, b])
                distance = meters_between(end, candidate)
                if distance < best_distance:
                    best_index, best_distance = i, distance
            if best_index is not None:
                patched.insert(best_index, end)
        out.append((code, flags, patched, name) if len(patched) != len(points) else road)
    return out


def suppress(roads, hand_edits):
    """Убрать чужие дороги, которые перерисовали руками → (сеть, сколько убрано).

    Модератор, поправивший геометрию существующей улицы, ждёт, что на схеме
    останется ОДНА дорога — его. Без этого их будет две: старая из OSM и новая
    поверх неё, в нескольких метрах друг от друга, и водитель увидит на месте
    улицы двойную линию.

    Ищем по МЕСТУ, а не по id: id ведёт в OSM и не переживает воскресной
    пересборки. Заменённой считается дорога, которая больше чем наполовину
    лежит в полосе вокруг нарисованной.
    """
    lines = [e for e in hand_edits
             if e.get("kind") == "geometry" and (e.get("props") or {}).get("replace")]
    if not lines:
        return roads, 0
    shapes = []
    for edit in lines:
        points = []
        for pair in edit.get("geom") or []:
            try:
                points.append((float(pair[0]), float(pair[1])))
            except (TypeError, ValueError, IndexError):
                points = []
                break
        if len(points) >= 2:
            shapes.append(points)
    if not shapes:
        return roads, 0

    kept, dropped = [], 0
    for road in roads:
        points = road[2]
        if not points:
            kept.append(road)
            continue
        replaced = False
        for shape in shapes:
            near = sum(1 for point in points
                       if _point_to_polyline(point, shape) <= REPLACE_METERS)
            if near >= max(2, len(points) * REPLACE_SHARE):
                replaced = True
                break
        if replaced:
            dropped += 1
        else:
            kept.append(road)
    return kept, dropped


def load_edits(path):
    """Снимок правок панели. Нет файла — нет правок, и это не ошибка: сборка
    обязана работать на машине, где панели никогда не было."""
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload.get("items") or []


def build_sidewalks(lines, tolerance_deg):
    """Тротуары как открытые ленты местности.

    Упрощаются грубее дорог и отсеиваются по длине: тротуар объясняет, где
    кончается асфальт, а не где именно повернуть, и лишняя вершина в нём —
    это байты без ответа на вопрос.
    """
    out = []
    for points in lines:
        simplified = simplify(points, tolerance_deg)
        if len(simplified) < 2:
            continue
        if polyline_meters(simplified) < MIN_SIDEWALK_METERS:
            continue
        out.append((AREA_SIDEWALK, 0, simplified))
    return out


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
# Тротуары. Своим набором по тому же закону, что вода и зелень: слой,
# невидимый на текущем охвате, не качается и не разбирается. В центре Ташкента
# их 3 439 — больше, чем всех улиц вместе, и возить их в общем файле значило
# бы удвоить трафик ради слоя, который виден только вблизи.
SET_SIDEWALK = "t"
# Точки. Их ДВА набора, и это не дубль.
#
# Дальше 340 м схема рисует не улицы, а костяк района: раздельные проезжие
# сведены в одну ось, мелочи нет вовсе. Точка, посаженная на детальную
# геометрию, на костяке уехала бы от нарисованной линии на полширины
# проспекта, а перекрёсток, который на костяке один, там дал бы четыре
# пиктограммы — по одной на каждый узел исходной сети.
#
# Поэтому дальний набор считается ЗАНОВО по костяку: свои узлы, своё сведение,
# своя посадка. Ровно тем же приёмом, каким дальняя сеть не является выборкой
# из ближней, а строится отдельно.
SET_POINTS, SET_POINTS_FAR = "p", "q"

# Коды видов местности — контракт с клиентом (SketchArea.Kind).
AREA_WATER, AREA_GREEN, AREA_RAIL, AREA_BLOCK = 1, 2, 3, 4
# Тротуар — тоже «местность», и это не натяжка, а экономия. Он открытая лента,
# как рельсы, и проходит теми же тайлами, той же распаковкой дельт и тем же
# бюджетом. Отдельный конвейер ради ленты, которая ничем не отличается от уже
# работающей, стоил бы больше, чем экономит.
AREA_SIDEWALK = 5
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

# Что считаем тротуаром. Не весь пешеходный highway: steps — лестница, а не
# путь вдоль дороги, и на схеме она была бы обрубком; path — тропа, которая
# может уходить куда угодно. Нужен ровно тот тротуар, что идёт вдоль проезжей
# части и объясняет, где кончается асфальт.
SIDEWALK_HIGHWAYS = {"footway", "pedestrian"}
# Короче этого тротуар — обрубок между двумя перекрёстками, шум на схеме.
MIN_SIDEWALK_METERS = 25.0

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


# Насколько стрелки отступают от конца пути. Двенадцать метров — стоп-линия
# плюс запас: стрелка, нарисованная в самом узле, окажется на перекрёстке, где
# её уже поздно читать.
ARROW_SETBACK_METERS = 12.0


def _step_back(points, meters):
    """Точка на ломаной в стольких метрах от её КОНЦА. None — путь короче."""
    remaining = meters
    for i in range(len(points) - 1, 0, -1):
        a, b = points[i - 1], points[i]
        length = meters_between(a, b)
        if length <= 0:
            continue
        if length >= remaining:
            t = remaining / length
            return (b[0] + (a[0] - b[0]) * t, b[1] + (a[1] - b[1]) * t)
        remaining -= length
    return None


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


# --- Точки: светофоры, лежачие полицейские, стоп-линии ----------------------

# Коды — контракт с клиентом (SketchPoint.Kind). Значения не переставляются:
# установленная сборка читает их как есть, а незнакомый код молча пропускает.
POINT_TRAFFIC_LIGHT, POINT_SPEED_BUMP, POINT_STOP_LINE, POINT_U_TURN = 1, 2, 3, 4
# Пешеходный переход. В OSM их 809 узлами только в центре Ташкента — рисовать
# такое руками было бы повторением ошибки со светофорами (закон 4 плана).
POINT_CROSSING = 5

POINT_TAGS = {("highway", "traffic_signals"): POINT_TRAFFIC_LIGHT,
              ("highway", "stop"): POINT_STOP_LINE,
              ("highway", "crossing"): POINT_CROSSING}

# --- Азимут и ширина в битах записи точки.
#
# Зебра и стоп-линия — это не значок, а ПОПЕРЕЧНАЯ ЧЕРТА. Без азимута она
# ляжет вдоль дороги вместо поперёк, без ширины — не дотянется до кромки или
# вылезет на газон. Оба числа известны в момент посадки точки на ось: дорогу
# мы там и нашли. Возить их отдельными полями записи нельзя по той же причине,
# по какой не поехали пятым элементом полосы, — формат записи фиксирован.
#
# Шаг азимута 3°: поперечная черта ошибки в полтора градуса не показывает, а
# 120 значений влезают в семь бит. Ширина — целыми метрами: на двадцатиметровом
# проспекте это полпроцента, и шесть бит покрывают всё, что вообще бывает.
PFLAG_AZIMUTH_STEP = 3
PFLAG_AZIMUTH_MASK = 0x7F
PFLAG_WIDTH_SHIFT = 7
PFLAG_WIDTH_MASK = 0x3F


def point_flags(azimuth_degrees, width_meters):
    """Упаковать азимут дороги и ширину проезжей части в биты записи точки."""
    steps = int(round((azimuth_degrees % 360) / PFLAG_AZIMUTH_STEP)) % (360 // PFLAG_AZIMUTH_STEP)
    width = max(0, min(PFLAG_WIDTH_MASK, int(round(width_meters))))
    return (steps & PFLAG_AZIMUTH_MASK) | (width << PFLAG_WIDTH_SHIFT)


def point_azimuth(flags):
    """Азимут дороги под точкой, градусы."""
    return (flags & PFLAG_AZIMUTH_MASK) * PFLAG_AZIMUTH_STEP


def point_width(flags):
    """Ширина проезжей части под точкой, метры. 0 — не измерена."""
    return (flags >> PFLAG_WIDTH_SHIFT) & PFLAG_WIDTH_MASK


# --- Стрелки полос.
#
# Единственный слой образца, который на 98 % придётся вводить руками: turn:lanes
# стоит у 163 дорог из 8 455 в центре Ташкента. Поэтому он и последний по
# очереди, а не первый — сначала берём то, что уже лежит в OSM.
POINT_LANE_ARROWS = 6

# Куда можно с полосы. Коды — контракт с клиентом (SketchPoint.LaneTurn).
TURN_NONE, TURN_THROUGH, TURN_LEFT, TURN_RIGHT = 0, 1, 2, 3
TURN_SLIGHT_LEFT, TURN_SLIGHT_RIGHT, TURN_UTURN = 4, 5, 6
TURN_THROUGH_LEFT, TURN_THROUGH_RIGHT, TURN_LEFT_RIGHT = 7, 8, 9

# Разбор одной полосы из turn:lanes. Значение бывает составным («through;left»),
# и порядок в нём не гарантирован — сравниваем множествами.
TURN_SETS = (
    (frozenset({"through", "left"}), TURN_THROUGH_LEFT),
    (frozenset({"through", "right"}), TURN_THROUGH_RIGHT),
    (frozenset({"left", "right"}), TURN_LEFT_RIGHT),
    (frozenset({"through"}), TURN_THROUGH),
    (frozenset({"left"}), TURN_LEFT),
    (frozenset({"right"}), TURN_RIGHT),
    (frozenset({"slight_left"}), TURN_SLIGHT_LEFT),
    (frozenset({"slight_right"}), TURN_SLIGHT_RIGHT),
    (frozenset({"reverse"}), TURN_UTURN),
    (frozenset({"merge_to_left"}), TURN_SLIGHT_LEFT),
    (frozenset({"merge_to_right"}), TURN_SLIGHT_RIGHT),
)

# Биты направлений идут ВЫШЕ азимута и ширины — по четыре на полосу.
#
# Восемь полос, а не пятнадцать: девять стрелок в ряд на экране схемы уже не
# читаются, а место в записи не бесплатно. Итого 13 + 32 = 45 бит — влезает в
# число JSON без потери точности (у double их 53).
PFLAG_TURNS_SHIFT = 13
TURN_BITS = 4
MAX_ARROW_LANES = 8


# Виды, которые НЕ сводятся в один объект.
#
# Светофоры перекрёстка — один объект: их четыре по подъездам, и четыре значка
# в одном пятне это каша. С переходами и стрелками наоборот: их тоже по одному
# на подъезд, но каждый лежит на своей проезжей части и чертится поперёк неё.
# Сведи их — и вместо четырёх зебр выйдет одна посреди перекрёстка.
POINT_NO_CLUSTER = {POINT_CROSSING, POINT_LANE_ARROWS}


def turn_code(value):
    """Код направления одной полосы. Неизвестное — TURN_NONE, а не отказ:
    в turn:lanes встречается что угодно, и терять из-за этого всю дорогу нельзя."""
    parts = frozenset(p.strip() for p in str(value).split(";") if p.strip())
    if not parts:
        return TURN_NONE
    for wanted, code in TURN_SETS:
        if parts == wanted:
            return code
    # Составное значение, которого нет в списке: берём главное направление.
    for single, code in (("through", TURN_THROUGH), ("left", TURN_LEFT),
                         ("right", TURN_RIGHT), ("reverse", TURN_UTURN)):
        if single in parts:
            return code
    return TURN_NONE


def parse_turn_lanes(value):
    """«left|through|through;right» → [2, 1, 8]. Пусто — тега нет или он пуст."""
    if not value:
        return []
    lanes = [turn_code(part) for part in str(value).split("|")]
    return lanes[:MAX_ARROW_LANES]


def pack_turns(flags, lanes):
    """Уложить направления полос в старшие биты записи точки."""
    for index, code in enumerate(lanes[:MAX_ARROW_LANES]):
        flags |= (code & 0xF) << (PFLAG_TURNS_SHIFT + index * TURN_BITS)
    return flags


def unpack_turns(flags, count):
    """Достать направления обратно. count — сколько полос ожидаем."""
    out = []
    for index in range(min(count, MAX_ARROW_LANES)):
        out.append((flags >> (PFLAG_TURNS_SHIFT + index * TURN_BITS)) & 0xF)
    return out
# Что считаем лежачим полицейским. Не весь traffic_calming: «chicane» и
# «choker» это сужение проезжей части, а не то, из-за чего сбрасывают скорость
# в конкретной точке.
CALMING_KINDS = {"bump", "hump", "table", "cushion"}

# Дальше этого от оси — объект не на той дороге, которую мы рисуем.
POINT_SNAP_METERS = 25.0
# Перекрёсток в OSM размечен ПОДЪЕЗДАМИ: с каждой стороны стоит свой светофор.
# На схеме это несколько пиктограмм в одном пятне, то есть каша вместо
# ориентира. Водителю нужен факт «этот перекрёсток со светофором», а не число
# столбов, — поэтому подъезды сводятся в узел графа, а не друг к другу.
#
# Замер по центру Ташкента (4,5 × 5 км, 318 светофоров): расстояние от
# светофора до ближайшего узла со степенью ≥ 3 — 0–10 м у 39, 10–20 у 69,
# 20–30 у 86 (пик — обычный вынос стоп-линии), 30–40 у 33, 40–50 у 25, дальше
# хвост. Излом на пятидесяти: что дальше — это пешеходный переход посреди
# квартала, и он заслуживает СВОЕЙ пиктограммы, а не переезда на перекрёсток.
POINT_JUNCTION_METERS = 50.0
# После привязки остаётся сблизить сами узлы: раздельная проезжая часть даёт
# на одном перекрёстке два узла в десятке метров.
POINT_CLUSTER_METERS = 20.0
# На костяке района сведение работает ИНАЧЕ, и узлы там ни при чём: замер по
# центру Ташкента — у костяка 8 узлов степени ≥ 3 на весь район против 2 498 у
# детальной сети. Костяк не разрезается по перекрёсткам заново, пересечения
# улиц там просто не являются узлами, и привязываться не к чему.
#
# Поэтому дальний набор сводится по расстоянию, и порог — размер настоящего
# городского перекрёстка: 70 м. Всё, что ближе, — один перекрёсток; квартал в
# центре 150–400 м, так что соседние в одну кучу не слипнутся. Замер: 318
# светофоров → 87 значков, в самом плотном кадре на 700 м — 10 штук.
POINT_FAR_CLUSTER_METERS = 70.0
# Виды, которые стоят НА перекрёстке. Лежачий полицейский в этот список не
# входит намеренно: он лежит посреди квартала, и притянуть его к ближайшему
# перекрёстку значило бы соврать ровно о том, ради чего он нарисован.
POINT_AT_JUNCTION = {POINT_TRAFFIC_LIGHT, POINT_STOP_LINE}
# Ячейка поискового индекса, ~1,1 км. Перебор 1 899 точек по 79 000 дорог —
# 150 миллионов расстояний; по сетке это тысячи.
POINT_GRID_DEGREES = 0.01
# Светофор стоит на улице, а не на выезде из двора: класс 7 (service) из
# кандидатов исключён — иначе точка садится на парковочный проезд в паре
# метров от настоящего перекрёстка.
POINT_MAX_CLASS = 6


def point_kind(properties):
    """Вид точечного объекта по тегам. None — не наш слой."""
    for key, value in properties.items():
        code = POINT_TAGS.get((key, value))
        if code is not None:
            return code
    if properties.get("traffic_calming") in CALMING_KINDS:
        return POINT_SPEED_BUMP
    return None


# Обстановка, которую ставят руками. Виды те же, что приезжают из OSM: панель
# заводит объект ТОГО ЖЕ вида, а не параллельный, поэтому дальше он идёт общим
# конвейером — привязка к узлу, сведение, посадка на ось с расчётом азимута и
# ширины. На телефоне не меняется ничего.
DRAWN_POINT_KINDS = {POINT_TRAFFIC_LIGHT, POINT_SPEED_BUMP, POINT_STOP_LINE,
                     POINT_U_TURN, POINT_CROSSING, POINT_LANE_ARROWS}


def drawn_points(edits):
    """Обстановка из правок панели → точки, как из OSM."""
    out = []
    for edit in edits:
        if edit.get("kind") != "point":
            continue
        props = edit.get("props") or {}
        kind = props.get("point")
        if kind not in DRAWN_POINT_KINDS:
            continue
        geom = edit.get("geom") or []
        if len(geom) < 2 or isinstance(geom[0], (list, tuple)):
            continue
        try:
            spot = (float(geom[0]), float(geom[1]))
        except (TypeError, ValueError):
            continue
        flags = 0
        turns = props.get("turns")
        if kind == POINT_LANE_ARROWS and isinstance(turns, list):
            flags = pack_turns(0, [t for t in turns if isinstance(t, int)])
        out.append((kind, flags, [spot]))
    return out


def collect_points(source_path):
    """Прочитать geojsonl узлов → список (kind, flags, [(lon, lat)]).

    Геометрия списком из одной точки, а не голой парой: дальше она проходит
    через те же tile_keys_of, encode и sort_key, что и дороги. Отдельная ветка
    ради одной координаты стоила бы больше, чем лишние скобки.
    """
    points = []
    if not source_path or not os.path.exists(source_path):
        return points
    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            kind = point_kind(feature.get("properties") or {})
            if kind is None:
                continue
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "Point":
                continue
            coordinates = geometry.get("coordinates") or []
            if len(coordinates) < 2:
                continue
            points.append((kind, 0, [(float(coordinates[0]), float(coordinates[1]))]))
    return points


def _cells_of(points, degrees):
    """Ячейки, которых касается ломаная, — вместе с промежуточными.

    Одних вершин мало: на прямом участке трассы соседние вершины отстоят на
    километры, и ячейки между ними остались бы пустыми. Точка, попавшая в
    такую ячейку, не нашла бы дорогу, лежащую прямо под ней.
    """
    keys = set()
    previous = None
    for lon, lat in points:
        keys.add(tile_key(lat, lon, degrees))
        if previous is not None:
            span = max(abs(lat - previous[1]), abs(lon - previous[0]))
            steps = int(span / (degrees / 2))
            for step in range(1, steps + 1):
                t = step / (steps + 1)
                keys.add(tile_key(previous[1] + (lat - previous[1]) * t,
                                  previous[0] + (lon - previous[0]) * t, degrees))
        previous = (lon, lat)
    return keys


def _neighbourhood(point, degrees):
    """Девять ячеек вокруг точки. Ключи те же, что у tile_key."""
    lon, lat = point
    row = int(math.floor((lat + 90) / degrees))
    column = int(math.floor((lon + 180) / degrees))
    return [f"{row + dr}_{column + dc}" for dr in (-1, 0, 1) for dc in (-1, 0, 1)]


def junction_nodes(roads):
    """Узлы графа, где сходятся три линии и больше.

    Считается по КОНЦАМ уже склеенных дорог: после merge_ways проходной узел
    исчез вместе со швом, а остались ровно перекрёстки и тупики. Тупик (одна
    линия) перекрёстком не считается.
    """
    degree = Counter()
    for road in roads:
        degree[_node(road[2][0])] += 1
        degree[_node(road[2][-1])] += 1
    return [(node[1] / SCALE, node[0] / SCALE)
            for node, count in degree.items() if count >= 3]


def attach_to_junctions(points, nodes, meters=POINT_JUNCTION_METERS):
    """Пересадить приперекрёстные точки в узел, к которому они относятся.

    Именно это, а не сведение соседей по радиусу, отвечает на вопрос «сколько
    светофоров рисовать»: четыре подъезда одного перекрёстка сходятся в один
    узел независимо от того, на сколько метров они разнесены, а два соседних
    перекрёстка остаются двумя, как бы близко они ни стояли.

    Побочная выгода: узел лежит РОВНО на пересечении нарисованных линий, то
    есть пиктограмма садится в перекрёсток без всякого магнита.
    """
    cells = defaultdict(list)
    for node in nodes:
        cells[tile_key(node[1], node[0], POINT_GRID_DEGREES)].append(node)

    attached, loose = {}, []
    for kind, flags, geometry in points:
        origin = geometry[0]
        if kind not in POINT_AT_JUNCTION:
            loose.append((kind, flags, geometry))
            continue
        best, best_distance = None, meters
        for key in _neighbourhood(origin, POINT_GRID_DEGREES):
            for node in cells.get(key, ()):
                distance = meters_between(origin, node)
                if distance < best_distance:
                    best, best_distance = node, distance
        if best is None:
            loose.append((kind, flags, geometry))
            continue
        attached[(kind, best)] = (kind, flags, [best])
    return list(attached.values()) + loose


def snap_points(points, roads, meters=POINT_SNAP_METERS):
    """Посадить точки на ось ближайшей улицы → (посаженные, отброшено).

    Садим на ТУ САМУЮ геометрию, которая поедет на телефон, — уже разрезанную,
    склеенную и упрощённую. Светофор, честно снятый с сырого OSM, на схеме
    оказался бы в стороне от нарисованной линии ровно настолько, насколько её
    сдвинуло упрощение, — и висел бы в воздухе рядом с дорогой.

    Не нашедший дороги в радиусе отбрасывается. Это не потеря: такой объект
    стоит у дороги, которую мы не рисуем (тропа, выезд с завода), и на схеме
    он был бы точкой в пустоте.
    """
    streets = [road for road in roads if road[0] <= POINT_MAX_CLASS]
    cells = defaultdict(list)
    for road in streets:
        for key in _cells_of(road[2], POINT_GRID_DEGREES):
            cells[key].append(road)

    snapped, dropped = [], 0
    for kind, flags, geometry in points:
        origin = geometry[0]
        best, best_distance, seen = None, meters, set()
        best_bearing, best_width = 0.0, 0.0
        for key in _neighbourhood(origin, POINT_GRID_DEGREES):
            for road in cells.get(key, ()):
                if id(road) in seen:
                    continue
                seen.add(id(road))
                candidate, bearing = _nearest_segment_on(origin, road[2])
                distance = meters_between(origin, candidate)
                if distance < best_distance:
                    best, best_distance = candidate, distance
                    best_bearing = bearing
                    best_width = road_width_meters(road[0], lanes_of(road[1]))
        if best is None:
            dropped += 1
            continue
        # Азимут и ширину знаем ровно здесь — дорогу мы только что нашли.
        # Дальше по конвейеру она уже не понадобится, и второй раз её никто
        # искать не будет.
        # Азимут и ширину ставим здесь, а всё, что лежит ВЫШЕ них, оставляем
        # как приехало: у стрелок полос там направления, и пересчёт посадки не
        # имеет права их стереть.
        above = flags & ~((1 << PFLAG_TURNS_SHIFT) - 1)
        snapped.append((kind, point_flags(best_bearing, best_width) | above, [best]))
    return snapped, dropped


def cluster_points(points, meters=POINT_CLUSTER_METERS):
    """Свести соседей одного вида в один объект, стоящий в центре скопления.

    Не «первый победил»: на четырёхстороннем перекрёстке противоположные
    светофоры отстоят метров на двадцать пять и в пару не попадают, зато
    каждый попадает в пару с боковым. Правильный ответ — связная компонента:
    всё, что цепляется друг за друга, это один перекрёсток.

    Пиктограмма ставится в ЦЕНТР компоненты, а не на один из подъездов. Центр
    четырёх светофоров — середина перекрёстка, то есть ровно там, где водитель
    их и видит; любой отдельный подъезд сместил бы значок к одной стороне.

    Порядок обхода задан сортировкой, а не порядком строк в экстракте: иначе
    sha256 тайла менялся бы от перестановки строк, и телефоны перекачивали бы
    файл, в котором не изменилось ничего.
    """
    ordered = sorted(points, key=lambda item: (item[0],
                                               round(item[2][0][1] * SCALE),
                                               round(item[2][0][0] * SCALE)))
    cells = defaultdict(list)
    for index, (kind, _, geometry) in enumerate(ordered):
        origin = geometry[0]
        cells[tile_key(origin[1], origin[0], POINT_GRID_DEGREES)].append(index)

    parent = list(range(len(ordered)))

    def root(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    for index, (kind, _, geometry) in enumerate(ordered):
        origin = geometry[0]
        for key in _neighbourhood(origin, POINT_GRID_DEGREES):
            if kind in POINT_NO_CLUSTER:
                continue
            for other in cells.get(key, ()):
                if other <= index or ordered[other][0] != kind:
                    continue
                if meters_between(origin, ordered[other][2][0]) <= meters:
                    a, b = root(index), root(other)
                    if a != b:
                        parent[max(a, b)] = min(a, b)

    groups = defaultdict(list)
    for index in range(len(ordered)):
        groups[root(index)].append(index)

    kept = []
    for head in sorted(groups):
        members = groups[head]
        kind, flags = ordered[head][0], ordered[head][1]
        lons = sorted(ordered[i][2][0][0] for i in members)
        lats = sorted(ordered[i][2][0][1] for i in members)
        centre = (sum(lons) / len(lons), sum(lats) / len(lats))
        kept.append((kind, flags, [centre]))
    return kept


def write_tiles(roads, target_dir, degrees=TILE_DEGREES_V2, areas=(), points=(),
                far_points=(), far=None):
    """Разложить дороги по тайлам и собрать индексы v1 и v2.

    Дорога, задевшая несколько тайлов, попадает в каждый целиком: дубль на
    границе дешевле, чем склейка на клиенте.

    Пишем ОБА формата. Клиент отбрасывает индекс чужой версии обеими точками
    загрузки, то есть выкатить только v2 значило бы оставить все установленные
    сборки без дорог совсем. v1 убирается, когда в проде не останется старых.
    """
    os.makedirs(target_dir, exist_ok=True)
    if far is None:
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
    area_sets = {SET_WATER: [], SET_GREEN: [], SET_RAIL: [], SET_BLOCKS: [],
                 SET_SIDEWALK: []}
    by_code = {AREA_WATER: SET_WATER, AREA_GREEN: SET_GREEN,
               AREA_RAIL: SET_RAIL, AREA_BLOCK: SET_BLOCKS,
               AREA_SIDEWALK: SET_SIDEWALK}
    for kind, flags, shape in areas:
        area_sets[by_code[kind]].append((kind, flags, shape))
    # Кварталы считаются из САМОЙ сети, а не приходят из OSM.
    area_sets[SET_BLOCKS].extend(build_blocks(roads))

    # --- Новый формат: мелкая сетка, файлы по наборам.
    # Ключ индекса — СОСТАВНОЙ: «тайл_набор». Не вложенный словарь, и это
    # ради клиента: у него уже есть разобранный и проверенный индекс вида
    # «ключ → sha256», и плоские ключи ложатся в него без единой правки
    # структуры. Телефон просто просит на три ключа больше.
    sets = split_sets(roads, far)
    sets.update(area_sets)
    # Точки в v1 не попадают намеренно: старый формат один файл на всё, и
    # установленная сборка, не знающая о них, читала бы их как дороги.
    if points:
        sets[SET_POINTS] = list(points)
    if far_points:
        sets[SET_POINTS_FAR] = list(far_points)
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
    parser.add_argument("--points", dest="points", default=None,
                        help="geojsonl узлов: светофоры, лежачие (необязателен)")
    parser.add_argument("--edits", dest="edits", default=None,
                        help="снимок правок панели (необязателен)")
    args = parser.parse_args()

    (raw, classes, flag_counts, read, skipped,
     lanes_tagged, raw_sidewalks, raw_arrows) = collect(args.source)
    edits = load_edits(args.edits)
    # Нарисованное руками добавляется ДО генерализации: своя дорога обязана
    # пройти ту же разрезку на узлах и склейку, что и всё остальное, иначе она
    # ляжет поверх сети, а не внутрь неё, и узлов на стыках не появится.
    hand = drawn(edits)
    # Сначала убираем то, что перерисовали руками: иначе на схеме останутся две
    # дороги — старая из OSM и новая поверх неё в нескольких метрах.
    raw, replaced = suppress(raw, edits)
    # Врезаем концы своих дорог в чужие линии ДО генерализации: разрезка на
    # перекрёстках работает по общим вершинам, а без врезки её там нет.
    roads = generalise(graft(raw, hand) + hand, args.tolerance / 111_320.0)
    # А правки СВОЙСТВ накладываются ПОСЛЕ: они посажены на ту геометрию,
    # которая поедет на телефон, а не на сырую.
    roads, edits_applied, edits_missed = apply_edits(roads, edits)
    # Местность упрощаем грубее дорог: контур пруда не несёт геометрии, по
    # которой принимают решения за рулём.
    areas = collect_areas(args.areas, args.tolerance * 3 / 111_320.0)
    # Тротуары — тоже «местность», и упрощаются так же грубо: их дело —
    # показать, где кончается асфальт, а не где повернуть.
    areas = areas + build_sidewalks(raw_sidewalks, args.tolerance * 3 / 111_320.0)
    # Точки садим ПОСЛЕ генерализации: сажать надо на ту геометрию, которая
    # поедет на телефон, а не на сырую.
    far = build_far(roads)
    raw_points = collect_points(args.points)
    # Стрелки полос — такой же точечный объект, и идут они тем же путём: снап
    # посадит их на нарисованную ось и посчитает азимут с шириной. Направления
    # приезжают в старших битах и посадкой не стираются.
    raw_points = raw_points + [
        (POINT_LANE_ARROWS, pack_turns(0, turns), [spot])
        for spot, turns in raw_arrows] + drawn_points(edits)
    at_junctions = attach_to_junctions(raw_points, junction_nodes(roads))
    clustered = cluster_points(at_junctions)
    points, dropped = snap_points(clustered, roads)
    # Дальний набор: только светофоры. Стоп-знак и лежачий на охвате района —
    # шум: решение по ним принимают, когда они уже видны глазами.
    lights = [p for p in raw_points if p[0] == POINT_TRAFFIC_LIGHT]
    far_points, far_dropped = snap_points(
        cluster_points(lights, POINT_FAR_CLUSTER_METERS), far)
    index, index_v2 = write_tiles(roads, args.tiles_dir, args.grid, areas, points,
                                  far_points, far)

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
              f"рельсы {counts[AREA_RAIL]}, тротуары {counts[AREA_SIDEWALK]}")
    if raw_points:
        kinds = Counter(kind for kind, _, _ in points)
        print(f"точки: прочитано {len(raw_points)}, на перекрёстках "
              f"{len(at_junctions)}, после сведения узлов {len(clustered)}, "
              f"вне дорог {dropped}, в тайлах {len(points)}")
        print(f"        стрелок полос {kinds[POINT_LANE_ARROWS]}")
        print(f"        светофоров {kinds[POINT_TRAFFIC_LIGHT]}, "
              f"лежачих {kinds[POINT_SPEED_BUMP]}, стоп-линий {kinds[POINT_STOP_LINE]}, "
              f"переходов {kinds[POINT_CROSSING]}")
        # Разметка без ширины ляжет чертой в ноль метров, то есть не ляжет
        # вовсе. Молчать об этом нельзя: на схеме это выглядит как «зебры не
        # приехали», а причина — в снапе.
        painted = [p for p in points if p[0] in (POINT_CROSSING, POINT_STOP_LINE)]
        widthless = sum(1 for p in painted if point_width(p[1]) == 0)
        if painted:
            print(f"        разметка: {len(painted)} черт, без ширины {widthless}")
        print(f"        на костяке района: {len(far_points)} светофоров "
              f"(вне костяка {far_dropped})")
    print("классы:", classes.most_common(10))
    bridges = sum(n for f, n in flag_counts.items() if f & FLAG_BRIDGE)
    tunnels = sum(n for f, n in flag_counts.items() if f & FLAG_TUNNEL)
    oneways = sum(n for f, n in flag_counts.items() if f & FLAG_ONEWAY)
    print(f"односторонних: {oneways}, мостов: {bridges}, тоннелей: {tunnels}")
    for label, group in (("сеть", roads), ("костяк", far)):
        if not group:
            continue
        widths = sorted(road_width_meters(r[0], lanes_of(r[1])) for r in group)
        widest = max(group, key=lambda r: road_width_meters(r[0], lanes_of(r[1])))
        print(f"{label}: полос от {lanes_of(min(group, key=lambda r: lanes_of(r[1]))[1])} "
              f"до {lanes_of(widest[1])}, ширина проезжей части "
              f"{widths[0]:.1f}–{widths[-1]:.1f} м "
              f"(медиана {widths[len(widths) // 2]:.1f})")
    if edits_applied or edits_missed or hand:
        print(f"правки панели: наложено {edits_applied}, "
              f"не нашли дороги {edits_missed}, нарисовано руками {len(hand)}, "
              f"заменено чужих {replaced}")
    share = 100.0 * lanes_tagged / read if read else 0.0
    print(f"полосы: тегом {lanes_tagged} из {read} ({share:.1f} %), "
          f"остальным по классу")
    return 0


if __name__ == "__main__":
    sys.exit(main())
