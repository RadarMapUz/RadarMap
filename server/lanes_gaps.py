#!/usr/bin/env python3
"""Очередь разметки полос (план 20.8): каким подходам к перекрёсткам данные
о полосах нужнее всего.

Перекрёстков тысячи, обойти или разметить все сразу нельзя. Начинать надо с
тех, через которые ездят чаще всего и где у телефона полос нет ни из OSRM,
ни из нашего слоя, ни (если дан экстракт) из turn:lanes OSM. Выход — CSV в
столбцах шаблона server/lanes/lanes_template.csv: строку заполняют на месте
(lanes, src, checked) и переносят в server/lanes/lanes.csv; пустые lanes
сборщик отвергнет, так что неразмеченная очередь опубликоваться не может.

ВХОД (любой набор):
  --traffic-db  traffic.db с VPS (traffic_build.py): рёбра OSM (u, v) и
                эффективные куски по ним в traffic_profile. Подход — ребро
                u→v, после которого водители реально разъезжаются хотя бы в
                две стороны (по каждой — не меньше порога и 5 % потока
                подхода); вес — поток подхода за последние месяцы (со
                старением профиля);
  --routes      ответы OSRM route (steps=true) — список маршрутов, когда
                пробок мало (замер 21.10: 12 маршрутов Ташкента): каждый
                поворот без `lanes` у OSRM — кандидат, вес — число маршрутов;
  --overlay     текущий слой (lanes.csv, GeoJSON или опубликованный
                lanes.<sha16>.json) — что уже покрыто;
  --osm         экстракт roads.geojsonl — что покрыто turn:lanes в OSM
                (тот же разбор, что build_lane_overlay.py --from-osm).
Покрыт ли подход, решается правилом телефона: запись слоя в 25 м и курс в
пределах её допуска.

ЛИЧНОГО НЕТ, и это проверяется тестом. Наружу идут только узлы дорог (общая
геометрия OSM), курс и счёт кусков, сложенный за месяцы, — ни часа, ни дня,
ни устройства, ни отдельного куска. Ребро в очередь попадает, только если
его прошли не меньше --min-traffic эффективных кусков И два куска прошли его
вместе за последние SHARED_TTL (traffic_shared — то же правило «не один
человек», что у файлов «обычно»): улица одного водителя в очередь не
попадает, даже если он ездит по ней каждый день. Запускать на VPS, где
лежит traffic.db, и забирать оттуда только CSV: сама база с машины не
уходит (в ней минутные куски следа).

База открывается только на чтение (PRAGMA query_only): крон пробок пишет в
неё каждые 2 минуты, и этот скрипт не должен ни мешать ему, ни менять её.

    python3 lanes_gaps.py --traffic-db /opt/radarmap/api/traffic.db \\
        --overlay lanes.csv --osm /opt/radarmap/work/roads.geojsonl \\
        --top 200 --csv lanes_queue.csv --geojson lanes_queue.geojson
    python3 lanes_gaps.py --routes route1.json route2.json --csv queue.csv
"""
import argparse
import csv
import datetime
import hashlib
import json
import os
import sqlite3
import sys
import time
from collections import defaultdict

import build_lane_overlay as blo
import traffic_build as tb

# Порог потока, эффективных кусков (traffic_build: кусок весит 1, старый
# меньше). Ниже — не про очередь и слишком близко к «одному человеку».
MIN_TRAFFIC = 10.0
# Сторона, куда уезжает меньше 5 % потока подхода, — не выбор ряда, а
# въезд во двор: без порога каждая подворотня проспекта стала бы
# «перекрёстком» с потоком всего проспекта.
TURN_SHARE = 0.05
MIN_TURNS = 2
# Курс подхода — по ~30 м до узла (узлы OSM у перекрёстка стоят в паре
# метров, и курс по одному ребру прыгает).
BEARING_BACK_METERS = 30.0
# Один подход перекрёстка — один пункт очереди: внутренние рёбра развязки
# (с первой проезжей части на вторую) идут тем же курсом в 20 м дальше.
SAME_APPROACH_METERS = 30.0
SAME_APPROACH_DEGREES = 20.0
# Правило телефона (контракт): запись слоя в 25 м, курс в её допуске.
PHONE_MATCH_METERS = 25.0
DEFAULT_TOP = 200

# Манёвры OSRM, перед которыми выбирают ряд.
TURN_MODIFIERS = {"left", "slight left", "sharp left", "right", "slight right",
                  "sharp right", "uturn"}
SKIP_TYPES = {"depart", "arrive", "roundabout", "rotary", "roundabout turn",
              "exit roundabout", "exit rotary", "notification"}

# Первые столбцы — ровно шаблон: строку очереди можно дописать и перенести.
OUTPUT_FIELDS = blo.CSV_FIELDS + ("traffic", "routes", "turns", "osm_turn_lanes", "edit_url")


def _warn(message):
    print("предупреждение: " + message, file=sys.stderr)


def _tables(conn):
    return {name for (name,) in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}


def _columns(conn, table):
    return {row[1] for row in conn.execute("PRAGMA table_info(%s)" % table)}


def open_readonly(path):
    if not os.path.exists(path):
        raise ValueError("нет базы %s" % path)
    conn = sqlite3.connect(path, timeout=5)
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA query_only = ON")
    return conn


def edge_weights(conn, now):
    """{(u, v): эффективные куски за всё время профиля}.

    pieces — с 8.8.16; на базе старше (или где pieces ещё нули) — n, число
    отрезков: в разы больше кусков, но порядок подходов тот же. Масштаб
    старения делится, как в traffic_build, — числа в выходе в «кусках»."""
    tables = _tables(conn)
    if "traffic_profile" not in tables or "traffic_nodes" not in tables:
        raise ValueError("в базе нет traffic_profile/traffic_nodes — это не traffic.db")
    measure = "n"
    if "pieces" in _columns(conn, "traffic_profile") and \
            conn.execute("SELECT 1 FROM traffic_profile WHERE pieces > 0 LIMIT 1").fetchone():
        measure = "pieces"
    else:
        _warn("в профиле нет кусков (pieces) — считаю по отрезкам (n); выложите traffic_build 8.8.16")
    scale = 1.0
    if "traffic_meta" in tables:
        row = conn.execute("SELECT value FROM traffic_meta WHERE key = 'profile_epoch'").fetchone()
        if row is not None:
            scale = tb.decay_scale(row[0], now)
    weights = {}
    for u, v, total in conn.execute(
            "SELECT u, v, SUM(%s) FROM traffic_profile GROUP BY u, v" % measure):
        if total and total > 0:
            weights[(u, v)] = total / scale
    return weights


def shared_edges(conn, now):
    """Рёбра «не одного человека» за SHARED_TTL; None — таблицы нет (старая база)."""
    tables = _tables(conn)
    if "traffic_shared" not in tables:
        _warn("в базе нет traffic_shared — правило «не один человек» не проверить, "
              "остаётся только порог потока")
        return None
    if "seen" in _columns(conn, "traffic_shared"):
        rows = conn.execute("SELECT u, v FROM traffic_shared WHERE seen >= ?", (now - tb.SHARED_TTL,))
    else:
        rows = conn.execute("SELECT u, v FROM traffic_shared")
    return {(u, v) for u, v in rows}


def traffic_approaches(conn, now, min_traffic=MIN_TRAFFIC):
    """Подходы к перекрёсткам по пробкам: [{lat, lon, bearing, traffic, turns}],
    поток по убыванию, по одному на подход."""
    weights = edge_weights(conn, now)
    shared = shared_edges(conn, now)
    nodes = {node: (lat, lon) for node, lat, lon in conn.execute("SELECT id, lat, lon FROM traffic_nodes")}
    topology = set(weights)
    if "traffic_edges" in _tables(conn):
        topology.update((u, v) for u, v in conn.execute("SELECT u, v FROM traffic_edges"))
    succ, pred = defaultdict(set), defaultdict(set)
    for u, v in topology:
        succ[u].add(v)
        pred[v].add(u)

    found = []
    for (u, v), weight in weights.items():
        if weight < min_traffic:
            continue
        if shared is not None and (u, v) not in shared:
            continue
        if u not in nodes or v not in nodes:
            continue
        floor = max(min_traffic, TURN_SHARE * weight)
        turns = sum(1 for w in succ[v] if w != u and weights.get((v, w), 0.0) >= floor)
        if turns < MIN_TURNS:
            continue
        # Назад по единственной цепочке до ~30 м: курс въезда, а не огрызка.
        start, after, seen = u, v, {u, v}
        travelled = blo.meters_between(*nodes[u], *nodes[v])
        while travelled < BEARING_BACK_METERS:
            back = [t for t in pred[start] if t != after and t in nodes and t not in seen]
            if len(back) != 1:
                break
            after, start = start, back[0]
            seen.add(start)
            travelled += blo.meters_between(*nodes[start], *nodes[after])
        if travelled < 1.0:
            continue
        lat, lon = nodes[v]
        bearing = int(round(blo.bearing_between(*nodes[start], lat, lon))) % 360
        found.append({"lat": round(lat, 5), "lon": round(lon, 5), "bearing": bearing,
                      "traffic": weight, "turns": turns, "routes": 0, "osrm_lanes": False})
    found.sort(key=lambda a: (-a["traffic"], a["lat"], a["lon"], a["bearing"]))
    return _one_per_approach(found)


def _same(a, b, meters, degrees):
    return (blo.angle_apart(a["bearing"], b["bearing"]) <= degrees
            and blo.meters_between(a["lat"], a["lon"], b["lat"], b["lon"]) <= meters)


def _one_per_approach(ranked):
    kept = []
    for item in ranked:
        if not any(_same(item, k, SAME_APPROACH_METERS, SAME_APPROACH_DEGREES) for k in kept):
            kept.append(item)
    return kept


def _route_documents(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    try:
        doc = json.loads(text)
    except ValueError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    return doc if isinstance(doc, list) else [doc]


def route_maneuvers(paths):
    """Повороты маршрутов OSRM: [{lat, lon, bearing, routes, osrm_lanes}].
    Один и тот же поворот в разных маршрутах — один пункт с их числом."""
    merged = []
    for path in paths:
        for doc in _route_documents(path):
            for route in (doc.get("routes") or []) if isinstance(doc, dict) else []:
                for leg in route.get("legs") or []:
                    for step in leg.get("steps") or []:
                        maneuver = step.get("maneuver") or {}
                        if maneuver.get("type") in SKIP_TYPES \
                                or maneuver.get("modifier") not in TURN_MODIFIERS:
                            continue
                        location = maneuver.get("location") or []
                        before = maneuver.get("bearing_before")
                        if len(location) < 2 or not isinstance(before, (int, float)):
                            continue
                        intersections = step.get("intersections") or []
                        lanes = bool(intersections and intersections[0].get("lanes"))
                        item = {"lat": round(float(location[1]), 5), "lon": round(float(location[0]), 5),
                                "bearing": int(round(before)) % 360, "traffic": 0.0, "turns": 0,
                                "routes": 1, "osrm_lanes": lanes}
                        twin = next((m for m in merged if _same(item, m, blo.DUPLICATE_METERS,
                                                                SAME_APPROACH_DEGREES)), None)
                        if twin is None:
                            merged.append(item)
                        else:
                            twin["routes"] += 1
                            twin["osrm_lanes"] = twin["osrm_lanes"] or lanes
    return merged


def merge(approaches, maneuvers):
    """Повороты маршрутов садятся на подходы пробок (25 м, 20°); остальные — свои пункты."""
    out = [dict(a) for a in approaches]
    for maneuver in maneuvers:
        twin = next((a for a in out if _same(maneuver, a, PHONE_MATCH_METERS, SAME_APPROACH_DEGREES)), None)
        if twin is None:
            out.append(dict(maneuver))
        else:
            twin["routes"] += maneuver["routes"]
            twin["osrm_lanes"] = twin["osrm_lanes"] or maneuver["osrm_lanes"]
    out.sort(key=lambda a: (-a["traffic"], -a["routes"], a["lat"], a["lon"], a["bearing"]))
    return out


def covered(item, records):
    """Правило телефона: запись в 25 м и курс подхода в пределах её допуска."""
    return any(blo.angle_apart(item["bearing"], r["bearing"]) <= r["tolerance"]
               and blo.meters_between(item["lat"], item["lon"], r["lat"], r["lon"]) <= PHONE_MATCH_METERS
               for r in records)


def load_overlay(paths):
    """Записи текущего слоя. Битая строка здесь не повод останавливаться —
    для очереди она просто не покрывает свой подход (и попадёт в очередь)."""
    records, broken = [], 0
    # Дата проверки здесь не важна: покрытие — это место и курс.
    any_day = datetime.date.max - datetime.timedelta(days=2)
    for path in paths:
        for _where, raw in blo.read_input(path):
            try:
                records.append(blo.validate_row(raw, any_day))
            except blo.Rejected:
                broken += 1
    if broken:
        _warn("в слое %d битых строк — их подходы считаются непокрытыми" % broken)
    return records


def queue(approaches, overlay=(), osm=None, top=DEFAULT_TOP):
    """Очередь: без полос у OSRM, без записи слоя, (с --osm) без turn:lanes в OSM.
    Возвращает (пункты, счёт исключённых по причинам)."""
    excluded = {"osrm": 0, "overlay": 0, "osm": 0}
    out = []
    for item in approaches:
        if item["osrm_lanes"]:
            excluded["osrm"] += 1
        elif covered(item, overlay):
            excluded["overlay"] += 1
        elif osm is not None and covered(item, osm):
            excluded["osm"] += 1
        else:
            out.append(item)
    return out[:top], excluded


def approach_id(item):
    """Устойчивый id подхода: те же узел и курс — тот же id в любом прогоне."""
    key = "%.5f,%.5f,%d" % (item["lat"], item["lon"], item["bearing"])
    return "gap-" + hashlib.sha1(key.encode()).hexdigest()[:8]


def rows_for_output(items, osm_checked):
    rows = []
    for item in items:
        rows.append({
            "id": approach_id(item), "lat": "%.5f" % item["lat"], "lon": "%.5f" % item["lon"],
            "bearing": item["bearing"], "tolerance": blo.DEFAULT_TOLERANCE,
            "lanes": "", "src": "", "checked": "",
            "traffic": int(round(item["traffic"])), "routes": item["routes"], "turns": item["turns"],
            "osm_turn_lanes": "нет" if osm_checked else "?",
            "edit_url": "https://www.openstreetmap.org/edit?editor=id#map=19/%.5f/%.5f"
                        % (item["lat"], item["lon"])})
    return rows


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def write_geojson(path, rows):
    features = [{"type": "Feature", "properties": dict(row, rank=rank),
                 "geometry": {"type": "Point", "coordinates": [float(row["lon"]), float(row["lat"])]}}
                for rank, row in enumerate(rows, start=1)]
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"type": "FeatureCollection", "features": features}, handle, ensure_ascii=False)


def main(argv=None, out=sys.stdout):
    parser = argparse.ArgumentParser(description="очередь разметки полос: где данные нужнее")
    parser.add_argument("--traffic-db", help="traffic.db (на VPS: /opt/radarmap/api/traffic.db)")
    parser.add_argument("--routes", nargs="+", default=[], help="ответы OSRM route (steps=true)")
    parser.add_argument("--overlay", nargs="+", default=[], help="текущий слой полос")
    parser.add_argument("--osm", metavar="GEOJSONL", help="экстракт roads.geojsonl (turn:lanes OSM)")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP)
    parser.add_argument("--min-traffic", type=float, default=MIN_TRAFFIC,
                        help="порог потока подхода, эффективных кусков (не ниже 2)")
    parser.add_argument("--csv", help="очередь в столбцах шаблона")
    parser.add_argument("--geojson", help="очередь точками для карты")
    parser.add_argument("--now", type=float, default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not args.traffic_db and not args.routes:
        parser.error("нужен --traffic-db или --routes")
    if args.min_traffic < 2:
        parser.error("--min-traffic ниже 2 — это уже следы отдельных людей")
    now = time.time() if args.now is None else args.now

    approaches = []
    if args.traffic_db:
        conn = open_readonly(args.traffic_db)
        try:
            approaches = traffic_approaches(conn, now, args.min_traffic)
        finally:
            conn.close()
    maneuvers = route_maneuvers(args.routes) if args.routes else []
    candidates = merge(approaches, maneuvers)
    overlay = load_overlay(args.overlay) if args.overlay else []
    osm = blo.osm_rows(args.osm, "2000-01-01")[0] if args.osm else None
    items, excluded = queue(candidates, overlay, osm, args.top)
    rows = rows_for_output(items, osm is not None)

    print("кандидатов: %d (по пробкам %d, поворотов маршрутов %d)"
          % (len(candidates), len(approaches), len(maneuvers)), file=out)
    print("уже есть полосы: у OSRM %d, в слое %d%s" % (
        excluded["osrm"], excluded["overlay"],
        ", в turn:lanes OSM %d — опубликуйте слой с --osm" % excluded["osm"] if osm is not None else ""),
        file=out)
    print("в очереди: %d" % len(rows), file=out)
    for rank, row in enumerate(rows[:20], start=1):
        print("%4d  %s  %s,%s  курс %3d  поток %5d  маршрутов %d  сторон %d" % (
            rank, row["id"], row["lat"], row["lon"], row["bearing"], row["traffic"],
            row["routes"], row["turns"]), file=out)
    if args.csv:
        write_csv(args.csv, rows)
        print("CSV: %s" % args.csv, file=out)
    if args.geojson:
        write_geojson(args.geojson, rows)
        print("GeoJSON: %s" % args.geojson, file=out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as error:
        print("ошибка: %s" % error, file=sys.stderr)
        sys.exit(1)
