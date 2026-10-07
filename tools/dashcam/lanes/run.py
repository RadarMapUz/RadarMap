"""Разбор полос по всем кадрам поездки → lanes/frames.jsonl.

    python3 run.py [trip_key]

Берём только кадры на ходу (kmh > MIN_KMH); закрытость своей полосы
пишется для каждого кадра, отбрасывание — при агрегировании (OCC_MAX).
"""
import json
import os
import sys
import time
from multiprocessing import Pool

from framesdb import MORNING, OUT, frames
from lanes import analyze, load_camera
from logic import carriageway_width, lane_layout, median_kind, track_filter
from marking import load_rgb

MIN_KMH = 15.0
_cam = None


def _init():
    global _cam
    _cam = load_camera()


def _one(row):
    fid, t, kmh, lat, lon, course, path = row
    try:
        res = analyze(load_rgb(path), _cam)
    except Exception as e:  # битый JPEG не должен ронять весь проход
        return {"id": fid, "error": repr(e)}
    lay = res["layout"]
    return {
        "id": fid, "t": t, "kmh": kmh, "lat": lat, "lon": lon, "course": course,
        "path": path,
        "occluded": round(res["occluded"], 3),
        "slope": round(res["slope"], 4),
        "lines": [[round(c, 2), k, float(f), bool(y)] for c, k, f, y in res["lines"]],
        "dashes": res["dashes"],
        "side": {k: (round(v, 2) if isinstance(v, float) else v)
                 for k, v in res["side"].items()},
        "layout": None if lay is None else {
            k: (round(v, 2) if isinstance(v, float) else v) for k, v in lay.items()},
    }


def main():
    trip = sys.argv[1] if len(sys.argv) > 1 else MORNING
    rows = [r for r in frames(trip) if r[2] is not None and r[2] > MIN_KMH
            and r[3] is not None]
    t0 = time.time()
    with Pool(8, initializer=_init) as pool:
        out = pool.map(_one, rows, chunksize=8)
    # Второй проход: линия должна держаться в соседних кадрах; раскладку
    # и ширину пересчитываем уже по устойчивым линиям.
    good = [o for o in out if "error" not in o]
    kept = track_filter(good)
    for o, ls in zip(good, kept):
        o["layout_raw"] = o["layout"]
        o["lines_raw"] = o["lines"]
        o["lines"] = ls
        side = o["side"]
        lay = lane_layout([(c, k, f) for c, k, f, _ in ls],
                          (side["left_edge"], side["right_edge"]))
        o["layout"] = None if lay is None else {
            k: (round(v, 2) if isinstance(v, float) else v) for k, v in lay.items()}
        # Край дальше одного ряда от последней линии — ненадёжен (плитка
        # тротуара похожа на асфальт), в ширину его не берём.
        if lay is not None:
            if not lay["left_edge_ok"]:
                side["left_edge"] = None
            if not lay["right_edge_ok"]:
                side["right_edge"] = None
        phys = side["left_strip"] in ("газон", "бордюр", "ограждение") and \
            side["left_edge"] is not None
        axis = lay["left_line"] if lay and lay["left_kind"] == "solid" else None
        w = carriageway_width(side["left_edge"] if phys else None, side["right_edge"], axis)
        side["width"] = None if w is None else round(w, 2)
        side["median"] = median_kind(lay["left_kind"] if lay else None, False,
                                     side["left_strip"])
    path = os.path.join(OUT, f"frames_{trip}.jsonl")
    with open(path, "w") as f:
        for o in out:
            f.write(json.dumps(o, ensure_ascii=False) + "\n")
    errs = sum(1 for o in out if "error" in o)
    lay = sum(1 for o in out if o.get("layout"))
    print(f"кадров на ходу: {len(rows)}, с раскладкой полос: {lay}, ошибок: {errs}, "
          f"{time.time() - t0:.0f} с → {path}")


if __name__ == "__main__":
    main()
