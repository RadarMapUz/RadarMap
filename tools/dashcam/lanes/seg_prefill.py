"""Предзаполнение разметки ломаными из v2 (окна) и v1 (одиночные кадры).

    python3 seg_prefill.py        → ~/RadarMapBuild/dashcam/lanes/prefill/{w<окно>,d<id>}.json

Окно: analyze_window с отладкой → треки, принятые v2 (сплошная,
прерывистая, край), и бордюры окна. В каждом проанализированном кадре k
линия — прямая на земле X = x_k + s_k·(Z − 8) (x_k — положение трека в
кадре k, s_k — общая наклонка кадра), от ближайшего видимого Z до 22 м;
край — до 18 м (дальше полосы краёв не мерят). Тип: сплошная/прерывистая
как у трека, край → бордюр. Двойную v2 не различает — её ставит человек.
Для переноса разметки между кадрами окна сохраняются наклонка s и
накопленный общий сдвиг cum каждого кадра.

Одиночный кадр БД: lanes.analyze (v1) — линии и края по одному кадру.

Это подсказка, не истина: лишние линии человек удаляет одной клавишей.
"""
import json
import os
import sys
from multiprocessing import Pool

from framesdb import OUT
from lanes import Z_NEAR, Z_REF, analyze, load_camera, visible_z_range
from marking import load_rgb
from seg_common import PREFILL, SELECTION, straight_line
from track import track_x_at

KIND = {"solid": "solid", "dashed": "dashed", "edge": "curb"}
LINE_Z1 = 22.0
EDGE_Z1 = 18.0
DUP_EDGE = 0.5        # бордюр окна ближе к треку-краю — тот же, второй не рисуем

_cam = None
_static = {}


def line_z0(cam, x):
    vis = visible_z_range(cam, x)
    return max(Z_NEAR + 0.5, vis[0]) if vis else None


def frame_lines(cam, items, s):
    """[(x@Z_REF, класс, z1)] → ломаные кадра."""
    out = []
    for x, cls, z1 in items:
        z0 = line_z0(cam, x)
        if z0 is None or z0 >= z1 - 1.0:
            continue
        pts = straight_line(cam, x, s, z0, z1, Z_REF)
        if len(pts) >= 2:
            out.append({"cls": cls, "pts": pts})
    return out


def window_prefill(res, names, cam, stride=2):
    """Результат analyze_window(keep_debug=True) → {"frames": {имя: {...}}}."""
    data, cum, good, k_ref = res["_data"], res["_cum"], res["_good"], res["_k_ref"]
    lk, lx = res["left_edge"]
    rk, rx = res["right_edge"]
    frames = {}
    for k in range(len(data)):
        items = []
        edge_xs = []
        for l in good:
            t = l["track"]
            # Трек рисуем только в пределах его жизни (±2 кадра).
            if not (t["k"][0] - 2 <= k <= t["k"][-1] + 2):
                continue
            x = track_x_at(t, k, cum)
            cls = KIND.get(l["kind"])
            if cls is None:
                continue
            items.append((x, cls, EDGE_Z1 if cls == "curb" else LINE_Z1))
            if cls == "curb":
                edge_xs.append(x)
        off = cum[k] - cum[k_ref]
        for kind, x0 in ((lk, lx), (rk, rx)):
            if kind == "curb" and x0 is not None:
                x = x0 + off
                if all(abs(x - e) >= DUP_EDGE for e in edge_xs):
                    items.append((x, "curb", EDGE_Z1))
        s = data[k]["s"]
        frames[names[k * stride]] = {"lines": frame_lines(cam, items, s),
                                     "s": round(float(s), 4), "cum": round(float(cum[k]), 3)}
    return {"frames": frames, "lanes": res["lanes"], "own": res["own"], "share": res["share"]}


def single_prefill(path, cam):
    res = analyze(load_rgb(path), cam)
    s = res["slope"]
    items = [(c, KIND[k], EDGE_Z1 if k == "edge" else LINE_Z1)
             for c, k, _, _ in res["lines"] if k in KIND]
    side = res["side"]
    edges = [c for c, k, _ in items if k == "curb"]
    for key, strip in (("left_edge", "left_strip"), ("right_edge", "right_strip")):
        x = side.get(key)
        if x is not None and side.get(strip) in ("бордюр", "газон", "ограждение") \
                and all(abs(x - e) >= DUP_EDGE for e in edges):
            items.append((x, "curb", EDGE_Z1))
    return {"lines": frame_lines(cam, items, s), "s": round(float(s), 4)}


def _init():
    global _cam
    _cam = load_camera()


def _window(job):
    import reflect
    from window import analyze_window, load_window
    fid, trip, t = job
    if trip not in _static:
        _static[trip] = reflect.load(trip)
    try:
        res = analyze_window(fid, trip, t, _cam, _static[trip], keep_debug=True)
        _, names, _, _ = load_window(fid)
        out = window_prefill(res, names, _cam)
    except Exception as e:  # одно окно не роняет прогон
        return f"w{fid}", {"error": repr(e)}
    return f"w{fid}", out


def _single(job):
    fid, path = job
    try:
        return f"d{fid}", single_prefill(path, _cam)
    except Exception as e:
        return f"d{fid}", {"error": repr(e)}


def write(key, obj):
    os.makedirs(PREFILL, exist_ok=True)
    with open(os.path.join(PREFILL, key + ".json"), "w") as f:
        json.dump(obj, f, ensure_ascii=False)


def main():
    from truth import load
    with open(SELECTION) as f:
        sel = json.load(f)
    truth = {r["id"]: r for r in load()}
    force = "--force" in sys.argv
    wins = sorted({it["win"] for it in sel if it["src"] == "window"})
    # Окна настройки целиком: из них же псевдоразметка (seg_pseudo.py).
    wins = sorted(set(wins) | {r["id"] for r in truth.values() if r["half"] == "tune"})
    wjobs = [(w, truth[w]["trip"], truth[w]["t"]) for w in wins
             if force or not os.path.exists(os.path.join(PREFILL, f"w{w}.json"))]
    djobs = [(it["frame_id"], it["path"]) for it in sel if it["src"] == "db"
             and (force or not os.path.exists(os.path.join(PREFILL, f"d{it['frame_id']}.json")))]
    print(f"окон: {len(wjobs)}, одиночных кадров: {len(djobs)}", flush=True)
    errs = 0
    with Pool(6, initializer=_init) as pool:
        for key, obj in pool.imap_unordered(_window, wjobs):
            write(key, obj)
            errs += "error" in obj
        for key, obj in pool.imap_unordered(_single, djobs, chunksize=4):
            write(key, obj)
            errs += "error" in obj
    print(f"готово, ошибок: {errs} → {PREFILL}")


if __name__ == "__main__":
    main()
