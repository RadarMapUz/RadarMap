#!/usr/bin/env python3
"""Замер OSRM для пробок в маршрутизаторе (32D, 27.10.2026): время ответа
`route` на парах аудита и проверка «маршрут объезжает пробку».

    # время ответа: тот же запрос, что шлёт приложение (alternatives=3,
    # steps, overview=full, подъезд со стороны цели); несколько серверов
    # по очереди на одних парах — сравнение CH и MLD в одинаковых условиях
    python3 route_bench.py time --base http://127.0.0.1:8092 --base http://127.0.0.1:8094 --rounds 3

    # искусственная пробка: середина маршрута пары → файл скоростей
    python3 route_bench.py jam --base http://127.0.0.1:8094 --pair chil-yunus --out jam.csv [--mode weight]
    # … osrm-customize с этим файлом (traffic_customize.sh --speeds jam.csv) …
    python3 route_bench.py check --base http://127.0.0.1:8094 --pair chil-yunus --jam jam.csv

    # штраф манёвра (33B): левый поворот первого варианта → --turn-penalty-file
    python3 route_bench.py turn --base http://127.0.0.1:8094 --pair chil-yunus --out turns.csv --penalty 90
    # … traffic_customize.sh --speeds пустой --turns turns.csv …
    python3 route_bench.py check --base http://127.0.0.1:8094 --pair chil-yunus --turns turns.csv

Только чтение: ничего не пишет на сервер. stdlib, как весь server/.
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PAIRS = os.path.join(HERE, "audit_pairs.json")
JAM_KMH = 5          # скорость искусственной пробки — пол traffic_speeds.SPEED_FLOOR_KMH


def load_pairs(path=PAIRS):
    with open(path) as f:
        return json.load(f)["pairs"]


def coords(pair):
    (alat, alon), (blat, blon) = pair["from"], pair["to"]
    return f"{alon:.6f},{alat:.6f};{blon:.6f},{blat:.6f}"


def app_url(base, pair):
    """Запрос приложения (OSRMQuery.items без курса): три альтернативы,
    шаги, полная геометрия, подъезд к цели со своей стороны."""
    return (f"{base.rstrip('/')}/route/v1/driving/{coords(pair)}?overview=full&geometries=geojson"
            "&alternatives=3&steps=true&approaches=unrestricted;curb")


def fetch(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read())


def percentile(values, q):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def cmd_time(args):
    pairs = load_pairs(args.pairs)
    results = {base: [] for base in args.base}
    variants = {base: [] for base in args.base}
    for _ in range(args.rounds):
        for pair in pairs:
            # Серверы по очереди на одной паре: фон машины (cron, соседи) в
            # одну и ту же секунду бьёт по обоим одинаково.
            for base in args.base:
                start = time.perf_counter()
                body = fetch(app_url(base, pair))
                results[base].append((time.perf_counter() - start) * 1000)
                variants[base].append(len(body.get("routes") or []))
    for base in args.base:
        ms = results[base]
        print(f"{base}: {len(ms)} запросов, медиана {statistics.median(ms):.0f} мс, "
              f"p90 {percentile(ms, 0.9):.0f} мс, макс {max(ms):.0f} мс, "
              f"вариантов в среднем {statistics.mean(variants[base]):.2f}")


def route_edges(route):
    """[(u, v, длина м, время с)] — рёбра OSM маршрута по аннотации."""
    out = []
    for leg in route["legs"]:
        ann = leg["annotation"]
        nodes = ann["nodes"]
        for i, (dist, dur) in enumerate(zip(ann["distance"], ann["duration"])):
            out.append((nodes[i], nodes[i + 1], dist, dur))
    return out


def pair_by_id(path, pair_id):
    for pair in load_pairs(path):
        if pair["id"] == pair_id:
            return pair
    raise SystemExit(f"нет пары {pair_id}")


def cmd_jam(args):
    pair = pair_by_id(args.pairs, args.pair)
    url = (f"{args.base.rstrip('/')}/route/v1/driving/{coords(pair)}?overview=false"
           "&annotations=nodes,distance,duration")
    route = fetch(url)["routes"][0]
    edges = route_edges(route)
    total = sum(e[2] for e in edges)
    along, lines, jammed = 0.0, [], 0.0
    for u, v, dist, dur in edges:
        if args.start * total <= along <= args.end * total and dur > 0 and dist > 0:
            model = dist / dur * 3.6
            if args.mode == "weight":
                lines.append(f"{u},{v},{model:.1f},{JAM_KMH / 3.6:.3f}")
            else:
                lines.append(f"{u},{v},{JAM_KMH}")
            jammed += dist
        along += dist
    with open(args.out, "w", encoding="ascii") as f:
        f.write("".join(line + "\n" for line in lines))
    print(f"{pair['name']}: маршрут {route['distance'] / 1000:.1f} км, {route['duration'] / 60:.1f} мин; "
          f"пробка {len(lines)} рёбер, {jammed / 1000:.1f} км по {JAM_KMH} км/ч → {args.out}")


def route_nodes(route):
    """Узлы OSM маршрута подряд (стыки участков — без повтора)."""
    out = []
    for leg in route["legs"]:
        for node in leg["annotation"]["nodes"]:
            if not out or out[-1] != node:
                out.append(node)
    return out


def cmd_turn(args):
    """Левый поворот первого варианта → строка --turn-penalty-file."""
    pair = pair_by_id(args.pairs, args.pair)
    url = (f"{args.base.rstrip('/')}/route/v1/driving/{coords(pair)}?overview=full&geometries=geojson"
           "&steps=true&annotations=nodes")
    route = fetch(url)["routes"][0]
    geom = route["geometry"]["coordinates"]
    nodes = route["legs"][0]["annotation"]["nodes"]
    lefts = [s["maneuver"] for s in route["legs"][0]["steps"]
             if s["maneuver"]["type"] in ("turn", "end of road") and s["maneuver"].get("modifier") in ("left", "sharp left")]
    if len(lefts) <= args.index:
        raise SystemExit("нет такого левого поворота")
    loc = lefts[args.index]["location"]
    # Геометрия overview=full: точка j ≥ 1 — узел nodes[j] (j = 0 — старт).
    j = min(range(1, len(geom) - 1), key=lambda i: (geom[i][0] - loc[0]) ** 2 + (geom[i][1] - loc[1]) ** 2)
    triple = (nodes[j - 1], nodes[j], nodes[j + 1])
    with open(args.out, "w", encoding="ascii") as f:
        f.write(f"{triple[0]},{triple[1]},{triple[2]},{args.penalty}\n")
    print(f"{pair['name']}: левый поворот у {loc} — тройка {triple}, штраф {args.penalty} с → {args.out}; "
          f"маршрут {route['distance'] / 1000:.2f} км, {route['duration'] / 60:.1f} мин")


def cmd_check(args):
    pair = pair_by_id(args.pairs, args.pair)
    jam, turns = set(), set()
    if args.jam:
        with open(args.jam, encoding="ascii") as f:
            jam = {tuple(int(x) for x in line.split(",")[:2]) for line in f if line.strip()}
    if args.turns:
        with open(args.turns, encoding="ascii") as f:
            turns = {tuple(int(x) for x in line.split(",")[:3]) for line in f if line.strip()}
    url = (f"{args.base.rstrip('/')}/route/v1/driving/{coords(pair)}?overview=false&alternatives=3"
           "&annotations=nodes,distance,duration")
    clean = True
    for k, route in enumerate(fetch(url)["routes"]):
        hit = sum((u, v) in jam for u, v, _, _ in route_edges(route))
        nodes = route_nodes(route)
        crossed = sum(tuple(nodes[i:i + 3]) in turns for i in range(len(nodes) - 2))
        clean &= k > 0 or (hit == 0 and crossed == 0)
        print(f"вариант {k}: {route['distance'] / 1000:.2f} км, {route['duration'] / 60:.1f} мин, "
              f"вес {route['weight']:.0f}, рёбер пробки {hit} из {len(jam)}, манёвров со штрафом {crossed} из {len(turns)}")
    print("объезд: да" if clean else "объезд: НЕТ — первый вариант идёт через пробку или манёвр")
    return 0 if clean else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("time")
    t.add_argument("--base", action="append", required=True)
    t.add_argument("--pairs", default=PAIRS)
    t.add_argument("--rounds", type=int, default=3)
    j = sub.add_parser("jam")
    j.add_argument("--base", required=True)
    j.add_argument("--pair", required=True)
    j.add_argument("--pairs", default=PAIRS)
    j.add_argument("--out", required=True)
    j.add_argument("--start", type=float, default=0.35, help="доля маршрута, где начинается пробка")
    j.add_argument("--end", type=float, default=0.65)
    j.add_argument("--mode", choices=("weight", "duration"), default="weight")
    c = sub.add_parser("check")
    c.add_argument("--base", required=True)
    c.add_argument("--pair", required=True)
    c.add_argument("--pairs", default=PAIRS)
    c.add_argument("--jam")
    c.add_argument("--turns", help="файл --turn-penalty-file: тройки, которых первый вариант должен избегать")
    u = sub.add_parser("turn")
    u.add_argument("--base", required=True)
    u.add_argument("--pair", required=True)
    u.add_argument("--pairs", default=PAIRS)
    u.add_argument("--out", required=True)
    u.add_argument("--penalty", type=int, default=90)
    u.add_argument("--index", type=int, default=0, help="какой по счёту левый поворот (с 0)")
    args = ap.parse_args(argv)
    return {"time": cmd_time, "jam": cmd_jam, "check": cmd_check, "turn": cmd_turn}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
