"""Число полос там, где OSM молчит, — по соседям той же улицы.

Зачем. Пунктир полос рисуется только по подтверждённому числу полос, а тег
lanes стоит у 40 % длины магистралей Ташкента (замер 05.10.2026). Остальное —
сплошной серый асфальт без разметки, и рядом с Яндексом это главная разница.
Видео для разметки нет; снимки Google и Яндекса брать нельзя. Остаётся то, что
уже есть: размеченные участки той же улицы и того же района.

Как. Голоса соседних размеченных участков в радиусе NEIGHBOUR_METERS:
ближний и длинный весит больше, продолжение той же ленты стык в стык — втрое.
Если у самой улицы есть размеченные участки, решает только она; соседние
улицы того же класса голосуют, лишь когда своих данных нет. Направленность обязана совпасть:
полосы односторонней ленты и двусторонней улицы — разные числа. Ответ
принимается, только если доля победителя не ниже MIN_CONFIDENCE и он
помещается в измеренную ширину полотна (fit_carriageways).

Проверено на размеченных участках Ташкента, спрятав половину тегов и угадав
их по второй половине (holdout_accuracy, 05.10.2026): при пороге 0,8 угадано
96,6 % (покрыто 63 % спрятанных); на всей сети так достраивается 360 км
из 952 км неразмеченных магистралей.

Куда идёт ответ — ТОЛЬКО в разметку (пунктир полос). Ширина полотна,
лимиты и алерты его не видят: ошибка стоит одной лишней линии на карте, а не
неверного предупреждения.

Чистый модуль, только stdlib.
"""
import math
from collections import Counter, defaultdict

NEIGHBOUR_METERS = 1500.0
MIN_CONFIDENCE = 0.8
SAME_STREET_WEIGHT = 4.0
# Продолжение той же ленты стык в стык (общая концевая точка, то же имя и
# направление) — самый надёжный свидетель: полосы не меняются посреди
# квартала. Без этого у Беруни голоса делились между продолжением (4) и
# встречной лентой (5), и кусок у перекрёстка оставался без пунктира.
CONNECTED_WEIGHT = 3.0
# Классы, где полосы угадываются: trunk…tertiary (коды build_roads).
INFER_CLASSES = {2, 3, 4, 5}
# Угаданные полосы обязаны поместиться в измеренное полотно: полоса не уже
# этого и не шире того. Иначе соседи врут про эту ленту (дублёр, съезд).
MIN_LANE_METERS = 2.75
MAX_LANE_METERS = 4.5
_CELL_METERS = 500.0


def _midpoint_metres(points):
    lon, lat = points[len(points) // 2]
    kx = 111_320 * math.cos(math.radians(lat))
    return lon * kx, lat * 111_320


def _key(point):
    return (round(point[0], 6), round(point[1], 6))


def _length_metres(points):
    kx = 111_320 * math.cos(math.radians(points[0][1]))
    return sum(math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)
               for a, b in zip(points, points[1:]))


def infer_lanes(roads, lanes_of, is_tagged, is_oneway, widths=None):
    """{id(дороги): (полос, уверенность)} для неразмеченных магистралей.

    roads — кортежи (класс, флаги, точки, имя) после generalise. Доступ к
    битам флагов — через переданные функции, чтобы модуль не знал раскладки.
    widths — {id(дороги): измеренная ширина полотна} или None.
    """
    widths = widths or {}
    items = []
    for road in roads:
        code, flags, points = road[0], road[1], road[2]
        if code not in INFER_CLASSES or len(points) < 2:
            continue
        x, y = _midpoint_metres(points)
        items.append({
            "ends": {_key(points[0]), _key(points[-1])},
            "road": road, "code": code, "name": (road[3] if len(road) > 3 else "") or "",
            "oneway": bool(is_oneway(flags)),
            "lanes": lanes_of(flags) if is_tagged(flags) else 0,
            "length": _length_metres(points), "x": x, "y": y,
        })
    grid = defaultdict(list)
    for index, item in enumerate(items):
        if item["lanes"]:
            grid[(int(item["x"] // _CELL_METERS), int(item["y"] // _CELL_METERS))].append(index)

    reach = int(math.ceil(NEIGHBOUR_METERS / _CELL_METERS))
    out = {}
    for item in items:
        if item["lanes"]:
            continue
        votes = Counter()
        cx, cy = int(item["x"] // _CELL_METERS), int(item["y"] // _CELL_METERS)
        for dx in range(-reach, reach + 1):
            for dy in range(-reach, reach + 1):
                for j in grid.get((cx + dx, cy + dy), ()):
                    other = items[j]
                    if other["oneway"] != item["oneway"]:
                        continue
                    distance = math.hypot(other["x"] - item["x"], other["y"] - item["y"])
                    if distance > NEIGHBOUR_METERS:
                        continue
                    same = bool(item["name"]) and other["name"] == item["name"]
                    if not same and other["code"] != item["code"]:
                        continue
                    weight = other["length"] / (1.0 + distance / 100.0)
                    weight *= SAME_STREET_WEIGHT if same else 1.0
                    if same and item["ends"] & other["ends"]:
                        weight *= CONNECTED_WEIGHT
                    votes[(other["lanes"], same)] += weight
        # Своя улица, если она что-то знает, решает одна: соседние улицы
        # района — слабые свидетели и только размывали уверенность (у Беруни
        # своя лента говорила «4» с перевесом 47,5 к 5,1, а в сумме с чужими
        # не набиралось порога). Чужие голосуют, только когда своих нет.
        own = Counter({lanes: weight for (lanes, same), weight in votes.items() if same})
        pool = own or Counter({lanes: weight for (lanes, _same), weight in votes.items()})
        if not pool:
            continue
        lanes, weight = pool.most_common(1)[0]
        confidence = weight / sum(pool.values())
        if confidence < MIN_CONFIDENCE:
            continue
        width = widths.get(id(item["road"]))
        if width and not (MIN_LANE_METERS * lanes <= width <= MAX_LANE_METERS * lanes):
            continue
        out[id(item["road"])] = (lanes, round(confidence, 3))
    return out


def holdout_accuracy(roads, lanes_of, is_tagged, is_oneway, with_lanes_cleared):
    """Точность на размеченных: прячем тег у каждого по очереди — дорого,
    поэтому прячем у всех сразу половину (чётные) и угадываем их по нечётным.

    with_lanes_cleared(road) → та же дорога без тега полос.
    Возвращает (угадано, всего угадывалось, всего размеченных в проверке).
    """
    tagged = [r for r in roads if r[0] in INFER_CLASSES and is_tagged(r[1])]
    hidden = tagged[0::2]
    hidden_ids = {id(r) for r in hidden}
    probe = [with_lanes_cleared(r) if id(r) in hidden_ids else r for r in roads]
    truth = {}
    for original, probed in zip(roads, probe):
        if id(original) in hidden_ids:
            truth[id(probed)] = lanes_of(original[1])
    guessed = infer_lanes(probe, lanes_of, is_tagged, is_oneway)
    hits = sum(1 for key, (lanes, _c) in guessed.items() if key in truth and truth[key] == lanes)
    total = sum(1 for key in guessed if key in truth)
    return hits, total, len(hidden)
