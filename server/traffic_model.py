#!/usr/bin/env python3
"""Модель обычных пробок (33G, априорная) — как у навигаторов при запуске
в новом городе: пока водителей мало, «обычно в это время» берётся из самой
дороги. Константы — traffic_config.py (раздел «Модель»), у каждой причина.

Для каждого направленного ребра OSM (u, v) дорог города — множитель
скорости графа по слоту часа недели (168 слотов, понедельник 00:00 по
Ташкенту = 0, праздник — как воскресенье, traffic_build.week_slot):

    m(e, s) = max(MODEL_FLOOR, 1 − D(e) · C(s) · R(e, s))

  * D(e) — глубина пробки ребра, только из OSM и графа:
        D = min(D_max, base(класс) · S(светофоры) · Z(центр) · L(полосы)
                       + Z · (узел + выезд))
    base — класс дороги; S — перекрёстков со светофором своей улицы на км в
    ±400 м (0,6 без них → 1,0 с трёх на км); Z — близость к центру Ташкента
    (1 до 4 км, 0,5 на 12 км, 0 на 20 км); L — полосы в одну сторону; узел
    и выезд — небольшая прибавка у пересечений главных дорог и у въездов
    в город с ТКАД. D квантуется (MODEL_DEPTH_STEP);
  * C(s) — кривая часа по дню недели (будни, пятница, суббота, воскресенье),
    значение в начале часа; минута — смесь соседних слотов (α = m/60), как у
    профиля 33A;
  * R(e, s) — направление в пики будней: утром в центр, вечером из центра;
    встречная сторона легче на MODEL_DIR_SPLIT.

Модель — догадка, и правила её применения жёстче, чем у данных:
  * маршрутизатор берёт её с весом MODEL_W_ROUTE (половина разницы до
    графа), и только где итог < 0,85 графа — то есть где разница велика;
  * голос («Впереди пробка», объезд) — никогда, только живые данные;
  * карта — светлее и с подписью «обычно в это время»;
  * наблюдения водителей её вытесняют: v_typ = (n·v_med + k·v_prior)/(n+k)
    (traffic_profile.slot_typical).

Файл модели (`traffic_model.json.gz`, MODEL_PATH на VPS) собирается на маке
раз в месяц вместе с графом — тем же PBF, что граф OSRM (ключи — узлы OSM):

    python3 server/traffic_model.py build --pbf ~/RadarMapBuild/osrm/uzbekistan-latest.osm.pbf \\
        --osrm http://127.0.0.1:5794 --out ~/RadarMapBuild/traffic_model/traffic_model.json.gz

Сборке нужен pyosmium (только на маке, как build_camera_candidates.py) и
OSRM того же графа: скорость графа ребра берётся из ответа `route`
(annotations distance/duration — та же мера, что traffic_edges.model_kmh
из `match`), а не пересчитывается из car_radarmap.lua — в режиме weight
она задаёт время ребра, и ошибка сдвинула бы ETA всем. Сервер читает
файл stdlib-ом (load_model).

Формат v1 (детерминирован: сортировка по ключу, целые проценты, координаты
до 1e-5°, скорость графа до 0,1 км/ч; ни времени сборки, ни чего-либо о
людях — модель только из OSM):
    {"v":1, "curves":[[168 × процент графа]], "edges":[[u, v, ulat, ulon, vlat, vlon, км/ч графа, кривая]]}
"""
import argparse
import gzip
import json
import math
import os
import sys

import traffic_config as tc

SLOTS = 168


# --- Чистые формулы ---------------------------------------------------------------

def class_base(cls):
    """Глубина класса; класса нет в модели — 0 (жилые, сервисные, …)."""
    return tc.MODEL_CLASS_BASE.get(cls, 0.0)


def signal_factor(per_km):
    """S: 0,6 без светофоров → 1,0 с MODEL_SIGNAL_FULL на км; не убывает."""
    share = min(max(per_km, 0.0), tc.MODEL_SIGNAL_FULL) / tc.MODEL_SIGNAL_FULL
    return tc.MODEL_SIGNAL_MIN_FACTOR + (1.0 - tc.MODEL_SIGNAL_MIN_FACTOR) * share


def centre_factor(km):
    """Z: 1 до CORE, к MID — MID_FACTOR, к EDGE — 0; не растёт с расстоянием."""
    if km <= tc.MODEL_CENTRE_CORE_KM:
        return 1.0
    if km <= tc.MODEL_CENTRE_MID_KM:
        t = (km - tc.MODEL_CENTRE_CORE_KM) / (tc.MODEL_CENTRE_MID_KM - tc.MODEL_CENTRE_CORE_KM)
        return 1.0 - (1.0 - tc.MODEL_CENTRE_MID_FACTOR) * t
    if km <= tc.MODEL_CENTRE_EDGE_KM:
        t = (km - tc.MODEL_CENTRE_MID_KM) / (tc.MODEL_CENTRE_EDGE_KM - tc.MODEL_CENTRE_MID_KM)
        return tc.MODEL_CENTRE_MID_FACTOR * (1.0 - t)
    return 0.0


def lane_factor(lanes):
    """L по полосам в одну сторону; неизвестно — 1."""
    if not lanes or lanes <= 0:
        return 1.0
    return tc.MODEL_LANE_FACTOR.get(min(int(lanes), max(tc.MODEL_LANE_FACTOR)), 1.0)


def depth(cls, lanes=None, signals_per_km=0.0, centre_km=0.0, near_node=False, near_exit=False):
    """D(e), квантованная до MODEL_DEPTH_STEP, в [0, MODEL_DEPTH_MAX]."""
    z = centre_factor(centre_km)
    raw = class_base(cls) * signal_factor(signals_per_km) * z * lane_factor(lanes)
    if raw > 0:
        raw += z * ((tc.MODEL_NODE_BONUS if near_node else 0.0) + (tc.MODEL_EXIT_BONUS if near_exit else 0.0))
    raw = min(tc.MODEL_DEPTH_MAX, max(0.0, raw))
    return round(round(raw / tc.MODEL_DEPTH_STEP) * tc.MODEL_DEPTH_STEP, 4)


def day_curve(slot):
    """C(s) — значение кривой в начале часа недели `slot` (0 — пн 00:00)."""
    day, hour = divmod(slot % SLOTS, 24)
    table = (tc.MODEL_CURVE_WEEKDAY if day < 4 else tc.MODEL_CURVE_FRIDAY if day == 4
             else tc.MODEL_CURVE_SATURDAY if day == 5 else tc.MODEL_CURVE_SUNDAY)
    return table[hour]


def quantize_radial(radial):
    """Радиальность ребра (−1 из центра … 1 в центр) → {−1, −0,5, 0, 0,5, 1}."""
    return max(-1.0, min(1.0, round(radial * 2) / 2))


def direction_factor(slot, radial):
    """R(e, s): в пики будней встречная пику сторона легче на MODEL_DIR_SPLIT
    (утром — из центра, вечером — в центр); в остальное время 1."""
    day, hour = divmod(slot % SLOTS, 24)
    if day > 4 or not radial:
        return 1.0
    if tc.MODEL_DIR_MORNING[0] <= hour < tc.MODEL_DIR_MORNING[1]:
        return 1.0 - tc.MODEL_DIR_SPLIT * max(0.0, -radial)
    if tc.MODEL_DIR_EVENING[0] <= hour < tc.MODEL_DIR_EVENING[1]:
        return 1.0 - tc.MODEL_DIR_SPLIT * max(0.0, radial)
    return 1.0


def multiplier(d, slot, radial=0.0):
    """m(e, s) = max(пол, 1 − D·C·R) — доля скорости графа в начале часа."""
    return max(tc.MODEL_FLOOR, 1.0 - d * day_curve(slot) * direction_factor(slot, radial))


def curve(d, radial=0.0):
    """168 множителей ребра в целых процентах графа (детерминизм файла)."""
    return [int(round(100 * multiplier(d, slot, radial))) for slot in range(SLOTS)]


def mixed(curve_pct, mix):
    """Множитель момента по смеси слотов [(слот, вес)] (traffic_profile.slot_mix)."""
    return sum(weight * curve_pct[slot] / 100.0 for slot, weight in mix)


def route_prior(v_graph, mult, w=None):
    """Опора маршрутизатора: граф минус w-доля (MODEL_W_ROUTE) разницы до модели."""
    w = tc.MODEL_W_ROUTE if w is None else w
    return v_graph * (1.0 - w * (1.0 - mult))


# --- Геометрия ---------------------------------------------------------------------

def meters(lat1, lon1, lat2, lon2):
    k = math.cos(math.radians((lat1 + lat2) / 2)) * 111320.0
    return math.hypot((lon2 - lon1) * k, (lat2 - lat1) * 111320.0)


def bearing(lat1, lon1, lat2, lon2):
    k = math.cos(math.radians((lat1 + lat2) / 2))
    return math.degrees(math.atan2((lon2 - lon1) * k, lat2 - lat1)) % 360


def centre_km(lat, lon):
    return meters(lat, lon, *tc.MODEL_CENTRE) / 1000.0


def radial(ulat, ulon, vlat, vlon):
    """cos угла между ребром и направлением на центр от его середины; внутри
    MODEL_DIR_INNER_KM — 0 (центр во все стороны)."""
    mlat, mlon = (ulat + vlat) / 2, (ulon + vlon) / 2
    if centre_km(mlat, mlon) < tc.MODEL_DIR_INNER_KM or (ulat == vlat and ulon == vlon):
        return 0.0
    edge = bearing(ulat, ulon, vlat, vlon)
    to_centre = bearing(mlat, mlon, *tc.MODEL_CENTRE)
    return math.cos(math.radians(edge - to_centre))


class Grid:
    """Точки по ячейкам ~550 м для поиска «в радиусе R»."""
    CELL = 0.005

    def __init__(self):
        self.cells = {}

    def key(self, lat, lon):
        return int(math.floor(lat / self.CELL)), int(math.floor(lon / self.CELL))

    def add(self, lat, lon, item):
        self.cells.setdefault(self.key(lat, lon), []).append((lat, lon, item))

    def near(self, lat, lon, radius):
        reach = int(math.ceil(radius / (self.CELL * 111320.0 * 0.75))) + 1
        y, x = self.key(lat, lon)
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                for plat, plon, item in self.cells.get((y + dy, x + dx), ()):
                    if meters(lat, lon, plat, plon) <= radius:
                        yield item


def cluster(points, radius):
    """Точки ближе `radius` — одна (жадно по порядку): [(lat, lon, [элементы])].
    Порядок входа задаёт результат — вход сортируется вызывающим."""
    grid, out = Grid(), []
    for lat, lon, item in points:
        hit = next(iter(grid.near(lat, lon, radius)), None)
        if hit is None:
            out.append((lat, lon, [item]))
            grid.add(lat, lon, len(out) - 1)
        else:
            out[hit][2].append(item)
    return out


# --- Признаки рёбер (чистая часть сборки) -------------------------------------------

def lanes_per_direction(tags, oneway):
    """Полосы в одну сторону по тегам OSM; неизвестно — None."""
    def number(value):
        try:
            return int(str(value).split(";")[0])
        except (TypeError, ValueError):
            return None
    total = number(tags.get("lanes"))
    if oneway:
        return total
    forward = number(tags.get("lanes:forward"))
    if forward:
        return forward
    return max(1, total // 2) if total else None


def oneway_of(tags):
    """1 — по ходу пути, −1 — против, 0 — в обе стороны."""
    value = tags.get("oneway")
    if value in ("yes", "true", "1"):
        return 1
    if value == "-1":
        return -1
    if value in ("no", "false", "0"):
        return 0
    if tags.get("junction") in ("roundabout", "circular") or tags.get("highway") in ("motorway", "motorway_link"):
        return 1
    return 0


def edge_features(ways, coords, signal_names, majors, exits):
    """Признаки каждого направленного ребра модели.

    ways — [(way_id, tags, [узлы])], coords — {узел: (lat, lon)},
    signal_names — [(lat, lon, frozenset имён улиц узла)] перекрёстков со
    светофором (уже слитых), majors / exits — [(lat, lon)] крупных узлов и
    выездов. Возвращает {(u, v): (класс, полос, светофоров на км, км до
    центра, у узла, у выезда, радиальность)}; на общем ребре двух путей —
    путь с большим классом (меньшим по порядку MODEL_CLASS_BASE)."""
    sig_grid, major_grid, exit_grid = Grid(), Grid(), Grid()
    for i, (lat, lon, names) in enumerate(signal_names):
        sig_grid.add(lat, lon, names)
    for lat, lon in majors:
        major_grid.add(lat, lon, 1)
    for lat, lon in exits:
        exit_grid.add(lat, lon, 1)
    rank = {cls: i for i, cls in enumerate(sorted(tc.MODEL_CLASS_BASE, key=lambda c: -tc.MODEL_CLASS_BASE[c]))}
    out = {}
    window_km = 2 * tc.MODEL_SIGNAL_RADIUS / 1000.0
    for way_id, tags, nodes in sorted(ways, key=lambda w: w[0]):
        cls = tags.get("highway")
        if cls not in tc.MODEL_CLASS_BASE:
            continue
        name = tags.get("name") or tags.get("ref") or f"#{way_id}"
        direction = oneway_of(tags)
        lanes = lanes_per_direction(tags, direction != 0)
        for a, b in zip(nodes, nodes[1:]):
            if a not in coords or b not in coords or a == b:
                continue
            (alat, alon), (blat, blon) = coords[a], coords[b]
            mlat, mlon = (alat + blat) / 2, (alon + blon) / 2
            signals = sum(1 for names in sig_grid.near(mlat, mlon, tc.MODEL_SIGNAL_RADIUS) if name in names)
            near_node = next(iter(major_grid.near(mlat, mlon, tc.MODEL_NODE_RADIUS)), None) is not None
            near_exit = next(iter(exit_grid.near(mlat, mlon, tc.MODEL_EXIT_RADIUS)), None) is not None
            km = centre_km(mlat, mlon)
            pairs = [(a, b)] if direction == 1 else [(b, a)] if direction == -1 else [(a, b), (b, a)]
            for u, v in pairs:
                (ulat, ulon), (vlat, vlon) = coords[u], coords[v]
                feature = (cls, lanes, signals / window_km, km, near_node, near_exit,
                           radial(ulat, ulon, vlat, vlon))
                old = out.get((u, v))
                if old is None or rank[cls] < rank[old[0]]:
                    out[(u, v)] = feature
    return out


def curve_key(feature):
    cls, lanes, per_km, km, near_node, near_exit, rad = feature
    d = depth(cls, lanes, per_km, km, near_node, near_exit)
    return d, (quantize_radial(rad) if d > 0 else 0.0)


def model_payload(features, coords, graph_kmh):
    """Файл модели: рёбра с глубиной > 0 и известной скоростью графа, у
    которых множитель хоть в одном слоте < WRITE_RATIO (иначе модель о них
    ничего не говорит). Кривые — по (глубина, радиальность), нумерация по
    порядку ключа: одинаковый вход — одинаковые байты."""
    keys = {}
    rows = []
    for edge in sorted(features):
        model = graph_kmh.get(edge)
        if not model or model <= 0:
            continue
        key = curve_key(features[edge])
        if key[0] <= 0 or min(curve(*key)) >= 100 * tc.WRITE_RATIO:
            continue
        keys.setdefault(key, None)
        rows.append((edge, key, model))
    ordered = sorted(keys)
    index = {key: i for i, key in enumerate(ordered)}
    edges = []
    for (u, v), key, model in rows:
        (ulat, ulon), (vlat, vlon) = coords[u], coords[v]
        edges.append([u, v, round(ulat, 5), round(ulon, 5), round(vlat, 5), round(vlon, 5),
                      round(model, 1), index[key]])
    return {"v": tc.MODEL_VERSION, "curves": [curve(*key) for key in ordered], "edges": edges}


def cap_payload(payload, max_edges=tc.MODEL_MAX_EDGES, max_bytes=tc.MODEL_MAX_FILE_BYTES):
    """Инвариант 5: сверх потолка — рёбра по убыванию значимости (длина ×
    наибольшее замедление). (payload, обрезано)."""
    edges = payload["edges"]

    def body(items):
        return json.dumps(dict(payload, edges=items), separators=(",", ":"))

    if len(edges) <= max_edges and len(gzip.compress(body(edges).encode(), 6, mtime=0)) <= max_bytes:
        return payload, 0
    curves = payload["curves"]

    def weight(e):
        return (-meters(e[2], e[3], e[4], e[5]) * (1 - min(curves[e[7]]) / 100.0), e[0], e[1])
    ranked = sorted(edges, key=weight)[:max_edges]
    while ranked and len(gzip.compress(body(sorted(ranked)).encode(), 6, mtime=0)) > max_bytes:
        ranked = ranked[:int(len(ranked) * 0.9)]
    return dict(payload, edges=sorted(ranked)), len(edges) - len(ranked)


def model_bytes(payload):
    """gzip без метки времени — побайтно одинаковый файл на одинаковый вход."""
    return gzip.compress(json.dumps(payload, separators=(",", ":")).encode(), 9, mtime=0)


# --- Чтение на сервере (stdlib) --------------------------------------------------------

_CACHE = {}


def load_model(path=tc.MODEL_PATH, enabled=None):
    """{(u, v): (км/ч графа, кривая — 168 процентов, (ulat, ulon, vlat, vlon))}
    или {} — нет файла, выключено, чужая версия, битый файл (отказ = граф).
    Кэш по mtime: стенд читает файл каждые 5 минут."""
    if not (tc.LAYER_MODEL if enabled is None else enabled) or not path:
        return {}
    try:
        stamp = os.stat(path).st_mtime_ns
    except FileNotFoundError:
        return {}
    cached = _CACHE.get(path)
    if cached and cached[0] == stamp:
        return cached[1]
    try:
        with gzip.open(path, "rt", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("v") != tc.MODEL_VERSION:
            raise ValueError(f"версия {data.get('v')!r}")
        curves = [tuple(int(x) for x in c) for c in data["curves"]]
        if any(len(c) != SLOTS or min(c) < 100 * tc.MODEL_FLOOR - 0.5 or max(c) > 100 for c in curves):
            raise ValueError("кривая вне [пол, 100]")
        out = {}
        for u, v, ulat, ulon, vlat, vlon, model, k in data["edges"][:tc.MODEL_MAX_EDGES]:
            if model > 0:
                out[(int(u), int(v))] = (float(model), curves[k], (ulat, ulon, vlat, vlon))
    except (OSError, ValueError, KeyError, TypeError, IndexError, EOFError) as error:
        print(f"модель пробок {path} не прочитана ({error}) — без модели", file=sys.stderr)
        out = {}
    _CACHE[path] = (stamp, out)
    return out


# --- Сборка на маке (pyosmium + OSRM) -----------------------------------------------------

def read_osm(pbf, bbox=tc.MODEL_BBOX):
    """(пути [(id, теги, узлы)], координаты {узел: (lat, lon)}, светофоры
    [(lat, lon, узел)], {узел: {(id пути, класс, имя)}}). pyosmium — только
    здесь: серверу он не нужен."""
    import osmium
    south, west, north, east = bbox
    wanted = set(tc.MODEL_CLASS_BASE)
    ways, coords, signals, members = [], {}, [], {}

    class Handler(osmium.SimpleHandler):
        def node(self, n):
            if n.tags.get("highway") == "traffic_signals" or n.tags.get("crossing") == "traffic_signals":
                if south <= n.location.lat <= north and west <= n.location.lon <= east:
                    signals.append((n.location.lat, n.location.lon, n.id))

        def way(self, w):
            cls = w.tags.get("highway")
            if cls not in wanted or w.tags.get("area") == "yes":
                return
            nodes, inside = [], False
            for n in w.nodes:
                if not n.location.valid():
                    continue
                lat, lon = n.location.lat, n.location.lon
                inside |= south <= lat <= north and west <= lon <= east
                coords[n.ref] = (lat, lon)
                nodes.append(n.ref)
            if not inside or len(nodes) < 2:
                return
            tags = {k: w.tags.get(k) for k in ("highway", "name", "ref", "lanes", "lanes:forward",
                                                "oneway", "junction") if w.tags.get(k) is not None}
            ways.append((w.id, tags, nodes))
            name = tags.get("name") or tags.get("ref") or f"#{w.id}"
            for ref in nodes:
                members.setdefault(ref, set()).add((w.id, cls, name))

    Handler().apply_file(pbf, locations=True)
    return ways, coords, signals, members


def junctions(members, coords):
    """(светофорные перекрёстки [(lat, lon, имена)] — заполняет вызывающий,
    крупные узлы [(lat, lon)], выезды [(lat, lon)]) по членству узлов."""
    big = {"motorway", "trunk", "primary"}
    points = []
    for ref in sorted(members):
        roads = members[ref]
        names = {name for _, cls, name in roads if cls in big}
        if len(names) >= 2 and ref in coords:
            lat, lon = coords[ref]
            fast = any(cls in ("motorway", "trunk") for _, cls, _ in roads)
            points.append((lat, lon, fast))
    clusters = cluster(points, tc.MODEL_NODE_CLUSTER)
    majors = [(lat, lon) for lat, lon, _ in clusters]
    lo, hi = tc.MODEL_EXIT_RING_KM
    exits = [(lat, lon) for lat, lon, items in clusters if any(items) and lo <= centre_km(lat, lon) <= hi]
    return majors, exits


def signal_junctions(signals, members):
    """Светофоры → перекрёстки (ближе MODEL_SIGNAL_CLUSTER — один) с именами
    улиц, на которых они стоят. Светофор не на дороге модели — не в счёт."""
    on_roads = sorted((lat, lon, ref) for lat, lon, ref in signals if ref in members)
    out = []
    for lat, lon, refs in cluster(on_roads, tc.MODEL_SIGNAL_CLUSTER):
        names = frozenset(name for ref in refs for _, _, name in members[ref])
        out.append((lat, lon, names))
    return out


def osrm_graph_speeds(ways, coords, edges, base, workers=8, timeout=20):
    """{(u, v): км/ч графа} из ответов `route` вдоль каждого пути в каждую
    его сторону (annotations distance/duration — мера traffic_edges.model_kmh).
    Ребро, которого путь OSRM не прошёл, остаётся без скорости — и без модели."""
    import concurrent.futures
    import urllib.request

    def request(nodes):
        (alat, alon), (blat, blon) = coords[nodes[0]], coords[nodes[1]]
        (clat, clon), (dlat, dlon) = coords[nodes[-2]], coords[nodes[-1]]
        start = (alat + (blat - alat) * 0.05, alon + (blon - alon) * 0.05)
        end = (clat + (dlat - clat) * 0.95, clon + (dlon - clon) * 0.95)
        b0 = int(round(bearing(alat, alon, blat, blon))) % 360
        b1 = int(round(bearing(clat, clon, dlat, dlon))) % 360
        url = (f"{base.rstrip('/')}/route/v1/driving/{start[1]:.6f},{start[0]:.6f};{end[1]:.6f},{end[0]:.6f}"
               f"?overview=false&annotations=nodes,distance,duration&bearings={b0},20;{b1},20"
               "&radiuses=8;8&continue_straight=true&alternatives=false")
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                body = json.loads(resp.read())
        except (OSError, ValueError):
            return []
        out = []
        for route in (body.get("routes") or [])[:1]:
            for leg in route.get("legs") or []:
                ann = leg.get("annotation") or {}
                ids, dist, dur = ann.get("nodes") or [], ann.get("distance") or [], ann.get("duration") or []
                for i in range(min(len(dist), len(dur), len(ids) - 1)):
                    if dist[i] > 0 and dur[i] > 0:
                        out.append(((ids[i], ids[i + 1]), dist[i], dist[i] / dur[i] * 3.6))
        return out

    jobs = []
    for _way_id, tags, nodes in ways:
        nodes = [n for n in nodes if n in coords]
        if len(nodes) < 2:
            continue
        direction = oneway_of(tags)
        if direction >= 0:
            jobs.append(nodes)
        if direction <= 0:
            jobs.append(nodes[::-1])
    best = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for done, result in enumerate(pool.map(request, jobs), 1):
            for edge, dist, kmh in result:
                if edge in edges and (edge not in best or dist > best[edge][0]):
                    best[edge] = (dist, kmh)
            if done % 2000 == 0:
                print(f"  OSRM: путей {done} из {len(jobs)}, рёбер со скоростью {len(best)}", file=sys.stderr)
    return {edge: round(kmh, 1) for edge, (_, kmh) in best.items()}


def cmd_build(args):
    print("→ OSM: пути, узлы, светофоры…", file=sys.stderr)
    ways, coords, signals, members = read_osm(args.pbf)
    majors, exits = junctions(members, coords)
    lights = signal_junctions(signals, members)
    print(f"  путей {len(ways)}, светофорных перекрёстков {len(lights)}, крупных узлов {len(majors)}, "
          f"выездов {len(exits)}", file=sys.stderr)
    features = edge_features(ways, coords, lights, majors, exits)
    wanted = {edge for edge, f in features.items() if curve_key(f)[0] > 0}
    print(f"→ OSRM {args.osrm}: скорость графа {len(wanted)} рёбер…", file=sys.stderr)
    graph = osrm_graph_speeds(ways, coords, wanted, args.osrm, workers=args.workers)
    payload, trimmed = cap_payload(model_payload(features, coords, graph))
    data = model_bytes(payload)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    tmp = args.out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, args.out)
    missing = len(wanted) - len(graph)
    print(f"✓ модель: рёбер {len(payload['edges'])}, кривых {len(payload['curves'])}, без скорости графа "
          f"{missing}, обрезано {trimmed}, {len(data) // 1024} КБ → {args.out}")
    return 0


def cmd_show(args):
    """Сводка файла: рёбер по множителю в слоте (проверка руками)."""
    model = load_model(args.model, enabled=True)
    slot = args.slot
    buckets = {}
    for _edge, (_g, c, _coords) in model.items():
        m = c[slot]
        key = "< 0,55" if m < 55 else "< 0,70" if m < 70 else "< 0,85" if m < 85 else "≥ 0,85"
        buckets[key] = buckets.get(key, 0) + 1
    print(f"слот {slot}: рёбер {len(model)}; " + ", ".join(f"{k}: {v}" for k, v in sorted(buckets.items())))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Модель обычных пробок (33G)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--pbf", required=True)
    b.add_argument("--osrm", required=True, help="OSRM того же графа, что стенд (скорость графа ребра)")
    b.add_argument("--out", required=True)
    b.add_argument("--workers", type=int, default=8)
    s = sub.add_parser("show")
    s.add_argument("--model", default=tc.MODEL_PATH)
    s.add_argument("--slot", type=int, default=18)
    args = parser.parse_args(argv)
    return cmd_build(args) if args.cmd == "build" else cmd_show(args)


if __name__ == "__main__":
    sys.exit(main())
