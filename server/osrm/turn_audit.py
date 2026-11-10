#!/usr/bin/env python3
"""Аудит запретов поворотов и одностороннего движения в Ташкенте (88, 10.11.2026).

Насколько OSM годится для маршрутов: сколько запретов и односторонних,
крупные перекрёстки без единого запрета, разрывы разделительной, битые
relation, тупиковые и встречные oneway, острова графа, — и что видно по
задержкам манёвров водителей (traffic_turn_obs, 33B).

    # 1. выборка из выгрузки страны (pyosmium, ~2 мин, пик ~1 ГБ) — тяжёлый шаг
    nice -n 15 python3 turn_audit.py scan --pbf uzbekistan-latest.osm.pbf --out scan.json
    # 2. разбор: числа в stdout, JSON для документа, GeoJSON для geojson.io
    python3 turn_audit.py report --scan scan.json --out audit.json --geojson turn_audit.geojson \
        [--turns turn_agg.json --routes runs/prod]
    # 3. картинки худших мест для render_routes.swift (фон — дороги из scan.json)
    python3 turn_audit.py shots --audit audit.json --scan scan.json --out shots/ --top 5 \
        [--extra "41.3073,69.2182,подпись"]
    swift render_routes.swift shots/*.spec.json

Только чтение: граф, сервер и маршрутизатор не меняются. Доступ и oneway —
как в car_radarmap.lua (иерархия motorcar → motor_vehicle → vehicle → access,
private/destination проезжаемы с ограничением, барьер вне белого списка
перекрывает узел).
"""
import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

# lon0, lat0, lon1, lat1 — CITY_BBOX из server/build_osrm_mld.sh
CITY_BBOX = (69.05, 41.15, 69.55, 41.48)
# Запас вокруг города: связность графа считается шире, чем отчёт.
PAD = 0.03

CAR = {"motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
       "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
       "residential", "living_street", "service", "road"}
MAJOR = {"motorway": 4, "trunk": 3, "primary": 2, "secondary": 1}
YARD = {"service", "living_street"}
# Как в car_radarmap.lua: запрет без «ограниченного» доступа.
BLOCKED = {"no", "agricultural", "forestry", "emergency", "psv", "taxi", "share_taxi", "minibus",
           "bus", "foot", "emergency_vehicle", "restricted", "military", "official"}
RESTRICTED = {"private", "delivery", "destination", "customers", "permit", "residents"}
BARRIER_OK = {"cattle_grid", "border_control", "toll_booth", "sally_port", "no", "entrance",
              "height_restrictor", "arch", "gate", "lift_gate"}
KINDS = {"no_right_turn", "no_left_turn", "no_u_turn", "no_straight_on", "no_entry", "no_exit",
         "only_right_turn", "only_left_turn", "only_straight_on", "only_u_turn"}
WAY_KEYS = ("highway", "oneway", "junction", "name", "name:ru", "ref", "access", "motor_vehicle",
            "motorcar", "vehicle", "service", "area", "dual_carriageway", "lanes", "oneway:motorcar",
            "oneway:conditional", "access:conditional", "motor_vehicle:conditional", "traffic_sign")
# Граница: рамка города задевает Казахстан (Сарыагаш, Келес) — его дороги в
# выгрузке Geofabrik обрезаны и дают ложные «острова» и «перекрёстки».
BORDERS = ("Uzbekistan", "Tashkent")
NODE_KEYS = ("highway", "barrier", "traffic_sign", "crossing", "access", "motor_vehicle", "motorcar",
             "vehicle", "traffic_signals", "direction", "kerb", "bollard", "sensory", "maxheight")


def in_box(lat, lon, pad=0.0):
    return CITY_BBOX[1] - pad <= lat <= CITY_BBOX[3] + pad and CITY_BBOX[0] - pad <= lon <= CITY_BBOX[2] + pad


def meters(a, b):
    dy = (b[0] - a[0]) * 111320.0
    dx = (b[1] - a[1]) * 111320.0 * math.cos(math.radians((a[0] + b[0]) / 2))
    return math.hypot(dx, dy)


def bearing(a, b):
    dy = b[0] - a[0]
    dx = (b[1] - a[1]) * math.cos(math.radians(a[0]))
    return math.degrees(math.atan2(dx, dy)) % 360


def turn(b_in, b_out):
    """Угол поворота −180…180, плюс — направо (как turn_angle в traffic_build)."""
    return (b_out - b_in + 540) % 360 - 180


# ---------------------------------------------------------------------- scan

def cmd_scan(args):
    import osmium

    rels = []
    rel_ways, rel_nodes = set(), set()
    borders, border_ways = {}, set()

    class Relations(osmium.SimpleHandler):
        def relation(self, r):
            if r.tags.get("boundary") == "administrative" and r.tags.get("admin_level") in ("2", "4") \
                    and r.tags.get("name:en") in BORDERS:
                outer = [m.ref for m in r.members if m.type == "w" and m.role in ("outer", "")]
                borders[r.tags["name:en"]] = outer
                border_ways.update(outer)
                return
            if r.tags.get("type") not in ("restriction", "restriction:motorcar", "restriction:hgv"):
                return
            members = [(m.type, m.ref, m.role) for m in r.members]
            for t, ref, _ in members:
                (rel_ways if t == "w" else rel_nodes if t == "n" else set()).add(ref)
            rels.append({"id": r.id, "tags": dict(r.tags), "members": members})

    Relations().apply_file(args.pbf)
    print("relation restriction в стране:", len(rels), file=sys.stderr)

    ways, nodes, member_ways, member_nodes, border_coords = {}, {}, {}, {}, {}

    class Body(osmium.SimpleHandler):
        def node(self, n):
            if not n.location.valid():
                return
            lat, lon = n.location.lat, n.location.lon
            if n.id in rel_nodes:
                member_nodes[n.id] = [round(lat, 7), round(lon, 7)]
            if len(n.tags) and in_box(lat, lon, PAD):
                tags = {k: n.tags[k] for k in NODE_KEYS if k in n.tags}
                if tags:
                    nodes[n.id] = [round(lat, 7), round(lon, 7), tags]

        def way(self, w):
            hw = w.tags.get("highway")
            refs = [nd.ref for nd in w.nodes]
            coords = []
            for nd in w.nodes:
                if nd.location.valid():
                    coords.append([round(nd.location.lat, 7), round(nd.location.lon, 7)])
                else:
                    coords.append(None)
            if w.id in border_ways:
                border_coords[w.id] = {"nodes": [refs[0], refs[-1]], "coords": [c for c in coords if c]}
            if w.id in rel_ways:
                member_ways[w.id] = {"highway": hw or "", "oneway": w.tags.get("oneway", ""),
                                     "junction": w.tags.get("junction", ""), "nodes": refs,
                                     "coords": coords, "name": w.tags.get("name", "")}
            if hw not in CAR:
                return
            if not any(c and in_box(c[0], c[1], PAD) for c in coords):
                return
            ways[w.id] = {"tags": {k: w.tags[k] for k in WAY_KEYS if k in w.tags},
                          "nodes": refs, "coords": coords}

    Body().apply_file(args.pbf, locations=True, idx="flex_mem")
    with open(args.out, "w") as f:
        json.dump({"bbox": CITY_BBOX, "pad": PAD, "relations": rels, "ways": ways, "nodes": nodes,
                   "member_ways": member_ways, "member_nodes": member_nodes,
                   "borders": {k: [border_coords[w] for w in v if w in border_coords]
                               for k, v in borders.items()}}, f)
    print(f"путей {len(ways)}, узлов с тегами {len(nodes)}, путей-членов {len(member_ways)}/{len(rel_ways)}, "
          f"узлов-членов {len(member_nodes)}/{len(rel_nodes)}", file=sys.stderr)


# -------------------------------------------------------------------- report

INSIDE = []  # функции «точка внутри»; пусто — только рамка


def in_core(lat, lon):
    return in_box(lat, lon) and all(f(lat, lon) for f in INSIDE)


def rings(parts):
    """Склеить внешние пути границы в кольца по общим концам."""
    pending = [list(p["coords"]) for p in parts if len(p["coords"]) >= 2]
    out = []
    while pending:
        ring = pending.pop()
        changed = True
        while changed and ring[0] != ring[-1]:
            changed = False
            for i, p in enumerate(pending):
                if p[0] == ring[-1]:
                    ring += p[1:]
                elif p[-1] == ring[-1]:
                    ring += p[::-1][1:]
                elif p[-1] == ring[0]:
                    ring = p[:-1] + ring
                elif p[0] == ring[0]:
                    ring = p[::-1][:-1] + ring
                else:
                    continue
                pending.pop(i)
                changed = True
                break
        if ring[0] == ring[-1] and len(ring) >= 4:
            out.append(ring)
    return out


def polygon_test(parts, lat_lo, lat_hi, step=0.002):
    """Чёт-нечет по рёбрам колец, разложенным по полосам широты."""
    bands = defaultdict(list)
    n = 0
    for ring in rings(parts):
        for a, b in zip(ring, ring[1:]):
            lo, hi = min(a[0], b[0]), max(a[0], b[0])
            if hi < lat_lo or lo > lat_hi or lo == hi:
                continue
            n += 1
            for k in range(int(lo / step), int(hi / step) + 1):
                bands[k].append((a, b))
    if not n:
        return None

    def inside(lat, lon):
        c = False
        for a, b in bands.get(int(lat / step), ()):
            if (a[0] > lat) != (b[0] > lat):
                x = a[1] + (lat - a[0]) * (b[1] - a[1]) / (b[0] - a[0])
                if x > lon:
                    c = not c
        return c
    return inside


def access_of(tags):
    for key in ("motorcar", "motor_vehicle", "vehicle", "access"):
        if key in tags:
            return tags[key]
    return None


def direction(tags):
    """+1 — только вперёд, −1 — только назад, 0 — в обе стороны, None — не проехать."""
    hw = tags.get("highway")
    ow = tags.get("oneway:motorcar") or tags.get("oneway")
    if ow == "reversible":
        return None
    if ow in ("yes", "1", "true"):
        return 1
    if ow == "-1":
        return -1
    if ow == "no":
        return 0
    if tags.get("junction") in ("roundabout", "circular") or hw == "motorway":
        return 1
    return 0


def drivable(tags):
    if tags.get("highway") not in CAR or tags.get("area") == "yes":
        return False
    if tags.get("service") == "emergency_access":
        return False
    acc = access_of(tags)
    if acc in BLOCKED:
        return False
    if tags.get("highway") == "service" and acc == "private":
        return False
    return direction(tags) is not None


def node_blocks(tags):
    """Узел-препятствие, как process_node в car_radarmap.lua: есть тег доступа —
    решает только он; иначе барьер вне белого списка и без исключений
    (поднимающийся столбик, опущенный бордюр, бордюр на переходе)."""
    acc = access_of(tags)
    if acc is not None:
        return acc in BLOCKED
    b = tags.get("barrier")
    if not b:
        return False
    if b in BARRIER_OK or tags.get("bollard") == "rising" or tags.get("kerb") in ("lowered", "flush"):
        return False
    if b == "kerb" and tags.get("highway") == "crossing":
        return False
    if b == "fence" and tags.get("sensory") in ("audible", "audio"):
        return False
    return True


def street_name(tags):
    return tags.get("name:ru") or tags.get("name") or tags.get("ref") or ""


class Graph:
    def __init__(self, scan):
        self.ways = {int(k): v for k, v in scan["ways"].items()}
        self.tagged = {int(k): v for k, v in scan["nodes"].items()}
        self.loc = {}
        self.out = defaultdict(set)   # узел → соседи по направлению движения
        self.inc = defaultdict(set)
        self.arms = defaultdict(list)  # узел → [(way, сосед, bearing)] без учёта направления
        self.seg_len = {}
        self.blocked = set()
        for nid, (lat, lon, tags) in self.tagged.items():
            if node_blocks(tags):
                self.blocked.add(nid)
        for wid, w in self.ways.items():
            refs, coords = w["nodes"], w["coords"]
            for r, c in zip(refs, coords):
                if c:
                    self.loc[r] = tuple(c)
            if not drivable(w["tags"]):
                continue
            d = direction(w["tags"])
            for a, b in zip(refs, refs[1:]):
                if a not in self.loc or b not in self.loc or a == b:
                    continue
                la, lb = self.loc[a], self.loc[b]
                self.seg_len[(a, b)] = self.seg_len[(b, a)] = meters(la, lb)
                self.arms[a].append((wid, b, bearing(la, lb)))
                self.arms[b].append((wid, a, bearing(lb, la)))
                if a in self.blocked or b in self.blocked:
                    continue
                if d in (0, 1):
                    self.out[a].add(b); self.inc[b].add(a)
                if d in (0, -1):
                    self.out[b].add(a); self.inc[a].add(b)

    def hw(self, wid):
        return self.ways.get(wid, {}).get("tags", {}).get("highway", "")

    def tags(self, wid):
        return self.ways.get(wid, {}).get("tags", {})

    def way_len(self, wid):
        w = self.ways[wid]
        cs = [c for c in w["coords"] if c]
        return sum(meters(a, b) for a, b in zip(cs, cs[1:]))

    def core_way(self, wid):
        return any(c and in_core(c[0], c[1]) for c in self.ways[wid]["coords"])


def scc_main(graph):
    """Самая большая сильно связная компонента ориентированного графа (Косарайю, без рекурсии)."""
    nodes = set(graph.out) | set(graph.inc)
    order, seen = [], set()
    for s in nodes:
        if s in seen:
            continue
        seen.add(s)
        stack = [(s, iter(graph.out.get(s, ())))]
        while stack:
            v, it = stack[-1]
            for w in it:
                if w not in seen:
                    seen.add(w)
                    stack.append((w, iter(graph.out.get(w, ()))))
                    break
            else:
                stack.pop()
                order.append(v)
    comp, best, best_size = {}, None, 0
    for s in reversed(order):
        if s in comp:
            continue
        members = [s]
        comp[s] = s
        i = 0
        while i < len(members):
            v = members[i]; i += 1
            for w in graph.inc.get(v, ()):
                if w not in comp:
                    comp[w] = s
                    members.append(w)
        if len(members) > best_size:
            best, best_size = s, len(members)
    return {v for v, c in comp.items() if c == best}


def restriction_kind(tags):
    for key in ("restriction", "restriction:motorcar", "restriction:motor_vehicle", "restriction:vehicle"):
        if key in tags:
            return tags[key], key
    if "restriction:conditional" in tags:
        return tags["restriction:conditional"].split("@")[0].strip(), "restriction:conditional"
    return "", ""


def audit_restrictions(scan, g):
    """Каждый relation: место, тип, дефекты (почему OSRM его выбросит или он бесполезен)."""
    mways = {int(k): v for k, v in scan["member_ways"].items()}
    mnodes = {int(k): tuple(v) for k, v in scan["member_nodes"].items()}
    out = []
    for r in scan["relations"]:
        kind, key = restriction_kind(r["tags"])
        roles = defaultdict(list)
        for t, ref, role in r["members"]:
            roles[role].append((t, ref))
        issues = []
        other = [k for k in r["tags"] if k.startswith("restriction:") and k != "restriction:conditional"]
        if any(v in ("motorcar", "motor_vehicle", "vehicle")
               for v in r["tags"].get("except", "").replace(" ", "").split(";")):
            issues.append("не для легковых: except=" + r["tags"]["except"])
        if not kind and other:
            issues.append("не для легковых: " + ",".join(other))
            kind = r["tags"][other[0]]
        elif not kind:
            issues.append("нет тега restriction")
        elif kind not in KINDS:
            issues.append(f"неизвестный тип {kind}")
        for role in ("from", "via", "to"):
            if not roles.get(role):
                issues.append(f"нет роли {role}")
        extra = set(roles) - {"from", "via", "to", "location_hint"}
        if extra:
            issues.append("лишние роли " + ",".join(sorted(extra)))
        if len(roles.get("from", [])) > 1 and kind != "no_entry":
            issues.append("несколько from")
        if len(roles.get("to", [])) > 1 and kind != "no_exit":
            issues.append("несколько to")
        missing = [f"{t}{ref}" for t, ref, _ in r["members"]
                   if (t == "w" and ref not in mways) or (t == "n" and ref not in mnodes)]
        if missing:
            issues.append("удалённые члены " + ",".join(missing))
        for role in ("from", "to"):
            for t, ref in roles.get(role, []):
                if t != "w":
                    issues.append(f"{role} — не путь")
                elif ref in mways and mways[ref]["highway"] not in CAR:
                    issues.append(f"{role} w{ref} — не автодорога ({mways[ref]['highway'] or 'без highway'})")
        via = roles.get("via", [])
        at = None
        angle = None
        if via and via[0][0] == "n" and via[0][1] in mnodes:
            vn = via[0][1]
            at = mnodes[vn]
            ends = {}
            for role in ("from", "to"):
                for t, ref in roles.get(role, []):
                    w = mways.get(ref)
                    if t != "w" or not w:
                        continue
                    if vn not in w["nodes"]:
                        issues.append(f"via не на {role}")
                        continue
                    if w["nodes"][0] != vn and w["nodes"][-1] != vn:
                        issues.append(f"via в середине {role} (путь не разрезан)")
                    ends[role] = w
            # Бесполезный или ловушка относительно oneway.
            f, t = ends.get("from"), ends.get("to")
            if f:
                d = direction({"highway": f["highway"], "oneway": f["oneway"], "junction": f["junction"]})
                i = f["nodes"].index(vn)
                arrives = (d in (0, 1) and i > 0) or (d in (0, -1) and i < len(f["nodes"]) - 1)
                if not arrives:
                    issues.append("from — oneway от via: запрет ни на что не влияет")
            if t:
                d = direction({"highway": t["highway"], "oneway": t["oneway"], "junction": t["junction"]})
                i = t["nodes"].index(vn)
                leaves = (d in (0, 1) and i < len(t["nodes"]) - 1) or (d in (0, -1) and i > 0)
                if not leaves:
                    issues.append("to — oneway к via: "
                                  + ("единственный разрешённый манёвр невозможен" if kind.startswith("only_")
                                     else "запрет лишний"))
            # Угол против типа: no_left_turn, а по геометрии направо.
            if f and t and f is not t and kind in KINDS and "u_turn" not in kind and kind not in ("no_entry", "no_exit"):
                angle = restriction_angle(f, t, vn)
                if angle is not None:
                    want = kind.split("_", 1)[1].replace("_turn", "").replace("_on", "")
                    # Только явное противоречие: съезды-«карманы» дают 20–30° у
                    # настоящего правого, это не ошибка разметки.
                    wrong = (want == "left" and angle > 35) or (want == "right" and angle < -35) \
                        or (want == "straight" and abs(angle) > 60)
                    if wrong and abs(angle) < 160:
                        side = "налево" if angle < 0 else "направо"
                        issues.append(f"тип {kind}, а по геометрии {side} ({angle:.0f}°)")
        elif via and via[0][0] == "w":
            vids = [ref for t, ref in via if t == "w"]
            if all(v in mways for v in vids):
                vw = mways[vids[0]]
                cs = [c for c in vw["coords"] if c]
                at = tuple(cs[len(cs) // 2]) if cs else None
                chain_ends = set()
                for v in vids:
                    chain_ends |= {mways[v]["nodes"][0], mways[v]["nodes"][-1]}
                for role in ("from", "to"):
                    for t, ref in roles.get(role, []):
                        w = mways.get(ref)
                        if w and not ({w["nodes"][0], w["nodes"][-1]} & chain_ends) and \
                                not (set(w["nodes"]) & chain_ends):
                            issues.append(f"{role} не касается via-пути")
        if at is None:
            for t, ref, _ in r["members"]:
                if t == "w" and ref in mways:
                    cs = [c for c in mways[ref]["coords"] if c]
                    if cs:
                        at = tuple(cs[0]); break
                if t == "n" and ref in mnodes:
                    at = mnodes[ref]; break
        out.append({"id": r["id"], "kind": kind or "?", "key": key, "via": via[0][0] if via else "",
                    "at": at, "issues": issues, "angle": None if angle is None else round(angle),
                    "via_node": via[0][1] if via and via[0][0] == "n" else None,
                    "via_ways": [ref for t, ref in via if t == "w"],
                    "from": [ref for t, ref in roles.get("from", [])],
                    "to": [ref for t, ref in roles.get("to", [])]})
    return out


def severity(issue):
    """X — запрет не для легковых (except=motorcar, restriction:hgv),
    E — OSRM запрет выбросит (битый), D — применит и сделает ловушку,
    B — запрет для автобусной полосы (машинам не нужен), W — лишний или
    противоречит геометрии."""
    if issue.startswith("не для легковых"):
        return "X"
    if "невозможен" in issue:
        return "D"
    if "busway" in issue:
        return "B"
    if "ни на что не влияет" in issue or "запрет лишний" in issue or issue.startswith("тип "):
        return "W"
    return "E"


def usable(r):
    """Запрет, который OSRM применит: без дефектов или только с замечаниями."""
    return not ({"E", "B", "D", "X"} & set(r.get("severity", ())))


def issue_key(issue):
    import re
    return re.sub(r"\s+", " ", re.sub(r"w\d+|n\d+|\(.*?\)|-?\d+°|,", " ", issue)).strip()


def restriction_angle(f, t, vn):
    def neighbour(w):
        i = w["nodes"].index(vn)
        j = i - 1 if i > 0 else i + 1
        if j >= len(w["coords"]) or not w["coords"][i] or not w["coords"][j]:
            return None, None
        return tuple(w["coords"][j]), tuple(w["coords"][i])
    pf, v = neighbour(f)
    pt, _ = neighbour(t)
    if not pf or not pt:
        return None
    return turn(bearing(pf, v), bearing(v, pt))


def cluster(points, radius):
    """Одиночная связь по расстоянию: [(id, (lat, lon))] → списки id."""
    cell = radius / 111320.0
    grid = defaultdict(list)
    for pid, p in points:
        grid[(int(p[0] / cell), int(p[1] / cell))].append((pid, p))
    parent = {pid: pid for pid, _ in points}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for pid, p in points:
        cy, cx = int(p[0] / cell), int(p[1] / cell)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for qid, q in grid.get((cy + dy, cx + dx), ()):
                    if qid != pid and meters(p, q) <= radius:
                        parent[find(pid)] = find(qid)
    groups = defaultdict(list)
    for pid, _ in points:
        groups[find(pid)].append(pid)
    return list(groups.values())


GENERIC = {"улица", "проспект", "дорога", "автодорога", "автомобильная", "шоссе", "кольцевая",
           "ko‘chasi", "ko'chasi", "koʻchasi", "kochasi", "shoh", "ko‘chasi", "yo‘li", "yoʻli", "yo'li",
           "avtomobil", "shosse", "prospekti", "shoh", "ул", "пр", "тупик", "street", "road", "avenue",
           "highway", "ring", "massivi", "berk", "автомагистраль", "трасса", "йули", "кучаси"}


def street_keys(t):
    """Нормализованные имена улицы: «Ташкентская кольцевая автодорога» и
    «Ташкентская Кольцевая Автомобильная Дорога» — одна улица."""
    import re
    keys = set()
    for k in ("name", "name:ru", "name:uz", "name:en", "old_name", "ref"):
        v = t.get(k)
        if not v:
            continue
        for part in v.split(";"):
            words = [w for w in re.split(r"[\s\-—–.,«»\"()]+", part.lower()) if w and w not in GENERIC]
            if words:
                keys.add(" ".join(words))
    return keys


def distinct_streets(tag_list):
    """[(подпись, класс)] разных главных улиц; безымянные не считаются отдельной
    улицей (это обычно куски той же дороги или съезды)."""
    groups = []
    for t in tag_list:
        rank = major_rank(t.get("highway", ""))
        keys = street_keys(t)
        if not rank or not keys:
            continue
        for grp in groups:
            if grp[0] & keys:
                grp[0] |= keys
                grp[2] = max(grp[2], rank)
                break
        else:
            groups.append([set(keys), street_name(t), rank])
    return [(label, rank) for _, label, rank in groups]


def major_rank(hw):
    if hw in MAJOR:
        return MAJOR[hw]
    return 0


def junctions(g, restrictions, signals):
    """Перекрёстки двух главных улиц (trunk/primary/secondary), сгруппированные
    по 60 м (у проспекта с разделительной узлы двух проезжих частей разнесены)."""
    cand = []
    for nid, arms in g.arms.items():
        if nid not in g.loc or not in_core(*g.loc[nid]):
            continue
        if len(arms) < 3:
            continue
        if len(distinct_streets([g.tags(w) for w, _, _ in arms])) >= 2:
            cand.append((nid, g.loc[nid]))
    # Развязка в разных уровнях — одни слияния и разветвления, выбора на
    # пересечении потоков нет; нужен хотя бы один узел «2 въезда × 2 выезда».
    groups = [ns for ns in cluster(cand, 60.0)
              if any(len(g.inc.get(n, ())) >= 2 and len(g.out.get(n, ())) >= 2 for n in ns)]
    # Места запретов: via-узел или середина via-пути.
    restr_points = [(r["id"], tuple(r["at"])) for r in restrictions if r["at"]]
    rgrid = defaultdict(list)
    for rid, p in restr_points:
        rgrid[(int(p[0] / 0.002), int(p[1] / 0.002))].append((rid, p))
    sgrid = defaultdict(list)
    for p in signals:
        sgrid[(int(p[0] / 0.002), int(p[1] / 0.002))].append(p)

    def near(grid, p, radius):
        cy, cx = int(p[0] / 0.002), int(p[1] / 0.002)
        res = []
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for item in grid.get((cy + dy, cx + dx), ()):
                    q = item[1] if isinstance(item[1], tuple) else item
                    if meters(p, q) <= radius:
                        res.append(item)
        return res
    r_by_id = {r["id"]: r for r in restrictions}
    out = []
    for nodes in groups:
        ns = set(nodes)
        lat = sum(g.loc[n][0] for n in nodes) / len(nodes)
        lon = sum(g.loc[n][1] for n in nodes) / len(nodes)
        arms, oneway_major, arm_tags = 0, 0, []
        for n in nodes:
            for wid, other, _ in g.arms[n]:
                if other in ns:
                    continue
                t = g.tags(wid)
                hw = t.get("highway", "")
                if hw == "service":
                    continue
                arms += 1
                arm_tags.append(t)
                if major_rank(hw) and direction(t) != 0:
                    oneway_major += 1
        streets = {label: rank for label, rank in distinct_streets(arm_tags)}
        radius = 40.0 + 15.0 * min(len(nodes), 4)
        rs = [rid for rid, _ in near(rgrid, (lat, lon), radius)]
        valid = [rid for rid in rs if usable(r_by_id[rid])]
        sig = bool(near(sgrid, (lat, lon), radius)) or any(
            g.tagged.get(n, [0, 0, {}])[2].get("highway") == "traffic_signals" for n in nodes)
        top = sorted(streets.values(), reverse=True)[:2]
        out.append({"at": [round(lat, 6), round(lon, 6)], "nodes": sorted(ns), "arms": arms,
                    "streets": sorted(streets, key=lambda k: -streets[k]), "ranks": top,
                    "score": sum(top) * 10 + min(arms, 12), "signal": sig,
                    "restrictions": len(rs), "valid_restrictions": len(valid),
                    "divided": oneway_major >= 2, "radius": radius})
    out.sort(key=lambda j: (-j["score"], -j["arms"]))
    return out


def median_openings(g, restrictions, signals):
    """Разрывы разделительной: короткий путь между двумя встречными oneway
    одной главной улицы. Посреди квартала (кроме двух проезжих частей и самого
    разрыва в узлах ничего нет) — разворот; иначе — часть перекрёстка."""
    no_u = defaultdict(int)
    for r in restrictions:
        if r["kind"] in ("no_u_turn", "no_left_turn") and usable(r):
            for w in r["from"] + r["to"]:
                no_u[w] += 1
    sig_nodes = {nid for nid, (_, _, t) in g.tagged.items() if t.get("highway") == "traffic_signals"}
    res = []
    for wid, w in g.ways.items():
        t = w["tags"]
        if not drivable(t) or not g.core_way(wid):
            continue
        if g.way_len(wid) > 60:
            continue
        a, b = w["nodes"][0], w["nodes"][-1]
        side, travel = {}, {}
        for end in (a, b):
            for owid, other, br in g.arms.get(end, ()):
                if owid == wid:
                    continue
                ot = g.tags(owid)
                d = direction(ot)
                if not major_rank(ot.get("highway", "")) or d == 0:
                    continue
                side.setdefault(end, set()).add((street_name(ot), owid))
                refs = g.ways[owid]["nodes"]
                i = refs.index(end)
                leaving = (i + 1 < len(refs) and refs[i + 1] == other) == (d == 1)
                travel.setdefault(end, []).append(br if leaving else (br + 180) % 360)
        if a not in side or b not in side:
            continue
        names_a = {n for n, _ in side[a] if n}
        names_b = {n for n, _ in side[b] if n}
        common = names_a & names_b
        if not common:
            continue
        ways_a = {o for _, o in side[a]}
        ways_b = {o for _, o in side[b]}
        if ways_a & ways_b:
            continue  # один и тот же путь с обеих сторон — не разрыв, а петля
        # Проезжие части у концов — встречные (а не два куска одной стороны).
        if not any(abs(turn(x, y)) > 135 for x in travel[a] for y in travel[b]):
            continue
        # посреди квартала: у концов нет других дорог, кроме проезжих частей
        others = 0
        for end in (a, b):
            for owid, other, _ in g.arms.get(end, ()):
                if owid != wid and owid not in ways_a | ways_b:
                    others += 1
        street = sorted(common)[0]
        rank = max(major_rank(g.hw(o)) for o in ways_a | ways_b)
        res.append({"way": wid, "at": [round(x, 6) for x in g.loc[a]], "street": street, "rank": rank,
                    "len": round(g.way_len(wid)), "midblock": others == 0,
                    "oneway": direction(t) != 0,
                    "signal": a in sig_nodes or b in sig_nodes,
                    "restricted": no_u.get(wid, 0) + sum(no_u.get(o, 0) for o in ways_a | ways_b) > 0,
                    "restricted_self": no_u.get(wid, 0) > 0})
    return res


def oneway_traps(g, main):
    """Тупиковые и встречные oneway: узел, куда въехать можно, а выехать нельзя
    (или наоборот), и острова вне главной сильно связной компоненты."""
    sinks, sources = [], []
    for n in set(g.inc) | set(g.out):
        if n not in g.loc or not in_core(*g.loc[n]):
            continue
        if n in g.blocked:
            continue
        ins, outs = g.inc.get(n, set()), g.out.get(n, set())
        arms = g.arms.get(n, [])
        oneway_arms = [w for w, _, _ in arms if direction(g.tags(w)) != 0]
        if not oneway_arms:
            continue
        if ins and not outs:
            heads = len({w for w in oneway_arms})
            sinks.append({"node": n, "at": list(g.loc[n]), "ways": sorted({w for w, _, _ in arms}),
                          "kind": "встречные oneway" if heads >= 2 else "тупиковый oneway",
                          "class": max((g.hw(w) for w, _, _ in arms), key=lambda h: major_rank(h) * 10 + (h != "service")),
                          "names": sorted({street_name(g.tags(w)) for w, _, _ in arms} - {""})})
        elif outs and not ins:
            sources.append({"node": n, "at": list(g.loc[n]), "ways": sorted({w for w, _, _ in arms}),
                            "kind": "oneway ниоткуда" if len({w for w in oneway_arms}) < 2 else "расходящиеся oneway",
                            "class": max((g.hw(w) for w, _, _ in arms), key=lambda h: major_rank(h) * 10 + (h != "service")),
                            "names": sorted({street_name(g.tags(w)) for w, _, _ in arms} - {""})})
    # Острова: проезжие участки в городе вне главной компоненты.
    lost_len = defaultdict(float)
    total_len = defaultdict(float)
    lost_ways = defaultdict(float)
    for (a, b), d in g.seg_len.items():
        if a > b:
            continue
        if not (in_core(*g.loc[a]) and in_core(*g.loc[b])):
            continue
        if b not in g.out.get(a, ()) and a not in g.out.get(b, ()):
            continue  # отрезок за барьером — не в графе
        total_len["all"] += d
        if a not in main or b not in main:
            lost_len["all"] += d
    for wid, w in g.ways.items():
        if not drivable(w["tags"]) or not g.core_way(wid):
            continue
        refs = [r for r in w["nodes"] if r in g.loc]
        if refs and all(r not in main for r in refs):
            lost_ways[w["tags"].get("highway")] += g.way_len(wid)
    return sinks, sources, total_len["all"], lost_len["all"], lost_ways


def route_turn_check(g, turns, runs_dir):
    """Манёвры маршрутов против наблюдений водителей: тройка (u, v, w), где на
    въезде (u, v) наблюдений много, а такого выезда нет ни одного."""
    by_in = defaultdict(lambda: defaultdict(int))
    for u, v, w, n, days, delay, angle in turns:
        by_in[(u, v)][w] += n
    seen_nodes = {v for (_, v) in by_in}
    stats = Counter()
    flagged = []
    for name in sorted(os.listdir(runs_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(runs_dir, name)) as f:
            resp = json.load(f)
        for rank, route in enumerate(resp.get("routes", [])[:3]):
            nodes = [n for leg in route["legs"] for n in leg["annotation"]["nodes"]]
            for a, b, c in zip(nodes, nodes[1:], nodes[2:]):
                if len({o for _, o, _ in g.arms.get(b, ())}) < 3:
                    continue
                stats["junction"] += 1
                if b in seen_nodes:
                    stats["node_seen"] += 1
                obs = by_in.get((a, b))
                if not obs:
                    continue
                stats["approach_seen"] += 1
                total = sum(obs.values())
                if obs.get(c):
                    stats["triple_seen"] += 1
                    continue
                if b not in g.loc or a not in g.loc or c not in g.loc:
                    continue
                ang = turn(bearing(g.loc[a], g.loc[b]), bearing(g.loc[b], g.loc[c]))
                if total >= 5 and abs(ang) >= 30:
                    flagged.append({"pair": name[:-5], "rank": rank, "at": list(g.loc[b]),
                                    "angle": round(ang), "approach_obs": total,
                                    "taken": {str(k): v for k, v in obs.items()}})
    return stats, flagged


def cmd_report(args):
    with open(args.scan) as f:
        scan = json.load(f)
    uz = polygon_test(scan.get("borders", {}).get("Uzbekistan", []), CITY_BBOX[1] - PAD, CITY_BBOX[3] + PAD)
    if uz:
        INSIDE.append(uz)
    else:
        print("граница Узбекистана не собрана — рамка целиком", file=sys.stderr)
    city_test = polygon_test(scan.get("borders", {}).get("Tashkent", []), CITY_BBOX[1] - PAD, CITY_BBOX[3] + PAD)
    g = Graph(scan)
    restrictions = audit_restrictions(scan, g)
    city = [r for r in restrictions if r["at"] and in_core(*r["at"])]
    signals = [(lat, lon) for _, (lat, lon, t) in g.tagged.items()
               if t.get("highway") == "traffic_signals" and in_core(lat, lon)]
    # 1. Числа
    kinds = Counter(r["kind"] for r in city)
    kinds_country = Counter(r["kind"] for r in restrictions)
    for r in restrictions:
        r["severity"] = sorted({severity(i) for i in r["issues"]})
    broken = [r for r in city if ({"E", "D"} & set(r["severity"])) and "X" not in r["severity"]]
    issue_kinds = Counter(f"{severity(i)} {issue_key(i)}" for r in city for i in r["issues"])
    road_len = defaultdict(float)
    oneway_len = defaultdict(float)
    oneway_count = Counter()
    access_no = Counter()
    access_restricted = Counter()
    conditional = Counter()
    for wid, w in g.ways.items():
        t = w["tags"]
        if not g.core_way(wid) or t.get("area") == "yes":
            continue
        hw = t.get("highway")
        L = g.way_len(wid)
        road_len[hw] += L
        if direction(t) not in (0,) and direction(t) is not None:
            oneway_len[hw] += L
            oneway_count[hw] += 1
        acc = access_of(t)
        if acc in BLOCKED:
            access_no[f"{hw}:{acc}"] += 1
        elif acc in RESTRICTED:
            access_restricted[acc] += 1
        for k in ("oneway:conditional", "access:conditional", "motor_vehicle:conditional"):
            if k in t:
                conditional[k] += 1
    barriers = Counter()
    signs = Counter()
    for nid, (lat, lon, t) in g.tagged.items():
        if not in_core(lat, lon):
            continue
        if "barrier" in t and nid in g.arms:
            barriers[t["barrier"] + (" (перекрывает)" if nid in g.blocked else "")] += 1
        if "traffic_sign" in t:
            signs[t["traffic_sign"]] += 1
    for wid, w in g.ways.items():
        if "traffic_sign" in w["tags"] and g.core_way(wid):
            signs["way:" + w["tags"]["traffic_sign"]] += 1
    main = scc_main(g)
    sinks, sources, total_len, lost_len, lost_ways = oneway_traps(g, main)
    # Тупик oneway, а в 30 м от него начинается такой же oneway — проезжая
    # часть разорвана (два куска не соединены узлом).
    for a in sinks:
        for b in sources:
            if meters(a["at"], b["at"]) <= 30:
                a["kind"] = b["kind"] = "разрыв проезжей части"
                a["gap_m"] = b["gap_m"] = round(meters(a["at"], b["at"]), 1)
    js = junctions(g, city, signals)
    openings = median_openings(g, city, signals)

    major_km = sum(road_len[h] for h in ("trunk", "primary", "secondary", "motorway")) / 1000
    all_km = sum(road_len.values()) / 1000
    nums = {
        "relations_city": len(city), "relations_country": len(restrictions),
        "kinds_city": dict(kinds.most_common()), "kinds_country": dict(kinds_country.most_common()),
        "via_way_city": sum(1 for r in city if r["via"] == "w"),
        "broken_city": len(broken), "issue_kinds": dict(issue_kinds.most_common()),
        "broken_country": sum(1 for r in restrictions
                              if {"E", "D"} & set(r["severity"]) and "X" not in r["severity"]),
        "busway_city": sum(1 for r in city if "B" in r["severity"]),
        "not_car_city": sum(1 for r in city if "X" in r["severity"]),
        "usable_city": sum(1 for r in city if usable(r)),
        "usable_kinds_city": dict(Counter(r["kind"] for r in city if usable(r)).most_common()),
        "warn_city": sum(1 for r in city if r["severity"] == ["W"]),
        "road_km": {k: round(v / 1000, 1) for k, v in sorted(road_len.items(), key=lambda kv: -kv[1])},
        "oneway_km": {k: round(v / 1000, 1) for k, v in sorted(oneway_len.items(), key=lambda kv: -kv[1])},
        "oneway_ways": dict(oneway_count.most_common()), "oneway_ways_total": sum(oneway_count.values()),
        "access_blocked": dict(access_no.most_common()), "access_restricted": dict(access_restricted.most_common()),
        "conditional": dict(conditional), "barriers": dict(barriers.most_common()),
        "traffic_signs": dict(signs.most_common(30)), "signals": len(signals),
        "major_km": round(major_km, 1), "all_km": round(all_km, 1),
        "graph_len_km": round(total_len / 1000, 1), "lost_len_km": round(lost_len / 1000, 2),
        "lost_ways_km": {k: round(v / 1000, 2) for k, v in sorted(lost_ways.items(), key=lambda kv: -kv[1])},
        "sinks": Counter(s["kind"] for s in sinks), "sources": Counter(s["kind"] for s in sources),
        "junctions": len(js), "junctions_signal": sum(1 for j in js if j["signal"]),
        "junctions_no_restr": sum(1 for j in js if j["restrictions"] == 0),
        "junctions_no_restr_signal": sum(1 for j in js if j["restrictions"] == 0 and j["signal"]),
        "junctions_no_valid": sum(1 for j in js if j["valid_restrictions"] == 0),
        "openings": len(openings), "openings_midblock": sum(1 for o in openings if o["midblock"]),
        "openings_midblock_restricted": sum(1 for o in openings if o["midblock"] and o["restricted_self"]),
        "openings_junction": sum(1 for o in openings if not o["midblock"]),
        "openings_junction_restricted": sum(1 for o in openings if not o["midblock"] and o["restricted"]),
    }
    if city_test:
        inside = [r for r in city if city_test(*r["at"])]
        nums["relations_tashkent_city"] = len(inside)
        nums["junctions_tashkent_city"] = sum(1 for j in js if city_test(*j["at"]))
        nums["junctions_tashkent_city_bare"] = sum(1 for j in js if city_test(*j["at"]) and j["restrictions"] == 0)
        for j in js:
            j["in_city"] = city_test(*j["at"])
    nums["per_100km_major"] = round(len(city) / major_km * 100, 1) if major_km else None
    nums["per_100_junctions"] = round(len(city) / len(js) * 100, 1) if js else None
    turn_part = None
    if args.turns:
        with open(args.turns) as f:
            turns = json.load(f)
        tstats = {"triples": len(turns), "obs": sum(t[3] for t in turns),
                  "qualified": sum(1 for t in turns if t[3] >= 5 and t[4] >= 3),
                  "nodes": len({t[1] for t in turns}),
                  "by_maneuver": dict(Counter(("разворот" if abs(t[6]) > 150 else "прямо" if abs(t[6]) < 30
                                               else "направо" if t[6] > 0 else "налево") for t in turns)),
                  "city_nodes": sum(1 for v in {t[1] for t in turns} if v in g.loc and in_core(*g.loc[v]))}
        # Насколько данные водителей покрывают крупные перекрёстки.
        jnodes = {n: i for i, j in enumerate(js) for n in j["nodes"]}
        tstats["junction_nodes_city"] = sum(1 for n, arms in g.arms.items()
                                            if n in g.loc and in_core(*g.loc[n]) and len({o for _, o, _ in arms}) >= 3)
        tstats["junctions_with_obs"] = len({jnodes[t[1]] for t in turns if t[1] in jnodes})
        # Поворот, запрещённый relation, а водители его делают (или наоборот).
        no_turn = {}
        for r in city:
            if r["via_node"] and usable(r) and r["kind"].startswith("no_"):
                for fw in r["from"]:
                    for tw in r["to"]:
                        no_turn[(fw, r["via_node"], tw)] = r["id"]
        pair_way = {}
        for wid, w in g.ways.items():
            for a, b in zip(w["nodes"], w["nodes"][1:]):
                pair_way[(a, b)] = pair_way[(b, a)] = wid
        against = []
        for u, v, w, n, days, delay, angle in turns:
            key = (pair_way.get((u, v)), v, pair_way.get((v, w)))
            if key[0] == key[2] and u != w:
                continue  # прошёл путь насквозь, а не развернулся
            if key in no_turn:
                against.append({"relation": no_turn[key], "at": list(g.loc.get(v, (0, 0))), "n": n,
                                "days": days, "angle": angle})
        only = {}
        for r in city:
            if r["via_node"] and usable(r) and r["kind"].startswith("only_"):
                for fw in r["from"]:
                    only[(fw, r["via_node"])] = (set(r["to"]), r["id"])
        for u, v, w, n, days, delay, angle in turns:
            fw, tw = pair_way.get((u, v)), pair_way.get((v, w))
            hit = only.get((fw, v))
            if hit and tw not in hit[0]:
                against.append({"relation": hit[1], "at": list(g.loc.get(v, (0, 0))), "n": n,
                                "days": days, "angle": angle, "only": True})
        tstats["against_restriction"] = against
        if args.routes:
            rs, flagged = route_turn_check(g, turns, args.routes)
            tstats["routes"] = dict(rs)
            tstats["route_flagged"] = flagged
        turn_part = tstats
    street_barriers = []
    for n in g.blocked:
        if n not in g.loc or not in_core(*g.loc[n]) or not g.arms.get(n):
            continue
        classes = {g.hw(w) for w, _, _ in g.arms[n]}
        if classes & {"trunk", "primary", "secondary", "tertiary", "trunk_link", "primary_link",
                      "secondary_link", "tertiary_link", "unclassified", "residential"}:
            street_barriers.append({"node": n, "at": list(g.loc[n]), "tags": g.tagged[n][2],
                                    "class": max(classes, key=lambda h: major_rank(h) * 10 + (h not in YARD)),
                                    "names": sorted({street_name(g.tags(w)) for w, _, _ in g.arms[n]} - {""})})
    nums["street_barriers"] = Counter(b["class"] for b in street_barriers)
    audit = {"numbers": nums, "street_barriers": street_barriers, "junctions": js, "openings": openings, "restrictions": city,
             "sinks": sinks, "sources": sources, "turns": turn_part}
    with open(args.out, "w") as f:
        json.dump(audit, f, ensure_ascii=False, default=lambda o: dict(o))
    print(json.dumps(nums, ensure_ascii=False, indent=1, default=lambda o: dict(o)))
    if turn_part:
        print(json.dumps({k: v for k, v in turn_part.items() if k not in ("route_flagged",)},
                         ensure_ascii=False, default=lambda o: dict(o))[:3000])
    if args.geojson:
        write_geojson(audit, args.geojson, args.top)


def write_geojson(audit, path, top):
    feats = []

    def point(at, props):
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [at[1], at[0]]},
                      "properties": props})
    bare = [j for j in audit["junctions"] if j["restrictions"] == 0]
    for i, j in enumerate(bare[:top]):
        point(j["at"], {"layer": "перекрёсток без запретов", "rank": i + 1, "streets": " × ".join(j["streets"][:3]),
                        "arms": j["arms"], "signal": j["signal"], "divided": j["divided"],
                        "marker-color": "#d62728", "marker-symbol": str(i + 1) if i < 9 else "",
                        "title": f"{i + 1}. " + " × ".join(j["streets"][:2])})
    for o in audit["openings"]:
        if o["midblock"] and o["rank"] >= 2:
            point(o["at"], {"layer": "разрыв разделительной", "street": o["street"], "len": o["len"],
                            "signal": o["signal"], "no_u_turn": o["restricted_self"],
                            "marker-color": "#1f77b4", "marker-size": "small"})
    for r in audit["restrictions"]:
        if {"E", "D"} & set(r["severity"]) and "X" not in r["severity"] and r["at"]:
            point(r["at"], {"layer": "ловушка: only_* в невозможный путь" if "D" in r["severity"] else "битый запрет", "relation": f"https://www.openstreetmap.org/relation/{r['id']}",
                            "kind": r["kind"], "issues": "; ".join(r["issues"]),
                            "marker-color": "#9467bd", "marker-size": "small"})
    for b in audit.get("street_barriers", []):
        point(b["at"], {"layer": "барьер на проезжей улице", "class": b["class"], "names": ", ".join(b["names"]),
                        "tags": ", ".join(f"{k}={v}" for k, v in b["tags"].items()),
                        "node": f"https://www.openstreetmap.org/node/{b['node']}",
                        "marker-color": "#000000", "marker-size": "small"})
    for s in audit["sinks"] + audit["sources"]:
        if s["class"] == "service":
            continue
        point(s["at"], {"layer": s["kind"], "class": s["class"], "names": ", ".join(s["names"]),
                        "node": f"https://www.openstreetmap.org/node/{s['node']}",
                        "marker-color": "#ff7f0e", "marker-size": "small"})
    with open(path, "w") as f:
        json.dump({"type": "FeatureCollection", "features": feats}, f, ensure_ascii=False, indent=0)
    print("GeoJSON:", len(feats), "точек →", path, file=sys.stderr)


# --------------------------------------------------------------------- shots

ROAD_STYLE = {
    "motorway": 0, "trunk": 0, "primary": 1, "secondary": 2, "tertiary": 3,
    "motorway_link": 1, "trunk_link": 1, "primary_link": 2, "secondary_link": 3, "tertiary_link": 3,
    "residential": 4, "unclassified": 4, "living_street": 5, "service": 5,
}


def cmd_shots(args):
    """Спецификации для render_routes.swift: рамка ~620×470 м вокруг места,
    фон — дороги, oneway главных классов — синей линией «маршрута» (стрелок
    направления рендер не рисует), запреты рядом — чёрные метки с типом."""
    with open(args.audit) as f:
        audit = json.load(f)
    with open(args.scan) as f:
        scan = json.load(f)
    os.makedirs(args.out, exist_ok=True)
    places = [j for j in audit["junctions"] if j["restrictions"] == 0 and j.get("in_city", True)][:args.top]
    for k, extra in enumerate(args.extra or []):
        lat, lon, title = extra.split(",", 2)
        places.append({"at": [float(lat), float(lon)], "title": title, "name": f"place_{k + 1:02d}"})
    restr_points = [r for r in audit["restrictions"]]
    for i, j in enumerate(places):
        lat, lon = j["at"]
        dlat, dlon = 0.0028, 0.0028 / math.cos(math.radians(lat))
        box = [lat - dlat, lon - dlon * 1.25, lat + dlat, lon + dlon * 1.25]
        roads, oneways = [], []
        for w in scan["ways"].values():
            t = w["tags"]
            style = ROAD_STYLE.get(t.get("highway"))
            pts = [c for c in w["coords"] if c]
            if style is None or len(pts) < 2:
                continue
            if not any(box[0] <= c[0] <= box[2] and box[1] <= c[1] <= box[3] for c in pts):
                continue
            line = [[round(c[1], 6), round(c[0], 6)] for c in pts]
            d = direction(t)
            if d in (1, -1) and style <= 3:
                if d == -1:
                    line = line[::-1]
                oneways.append(line)
            roads.append([style, line])
        markers = [{"p": [lon, lat], "kind": "to", "text": f"{i + 1}"}]
        for r in restr_points:
            if r["at"] and box[0] <= r["at"][0] <= box[2] and box[1] <= r["at"][1] <= box[3]:
                markers.append({"p": [r["at"][1], r["at"][0]], "kind": "defect", "text": r["kind"]})
        title = j.get("title") or (f"{i + 1}. " + " × ".join(j["streets"][:2]) + f" — ветвей {j['arms']}, "
                                   + ("светофор" if j["signal"] else "без светофора") + ", запретов 0")
        spec = {"title": title,
                "bbox": box, "width": 1200, "height": 900, "roads": roads,
                "routes": [{"rank": 0, "p": l, "label": "oneway (синим)" if k == 0 else ""}
                           for k, l in enumerate(oneways)][:200],
                "markers": markers}
        with open(os.path.join(args.out, (j.get("name") or f"junction_{i + 1:02d}") + ".spec.json"), "w") as f:
            json.dump(spec, f, ensure_ascii=False)
    print("спецификаций:", len(places))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--pbf", required=True)
    s.add_argument("--out", required=True)
    r = sub.add_parser("report")
    r.add_argument("--scan", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--geojson")
    r.add_argument("--top", type=int, default=30)
    r.add_argument("--turns", help="агрегат traffic_turn_obs: [[u, v, w, n, дней, медиана с, угол]]")
    r.add_argument("--routes", help="каталог ответов route_audit.py fetch")
    h = sub.add_parser("shots")
    h.add_argument("--audit", required=True)
    h.add_argument("--scan", required=True)
    h.add_argument("--out", required=True)
    h.add_argument("--top", type=int, default=5)
    h.add_argument("--extra", action="append", help="lat,lon,подпись — ещё одно место")
    args = ap.parse_args()
    {"scan": cmd_scan, "report": cmd_report, "shots": cmd_shots}[args.cmd](args)


if __name__ == "__main__":
    main()
