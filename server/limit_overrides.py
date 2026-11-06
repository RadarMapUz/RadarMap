#!/usr/bin/env python3
"""Официальные снижения лимитов поверх OSM: limit_overrides.json → сегменты.

ЗАЧЕМ. Лимит в приложении — тег maxspeed из OSM, а областной кенгаш снижает
скорость решением, и до OSM это доезжает, если доезжает, через месяцы. На А-373
и 4Р-12 тега нет вовсе, и приложение считало 100 там, где знак давно 80.

ГДЕ ЖИВЁТ. Шаг сборки: extract_speed_limits.py накладывает поправки каждый месяц
сам, поэтому они переживают крон; подпись ставит владелец (publish_limits.sh), и
перед подписью check_built() проверяет геометрией, что поправка действительно в
файле. Клиент не меняется: формат тот же, просто на дороге появились сегменты.

ЧТО МЕНЯЕТСЯ. Только проезжая часть своей дороги: way с нужным ref и классом без
_link — съезд и параллельная улица ref этой дороги не несут. Путь ищется в ОБЕ
стороны (на раздельной дороге это два разных полотна), между точками start и end.
Цепочка порвалась или длина не сошлась с измеренной — поправка НЕ применяется:
80 вместо 100 звучит как «Превышение скорости» и считает штраф, поэтому «почти
нашли» не считается.

ТЕГ НИЖЕ ПОПРАВКИ ОСТАЁТСЯ. Снижение до 80 не поднимает 60 у моста: такой знак
ставят поверх общего режима, и поправка не вправе его отменить.

Логика чистая: на входе сегменты и записи way, на выходе новый список — ни диска,
ни сети, ни osmium. Покрыто test_limit_overrides.py.
"""
import argparse
import hashlib
import heapq
import json
import math
import os
import sys

DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "limit_overrides.json")

FORMAT = 1
VERIFIED = "verified"

# Классы, на которых поправка вообще возможна. *_link сюда не входит намеренно:
# съезд с ref основной дороги в OSM встречается (A373 trunk_link), а лимита
# поправки у него нет.
MAIN_HIGHWAYS = {"motorway", "trunk", "primary", "secondary", "tertiary"}

# Короче километра — это 36 секунд на сотне: цифра на экране мигнёт, голос успеет
# сказать про снижение, и дальше снова 100. Такой кусок хуже его отсутствия.
MIN_APPLIED_METERS = 1000

# Как далеко точка start/end может лежать от полотна. Полоса разделённой дороги
# отстоит от своей пары на десятки метров, в горах — больше.
ANCHOR_REACH_METERS = 250

# Допуск измеренной при сборке длины против записанной: OSM правят, а 5 % на
# двадцати километрах — это уже чужая дорога или объезд через другой ref.
LENGTH_TOLERANCE = 0.05
LENGTH_TOLERANCE_MIN_METERS = 150

# Сегмент режется не длиннее этого. Рамка длинного горного way накрывает пол-долины,
# и LimitIndex.nearestRoad обходил бы все его точки на каждом GPS-тике; средний
# сегмент боевого файла — 8,5 точки.
MAX_POINTS_PER_SEGMENT = 24

# Как далеко клиент берёт дорогу под колёсами и насколько её ось может отличаться
# от курса (LimitIndex.matchHit: 35 м, ±40°). Рядом с зоной в этих пределах не
# должно быть дороги, где реальный лимит выше: на ней 80 станет ложным превышением.
NEIGHBOUR_REACH_METERS = 35
NEIGHBOUR_AXIS_DEGREES = 40
# Чужая магистраль рядом запрещает зону и без тега: там предполагается 100.
NEIGHBOUR_HIGHWAYS = {"motorway", "trunk"}

# Проба гейта публикации: как далеко от неё может лежать сегмент поправки.
PROBE_REACH_METERS = 25
# Доля проб, где лимит обязан быть ровно лимитом поправки (остальные — тег ниже).
PROBE_EXACT_SHARE = 0.9

_LOOKALIKES = str.maketrans({"А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H",
                             "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "У": "Y"})


def normalize_ref(raw):
    """"А-373; 4Р 12" → {"A373", "4P12"}: кириллица и латиница в OSM вперемешку."""
    out = set()
    for token in (raw or "").split(";"):
        token = token.upper().translate(_LOOKALIKES).replace("-", "").replace(" ", "")
        if token:
            out.add(token)
    return out


def load(path=DEFAULT_PATH):
    """Файл поправок. Битого не бывает «частично»: ValueError, и решает вызывающий."""
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    validate(doc)
    return doc


def validate(doc):
    if not isinstance(doc, dict) or doc.get("format") != FORMAT:
        raise ValueError("limit_overrides: формат не %d" % FORMAT)
    if not isinstance(doc.get("overrides", []), list):
        raise ValueError("limit_overrides: overrides не список")
    seen = set()
    for entry in doc.get("overrides", []):
        if not isinstance(entry, dict):
            raise ValueError("limit_overrides: запись не объект")
        ident = entry.get("id")
        if not ident or ident in seen:
            raise ValueError("limit_overrides: нет id или повтор (%r)" % ident)
        seen.add(ident)
        if entry.get("status") != VERIFIED:
            continue
        limit = entry.get("limit")
        if not isinstance(limit, int) or isinstance(limit, bool) or not 20 <= limit <= 130:
            raise ValueError("limit_overrides: %s — лимит %r" % (ident, limit))
        if not normalize_ref(";".join(entry.get("refs") or [])):
            raise ValueError("limit_overrides: %s — нет ref" % ident)
        for key in ("start", "end"):
            point = entry.get(key)
            if not (isinstance(point, list) and len(point) == 2
                    and all(isinstance(v, (int, float)) for v in point)):
                raise ValueError("limit_overrides: %s — %s не [lat, lon]" % (ident, key))
        length = entry.get("length_m")
        if not isinstance(length, (int, float)) or length < MIN_APPLIED_METERS:
            raise ValueError("limit_overrides: %s — длина %r короче %d м"
                             % (ident, length, MIN_APPLIED_METERS))


def verified(doc):
    return [entry for entry in doc.get("overrides", []) if entry.get("status") == VERIFIED]


def wanted_refs(doc):
    """Какие ref нужны сборщику: остальные дороги он даже не запоминает."""
    out = set()
    for entry in verified(doc):
        out |= normalize_ref(";".join(entry["refs"]))
    return out


def fingerprint(doc):
    """Отпечаток набора: то, что сервер применил, против того, что в репозитории.

    Только поля, влияющие на результат: правка источника или описания не должна
    заставлять пересобирать файл и подписывать его заново.
    """
    fields = sorted(
        (entry["id"], entry["limit"], sorted(normalize_ref(";".join(entry["refs"]))),
         entry["start"], entry["end"], entry["length_m"])
        for entry in verified(doc))
    encoded = json.dumps(fields, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()[:16]


# --- Геометрия. Локальная проекция: сотни метров, углы важнее третьего знака.

def _meters(a_lat, a_lon, b_lat, b_lon):
    mean = math.radians((a_lat + b_lat) / 2)
    dy = (b_lat - a_lat) * 111320.0
    dx = (b_lon - a_lon) * 111320.0 * math.cos(mean)
    return math.hypot(dx, dy)


def _project(lat, lon, a, b):
    """Точка на отрезке ab, ближайшая к (lat, lon): (метры, t от a к b)."""
    scale = math.cos(math.radians(lat))
    ax, ay = (a[1] - lon) * scale, a[0] - lat
    bx, by = (b[1] - lon) * scale, b[0] - lat
    dx, dy = bx - ax, by - ay
    squared = dx * dx + dy * dy
    t = 0.0 if squared == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / squared))
    return math.hypot(ax + t * dx, ay + t * dy) * 111320.0, t


def _bearing(a, b):
    scale = math.cos(math.radians((a[0] + b[0]) / 2))
    return math.degrees(math.atan2((b[1] - a[1]) * scale, b[0] - a[0])) % 360


def _opposite(first, second):
    diff = abs(first - second) % 360
    return min(diff, 360 - diff) > 90


class _Edge:
    """Шаг way в одну сторону: pos — номер пары узлов, forward — по ходу way."""
    __slots__ = ("way", "pos", "forward", "a", "b", "a_id", "b_id", "length")

    def __init__(self, way, pos, forward):
        low, high = way["nodes"][pos], way["nodes"][pos + 1]
        first, second = (low, high) if forward else (high, low)
        self.way, self.pos, self.forward = way, pos, forward
        self.a_id, self.b_id = first[0], second[0]
        self.a, self.b = (first[1], first[2]), (second[1], second[2])
        self.length = _meters(self.a[0], self.a[1], self.b[0], self.b[1])


def _edges(ways, refs):
    """Шаги своей дороги с учётом oneway. Съезд и чужой ref сюда не попадают."""
    out = []
    for way in ways:
        if way["highway"] not in MAIN_HIGHWAYS or not (way["refs"] & refs):
            continue
        for pos in range(len(way["nodes"]) - 1):
            if way["oneway"] >= 0:
                out.append(_Edge(way, pos, True))
            if way["oneway"] <= 0:
                out.append(_Edge(way, pos, False))
    return out


def _anchors(edges, point):
    """Шаги, на которых лежит точка: ближайший и ближайший встречный — две стороны.

    Перебор всех шагов в радиусе не годится: путь от дальнего шага короче, и
    зона молча усыхала бы на ширину радиуса.
    """
    found = []
    for edge in edges:
        distance, t = _project(point[0], point[1], edge.a, edge.b)
        if distance <= ANCHOR_REACH_METERS:
            found.append((distance, t, edge))
    if not found:
        return []
    found.sort(key=lambda item: item[0])
    first = found[0]
    direction = _bearing(first[2].a, first[2].b)
    for item in found[1:]:
        if _opposite(direction, _bearing(item[2].a, item[2].b)):
            return [first, item]
    return [first]


def _path(edges, source, target):
    """Кратчайший путь по шагам: (метры, [(edge, t0, t1)]) или None."""
    _, s_t, s_edge = source
    _, t_t, t_edge = target
    if s_edge is t_edge:
        if t_t < s_t:
            return None
        return s_edge.length * (t_t - s_t), [(s_edge, s_t, t_t)]

    outgoing = {}
    for edge in edges:
        outgoing.setdefault(edge.a_id, []).append(edge)

    start_cost = s_edge.length * (1 - s_t)
    best = {s_edge.b_id: start_cost}
    previous = {}
    queue = [(start_cost, s_edge.b_id)]
    while queue:
        cost, node = heapq.heappop(queue)
        if cost > best.get(node, math.inf):
            continue
        if node == t_edge.a_id:
            break
        for edge in outgoing.get(node, ()):
            next_cost = cost + edge.length
            if next_cost < best.get(edge.b_id, math.inf):
                best[edge.b_id] = next_cost
                previous[edge.b_id] = edge
                heapq.heappush(queue, (next_cost, edge.b_id))
    if t_edge.a_id not in best:
        return None
    steps = [(t_edge, 0.0, t_t)]
    node = t_edge.a_id
    while node != s_edge.b_id:
        edge = previous[node]
        steps.append((edge, 0.0, 1.0))
        node = edge.a_id
    steps.append((s_edge, s_t, 1.0))
    steps.reverse()
    return best[t_edge.a_id] + t_edge.length * t_t, steps


def _route(edges, start, end, expected):
    """Лучший путь start→end, сошедшийся с записанной длиной, или (None, причина).

    expected=None — длина ещё не измерена (только refresh): берём кратчайший.
    """
    sources, targets = _anchors(edges, start), _anchors(edges, end)
    if not sources or not targets:
        return None, "точка дальше %d м от полотна" % ANCHOR_REACH_METERS
    if expected is None:
        allowance, expected = math.inf, 0
    else:
        allowance = max(expected * LENGTH_TOLERANCE, LENGTH_TOLERANCE_MIN_METERS)
    best = None
    measured = None
    for source in sources:
        for target in targets:
            found = _path(edges, source, target)
            if found is None:
                continue
            measured = found[0] if measured is None else min(measured, found[0])
            if abs(found[0] - expected) <= allowance and (best is None or found[0] < best[0]):
                best = found
    if best is None:
        if measured is None:
            return None, "цепочка ref разорвана"
        return None, "длина %.0f м вместо %.0f м" % (measured, expected)
    return best, None


def _same_axis(first, second):
    diff = abs(first - second) % 180
    return min(diff, 180 - diff) <= NEIGHBOUR_AXIS_DEGREES


def _close_alongside(a, b, zone):
    """Лежит ли отрезок ab в пределах клиента от какого-нибудь шага зоны."""
    axis = _bearing(a, b)
    middle = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    for edge in zone:
        if not _same_axis(axis, _bearing(edge.a, edge.b)):
            continue
        for point in (a, middle, b):
            if _project(point[0], point[1], edge.a, edge.b)[0] <= NEIGHBOUR_REACH_METERS:
                return True
    return False


def _neighbour_conflict(steps, segments, ways, refs, limit):
    """Причина не применять зону или None. Съезды и дворы не в счёт: там лимит ниже.

    Смотрим только в рамке зоны: кандидатов там десятки, а крон ходит раз в месяц.
    """
    zone = [edge for edge, t0, t1 in steps if t1 > t0]
    lats = [value for edge in zone for value in (edge.a[0], edge.b[0])]
    lons = [value for edge in zone for value in (edge.a[1], edge.b[1])]
    margin = NEIGHBOUR_REACH_METERS / 111320.0 * 2
    low_lat, high_lat = min(lats) - margin, max(lats) + margin
    low_lon, high_lon = min(lons) - margin, max(lons) + margin

    def inside(point):
        return low_lat <= point[0] <= high_lat and low_lon <= point[1] <= high_lon

    own = {id(record["segment"]) for record in ways
           if record["refs"] & refs and record.get("segment") is not None}
    for limit_there, cls, flat in ((s[0], s[1], s[2]) for s in segments
                                   if s[0] > limit and id(s) not in own):
        if not 1 <= cls <= 5:
            continue
        points = [(flat[i], flat[i + 1]) for i in range(0, len(flat), 2)]
        for a, b in zip(points, points[1:]):
            if (inside(a) or inside(b)) and _close_alongside(a, b, zone):
                return "рядом дорога с лимитом %d у %.5f,%.5f" % (limit_there, a[0], a[1])
    for record in ways:
        if record["refs"] & refs or record["highway"] not in NEIGHBOUR_HIGHWAYS:
            continue
        points = [(node[1], node[2]) for node in record["nodes"]]
        for a, b in zip(points, points[1:]):
            if (inside(a) or inside(b)) and _close_alongside(a, b, zone):
                return "рядом другая магистраль (way %d) у %.5f,%.5f" % (record["id"], a[0], a[1])
    return None


def _intervals(steps):
    """Покрытие пути в параметрах way: {id way: [(p0, p1)]}, p = номер пары + t."""
    out = {}
    for edge, t0, t1 in steps:
        if edge.forward:
            low, high = edge.pos + t0, edge.pos + t1
        else:
            low, high = edge.pos + 1 - t1, edge.pos + 1 - t0
        if high > low:
            out.setdefault(edge.way["id"], []).append((low, high))
    return out


def _merge(intervals):
    merged = []
    for low, high in sorted(intervals):
        if merged and low <= merged[-1][1] + 1e-9:
            merged[-1] = (merged[-1][0], max(merged[-1][1], high))
        else:
            merged.append((low, high))
    return merged


def _at(nodes, position):
    pos = min(int(position), len(nodes) - 2)
    t = position - pos
    a, b = nodes[pos], nodes[pos + 1]
    return (round(a[1] + (b[1] - a[1]) * t, 5), round(a[2] + (b[2] - a[2]) * t, 5))


def _slice(nodes, low, high):
    """Кусок way между двумя параметрами, без повторов от округления."""
    points = [_at(nodes, low)]
    for pos in range(int(math.floor(low)) + 1, int(math.ceil(high))):
        points.append((round(nodes[pos][1], 5), round(nodes[pos][2], 5)))
    points.append(_at(nodes, high))
    unique = [points[0]]
    for point in points[1:]:
        if point != unique[-1]:
            unique.append(point)
    return unique


def _chunks(points):
    """Куски не длиннее MAX_POINTS_PER_SEGMENT с общей точкой на стыке."""
    step = MAX_POINTS_PER_SEGMENT - 1
    for begin in range(0, max(len(points) - 1, 1), step):
        part = points[begin:begin + step + 1]
        if len(part) >= 2:
            yield [value for point in part for value in point]


def _complement(intervals, count):
    """Части way вне поправки: они сохраняют свой тег."""
    out, cursor = [], 0.0
    for low, high in intervals:
        if low > cursor:
            out.append((cursor, low))
        cursor = high
    if cursor < count - 1:
        out.append((cursor, count - 1))
    return out


def _length(nodes, low, high):
    points = _slice(nodes, low, high)
    return sum(_meters(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:]))


def apply_overrides(segments, ways, doc):
    """Новый список сегментов и отчёт. Вход не меняется, повтор даёт то же самое.

    segments — как у extract_speed_limits.collect: [limit, cls, flat];
    ways — записи way() ниже: у way есть ссылка на СВОЙ сегмент, если тег был.
    """
    report = {"sha": fingerprint(doc), "applied": [], "failed": {}, "details": {}}
    claimed = {}   # id way -> [(p0, p1, limit)]
    by_id = {way["id"]: way for way in ways}
    for entry in verified(doc):
        refs = normalize_ref(";".join(entry["refs"]))
        edges = _edges(ways, refs)
        forward, why = _route(edges, entry["start"], entry["end"], entry["length_m"])
        backward = None
        if forward is not None:
            backward, why = _route(edges, entry["end"], entry["start"], entry["length_m"])
        if forward is None or backward is None:
            report["failed"][entry["id"]] = why
            continue
        neighbour = _neighbour_conflict(forward[1] + backward[1], segments, ways, refs, entry["limit"])
        if neighbour:
            report["failed"][entry["id"]] = neighbour
            continue
        covered = {}
        for way_id, parts in list(_intervals(forward[1]).items()) + list(_intervals(backward[1]).items()):
            covered.setdefault(way_id, []).extend(parts)
        conflict = None
        for way_id, parts in covered.items():
            for low, high in _merge(parts):
                for other_low, other_high, other_limit in claimed.get(way_id, ()):
                    if low < other_high and other_low < high and other_limit != entry["limit"]:
                        conflict = "пересекается с другой поправкой на way %d" % way_id
        if conflict:
            report["failed"][entry["id"]] = conflict
            continue
        for way_id, parts in covered.items():
            for low, high in _merge(parts):
                claimed.setdefault(way_id, []).append((low, high, entry["limit"]))
        report["applied"].append(entry["id"])
        report["details"][entry["id"]] = {
            "limit": entry["limit"],
            "forward_m": round(forward[0]),
            "backward_m": round(backward[0]),
            "ways": len(covered),
        }

    dropped = set()
    added = []
    stats = {"created": 0, "replaced": 0, "kept_lower_m": 0.0}
    for way_id in sorted(claimed):
        record = by_id[way_id]
        nodes = record["nodes"]
        old = record.get("segment")
        overlay = []
        for low, high, limit in claimed[way_id]:
            if old is not None and old[0] <= limit:
                if old[0] < limit:
                    stats["kept_lower_m"] += _length(nodes, low, high)
                continue
            overlay.append((low, high, limit))
        if not overlay:
            continue
        for limit in sorted({item[2] for item in overlay}):
            for low, high in _merge([(a, b) for a, b, c in overlay if c == limit]):
                for flat in _chunks(_slice(nodes, low, high)):
                    added.append([limit, record["cls"], flat])
                    stats["created"] += 1
        if old is not None:
            dropped.add(id(old))
            stats["replaced"] += 1
            for low, high in _complement(_merge([(a, b) for a, b, _ in overlay]), len(nodes)):
                for flat in _chunks(_slice(nodes, low, high)):
                    added.append([old[0], old[1], flat])
    stats["kept_lower_m"] = round(stats["kept_lower_m"])
    report["stats"] = stats

    result = [segment for segment in segments if id(segment) not in dropped]
    existing = {(segment[0], segment[1], tuple(segment[2])) for segment in result}
    for segment in added:
        key = (segment[0], segment[1], tuple(segment[2]))
        if key not in existing:
            existing.add(key)
            result.append(segment)
    return result, report


def way_record(way_id, highway, cls, tags_oneway, tags_ref, nodes, segment=None, junction=None):
    """Запись way для наложения. nodes — [(id узла, lat, lon)], из collect()."""
    if junction == "roundabout" or tags_oneway in ("yes", "1", "true"):
        oneway = 1
    elif tags_oneway == "-1":
        oneway = -1
    else:
        oneway = 0
    return {"id": way_id, "highway": highway, "cls": cls, "oneway": oneway,
            "refs": normalize_ref(tags_ref), "nodes": nodes, "segment": segment}


# --- Гейт публикации. Сервер пересобирает файл сам, а подпись ставится на маке.

def _segments_near(segments, probes):
    """Сегменты с рамкой у проб: иначе 21 тысяча × сотня проб на каждом запуске."""
    margin = PROBE_REACH_METERS / 111320.0 * 2
    lats = [probe[0] for probe in probes]
    lons = [probe[1] for probe in probes]
    low_lat, high_lat = min(lats) - margin, max(lats) + margin
    low_lon, high_lon = min(lons) - margin, max(lons) + margin
    out = []
    for limit, cls, flat in segments:
        if any(low_lat <= flat[i] <= high_lat and low_lon <= flat[i + 1] <= high_lon
               for i in range(0, len(flat), 2)):
            out.append((limit, cls, flat))
    return out


def _limit_at(probe, segments):
    best = None
    for limit, _cls, flat in segments:
        for i in range(0, len(flat) - 2, 2):
            distance, _ = _project(probe[0], probe[1], (flat[i], flat[i + 1]), (flat[i + 2], flat[i + 3]))
            if distance <= PROBE_REACH_METERS and (best is None or distance < best[0]):
                best = (distance, limit)
    return None if best is None else best[1]


def check_built(built, doc):
    """Применены ли поправки в собранном файле. ValueError с причиной — отказ.

    Отметка в файле говорит, с каким набором сервер собирал; пробы проверяют сам
    результат. Нужно и то и другое: без отметки не увидеть снятую поправку, без
    проб — файл, собранный не тем кодом или с разорвавшейся за месяц цепочкой.
    """
    entries = verified(doc)
    mark = built.get("limit_overrides")
    if not entries:
        # Аварийное снятие последней поправки: в файле ещё лежат её 80, и без
        # этой проверки его можно было бы подписать как чистый.
        if isinstance(mark, dict) and mark.get("applied"):
            raise ValueError("в репозитории поправок нет, а файл собран с %s: "
                             "выложите limit_overrides.json на сервер и пересоберите"
                             % ", ".join(mark["applied"]))
        return
    if not isinstance(mark, dict):
        raise ValueError("в файле нет отметки поправок: сервер собирал старым кодом "
                         "или без limit_overrides.json")
    expected = fingerprint(doc)
    if mark.get("sha") != expected:
        raise ValueError("файл собран с другим набором поправок (%s, в репозитории %s): "
                         "выложите limit_overrides.json на сервер и пересоберите"
                         % (mark.get("sha"), expected))
    applied = set(mark.get("applied") or [])
    for entry in entries:
        if entry["id"] not in applied:
            why = (mark.get("failed") or {}).get(entry["id"], "причина не записана")
            raise ValueError("поправка %s не применена сервером: %s" % (entry["id"], why))
    segments = built["segments"]
    for entry in entries:
        probes = entry.get("probes") or []
        if not probes:
            raise ValueError("поправка %s без проб: нечем проверить файл" % entry["id"])
        nearby = _segments_near(segments, probes)
        exact = 0
        for probe in probes:
            limit = _limit_at(probe, nearby)
            if limit is None:
                raise ValueError("поправка %s: у пробы %.5f,%.5f нет сегмента"
                                 % (entry["id"], probe[0], probe[1]))
            if limit > entry["limit"]:
                raise ValueError("поправка %s: у пробы %.5f,%.5f лимит %d вместо %d"
                                 % (entry["id"], probe[0], probe[1], limit, entry["limit"]))
            exact += limit == entry["limit"]
        if exact < PROBE_EXACT_SHARE * len(probes):
            raise ValueError("поправка %s: лимит %d только у %d проб из %d"
                             % (entry["id"], entry["limit"], exact, len(probes)))


def describe(report):
    """Строки для журнала крона: отказ виден глазами, а не только на подписи."""
    lines = []
    for ident in report["applied"]:
        detail = report["details"][ident]
        lines.append("поправка %s: %d км/ч, %d и %d м, way %d" % (
            ident, detail["limit"], detail["forward_m"], detail["backward_m"], detail["ways"]))
    for ident, why in sorted(report["failed"].items()):
        lines.append("ПОПРАВКА НЕ ПРИМЕНЕНА %s: %s" % (ident, why))
    stats = report["stats"]
    lines.append("поправки: новых сегментов %d, заменено way с тегом %d, оставлено тега ниже %d м" % (
        stats["created"], stats["replaced"], stats["kept_lower_m"]))
    return lines


# --- Доказательство привязки: километры зоны считаются из данных, а не пишутся.

def zone_km(boundary, anchors):
    """Километры точки зоны (низ, верх) по камерам, на которые она опирается.

    Смещение км − длина OSM у камеры с пикетом — одно число, у адреса «73 km
    oralig‘i» — полоса в километр: адрес значит «где-то в км 73–74».
    """
    by_camera = {anchor["camera"]: anchor for anchor in anchors}
    offsets = []
    for camera in boundary["anchors"]:
        anchor = by_camera[camera]
        for km in anchor["km"]:
            offsets.append(km - anchor["along_m"] / 1000.0)
    along = boundary["along_m"] / 1000.0
    return along + min(offsets), along + max(offsets)


def check_proof(entry):
    """ValueError, если по собственным данным зона выходит за участок решения."""
    proof = entry.get("proof")
    if not isinstance(proof, dict) or not proof.get("anchors"):
        raise ValueError("%s: нет данных привязки" % entry["id"])
    low, _ = zone_km(proof["start"], proof["anchors"])
    _, high = zone_km(proof["end"], proof["anchors"])
    if low < entry["km"][0] - 1e-6:
        raise ValueError("%s: начало зоны может лежать на км %.2f, участок с км %s"
                         % (entry["id"], low, entry["km"][0]))
    if high > entry["km"][1] + 1e-6:
        raise ValueError("%s: конец зоны может лежать на км %.2f, участок до км %s"
                         % (entry["id"], high, entry["km"][1]))
    return low, high


# --- Обновление проб и длины: раз OSM сдвинул полотно, гейт скажет об этом сам.

def measure(ways, entry):
    """Длины в обе стороны и пробы по обоим полотнам.

    Пробы — раз в километр и не ближе ста метров к концу зоны: у самого края
    снятая по другому полотну точка легко попадёт за границу зоны.
    """
    refs = normalize_ref(";".join(entry["refs"]))
    edges = _edges(ways, refs)
    paths = []
    for start, end in ((entry["start"], entry["end"]), (entry["end"], entry["start"])):
        found, why = _route(edges, start, end, None)
        if found is None:
            raise ValueError("%s: %s" % (entry["id"], why))
        paths.append(found)
    probes = []
    for length, steps in paths:
        spacing = min(1000.0, max(length / 4, 200.0))
        target, travelled = min(100.0, spacing / 2), 0.0
        for edge, t0, t1 in steps:
            piece = edge.length * (t1 - t0)
            while piece > 0 and target <= travelled + piece and target <= length - 100:
                t = t0 + (t1 - t0) * (target - travelled) / piece
                probes.append([round(edge.a[0] + (edge.b[0] - edge.a[0]) * t, 5),
                               round(edge.a[1] + (edge.b[1] - edge.a[1]) * t, 5)])
                target += spacing
            travelled += piece
    return {"length_m": round((paths[0][0] + paths[1][0]) / 2),
            "forward_m": round(paths[0][0]), "backward_m": round(paths[1][0]), "probes": probes}


def refresh(pbf, path=DEFAULT_PATH):
    """Переписать length_m и probes в файле поправок по выгрузке OSM. Только для людей."""
    from extract_speed_limits import collect
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    _segments, _skipped, ways = collect(pbf, wanted_refs(doc))
    for entry in verified(doc):
        check_proof(entry)
        measured = measure(ways, entry)
        entry["length_m"] = measured["length_m"]
        entry["probes"] = measured["probes"]
        print("%s: %d и %d м, проб %d" % (entry["id"], measured["forward_m"],
                                          measured["backward_m"], len(measured["probes"])))
    validate(doc)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, ensure_ascii=False, indent=1)
        handle.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description="поправки лимитов: отпечаток и обновление проб")
    parser.add_argument("--refresh", metavar="PBF", help="пересчитать length_m и probes по выгрузке OSM")
    parser.add_argument("--file", default=DEFAULT_PATH)
    args = parser.parse_args(argv)
    if args.refresh:
        refresh(args.refresh, args.file)
    doc = load(args.file)
    print(json.dumps({"sha": fingerprint(doc), "verified": [entry["id"] for entry in verified(doc)]},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
