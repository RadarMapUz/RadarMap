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
import shutil
import sys
from collections import Counter, OrderedDict, defaultdict

import surface_check

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
# Допуск упрощения для ПОДРОБНЫХ наборов.
#
# Было четыре метра, и это ломало дороги ровно там, где на них смотрят. Замер
# на 400 улицах центра: при четырёх метрах отклонение от настоящей оси —
# медиана 2,4 м, худшее 4,0 м. На виде вблизи (100 метров на высоту экрана
# телефона) метр это восемь пунктов, то есть кривая уезжала от дороги на
# двадцать пунктов, а в худшем случае на тридцать четыре — при ширине полотна
# около шестидесяти. Отсюда «ломаные дороги»: прямая улица шла зигзагом, а
# полотно, построенное по этой же оси, повторяло зигзаг краями.
#
# Один метр даёт медиану 0,65 м — меньше шести пунктов, то есть меньше
# толщины разметки. Замерено и по весу: тайлы прибавляют 8 %, а не 40, как
# я боялся — лишние вершины на прямой кодируются дельтами почти в ноль.
SIMPLIFY_METERS = 1.0
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
    """Убрать ХВОСТЫ короче порога — но не перемычки.

    Обрубок — это кусок, у которого хотя бы один конец ни к чему не примыкает:
    остаток геометрии после разреза, подъездной аппендикс, дрожь мыши. Кусок,
    у которого ОБА конца лежат в узлах сети, — это перемычка, и короткая она по
    делу: кусок проспекта между двумя примыканиями, съезд с развязки, вставка
    между разделёнными проезжими.

    Пока правило было «короче двадцати метров — вон», такие перемычки
    удалялись, и на их месте оставалась ДЫРА ПОСРЕДИ УЛИЦЫ. Именно она и
    читалась как «дороги сломанные» — на любой отрисовке, потому что чинить
    рисование бессмысленно, когда куска нет в данных.

    Замерено на боевых тайлах в круге 600 метров вокруг перекрёстка Фурката и
    Ислама Каримова: 16 разрывов на улицах класса «проспект» и «жилая»,
    величина 3,7–47 метров, медиана 15,2 — то есть ровно под порогом. Среди
    порванных: Фурката (дважды), Ислама Каримова, Бунёдкор, Ќоратош.
    """
    degree = Counter()
    for road in roads:
        points = road[2]
        degree[_node(points[0])] += 1
        degree[_node(points[-1])] += 1
    kept = []
    for road in roads:
        if polyline_meters(road[2]) >= meters:
            kept.append(road)
            continue
        first, last = _node(road[2][0]), _node(road[2][-1])
        # Оба конца делятся с кем-то ещё — перемычка. Удалить её значит
        # разорвать улицу, а не убрать обрубок.
        if degree[first] > 1 and degree[last] > 1:
            kept.append(road)
    return kept


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


def _midpoint(points):
    """Середина линии ПО ДЛИНЕ, а не по номеру вершины.

    Разница не косметическая: у линии из двух точек «вершина посередине» — это
    её конец, а концы у дорог на перекрёстке общие. Опора, поставленная в
    общий конец, указывала бы сразу на несколько дорог.
    """
    if len(points) < 2:
        return points[0] if points else None
    spans = []
    total = 0.0
    for i in range(1, len(points)):
        a, b = points[i - 1], points[i]
        lon_scale = math.cos(math.radians(a[1]))
        step = math.hypot((b[0] - a[0]) * lon_scale, b[1] - a[1])
        spans.append(step)
        total += step
    if total <= 0:
        return points[0]
    walked = 0.0
    half = total / 2
    for i, step in enumerate(spans):
        if walked + step >= half and step > 0:
            share = (half - walked) / step
            a, b = points[i], points[i + 1]
            return (a[0] + (b[0] - a[0]) * share, a[1] + (b[1] - a[1]) * share)
        walked += step
    return points[-1]


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


def tile_box_of(key, degrees=TILE_DEGREES):
    """Кусок земли тайла по его ключу → (юг, запад, север, восток)."""
    row, column = (int(part) for part in key.split("_"))
    south = row * degrees - 90
    west = column * degrees - 180
    return (south, west, south + degrees, west + degrees)


def clip_ring(points, box, margin):
    """Обрезать замкнутое кольцо по прямоугольнику тайла. Сазерленд — Ходжман.

    Раньше объект, задевший несколько тайлов, попадал в каждый ЦЕЛИКОМ: «дубль
    на границе дешевле, чем склейка на клиенте». Для улицы это верно — у неё
    десяток вершин. Для озера это неверно на два порядка.

    Замерено на боевом экстракте: озеро Хайдаркуль после упрощения — 12 734
    вершины и 103 тайла, то есть 1,3 миллиона копий вершин ради одного
    объекта. Все крупные кольца страны вместе дают 2,4 миллиона копий: тайл у
    берега вёз 180 КБ контура, которого на нём не видно.

    Отсечение выпуклым прямоугольником — ровно тот случай, где Сазерленд —
    Ходжман точен и не требует ничего сверх четырёх проходов.
    """
    south, west, north, east = box
    south -= margin; west -= margin; north += margin; east += margin
    edges = (
        lambda p: p[0] >= west,   # слева
        lambda p: p[0] <= east,
        lambda p: p[1] >= south,
        lambda p: p[1] <= north,
    )
    cuts = (
        lambda a, bb: _cross_x(a, bb, west),
        lambda a, bb: _cross_x(a, bb, east),
        lambda a, bb: _cross_y(a, bb, south),
        lambda a, bb: _cross_y(a, bb, north),
    )
    out = list(points)
    if out and out[0] == out[-1]:
        out = out[:-1]
    for inside, cut in zip(edges, cuts):
        if not out:
            return []
        clipped = []
        for i, point in enumerate(out):
            before = out[i - 1]
            if inside(point):
                if not inside(before):
                    clipped.append(cut(before, point))
                clipped.append(point)
            elif inside(before):
                clipped.append(cut(before, point))
        out = clipped
    if len(out) < 3:
        return []
    out.append(out[0])
    return out


def clip_line(points, box, margin):
    """Обрезать НЕЗАМКНУТУЮ ломаную по тайлу → список кусков.

    Кусков может быть несколько: река входит в тайл, выходит и возвращается.
    Склеивать их обратно нельзя — получилась бы хорда через чужую землю.
    """
    south, west, north, east = box
    south -= margin; west -= margin; north += margin; east += margin
    inside = lambda p: west <= p[0] <= east and south <= p[1] <= north
    out, piece = [], []
    for i in range(1, len(points)):
        part = _clip_segment(points[i - 1], points[i], south, west, north, east)
        if part is None:
            if len(piece) > 1:
                out.append(piece)
            piece = []
            continue
        start, end = part
        if not piece:
            piece = [start, end]
        elif piece[-1] == start:
            piece.append(end)
        else:
            if len(piece) > 1:
                out.append(piece)
            piece = [start, end]
    if len(piece) > 1:
        out.append(piece)
    return out


def _cross_x(one, two, x):
    share = (x - one[0]) / (two[0] - one[0]) if two[0] != one[0] else 0.0
    return (x, one[1] + (two[1] - one[1]) * share)


def _cross_y(one, two, y):
    share = (y - one[1]) / (two[1] - one[1]) if two[1] != one[1] else 0.0
    return (one[0] + (two[0] - one[0]) * share, y)


def _clip_segment(one, two, south, west, north, east):
    """Отрезок внутри рамки → (начало, конец). None — не задевает."""
    dx, dy = two[0] - one[0], two[1] - one[1]
    low, high = 0.0, 1.0
    for edge, delta in ((west - one[0], dx), (one[0] - east, -dx),
                        (south - one[1], dy), (one[1] - north, -dy)):
        if delta == 0:
            if edge > 0:
                return None
            continue
        step = edge / delta
        if delta > 0:
            if step > high:
                return None
            low = max(low, step)
        else:
            if step < low:
                return None
            high = min(high, step)
    if low > high:
        return None
    return ((one[0] + dx * low, one[1] + dy * low),
            (one[0] + dx * high, one[1] + dy * high))


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
    rings = set()        # подписи колец из многоугольников
    orphans = []         # замкнутые линии: решим в конце, есть ли у них двойник
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
            # Замкнутая линия — обычно второе тело площади, и её мы отбрасываем
            # (иначе площадь легла бы в тайл дважды). Но «обычно» это не
            # «всегда»: у одной-двух записей из тридцати восьми тысяч
            # многоугольника-двойника нет вовсе, и такая линия — единственное
            # тело объекта. Ворота публикации поймали ровно этот случай: из
            # тайла 2615_4994 пропал пруд, у которого был только линейный вид.
            #
            # Поэтому замкнутые линии откладываем и в конце добавляем те, чьей
            # подписи нет среди колец.
            for closed, points in _shapes_of(geometry):
                if closed:
                    rings.add(_ring_signature(points))
                out = _kept_area(kind, closed, points, tolerance_deg)
                if out is not None:
                    areas.append(out)
            if geometry.get("type") == "LineString":
                coordinates = geometry.get("coordinates") or []
                if len(coordinates) > 2 and coordinates[0] == coordinates[-1]:
                    orphans.append((kind, [tuple(p[:2]) for p in coordinates]))

    for kind, points in orphans:
        if _ring_signature(points) in rings:
            continue
        out = _kept_area(kind, True, points, tolerance_deg)
        if out is not None:
            areas.append(out)
    return areas


def _kept_area(kind, closed, points, tolerance_deg):
    """Упростить и отсеять мелочь. None — объект не доехал."""
    if len(points) < (3 if closed else 2):
        return None
    points = simplify(points, tolerance_deg)
    if len(points) < (3 if closed else 2):
        return None
    if extent_meters(points) < MIN_AREA_METERS:
        return None
    return (kind, AREA_FLAG_CLOSED if closed else 0, points)


def _ring_signature(points):
    """Подпись кольца: рамка и число вершин.

    Замерено на боевом экстракте: 38 703 различных кольца и 37 759 замкнутых
    линий, и по этой подписи они сходятся все, кроме двух. Считается по СЫРЫМ
    координатам — упрощение у двойников одно и то же, но сравнивать надёжнее
    до него.
    """
    lons = [point[0] for point in points]
    lats = [point[1] for point in points]
    return (round(min(lons), 6), round(min(lats), 6),
            round(max(lons), 6), round(max(lats), 6), len(points))


def _shapes_of(geometry):
    """Геометрия osmium → список (замкнуто, точки).

    Osmium НЕ пишет «Polygon». Площадь у него всегда MultiPolygon, даже когда
    контур один: внутри его модели площадь — это мультиполигон по определению.
    Разбор искал «Polygon», не находил и уходил в `continue` — то есть каждая
    площадь молча выбрасывалась.

    Уцелевало от неё второе тело: то же замкнутое кольцо osmium пишет ЕЩЁ РАЗ
    как LineString, геометрией самой линии. Его мы и клали в тайл — без бита
    замыкания. Парки и пруды приезжали на панель контуром вместо заливки, и
    это было не «старые тайлы», а потеря на разборе.

    Замерено на боевом экстракте (300 тысяч записей):

        колец из многоугольников   38 755, различных 38 703
        замкнутых линий            37 761, различных 37 759
        линий без кольца-двойника  2
        колец без линии-двойника   946   ← это и терялось целиком

    Отсюда правило: площадь берём из многоугольника, линию — только НЕЗАМКНУТУЮ.
    Оно теряет две записи из тридцати восьми тысяч и возвращает 946 площадей,
    которых на карте не было вовсе: это площади-отношения — большие парки и
    озёра с островами, у которых своей линии нет.

    Дырки (внутренние кольца) пропускаем: в записи тайла лежит ОДНО кольцо, и
    пруд внутри парка рисуется своим объектом набора воды поверх зелени.
    """
    shape = geometry.get("type")
    coordinates = geometry.get("coordinates") or []
    if shape == "MultiPolygon":
        return [(True, polygon[0]) for polygon in coordinates
                if polygon and polygon[0]]
    if shape == "Polygon":
        return [(True, coordinates[0])] if coordinates and coordinates[0] else []
    if shape == "LineString":
        if len(coordinates) > 2 and coordinates[0] == coordinates[-1]:
            # Второе тело площади. Кольцо приедет многоугольником.
            return []
        return [(False, coordinates)]
    return []


def collect_houses(source_path, tolerance_deg, floor=None):
    """Прочитать geojsonl зданий → тот же список (kind, flags, points).

    Отдельной функцией от местности, и не ради порядка: у домов другая цена.
    В одном кадре центра их 54 094 против семисот дорог, то есть слой домов
    один весит больше, чем вся остальная схема. Поэтому здесь свой порог
    размера и своё, более грубое упрощение — замерено: при упрощении в четыре
    метра и пороге в десять центр Ташкента укладывается в 3 МБ вместо 4,2.

    Дом за рулём отвечает на один вопрос — «мне вот сюда сворачивать?», — и
    на него отвечает пятно нужного размера в нужном месте, а не точный контур
    крыльца. Но упрощать его дорожным допуском нельзя: дорога длиной в
    километр не замечает двенадцати метров сглаживания, а дом сам шириной в
    десять — см. HOUSE_SIMPLIFY_METERS.
    """
    houses = []
    if floor is None:
        floor = MIN_HOUSE_METERS
    if not source_path or not os.path.exists(source_path):
        return houses
    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            geometry = feature.get("geometry") or {}
            # Osmium пишет площадь как MultiPolygon — см. _shapes_of. Третье
            # место с этой же проверкой; первые два молча теряли всю зелень и
            # все дома страны.
            shapes = [pts for closed, pts in _shapes_of(geometry) if closed]
            if not shapes:
                continue
            points = shapes[0]
            if len(points) < 4:
                continue
            points = simplify(points, tolerance_deg)
            # После упрощения контур обязан остаться контуром: три точки и
            # замыкание — минимум, ниже которого это уже не пятно.
            if len(points) < 4:
                continue
            if extent_meters(points) < floor:
                continue
            houses.append((AREA_HOUSE, AREA_FLAG_CLOSED, points))
    return houses


# --- Адреса -----------------------------------------------------------------
#
# Отдельным файлом на город, а НЕ тайлом, и это не прихоть раскладки. Поиск
# адреса идёт по всему городу сразу: человек ищет то место, куда ещё не
# приехал, — тайловая окрестность отвечала бы только про то, где он уже стоит.
#
# Зачем это вообще, если поиск в приложении и так работает: он работает по
# сети, через Apple. В роуминге, в подвале парковки, в тоннеле и на краю
# покрытия «Куда» просто перестаёт существовать. Свой индекс работает всегда.
#
# Потолок назван честно и замерен: в кадре центра Ташкента 18 755 объектов с
# адресом при 54 094 домах. Треть. Остальное так и останется за Apple, и
# порядок источников это учитывает.
SET_ADDRESSES = "a"

# Сетка адресов — КРУПНАЯ, 0.5°, та же, что у старого формата тайлов. Полградуса
# это полсотни километров: город целиком в одной клетке, и поиск по нему не
# требует собирать десяток файлов.
ADDRESS_DEGREES = TILE_DEGREES


def address_key(lat, lon):
    return tile_key(lat, lon, ADDRESS_DEGREES)


def collect_addresses(source_path):
    """Прочитать geojsonl с адресами → [(улица, номер, lon, lat)].

    Берём и точки, и контуры: в OSM адрес живёт и тем, и другим — в кадре
    центра Ташкента 17 153 контура против 1 517 точек. У контура берём
    середину рамки: подъезд нам неизвестен, а середина дома — честный ответ на
    «куда ехать».

    Без улицы адрес бесполезен: «дом 12» без названия не найти и не показать.
    """
    out = []
    if not source_path or not os.path.exists(source_path):
        return out
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
            street = (properties.get("addr:street") or "").strip()
            number = (properties.get("addr:housenumber") or "").strip()
            if not street or not number:
                continue
            spot = feature_center(feature.get("geometry") or {})
            if spot is None:
                continue
            out.append((street, number, spot[0], spot[1]))
    return out


def feature_center(geometry):
    """Середина рамки объекта. None — геометрии нет или она не наша."""
    shape = geometry.get("type")
    coords = geometry.get("coordinates")
    if shape == "Point" and isinstance(coords, (list, tuple)) and len(coords) >= 2:
        try:
            return float(coords[0]), float(coords[1])
        except (TypeError, ValueError):
            return None
    if shape == "MultiPolygon":
        # Адрес чаще всего висит на КОНТУРЕ здания, а контур приезжает
        # многоугольником. Без этой ветки адресный индекс терял ровно те
        # объекты, ради которых он и заводился.
        points = []
        for polygon in coords or []:
            if polygon and polygon[0]:
                points.extend(polygon[0])
    elif shape == "Polygon":
        rings = coords or []
        points = rings[0] if rings else []
    elif shape == "LineString":
        points = coords or []
    else:
        return None
    good = [p for p in points
            if isinstance(p, (list, tuple)) and len(p) >= 2]
    if not good:
        return None
    try:
        lons = [float(p[0]) for p in good]
        lats = [float(p[1]) for p in good]
    except (TypeError, ValueError):
        return None
    return (min(lons) + max(lons)) / 2, (min(lats) + max(lats)) / 2


def addresses_by_cell(rows):
    """Адреса → {ключ клетки: полезная нагрузка файла}.

    Внутри клетки группируем ПО УЛИЦЕ: название улицы повторяется у каждого
    дома, а улиц в городе тысячи против десятков тысяч домов. Координаты —
    целыми 1e-5° и дельтами вдоль улицы, ровно как в тайлах: второй способ
    паковать координаты в одном проекте — это второй способ ошибиться.
    """
    cells = {}
    for street, number, lon, lat in rows:
        key = address_key(lat, lon)
        cells.setdefault(key, {}).setdefault(street, []).append((number, lon, lat))
    out = {}
    for key, streets in cells.items():
        packed = []
        for street in sorted(streets):
            houses = sorted(streets[street], key=lambda h: (h[2], h[1]))
            numbers, points = [], []
            previous_lat = previous_lon = None
            for number, lon, lat in houses:
                ilat, ilon = round(lat * SCALE), round(lon * SCALE)
                if previous_lat is None:
                    points.extend((ilat, ilon))
                else:
                    points.extend((ilat - previous_lat, ilon - previous_lon))
                previous_lat, previous_lon = ilat, ilon
                numbers.append(number)
            packed.append({"n": street, "h": numbers, "p": points})
        out[key] = {"version": 1, "streets": packed}
    return out


def stream_houses(source_path, target_dir, degrees, tolerance_deg=None,
                  floor=None, handles=64):
    """Разложить дома по тайлам ПОТОКОМ, не держа их в памяти.

    Дома — единственный слой, который в память не влезает. Замерено: в одном
    кадре центра Ташкента их 54 094 при семистах дорогах; по стране это
    миллионы контуров, а на сервере 2 ГБ памяти, из которых свободен один, и
    рядом работают API и панель. Собранный списком слой убил бы их обоих.

    Поэтому дом проходит путь «прочитал — упростил — дописал в файл своего
    тайла» и больше нигде не задерживается. В памяти одновременно живут один
    контур и до `handles` открытых файлов.

    Открытых файлов немного и это не жадность: экстракт идёт примерно по
    порядку обхода земли, поэтому соседние дома попадают в те же тайлы, и
    вытеснение по редкому использованию почти не срабатывает.

    Возвращает {ключ тайла: записи} — уже посчитанные строки индекса, чтобы
    write_tiles не пересобирал их заново.
    """
    if tolerance_deg is None:
        tolerance_deg = HOUSE_SIMPLIFY_METERS / 111_320.0
    if floor is None:
        floor = MIN_HOUSE_METERS
    if not source_path or not os.path.exists(source_path):
        return {}

    work = os.path.join(target_dir, "_houses")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    open_files = OrderedDict()
    keys = set()

    def sink(key):
        handle = open_files.get(key)
        if handle is not None:
            open_files.move_to_end(key)
            return handle
        while len(open_files) >= handles:
            open_files.popitem(last=False)[1].close()
        handle = open(os.path.join(work, key + ".jsonl"), "a", encoding="utf-8")
        open_files[key] = handle
        keys.add(key)
        return handle

    try:
        with open(source_path, encoding="utf-8") as source:
            for line in source:
                line = line.lstrip("\x1e").strip()
                if not line:
                    continue
                try:
                    feature = json.loads(line)
                except ValueError:
                    continue
                # Osmium НЕ пишет «Polygon». Здесь стояла ровно та же
                # проверка, что и в collect_areas, и с тем же исходом:
                # на боевом экстракте 100 % домов — MultiPolygon, то есть
                # ВСЕ 1 653 195 домов страны выбрасывались молча. В отчёте
                # сборки строки «дома:» просто не было, и понять, что слой
                # потерян, можно было только по её отсутствию.
                geometry = feature.get("geometry") or {}
                levels = house_levels(feature.get("properties") or {})
                flags = AREA_FLAG_CLOSED | (levels << HOUSE_LEVELS_SHIFT)
                for closed, points in _shapes_of(geometry):
                    # Дом — площадь. Незамкнутая линия здесь — это забор или
                    # второе тело того же контура; ни то, ни другое не дом.
                    if not closed or len(points) < 4:
                        continue
                    points = simplify(points, tolerance_deg)
                    if len(points) < 4 or extent_meters(points) < floor:
                        continue
                    record = [AREA_HOUSE, flags, encode(points)]
                    row = json.dumps(record, separators=(",", ":"))
                    for key in tile_keys_of(points, degrees):
                        sink(key).write(row + "\n")
    finally:
        for handle in open_files.values():
            handle.close()

    written = flush_streamed(work, keys, target_dir, SET_HOUSES)
    shutil.rmtree(work, ignore_errors=True)
    return written


def flush_streamed(work, keys, target_dir, set_name):
    """Дописать разложенное по временным файлам в готовые тайлы.

    Возвращает ТОЛЬКО записи индекса, а не строки. Разница не косметическая:
    раньше здесь собирался словарь «ключ → все строки тайла», то есть слой
    целиком всё-таки оказывался в памяти — потоковой раскладка была лишь до
    этого места. На стране это 1 653 195 домов, и сборку убило ядро (Killed на
    шаге 3/4 при 604 522 дорогах и полутора гигабайтах свободных).

    Теперь тайл пишется на диск сразу, и в памяти одновременно живут строки
    ОДНОГО тайла.
    """
    index = {}
    for key in sorted(keys):
        path = os.path.join(work, key + ".jsonl")
        rows = []
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
        if not rows:
            continue
        # Порядок внутри тайла УСТОЙЧИВЫЙ. Недетерминированная сборка меняет
        # sha256 всех тайлов каждую неделю, и каждый телефон перекачивает свои
        # файлы впустую — при том что в данных не изменилось ничего.
        rows.sort(key=lambda row: (row[0], row[1], row[2][0], row[2][1],
                                   len(row[2])))
        blob = json.dumps({"version": 2, "roads": rows},
                          separators=(",", ":")).encode()
        composite = f"{key}_{set_name}"
        with open(os.path.join(target_dir, f"road2_{composite}.json"), "wb") as out:
            out.write(blob)
        index[composite] = {"sha256": hashlib.sha256(blob).hexdigest(),
                            "bytes": len(blob)}
        rows.clear()
    return index


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
    # Опора для панели: id дороги в OSM и место, где она была на этой сборке.
    #
    # Собирается ИЗ СЫРОГО экстракта, до склейки и упрощения, и только здесь
    # это возможно: после склейки «дорога» — несколько способов OSM, сведённых
    # в одну линию, и одного id у неё уже нет.
    identities = []
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
            osm_id = feature.get("id")
            if isinstance(osm_id, str) and osm_id:
                middle = _midpoint(points)
                identities.append((osm_id, float(middle[0]), float(middle[1]),
                                   round(_bearing(points), 1), code))
            classes[properties["highway"]] += 1
            flag_counts[roads[-1][1]] += 1

    return (roads, classes, flag_counts, read, skipped, lanes_tagged,
            sidewalks, arrows, identities)


def write_identities(identities, target_dir):
    """Опора правок: id дороги в OSM → где она была на этой сборке.

    Файлы кладутся РЯДОМ с тайлами, но НЕ в индекс — и это разница по
    существу. Индекс подписывает владелец, и подпись накрывает то, что едет на
    телефоны; сюда телефон не ходит никогда, потому что ключа в индексе нет, а
    окрестность просит только известные наборы. Читает эти файлы одна панель.

    Плата названа прямо: файл вне индекса — значит вне подписи. Тот, кто может
    его переписать, может сбить привязку правок, но не подсунуть телефонам
    геометрию. Это ровно та граница, ради которой ключ подписи лежит у
    владельца.
    """
    cells = {}
    for osm_id, lon, lat, bearing, code in identities:
        cells.setdefault(address_key(lat, lon), []).append(
            [osm_id, round(lat * SCALE), round(lon * SCALE), bearing, code])
    for key, rows in sorted(cells.items()):
        rows.sort()
        path = os.path.join(target_dir, f"ids_{key}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "roads": rows}, handle,
                      separators=(",", ":"), ensure_ascii=False)
    return len(cells)


# --- Поверхность дороги -----------------------------------------------------
#
# Сеть остаётся сетью. Куски, разрезанные по перекрёсткам, — это ГРАФ: по нему
# работают магнит, привязка правок, поиск ближайшей дороги и весь конструктор.
# Их никто не трогает.
#
# Поверхность — ОТДЕЛЬНЫЙ, производный слой: контур полотна, площадь
# перекрёстка, фаска подхода. Он считается из той же сети раз в неделю и
# кладётся в тайл готовой геометрией, потому что это ГЕОМЕТРИЯ, а не
# отрисовка: она не зависит от зума и не меняется, пока не пересобраны тайлы.
#
# Считать её в браузере на каждое движение карты неверно в любом движке — и в
# canvas, и в WebGL. Здесь она считается один раз.


def street_key(road):
    """Что делает два куска одной улицей.

    Имя и класс — мало: «Мустакиллик» есть в каждом районе. Ключ только
    группирует кандидатов; решает совпадение концов (см. merge_streets).

    Характер тоже в ключе: односторонняя и встречная ей — РАЗНЫЕ улицы, и
    склеивать их в одну ленту значило бы нарисовать одну проезжую часть там,
    где их две.
    """
    code, flags = road[0], road[1]
    name = road[3] if len(road) > 3 else ""
    return (code, name,
            bool(flags & FLAG_ONEWAY),
            bool(flags & FLAG_BRIDGE),
            bool(flags & FLAG_TUNNEL))


def street_width(pieces):
    """Одна ширина на улицу.

    Измеренная побеждает классовую, и из измеренных берётся НАИБОЛЬШАЯ:
    проспект не сужается на треть посреди квартала. Замерено на живом кадре —
    у всех восьми улиц центра в одном кадре по две-три разные ширины, и
    рисовались они пятнадцатью кусками встык.
    """
    measured = [p for p in pieces if p[1] & FLAG_LANES_TAGGED and lanes_of(p[1])]
    source = measured or pieces
    return max(road_width_meters(p[0], lanes_of(p[1])) for p in source)


def merge_streets(roads):
    """Куски → улицы. [(код, биты, точки, имя, ширина, измерена)]"""
    return [street for street, _chain in street_chains(roads)]


def street_chains(roads):
    """То же самое, но вместе с кусками, из которых улица собрана.

    Куски нужны перекрёсткам: узел сети живёт на СТЫКЕ кусков, а не на концах
    улицы, — улица через перекрёсток проходит насквозь. Сеть остаётся сетью.

    Склеиваем только те, у которых КОНЕЦ одного совпадает с началом другого:
    совпавшего имени мало. Порядок обхода устойчив — от него зависит sha256
    тайлов, а недетерминированная сборка заставляет каждый телефон
    перекачивать свои файлы впустую.
    """
    groups = {}
    for road in roads:
        groups.setdefault(street_key(road), []).append(road)

    streets = []
    for key in sorted(groups, key=lambda k: (k[0], k[1], k[2], k[3], k[4])):
        pieces = sorted(groups[key], key=sort_key)
        used = [False] * len(pieces)
        # Кто где кончается — СЛОВАРЁМ, а не перебором.
        #
        # Перебор всех кусков группы на каждый шаг ленты квадратичен, и
        # замерено это до выката, а не после: 1000 дорог — 0,04 с, 8000 — 3,1 с,
        # то есть удвоение данных стоит вчетверо времени. Самая большая группа
        # склейки — 4295 безымянных кусков; на стране такая сборка не кончилась
        # бы за ночь и повесила бы еженедельную пересборку.
        at_spot = defaultdict(list)
        for other, piece in enumerate(pieces):
            line = piece[2]
            for end in (line[0], line[-1]):
                at_spot[_spot_bucket(end)].append(other)
        for index, first in enumerate(pieces):
            if used[index]:
                continue
            used[index] = True
            points = list(first[2])
            chain = [first]
            grew = True
            while grew:
                grew = False
                # На конце улицы может сойтись НЕСКОЛЬКО её же кусков: ответвление
                # с тем же именем, встречная петля, съезд. Брать первый
                # попавшийся нельзя — лента уходила бы в отросток и обрывалась,
                # а прямое продолжение оставалось отдельной лентой.
                #
                # Берём самое ПРЯМОЕ продолжение и отказываемся от поворота
                # круче MAX_MERGE_TURN: улица не разворачивается на себя в узле.
                for at_tail in (True, False):
                    best, best_turn, best_line = None, None, None
                    edge = points[-1] if at_tail else points[0]
                    inner = points[-2] if at_tail else points[1]
                    for other in _near_spot(at_spot, edge):
                        if used[other]:
                            continue
                        line = pieces[other][2]
                        if _same_spot(edge, line[0]):
                            forward = list(line)
                        elif _same_spot(edge, line[-1]):
                            forward = list(reversed(line))
                        else:
                            continue
                        if len(forward) < 2:
                            continue
                        turn = _turn_between(inner, edge, forward[1])
                        if turn > MAX_MERGE_TURN:
                            continue
                        if best_turn is None or turn < best_turn:
                            best, best_turn, best_line = other, turn, forward
                    if best is None:
                        continue
                    if at_tail:
                        points.extend(best_line[1:])
                    else:
                        points = list(reversed(best_line))[:-1] + points
                    used[best] = True
                    chain.append(pieces[best])
                    grew = True
            width = street_width(chain)
            streets.append(((key[0], first[1], points, key[1],
                             round(width, 1),
                             any(p[1] & FLAG_LANES_TAGGED for p in chain)),
                            chain))
    return fit_carriageways(streets)


# Встречные ленты проспекта обязаны оставлять между кромками разделительную.
#
# Ширину ленты мы чаще всего УГАДЫВАЕМ по классу (полосы тегом — у 1,4 %
# дорог страны), и у проспекта две угаданные ленты по 10–14 м накрывали
# расстояние между своими осями: вместо двух проезжих с разделительной на
# карте была одна сплошная серая лента (Навои × Рашидов, 27.09.2026). Оси в
# OSM рисуют по середине проезжих, и расстояние между ними — измерение, а
# ширина по классу — догадка; при споре правее измерение.
CARRIAGEWAY_MIN_GAP_METERS = 1.5
CARRIAGEWAY_MIN_WIDTH_METERS = 3.5
CARRIAGEWAY_MIN_SAMPLES = 3


def carriageway_gap(one, other):
    """Типичное расстояние между осями встречных лент (медиана по шагам), или None."""
    gaps = []
    for spot, _segment in _walk(one, MEDIAN_STEP_METERS):
        near, gap, _along = _nearest_along(spot, other)
        if near is not None and 2.0 <= gap <= MEDIAN_MAX_METERS:
            gaps.append(gap)
    if len(gaps) < CARRIAGEWAY_MIN_SAMPLES:
        return None
    gaps.sort()
    return gaps[len(gaps) // 2]


def fit_carriageways(streets):
    """Сузить встречные ленты одной улицы так, чтобы разделительная была видна."""
    groups = {}
    for index, (street, _chain) in enumerate(streets):
        if street[3] and street[1] & FLAG_ONEWAY and len(street[2]) >= 2:
            groups.setdefault((street[0], street[3]), []).append(index)
    caps = {}
    for key in sorted(groups):
        members = groups[key]
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                a, b = streets[members[i]][0], streets[members[j]][0]
                if not _near_boxes(a[2], b[2], MEDIAN_MAX_METERS):
                    continue
                if not _opposite(a[2], b[2]):
                    continue
                gap = carriageway_gap(a[2], b[2])
                if gap is None:
                    continue
                room = gap - CARRIAGEWAY_MIN_GAP_METERS
                need = (a[4] + b[4]) / 2.0
                if need <= room or need <= 0:
                    continue
                factor = max(room, 0.0) / need
                for member, street in ((members[i], a), (members[j], b)):
                    fitted = max(CARRIAGEWAY_MIN_WIDTH_METERS, street[4] * factor)
                    caps[member] = min(caps.get(member, street[4]), fitted)
    if not caps:
        return streets
    out = []
    for index, (street, chain) in enumerate(streets):
        if index in caps:
            street = street[:4] + (round(caps[index], 1),) + street[5:]
        out.append((street, chain))
    return out


# Почему ширина считается ПО ЛЕНТЕ, а не по улице целиком.
#
# Первым решением было «одна ширина на всю улицу с этим именем»: замер
# показывал, что у 44 улиц из 74 в кадре по две-три разные ширины, и это
# читалось как «несколько дорог склеили». Оказалось — читалось неверно.
#
# Данные по «Amir Temur shoh ko'chasi»: 67 кусков КЛАССА 3 (проспект, 3–5
# полос) и 30 кусков КЛАССА 4 (дублёр с тем же именем, 2–3 полосы). Дублёр
# действительно уже проспекта, а сам проспект действительно шире у
# перекрёстков — там добавляются полосы поворота. Разная ширина здесь ПРАВДА.
#
# Сведение их к одной ширине было бы враньём в сторону красивой картинки:
# дублёр стал бы проспектом, а трёхполосный участок — пятиполосным. Поэтому
# ширина одна на непрерывную ленту — там, где улица физически одна и та же, —
# и разная между лентами, где она разная в жизни.
#
# Настоящей причиной «сосисок» был не разброс ширин между улицами, а СТУПЕНЬ
# ВНУТРИ одной непрерывной ленты: пятнадцать кусков подряд рисовались каждый
# своей шириной. Это склейка и чинит.


# Ближе этого две вершины — одна и та же: шаг координат в тайле 1e-5°, это
# чуть больше метра, и после генерализации сошедшиеся концы отличаются в
# последнем знаке.
SPOT_EPSILON = 1.5e-5


def _turn_between(before, node, after):
    """Насколько лента поворачивает в узле, градусы. 0 — идёт прямо."""
    scale = math.cos(math.radians(node[1]))
    ax, ay = (node[0] - before[0]) * scale, node[1] - before[1]
    bx, by = (after[0] - node[0]) * scale, after[1] - node[1]
    if (ax == 0 and ay == 0) or (bx == 0 and by == 0):
        return 0.0
    angle = math.degrees(math.atan2(ax * by - ay * bx, ax * bx + ay * by))
    return abs(angle)


def _spot_bucket(point):
    return (int(point[0] // SPOT_EPSILON), int(point[1] // SPOT_EPSILON))


def _near_spot(index, point):
    """Куски, кончающиеся рядом с точкой. Соседние клетки обходим тоже: две
    точки ближе эпсилона могут лечь в разные, и половина стыков потерялась бы.

    Порядок устойчив — от него зависит sha256 тайлов.
    """
    x, y = _spot_bucket(point)
    found = set()
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            found.update(index.get((x + dx, y + dy), ()))
    return sorted(found)


def _same_spot(one, other):
    return (abs(one[0] - other[0]) < SPOT_EPSILON
            and abs(one[1] - other[1]) < SPOT_EPSILON)


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
    names_by_index = {}
    missed = []
    for edit in edits:
        kind = edit.get("kind")
        if kind not in ("lanes", "name"):
            continue
        props = edit.get("props") or {}
        lanes = props.get("lanes")
        title = props.get("name")
        geometry = edit.get("geom") or []
        if len(geometry) < 2 or isinstance(geometry[0], (list, tuple)):
            missed.append(edit)
            continue
        if kind == "lanes" and not isinstance(lanes, int):
            missed.append(edit)
            continue
        if kind == "name" and not (isinstance(title, str) and title.strip()):
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
        if kind == "name":
            # Название — единственное, что человек знает лучше OSM всегда: он
            # там был. Поэтому оно перекрывает пришедшее из экстракта, а не
            # дополняет его.
            names_by_index[best] = title.strip()
        else:
            # Рука старше автоматики — но не старше физики: потолок класса
            # стоит и здесь. Опечатка модератора не должна залить квартал
            # асфальтом.
            lanes_by_index[best] = clamp_lanes(roads[best][0], lanes)

    if not lanes_by_index and not names_by_index:
        return roads, 0, len(missed)
    patched = list(roads)
    for index, lanes in lanes_by_index.items():
        code, flags, points, name = patched[index]
        # Правка делает дорогу ИЗМЕРЕННОЙ: модератор смотрел на спутник, и в
        # очереди конструктора ей больше делать нечего.
        patched[index] = (code, with_lanes(flags, lanes) | FLAG_LANES_TAGGED,
                          points, name)
    for index, title in names_by_index.items():
        code, flags, points, _ = patched[index]
        patched[index] = (code, flags, points, title)
    return (patched, len(lanes_by_index) + len(names_by_index), len(missed))


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
    # Дорогу убирают двумя способами, и оба сводятся к одному действию.
    #
    # «Перерисовал» — своя линия помечена заменой. «Убрал» — своей линии нет
    # вовсе: улицу перекрыли, снесли, застроили, и рисовать ради этого
    # фиктивную дорогу нелепо. У правки «убрать» в геометрии лежит копия той
    # самой чужой линии, снятая в момент щелчка, — по ней и ищем.
    lines = [e for e in hand_edits
             if (e.get("kind") == "geometry"
                 and (e.get("props") or {}).get("replace"))
             or e.get("kind") == "remove"]
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
SET_HOUSES = "h"
# Поверхность дорог. Только ближний охват: на охвате района полотно вырождается
# в линию, и возить контуры туда — платить за то, чего не видно.
SET_SURFACE = "d"
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

# Населённые пункты: город, посёлок, кишлак, район города.
#
# Своим набором, а не вместе с обстановкой: обстановка живёт на ближнем плане
# и посажена на дорогу, а название города нужно ровно там, где дорог уже не
# видно. Один файл на тайл, запись — точка с именем.
#
# Ранг в коде записи, как класс у дороги: по нему клиент решает, с какого
# охвата подписывать. Город виден с охвата области, кишлак — с районного;
# показать всё сразу значит закрыть карту словами.
# Крупным считается кольцо, которое НЕ влезает в тайл целиком по числу
# вершин. Мелочь режется впустую: она и так лежит в одном-двух тайлах, а
# отсечение стоило бы дороже переноса.
BIG_AREA_POINTS = 64

SET_PLACES = "n"
PLACE_RANKS = {"city": 1, "town": 2, "village": 3, "hamlet": 4,
               "suburb": 5, "neighbourhood": 6}

# Коды видов местности — контракт с клиентом (SketchArea.Kind).
AREA_WATER, AREA_GREEN, AREA_RAIL, AREA_BLOCK = 1, 2, 3, 4
# Тротуар — тоже «местность», и это не натяжка, а экономия. Он открытая лента,
# как рельсы, и проходит теми же тайлами, той же распаковкой дельт и тем же
# бюджетом. Отдельный конвейер ради ленты, которая ничем не отличается от уже
# работающей, стоил бы больше, чем экономит.
AREA_SIDEWALK = 5
# Дома. Последний слой по важности за рулём и первый по числу объектов: в
# одном центре Ташкента их 54 094 против семисот дорог. Поэтому у них свой
# набор, свой порог площади и своё, более грубое упрощение — и показываются
# они только на ближнем охвате, где водитель уже ищет подъезд, а не поворот.
AREA_HOUSE = 6
# Поверхность дороги — ГОТОВАЯ ГЕОМЕТРИЯ, посчитанная здесь, а не в браузере.
#
# Сегодня клиент на каждую перерисовку строит из осевых линий полотно,
# перекрёстки и фаски заново. Это геометрия, а не отрисовка: она одинакова для
# всех, не зависит от зума и не меняется, пока не пересобраны тайлы. Считать её
# на каждое движение карты неверно в любом движке — и в canvas, и в WebGL.
#
# Осевые при этом НЕ выбрасываются: по ним работает магнит, привязка правок и
# весь конструктор. Сеть остаётся сетью, поверхность — отдельный слой поверх.
AREA_ROAD = 7
AREA_JUNCTION = 8
# Разделительная — ПОЛОСА ЗЕМЛИ между встречными проезжими, а не краска.
#
# На проспекте потоки разделены физически: газон, отбойник, бордюр. Рисовать
# там пунктир значит утверждать, что это разметка, — и водитель, поймавший
# враньё, перестанет верить и правде.
#
# Знаем мы это не из тегов, а из геометрии: сборка склеила две ОДНОСТОРОННИЕ
# ленты одной улицы, идущие навстречу в нескольких метрах друг от друга.
# Полоса между их внутренними кромками и есть разделительная.
AREA_MEDIAN = 9
AREA_FLAG_CLOSED = 1


# Местность обзора: вода и крупная зелень, только площади.
#
# До 27.09.2026 обзорный зум MVT нёс одни дороги: ниже 14.6 карта была сетью
# линий на чёрном — ни реки, ни парка, ни водохранилища, то есть ничего, по
# чему глаз узнаёт место. Стиль телефона слой land-far уже рисует (заливка
# полигонов по kind), ему просто нечего было дать.
#
# Порог площади — от пикселя: на z11 у широты Ташкента пиксель около 57 м, и
# 10 га — это пятно примерно 5×5 пикселей. Мельче — точка шума, которая стоит
# байтов и не узнаётся. Упрощение 30 м — полпикселя того же зума.
FAR_AREA_KINDS = (AREA_WATER, AREA_GREEN)
FAR_AREA_MIN_M2 = 100_000.0
FAR_AREA_SIMPLIFY_METERS = 30.0


def ring_area_m2(points):
    """Площадь кольца [(lon, lat)] в квадратных метрах (равновеликая аппроксимация
    по широте середины — для отбора по порогу точнее не нужно)."""
    if len(points) < 3:
        return 0.0
    mid_lat = sum(lat for _lon, lat in points) / len(points)
    kx = LAT_METERS * math.cos(math.radians(mid_lat))
    ring = list(points)
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    twice = 0.0
    for (lon1, lat1), (lon2, lat2) in zip(ring, ring[1:]):
        twice += (lon1 * kx) * (lat2 * LAT_METERS) - (lon2 * kx) * (lat1 * LAT_METERS)
    return abs(twice) / 2.0


def build_far_areas(areas):
    """Местность для обзорного зума: крупная вода и зелень, огрублённая.

    Линии (каналы, ручьи) сюда не идут: слой land-far в стиле телефона — это
    заливка полигонов, линию он не нарисует, а байты она стоила бы.
    """
    out = []
    tolerance = FAR_AREA_SIMPLIFY_METERS / LAT_METERS
    for kind, flags, points in areas:
        if kind not in FAR_AREA_KINDS or not flags & AREA_FLAG_CLOSED:
            continue
        if ring_area_m2(points) < FAR_AREA_MIN_M2:
            continue
        coarse = simplify(list(points), tolerance)
        if len(coarse) < 3:
            continue
        out.append((kind, flags, coarse))
    return out


# Класс дороги — В БИТАХ записи, как этажность у дома. Клиент красит полотно по
# классу, а не гадает по ширине. Пятый элемент записи невозможен:
# RoadTiles.decodeEntries принимает длину 3 или 4 и на пятом возвращает nil на
# ВЕСЬ тайл — потерялась бы не дорога, а регион.
SURFACE_CLASS_SHIFT = 1
SURFACE_CLASS_MASK = 0b1111
# Дворовым проездам полотна не полагается: их больше половины сети, рисуются
# они тонкой лентой, и контур для них — чистая трата места.
SURFACE_MAX_CLASS = 6
# Скруглённый стык: шаг дуги на внешнем углу поворота. Двадцать градусов —
# по дну: мельче не видно даже на ближнем охвате, а вершины считаются.
SURFACE_ARC_STEP = 20.0

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
# Дом мельче этого — сарай, гараж или навес. За рулём они не помогают найти
# подъезд, а по числу их больше, чем самих домов: в замере центра Ташкента
# порог в десять метров убирает треть объектов и четверть веса.
MIN_HOUSE_METERS = 10.0
# Упрощение домов — СВОЁ и мелкое, а не кратное дорожному.
#
# Допуск обязан быть соразмерен объекту. Дорога длиной в километр не замечает
# двенадцати метров сглаживания; типовой дом сам шириной в десять, и такой
# допуск стирает его целиком — замерено: при кратном дорожному в тайлы
# доезжала треть домов, остальные схлопывались в точку и отбрасывались.
#
# Полтора метра — по дну: координата в тайле лежит с шагом 1e-5°, это 1,1 м, и
# сглаживать мельче нечего.
HOUSE_SIMPLIFY_METERS = 1.5
# Этажность дома — В БИТАХ записи, старше бита «замкнут».
#
# Пятый элемент записи невозможен: RoadTiles.decodeEntries принимает длину 3
# или 4, и пятый отправил бы в nil ВЕСЬ тайл у сборок, которые о нём не знают.
# Биты же старая сборка просто не видит — она читает флаги масками.
#
# Замерено: этажность есть у 39 % домов центра в OSM и у 0 % контуров ML.
# Значит объём получит меньше половины домов, и это правильнее, чем выдумать
# высоту остальным: одинаковые коробки по всему городу читаются как макет.
HOUSE_LEVELS_SHIFT = 1
HOUSE_LEVELS_MASK = 0x3F


def house_levels(properties):
    """Этажей у дома. 0 — не сказано, и выдумывать нельзя."""
    raw = properties.get("building:levels")
    if raw is None:
        # Высота в метрах — тоже ответ: делим на три метра на этаж.
        metres = properties.get("height")
        try:
            return max(0, min(HOUSE_LEVELS_MASK, int(round(float(metres) / 3))))
        except (TypeError, ValueError):
            return 0
    try:
        return max(0, min(HOUSE_LEVELS_MASK, int(round(float(raw)))))
    except (TypeError, ValueError):
        return 0


# Виды местности, которые можно обвести руками. Те же коды, что у слоёв из
# OSM: панель заводит объект ТОГО ЖЕ вида, а не параллельный, поэтому телефон
# рисует его тем же кодом и добавлять там нечего.
DRAWN_AREA_KINDS = {AREA_WATER, AREA_GREEN, AREA_RAIL, AREA_BLOCK, AREA_HOUSE}
# Меньше этого контур на охвате схемы неразличим, а весит столько же.
MIN_DRAWN_AREA_METERS = 30.0
# У дома порог свой и мелкий: типовой дом в периметре — сорок метров, и общий
# порог местности выбросил бы половину нарисованных руками домов.
MIN_DRAWN_HOUSE_METERS = 12.0


def drawn_areas(edits):
    """Обведённая руками местность → записи слоя, как из OSM."""
    out = []
    for edit in edits:
        if edit.get("kind") != "area":
            continue
        props = edit.get("props") or {}
        kind = props.get("area")
        if kind not in DRAWN_AREA_KINDS:
            continue
        ring = edit.get("geom") or []
        if len(ring) < 3 or not isinstance(ring[0], (list, tuple)):
            continue
        points = []
        for pair in ring:
            try:
                points.append((float(pair[0]), float(pair[1])))
            except (TypeError, ValueError, IndexError):
                points = []
                break
        if len(points) < 3:
            continue
        floor = (MIN_DRAWN_HOUSE_METERS if kind == AREA_HOUSE
                 else MIN_DRAWN_AREA_METERS)
        if polyline_meters(points) < floor:
            continue
        # Замкнутый контур заливается, разомкнутый — лента. Обведённое руками
        # всегда полигон: ленты (рельсы вдоль насыпи) в панели не рисуют.
        out.append((kind, AREA_FLAG_CLOSED, points))
    return out


def drawn_addresses(edits):
    """Адреса домов, обведённых руками → строки для адресного файла.

    Дом, нарисованный в панели, обязан находиться поиском ровно так же, как
    пришедший из OSM: телефон не знает и не должен знать, откуда взялся дом.

    Адрес необязателен: контур без адреса — всё равно застройка на схеме, и
    заставлять человека придумывать номер ради того, чтобы обвести дом, значит
    получить выдуманные номера.
    """
    out = []
    for edit in edits:
        if edit.get("kind") != "area":
            continue
        props = edit.get("props") or {}
        if props.get("area") != AREA_HOUSE:
            continue
        street = str(props.get("street") or "").strip()
        number = str(props.get("house") or "").strip()
        if not street or not number:
            continue
        ring = edit.get("geom") or []
        if len(ring) < 3 or not isinstance(ring[0], (list, tuple)):
            continue
        spot = feature_center({"type": "Polygon", "coordinates": [ring]})
        if spot is None:
            continue
        out.append((street, number, spot[0], spot[1]))
    return out


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


def build_blocks(roads, min_area=BLOCK_MIN_AREA, max_area=BLOCK_MAX_AREA,
                 kind=AREA_BLOCK, classes=None, accept=None):
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

    `accept(дороги грани)` — последнее слово о грани по её составу: площадь
    не отличает островок от середины перекрёстка, состав — отличает.
    """
    # Полурёбра: каждая линия даёт два направленных ребра.
    half = []            # (from_node, to_node, points)
    half_road = []       # дорога, из которой полуребро
    for road in roads:
        points = road[2]
        if len(points) < 2:
            continue
        if classes is not None and road[0] not in classes:
            continue
        half.append((_node(points[0]), _node(points[-1]), points))
        half.append((_node(points[-1]), _node(points[0]), list(reversed(points))))
        half_road.extend((road, road))

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
        if accept is not None and not accept([half_road[edge] for edge in cycle]):
            continue
        blocks.append((kind, AREA_FLAG_CLOSED, ring))
    return blocks


# Островок на съезде: грань дорожного графа, слишком маленькая для квартала.
#
# Считать его отдельно не надо — он УЖЕ находится там же, где кварталы, и
# отбрасывается порогом площади. Треугольник между съездом, основным ходом и
# поперечной улицей — это грань в двадцать-тысячу квадратных метров; квартал
# начинается с четырёхсот, и в этом окне они пересекаются, поэтому границу
# островка ведём по СОСТАВУ дорог, а не только по площади.
ISLAND_MIN_AREA = 20.0
ISLAND_MAX_AREA = 1200.0
# Островок окружён магистральной сетью. Дворовая петля той же площади — это
# двор, а не островок, и красить её асфальтовым бордюром было бы враньём.
ISLAND_CLASSES = frozenset({1, 2, 3, 4, 5})


# Доля обвода островка, которую обязан дать съезд (безымянная лента).
# У настоящего островка на съезде съезд — одна из трёх сторон; у середины
# перекрёстка безымянным бывает только коротенький кусок-связка в пару метров.
ISLAND_MIN_UNNAMED_SHARE = 0.2


def _length_of(points):
    return sum(meters_between(a, b) for a, b in zip(points, points[1:]))


def is_island_face(face_roads):
    """Грань — островок, а не середина перекрёстка.

    Где пересекаются два проспекта с раздельными направлениями, четыре ленты
    замыкают между собой квадрат асфальта в пару сотен метров — по площади
    ровно островок. Закрашенный тёмным, он давал «шахматку» посреди
    перекрёстка (Навои у Анхора, Навои × Рашидов; 27.09.2026). Отличает его
    состав: такую грань обходят именованные ленты двух и более улиц, а
    безымянного в обводе — от силы короткая связка. У настоящего островка
    безымянный съезд — заметная часть обвода.
    """
    names = {road[3] for road in face_roads if len(road) > 3 and road[3]}
    if len(names) < 2:
        return True
    total = unnamed = 0.0
    for road in face_roads:
        length = _length_of(road[2]) if len(road) > 2 else 0.0
        total += length
        if len(road) <= 3 or not road[3]:
            unnamed += length
    return total > 0 and unnamed / total >= ISLAND_MIN_UNNAMED_SHARE


def build_islands(roads):
    """Островки на съездах. Тот же обход граней, другое окно площади.

    Грань между почти параллельными линиями проходит порог площади, будучи
    шириной в метр, — на карте это игла поперёк асфальта. Такие отсекает
    surface_check (лезвие, игла, самопересечение): островок не выдумываем.
    """
    return [island for island in build_blocks(
                roads, min_area=ISLAND_MIN_AREA, max_area=ISLAND_MAX_AREA,
                kind=AREA_MEDIAN, classes=ISLAND_CLASSES, accept=is_island_face)
            if surface_check.defect(island[2]) is None]


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
# Выше восьми стрелок полос: совместимо со старым JSON и точностью double.
PFLAG_PAINTED = 1 << 45
PFLAG_ONEWAY = 1 << 46


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


# Какие переходы размечены зеброй — по смыслу тегов OSM, а не по одному тегу.
#
# До 28.09.2026 зебра рисовалась только при crossing=zebra или
# crossing:markings=yes|zebra — это ~350 переходов Ташкента из 4 600, и карта
# рядом с Яндексом выглядела голой. По вики OSM размечены и marked (нынешний
# стандарт), и uncontrolled (старое «зебра без светофора»), и traffic_signals —
# регулируемый переход размечен, если явно не сказано crossing:markings=no.
# Не рисуем unmarked/no и переходы вовсе без тега crossing: о них мы не знаем.
MARKED_CROSSINGS = {"zebra", "marked", "uncontrolled", "traffic_signals"}


def crossing_is_marked(properties):
    markings = properties.get("crossing:markings")
    if markings == "no":
        return False
    if markings and markings != "no":
        return True
    kinds = set(str(properties.get("crossing") or "").split(";"))
    return bool(kinds & MARKED_CROSSINGS)


def point_kind(properties):
    """Вид точечного объекта по тегам. None — не наш слой."""
    if properties.get("road_marking") == "stop_line":
        return POINT_STOP_LINE
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
        # В ручном редакторе эти виды означают именно нарисованную разметку.
        flags = PFLAG_PAINTED if kind in (POINT_STOP_LINE, POINT_CROSSING) else 0
        turns = props.get("turns")
        if kind == POINT_LANE_ARROWS and isinstance(turns, list):
            flags = pack_turns(0, [t for t in turns if isinstance(t, int)])
        out.append((kind, flags, [spot]))
    return out


def collect_places(source_path):
    """Прочитать geojsonl мест → [(ранг, биты, [(lon, lat)], имя)].

    Берём и точки, и площади: город в OSM бывает и узлом, и границей. У
    площади — середина рамки: центр города нам неизвестен, а середина —
    честный ответ на «где примерно».

    Без имени место бесполезно: подписывать нечем, а рисовать точку без
    подписи незачем — на схеме и так есть дороги.
    """
    out = []
    if not source_path or not os.path.exists(source_path):
        return out
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
            rank = PLACE_RANKS.get((properties.get("place") or "").strip())
            name = (properties.get("name") or "").strip()
            if rank is None or not name:
                continue
            spot = _middle_of(feature.get("geometry") or {})
            if spot is None:
                continue
            out.append((rank, 0, [spot], name))
    return out


def _middle_of(geometry):
    """Середина рамки любой геометрии → (lon, lat). None — не разобрали."""
    shape = geometry.get("type")
    coords = geometry.get("coordinates")
    if shape == "Point" and coords and len(coords) >= 2:
        return (round(coords[0], 5), round(coords[1], 5))
    points = []
    def walk(node):
        if isinstance(node, (list, tuple)):
            if node and isinstance(node[0], (int, float)) and len(node) >= 2:
                points.append(node)
            else:
                for item in node:
                    walk(item)
    walk(coords)
    if not points:
        return None
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    return (round((min(lons) + max(lons)) / 2, 5),
            round((min(lats) + max(lats)) / 2, 5))


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
            properties = feature.get("properties") or {}
            painted = properties.get("road_marking") == "stop_line" or (
                kind == POINT_CROSSING and crossing_is_marked(properties))
            points.append((kind, PFLAG_PAINTED if painted else 0,
                           [(float(coordinates[0]), float(coordinates[1]))]))
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
        best_bearing, best_width, best_oneway = 0.0, 0.0, False
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
                    best_oneway = bool(road[1] & FLAG_ONEWAY)
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
        above = (above & ~PFLAG_ONEWAY) | (PFLAG_ONEWAY if best_oneway else 0)
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


# --- Поверхность дороги: контур полотна ------------------------------------


def _unit(dx, dy):
    length = math.hypot(dx, dy)
    return (0.0, 0.0) if length == 0 else (dx / length, dy / length)


def _lon_scale(points):
    return math.cos(math.radians(sum(p[1] for p in points) / len(points)))


def _shift(point, normal, half, scale):
    return (point[0] + normal[0] * half / scale, point[1] + normal[1] * half)


def _arc(point, first, second, half, scale, turn):
    """Дуга скругления на внешнем углу поворота.

    Только на ВНЕШНЕМ: на внутреннем дуга даёт петлю с обратным обходом, и
    заливка по чётности выест из полотна дырку ровно в месте поворота.
    """
    start = math.atan2(first[1], first[0])
    end = math.atan2(second[1], second[0])
    span = (end - start + math.pi) % (2 * math.pi) - math.pi
    if turn * span <= 0:
        return []
    steps = max(1, int(abs(math.degrees(span)) / SURFACE_ARC_STEP))
    out = []
    for step in range(1, steps):
        angle = start + span * step / steps
        out.append(_shift(point, (math.cos(angle), math.sin(angle)), half, scale))
    return out


def _line_cross(a, b, c, d):
    """Точка пересечения отрезков ab и cd и доли вдоль каждого, или None.
    Координаты — (lon, lat); для пересечения масштаб не важен: он одинаков
    по обеим осям для обеих прямых и на долю вдоль отрезка не влияет."""
    rx, ry = b[0] - a[0], b[1] - a[1]
    sx, sy = d[0] - c[0], d[1] - c[1]
    denominator = rx * sy - ry * sx
    if denominator == 0:
        return None
    qx, qy = c[0] - a[0], c[1] - a[1]
    t = (qx * sy - qy * sx) / denominator
    u = (qx * ry - qy * rx) / denominator
    return (a[0] + rx * t, a[1] + ry * t), t, u


def _side(points, half, scale):
    """Одна кромка полотна: осевая, отодвинутая влево на половину ширины.

    Внешний угол поворота скругляется дугой. Внутренний — СРЕЗАЕТСЯ в точке,
    где сходятся две сдвинутые кромки: иначе конец одной заходит за начало
    другой, кромка петляет, и заливка выедает из асфальта дыру. Так было у
    26 % контуров полотна Ташкента (замер 27.09.2026). Если кромки на коротких
    отрезках так и не сходятся в пределах своих отрезков, угол остаётся как
    был — такой контур потом режет surface_pieces.
    """
    segments = []
    for index in range(len(points) - 1):
        here, ahead = points[index], points[index + 1]
        along = _unit((ahead[0] - here[0]) * scale, ahead[1] - here[1])
        if along == (0.0, 0.0):
            continue
        normal = (-along[1], along[0])
        segments.append((here, normal, _shift(here, normal, half, scale),
                         _shift(ahead, normal, half, scale)))
    edge = []
    for position, (here, normal, start, end) in enumerate(segments):
        if position == 0:
            edge.append(start)
        else:
            previous_normal = segments[position - 1][1]
            turn = previous_normal[0] * normal[1] - previous_normal[1] * normal[0]
            # Левая кромка снаружи поворота, когда путь сворачивает ВПРАВО
            # (turn < 0). Прежнее условие в _arc — «turn * span <= 0» — не
            # отличало одно от другого: turn и span меряют один и тот же
            # поворот и всегда одного знака, так что дуга вставала и на
            # внутренний угол, где она и давала петлю.
            if turn < 0:
                edge.extend(_arc(here, previous_normal, normal, half, scale, turn))
                edge.append(start)
            else:
                crossing = _line_cross(segments[position - 1][2], edge[-1], start, end)
                if crossing and 0.0 <= crossing[1] <= 1.0 and 0.0 <= crossing[2] <= 1.0:
                    edge[-1] = crossing[0]
                else:
                    edge.append(start)
        edge.append(end)
    return edge


def road_contour(points, width):
    """Замкнутый контур проезжей части: осевая, раздутая на ширину.

    Торцы срезаны, а не скруглены, и это не упрощение: там, где улица упирается
    в перекрёсток, шов закрывает площадь узла (AREA_JUNCTION), а не заглушка.
    """
    if len(points) < 2 or width <= 0:
        return []
    scale = _lon_scale(points) or 1.0
    half = width / 2.0 / LAT_METERS
    left = _side(points, half, scale)
    right = _side(list(reversed(points)), half, scale)
    if not left or not right:
        return []
    return left + right


# Круг, которым закрывается стык двух кусков полотна: столько сторон, чтобы
# на ближнем зуме граней не было видно, и не больше — это вершины в тайле.
JOIN_DISC_SIDES = 16


def join_disc(point, width):
    """Круг радиусом в полширины вокруг вершины осевой — скругление стыка,
    ровно то, что делает line-join: round у линии той же ширины."""
    scale = _lon_scale([point]) or 1.0
    half = width / 2.0 / LAT_METERS
    return [_shift(point, (math.cos(2 * math.pi * i / JOIN_DISC_SIDES),
                           math.sin(2 * math.pi * i / JOIN_DISC_SIDES)), half, scale)
            for i in range(JOIN_DISC_SIDES)]


def surface_pieces(points, width):
    """Полотно улицы кусками, каждый из которых — честный многоугольник.

    Контур «осевая, раздутая на ширину» на внутренней стороне крутого изгиба
    перехлёстывает сам себя: сдвинутые отрезки пересекаются, и заливка такой
    фигуры выедает из асфальта дыру. Замерено 27.09.2026 по Ташкенту: так
    было у 26 % контуров полотна — это и были «пропуски» на снимке владельца.

    Поэтому: целиком, если контур чистый; иначе — самые длинные куски с
    чистым контуром (граница ищется делением пополам: удлинение куска
    перехлёст не убирает), а стык закрывается кругом в полширины.
    """
    if len(points) < 2 or width <= 0:
        return
    whole = road_contour(points, width)
    if len(whole) >= 3 and surface_check.defect(whole, shape_checks=False) is None:
        yield whole
        return
    last = len(points) - 1
    start = 0
    while start < last:
        lo, hi = start + 1, last
        best_end, best = start + 1, road_contour(points[start:start + 2], width)
        while lo <= hi:
            middle = (lo + hi) // 2
            trial = road_contour(points[start:middle + 1], width)
            if len(trial) >= 3 and surface_check.defect(trial, shape_checks=False) is None:
                best_end, best = middle, trial
                lo = middle + 1
            else:
                hi = middle - 1
        if len(best) >= 3 and surface_check.defect(best, shape_checks=False) is None:
            yield best
        if best_end < last:
            yield join_disc(points[best_end], width)
        start = best_end


def iter_surface(streets):
    """Полотно для каждой улицы. Вход — склеенные улицы merge_streets.

    Выдаёт ПО ОДНОЙ фигуре, а не списком: список всех контуров страны в память
    не влезает, и первый боевой прогон это доказал — ядро убило сборку.
    """
    for code, _flags, points, _name, width, _measured in streets:
        if code > SURFACE_MAX_CLASS:
            continue
        flags = AREA_FLAG_CLOSED | (min(code, SURFACE_CLASS_MASK)
                                    << SURFACE_CLASS_SHIFT)
        for ring in surface_pieces(points, width):
            yield (AREA_ROAD, flags, ring)


def build_surface(streets):
    return list(iter_surface(streets))


def surface_class(flags):
    return (flags >> SURFACE_CLASS_SHIFT) & SURFACE_CLASS_MASK


# --- Перекрёсток: площадь между кромками, а не круг -------------------------

# Проверено и отвергнуто: круг самой широкой дороги клинья между кромками не
# закрывает, и круглые торцы вместо срезанных тоже — 31 дырка против 30, в
# пределах шума. Дело не в торцах: площадь между кромками сходящихся дорог не
# принадлежит НИ ОДНОЙ из осевых, и накрыть её может только своя фигура.
MIN_JUNCTION_ARMS = 3
# Фаска подхода: на последних метрах перед узлом полотно расширяется.
FLARE_METERS = 8.0
FLARE_WIDEN_METERS = 1.5


def convex_hull(points):
    """Оболочка по Эндрю. Точки в градусах; долгота сжата по широте, иначе на
    сорок первой параллели оболочка выходит перекошенной на четверть."""
    unique = sorted(set(points))
    if len(unique) < 3:
        return list(unique)
    scale = _lon_scale(unique) or 1.0

    def cross(o, a, b):
        return (((a[0] - o[0]) * scale) * (b[1] - o[1])
                - (a[1] - o[1]) * ((b[0] - o[0]) * scale))

    def half(source):
        out = []
        for point in source:
            while len(out) > 1 and cross(out[-2], out[-1], point) <= 0:
                out.pop()
            out.append(point)
        return out[:-1]

    return half(unique) + half(list(reversed(unique)))


def _node_key(point):
    return (round(point[0] / SPOT_EPSILON), round(point[1] / SPOT_EPSILON))


def junction_arms(chains):
    """Что сходится в каждом узле сети: (точка, направление наружу, ширина)."""
    arms = defaultdict(list)
    for street, chain in chains:
        width = street[4]
        if street[0] > SURFACE_MAX_CLASS:
            continue
        for piece in chain:
            points = piece[2]
            for node, neighbour in ((points[0], points[1]),
                                    (points[-1], points[-2])):
                arms[_node_key(node)].append((node, neighbour, width))
    return arms


def _edge_points(node, neighbour, width, scale, back=0.0):
    """Две кромки дороги в узле: центр ± половина ширины поперёк направления."""
    along = _unit((neighbour[0] - node[0]) * scale, neighbour[1] - node[1])
    if along == (0.0, 0.0):
        return []
    across = (-along[1], along[0])
    half = width / 2.0 / LAT_METERS
    step = back / LAT_METERS
    base = (node[0] + along[0] * step / scale, node[1] + along[1] * step)
    return [_shift(base, across, half, scale),
            _shift(base, (-across[0], -across[1]), half, scale)]


# Ближе этого два узла принадлежат ОДНОМУ перекрёстку.
#
# Пересечение двух проспектов с раздельными проезжими — это не один узел, а
# четыре и больше: у каждой проезжей свой конец. Оболочка, построенная по
# каждому узлу отдельно, накрывает четыре пятачка, а середина между ними не
# принадлежит ни одному — и остаётся чёрной дырой ровно в центре перекрёстка.
#
# Тридцать пять метров — по замеру: между проезжими проспекта 8–40 метров
# (тот же порог, что у разделительной), а до соседнего перекрёстка в городской
# сетке заметно дальше.
JUNCTION_CLUSTER_METERS = 35.0


def cluster_junctions(arms):
    """Свести узлы одного перекрёстка вместе. Возвращает список списков ног."""
    # Берём и узлы с ДВУМЯ концами, а не только перекрёстки.
    #
    # Там, где две ленты одной улицы стыкуются, у контуров срезанные торцы, и
    # если ленты подходят под разными углами или разной ширины — между
    # торцами остаётся клин пустоты. Это не перекрёсток, заливать его целиком
    # незачем, но и оставлять дырой нельзя: замерено, таких стыков в центре
    # были сотни.
    spots = [(key, arms[key]) for key in sorted(arms)
             if len(arms[key]) >= 2]
    parent = list(range(len(spots)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def unite(a, b):
        ra, rb = root(a), root(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    # Сетка по клеткам размером с порог: перебор всех пар квадратичен, а узлов
    # в стране сотни тысяч.
    cell = JUNCTION_CLUSTER_METERS / LAT_METERS
    buckets = defaultdict(list)
    for index, (_key, legs) in enumerate(spots):
        node = legs[0][0]
        buckets[(int(node[0] / cell), int(node[1] / cell))].append(index)
    for (bx, by), here in buckets.items():
        neighbours = []
        for dx in (0, 1):
            for dy in (-1, 0, 1):
                if dx == 0 and dy < 0:
                    continue
                neighbours.extend(buckets.get((bx + dx, by + dy), ()))
        for one in here:
            for other in neighbours:
                if one >= other:
                    continue
                if meters_between(spots[one][1][0][0],
                                  spots[other][1][0][0]) <= JUNCTION_CLUSTER_METERS:
                    unite(one, other)

    groups = {}
    for index, (_key, legs) in enumerate(spots):
        groups.setdefault(root(index), []).extend(legs)
    return [groups[key] for key in sorted(groups)]


# Ленты сходятся ровно — заливать нечего. Метр разницы в ширине и пятнадцать
# градусов поворота: ниже этого торцы совпадают, и клина не видно.
SEAM_WIDTH_METERS = 1.0
SEAM_TURN_DEGREES = 15.0


def _seam_needs_patch(legs):
    """Нужна ли заплатка на стыке двух лент."""
    if len(legs) != 2:
        return False
    (node_a, ahead_a, width_a), (node_b, ahead_b, width_b) = legs
    if abs(width_a - width_b) >= SEAM_WIDTH_METERS:
        return True
    # НОЛЬ — ленты идут насквозь, торцы совпадают; угол и есть излом.
    #
    # Первая версия сравнивала со 180° и объявляла изломом каждый прямой
    # стык: обе соседние вершины смотрят НАРУЖУ от узла, и у сквозной ленты
    # угол между ними равен нулю, а не развёрнутому.
    return _turn_between(ahead_a, node_a, ahead_b) >= SEAM_TURN_DEGREES


# Насколько оболочка заходит вглубь подхода, в ширинах дороги.
#
# Подобрано ЗАМЕРОМ, а не на глаз. Дыры — непокрытые точки, окружённые
# асфальтом с трёх сторон:
#
#   заход ×1,0 — 15 % перекрёстков с дырами, площадь вдвое больше ожидаемой
#   заход ×1,5 — 10 %, площадь втрое
#   заход ×2,0 —  8 %, площадь впятеро
#   заход ×3,0 —  7 %, площадь всемеро
#
# Полтора — там, где кривая ломается: дальше платим площадью втрое дороже за
# каждый следующий процент, а лишняя площадь это асфальт на тротуаре.
JUNCTION_REACH = 1.5

# Потолок площади оболочки, в квадратах самой широкой дороги.
#
# Замер нашёл кластеры, где оболочка в 55 раз больше ожидаемой: узлы свелись
# через полквартала, и выпуклая оболочка залила асфальтом двор целиком. Такой
# кластер разбираем обратно на отдельные узлы — лучше шов, чем двор под
# асфальтом.
JUNCTION_MAX_AREA = 12.0
# Площадь сама по себе клин не ловит: у правильного креста 25 м оболочка по
# замыслу заходит на подходы и тянет на семь квадратов ширины, а клин Навои ×
# Лабзак (27.09.2026, 5 309 м², улица входит под острым углом) — на восемь с
# половиной. Отличает их ДОЛЯ оболочки, которую не покрывают сами дороги: у
# креста это скруглённые углы, у клина — земля между улицами.
JUNCTION_MAX_UNCOVERED = 0.35
# Дальше этого от центра перекрёстка (в ширинах самой широкой дороги, плюс
# разброс сведённых узлов) асфальт — уже подход, и его рисует линия дороги.
# Оболочка обрезается кругом: клин земли между сходящимися улицами (Навои ×
# Лабзак) остаётся землёй, а подходы — по-прежнему заходят в узел.
JUNCTION_REACH_WIDTHS = 1.2
JUNCTION_DISC_SIDES = 32
# Шаг сетки, по которой меряется непокрытая доля, и запас к полуширине дороги.
JUNCTION_COVER_STEP_METERS = 3.0
JUNCTION_COVER_SLACK_METERS = 1.0
#
# Узел пишется только там, где сходится хоть одна дорога шире этого. Стиль
# телефона красит площадь узла цветом проспекта, и на перекрёстке дворовых
# проездов она читалась серым ромбом поверх тёмных улиц. Там стык закрывает
# сама линия со скруглённым концом — MapLibre рисует каймы и полотна в два
# прохода, шва не бывает.
JUNCTION_MIN_WIDEST_METERS = 9.0


def _hull_of(legs):
    """Оболочка кромок группы ног. Пустой список — фигуры нет."""
    scale = _lon_scale([legs[0][0]]) or 1.0
    edges = []
    for node, neighbour, width in legs:
        edges.extend(_edge_points(node, neighbour, width, scale))
        reach = min(width * JUNCTION_REACH,
                    meters_between(node, neighbour) * 0.9)
        if reach > 1.0:
            edges.extend(_edge_points(node, neighbour, width, scale, back=reach))
    ring = convex_hull(edges)
    return ring if len(ring) >= 3 else []


# Скругление въезда в перекрёсток.
#
# Оболочка кромок даёт ПРАВИЛЬНУЮ площадь, но с острыми углами: в жизни угол
# между двумя улицами скруглён бордюром, и именно это отличает нарисованный
# перекрёсток от настоящего сильнее всего остального.
#
# Радиус не выдумываем: он не имеет права съесть проезжую часть, поэтому берём
# половину ширины САМОЙ УЗКОЙ ноги узла и ограничиваем сверху. Двор к проспекту
# получит маленький радиус, два проспекта — большой, и оба останутся честными.
KERB_RADIUS_MIN = 2.0
KERB_RADIUS_MAX = 10.0
# Дуга приближается квадратичной кривой Безье через сам угол. Это парабола, а
# не окружность, но отклонение на наших радиусах меньше допуска упрощения
# (4 м): проверено тестом, а не на глаз.
#
# Точек на угол — ОДНА, и это замер, а не экономия из принципа. На 5 987
# настоящих перекрёстках центра Ташкента:
#
#   одна точка  — вершин ×3,1, набор «d» тяжелее на 26 %
#   две точки   — вершин ×4,0, тяжелее на 38 %
#   три точки   — вершин ×4,9, тяжелее на 51 %
#
# Разницу между одной и двумя на экране телефона (55 метров на высоту) видно
# только рядом с вершинами, и она не стоит двенадцати процентов веса.
KERB_ARC_STEPS = 1
# Почти прямой угол скруглять нечего: там нет угла.
KERB_STRAIGHT_DEGREES = 12.0


def round_corners(ring, radius, scale, steps=KERB_ARC_STEPS):
    """Скруглить углы кольца бордюрным радиусом. Кольцо → кольцо.

    Срез считается по касательным: t = R / tan(θ/2), но не больше половины
    каждой из соседних сторон — иначе соседние скругления съедят друг друга и
    кольцо вывернется.
    """
    if radius <= 0 or len(ring) < 4:
        return ring
    points = ring[:-1] if ring[0] == ring[-1] else list(ring)
    if len(points) < 3:
        return ring
    straight = math.radians(180.0 - KERB_STRAIGHT_DEGREES)
    out = []
    for i, point in enumerate(points):
        before = points[i - 1]
        after = points[(i + 1) % len(points)]
        one = ((before[0] - point[0]) * scale, before[1] - point[1])
        two = ((after[0] - point[0]) * scale, after[1] - point[1])
        len_one = math.hypot(*one)
        len_two = math.hypot(*two)
        if len_one <= 0 or len_two <= 0:
            out.append(point)
            continue
        one = (one[0] / len_one, one[1] / len_one)
        two = (two[0] / len_two, two[1] / len_two)
        cosine = max(-1.0, min(1.0, one[0] * two[0] + one[1] * two[1]))
        angle = math.acos(cosine)
        if angle >= straight or angle <= 1e-6:
            out.append(point)
            continue
        # ВСЁ В МЕТРАХ, и только в конце — обратно в градусы.
        #
        # Длины сторон здесь в градусах (с поправкой на долготу), радиус — в
        # метрах. Смешать их значит получить срез в доли миллиметра: угол
        # «скруглится» на 0,2 мм, и все проверки, кроме числовой, это
        # пропустят. Ровно так и вышло с первого раза.
        cut = min(radius / math.tan(angle / 2),
                  len_one * 111_320.0 / 2, len_two * 111_320.0 / 2) / 111_320.0
        if cut <= 0:
            out.append(point)
            continue
        start = (point[0] + one[0] * cut / scale, point[1] + one[1] * cut)
        end = (point[0] + two[0] * cut / scale, point[1] + two[1] * cut)
        out.append(start)
        for step in range(1, steps + 1):
            t = step / (steps + 1)
            back = (1 - t) * (1 - t)
            mid = 2 * (1 - t) * t
            fore = t * t
            out.append((back * start[0] + mid * point[0] + fore * end[0],
                        back * start[1] + mid * point[1] + fore * end[1]))
        out.append(end)
    out.append(out[0])
    return out


def kerb_radius(legs):
    """Радиус бордюра узла: половина ширины самой узкой ноги, в пределах."""
    if not legs:
        return 0.0
    narrow = min(leg[2] for leg in legs)
    return max(KERB_RADIUS_MIN, min(KERB_RADIUS_MAX, narrow / 2))


def _hull_fits(legs, ring):
    want = max(leg[2] for leg in legs) ** 2
    if want > 0 and abs(signed_area_meters(ring)) > want * JUNCTION_MAX_AREA:
        return False
    return uncovered_share(legs, ring) <= JUNCTION_MAX_UNCOVERED


def clip_to_reach(legs, ring):
    """Оболочка узла ∩ круг досягаемости перекрёстка (Сазерленд — Ходжмен:
    круг выпуклый, а для выпуклого отсекателя форма субъекта не важна)."""
    if len(ring) < 3 or not legs:
        return ring
    nodes = [leg[0] for leg in legs]
    centre = (sum(p[0] for p in nodes) / len(nodes), sum(p[1] for p in nodes) / len(nodes))
    kx = LAT_METERS * math.cos(math.radians(centre[1]))
    spread = max(math.hypot((p[0] - centre[0]) * kx, (p[1] - centre[1]) * LAT_METERS)
                 for p in nodes)
    radius = JUNCTION_REACH_WIDTHS * max(leg[2] for leg in legs) + spread
    clipper = [(centre[0] + radius * math.cos(2 * math.pi * i / JUNCTION_DISC_SIDES) / kx,
                centre[1] + radius * math.sin(2 * math.pi * i / JUNCTION_DISC_SIDES) / LAT_METERS)
               for i in range(JUNCTION_DISC_SIDES)]
    subject = list(ring)
    if len(subject) > 1 and subject[0] == subject[-1]:
        subject.pop()
    # Обход отсекателя — против часовой (как построен круг); «внутри» — слева.
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]

        def left(p):
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= 0

        def cut(p, q):
            crossing = _line_cross(p, q, a, b)
            return crossing[0] if crossing else q

        out = []
        for j in range(len(subject)):
            here, ahead = subject[j], subject[(j + 1) % len(subject)]
            if left(ahead):
                if not left(here):
                    out.append(cut(here, ahead))
                out.append(ahead)
            elif left(here):
                out.append(cut(here, ahead))
        subject = out
        if len(subject) < 3:
            return []
    return subject


def uncovered_share(legs, ring):
    """Какая доля оболочки узла лежит вне полотна его дорог.

    Сетка с шагом JUNCTION_COVER_STEP_METERS по рамке оболочки; точка внутри
    оболочки считается покрытой, если она не дальше полуширины (плюс запас) от
    оси хоть одной ноги. Нога — отрезок от узла к соседней вершине.
    """
    if len(ring) < 3 or not legs:
        return 0.0
    lat0 = legs[0][0][1]
    kx = LAT_METERS * math.cos(math.radians(lat0))
    origin = legs[0][0]

    def local(point):
        return ((point[0] - origin[0]) * kx, (point[1] - origin[1]) * LAT_METERS)

    shape = [local(p) for p in ring]
    segments = [(local(node), local(neighbour), width / 2.0 + JUNCTION_COVER_SLACK_METERS)
                for node, neighbour, width in legs]
    xs = [p[0] for p in shape]
    ys = [p[1] for p in shape]
    inside = covered = 0
    step = JUNCTION_COVER_STEP_METERS
    y = min(ys) + step / 2
    while y < max(ys):
        x = min(xs) + step / 2
        while x < max(xs):
            if _point_in_ring((x, y), shape):
                inside += 1
                for a, b, reach in segments:
                    if _distance_to_segment((x, y), a, b) <= reach:
                        covered += 1
                        break
            x += step
        y += step
    return 0.0 if inside == 0 else 1.0 - covered / inside


def _point_in_ring(point, ring):
    x, y = point
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def _distance_to_segment(p, a, b):
    ax, ay = b[0] - a[0], b[1] - a[1]
    length = ax * ax + ay * ay
    if length == 0:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    t = max(0.0, min(1.0, ((p[0] - a[0]) * ax + (p[1] - a[1]) * ay) / length))
    return math.hypot(p[0] - a[0] - ax * t, p[1] - a[1] - ay * t)


def iter_junctions(arms):
    """Асфальт перекрёстка — оболочка кромок ВСЕХ его дорог, а не одного узла."""
    for legs in cluster_junctions(arms):
        if len(legs) < MIN_JUNCTION_ARMS and not _seam_needs_patch(legs):
            continue
        if max(leg[2] for leg in legs) < JUNCTION_MIN_WIDEST_METERS:
            continue
        ring = _hull_of(legs)
        if not ring:
            continue
        if _hull_fits(legs, ring):
            scale = _lon_scale([legs[0][0]]) or 1.0
            shaped = clip_to_reach(legs, round_corners(ring, kerb_radius(legs), scale))
            if len(shaped) >= 3:
                yield (AREA_JUNCTION, AREA_FLAG_CLOSED, shaped)
            continue
        # Кластер растянулся — разбираем обратно по узлам. Лучше шов, чем
        # двор, залитый асфальтом.
        by_node = {}
        for leg in legs:
            by_node.setdefault(_node_key(leg[0]), []).append(leg)
        for key in sorted(by_node):
            alone = by_node[key]
            if len(alone) < MIN_JUNCTION_ARMS and not _seam_needs_patch(alone):
                continue
            small = _hull_of(alone)
            # Оболочка одного узла тоже бывает клином: острый угол входа даёт
            # её и без сведения узлов. Не влезла — стык закроет линия.
            if small and _hull_fits(alone, small):
                small = clip_to_reach(alone, small)
                if len(small) >= 3:
                    yield (AREA_JUNCTION, AREA_FLAG_CLOSED, small)


def build_junctions(arms):
    return list(iter_junctions(arms))


def iter_flares(arms):
    """Фаска подхода: полотно расширяется на последних метрах перед узлом.

    Расширение ограничено четвертью ширины и шириной самого узла — иначе
    дворовый проезд, упирающийся в проспект, раздувается вдвое и читается как
    ещё один проспект.
    """
    for key in sorted(arms):
        legs = arms[key]
        if len(legs) < MIN_JUNCTION_ARMS:
            continue
        node = legs[0][0]
        scale = _lon_scale([node]) or 1.0
        widest = max(leg[2] for leg in legs)
        for _node, neighbour, width in legs:
            widen = min(FLARE_WIDEN_METERS, width / 4.0,
                        max(0.0, (widest - width) / 2.0))
            if widen <= 0:
                continue
            far = _edge_points(node, neighbour, width, scale, FLARE_METERS)
            near = _edge_points(node, neighbour, width + 2 * widen, scale)
            if not far or not near:
                continue
            yield (AREA_ROAD, AREA_FLAG_CLOSED,
                   [far[0], near[0], near[1], far[1]])


def build_flares(arms):
    return list(iter_flares(arms))

# Что ворота поверхности не пустили в тайл: (вид, причина) → число. Печатается
# в отчёте сборки: рост этих чисел между прогонами — регрессия генерации.
SURFACE_REJECTED = Counter()


def quantized(ring):
    """Кольцо таким, каким оно ляжет в тайл: шаг 1e-5°, без повторов подряд.

    Проверять надо ЭТО, а не исходник: узкая фигура после округления до метра
    бывает иглой, которой до округления не было.
    """
    out = []
    for lon, lat in ring:
        point = (round(lon * SCALE) / SCALE, round(lat * SCALE) / SCALE)
        if not out or out[-1] != point:
            out.append(point)
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def surface_gate(figure):
    """Пропустить фигуру поверхности в тайл или отказать (и сосчитать отказ)."""
    kind, _flags, ring = figure
    reason = surface_check.defect_of_kind(kind, quantized(ring))
    if reason:
        SURFACE_REJECTED[(kind, reason)] += 1
        return False
    return True


def stream_surface(roads, target_dir, degrees, handles=64):
    """Поверхность — на диск потоком, по тому же закону, что дома.

    Контур улицы примерно втрое тяжелее её осевой по вершинам, и держать слой
    списком нельзя: замерено 433 байта на дорогу, а дорог в стране 604 522.
    Склейка при этом всё равно идёт по всей сети — иначе улица разорвётся на
    границе тайла, — но наружу отдаётся только индекс.
    """
    work = os.path.join(target_dir, "_surface")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    open_files = OrderedDict()
    keys = set()

    def sink(key):
        handle = open_files.get(key)
        if handle is not None:
            open_files.move_to_end(key)
            return handle
        while len(open_files) >= handles:
            open_files.popitem(last=False)[1].close()
        handle = open(os.path.join(work, key + ".jsonl"), "a", encoding="utf-8")
        open_files[key] = handle
        keys.add(key)
        return handle

    try:
        chains = street_chains(roads)
        arms = junction_arms(chains)

        def put(figure):
            if not surface_gate(figure):
                return
            kind, flags, ring = figure
            row = json.dumps([kind, flags, encode(ring)], separators=(",", ":"))
            for key in tile_keys_of(ring, degrees):
                sink(key).write(row + "\n")

        for figure in iter_surface(street for street, _chain in chains):
            put(figure)
        for figure in iter_junctions(arms):
            put(figure)
        for figure in iter_flares(arms):
            put(figure)
        spots = junction_spots(arms)
        for figure in build_medians(chains, junction_index(spots)):
            put(figure)
        del chains
        # Середина перекрёстка — не островок и не разделительная: у Навои ×
        # Рашидов (28.09.2026) квадрат асфальта между четырьмя лентами проходил
        # и порог площади, и правило состава. Отличает его место: центр такой
        # фигуры лежит в пределах досягаемости узлов перекрёстка.
        inner = junction_index([(node, radius * JUNCTION_CORE_REACH) for node, radius in spots])
        for figure in build_islands(roads):
            if _at_junction(_centroid(figure[2]), inner):
                SURFACE_REJECTED[(AREA_MEDIAN, "середина перекрёстка")] += 1
                continue
            put(figure)
    finally:
        for handle in open_files.values():
            handle.close()

    written = flush_streamed(work, keys, target_dir, SET_SURFACE)
    shutil.rmtree(work, ignore_errors=True)
    return written


# Ближе этого две встречные проезжие — одна дорога с разметкой, а не проспект
# с островком: восемь метров это ширина двух полос, разделять там нечего.
MEDIAN_MIN_METERS = 8.0
# Дальше этого это уже две разные улицы, а не проспект.
MEDIAN_MAX_METERS = 40.0
# Насколько встречные обязаны быть параллельны. Тридцать градусов — запас на
# генерализацию и на плавные повороты; больше уже перекрёсток.
MEDIAN_MAX_TURN = 30.0
# Реже этого шага полосу не разбиваем: она обязана повторять изгиб проспекта.
MEDIAN_STEP_METERS = 25.0
# Проекция на встречную ленту идёт в одну сторону. Шаг назад больше этого —
# встречная свернула (мост, съезд, слияние), и ближайшая точка прыгнула на
# другой её участок: дальше кромка пошла бы вспять и вывернула полосу
# «бабочкой». Ровно это было на мосту Навои через Анхор (снимок 27.09.2026).
MEDIAN_BACKTRACK_METERS = 3.0
# Ширина полосы между соседними шагами меняется плавно. Скачок больше этого
# на шаге в 25 м — не расхождение проспекта, а прыжок ближайшей точки.
MEDIAN_MAX_GAP_JUMP_METERS = 6.0


def _box_of(points):
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    return min(lons), min(lats), max(lons), max(lats)


def _near_boxes(one, other, meters):
    """Сходятся ли рамки двух лент ближе, чем на столько метров."""
    a, b = _box_of(one), _box_of(other)
    slack = meters / LAT_METERS
    scale = math.cos(math.radians((a[1] + a[3]) / 2)) or 1.0
    return not (a[0] - slack / scale > b[2] or b[0] - slack / scale > a[2]
                or a[1] - slack > b[3] or b[1] - slack > a[3])


def _opposite(one, other):
    """Идут ли ленты навстречу друг другу."""
    turn = abs(_bearing(one) - _bearing(other))
    turn = min(turn, 360 - turn)
    return abs(turn - 180) <= MEDIAN_MAX_TURN


def _walk(points, step_meters):
    """Точки вдоль ломаной с шагом в метрах, вместе с направлением."""
    out = []
    travelled = 0.0
    target = 0.0
    for index in range(1, len(points)):
        before, after = points[index - 1], points[index]
        piece = meters_between(before, after)
        if piece <= 0:
            continue
        while target <= travelled + piece:
            share = (target - travelled) / piece
            out.append(((before[0] + (after[0] - before[0]) * share,
                         before[1] + (after[1] - before[1]) * share),
                        (before, after)))
            target += step_meters
        travelled += piece
    return out


def build_medians(chains, junctions=()):
    """Полосы земли между встречными проезжими одной улицы.

    `junctions` — узлы, через которые полоса идти НЕ ИМЕЕТ ПРАВА. На
    перекрёстке встречная проезжая никуда не девается и держится на том же
    расстоянии, поэтому по одному расстоянию полоса продолжается прямо через
    узел и закрашивает асфальт тёмным. На карте это чёрная клякса поперёк
    перекрёстка — ровно то, от чего мы уходили, убирая швы.

    Только там, где они ЕСТЬ: обе ленты односторонние, у обеих одно имя, идут
    навстречу и держатся друг от друга на расстоянии проспекта. Ни одного
    островка там, где его нет в жизни.
    """
    named = [street for street, _chain in chains
             if street[3] and street[1] & FLAG_ONEWAY and len(street[2]) >= 2]
    by_name = {}
    for street in named:
        by_name.setdefault((street[0], street[3]), []).append(street)

    out = []
    for key in sorted(by_name):
        group = by_name[key]
        for first in range(len(group)):
            for second in range(first + 1, len(group)):
                one, other = group[first], group[second]
                # Дешёвая отсечка по рамкам ДО всего остального.
                #
                # Пар внутри группы квадратично много — у «Abdulla Qodiriy»
                # 38 лент, то есть 703 пары, — а по стране группы крупнее.
                # Сравнение четырёх чисел отсекает почти все, и до дорогого
                # обхода доходят только соседи.
                if not _near_boxes(one[2], other[2], MEDIAN_MAX_METERS):
                    continue
                if not _opposite(one[2], other[2]):
                    continue
                strip = _median_strip(one, other, junctions)
                if strip:
                    out.append((AREA_MEDIAN, AREA_FLAG_CLOSED, strip))
    return out


def _nearest_along(point, line):
    """Ближайшая точка ломаной, расстояние до неё и путь вдоль ломаной до неё
    (в метрах от начала) — по пути проверяется, что проекция не пятится."""
    best, gap, along = None, float("inf"), 0.0
    travelled = 0.0
    for index in range(1, len(line)):
        before, after = line[index - 1], line[index]
        piece = meters_between(before, after)
        scale = math.cos(math.radians(point[1]))
        ax = (after[0] - before[0]) * scale
        ay = after[1] - before[1]
        length = ax * ax + ay * ay
        if length == 0:
            continue
        share = (((point[0] - before[0]) * scale) * ax
                 + (point[1] - before[1]) * ay) / length
        share = max(0.0, min(1.0, share))
        spot = (before[0] + (after[0] - before[0]) * share,
                before[1] + (after[1] - before[1]) * share)
        here = meters_between(point, spot)
        if here < gap:
            best, gap, along = spot, here, travelled + piece * share
        travelled += piece
    return best, gap, along


def _median_strip(one, other, junctions=()):
    """Многоугольник между внутренними кромками двух встречных проезжих.

    Три условия продолжения, кроме расстояния: не перекрёсток; проекция на
    встречную идёт в ту же сторону, что и шла; ширина не прыгает. Нарушение
    любого — конец полосы (если она уже набралась) или сброс. Итог проходит
    surface_check: кривая полоса на карту не едет вовсе.
    """
    left, right = [], []
    direction = 0
    previous_along = previous_gap = None
    for spot, _segment in _walk(one[2], MEDIAN_STEP_METERS):
        near, gap, along = _nearest_along(spot, other[2])
        if _at_junction(spot, junctions):
            near = None
        if near is not None and previous_along is not None:
            step = along - previous_along
            if direction == 0 and abs(step) > MEDIAN_BACKTRACK_METERS:
                direction = 1 if step > 0 else -1
            if direction and step * direction < -MEDIAN_BACKTRACK_METERS:
                near = None
            elif abs(gap - previous_gap) > MEDIAN_MAX_GAP_JUMP_METERS:
                near = None
        if near is None or not (MEDIAN_MIN_METERS <= gap <= MEDIAN_MAX_METERS):
            # Разрыв — конец полосы: проспект расходится или кончается.
            # Продолжать через разрыв значило бы нарисовать островок поперёк
            # перекрёстка.
            if len(left) >= 2:
                break
            left, right = [], []
            direction = 0
            previous_along = previous_gap = None
            continue
        previous_along, previous_gap = along, gap
        scale = _lon_scale([spot]) or 1.0
        half_one = one[4] / 2.0 / LAT_METERS
        half_two = other[4] / 2.0 / LAT_METERS
        toward = _unit((near[0] - spot[0]) * scale, near[1] - spot[1])
        if toward == (0.0, 0.0):
            continue
        left.append(_shift(spot, toward, half_one, scale))
        right.append(_shift(near, (-toward[0], -toward[1]), half_two, scale))
    if len(left) < 2:
        return []
    ring = left + list(reversed(right))
    return ring if surface_check.defect(ring) is None else []


# Клетка поиска перекрёстка. Больше любого радиуса узла: половина самой
# широкой дороги страны (56 м) плюс запас — это 32 метра, и шестьдесят четыре
# с проверкой соседних клеток накрывают их с двойным запасом.
JUNCTION_CELL_METERS = 64.0


def junction_index(spots):
    """Узлы, разложенные по клеткам. Тот же приём, что спас склейку.

    Проверка «стоим ли в перекрёстке» шла ЛИНЕЙНО по всем узлам страны, и
    звалась она на каждый двадцатипятиметровый шаг каждой разделительной
    полосы. Замерено профайлером на живой сборке: процесс просидел в
    `_at_junction` четыре часа сорок шесть минут при ста процентах ЦП и НУЛЕ
    записей на диск — арифметика сходится, узлов сотни тысяч, шагов десятки
    тысяч, произведение — десятки миллиардов расстояний.
    """
    cell = JUNCTION_CELL_METERS / LAT_METERS
    index = defaultdict(list)
    for node, radius in spots:
        index[(int(node[0] / cell), int(node[1] / cell))].append((node, radius))
    return index


def _at_junction(point, junctions):
    """Стоим ли мы в перекрёстке. Радиус — по самой широкой из его дорог.

    Принимает и разложенный по клеткам индекс, и простой список: вызовы из
    тестов и старого кода обязаны продолжать работать, а список из десятка
    узлов перебрать дешевле, чем разложить.
    """
    if isinstance(junctions, dict):
        cell = JUNCTION_CELL_METERS / LAT_METERS
        x, y = int(point[0] / cell), int(point[1] / cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for node, radius in junctions.get((x + dx, y + dy), ()):
                    if meters_between(point, node) <= radius:
                        return True
        return False
    for node, radius in junctions:
        if meters_between(point, node) <= radius:
            return True
    return False


# Во сколько радиусов узла (половина самой широкой дороги + 4 м) лежит
# «середина перекрёстка»: островок с центром ближе — это асфальт между лентами.
JUNCTION_CORE_REACH = 1.5


def _centroid(ring):
    return (sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring))


def junction_spots(arms):
    """Узлы с их радиусами: где полоса обязана прерваться."""
    out = []
    for key in sorted(arms):
        legs = arms[key]
        if len(legs) < MIN_JUNCTION_ARMS:
            continue
        widest = max(leg[2] for leg in legs)
        # Половина самой широкой плюс запас: полоса должна кончиться ДО
        # кромки перекрёстка, а не на ней.
        out.append((legs[0][0], widest / 2.0 + 4.0))
    return out


def _nearest_with_gap(point, line):
    """Ближайшая точка ломаной И расстояние до неё в метрах.

    Имя не `_nearest_on`: такая функция в файле уже есть и отдаёт только
    точку. Второе определение молча перекрыло первое, и сведение раздельных
    проезжих начало получать кортеж вместо координаты — пятнадцать тестов
    упали разом, ни один из них не про разделительные.
    """
    best, gap = None, float("inf")
    for index in range(1, len(line)):
        before, after = line[index - 1], line[index]
        scale = math.cos(math.radians(point[1]))
        ax = (after[0] - before[0]) * scale
        ay = after[1] - before[1]
        length = ax * ax + ay * ay
        if length == 0:
            continue
        share = (((point[0] - before[0]) * scale) * ax
                 + (point[1] - before[1]) * ay) / length
        share = max(0.0, min(1.0, share))
        spot = (before[0] + (after[0] - before[0]) * share,
                before[1] + (after[1] - before[1]) * share)
        here = meters_between(point, spot)
        if here < gap:
            best, gap = spot, here
    return best, gap


def build_road_surface(roads):
    """Весь слой поверхности: полотно улиц, перекрёстки, фаски.

    Осевые остаются нетронутыми — по ним работает магнит, привязка правок и
    конструктор. Это ДОПОЛНИТЕЛЬНЫЙ слой для картинки, а не замена сети.
    """
    chains = street_chains(roads)
    arms = junction_arms(chains)
    return (list(iter_surface(street for street, _chain in chains))
            + list(iter_junctions(arms)) + list(iter_flares(arms))
            + build_medians(chains, junction_spots(arms))
            + build_islands(roads))


def write_tiles(roads, target_dir, degrees=TILE_DEGREES_V2, areas=(), points=(),
                far_points=(), far=None, addresses=None, houses=None,
                surface=True, places=()):
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

    def tile(items, step, clip=False):
        by_key = defaultdict(list)
        for road in items:
            for key in tile_keys_of(road[2], step):
                by_key[key].append(road)
        if not clip:
            return by_key
        # Крупную местность режем ПО ТАЙЛУ, а не возим целиком.
        #
        # Правило «дубль на границе дешевле склейки» верно для улицы с
        # десятком вершин и неверно для озера с двенадцатью тысячами: замерено
        # на боевом экстракте — 2,4 миллиона копий вершин у крупных колец, из
        # них 1,3 миллиона у одного Хайдаркуля.
        #
        # Запас в пол-тайла: объект, обрезанный ровно по краю, на клиенте
        # обнажает шов, а лишние полкилометра ничего не стоят.
        margin = step / 2
        for key, rows in by_key.items():
            box = tile_box_of(key, step)
            cut = []
            for row in rows:
                if len(row[2]) < BIG_AREA_POINTS:
                    cut.append(row)
                    continue
                closed = bool(row[1] & AREA_FLAG_CLOSED)
                if closed:
                    ring = clip_ring(row[2], box, margin)
                    if len(ring) >= 4:
                        cut.append((row[0], row[1], ring) + tuple(row[3:]))
                else:
                    for piece in clip_line(row[2], box, margin):
                        cut.append((row[0], row[1], piece) + tuple(row[3:]))
            by_key[key] = cut
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
                 SET_SIDEWALK: [], SET_HOUSES: []}
    by_code = {AREA_WATER: SET_WATER, AREA_GREEN: SET_GREEN,
               AREA_RAIL: SET_RAIL, AREA_BLOCK: SET_BLOCKS,
               AREA_SIDEWALK: SET_SIDEWALK, AREA_HOUSE: SET_HOUSES}
    by_code[AREA_MEDIAN] = SET_SURFACE
    for kind, flags, shape in areas:
        area_sets[by_code[kind]].append((kind, flags, shape))
    # Кварталы считаются из САМОЙ сети, а не приходят из OSM.
    area_sets[SET_BLOCKS].extend(build_blocks(roads))
    # Поверхность считается ЗДЕСЬ, раз в неделю, а не в браузере на каждый
    # кадр. Клиенту остаётся залить присланные многоугольники.


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
    if places:
        sets[SET_PLACES] = list(places)
    land = set(area_sets)
    tiled = {name: tile(items, degrees, clip=name in land)
             for name, items in sets.items()}
    index_v2 = {}
    # Дома и поверхность СВОИ ФАЙЛЫ УЖЕ НАПИСАЛИ и отдают только записи
    # индекса. Оба слоя в память не влезают: домов в стране 1 653 195, а
    # контур улицы втрое тяжелее её осевой по вершинам.
    if houses:
        index_v2.update(houses)
    if surface:
        index_v2.update(stream_surface(roads, target_dir, degrees))
    for name, by_key in sorted(tiled.items()):
        for key, items in sorted(by_key.items()):
            if not items:
                continue
            rows = encoded(items)
            blob = json.dumps({"version": 2, "roads": rows},
                              separators=(",", ":")).encode()
            composite = f"{key}_{name}"
            path = os.path.join(target_dir, f"road2_{composite}.json")
            with open(path, "wb") as handle:
                handle.write(blob)
            index_v2[composite] = {"sha256": hashlib.sha256(blob).hexdigest(),
                                   "bytes": len(blob)}

    # Адреса — своими файлами и В ТОМ ЖЕ ИНДЕКСЕ. Не отдельный подписанный
    # список: индекс уже подписывается владельцем и уже накрывает файлы через
    # sha256, а второй такой же механизм — это второе место, где подпись может
    # разойтись с данными.
    #
    # Ключ на крупной сетке (0.5°) и с буквой набора на конце, как у тайлов:
    # клиент разбирает ключ одним и тем же кодом, а окрестность их не просит —
    # адреса запрашиваются по месту, а не по рамке.
    for key, payload in sorted((addresses or {}).items()):
        blob = json.dumps(payload, separators=(",", ":"),
                          ensure_ascii=False).encode()
        composite = f"{key}_{SET_ADDRESSES}"
        with open(os.path.join(target_dir, f"road2_{composite}.json"), "wb") as handle:
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
    parser.add_argument("--houses", dest="houses", default=None,
                        help="geojsonl зданий (необязателен)")
    parser.add_argument("--addresses", dest="addresses", default=None,
                        help="geojsonl объектов с addr:street (необязателен)")
    parser.add_argument("--places", dest="places", default=None,
                        help="geojsonl населённых пунктов (необязателен)")
    # Поверхность считается по ВСЕЙ переданной сети, и на боевом с гигабайтом
    # памяти это не то, что включают молча. Ключом — как дома и адреса.
    parser.add_argument("--no-surface", dest="surface", action="store_false",
                        default=True,
                        help="не считать поверхность дорог (набор d)")
    # MVT — РЯДОМ с нашим форматом, а не вместо.
    #
    # Наш JSON читают телефон и панель, и он остаётся: переход идёт
    # параллельно. MVT пишется из тех же данных одним лишним шагом кодирования
    # — это второй вывод одной сборки, а не вторая копия карты.
    parser.add_argument("--mvt", dest="mvt", action="store_true", default=False,
                        help="написать ещё и тайлы MVT (mvt/<z>/<x>/<y>.mvt)")
    parser.add_argument("--edits", dest="edits", default=None,
                        help="снимок правок панели (необязателен)")
    args = parser.parse_args()

    # Модуль MVT проверяем ПЕРВЫМ делом, а не после сборки.
    #
    # Он импортировался там, где используется, — то есть после часа работы:
    # закачки страны, шести экстрактов и всей раскладки тайлов. Отсутствие
    # файла на сервере валило прогон на последнем шаге, уже потратив всё.
    # Проверка, которая может пройти в первую секунду, обязана проходить в
    # первую секунду.
    if args.mvt:
        import build_mvt

    (raw, classes, flag_counts, read, skipped,
     lanes_tagged, raw_sidewalks, raw_arrows, identities) = collect(args.source)
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
    # Сырьё дальше не нужно, и держать его — не мелочь.
    #
    # Замерено: сырые дороги стоят 1056 байт на штуку, то есть 0,64 ГБ на
    # 604 522 дороги страны, и жили они до самого конца сборки рядом с
    # обобщёнными. На машине с двумя гигабайтами это и решало исход: первый
    # боевой прогон дважды убило ядро на шаге сборки. Для отчёта нужен один
    # счётчик, а не список.
    raw_count, hand_count = len(raw), len(hand)
    del raw, hand
    # Местность упрощаем грубее дорог: контур пруда не несёт геометрии, по
    # которой принимают решения за рулём.
    areas = collect_areas(args.areas, args.tolerance * 3 / 111_320.0)
    # Тротуары — тоже «местность», и упрощаются так же грубо: их дело —
    # показать, где кончается асфальт, а не где повернуть.
    areas = areas + build_sidewalks(raw_sidewalks, args.tolerance * 3 / 111_320.0)
    del raw_sidewalks
    # Обведённое руками — тем же слоем, что и пришедшее из OSM: телефон не
    # знает и не должен знать, откуда взялся газон.
    areas = areas + drawn_areas(edits)
    # Дома — последними и своим порогом. Их больше, чем всего остального
    # вместе взятого, и упрощаются они грубее: за рулём дом отвечает на
    # вопрос «мне вот сюда сворачивать», а не «где именно у него угол».
    # Дома НЕ в общем списке местности: их миллионы, и список убил бы память
    # сервера вместе с работающим рядом API. Раскладываются потоком, прямо в
    # файлы тайлов.
    houses = stream_houses(args.houses, args.tiles_dir, args.grid)
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
    del raw_arrows
    at_junctions = attach_to_junctions(raw_points, junction_nodes(roads))
    clustered = cluster_points(at_junctions)
    points, dropped = snap_points(clustered, roads)
    raw_points_count = len(raw_points)
    # Детальная карта сохраняет каждый подъезд; обзорная схема по-прежнему
    # получает один ориентир на перекрёсток. Не теряем данные до кодирования.
    mvt_points, _ = snap_points(raw_points, roads) if args.mvt else ([], 0)
    junction_count, clustered_count = len(at_junctions), len(clustered)
    del at_junctions, clustered
    # Дальний набор: только светофоры. Стоп-знак и лежачий на охвате района —
    # шум: решение по ним принимают, когда они уже видны глазами.
    lights = [p for p in raw_points if p[0] == POINT_TRAFFIC_LIGHT]
    far_points, far_dropped = snap_points(
        cluster_points(lights, POINT_FAR_CLUSTER_METERS), far)
    del lights, raw_points
    address_rows = collect_addresses(args.addresses) + drawn_addresses(edits)
    addresses = addresses_by_cell(address_rows)
    address_count = len(address_rows)
    address_streets = len({street for street, _, _, _ in address_rows})
    del address_rows
    # Опора правок пишется ДО тайлов, а не после: это 604 522 записи, и после
    # записи файла они памяти уже не занимают.
    if identities:
        identity_count = len(identities)
        identity_cells = write_identities(identities, args.tiles_dir)
    else:
        identity_count = identity_cells = 0
    del identities
    places = collect_places(args.places)
    index, index_v2 = write_tiles(roads, args.tiles_dir, args.grid, areas, points,
                                  far_points, far, addresses, houses,
                                  args.surface, places)

    if places:
        ranks = Counter(place[0] for place in places)
        named = ", ".join(f"{name} {ranks[rank]}" for name, rank in
                          (("городов", 1), ("посёлков", 2), ("кишлаков", 3),
                           ("хуторов", 4), ("районов", 5), ("кварталов", 6))
                          if ranks.get(rank))
        print(f"места: {len(places)} — {named}")

    if SURFACE_REJECTED:
        names = {AREA_ROAD: "полотно", AREA_JUNCTION: "узел", AREA_MEDIAN: "разделительная"}
        print("поверхность, не пущено воротами: " + ", ".join(
            f"{names.get(kind, kind)} — {reason} {count}"
            for (kind, reason), count in sorted(SURFACE_REJECTED.items())))

    if houses:
        weight = sum(meta["bytes"] for meta in houses.values())
        print(f"дома: {len(houses)} тайлов, {weight / 1e6:.1f} МБ (потоком)")

    if args.mvt:
        far_areas = build_far_areas(areas)
        # Ширина линии — по ленте, как у полотна: без этого край улицы
        # ступенчатый на стыках кусков с полосами из тега и без.
        widths = {id(piece): street[4]
                  for street, chain in street_chains(roads) for piece in chain}
        made = build_mvt.build_mvt(roads, args.tiles_dir, areas=areas,
                                   points=mvt_points, far=far,
                                   far_areas=far_areas, places=places,
                                   widths=widths)
        del widths
        print(f"MVT обзор: местности {len(far_areas)} площадей, мест {len(places)}")
        weight = sum(meta["bytes"] for meta in made.values())
        print(f"MVT: {len(made)} тайлов, {weight / 1e6:.1f} МБ "
              f"(зумы {build_mvt.ZOOM_DETAIL} и {build_mvt.ZOOM_FAR})")

    if identity_count:
        print(f"опора правок: {identity_count} дорог с id из OSM, "
              f"клеток {identity_cells}")
    else:
        print("опора правок: id из OSM в экстракте нет — привязка только "
              "геометрией (экстракт без -u type_id)")

    if address_count:
        print(f"адреса: {address_count} на {address_streets} улицах, "
              f"клеток {len(addresses)}")

    points_total = sum(len(r[2]) for r in roads)
    print(f"склейка и отсев: {raw_count} → {len(roads)} дорог")
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
    if raw_points_count:
        kinds = Counter(kind for kind, _, _ in points)
        print(f"точки: прочитано {raw_points_count}, на перекрёстках "
              f"{junction_count}, после сведения узлов {clustered_count}, "
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
    if edits_applied or edits_missed or hand_count:
        print(f"правки панели: наложено {edits_applied}, "
              f"не нашли дороги {edits_missed}, нарисовано руками {hand_count}, "
              f"заменено чужих {replaced}")
    share = 100.0 * lanes_tagged / read if read else 0.0
    print(f"полосы: тегом {lanes_tagged} из {read} ({share:.1f} %), "
          f"остальным по классу")
    return 0


if __name__ == "__main__":
    sys.exit(main())
