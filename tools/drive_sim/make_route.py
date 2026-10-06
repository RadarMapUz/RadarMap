"""Маршрут для симулятора: А → Б по нашему OSRM, посаженный на наши полосы.

    python3 tools/drive_sim/make_route.py roads.geojsonl points.geojsonl cameras.json \\
        69.2030,41.2700 69.2405,41.3110 route.json [OSRM]

Всё — наши данные: геометрия маршрута от нашего OSRM, полосы и ширина — из той
же сети, что в тайлах (build_roads: generalise + имена + угадывание полос),
стрелки — turn:lanes из OSM, светофоры — точки OSM, камеры — наша база.

Выход (route.json):
- points: [lon, lat, ширина своего направления м, полос, скорость км/ч] —
  ЦЕНТР своего направления: у двусторонней дороги ось сдвинута вправо на
  четверть ширины, ширина — половина;
- maneuvers: [{s, kind, modifier, name, turns, lanes}] — s в метрах от начала,
  turns — стрелки подхода (коды build_roads.TURN_*), lanes — номера полос,
  из которых манёвр разрешён (0 — левая);
- signals: [s] — светофоры на маршруте; cameras: [{s, type}].
"""
import json
import math
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server"))
import build_roads as br  # noqa: E402

OSRM = "https://soulmed.uz/radarmap/osrm"
STEP_METERS = 5.0
MATCH_METERS = 18.0
MATCH_DEGREES = 40.0
ARROW_BEFORE_METERS = 120.0
SIGNAL_METERS = 22.0
STOP_SEARCH_METERS = 45.0      # где искать переход перед светофором
STOP_GAP_METERS = 3.5          # стоп-линия до перехода
CAMERA_METERS = 35.0
SPEED_MAIN, SPEED_OTHER = 60, 40          # как пол лимитов города (extract_speed_limits)

ALLOWED = {
    "left": {br.TURN_LEFT, br.TURN_SLIGHT_LEFT, br.TURN_THROUGH_LEFT, br.TURN_LEFT_RIGHT},
    "sharp left": {br.TURN_LEFT, br.TURN_THROUGH_LEFT, br.TURN_LEFT_RIGHT},
    "slight left": {br.TURN_SLIGHT_LEFT, br.TURN_LEFT, br.TURN_THROUGH_LEFT, br.TURN_THROUGH},
    "right": {br.TURN_RIGHT, br.TURN_SLIGHT_RIGHT, br.TURN_THROUGH_RIGHT, br.TURN_LEFT_RIGHT},
    "sharp right": {br.TURN_RIGHT, br.TURN_THROUGH_RIGHT, br.TURN_LEFT_RIGHT},
    "slight right": {br.TURN_SLIGHT_RIGHT, br.TURN_RIGHT, br.TURN_THROUGH_RIGHT, br.TURN_THROUGH},
    "straight": {br.TURN_THROUGH, br.TURN_THROUGH_LEFT, br.TURN_THROUGH_RIGHT},
    "uturn": {br.TURN_UTURN, br.TURN_LEFT},
}


def xy(point, origin):
    kx = 111_320 * math.cos(math.radians(origin[1]))
    return ((point[0] - origin[0]) * kx, (point[1] - origin[1]) * 111_320)


def heading(a, b):
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1])) % 360


def angle(a, b):
    return abs((a - b + 180) % 360 - 180)


def densify(line, origin):
    pts = [xy(p, origin) for p in line]
    out = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        steps = max(1, int(length / STEP_METERS))
        out.extend((a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps)
                   for i in range(1, steps + 1))
    return out


class Segments:
    """Отрезки нашей сети в метрах, по клеткам 50 м."""

    def __init__(self, roads, origin):
        self.grid = {}
        for road in roads:
            if road[0] > 7 or road[1] & (br.FLAG_TUNNEL):
                continue
            lanes = br.lanes_of(road[1])
            width = br.road_width_meters(road[0], lanes)
            pts = [xy(p, origin) for p in road[2]]
            for a, b in zip(pts, pts[1:]):
                for cx in range(int(min(a[0], b[0]) // 50) - 1, int(max(a[0], b[0]) // 50) + 2):
                    for cy in range(int(min(a[1], b[1]) // 50) - 1, int(max(a[1], b[1]) // 50) + 2):
                        self.grid.setdefault((cx, cy), []).append((a, b, road, width, lanes))

    def match(self, p, course):
        best = None
        for a, b, road, width, lanes in self.grid.get((int(p[0] // 50), int(p[1] // 50)), ()):
            dx, dy = b[0] - a[0], b[1] - a[1]
            length = dx * dx + dy * dy
            if length == 0:
                continue
            t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length))
            fx, fy = a[0] + dx * t, a[1] + dy * t
            distance = math.hypot(p[0] - fx, p[1] - fy)
            seg = heading(a, b)
            oneway = road[1] & br.FLAG_ONEWAY
            off = angle(seg, course)
            if not oneway:
                off = min(off, 180 - off)
            if distance > MATCH_METERS or off > MATCH_DEGREES:
                continue
            score = distance + off * 0.2
            if best is None or score < best[0]:
                best = (score, (fx, fy), seg, road, width, lanes, oneway)
        return best


def cumulative(path):
    s = [0.0]
    for a, b in zip(path, path[1:]):
        s.append(s[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    return s


def project(p, path, svals, reach):
    best = None
    for i, (a, b) in enumerate(zip(path, path[1:])):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = dx * dx + dy * dy
        if length == 0:
            continue
        t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length))
        d = math.hypot(p[0] - a[0] - dx * t, p[1] - a[1] - dy * t)
        if d <= reach and (best is None or d < best[0]):
            best = (d, svals[i] + math.sqrt(length) * t, heading(a, b))
    return best


def allowed_lanes(turns, modifier, kind):
    if not turns:
        return []
    wanted = ALLOWED.get(modifier or "straight", ALLOWED["straight"])
    if kind in ("depart", "arrive", "new name", "continue") and not modifier:
        wanted = ALLOWED["straight"]
    return [i for i, code in enumerate(turns) if code in wanted]


def main():
    roads_path, points_path, cameras_path, start, end, out = sys.argv[1:7]
    osrm = sys.argv[7] if len(sys.argv) > 7 else OSRM
    url = (f"{osrm}/route/v1/driving/{start};{end}"
           "?overview=full&geometries=geojson&steps=true")
    with urllib.request.urlopen(url, timeout=30) as response:
        reply = json.load(response)
    if reply.get("code") != "Ok":
        sys.exit(f"OSRM: {reply.get('code')}")
    route = reply["routes"][0]
    line = route["geometry"]["coordinates"]
    origin = tuple(line[0])

    raw, *_rest = br.collect(roads_path)
    arrows_raw = _rest[6]
    roads = br.generalise(raw, br.SIMPLIFY_METERS / 111_320.0)
    roads, _ = br.heal_gap_names(roads)
    roads, _ = br.apply_lane_inference(roads)
    segments = Segments(roads, origin)

    path = densify(line, origin)
    centre, info = [], []
    for i, p in enumerate(path):
        a, b = path[max(0, i - 1)], path[min(len(path) - 1, i + 1)]
        course = heading(a, b)
        hit = segments.match(p, course)
        if hit is None:
            centre.append(p)
            info.append((3.5, 1, SPEED_OTHER))
            continue
        _score, foot, _seg, road, width, lanes, oneway = hit
        speed = SPEED_MAIN if road[0] <= 4 else SPEED_OTHER
        if oneway:
            centre.append(foot)
            info.append((width, lanes, speed))
        else:
            # Своя половина двусторонней дороги: центр правее оси на четверть.
            rad = math.radians(course)
            shift = width / 4
            centre.append((foot[0] + math.cos(rad) * shift, foot[1] - math.sin(rad) * shift))
            info.append((width / 2, max(1, lanes // 2), speed))
    svals = cumulative(centre)

    # Стрелки подхода: точка turn:lanes в OSM стоит у конца куска перед узлом.
    arrows = [(xy(spot, origin), turns) for spot, turns in arrows_raw]
    maneuvers = []
    for leg in route["legs"]:
        for step in leg["steps"]:
            m = step["maneuver"]
            at = project(xy(m["location"], origin), centre, svals, 40.0)
            if at is None:
                continue
            s = at[1]
            turns = []
            best = None
            for spot, codes in arrows:
                hit = project(spot, centre, svals, 12.0)
                if hit and s - ARROW_BEFORE_METERS <= hit[1] <= s + 5 and (best is None or hit[1] > best[0]):
                    best = (hit[1], codes)
            if best:
                turns = best[1]
            maneuvers.append({"s": round(s, 1), "kind": m["type"], "modifier": m.get("modifier"),
                              "name": step.get("name", ""), "turns": turns,
                              "lanes": allowed_lanes(turns, m.get("modifier"), m["type"])})

    signals, crossings = [], []
    with open(points_path, encoding="utf-8") as handle:
        for line_ in handle:
            line_ = line_.lstrip("\x1e").strip()
            if not line_:
                continue
            feature = json.loads(line_)
            kind = (feature.get("properties") or {}).get("highway")
            if kind not in ("traffic_signals", "crossing"):
                continue
            hit = project(xy(feature["geometry"]["coordinates"], origin), centre, svals,
                          SIGNAL_METERS if kind == "traffic_signals" else 12.0)
            if not hit:
                continue
            if kind == "crossing":
                crossings.append(hit[1])
            elif all(abs(hit[1] - s) > 25 for s in signals):
                signals.append(round(hit[1], 1))
    signals.sort()
    # Стоп-линия — перед переходом своего подхода, а не у точки светофора:
    # в OSM светофор часто стоит уже внутри перекрёстка (Чиланзар).
    stops = []
    for s in signals:
        before = [c for c in crossings if s - STOP_SEARCH_METERS <= c <= s + 5]
        stop = round((min(before) if before else s) - STOP_GAP_METERS, 1)
        if all(abs(stop - other["stop"]) > 10 for other in stops):    # один подход — одна линия
            stops.append({"s": s, "stop": stop})

    cameras = []
    with open(cameras_path, encoding="utf-8") as handle:
        data = json.load(handle)
    for camera in (data if isinstance(data, list) else data.get("cameras", [])):
        p = xy((camera["lon"], camera["lat"]), origin)
        if abs(p[0]) > 20000 or abs(p[1]) > 20000:
            continue
        hit = project(p, centre, svals, CAMERA_METERS)
        if hit:
            cameras.append({"s": round(hit[1], 1), "type": camera.get("type", "камера")})
    cameras.sort(key=lambda c: c["s"])

    kx = 111_320 * math.cos(math.radians(origin[1]))
    points = [[round(origin[0] + p[0] / kx, 7), round(origin[1] + p[1] / 111_320, 7),
               round(w, 1), n, v] for p, (w, n, v) in zip(centre, info)]
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"from": start, "to": end, "length": round(svals[-1]), "points": points,
                   "maneuvers": maneuvers, "signals": stops, "cameras": cameras}, handle,
                  ensure_ascii=False)
    print(f"{svals[-1]:.0f} м, точек {len(points)}, манёвров {len(maneuvers)} "
          f"(со стрелками {sum(1 for m in maneuvers if m['turns'])}), светофоров {len(signals)}, "
          f"камер {len(cameras)}")


if __name__ == "__main__":
    main()
