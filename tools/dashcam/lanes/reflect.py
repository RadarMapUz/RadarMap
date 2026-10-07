"""Неподвижные отражения: медиана отклика разметки по поездке.

    python3 reflect.py [trip ...]     → ~/RadarMapBuild/dashcam/lanes/static/<trip>.npz

На солнце в лобовом стекле отражается сетка динамика с торпедо (ромбы с
шагом ~8 px), блики на капоте и щётки — они стоят на месте в координатах
кадра, что бы машина ни делала. Разметка же за поездку проходит через
каждый пиксель лишь иногда: повороты, перестроения, разные дороги. Поэтому
медиана отклика top-hat по сотням кадров поездки — это и есть «неподвижная
светлая структура», и её вычитаем из отклика каждого кадра до порога.
Вычитаем, а не маскируем: сетка лежит поверх своей полосы, и маска стёрла
бы вместе с ней настоящие линии.
"""
import os
import sys

import numpy as np

from framesdb import OUT, frames
from marking import load_rgb, tophat_rows

STATIC = os.path.join(OUT, "static")
N_FRAMES = 300
MIN_KMH = 15.0


def responses(rgb):
    """Отклики top-hat яркости и «жёлтости» — те же, что в marking_masks."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    gray = 0.299 * r + 0.587 * g + 0.114 * b
    yel = np.clip((r + g) / 2 - b, 0, None)
    return tophat_rows(gray), tophat_rows(yel)


def build(trip):
    rows = [r for r in frames(trip) if r[2] is not None and r[2] > MIN_KMH]
    if len(rows) > N_FRAMES:
        idx = np.linspace(0, len(rows) - 1, N_FRAMES).astype(int)
        rows = [rows[i] for i in idx]
    th, ty = [], []
    for r in rows:
        a, b = responses(load_rgb(r[6]))
        th.append(a.astype(np.float16))
        ty.append(b.astype(np.float16))
    med = np.median(np.stack(th).astype(np.float32), 0)
    medy = np.median(np.stack(ty).astype(np.float32), 0)
    os.makedirs(STATIC, exist_ok=True)
    path = os.path.join(STATIC, f"{trip}.npz")
    np.savez_compressed(path, th=med.astype(np.float32), ty=medy.astype(np.float32),
                        n=len(rows))
    return path, len(rows)


def load(trip):
    """→ (медиана top-hat яркости, жёлтости) или None, если не построена."""
    path = os.path.join(STATIC, f"{trip}.npz")
    if not os.path.exists(path):
        return None
    z = np.load(path)
    return z["th"], z["ty"]


def main():
    trips = sys.argv[1:]
    if not trips:
        import json
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "truth.json")) as f:
            trips = sorted({r["trip"] for r in json.load(f)})
    for t in trips:
        path, n = build(t)
        print(f"{t}: {n} кадров → {path}", flush=True)


if __name__ == "__main__":
    main()
