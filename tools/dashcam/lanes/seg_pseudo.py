"""Псевдоразметка из уверенных окон v2 — только для проверки конвейера.

    python3 seg_pseudo.py       → ~/RadarMapBuild/dashcam/lanes/pseudo/<ключ>.json

Уверенное окно: половина НАСТРОЙКИ истины, человек его судит, ответ v2
(eval_tune.json) совпал с истиной по числу полос, и голос окна ≥ 60 %.
Все проанализированные кадры такого окна (каждый второй, ~50 на окно)
получают ломаные из предзаполнения (seg_prefill.py). Линии за бордюром
отбрасываются (v2 их иногда принимает — тротуар, фактура плитки).

Это НЕ истина: линии, которые v2 пропустил, в маске станут фоном, и
модель на этом учится их не видеть. Цель — убедиться, что труба
«разметка → маски → обучение → Core ML → v2 с маской модели» работает,
а не получить итоговую точность. Проверочная половина сюда не попадает
по построению (eval_tune.json — только настройка).
"""
import json
import os

import numpy as np

from framesdb import OUT
from lanes import load_camera
from seg_common import PREFILL, PSEUDO, jpg_to_ground, key_for, save_label

MIN_SHARE = 0.6


def confident(truth, results, min_share=MIN_SHARE):
    """Окна, где v2 совпал с истиной настройки и голос уверенный."""
    by = {r["id"]: r for r in truth}
    out = []
    for r in results:
        t = by.get(r.get("id"))
        if t is None or t["half"] != "tune" or not t["judge"] or "error" in r:
            continue
        if r.get("lanes") is not None and r["lanes"] == t["lanes"] and r.get("share", 0) >= min_share:
            out.append(r["id"])
    return out


def inside_curbs(cam, lines):
    """Линии разметки между крайними бордюрами (бордюры остаются)."""
    xs = []
    for ln in lines:
        X, Z = jpg_to_ground(cam, ln["pts"])
        ok = np.isfinite(X)
        xs.append(float(np.median(X[ok])) if ok.any() else None)
    curbs = [x for ln, x in zip(lines, xs) if ln["cls"] == "curb" and x is not None]
    lo = max([x for x in curbs if x < 0], default=-1e9)
    hi = min([x for x in curbs if x > 0], default=1e9)
    return [ln for ln, x in zip(lines, xs)
            if x is not None and (ln["cls"] == "curb" or lo < x < hi)]


def main():
    from truth import load
    truth = load()
    trip = {r["id"]: r["trip"] for r in truth}
    with open(os.path.join(OUT, "eval_tune.json")) as f:
        results = json.load(f)
    wins = confident(truth, results)
    cam = load_camera()
    n = 0
    for w in wins:
        with open(os.path.join(PREFILL, f"w{w}.json")) as f:
            pf = json.load(f)
        for name, fr in pf["frames"].items():
            lab = {"key": key_for(win=w, name=name), "src": "window", "win": w, "name": name,
                   "trip": trip[w], "lines": inside_curbs(cam, fr["lines"]), "boxes": [],
                   "origin": "pseudo"}
            save_label(lab, PSEUDO)
            n += 1
    print(f"уверенных окон: {len(wins)} {wins}, кадров псевдоразметки: {n} → {PSEUDO}")


if __name__ == "__main__":
    main()
