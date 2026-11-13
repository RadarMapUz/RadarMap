#!/usr/bin/env python3
"""Слой наших поправок маршрутов (91, 13.11.2026).

Граф OSRM собирается из чистой выгрузки OSM, и до 91 всё, что мы знаем
лучше OSM, — «налево нельзя» под знаком, кирпич, бордюр на оси улицы, битый
relation — до маршрута не доходило: правки конструктора едут только в тайлы.
Слой накладывает правки на выгрузку ПЕРЕД osrm-extract: osmChange →
pyosmium MergeInputReader → копия pbf. Графу всё равно, откуда взялся
relation, — он видит обычный OSM.

    python3 server/osrm/route_patches.py apply --pbf IN.osm.pbf --out OUT.osm.pbf \
        --report DIR [--repo patches/route_patches.json] [--panel panel.json]
    python3 server/osrm/route_patches.py cards --scan scan.json --audit audit.json \
        --runs DIR [DIR …] --out server/review/junction_turns.json
    python3 server/osrm/route_patches.py check --report DIR --runs DIR [DIR …]

Два источника правок: файл в репозитории (patches/route_patches.json —
исправления аудитов, ревьюятся коммитом) и правки модераторов из панели
(map_edits, `admin.py --export-route-patches`, только чтение).

ПРАВКА ДЕРЖИТСЯ ЗА OSM id И ОТПЕЧАТОК. Узлы пути, теги барьера, версия
relation записаны в правке; на свежей выгрузке сверяется всё. Что-то
разошлось — правка НЕ применяется, а уходит в очередь «проверить»: тот же
принцип, что у osm_queue (автоматика двигает, но не решает). Правка из
конструктора задана местом и азимутами — её опора ищется заново каждую
сборку, и неоднозначность тоже идёт в очередь, а не в догадку. OSM сделал то
же сам — «OSM догнал», правка не дублируется.

OSRM ТИХО выбрасывает запрет, у которого узел via не конец пути from или to
(проверено на v26.7.3: «removed 0 invalid», а в графе запретов 0). Поэтому
под каждый запрет пути режутся в узлах via, и все relation, которые ссылались
на разрезанный путь, перецепляются на нужный кусок — иначе слой молча убил
бы чужие запреты OSM.
"""
import argparse
import hashlib
import json
import math
import os
import sys
import time
from collections import Counter, defaultdict
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import turn_audit as ta  # noqa: E402

REPO_FILE = os.path.join(HERE, "patches", "route_patches.json")

KINDS = ("turn_ban", "no_entry", "oneway", "unbarrier", "relation_fix")
KIND_WORDS = {"turn_ban": "запрет поворота", "no_entry": "кирпич", "oneway": "одностороннее",
              "unbarrier": "убрать барьер", "relation_fix": "починить relation"}
NO_TURNS = {"no_left_turn", "no_right_turn", "no_straight_on", "no_u_turn"}
ONLY_TURNS = {"only_left_turn", "only_right_turn", "only_straight_on", "only_u_turn"}

APPLIED, CAUGHT_UP, CHECK = "applied", "caught_up", "check"
VERDICT_WORDS = {APPLIED: "применена", CAUGHT_UP: "OSM догнал", CHECK: "проверить"}

# Узел опоры уехал дальше — это уже не дрожание координат выгрузки.
MOVE_METERS = 5.0
# Перекрёсток с разделительными: узлы двух проезжих частей — в 20–40 м.
CLUSTER_METERS = 40.0
BEARING_DEGREES = 35.0
ROAD_METERS = 20.0
BARRIER_METERS = 15.0
# Вторая дорога ближе трёх метров к первой — не гадаем (проспект с дублёром).
AMBIGUOUS_METERS = 3.0
INNER_HOPS = 8
BLOCK_METERS = 500.0
# Что собирать вокруг правки: квартал целиком и его соседей.
COLLECT_METERS = 650.0
PROBE_METERS = 90.0
# Свои id новых путей и relation: заведомо выше любых id OSM.
NEW_ID = 9_000_000_000_000
BLOCKING_ACCESS = ("access", "motor_vehicle", "motorcar", "vehicle")
ONEWAY_KEYS = ("oneway:motorcar", "oneway:motor_vehicle", "oneway:vehicle")


def pairs(path):
    return list(zip(path, path[1:]))


def seg_key(a, b):
    return (a, b) if a < b else (b, a)


def angle_apart(one, other):
    gap = abs((one - other) % 360)
    return min(gap, 360 - gap)


def maneuver(angle):
    """Вид поворота по углу (плюс — направо, как ta.turn)."""
    if abs(angle) >= 150:
        return "uturn"
    if angle <= -30:
        return "left"
    if angle >= 30:
        return "right"
    return "straight"


RESTRICTION_MANEUVER = {"no_left_turn": "left", "only_left_turn": "left", "no_right_turn": "right",
                        "only_right_turn": "right", "no_straight_on": "straight",
                        "only_straight_on": "straight", "no_u_turn": "uturn", "only_u_turn": "uturn"}


# ------------------------------------------------------------------ правки

def normalize(raw, source):
    """Правка из файла или панели → единый вид. (правка, None) или (None, почему)."""
    if not isinstance(raw, dict):
        return None, "правка — не объект"
    pid = str(raw.get("id") or "").strip()
    kind = raw.get("kind")
    if not pid:
        return None, "у правки нет id"
    if kind not in KINDS:
        return None, f"неизвестный вид {kind!r}"
    out = {"id": pid, "kind": kind, "source": source, "note": str(raw.get("note") or ""),
           "evidence": raw.get("evidence") or "", "expect": raw.get("expect") or {}}
    intent = raw.get("intent")
    if intent is not None:
        if not (isinstance(intent, dict) and _point(intent.get("at"))):
            return None, "intent без точки at"
        out["intent"] = intent
    if kind == "turn_ban":
        value = raw.get("restriction")
        if value not in NO_TURNS | ONLY_TURNS:
            return None, f"неизвестный запрет {value!r}"
        out["restriction"] = value
        path = raw.get("path")
        if path is not None:
            if not _ids(path) or len(path) < 3:
                return None, "path: нужно не меньше трёх узлов OSM"
            if value in ONLY_TURNS and len(path) != 3:
                return None, "only_*: только через узел (три узла)"
            out["path"] = [int(n) for n in path]
        if path is None and intent is None:
            return None, "нужен path или intent"
        if intent is not None and not all(isinstance(intent.get(k), (int, float))
                                          for k in ("from_bearing", "to_bearing")):
            return None, "intent: нужны from_bearing и to_bearing"
    elif kind in ("no_entry", "oneway"):
        path = raw.get("path")
        if path is not None:
            if not _ids(path) or len(path) < 2:
                return None, "path: нужно не меньше двух узлов OSM"
            out["path"] = [int(n) for n in path]
        elif intent is None or not isinstance(intent.get("bearing"), (int, float)):
            return None, "нужен path или intent с bearing"
    elif kind == "unbarrier":
        node = raw.get("node")
        if node is not None:
            if not _ids([node]):
                return None, "node — не id"
            out["node"] = int(node)
        elif intent is None:
            return None, "нужен node или intent"
    elif kind == "relation_fix":
        rid = raw.get("relation")
        if not _ids([rid]):
            return None, "relation — не id"
        out["relation"] = int(rid)
        members = raw.get("members")
        if members is not None:
            try:
                out["members"] = [(str(t), int(ref), str(role)) for t, ref, role in members]
            except (TypeError, ValueError):
                return None, "members: [[тип, id, роль], …]"
            if any(t not in ("n", "w", "r") for t, _, _ in out["members"]):
                return None, "members: тип n, w или r"
    anchored = out.get("path") or out.get("node")
    if out["expect"].get("at") is not None or anchored:
        at = out["expect"].get("at")
        if kind == "unbarrier" and at is not None:
            at = [at]
        want = len(out["path"]) if out.get("path") else 1
        if not (isinstance(at, list) and len(at) == want and all(_point(p) for p in at)):
            return None, "expect.at: [широта, долгота] на каждый узел опоры"
    return out, None


def _ids(values):
    try:
        return all(int(v) > 0 for v in values)
    except (TypeError, ValueError):
        return False


def _point(value):
    return (isinstance(value, (list, tuple)) and len(value) == 2
            and all(isinstance(v, (int, float)) for v in value)
            and -90 <= value[0] <= 90 and -180 <= value[1] <= 180)


def load_repo(path=REPO_FILE):
    if not path or not os.path.exists(path):
        return {}, []
    with open(path, encoding="utf-8") as f:
        payload = json.load(f)
    return payload.get("settings") or {}, payload.get("patches") or []


def from_panel(item):
    """Правка конструктора (строка map_edits) → правка слоя. raw у панели —
    [долгота, широта], у слоя — [широта, долгота], как у OSM и аудита 88."""
    props = item.get("props") or {}
    raw = item.get("raw") or []
    out = {"id": f"panel-{item.get('id')}", "kind": item.get("kind"),
           "note": item.get("note") or "", "evidence": props.get("evidence") or "",
           "author": item.get("author") or ""}
    if len(raw) >= 2 and not isinstance(raw[0], (list, tuple)):
        out["intent"] = {"at": [float(raw[1]), float(raw[0])]}
    kind = item.get("kind")
    if kind == "turn_ban":
        out["restriction"] = props.get("restriction")
        if "intent" in out:
            out["intent"]["from_bearing"] = props.get("from_bearing")
            out["intent"]["to_bearing"] = props.get("to_bearing")
        if props.get("path"):
            out["path"] = props["path"]
            if props.get("path_at"):
                out["expect"] = {"at": props["path_at"]}
    elif kind in ("no_entry", "oneway") and "intent" in out:
        out["intent"]["bearing"] = props.get("bearing")
    return out


def layer_sha(patches):
    body = json.dumps(sorted(patches, key=lambda p: p["id"]), ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(body.encode()).hexdigest()[:16]


# --------------------------------------------------------------------- сеть

class Net:
    """Кусок OSM вокруг правок: пути highway с узлами, теги узлов, relation.

    nodes: id → {"at": (lat, lon), "tags": {}, "version": v}
    ways: id → {"nodes": [...], "tags": {}, "version": v}
    relations: id → {"tags": {}, "members": [(тип, id, роль)], "version": v}
    """

    def __init__(self, nodes, ways, relations):
        self.nodes, self.ways, self.relations = nodes, ways, relations
        self.seg = defaultdict(list)       # (min, max) → [(путь, индекс отрезка)]
        self.nbr = defaultdict(set)
        self.blocked = {n for n, d in nodes.items() if ta.node_blocks(d.get("tags") or {})}
        self.grid = defaultdict(list)
        for wid, w in ways.items():
            if not ta.drivable(w["tags"]):
                continue
            refs = w["nodes"]
            for i, (a, b) in enumerate(zip(refs, refs[1:])):
                if a == b or a not in nodes or b not in nodes:
                    continue
                self.seg[seg_key(a, b)].append((wid, i))
                self.nbr[a].add(b)
                self.nbr[b].add(a)
        for n in self.nbr:
            lat, lon = nodes[n]["at"]
            self.grid[(int(lat / 0.002), int(lon / 0.002))].append(n)

    def at(self, n):
        return self.nodes[n]["at"]

    def near(self, point, meters):
        cy, cx = int(point[0] / 0.002), int(point[1] / 0.002)
        reach = int(meters / 160) + 1
        out = []
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                for n in self.grid.get((cy + dy, cx + dx), ()):
                    if ta.meters(point, self.at(n)) <= meters:
                        out.append(n)
        return out

    def ways_of(self, a, b):
        return [wid for wid, _ in self.seg.get(seg_key(a, b), ())]

    def can_go(self, a, b, through_barriers=False):
        """Отрезок a→b проезжий в эту сторону: путь, oneway, барьеры."""
        if not through_barriers and (a in self.blocked or b in self.blocked):
            return False
        for wid, i in self.seg.get(seg_key(a, b), ()):
            d = ta.direction(self.ways[wid]["tags"])
            forward = self.ways[wid]["nodes"][i] == a
            if d == 0 or (d == 1 and forward) or (d == -1 and not forward):
                return True
        return False

    def bearing(self, a, b):
        return ta.bearing(self.at(a), self.at(b))

    def street(self, a, b):
        for wid in self.ways_of(a, b):
            name = ta.street_name(self.ways[wid]["tags"])
            if name:
                return name
        return ""


def restriction_parts(members):
    fr = [ref for t, ref, role in members if role == "from" and t == "w"]
    to = [ref for t, ref, role in members if role == "to" and t == "w"]
    via = [(t, ref) for t, ref, role in members if role == "via"]
    return fr, via, to


def restriction_state(members, net):
    """("ok" | "interior" | "broken", почему). interior — via не конец from/to:
    OSRM такой запрет тихо выбросит, а разрез пути его чинит."""
    fr, via, to = restriction_parts(members)
    if len(fr) != 1:
        return "broken", "нужна ровно одна роль from"
    if len(to) != 1:
        return "broken", "нужна ровно одна роль to"
    if not via:
        return "broken", "нет роли via"
    for wid in fr + to + [ref for t, ref in via if t == "w"]:
        w = net.ways.get(wid)
        if w is None:
            return "broken", f"путь {wid} не в выгрузке или не дорога"
        if not ta.drivable(w["tags"]):
            return "broken", f"путь {wid} — не автодорога ({w['tags'].get('highway')})"
    if via[0][0] == "n":
        if len(via) != 1:
            return "broken", "via: несколько узлов"
        v = via[0][1]
        interior = False
        for wid in fr + to:
            refs = net.ways[wid]["nodes"]
            if v not in refs:
                return "broken", f"via {v} не на пути {wid}"
            if refs[0] != v and refs[-1] != v:
                interior = True
        return ("interior", "via не конец пути") if interior else ("ok", "")
    if any(t != "w" for t, _ in via):
        return "broken", "via: узлы и пути вперемешку"
    via_nodes = {n for _, ref in via for n in net.ways[ref]["nodes"]}
    for wid in fr + to:
        if not via_nodes & set(net.ways[wid]["nodes"]):
            return "broken", f"путь {wid} не касается via"
    return "ok", ""


def restriction_kind(tags):
    if any(v in ("motorcar", "motor_vehicle", "vehicle")
           for v in tags.get("except", "").replace(" ", "").split(";")):
        return None
    return tags.get("restriction") or tags.get("restriction:motorcar") or None


# ------------------------------------------------------------ разрешение

def decision(patch, verdict, reason="", **extra):
    out = {"id": patch["id"], "kind": patch["kind"], "source": patch["source"], "verdict": verdict,
           "reason": reason, "note": patch.get("note", ""), "evidence": patch.get("evidence", "")}
    if patch.get("author"):
        out["author"] = patch["author"]
    out.update(extra)
    return out


def anchor_problem(patch, net, ids, need_road=True):
    """Опора на месте? None — да, иначе почему нет."""
    want = (patch.get("expect") or {}).get("at")
    if patch["kind"] == "unbarrier" and want is not None:
        want = [want]
    for i, n in enumerate(ids):
        if n not in net.nodes:
            return f"узла {n} нет в выгрузке"
        if need_road and n not in net.nbr:
            return f"узел {n} больше не на проезжей дороге"
        if want and i < len(want):
            shift = ta.meters(net.at(n), want[i])
            if shift > MOVE_METERS:
                return f"узел {n} сдвинулся на {shift:.0f} м"
    if need_road:
        for a, b in pairs(ids):
            if not net.ways_of(a, b):
                return f"узлы {a} и {b} больше не соседи по дороге"
    return None


def inner_path(net, start, goal, inner):
    """Кратчайший проезжий путь внутри перекрёстка (Дейкстра по метрам)."""
    if start == goal:
        return [start]
    best = {start: 0.0}
    prev = {}
    frontier = [(0.0, 0, start)]
    import heapq
    while frontier:
        dist, hops, n = heapq.heappop(frontier)
        if n == goal:
            path = [n]
            while path[-1] != start:
                path.append(prev[path[-1]])
            return path[::-1]
        if dist > best.get(n, 1e18) or hops >= INNER_HOPS:
            continue
        for m in net.nbr[n]:
            if m not in inner or not net.can_go(n, m):
                continue
            nd = dist + ta.meters(net.at(n), net.at(m))
            if nd < best.get(m, 1e18):
                best[m] = nd
                prev[m] = n
                heapq.heappush(frontier, (nd, hops + 1, m))
    return None


def geometric_turn(intent, net):
    """Путь поворота по месту и азимутам → ([узлы], None) или (None, почему)."""
    at = tuple(intent["at"])
    inner = set(net.near(at, CLUSTER_METERS))
    if not inner:
        return None, "рядом с точкой нет дорог"
    fb, tb = float(intent["from_bearing"]), float(intent["to_bearing"])
    entries, exits = [], []
    for b in inner:
        for a in net.nbr[b]:
            if a in inner:
                continue
            if net.can_go(a, b) and angle_apart(net.bearing(a, b), fb) <= BEARING_DEGREES:
                entries.append((a, b))
            if net.can_go(b, a) and angle_apart(net.bearing(b, a), tb) <= BEARING_DEGREES:
                exits.append((b, a))
    entries, exits = _prefer_streets(net, entries), _prefer_streets(net, exits)
    found = []
    for a, b in entries:
        for c, d in exits:
            inside = inner_path(net, b, c, inner)
            if inside:
                found.append([a] + inside + [d])
    if not found:
        return None, (f"не нашли поворот с азимута {fb:.0f}° на {tb:.0f}° "
                      f"(подходов {len(entries)}, выездов {len(exits)})")
    if len(found) > 1:
        return None, f"неоднозначно: {len(found)} вариантов поворота — нужна правка по узлам"
    return found[0], None


def _prefer_streets(net, edges):
    """Двор рядом с улицей под тем же азимутом — не повод для неоднозначности."""
    def yard(edge):
        return all(net.ways[w]["tags"].get("highway") in ("service", "living_street")
                   for w in net.ways_of(*edge))
    streets = [e for e in edges if not yard(e)]
    return streets or edges


def nearest_segment(net, point, bearing=None):
    """Ближайший проезжий отрезок (a, b), ориентированный по азимуту."""
    found = []
    for key, refs in net.seg.items():
        a, b = key
        pa, pb = net.at(a), net.at(b)
        if (abs(pa[0] - point[0]) > 0.01 or abs(pa[1] - point[1]) > 0.01):
            continue
        dist = _to_segment(point, pa, pb)
        if dist > ROAD_METERS:
            continue
        if bearing is not None:
            if angle_apart(ta.bearing(pa, pb), bearing) <= BEARING_DEGREES:
                found.append((dist, a, b))
            elif angle_apart(ta.bearing(pb, pa), bearing) <= BEARING_DEGREES:
                found.append((dist, b, a))
        else:
            found.append((dist, a, b))
    found.sort()
    if not found:
        return None, "рядом нет дороги под этим азимутом"
    dist, a, b = found[0]
    for other, c, d in found[1:]:
        if other - dist > AMBIGUOUS_METERS:
            break
        if {c, d} & {a, b}:
            continue
        return None, "неоднозначно: две дороги рядом (проспект с дублёром?)"
    return (a, b), None


def _to_segment(p, a, b):
    kx = 111320.0 * math.cos(math.radians(p[0]))
    ax, ay = (a[1] - p[1]) * kx, (a[0] - p[0]) * 111320.0
    bx, by = (b[1] - p[1]) * kx, (b[0] - p[0]) * 111320.0
    dx, dy = bx - ax, by - ay
    norm = dx * dx + dy * dy
    t = 0.0 if norm == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / norm))
    return math.hypot(ax + t * dx, ay + t * dy)


BEND_DEGREES = 60.0


def block_of(net, a, b):
    """Квартал улицы вокруг отрезка a→b: до ближайших перекрёстков в обе
    стороны или до угла (излом больше BEND_DEGREES — это уже другая улица)."""
    forward, back = [a, b], []
    length = ta.meters(net.at(a), net.at(b))

    def step(prev, cur, taken):
        if len(net.nbr[cur]) != 2:
            return None
        nxt = next(iter(net.nbr[cur] - {prev}))
        if nxt in taken or angle_apart(net.bearing(prev, cur), net.bearing(cur, nxt)) > BEND_DEGREES:
            return None
        return nxt

    prev, cur = a, b
    while length < BLOCK_METERS:
        nxt = step(prev, cur, forward)
        if nxt is None:
            break
        length += ta.meters(net.at(cur), net.at(nxt))
        forward.append(nxt)
        prev, cur = cur, nxt
    prev, cur = b, a
    while length < BLOCK_METERS:
        nxt = step(prev, cur, forward + back)
        if nxt is None:
            break
        length += ta.meters(net.at(cur), net.at(nxt))
        back.append(nxt)
        prev, cur = cur, nxt
    if length >= BLOCK_METERS:
        return None
    return back[::-1] + forward


def existing_turn(net, path, value):
    """Что про этот путь уже говорит OSM: ("same", rid) — запрещает то же,
    ("conflict", rid) — противоречит, None — молчит."""
    from_ways = set(net.ways_of(path[0], path[1]))
    to_ways = set(net.ways_of(path[-2], path[-1]))
    via_ways = {w for a, b in pairs(path[1:-1]) for w in net.ways_of(a, b)}
    for rid, rel in sorted(net.relations.items()):
        kind = restriction_kind(rel["tags"])
        if rel["tags"].get("type") != "restriction" or not kind:
            continue
        fr, via, to = restriction_parts(rel["members"])
        if not (set(fr) & from_ways):
            continue
        if len(path) == 3:
            if via != [("n", path[1])]:
                continue
        elif not via or any(t != "w" for t, _ in via) or {ref for _, ref in via} != via_ways:
            continue
        hits_to = bool(set(to) & to_ways)
        if value in NO_TURNS:
            if (kind.startswith("no_") and hits_to) or (kind.startswith("only_") and not hits_to):
                return "same", rid
            if kind.startswith("only_") and hits_to:
                return "conflict", rid
        elif kind.startswith("only_"):
            return ("same", rid) if hits_to else ("conflict", rid)
        elif hits_to:
            return "conflict", rid
    return None


def resolve(patch, net):
    """Одна правка против свежей выгрузки → решение с планом изменений."""
    kind = patch["kind"]
    if kind == "turn_ban":
        return resolve_turn(patch, net)
    if kind in ("no_entry", "oneway"):
        return resolve_oneway(patch, net)
    if kind == "unbarrier":
        return resolve_barrier(patch, net)
    return resolve_relation(patch, net)


def resolve_turn(patch, net):
    path = patch.get("path")
    if path:
        why = anchor_problem(patch, net, path)
        if why:
            hint = None
            if patch.get("intent"):
                hint, _ = geometric_turn(patch["intent"], net)
            return decision(patch, CHECK, f"опора изменилась: {why}", suggestion=hint)
    else:
        path, why = geometric_turn(patch["intent"], net)
        if not path:
            return decision(patch, CHECK, why)
    if not all(net.can_go(a, b) for a, b in pairs(path)):
        return decision(patch, CAUGHT_UP, "по графу этот поворот и так невозможен (oneway или барьер)",
                        path=path)
    hit = existing_turn(net, path, patch["restriction"])
    if hit and hit[0] == "conflict":
        return decision(patch, CHECK, f"противоречит relation {hit[1]} в OSM", path=path)
    if hit:
        rel = net.relations[hit[1]]
        plan = []
        state, _ = restriction_state(rel["members"], net)
        reason = f"в OSM есть relation {hit[1]}"
        if state == "interior":
            plan.append(("normalize", hit[1]))
            reason += " (via не конец пути — путь разрезаем, иначе OSRM его выбросит)"
        return decision(patch, CAUGHT_UP, reason, path=path, plan=plan, check={"ban_paths": [path]})
    angle = ta.turn(net.bearing(path[0], path[1]), net.bearing(path[-2], path[-1]))
    maneuver_kind = maneuver(angle)
    if mismatch(RESTRICTION_MANEUVER[patch["restriction"]], angle):
        return decision(patch, CHECK, f"тип {patch['restriction']}, а по узлам поворот на {angle:.0f}°", path=path)
    return decision(patch, APPLIED, "", path=path, maneuver=maneuver_kind,
                    plan=[("restriction", patch["restriction"], path, patch["id"])],
                    check={"ban_paths": [path]} if patch["restriction"] in NO_TURNS else {})


def resolve_oneway(patch, net):
    path = patch.get("path")
    if path:
        why = anchor_problem(patch, net, path)
        if why:
            return decision(patch, CHECK, f"опора изменилась: {why}")
        allowed = path if patch["kind"] == "oneway" else path[::-1]
    else:
        intent = patch["intent"]
        seg, why = nearest_segment(net, tuple(intent["at"]), float(intent["bearing"]))
        if not seg:
            return decision(patch, CHECK, why)
        block = block_of(net, *seg)
        if not block:
            return decision(patch, CHECK, f"квартал длиннее {BLOCK_METERS:.0f} м — задайте правку по узлам")
        allowed = block if patch["kind"] == "oneway" else block[::-1]
    if not all(net.can_go(a, b) for a, b in pairs(allowed)):
        return decision(patch, CHECK, "в OSM здесь одностороннее в обратную сторону или барьер",
                        path=allowed)
    forbidden = [[b, a] for a, b in pairs(allowed)]
    if not any(net.can_go(a, b) for a, b in forbidden):
        return decision(patch, CAUGHT_UP, "в OSM участок уже односторонний в эту сторону", path=allowed,
                        check={"forbidden_pairs": forbidden})
    return decision(patch, APPLIED, "", path=allowed, plan=[("oneway", allowed, patch["id"])],
                    check={"forbidden_pairs": forbidden})


def resolve_barrier(patch, net):
    node = patch.get("node")
    if node:
        why = anchor_problem(patch, net, [node], need_road=False)
        if why:
            return decision(patch, CHECK, f"опора изменилась: {why}")
    else:
        at = tuple(patch["intent"]["at"])
        found = sorted((ta.meters(at, net.at(n)), n) for n in net.near(at, BARRIER_METERS)
                       if n in net.blocked)
        if not found:
            if any(n in net.nbr for n in net.near(at, BARRIER_METERS)):
                return decision(patch, CAUGHT_UP, "рядом нет барьера, перекрывающего проезд")
            return decision(patch, CHECK, "рядом нет дороги")
        if len(found) > 1 and found[1][0] - found[0][0] <= AMBIGUOUS_METERS:
            return decision(patch, CHECK, "неоднозначно: два барьера рядом")
        node = found[0][1]
    tags = dict(net.nodes[node].get("tags") or {})
    if not ta.node_blocks(tags):
        return decision(patch, CAUGHT_UP, "барьера на узле больше нет — проезд открыт", node=node,
                        check={"through": node})
    want = (patch.get("expect") or {}).get("tags") or {}
    changed = [f"{k}={tags.get(k)!s} (было {v})" for k, v in sorted(want.items()) if tags.get(k) != v]
    if changed:
        return decision(patch, CHECK, "теги узла изменились: " + ", ".join(changed), node=node)
    new = {k: v for k, v in tags.items()
           if k != "barrier" and not (k in BLOCKING_ACCESS and v in ta.BLOCKED)}
    if ta.node_blocks(new):
        return decision(patch, CHECK, "узел перекрывает проезд и без barrier — нужен разбор", node=node)
    if node not in net.nbr:
        return decision(patch, CHECK, "узел не на проезжей дороге", node=node)
    return decision(patch, APPLIED, "", node=node, plan=[("tags", node, new, patch["id"])],
                    check={"through": node})


def resolve_relation(patch, net):
    rid = patch["relation"]
    rel = net.relations.get(rid)
    if rel is None:
        return decision(patch, CAUGHT_UP, "relation удалён из OSM")
    want = patch.get("expect") or {}
    if want.get("version") is not None and rel["version"] != want["version"]:
        state, why = restriction_state(rel["members"], net)
        if state == "ok":
            return decision(patch, CAUGHT_UP, f"relation починили в OSM (версия {rel['version']})")
        return decision(patch, CHECK, f"relation изменён (версия {want['version']} → {rel['version']}), "
                                      f"а запрет всё ещё не годен: {why}")
    members = patch.get("members") or rel["members"]
    state, why = restriction_state(members, net)
    if state == "broken":
        return decision(patch, CHECK, f"починка не делает relation годным: {why}")
    wrong = against_geometry(rel["tags"], members, net)
    if wrong:
        return decision(patch, CHECK, wrong)
    if state == "interior":
        _, why = side_choice(rel["tags"], members, net)
        if why:
            return decision(patch, CHECK, why)
    plan = [("relation", rid, members if patch.get("members") else None, patch["id"])]
    return decision(patch, APPLIED, "" if state == "ok" else "путь разрезан в via", plan=plan,
                    members=[list(m) for m in members])


def against_geometry(tags, members, net):
    """Тип запрета против геометрии: no_left_turn, а по узлам — направо. Только
    там, где via — конец обоих путей (иначе сторона подхода не определена)."""
    want = RESTRICTION_MANEUVER.get(restriction_kind(tags) or "")
    fr, via, to = restriction_parts(members)
    if not want or len(via) != 1 or via[0][0] != "n":
        return None
    v = via[0][1]
    near = []
    for wid in (fr[0], to[0]):
        refs = net.ways[wid]["nodes"]
        if refs[0] == v:
            near.append(refs[1])
        elif refs[-1] == v:
            near.append(refs[-2])
        else:
            return None
    angle = ta.turn(net.bearing(near[0], v), net.bearing(v, near[1]))
    if mismatch(want, angle):
        return f"тип {restriction_kind(tags)}, а по геометрии поворот на {angle:.0f}°"
    return None


def mismatch(want, angle):
    """Тип запрета явно против угла (налево, а угол направо; прямо, а угол крутой)."""
    return ((want == "left" and angle > 30) or (want == "right" and angle < -30)
            or (want == "straight" and abs(angle) > 60) or (want == "uturn" and abs(angle) < 120))


def side_choice(tags, members, net):
    """via внутри пути: с какой стороны подход и куда выезд. → ({путь: сосед via}, None)
    или (None, почему). Сторона выбирается по типу запрета, и только однозначно."""
    fr, via, to = restriction_parts(members)
    if len(fr) != 1 or len(to) != 1 or len(via) != 1 or via[0][0] != "n":
        return None, "не через узел"
    v = via[0][1]

    def sides(wid):
        refs = net.ways[wid]["nodes"]
        return [refs[i + d] for i, n in enumerate(refs) if n == v
                for d in (-1, 1) if 0 <= i + d < len(refs)]
    want = RESTRICTION_MANEUVER.get(restriction_kind(tags) or "")
    combos = [(f, t) for f in sides(fr[0]) for t in sides(to[0])
              if f != t or fr[0] != to[0] or want == "uturn"]
    if want:
        combos = [(f, t) for f, t in combos
                  if maneuver(ta.turn(net.bearing(f, v), net.bearing(v, t))) == want]
    if len(combos) != 1:
        return None, f"via внутри пути, сторону не выбрать ({len(combos)} вариантов по типу запрета)"
    return {"from": combos[0][0], "to": combos[0][1]}, None


# ---------------------------------------------------------------- изменения

class Changes:
    """План правок → новые и изменённые объекты OSM."""

    def __init__(self, net):
        self.net = net
        self.node_tags = {}                  # узел → новые теги
        self.split = defaultdict(set)        # путь → узлы разреза
        self.oneway = {}                     # (путь, индекс отрезка) → True, если по ходу пути
        self.restrictions = []               # (значение, путь узлов, id правки)
        self.relation_members = {}           # relation → новые участники
        self.normalize = set()               # relation, у которых via надо сделать концом пути
        self.notes = []

    def way_for(self, a, b):
        ways = [w for w in self.net.ways_of(a, b) if ta.drivable(self.net.ways[w]["tags"])]
        return min(ways) if ways else None

    def runs(self, path):
        """Путь узлов → [(путь OSM, его узлы подряд)]: где путь OSM меняется."""
        out = []
        for a, b in pairs(path):
            wid = self.way_for(a, b)
            if out and out[-1][0] == wid:
                out[-1][1].append(b)
            else:
                out.append((wid, [a, b]))
        return out

    def add(self, item):
        op = item[0]
        if op == "tags":
            self.node_tags[item[1]] = item[2]
        elif op == "oneway":
            for wid, nodes in self.runs(item[1]):
                refs = self.net.ways[wid]["nodes"]
                for a, b in pairs(nodes):
                    i = next(k for k in range(len(refs) - 1) if seg_key(refs[k], refs[k + 1]) == seg_key(a, b))
                    self.oneway[(wid, i)] = refs[i] == a
                self.cut(wid, nodes[0])
                self.cut(wid, nodes[-1])
        elif op == "restriction":
            _, value, path, pid = item
            self.restrictions.append((value, path, pid))
            self.cut(self.way_for(path[0], path[1]), path[1])
            self.cut(self.way_for(path[-2], path[-1]), path[-2])
            for wid, nodes in self.runs(path[1:-1]):
                self.cut(wid, nodes[0])
                self.cut(wid, nodes[-1])
        elif op == "relation":
            _, rid, members, _ = item
            if members is not None:
                self.relation_members[rid] = list(members)
            self.normalize.add(rid)
        elif op == "normalize":
            self.normalize.add(item[1])

    def cut(self, wid, node):
        refs = self.net.ways[wid]["nodes"]
        if node in refs[1:-1]:
            self.split[wid].add(node)

    def members_of(self, rid):
        return self.relation_members.get(rid) or self.net.relations[rid]["members"]

    def finalize(self):
        """→ {"nodes": {...}, "ways": {...}, "relations": {...}} (изменённые и новые)."""
        net = self.net
        for rid in sorted(self.normalize):
            fr, via, to = restriction_parts(self.members_of(rid))
            if len(via) == 1 and via[0][0] == "n":
                for wid in fr + to:
                    if wid in net.ways:
                        self.cut(wid, via[0][1])
        next_id = [NEW_ID]

        def new_id():
            next_id[0] += 1
            return next_id[0]

        chunks = {}       # путь → [(id, узлы, первый индекс отрезка)]
        out_ways = {}
        for wid in sorted(set(self.split) | {w for w, _ in self.oneway}):
            w = net.ways[wid]
            refs = w["nodes"]
            cuts = sorted({i for i, n in enumerate(refs) if n in self.split.get(wid, ()) and 0 < i < len(refs) - 1})
            bounds = [0] + cuts + [len(refs) - 1]
            parts = []
            for k, (s, e) in enumerate(zip(bounds, bounds[1:])):
                cid = wid if k == 0 else new_id()
                parts.append((cid, refs[s:e + 1], s))
            chunks[wid] = parts
            for cid, nodes, start in parts:
                tags = dict(w["tags"])
                marks = [self.oneway[(wid, start + j)] for j in range(len(nodes) - 1)
                         if (wid, start + j) in self.oneway]
                if marks:
                    tags["oneway"] = "yes" if all(marks) else "-1"
                    for key in ONEWAY_KEYS:
                        tags.pop(key, None)
                out_ways[cid] = {"nodes": nodes, "tags": tags,
                                 "version": w["version"] + 1 if cid == wid else 1,
                                 "action": "modify" if cid == wid else "create", "origin": wid}

        def chunk_of(a, b):
            wid = self.way_for(a, b)
            for cid, nodes, _ in chunks.get(wid, [(wid, net.ways[wid]["nodes"], 0)]):
                for x, y in pairs(nodes):
                    if seg_key(x, y) == seg_key(a, b):
                        return cid
            return wid

        out_relations = {}
        for value, path, pid in self.restrictions:
            members = [("w", chunk_of(path[0], path[1]), "from")]
            if len(path) == 3:
                members.append(("n", path[1], "via"))
            else:
                seen = []
                for a, b in pairs(path[1:-1]):
                    cid = chunk_of(a, b)
                    if cid not in seen:
                        seen.append(cid)
                members += [("w", cid, "via") for cid in seen]
            members.append(("w", chunk_of(path[-2], path[-1]), "to"))
            out_relations[new_id()] = {"members": members, "version": 1, "action": "create",
                                       "tags": {"type": "restriction", "restriction": value,
                                                "radarmap:patch": pid}}
        for rid, rel in sorted(net.relations.items()):
            members = self.members_of(rid)
            touched = rid in self.relation_members or any(t == "w" and ref in chunks for t, ref, _ in members)
            if not touched:
                continue
            fixed = self.repoint(rel["tags"], members, chunks)
            if fixed != rel["members"]:
                out_relations[rid] = {"members": fixed, "tags": dict(rel["tags"]),
                                      "version": rel["version"] + 1, "action": "modify"}
        out_nodes = {}
        for nid, tags in self.node_tags.items():
            node = net.nodes[nid]
            out_nodes[nid] = {"at": node["at"], "tags": tags, "version": node["version"] + 1,
                              "action": "modify"}
        return {"nodes": out_nodes, "ways": out_ways, "relations": out_relations}

    def repoint(self, tags, members, chunks):
        """Участники relation после разреза путей: каждый from/to — на кусок
        у via (выбор стороны — по типу поворота), прочие — все куски по порядку."""
        net = self.net
        is_restriction = tags.get("type", "").startswith("restriction")
        fr, via, to = restriction_parts(members)
        via_node = via[0][1] if is_restriction and len(via) == 1 and via[0][0] == "n" else None
        via_way_nodes = set()
        if is_restriction and via and all(t == "w" for t, _ in via):
            for _, ref in via:
                for cid, nodes, _ in chunks.get(ref, [(ref, net.ways[ref]["nodes"] if ref in net.ways else [], 0)]):
                    via_way_nodes |= {nodes[0], nodes[-1]} if nodes else set()
        out = []
        for t, ref, role in members:
            if t != "w" or ref not in chunks:
                out.append((t, ref, role))
                continue
            parts = chunks[ref]
            if is_restriction and role in ("from", "to") and via_node is not None:
                ends = [p for p in parts if via_node in (p[1][0], p[1][-1])]
                if len(ends) > 1:
                    sides, _ = side_choice(tags, members, net)
                    near = sides and sides[role]
                    picked = [p for p in ends if near is not None and any(
                        seg_key(x, y) == seg_key(near, via_node) for x, y in pairs(p[1]))]
                    ends = picked or ends[:1]
                out.append(("w", ends[0][0] if ends else ref, role))
            elif is_restriction and role in ("from", "to") and via_way_nodes:
                ends = [p for p in parts if {p[1][0], p[1][-1]} & via_way_nodes]
                out.append(("w", (ends or parts)[0][0], role))
            else:
                out += [("w", cid, role) for cid, _, _ in parts]
        return out


# ------------------------------------------------------------------ вывод

def osc_xml(objects):
    """osmChange для слияния с выгрузкой (MergeInputReader)."""
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<osmChange version="0.6" generator="RadarMap route_patches">']
    for action in ("modify", "create"):
        body = []
        for nid, n in sorted(objects["nodes"].items()):
            if n["action"] == action:
                body.append(_node_xml(nid, n))
        for wid, w in sorted(objects["ways"].items()):
            if w["action"] == action:
                body.append(_way_xml(wid, w))
        for rid, r in sorted(objects["relations"].items()):
            if r["action"] == action:
                body.append(_relation_xml(rid, r))
        if body:
            lines += [f"<{action}>"] + body + [f"</{action}>"]
    lines.append("</osmChange>")
    return "\n".join(lines) + "\n"


def _tags_xml(tags):
    return "".join(f'<tag k={quoteattr(str(k))} v={quoteattr(str(v))}/>' for k, v in sorted(tags.items()))


def _version(obj):
    return f' version="{obj["version"]}"' if obj.get("version") else ""


def _node_xml(nid, n, extra=""):
    lat, lon = n["at"]
    return (f'<node id="{nid}"{_version(n)}{extra} lat="{lat:.7f}" lon="{lon:.7f}">'
            f'{_tags_xml(n.get("tags") or {})}</node>')


def _way_xml(wid, w, extra=""):
    nds = "".join(f'<nd ref="{r}"/>' for r in w["nodes"])
    return f'<way id="{wid}"{_version(w)}{extra}>{nds}{_tags_xml(w["tags"])}</way>'


def _relation_xml(rid, r, extra=""):
    kinds = {"n": "node", "w": "way", "r": "relation"}
    mem = "".join(f'<member type="{kinds[t]}" ref="{ref}" role={quoteattr(role)}/>' for t, ref, role in r["members"])
    return f'<relation id="{rid}"{_version(r)}{extra}>{mem}{_tags_xml(r["tags"])}</relation>'


def josm_xml(objects, net, node_versions):
    """Файл JOSM для правки OSM владельцем: новые объекты — с отрицательными
    id, изменённые — с версией из выгрузки и action="modify", узлы путей — для
    показа. Своих тегов (radarmap:patch) в OSM не везём."""
    remap = {}
    counter = [0]

    def neg(oid):
        if oid not in remap:
            counter[0] -= 1
            remap[oid] = counter[0]
        return remap[oid]

    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<osm version="0.6" generator="RadarMap route_patches" upload="true">']
    shown = set()
    for nid, n in sorted(objects["nodes"].items()):
        orig = net.nodes[nid]
        lines.append(_node_xml(nid, {"at": orig["at"], "tags": n["tags"], "version": orig["version"]},
                               ' action="modify"'))
        shown.add(nid)
    for wid, w in sorted(objects["ways"].items()):
        for r in w["nodes"]:
            if r in shown or r not in net.nodes:
                continue
            shown.add(r)
            orig = net.nodes[r]
            lines.append(_node_xml(r, {"at": orig["at"], "tags": orig.get("tags") or {},
                                       "version": node_versions.get(r) or orig.get("version") or 1}))
    for wid, w in sorted(objects["ways"].items()):
        if w["action"] == "create":
            lines.append(_way_xml(neg(wid), {"nodes": w["nodes"], "tags": w["tags"]}, ' action="modify"'))
        else:
            lines.append(_way_xml(wid, {"nodes": w["nodes"], "tags": w["tags"],
                                        "version": net.ways[wid]["version"]}, ' action="modify"'))
    for rid, r in sorted(objects["relations"].items()):
        members = [(t, remap.get(ref, ref) if t == "w" else ref, role) for t, ref, role in r["members"]]
        tags = {k: v for k, v in r["tags"].items() if not k.startswith("radarmap:")}
        if r["action"] == "create":
            lines.append(_relation_xml(neg(rid), {"members": members, "tags": tags}, ' action="modify"'))
        else:
            lines.append(_relation_xml(rid, {"members": members, "tags": tags,
                                             "version": net.relations[rid]["version"]}, ' action="modify"'))
    lines.append("</osm>")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------ пробы

def walk(net, start, toward, meters):
    """Точка в meters от start по дороге через toward (без поворотов на
    перекрёстках) и азимут движения в ней ОТ start."""
    path = [start, toward]
    length = ta.meters(net.at(start), net.at(toward))
    while length < meters:
        cur, prev = path[-1], path[-2]
        options = [n for n in net.nbr[cur] if n != prev and n not in path]
        if not options:
            break
        heading = net.bearing(prev, cur)
        nxt = min(options, key=lambda n: angle_apart(net.bearing(cur, n), heading))
        if angle_apart(net.bearing(cur, nxt), heading) > 45:
            break
        length += ta.meters(net.at(cur), net.at(nxt))
        path.append(nxt)
    a, b = path[-2], path[-1]
    over = max(0.0, length - meters)
    seg = ta.meters(net.at(a), net.at(b)) or 1.0
    t = max(0.0, min(1.0, 1 - over / seg))
    lat = net.at(a)[0] + (net.at(b)[0] - net.at(a)[0]) * t
    lon = net.at(a)[1] + (net.at(b)[1] - net.at(a)[1]) * t
    return [round(lat, 7), round(lon, 7)], round(net.bearing(a, b))


def probes_for(dec, net):
    """Пары точек «до и после» правки для аудита графа."""
    out = []
    pid = dec["id"]
    if dec["kind"] == "turn_ban" and dec.get("path") and dec["verdict"] != CHECK:
        p = dec["path"]
        start, h_back = walk(net, p[1], p[0], PROBE_METERS)
        end, h_out = walk(net, p[-2], p[-1], PROBE_METERS)
        out.append({"id": f"{pid}", "from": start, "to": end, "bearings": [(h_back + 180) % 360, h_out],
                    "expect": "avoid"})
    elif dec["kind"] == "unbarrier" and dec.get("node"):
        n = dec["node"]
        nbrs = sorted(net.nbr.get(n, ()))
        for i, a in enumerate(nbrs):
            for b in nbrs:
                if a == b or angle_apart(net.bearing(a, n), net.bearing(n, b)) > 45:
                    continue
                if not (net.can_go(a, n, True) and net.can_go(n, b, True)):
                    continue
                start, h1 = walk(net, n, a, PROBE_METERS)
                end, h2 = walk(net, n, b, PROBE_METERS)
                out.append({"id": f"{pid}-{len(out) + 1}", "from": start, "to": end,
                            "bearings": [(h1 + 180) % 360, h2], "expect": "through"})
    elif dec["kind"] in ("no_entry", "oneway") and dec.get("path"):
        p = dec["path"][::-1]  # запрещённое направление
        length = sum(ta.meters(net.at(a), net.at(b)) for a, b in pairs(p))
        if length >= 30:
            start, _ = walk(net, p[0], p[1], min(10.0, length / 4))
            end, _ = walk(net, p[-1], p[-2], min(10.0, length / 4))
            out.append({"id": pid, "from": start, "to": end,
                        "bearings": [round(net.bearing(p[0], p[1])), None], "expect": "avoid"})
    return out


def violations(nodes, check):
    """Сколько раз маршрут (узлы OSM по ходу) нарушает правку."""
    count = 0
    for path in check.get("ban_paths") or ():
        k = len(path)
        count += sum(1 for i in range(len(nodes) - k + 1) if nodes[i:i + k] == path)
    forbidden = {tuple(p) for p in check.get("forbidden_pairs") or ()}
    if forbidden:
        count += sum(1 for a, b in zip(nodes, nodes[1:]) if (a, b) in forbidden)
    return count


def route_nodes(route):
    out = []
    for leg in route.get("legs", []):
        for n in (leg.get("annotation") or {}).get("nodes", []):
            if not out or out[-1] != n:
                out.append(n)
    return out


def probe_url(base, probe):
    (alat, alon), (blat, blon) = probe["from"], probe["to"]
    marks = ";".join("" if b is None else f"{int(b) % 360},60" for b in probe["bearings"])
    return (f"{base.rstrip('/')}/route/v1/driving/{alon:.7f},{alat:.7f};{blon:.7f},{blat:.7f}"
            f"?overview=false&annotations=nodes&bearings={marks}")


def check_runs(report, run_dir):
    """Маршруты пар и проб одного графа против наших правок.

    → {"violations": n, "by_patch": {id: n}, "probes": {id: {"ok", "through", "distance"}}}"""
    checks = {d["id"]: d["check"] for d in report["patches"] if d.get("check")}
    out = {"violations": 0, "by_patch": {}, "probes": {}}
    for name in sorted(os.listdir(run_dir)) if os.path.isdir(run_dir) else []:
        if not name.endswith(".json"):
            continue
        with open(os.path.join(run_dir, name)) as f:
            resp = json.load(f)
        for route in resp.get("routes", [])[:3]:
            nodes = route_nodes(route)
            for pid, chk in checks.items():
                n = violations(nodes, chk)
                if n:
                    out["by_patch"][pid] = out["by_patch"].get(pid, 0) + n
                    out["violations"] += n
    probe_dir = os.path.join(run_dir, "probes")
    for d in report["patches"]:
        for probe in d.get("probes") or ():
            path = os.path.join(probe_dir, probe["id"] + ".json")
            if not os.path.exists(path):
                continue
            with open(path) as f:
                resp = json.load(f)
            if resp.get("code") != "Ok" or not resp.get("routes"):
                # «Объехать» без маршрута вовсе — тоже не нарушение: туда в эту
                # сторону просто нельзя (oneway при азимуте точки).
                out["probes"][probe["id"]] = {"ok": probe["expect"] == "avoid", "error": resp.get("code"),
                                              "expect": probe["expect"]}
                continue
            route = resp["routes"][0]
            nodes = route_nodes(route)
            if probe["expect"] == "through":
                ok = d["check"].get("through") in nodes
            else:
                ok = violations(nodes, d["check"]) == 0
            out["probes"][probe["id"]] = {"ok": ok, "expect": probe["expect"], "distance": round(route["distance"]),
                                          "duration": round(route["duration"])}
    return out


# ---------------------------------------------------------------- выгрузка

def interest(patches):
    """Что собрать из выгрузки: точки с радиусом, пути и relation по id."""
    points, ways, relations = [], set(), set()
    for p in patches:
        at = (p.get("expect") or {}).get("at")
        if at:
            for q in ([at] if p["kind"] == "unbarrier" else at):
                points.append((q[0], q[1]))
        if p.get("intent"):
            points.append(tuple(p["intent"]["at"]))
        if p["kind"] == "relation_fix":
            relations.add(p["relation"])
            ways |= {ref for t, ref, _ in (p.get("members") or ()) if t == "w"}
            ways |= {ref for t, ref, _ in ((p.get("expect") or {}).get("members") or ()) if t == "w"}
    return points, ways, relations


def collect(pbf, patches, radius=COLLECT_METERS):
    """Один проход по выгрузке (pyosmium, ~7 с и ~0,9 ГБ на страну) → Net."""
    import osmium
    points, want_ways, want_rels = interest(patches)
    if want_rels:
        # Участники чинимых relation — до прохода по путям (relation в pbf идут последними).
        for r in osmium.FileProcessor(pbf, osmium.osm.RELATION).with_filter(osmium.filter.IdFilter(sorted(want_rels))):
            want_ways |= {m.ref for m in r.members if m.type == "w"}
    grid = set()
    cell = 0.002
    reach = int(radius / (cell * 80000)) + 1
    for lat, lon in points:
        cy, cx = int(lat / cell), int(lon / cell)
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                grid.add((cy + dy, cx + dx))
    nodes, ways, relations = {}, {}, {}
    tagged = {}
    rel_nodes = set()
    keys = ("highway", "barrier", "type") + BLOCKING_ACCESS
    fp = osmium.FileProcessor(pbf).with_locations("sparse_mem_array").with_filter(osmium.filter.KeyFilter(*keys))
    for o in fp:
        if o.is_node():
            if o.location.valid():
                tagged[o.id] = {"at": (o.location.lat, o.location.lon), "tags": dict(o.tags),
                                "version": o.version}
        elif o.is_way():
            if "highway" not in o.tags and o.id not in want_ways:
                continue
            refs = [n.ref for n in o.nodes]
            locs = []
            hit = o.id in want_ways
            for n in o.nodes:
                loc = n.location
                if not loc.valid():
                    locs.append(None)
                    continue
                locs.append((loc.lat, loc.lon))
                if not hit and (int(loc.lat / cell), int(loc.lon / cell)) in grid:
                    hit = True
            if not hit:
                continue
            ways[o.id] = {"nodes": refs, "tags": dict(o.tags), "version": o.version}
            for r, loc in zip(refs, locs):
                if loc and r not in nodes:
                    nodes[r] = {"at": loc, "tags": {}, "version": 0}
        else:
            members = [(m.type, m.ref, m.role) for m in o.members]
            restriction = o.tags.get("type", "").startswith("restriction")
            if restriction or o.id in want_rels or any(t == "w" and ref in ways for t, ref, _ in members):
                relations[o.id] = {"tags": dict(o.tags), "members": members, "version": o.version}
                rel_nodes |= {ref for t, ref, _ in members if t == "n"}
    for nid, data in tagged.items():
        if nid in nodes:
            nodes[nid] = data
        elif nid in rel_nodes:
            nodes[nid] = data
    return Net(nodes, ways, relations)


def node_versions(pbf, ids):
    import osmium
    out = {}
    if not ids:
        return out
    for n in osmium.FileProcessor(pbf, osmium.osm.NODE).with_filter(osmium.filter.IdFilter(sorted(ids))):
        out[n.id] = n.version
    return out


def merge(pbf, osc_path, out):
    """Выгрузка + osmChange → новая выгрузка (C++ pyosmium, ~2 с на страну)."""
    import osmium
    import osmium.io as oio
    if os.path.exists(out):
        os.remove(out)
    pool = oio.ThreadPool()
    reader = oio.Reader(pbf, thread_pool=pool)
    header = oio.Header()
    for key in ("osmosis_replication_timestamp", "osmosis_replication_sequence_number"):
        value = reader.header().get(key)
        if value:
            header.set(key, value)
    writer = oio.Writer(oio.File(out), header, thread_pool=pool)
    changes = osmium.MergeInputReader()
    changes.add_file(osc_path)
    try:
        changes.apply_to_reader(reader, writer, False)
    finally:
        reader.close()
        writer.close()


# ------------------------------------------------------------------ сборка

def gather(repo_path, panel_items):
    """Правки обоих источников → (правки, неразобранные решения, настройки)."""
    settings, repo_raw = load_repo(repo_path)
    patches, rejected = [], []
    seen = set()
    for raw, source in [(r, "repo") for r in repo_raw] + [(from_panel(i), "panel") for i in panel_items or ()]:
        patch, why = normalize(raw, source)
        if patch is None:
            stub = {"id": str((raw or {}).get("id") or "?"), "kind": (raw or {}).get("kind") or "?",
                    "source": source}
            rejected.append(decision(stub, CHECK, f"правка не разобрана: {why}"))
            continue
        if patch["id"] in seen:
            rejected.append(decision(patch, CHECK, "повтор id"))
            continue
        seen.add(patch["id"])
        patches.append(patch)
    return patches, rejected, settings


def plan_layer(patches, rejected, net):
    """Правки против сети → (решения, Changes). Противоречия — в очередь."""
    decisions = list(rejected)
    resolved = [resolve(p, net) for p in sorted(patches, key=lambda p: p["id"])]
    # Противоречия: одно и то же звено в разные стороны.
    owner = {}
    for d in resolved:
        if d["verdict"] == APPLIED and d["kind"] in ("no_entry", "oneway"):
            for a, b in pairs(d["path"]):
                prior = owner.get(seg_key(a, b))
                if prior and prior[1] != (a, b):
                    for x in (d, prior[0]):
                        x["verdict"], x["reason"] = CHECK, "противоречит другой правке одностороннего"
                        x.pop("plan", None)
                owner[seg_key(a, b)] = (d, (a, b))
    done_bans = {}
    changes = Changes(net)
    for d in resolved:
        if d["verdict"] == CHECK:
            continue
        for item in d.get("plan") or ():
            if item[0] == "restriction":
                key = (item[1], tuple(item[2]))
                if key in done_bans:
                    d["reason"] = f"то же, что {done_bans[key]}"
                    continue
                done_bans[key] = d["id"]
            changes.add(item)
    for d in resolved:
        d["probes"] = probes_for(d, net) if d["verdict"] != CHECK else []
        if "plan" in d:
            d["plan"] = [list(x) if not isinstance(x, list) else x for x in d["plan"]]
    decisions += resolved
    return decisions, changes


def evidence_ok_for_osm(d):
    """В OSM нельзя по снимкам и панорамам Яндекса: такая правка едет только в наш граф."""
    return d.get("evidence") not in ("yandex",)


def write_report(report_dir, report):
    os.makedirs(report_dir, exist_ok=True)
    with open(os.path.join(report_dir, "report.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    lines = [f"# Слой поправок маршрутов — {report['date']}", "",
             f"Выгрузка: данные на {report['pbf'].get('osm_timestamp')}, слой `{report['layer_sha']}`. "
             f"Правок {len(report['patches'])}: " + ", ".join(
                 f"{VERDICT_WORDS[k]} {v}" for k, v in sorted(report["counts"].items())) + ".",
             "", "Изменено в выгрузке: " + ", ".join(f"{k} {v}" for k, v in report["changes"].items()) + ".", ""]
    queue = [d for d in report["patches"] if d["verdict"] == CHECK]
    lines += [f"## Очередь «проверить» ({len(queue)})", ""]
    lines += [f"- `{d['id']}` ({KIND_WORDS.get(d['kind'], d['kind'])}, {d['source']}): {d['reason']}"
              + (f" — найдена другая опора: {d['suggestion']}" if d.get("suggestion") else "")
              for d in queue] or ["Пусто."]
    lines += ["", "## Все правки", "", "| id | вид | источник | решение | почему |", "|---|---|---|---|---|"]
    for d in report["patches"]:
        lines.append(f"| `{d['id']}` | {KIND_WORDS.get(d['kind'], d['kind'])} | {d['source']} | "
                     f"{VERDICT_WORDS[d['verdict']]} | {d['reason'] or '—'} |")
    with open(os.path.join(report_dir, "report.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def apply_layer(pbf, out, report_dir, repo_path=REPO_FILE, panel_items=(), date=None, pbf_info=None):
    """Наложить слой на выгрузку → сводка. Пишет out (pbf), report_dir/{report.json,
    report.md, changes.osc, osm_josm.osm, osm_checklist.md}."""
    started = time.monotonic()
    patches, rejected, settings = gather(repo_path, panel_items)
    net = collect(pbf, patches) if patches else Net({}, {}, {})
    decisions, changes = plan_layer(patches, rejected, net)
    objects = changes.finalize()
    os.makedirs(report_dir, exist_ok=True)
    osc_path = os.path.join(report_dir, "changes.osc")
    with open(osc_path, "w") as f:
        f.write(osc_xml(objects))
    merge(pbf, osc_path, out)
    # Для OSM — только применённое и проверенное не по Яндексу.
    osm_ids = {d["id"] for d in decisions if d["verdict"] in (APPLIED, CAUGHT_UP) and evidence_ok_for_osm(d)}
    osm_changes = Changes(net)
    for d in decisions:
        if d["id"] in osm_ids and d["verdict"] != CHECK:
            for item in d.get("plan") or ():
                osm_changes.add(tuple(item))
    osm_objects = osm_changes.finalize()
    refs = {r for w in osm_objects["ways"].values() for r in w["nodes"]}
    with open(os.path.join(report_dir, "osm_josm.osm"), "w") as f:
        f.write(josm_xml(osm_objects, net, node_versions(pbf, refs) if refs else {}))
    write_checklist(report_dir, decisions, osm_ids)
    counts = Counter(d["verdict"] for d in decisions)
    report = {"date": date or time.strftime("%Y-%m-%d"), "pbf": pbf_info or {}, "layer_sha": layer_sha(patches),
              "settings": settings, "counts": dict(counts),
              "changes": {"узлов": len(objects["nodes"]),
                          "путей изменено": sum(1 for w in objects["ways"].values() if w["action"] == "modify"),
                          "путей новых": sum(1 for w in objects["ways"].values() if w["action"] == "create"),
                          "relation изменено": sum(1 for r in objects["relations"].values() if r["action"] == "modify"),
                          "relation новых": sum(1 for r in objects["relations"].values() if r["action"] == "create")},
              "seconds": round(time.monotonic() - started, 1), "patches": decisions}
    write_report(report_dir, report)
    return report


def write_checklist(report_dir, decisions, osm_ids):
    lines = ["# Правки для OSM — проверить и залить со своего аккаунта", "",
             "Файл `osm_josm.osm` открыть в JOSM, сверить каждую правку по разрешённым для OSM",
             "источникам (снимки Bing/Esri, Mapillary, свой выезд или регистратор), «Обновить",
             "данные», залить своим аккаунтом с комментарием правки. Снимки и панорамы Яндекса",
             "и Google для OSM нельзя: правка, проверенная только по ним, в файл не попала.", ""]
    for d in decisions:
        if d["verdict"] == CHECK:
            continue
        if d["verdict"] == CAUGHT_UP:
            mark = "в OSM уже так" + (" (разрез пути в via — в файле)" if d.get("plan") else "")
        elif d["id"] in osm_ids:
            mark = "в файле"
        else:
            mark = "НЕ в файле (проверено по Яндексу — только наш граф)"
        what = d.get("path") or d.get("node") or d.get("members") or ""
        lines.append(f"- `{d['id']}` — {KIND_WORDS.get(d['kind'], d['kind'])}, {VERDICT_WORDS[d['verdict']]}; "
                     f"{mark}. {d.get('note') or ''} Узлы/участники: `{what}`")
    with open(os.path.join(report_dir, "osm_checklist.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


# ------------------------------------------------------------------ карточки

def junction_cards(scan, audit, run_dirs=(), limit=None):
    """Перекрёстки без запретов (аудит 88) → карточки «можно ли отсюда налево и на
    разворот?» для панели. Сначала узлы, где наши маршруты поворачивают налево."""
    g = ta.Graph(scan)
    pair_way = {}
    for wid, w in g.ways.items():
        if ta.drivable(w["tags"]):
            for a, b in zip(w["nodes"], w["nodes"][1:]):
                pair_way.setdefault(seg_key(a, b), wid)
    grid = defaultdict(list)
    for n, (lat, lon) in g.loc.items():
        if n in g.out or n in g.inc:
            grid[(int(lat / 0.001), int(lon / 0.001))].append(n)

    def around(center, meters):
        cy, cx = int(center[0] / 0.001), int(center[1] / 0.001)
        reach = int(meters / 80) + 1
        return [n for dy in range(-reach, reach + 1) for dx in range(-reach, reach + 1)
                for n in grid.get((cy + dy, cx + dx), ()) if ta.meters(center, g.loc[n]) <= meters]

    def hw(a, b):
        return g.hw(pair_way.get(seg_key(a, b)))

    def name(a, b):
        return ta.street_name(g.tags(pair_way.get(seg_key(a, b)))) if pair_way.get(seg_key(a, b)) else ""

    def bearing(a, b):
        return ta.bearing(g.loc[a], g.loc[b])

    def shortest(start, goal, inner):
        import heapq
        if start == goal:
            return [start]
        best, prev, frontier = {start: 0.0}, {}, [(0.0, start)]
        while frontier:
            dist, n = heapq.heappop(frontier)
            if n == goal:
                path = [n]
                while path[-1] != start:
                    path.append(prev[path[-1]])
                return path[::-1]
            if dist > best.get(n, 1e18):
                continue
            for m in g.out.get(n, ()):
                if m in inner:
                    nd = dist + g.seg_len.get((n, m), 0.0)
                    if nd < best.get(m, 1e18):
                        best[m], prev[m] = nd, n
                        heapq.heappush(frontier, (nd, m))
        return None

    cards, node_card = [], {}
    bare = [j for j in audit["junctions"] if j.get("restrictions") == 0]
    for rank, j in enumerate(bare, 1):
        center = tuple(j["at"])
        spread = [ta.meters(center, g.loc[n]) for n in j["nodes"] if n in g.loc]
        if not spread:
            continue
        reach = max(spread) + 15.0
        inner = set(around(center, reach))
        if not inner:
            continue
        entries, exits, arms = [], [], []
        for b in inner:
            for a in g.inc.get(b, ()):
                if a not in inner and hw(a, b) not in ("service", ""):
                    entries.append((a, b))
            for d in g.out.get(b, ()):
                if d not in inner and hw(b, d) not in ("service", ""):
                    exits.append((b, d))
            for _, other, _ in g.arms.get(b, ()):
                if other not in inner and hw(b, other) not in ("service", ""):
                    arms.append(round(ta.bearing(center, g.loc[other])))
        moves = []
        for a, b in entries:
            fb = bearing(a, b)
            by_kind = defaultdict(list)
            for c, d in exits:
                inside = shortest(b, c, inner)
                if not inside:
                    continue
                path = [a] + inside + [d]
                kind = maneuver(ta.turn(fb, bearing(c, d)))
                if kind not in ("left", "uturn"):
                    continue
                length = sum(g.seg_len.get((x, y), 0.0) for x, y in pairs(path[1:-1]))
                by_kind[(kind, name(c, d) if kind == "left" else "")].append((length, path, (c, d)))
            for (kind, _), options in by_kind.items():
                length, path, (c, d) = min(options)
                moves.append({"key": ",".join(map(str, path)), "kind": kind, "path": path,
                              "pts": [[round(g.loc[n][0], 7), round(g.loc[n][1], 7)] for n in path],
                              "from_street": name(a, b), "to_street": name(c, d),
                              "from_bearing": round(fb), "to_bearing": round(bearing(c, d)),
                              "from_hw": hw(a, b), "to_hw": hw(c, d), "routes": 0})
        if not moves:
            continue
        key = f"j{min(j['nodes'])}"
        card = {"key": key, "rank": rank, "at": [round(center[0], 6), round(center[1], 6)],
                "streets": j.get("streets", []), "signal": j.get("signal"), "divided": j.get("divided"),
                "arms": sorted(set(arms)), "score": j.get("score"), "in_city": j.get("in_city", True),
                "moves": sorted(moves, key=lambda m: (m["from_bearing"], m["kind"])), "route_lefts": 0,
                "inner": sorted(inner)}
        cards.append(card)
        for n in inner:
            node_card.setdefault(n, card)
    by_entry_exit = {}
    for card in cards:
        for m in card["moves"]:
            by_entry_exit[(m["path"][0], m["path"][1], m["path"][-2], m["path"][-1])] = (card, m)
    for run_dir in run_dirs:
        for fname in sorted(os.listdir(run_dir)):
            if not fname.endswith(".json"):
                continue
            with open(os.path.join(run_dir, fname)) as f:
                resp = json.load(f)
            for route in resp.get("routes", [])[:3]:
                nodes = route_nodes(route)
                for i in range(len(nodes) - 1):
                    card = node_card.get(nodes[i + 1])
                    if card is None or nodes[i] in card["inner"] or nodes[i + 1] not in card["inner"]:
                        continue
                    inner = set(card["inner"])
                    k = i + 1
                    while k + 1 < len(nodes) and nodes[k + 1] in inner:
                        k += 1
                    if k + 1 >= len(nodes):
                        continue
                    hit = by_entry_exit.get((nodes[i], nodes[i + 1], nodes[k], nodes[k + 1]))
                    if hit:
                        hit[1]["routes"] += 1
                        hit[0]["route_lefts"] += 1
    for card in cards:
        card.pop("inner")
    cards.sort(key=lambda c: (-c["route_lefts"], -(c["score"] or 0), -len(c["arms"])))
    return cards[:limit] if limit else cards


# -------------------------------------------------------------------- CLI

def cmd_apply(args):
    panel = []
    if args.panel:
        with open(args.panel) as f:
            panel = json.load(f).get("items") or []
    report = apply_layer(args.pbf, args.out, args.report, args.repo, panel)
    print(f"слой {report['layer_sha']}: " + ", ".join(
        f"{VERDICT_WORDS[k]} {v}" for k, v in sorted(report["counts"].items())) + f"; {report['seconds']} с")
    for d in report["patches"]:
        if d["verdict"] == CHECK:
            print(f"  проверить: {d['id']} — {d['reason']}")
    return 0


def cmd_cards(args):
    with open(args.scan) as f:
        scan = json.load(f)
    with open(args.audit) as f:
        audit = json.load(f)
    cards = junction_cards(scan, audit, args.runs or (), args.limit)
    payload = {"version": 1, "built": time.strftime("%Y-%m-%d"), "source": args.source or "", "cards": cards}
    with open(args.out, "w") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
    moves = sum(len(c["moves"]) for c in cards)
    print(f"карточек {len(cards)}, вопросов {moves}, с левыми поворотами наших маршрутов "
          f"{sum(1 for c in cards if c['route_lefts'])}")
    return 0


def cmd_check(args):
    with open(os.path.join(args.report, "report.json")) as f:
        report = json.load(f)
    bad = 0
    for run_dir in args.runs:
        r = check_runs(report, run_dir)
        failed = [k for k, v in r["probes"].items() if not v["ok"]]
        print(f"{run_dir}: нарушений {r['violations']} {r['by_patch'] or ''}; пробы: "
              f"{len(r['probes']) - len(failed)} из {len(r['probes'])} как ждали" + (f", мимо: {failed}" if failed else ""))
        bad += r["violations"] + len(failed)
    return 1 if bad else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("apply")
    a.add_argument("--pbf", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--report", required=True)
    a.add_argument("--repo", default=REPO_FILE)
    a.add_argument("--panel")
    c = sub.add_parser("cards")
    c.add_argument("--scan", required=True)
    c.add_argument("--audit", required=True)
    c.add_argument("--runs", nargs="*")
    c.add_argument("--out", required=True)
    c.add_argument("--limit", type=int)
    c.add_argument("--source", help="подпись: из какой выгрузки и аудита")
    k = sub.add_parser("check")
    k.add_argument("--report", required=True)
    k.add_argument("--runs", nargs="+", required=True)
    args = p.parse_args()
    return {"apply": cmd_apply, "cards": cmd_cards, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
