#!/usr/bin/env python3
"""Аудит качества маршрутов OSRM (29.E, 25.10.2026).

Берёт пары «откуда → куда» (audit_pairs.json), строит маршруты тем же
запросом, что приложение (alternatives, steps), и ищет то, за что местный
водитель назовёт навигатор глупым: транзит через дворы и service-проезды,
петли и развороты, левые повороты через встречку без светофора, нарушения
запретов поворотов, «поверните» на прямой, прибытие через разделительную, ETA
против того, как едут люди (профиль traffic_build).

    # 1. ответы движка (бережно: ≤ 1 запрос/с к публичному эндпоинту)
    python3 route_audit.py fetch --base https://soulmed.uz/radarmap/osrm --out runs/prod
    python3 route_audit.py fetch --base http://127.0.0.1:5101 --out runs/local --delay 0
    # 2. теги OSM под маршрутами (pyosmium, локальная выгрузка) — один раз на набор
    python3 route_audit.py index --pbf uzbekistan-latest.osm.pbf --runs runs/prod runs/local --out tags.json
    # 3. разбор: таблица в stdout и JSON для отчёта
    python3 route_audit.py analyze --runs runs/prod --tags tags.json --out prod.json
    # 4. картинки: спецификация для render_routes.swift (фон — roads.geojsonl)
    python3 route_audit.py render --runs runs/prod runs/local --roads roads.geojsonl --out shots/

Только чтение: ничего не пишет на сервер и не меняет граф. pyosmium нужен
только шагу index (он же — в build_camera_candidates.py); остальное — stdlib.
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.request
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PAIRS = os.path.join(HERE, "audit_pairs.json")

# Классы дорог, по которым местный водитель НЕ едет транзитом.
YARD = {"service", "living_street", "track", "pedestrian"}
MINOR = YARD | {"residential", "unclassified"}
MAJOR = {"motorway", "trunk", "primary", "secondary",
         "motorway_link", "trunk_link", "primary_link", "secondary_link"}
# Край маршрута, где двор законен: выезд от дома и заезд к цели.
EDGE_METERS = 400.0
# Светофор «на этом перекрёстке»: узлы двух проезжих частей проспекта
# разнесены на 20–40 м, сигнал стоит на каждой.
SIGNAL_RADIUS = 40.0
# «Поверните» при изломе меньше этого — команда на почти прямой.
STRAIGHT_DEGREES = 30.0
# Молчаливый поворот: new name/continue на перекрёстке с изломом больше этого.
SILENT_DEGREES = 55.0
# Петля: тот же узел дважды на отрезке короче этого.
LOOP_METERS = 2500.0
# Городская часть ETA — шаги со скоростью графа ниже этой (км/ч).
URBAN_KMH = 62.0
# Насколько дольше графа едут люди по рёбрам Ташкента (traffic_profile на
# VPS, 25.10.2026, 16,8 тыс. проходов рёбер; время факта / время графа).
# Мало водителей — оценка, не закон; в отчёте сказано так же.
HOUR_FACTOR = {8: 1.41, 13: 1.02, 19: 1.71}


def load_pairs(path=PAIRS):
    with open(path) as f:
        return json.load(f)["pairs"]


def route_url(base, pair, alternatives="true", extra=""):
    (alat, alon), (blat, blon) = pair["from"], pair["to"]
    return (f"{base.rstrip('/')}/route/v1/driving/{alon:.6f},{alat:.6f};{blon:.6f},{blat:.6f}"
            f"?overview=full&geometries=geojson&alternatives={alternatives}&steps=true"
            "&annotations=nodes,distance,duration,speed" + extra)


def cmd_fetch(args):
    os.makedirs(args.out, exist_ok=True)
    for i, pair in enumerate(load_pairs(args.pairs)):
        target = os.path.join(args.out, pair["id"] + ".json")
        if os.path.exists(target) and not args.force:
            continue
        if i and args.delay:
            time.sleep(args.delay)
        req = urllib.request.Request(route_url(args.base, pair, args.alternatives, args.extra),
                                     headers={"User-Agent": "RadarMap-route-audit/1"})
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
        with open(target, "wb") as f:
            f.write(body)
        print("ok", pair["id"], len(body))


# --------------------------------------------------------------------- index

def run_files(dirs):
    for d in dirs:
        for name in sorted(os.listdir(d)):
            if name.endswith(".json"):
                yield os.path.join(d, name)


def route_nodes(resp):
    nodes = set()
    for route in resp.get("routes", []):
        for leg in route["legs"]:
            nodes.update(leg.get("annotation", {}).get("nodes", []))
    return nodes


def cmd_index(args):
    import osmium  # только здесь

    wanted = set()
    for path in run_files(args.runs):
        with open(path) as f:
            wanted |= route_nodes(json.load(f))
    print("узлов под маршрутами:", len(wanted), file=sys.stderr)
    keep = ("highway", "service", "oneway", "name", "lanes", "maxspeed", "junction",
            "access", "motor_vehicle", "turn:lanes", "dual_carriageway")
    ways, signals, restrictions = {}, [], []

    class Handler(osmium.SimpleHandler):
        def node(self, n):
            if n.tags.get("highway") == "traffic_signals":
                signals.append((n.id, n.location.lat, n.location.lon))

        def way(self, w):
            if "highway" not in w.tags:
                return
            refs = [n.ref for n in w.nodes]
            if not any(r in wanted for r in refs):
                return
            ways[w.id] = {"tags": {k: w.tags[k] for k in keep if k in w.tags}, "nodes": refs}

        def relation(self, r):
            if r.tags.get("type") != "restriction":
                return
            # except=motorcar — запрет не для легковых, OSRM его не применяет
            if any(v in ("motorcar", "motor_vehicle", "vehicle")
                   for v in r.tags.get("except", "").replace(" ", "").split(";")):
                return
            kind = r.tags.get("restriction") or r.tags.get("restriction:motorcar") or ""
            members = {"from": [], "via": [], "to": []}
            for m in r.members:
                if m.role in members:
                    members[m.role].append((m.type, m.ref))
            restrictions.append({"id": r.id, "kind": kind, **members})

    Handler().apply_file(args.pbf, locations=True)
    with open(args.out, "w") as f:
        json.dump({"ways": ways, "signals": signals, "restrictions": restrictions}, f)
    print(f"путей {len(ways)}, светофоров {len(signals)}, запретов {len(restrictions)}", file=sys.stderr)


# ------------------------------------------------------------------- analyze

def meters(a, b):
    """Расстояние (lat, lon) → (lat, lon), м; равноугольно, для городских масштабов."""
    dy = (b[0] - a[0]) * 111320.0
    dx = (b[1] - a[1]) * 111320.0 * math.cos(math.radians((a[0] + b[0]) / 2))
    return math.hypot(dx, dy)


class Tags:
    def __init__(self, data):
        self.ways = {int(k): v for k, v in data["ways"].items()}
        self.pair = {}
        for wid, w in self.ways.items():
            refs = w["nodes"]
            for a, b in zip(refs, refs[1:]):
                self.pair[(a, b)] = wid
                self.pair[(b, a)] = wid
        # Сетка светофоров 0,005° — поиск соседей за O(1).
        self.signal_grid = defaultdict(list)
        for _, lat, lon in data["signals"]:
            self.signal_grid[(int(lat / 0.005), int(lon / 0.005))].append((lat, lon))
        self.no_turn = set()
        self.only_turn = {}
        for r in data["restrictions"]:
            if not (r["from"] and r["to"] and r["via"]) or r["via"][0][0] != "n":
                continue  # запреты через путь (via=way) здесь не судим
            f, v, t = r["from"][0][1], r["via"][0][1], r["to"][0][1]
            if r["kind"].startswith("no_"):
                self.no_turn.add((f, v, t))
            elif r["kind"].startswith("only_"):
                self.only_turn[(f, v)] = t

    def highway(self, wid):
        return self.ways.get(wid, {}).get("tags", {}).get("highway", "?") if wid else "?"

    def tag(self, wid, key):
        return self.ways.get(wid, {}).get("tags", {}).get(key) if wid else None

    def signal_near(self, lat, lon, radius=SIGNAL_RADIUS):
        cy, cx = int(lat / 0.005), int(lon / 0.005)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for p in self.signal_grid.get((cy + dy, cx + dx), ()):
                    if meters((lat, lon), p) <= radius:
                        return True
        return False


def angle_between(before, after):
    d = (after - before + 540) % 360 - 180
    return d  # >0 — вправо


def bearing(a, b):
    dy = b[0] - a[0]
    dx = (b[1] - a[1]) * math.cos(math.radians(a[0]))
    return math.degrees(math.atan2(dx, dy)) % 360


def geometric_bend(coords, along, k, before=30.0, after=60.0):
    """Излом линии в точке k: курс за `before` м до против курса за `after` м после."""
    if not coords or k <= 0 or k >= len(coords) - 1:
        return 0.0
    i = k
    while i > 0 and along[k] - along[i] < before:
        i -= 1
    j = k
    while j < len(coords) - 1 and j < len(along) - 1 and along[j] - along[k] < after:
        j += 1
    if i == k or j == k:
        return 0.0
    return angle_between(bearing(coords[i], coords[k]), bearing(coords[k], coords[j]))


def analyze_route(route, tags, rank):
    coords = []      # (lat, lon) вдоль всей линии
    nodes, dist, speed, dur = [], [], [], []
    for leg in route["legs"]:
        ann = leg["annotation"]
        nodes += ann["nodes"]
        dist += ann["distance"]
        speed += ann["speed"]
        dur += ann["duration"]
    coords = [(c[1], c[0]) for c in route["geometry"]["coordinates"]]
    total = route["distance"]
    along = [0.0]
    for d in dist:
        along.append(along[-1] + d)
    edge = min(EDGE_METERS, total * 0.15)

    seg_way = [tags.pair.get((a, b)) for a, b in zip(nodes, nodes[1:])]
    by_class = defaultdict(float)
    yard_mid, minor_mid = 0.0, 0.0
    yard_spans = []
    span = None
    for i, wid in enumerate(seg_way):
        if i >= len(dist):
            break
        cls = tags.highway(wid)
        by_class[cls] += dist[i]
        mid = edge <= along[i] <= total - edge
        if mid and cls in MINOR:
            minor_mid += dist[i]
        if mid and cls in YARD:
            yard_mid += dist[i]
            if span is None:
                span = {"from": along[i], "len": 0.0, "class": cls,
                        "name": tags.tag(wid, "name") or "", "service": tags.tag(wid, "service") or "",
                        "at": coords[min(i, len(coords) - 1)]}
            span["len"] += dist[i]
        elif span is not None:
            yard_spans.append(span)
            span = None
    if span is not None:
        yard_spans.append(span)
    yard_spans = [s for s in yard_spans if s["len"] >= 30]

    # Петли: тот же узел OSM дважды на коротком отрезке пути.
    first_seen, loops = {}, []
    for i, n in enumerate(nodes):
        if n in first_seen and along[i] - along[first_seen[n]] <= LOOP_METERS \
                and edge <= along[i] <= total - edge:
            j = first_seen[n]
            loops.append({"len": round(along[i] - along[j]), "at": coords[min(j, len(coords) - 1)],
                          "class": tags.highway(seg_way[j] if j < len(seg_way) else None)})
        first_seen.setdefault(n, i)
    # Одну петлю видно многими повторами узлов — оставляем по одной на 300 м пути.
    dedup = []
    for lp in loops:
        if not dedup or meters(dedup[-1]["at"], lp["at"]) > 300:
            dedup.append(lp)
    loops = dedup

    # Манёвры
    uturns, lefts, straight_turns, close, restr, silent = [], [], [], [], [], []
    voiced_at = []
    step_along = 0.0
    steps = [s for leg in route["legs"] for s in leg["steps"]]
    signals_on_route = 0
    counted_signal = set()
    for i, n in enumerate(nodes):
        pass
    for s in steps:
        m = s["maneuver"]
        typ, mod = m["type"], m.get("modifier")
        lat, lon = m["location"][1], m["location"][0]
        here = step_along
        step_along += s["distance"]
        if typ in ("depart",):
            continue
        # индекс узла манёвра — ближайшая точка линии
        k = min(range(len(coords)), key=lambda q: abs(coords[q][0] - lat) + abs(coords[q][1] - lon))
        w_in = seg_way[k - 1] if 0 < k <= len(seg_way) else None
        w_out = seg_way[k] if k < len(seg_way) else None
        c_in, c_out = tags.highway(w_in), tags.highway(w_out)
        # Излом по линии (30 м до, 60 м после): bearing_before/after OSRM меряет
        # в точке манёвра, а у поворота через разделительную он склеен из двух
        # узлов — по ним «налево» выглядит прямой (ложные срабатывания).
        bend = geometric_bend(coords, along, k)
        junction = len((s.get("intersections") or [{}])[0].get("bearings", [])) > 2
        voiced = typ in ("turn", "end of road", "fork", "merge", "on ramp", "off ramp",
                         "roundabout", "rotary") or (typ == "continue" and mod == "uturn")
        if voiced and typ not in ("roundabout", "rotary"):
            voiced_at.append((here, typ, mod, (lat, lon)))
        if mod == "uturn" and typ != "arrive":
            uturns.append({"at": (lat, lon), "along": round(here), "in": c_in, "out": c_out,
                           "name": s.get("name", ""), "mid": edge <= here <= total - edge})
        if typ in ("turn", "end of road") and mod in ("left", "sharp left"):
            signal = tags.signal_near(lat, lon)
            major = c_in in MAJOR or c_out in MAJOR
            two_way_in = tags.tag(w_in, "oneway") not in ("yes", "1", "-1")
            lefts.append({"at": (lat, lon), "along": round(here), "in": c_in, "out": c_out,
                          "signal": signal, "major": major, "two_way_in": two_way_in,
                          "name": s.get("name", "")})
        if typ in ("turn", "end of road") and mod in ("left", "right", "sharp left", "sharp right") \
                and abs(bend) < STRAIGHT_DEGREES:
            straight_turns.append({"at": (lat, lon), "mod": mod, "bend": round(bend), "name": s.get("name", "")})
        # Молчаливый поворот: приложение молчит на new name/continue, а линия
        # на перекрёстке уходит больше чем на SILENT_DEGREES.
        if typ in ("new name", "continue") and mod != "uturn" and junction and abs(bend) >= SILENT_DEGREES:
            silent.append({"at": (lat, lon), "type": typ, "mod": mod, "bend": round(bend), "name": s.get("name", "")})
        # запреты поворотов (via — узел)
        if w_in and w_out and w_in != w_out and k < len(nodes):
            via = nodes[k]
            if (w_in, via, w_out) in tags.no_turn:
                restr.append({"at": (lat, lon), "kind": "no_*", "from": w_in, "to": w_out})
            only = tags.only_turn.get((w_in, via))
            if only is not None and only != w_out:
                restr.append({"at": (lat, lon), "kind": "only_*", "from": w_in, "to": w_out})
    for a, b in zip(voiced_at, voiced_at[1:]):
        if b[0] - a[0] < 40:
            close.append({"at": b[3], "gap": round(b[0] - a[0]), "pair": f"{a[1]}/{a[2]} → {b[1]}/{b[2]}"})
    for i, n in enumerate(nodes):
        if i < len(coords) and n not in counted_signal and tags.signal_near(*coords[i], radius=8):
            counted_signal.add(n)
    # светофор на перекрёстке считаем один раз: соседние узлы ближе 60 м — один
    sig_points = []
    for i, n in enumerate(nodes):
        if n in counted_signal and i < len(coords):
            if not sig_points or meters(sig_points[-1], coords[i]) > 60:
                sig_points.append(coords[i])
    signals_on_route = len(sig_points)

    # Прибытие
    last = steps[-1]["maneuver"]
    final_way = seg_way[-1] if seg_way else None
    arrive = {"side": last.get("modifier", "straight"), "class": tags.highway(final_way),
              "oneway": tags.tag(final_way, "oneway") in ("yes", "1"),
              "name": steps[-1].get("name", "")}
    arrive["across"] = arrive["side"] in ("left", "sharp left", "slight left") and (
        arrive["oneway"] or arrive["class"] in MAJOR)

    urban_time = sum(t for t, v in zip(dur, speed) if v * 3.6 < URBAN_KMH)
    eta = {h: route["duration"] + (f - 1) * urban_time for h, f in HOUR_FACTOR.items()}
    return {
        "rank": rank,
        "distance": round(total), "duration": round(route["duration"]), "weight": round(route["weight"]),
        "classes": {k: round(v) for k, v in sorted(by_class.items(), key=lambda kv: -kv[1])},
        "minor_mid": round(minor_mid), "yard_mid": round(yard_mid), "yard_spans": yard_spans,
        "loops": loops, "uturns": uturns, "lefts": lefts, "straight_turns": straight_turns, "silent": silent,
        "close": close, "restrictions": restr, "arrive": arrive,
        "signals": signals_on_route, "urban_time": round(urban_time),
        "eta_by_hour": {h: round(v) for h, v in eta.items()},
        "coords": coords,
    }


def overlap(a, b):
    """Доля длины `a`, общая с `b`, по парам узлов."""
    pa = {}
    for leg in a["legs"]:
        ann = leg["annotation"]
        for (x, y), d in zip(zip(ann["nodes"], ann["nodes"][1:]), ann["distance"]):
            pa[(x, y)] = d
    pb = set()
    for leg in b["legs"]:
        ann = leg["annotation"]
        pb.update(zip(ann["nodes"], ann["nodes"][1:]))
    total = sum(pa.values()) or 1
    return sum(d for k, d in pa.items() if k in pb) / total


def cmd_analyze(args):
    with open(args.tags) as f:
        tags = Tags(json.load(f))
    pairs = {p["id"]: p for p in load_pairs(args.pairs)}
    report = []
    for path in run_files(args.runs):
        pid = os.path.basename(path)[:-5]
        with open(path) as f:
            resp = json.load(f)
        if resp.get("code") != "Ok":
            report.append({"id": pid, "error": resp.get("code")})
            continue
        routes = resp["routes"][:3]
        variants = [analyze_route(r, tags, i) for i, r in enumerate(routes)]
        fastest = min(range(len(routes)), key=lambda i: routes[i]["duration"])
        for i, v in enumerate(variants):
            v["vs_fastest"] = round(routes[i]["duration"] / routes[fastest]["duration"], 3)
            v["overlap_fastest"] = round(overlap(routes[i], routes[fastest]), 3) if i != fastest else 1.0
        p = pairs.get(pid, {})
        crow = meters(tuple(p["from"]), tuple(p["to"])) if p else 0
        report.append({"id": pid, "name": p.get("name", pid), "crow": round(crow), "variants": variants})
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, ensure_ascii=False)
    if args.marks_out:
        label = os.path.basename(os.path.normpath(args.runs[0]))
        with open(args.marks_out, "w") as f:
            json.dump({f"{label}/{r['id']}": defect_marks(r) for r in report if "variants" in r},
                      f, ensure_ascii=False)
    print_table(report)


def defect_marks(entry):
    """Метки дефектов для картинки: Д — двор/махалля, Р — разворот, Л — левый
    без светофора через главную, П — петля, ! — прибытие через разделительную."""
    marks = []
    for v in entry["variants"]:
        n = v["rank"] + 1
        def add(at, text):
            marks.append({"p": [at[1], at[0]], "kind": "defect", "text": f"{n}{text}"})
        for s in v["yard_spans"]:
            if s["len"] >= 150:
                add(s["at"], f"Д{round(s['len'])}")
        for u in v["uturns"]:
            if u["mid"]:
                add(u["at"], "Р")
        for l in v["lefts"]:
            if l["major"] and not l["signal"]:
                add(l["at"], "Л")
        for lp in v["loops"]:
            add(lp["at"], "П")
        if v["arrive"]["across"]:
            add(v["coords"][-1], "!")
    return marks


def print_table(report):
    print(f"{'пара':14} {'вар':>3} {'км':>6} {'мин':>5} {'×быстр':>6} {'общ%':>5} {'двор м':>6} "
          f"{'мелк м':>6} {'петли':>5} {'разв':>4} {'лев без св':>10} {'запр':>4} {'прям':>4} "
          f"{'близко':>6} {'молч':>4} {'св':>3} {'приб':>8} {'ETA19':>6}")
    for r in report:
        if "error" in r:
            print(r["id"], "ошибка", r["error"])
            continue
        for v in r["variants"]:
            bad_left = sum(1 for l in v["lefts"] if not l["signal"] and l["major"])
            print(f"{r['id'][:14]:14} {v['rank']:>3} {v['distance']/1000:6.1f} {v['duration']/60:5.1f} "
                  f"{v['vs_fastest']:6.2f} {v['overlap_fastest']*100:5.0f} {v['yard_mid']:6} "
                  f"{v['minor_mid']:6} {len(v['loops']):5} {len(v['uturns']):4} "
                  f"{bad_left:>3}/{len(v['lefts']):<6} {len(v['restrictions']):4} {len(v['straight_turns']):4} "
                  f"{len(v['close']):6} {len(v['silent']):4} {v['signals']:3} {v['arrive']['side'][:6]:>6}{'!' if v['arrive']['across'] else ' ':1} "
                  f"{v['eta_by_hour'][19]/60:6.1f}")


# -------------------------------------------------------------------- render

ROAD_STYLE = {
    "motorway": 0, "trunk": 0, "primary": 1, "secondary": 2, "tertiary": 3,
    "motorway_link": 1, "trunk_link": 1, "primary_link": 2, "secondary_link": 3, "tertiary_link": 3,
    "residential": 4, "unclassified": 4, "living_street": 5, "service": 5, "track": 6,
}


def cmd_render(args):
    """Спецификации картинок: фон дорог из roads.geojsonl + линии вариантов."""
    os.makedirs(args.out, exist_ok=True)
    runs = []
    for d in args.runs:
        label = os.path.basename(os.path.normpath(d))
        for path in run_files([d]):
            with open(path) as f:
                resp = json.load(f)
            if resp.get("code") == "Ok":
                runs.append((label, os.path.basename(path)[:-5], resp))
    boxes = {}
    for label, pid, resp in runs:
        lats = [c[1] for r in resp["routes"] for c in r["geometry"]["coordinates"]]
        lons = [c[0] for r in resp["routes"] for c in r["geometry"]["coordinates"]]
        b = boxes.get(pid, [90, 180, -90, -180])
        boxes[pid] = [min(b[0], min(lats)), min(b[1], min(lons)), max(b[2], max(lats)), max(b[3], max(lons))]
    for pid, b in boxes.items():
        pad_lat, pad_lon = (b[2] - b[0]) * 0.08 + 0.002, (b[3] - b[1]) * 0.08 + 0.002
        boxes[pid] = [b[0] - pad_lat, b[1] - pad_lon, b[2] + pad_lat, b[3] + pad_lon]
    background = defaultdict(list)
    big = {pid for pid, b in boxes.items() if (b[2] - b[0]) > 0.35}
    with open(args.roads) as f:
        for line in f:
            line = line.strip().lstrip("\x1e")
            if not line:
                continue
            try:
                feat = json.loads(line)
            except ValueError:
                continue
            hw = feat.get("properties", {}).get("highway")
            style = ROAD_STYLE.get(hw)
            if style is None or feat["geometry"]["type"] != "LineString":
                continue
            pts = feat["geometry"]["coordinates"]
            lo_lon = min(p[0] for p in pts); hi_lon = max(p[0] for p in pts)
            lo_lat = min(p[1] for p in pts); hi_lat = max(p[1] for p in pts)
            for pid, b in boxes.items():
                if pid in big and style > 2:
                    continue
                if hi_lat < b[0] or lo_lat > b[2] or hi_lon < b[1] or lo_lon > b[3]:
                    continue
                background[pid].append([style, [[round(p[0], 6), round(p[1], 6)] for p in pts]])
    pairs = {p["id"]: p for p in load_pairs(args.pairs)}
    for label, pid, resp in runs:
        spec = {
            "title": f"{pairs.get(pid, {}).get('name', pid)} — {label}",
            "bbox": boxes[pid], "width": 1200, "height": 900,
            "roads": background[pid],
            "routes": [{"rank": i, "p": [[round(c[0], 6), round(c[1], 6)] for c in r["geometry"]["coordinates"]],
                        "label": f"{i + 1}: {r['duration'] / 60:.0f} мин, {r['distance'] / 1000:.1f} км"}
                       for i, r in enumerate(resp["routes"][:3])],
            "markers": [],
        }
        p = pairs.get(pid)
        if p:
            spec["markers"] = [{"p": [p["from"][1], p["from"][0]], "kind": "from"},
                               {"p": [p["to"][1], p["to"][0]], "kind": "to"}]
        if args.marks and os.path.exists(args.marks):
            with open(args.marks) as f:
                marks = json.load(f).get(f"{label}/{pid}", [])
            spec["markers"] += marks
        with open(os.path.join(args.out, f"{pid}__{label}.spec.json"), "w") as f:
            json.dump(spec, f, ensure_ascii=False)
    print("спецификаций:", len(runs))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--base", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--pairs", default=PAIRS)
    f.add_argument("--delay", type=float, default=1.1)
    f.add_argument("--force", action="store_true")
    # Приложение до 29.E слало alternatives=true (≤ 1 альтернативы), после — 3.
    f.add_argument("--alternatives", default="true")
    f.add_argument("--extra", default="", help="добавка к запросу, например &approaches=unrestricted;curb")
    i = sub.add_parser("index")
    i.add_argument("--pbf", required=True)
    i.add_argument("--runs", nargs="+", required=True)
    i.add_argument("--out", required=True)
    a = sub.add_parser("analyze")
    a.add_argument("--runs", nargs="+", required=True)
    a.add_argument("--tags", required=True)
    a.add_argument("--pairs", default=PAIRS)
    a.add_argument("--out")
    a.add_argument("--marks-out")
    r = sub.add_parser("render")
    r.add_argument("--runs", nargs="+", required=True)
    r.add_argument("--roads", required=True)
    r.add_argument("--pairs", default=PAIRS)
    r.add_argument("--marks")
    r.add_argument("--out", required=True)
    args = ap.parse_args()
    {"fetch": cmd_fetch, "index": cmd_index, "analyze": cmd_analyze, "render": cmd_render}[args.cmd](args)


if __name__ == "__main__":
    main()
