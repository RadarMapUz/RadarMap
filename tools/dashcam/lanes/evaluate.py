"""Прогон v2 по кадрам истины и счёт точности.

    python3 evaluate.py [tune|test|all] [--cached]

Для каждого кадра истины — окно полного fps вокруг него (window.py),
ответ окна сравнивается с разметкой глазами. Считаем отдельно для
половины настройки и проверки (пороги крутятся только на настройке):

- доля ответа — среди кадров, которые человек судит (judge), и среди всех;
- точность числа полос и своей полосы — среди отвеченных судимых;
- края: бордюр/газон/ограждение — «граница», парковка — «машины»; сверяем
  только там, где разметка края есть.
Результаты окон — ~/RadarMapBuild/dashcam/lanes/eval_<half>.json.
"""
import json
import os
import sys
from multiprocessing import Pool

from framesdb import OUT
from lanes import load_camera
import reflect
from truth import load
from window import analyze_window

_cam = None
_static = {}


def _init():
    global _cam
    _cam = load_camera()


def _one(r):
    if r["trip"] not in _static:
        _static[r["trip"]] = reflect.load(r["trip"])
    try:
        res = analyze_window(r["id"], r["trip"], r["t"], _cam, _static[r["trip"]])
    except Exception as e:  # одно битое окно не роняет прогон
        import traceback
        return {"id": r["id"], "error": repr(e), "tb": traceback.format_exc()}
    return res


PHYS = ("бордюр", "газон", "ограждение")


def edge_truth(v):
    if v in PHYS:
        return "curb"
    if v == "парковка":
        return "cars"
    return None


def score(rows, res):
    by = {r["id"]: r for r in res}
    judged = [r for r in rows if r["judge"]]
    ans = [r for r in judged if by[r["id"]].get("lanes") is not None]
    ok = [r for r in ans if by[r["id"]]["lanes"] == r["lanes"]]
    own_ok = [r for r in ans if by[r["id"]]["own"] == r["own"]]
    both = [r for r in ans if by[r["id"]]["lanes"] == r["lanes"] and by[r["id"]]["own"] == r["own"]]
    ans_all = [r for r in rows if by[r["id"]].get("lanes") is not None]
    out = {
        "кадров": len(rows), "судим": len(judged),
        "ответ_судимых": f"{len(ans)}/{len(judged)}",
        "ответ_всех": f"{len(ans_all)}/{len(rows)}",
        "полос_верно": f"{len(ok)}/{len(ans)}",
        "своя_верно": f"{len(own_ok)}/{len(ans)}",
        "обе_верно": f"{len(both)}/{len(ans)}",
        "ответ_где_не_судим": [r["n"] for r in rows if not r["judge"] and by[r["id"]].get("lanes")],
    }
    for side, key in (("справа", "right_edge"), ("слева", "left_edge")):
        tv = side == "справа" and "right" or "left"
        pairs = [(edge_truth(r[tv]), by[r["id"]].get(key, [None])[0]) for r in judged]
        pairs = [(t, p) for t, p in pairs if t is not None]
        said = [(t, p) for t, p in pairs if p in ("curb", "cars")]
        out[f"край_{side}"] = (f"{sum(t == p for t, p in said)}/{len(said)} верно, "
                              f"сказано {len(said)}/{len(pairs)}")
        curb = [(t, p) for t, p in pairs if p == "curb"]
        out[f"бордюр_{side}_точн"] = f"{sum(t == 'curb' for t, _ in curb)}/{len(curb)}"
    return out


def main():
    half = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "tune"
    rows = [r for r in load() if half == "all" or r["half"] == half]
    path = os.path.join(OUT, f"eval_{half}.json")
    if "--cached" in sys.argv and os.path.exists(path):
        with open(path) as f:
            res = json.load(f)
    else:
        with Pool(6, initializer=_init) as pool:
            res = pool.map(_one, rows, chunksize=1)
        with open(path, "w") as f:
            json.dump(res, f, ensure_ascii=False, indent=1, default=str)
    errs = [r for r in res if "error" in r]
    for e in errs[:3]:
        print(e["id"], e["tb"])
    by = {r["id"]: r for r in res}
    for r in rows:
        p = by[r["id"]]
        if "error" in p:
            continue
        mark = "" if not r["judge"] else ("✓" if p["lanes"] == r["lanes"] else ("·" if p["lanes"] is None else "✗"))
        print(f"#{r['n']:2d} {mark:1s} истина {r['lanes'] if r['judge'] else '—'}/{r['own'] if r['judge'] else '—'}"
              f"  ответ {p['lanes']}/{p['own']} ({p['share']})  края {p['left_edge'][0]}/{p['right_edge'][0]}"
              f"  истина краёв {r['left']}/{r['right']}  {r['note']}")
    for k, v in score(rows, [r for r in res if "error" not in r] +
                      [{"id": e["id"]} for e in errs]).items():
        print(f"{k}: {v}")


if __name__ == "__main__":
    main()
