"""Список работ по перекрёсткам: где в OSM не хватает данных для карты «как у Яндекса».

    python3 server/junction_worklist.py roads.geojsonl points.geojsonl --html worklist.html

Зачем. Бесплатный и законный путь к реальной разметке — дорисовать её в OSM
(редактор iD/RapiD, снимки Bing/Esri, разрешённые для правок OSM): наша сборка
каждую неделю сама подтягивает `lanes`, `turn:lanes`, переходы и островки.
Но перекрёстков тысячи, и начинать надо с тех, где ездят больше всего и где
данных меньше всего. Этот скрипт ставит их в очередь и даёт ссылку «открыть в
редакторе» на каждый.

Перекрёсток — скопление светофоров (в OSM их ставят на каждый подход). Его
вес — классы примыкающих магистралей; недостача — подходы без `lanes`, ни
одного `turn:lanes`, меньше двух переходов. Только stdlib, вход — те же
экстракты, что у build_roads.
"""
import argparse
import html
import json
import math
from collections import defaultdict

CLUSTER_METERS = 45.0
REACH_METERS = 45.0
CROSSING_METERS = 55.0
SAME_JUNCTION_METERS = 130.0
CLASS_WEIGHT = {"trunk": 5, "primary": 4, "secondary": 3, "tertiary": 2,
                "trunk_link": 1, "primary_link": 1, "secondary_link": 1, "tertiary_link": 1}
_CELL = 0.001


def _metres(a, b):
    kx = 111_320 * math.cos(math.radians((a[1] + b[1]) / 2))
    return math.hypot((a[0] - b[0]) * kx, (a[1] - b[1]) * 111_320)


def _to_line(point, points):
    """Метров от точки до ломаной."""
    kx = 111_320 * math.cos(math.radians(point[1]))
    best = float("inf")
    for a, b in zip(points, points[1:] or points):
        ax, ay = (a[0] - point[0]) * kx, (a[1] - point[1]) * 111_320
        bx, by = (b[0] - point[0]) * kx, (b[1] - point[1]) * 111_320
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
        best = min(best, math.hypot(ax + t * dx, ay + t * dy))
    return best


def _features(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if line:
                yield json.loads(line)


def cluster_signals(signals, reach=CLUSTER_METERS):
    """Светофоры одного перекрёстка → [(центр, число светофоров)]."""
    clusters = []          # [сумма lon, сумма lat, n]
    grid = defaultdict(list)
    for point in sorted(signals):
        cell = (int(point[0] / _CELL), int(point[1] / _CELL))
        best = None
        for gx in range(cell[0] - 1, cell[0] + 2):
            for gy in range(cell[1] - 1, cell[1] + 2):
                for index in grid.get((gx, gy), ()):
                    sx, sy, n = clusters[index]
                    if _metres(point, (sx / n, sy / n)) <= reach:
                        best = index
                        break
                if best is not None:
                    break
            if best is not None:
                break
        if best is None:
            clusters.append([point[0], point[1], 1])
            grid[cell].append(len(clusters) - 1)
        else:
            clusters[best][0] += point[0]
            clusters[best][1] += point[1]
            clusters[best][2] += 1
    return [((sx / n, sy / n), n) for sx, sy, n in clusters]


def assess(centre, ways, crossings):
    """Оценка перекрёстка: вес, недостачи, имена улиц.

    ways — [(класс, теги, точки)] магистралей рядом; crossings — точки/линии переходов.
    """
    near = [(cls, tags) for cls, tags, points in ways
            if cls in CLASS_WEIGHT and _to_line(centre, points) <= REACH_METERS]
    if not near:
        return None
    weight = sum(CLASS_WEIGHT[cls] for cls, _tags in near)
    no_lanes = sum(1 for _cls, tags in near if "lanes" not in tags)
    turn = any(any(k.startswith("turn:lanes") for k in tags) for _cls, tags in near)
    crossing_count = sum(1 for spot in crossings if _metres(spot, centre) <= CROSSING_METERS)
    missing = []
    if no_lanes:
        missing.append(f"нет lanes у {no_lanes} из {len(near)} кусков")
    if not turn:
        missing.append("нет turn:lanes")
    if crossing_count < 2:
        missing.append("переходов меньше двух")
    names = sorted({tags.get("name") for _cls, tags in near if tags.get("name")})
    score = weight * (1 + len(missing) + no_lanes / len(near))
    return {"score": round(score, 1), "weight": weight, "missing": missing, "names": names}


def worklist(roads_path, points_path, limit=150):
    signals, crossings = [], []
    for feature in _features(points_path):
        props = feature.get("properties") or {}
        coords = (feature.get("geometry") or {}).get("coordinates")
        if not coords:
            continue
        if props.get("highway") == "traffic_signals":
            signals.append(tuple(coords[:2]))
        elif props.get("highway") == "crossing":
            crossings.append(tuple(coords[:2]))
    ways = []
    for feature in _features(roads_path):
        props = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "LineString":
            continue
        points = [tuple(p[:2]) for p in geometry["coordinates"]]
        if props.get("footway") == "crossing":
            crossings.append(points[len(points) // 2])
        elif props.get("highway") in CLASS_WEIGHT:
            ways.append((props["highway"], props, points))
    by_cell = defaultdict(list)
    for way in ways:
        for p in way[2]:
            by_cell[(int(p[0] / 0.005), int(p[1] / 0.005))].append(way)
    crossing_cells = defaultdict(list)
    for spot in crossings:
        crossing_cells[(int(spot[0] / 0.005), int(spot[1] / 0.005))].append(spot)
    out = []
    for centre, count in cluster_signals(signals):
        cell = (int(centre[0] / 0.005), int(centre[1] / 0.005))
        local, seen = [], set()
        spots = []
        for gx in range(cell[0] - 1, cell[0] + 2):
            for gy in range(cell[1] - 1, cell[1] + 2):
                for way in by_cell.get((gx, gy), ()):
                    if id(way) not in seen:
                        seen.add(id(way))
                        local.append(way)
                spots.extend(crossing_cells.get((gx, gy), ()))
        result = assess(centre, local, spots)
        if result and result["missing"]:
            result["lat"], result["lon"], result["signals"] = round(centre[1], 6), round(centre[0], 6), count
            out.append(result)
    out.sort(key=lambda r: (-r["score"], r["lat"], r["lon"]))
    # Большой перекрёсток — несколько скоплений светофоров в сотне метров:
    # в списке он один, с наибольшим весом.
    kept = []
    for row in out:
        spot = (row["lon"], row["lat"])
        if any(_metres(spot, (k["lon"], k["lat"])) <= SAME_JUNCTION_METERS
               and set(row["names"]) & set(k["names"]) for k in kept):
            continue
        kept.append(row)
    return kept[:limit]


def to_html(rows):
    def link(row, base):
        return f'{base}#map=19/{row["lat"]}/{row["lon"]}'
    body = "".join(
        f"<tr><td>{i}</td><td>{html.escape(' × '.join(r['names'][:3]) or '—')}</td>"
        f"<td>{html.escape('; '.join(r['missing']))}</td><td>{r['score']}</td>"
        f'<td><a href="{link(r, "https://www.openstreetmap.org/edit?editor=id")}">iD</a> · '
        f'<a href="{link(r, "https://rapideditor.org/edit")}">RapiD</a></td></tr>'
        for i, r in enumerate(rows, 1))
    return ("<!doctype html><meta charset=utf-8><title>Перекрёстки: что дорисовать в OSM</title>"
            "<table border=1 cellpadding=4><tr><th>#</th><th>Улицы</th><th>Чего нет</th>"
            f"<th>Вес</th><th>Открыть</th></tr>{body}</table>")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("roads")
    parser.add_argument("points")
    parser.add_argument("--limit", type=int, default=150)
    parser.add_argument("--html")
    parser.add_argument("--json")
    args = parser.parse_args()
    rows = worklist(args.roads, args.points, args.limit)
    for i, row in enumerate(rows[:15], 1):
        print(f"{i:3} {row['score']:6} {' × '.join(row['names'][:3]) or '—':60} {'; '.join(row['missing'])}")
    print(f"всего в списке: {len(rows)}")
    if args.html:
        with open(args.html, "w", encoding="utf-8") as handle:
            handle.write(to_html(rows))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(rows, handle, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
