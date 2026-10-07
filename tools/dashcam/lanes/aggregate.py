"""Кадры → участки ~50 м (положение + курс) → полосы, ширина, обочина;
сверка с OSM (~/RadarMapBuild/roads.geojsonl) и с нашей моделью ширины
(server/build_roads.py: road_width_meters).

    python3 aggregate.py [trip_key]

Пишет lanes/segments_<trip>.json и печатает сводку.
"""
import json
import math
import os
import sys
from collections import Counter, defaultdict

from framesdb import MORNING, OUT
from lanes import OCC_MAX
from logic import model_width, robust_count, robust_value, seg_key

ROADS = os.path.expanduser("~/RadarMapBuild/roads.geojsonl")
MATCH_M = 20.0          # участок ↔ ребро OSM не дальше
MATCH_TURN = 30.0       # и направление совпадает в пределах


def load_ways(bbox):
    """Рёбра OSM в bbox: [(lat1, lon1, lat2, lon2, props)]."""
    s, w, n, e = bbox
    out = []
    with open(ROADS) as f:
        for line in f:
            line = line.strip("\x1e \n")   # GeoJSON Text Sequences: в начале строки RS
            if not line:
                continue
            o = json.loads(line)
            g = o.get("geometry") or {}
            if g.get("type") != "LineString":
                continue
            cs = g["coordinates"]
            if not any(s <= c[1] <= n and w <= c[0] <= e for c in cs):
                continue
            p = o.get("properties") or {}
            for a, b in zip(cs, cs[1:]):
                out.append((a[1], a[0], b[1], b[0], p))
    return out


def _xy(lat0, lat, lon, lon0):
    return ((lon - lon0) * 111_320.0 * math.cos(math.radians(lat0)),
            (lat - lat0) * 111_320.0)


def nearest_way(lat, lon, course, ways):
    """Ближайшее ребро с совместимым направлением → (props, dist, forward)."""
    best = None
    for la1, lo1, la2, lo2, p in ways:
        ax, ay = _xy(lat, la1, lo1, lon)
        bx, by = _xy(lat, la2, lo2, lon)
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        if L2 < 1e-6:
            continue
        t = max(0.0, min(1.0, -(ax * dx + ay * dy) / L2))
        d = math.hypot(ax + t * dx, ay + t * dy)
        if d > MATCH_M or (best and d >= best[1]):
            continue
        brg = math.degrees(math.atan2(dx, dy)) % 360
        diff = abs((brg - course + 180) % 360 - 180)
        oneway = p.get("oneway") in ("yes", "1", "true")
        if diff <= MATCH_TURN:
            best = (p, d, True)
        elif not oneway and diff >= 180 - MATCH_TURN:
            best = (p, d, False)
    return best


def osm_lanes_dir(p, forward):
    """Полос OSM в нашем направлении, или None, если тегов нет."""
    oneway = p.get("oneway") in ("yes", "1", "true")
    def num(k):
        try:
            return int(str(p.get(k)).split(";")[0])
        except (TypeError, ValueError):
            return None
    if oneway:
        return num("lanes")
    v = num("lanes:forward" if forward else "lanes:backward")
    if v:
        return v
    total = num("lanes")
    if total and total % 2 == 0:
        return total // 2
    return None


def main():
    trip = sys.argv[1] if len(sys.argv) > 1 else MORNING
    rows = [json.loads(l) for l in open(os.path.join(OUT, f"frames_{trip}.jsonl"))]
    rows = [r for r in rows if "error" not in r and r.get("lat")]
    segs = defaultdict(list)
    for r in rows:
        segs[seg_key(r["lat"], r["lon"], r["course"])].append(r)
    lats = [r["lat"] for r in rows]
    lons = [r["lon"] for r in rows]
    ways = load_ways((min(lats) - 0.002, min(lons) - 0.002, max(lats) + 0.002, max(lons) + 0.002))
    out = []
    for key, fr in segs.items():
        acc = [r for r in fr if r["occluded"] <= OCC_MAX]
        lanes, conf, nv = robust_count([r["layout"]["lanes"] for r in acc if r["layout"]],
                                       min_n=2, min_agree=0.6)
        width, spread, nw = robust_value([r["side"]["width"] for r in acc], min_n=2)
        med = Counter(r["side"]["median"] for r in acc if r["side"]["median"] not in (None, "нет"))
        sw = Counter(r["side"]["sidewalk"] for r in acc if r["side"]["sidewalk"] is not None)
        lat = sum(r["lat"] for r in fr) / len(fr)
        lon = sum(r["lon"] for r in fr) / len(fr)
        crs = fr[len(fr) // 2]["course"]
        m = nearest_way(lat, lon, crs, ways)
        rec = {"lat": round(lat, 6), "lon": round(lon, 6), "course": round(crs),
               "frames": len(fr), "accepted": len(acc), "lane_votes": nv,
               "lanes": lanes, "confidence": round(conf, 2),
               "width": None if width is None else round(width, 2), "width_n": nw,
               "median": med.most_common(1)[0][0] if med else None,
               "sidewalk": (sw.most_common(1)[0][0] if sw else None),
               "ids": [r["id"] for r in fr]}
        if m:
            p, d, fwd = m
            oneway = p.get("oneway") in ("yes", "1", "true")
            rec.update(osm_highway=p.get("highway"), osm_name=p.get("name"),
                       osm_oneway=oneway, osm_lanes=osm_lanes_dir(p, fwd),
                       osm_dist=round(d, 1))
            try:
                tag = int(str(p.get("lanes")).split(";")[0]) if p.get("lanes") else None
            except ValueError:
                tag = None
            rec["model_width"] = model_width(tag, p.get("highway"), oneway)
        out.append(rec)
    with open(os.path.join(OUT, f"segments_{trip}.json"), "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    est = [s for s in out if s["lanes"] is not None]
    matched = [s for s in est if "osm_highway" in s]
    with_tag = [s for s in matched if s["osm_lanes"]]
    agree = [s for s in with_tag if s["osm_lanes"] == s["lanes"]]
    off1 = [s for s in with_tag if abs(s["osm_lanes"] - s["lanes"]) == 1]
    no_tag = [s for s in matched if not s["osm_lanes"]]
    wid = [s for s in out if s["width"] is not None and s.get("model_width")]
    print(f"участков на маршруте: {len(out)}; с принятыми кадрами: "
          f"{sum(1 for s in out if s['accepted'])}; с оценкой полос: {len(est)}")
    print(f"  из них сопоставлено с OSM: {len(matched)}; у OSM есть полосы: {len(with_tag)} "
          f"(совпало {len(agree)}, ±1 — {len(off1)}, хуже — {len(with_tag) - len(agree) - len(off1)}); "
          f"у OSM полос нет: {len(no_tag)}")
    print("  наша оценка полос:", dict(Counter(s["lanes"] for s in est)))
    if wid:
        diffs = sorted(s["model_width"] - s["width"] for s in wid)
        med = diffs[len(diffs) // 2]
        print(f"ширина: участков с замером и моделью {len(wid)}; модель − замер: медиана "
              f"{med:+.1f} м, разброс {diffs[0]:+.1f}…{diffs[-1]:+.1f}; "
              f"|разница| ≤ 1,5 м у {sum(1 for d in diffs if abs(d) <= 1.5)}")
    print("разделительная:", dict(Counter(s["median"] for s in out if s["accepted"])))
    print("тротуар справа:", dict(Counter(s["sidewalk"] for s in out if s["accepted"])))
    return out


if __name__ == "__main__":
    main()
