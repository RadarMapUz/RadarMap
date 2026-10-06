"""Маршрут для симуляции: цепочка кусков одной ленты с шириной и полосами.

    python3 tools/drive_sim/make_route.py roads.geojsonl "Bunyodkor shoh ko'chasi" 69.2052 41.2742 route.json

Берёт ту же сеть, что сборка карты (build_roads.collect + generalise + полосы),
находит ближайший к точке старта односторонний кусок улицы и идёт по ходу,
пока продолжение той же улицы есть. Каждая точка: [lon, lat, ширина м, полос].
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server"))
import build_roads as br  # noqa: E402

MAX_POINTS = 4000


def main():
    source, name, lon, lat, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
    roads = br.generalise(br.collect(source)[0], br.SIMPLIFY_METERS / 111_320.0)
    roads, _ = br.heal_gap_names(roads)
    roads, _ = br.apply_lane_inference(roads)
    street = [r for r in roads if len(r) > 3 and r[3] == name and r[1] & br.FLAG_ONEWAY]
    if not street:
        sys.exit("улица не найдена")
    start = min(street, key=lambda r: min(br.meters_between((lon, lat), p) for p in r[2]))
    by_start = {}
    for road in street:
        by_start.setdefault((round(road[2][0][0], 6), round(road[2][0][1], 6)), []).append(road)
    path, seen, road = [], set(), start
    while road is not None and id(road) not in seen and len(path) < MAX_POINTS:
        seen.add(id(road))
        lanes = br.lanes_of(road[1])
        width = br.road_width_meters(road[0], lanes)
        for p in road[2][(1 if path else 0):]:
            path.append([round(p[0], 7), round(p[1], 7), round(width, 1), lanes])
        end = road[2][-1]
        options = by_start.get((round(end[0], 6), round(end[1], 6)), [])
        road = options[0] if options else None
    length = sum(br.meters_between(a[:2], b[:2]) for a, b in zip(path, path[1:]))
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"name": name, "points": path}, handle)
    print(f"точек {len(path)}, {length:.0f} м")


if __name__ == "__main__":
    main()
