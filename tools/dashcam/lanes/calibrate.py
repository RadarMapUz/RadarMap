"""Калибровка горизонта, дисторсии и рыскания по разметке на прямых.

На прямой дороге линии разметки на виде сверху — вертикальные и
параллельные: распределение X точек разметки вблизи (6–12 м) и вдали
(15–30 м) должно совпадать. Перебираем горизонт v_г, k и рыскание,
максимизируя корреляцию этих двух гистограмм по многим кадрам (k — по
паспортному углу обзора, см. K_PRIOR). Высота
камеры фиксирована (1,3 м) — она задаёт боковой масштаб, f — по углу
обзора ~120°.

    python3 calibrate.py [число_кадров]
"""
import json
import math
import os
import random
import sys

import numpy as np

from camera import Camera, jpg_to_src
from framesdb import OUT, frames, straight_ids
from marking import load_rgb, marking_masks

BINS = np.arange(-8, 8.0001, 0.1)
# Дисторсия этим критерием почти не меряется: корреляция ближних и дальних
# гистограмм плоская по k от 0,6 до 1,3 (проверено перебором — 0,588…0,598),
# потому что k сильно влияет только на края кадра, где разметки мало.
# Берём k из паспортного угла обзора ~120° при f = 700 px (k=0,3 → 120,5°)
# и проверяем глазами по линиям у края кадра.
K_PRIOR = 0.3
# Фокус f: первая версия брала 700 px из паспортных ~120°. Линейка по
# скорости (speedcal.py: сдвиг картинки между кадрами против v·Δt) дала
# продольный масштаб в 0,64 от истинного → f ≈ 1095 px; боковой масштаб от f
# не зависит (X ≈ h·Δu/Δv), поэтому ширины полос при этом не меняются, а
# дальности становятся честными (низ кадра — ~6 м, а не 3,6).


def speed_focal(default=700.0):
    """Фокус из калибровки по скорости (speedcal.py), если она уже есть."""
    try:
        with open(os.path.join(OUT, "speedcal.json")) as fh:
            return float(json.load(fh)["summary"]["f_by_speed"])
    except (OSError, KeyError, ValueError):
        return default


def cam_from(vh, k, yaw, f=700.0):
    pitch = math.degrees(math.atan((540.0 - vh) / f))
    return Camera(f=f, k=k, pitch_deg=pitch, yaw_deg=yaw)


def frame_points(path):
    rgb = load_rgb(path)
    white, yellow, _ = marking_masks(rgb)
    ys, xs = np.nonzero(white | yellow)
    keep = ys >= 370
    u, v = jpg_to_src(xs[keep].astype(float), ys[keep].astype(float))
    return u, v


def score(cam, pts):
    total = 0.0
    for u, v in pts:
        X, Z = cam.src_to_ground(u, v)
        ok = np.isfinite(X)
        X, Z = X[ok], Z[ok]
        near = X[(Z >= 6) & (Z < 12)]
        far = X[(Z >= 15) & (Z < 30)]
        if len(near) < 20 or len(far) < 20:
            continue
        hn, _ = np.histogram(near, BINS)
        hf, _ = np.histogram(far, BINS)
        k3 = np.array([1, 2, 1], float)
        hn = np.convolve(hn, k3, "same").astype(float)
        hf = np.convolve(hf, k3, "same").astype(float)
        hn /= np.linalg.norm(hn) + 1e-9
        hf /= np.linalg.norm(hf) + 1e-9
        total += float(hn @ hf)
    return total / max(1, len(pts))


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    rows = straight_ids(frames())
    random.seed(7)
    sample = random.sample(rows, min(n, len(rows)))
    pts = [frame_points(r[6]) for r in sample]
    best = None
    grid = []
    for vh in range(595, 656, 5):
        for k in (K_PRIOR,):
            for yaw in (-6, -5, -4, -3, -2, -1, 0, 1, 2):
                s = score(cam_from(vh, k, yaw), pts)
                grid.append((s, vh, k, yaw))
                if best is None or s > best[0]:
                    best = (s, vh, k, yaw)
    # Уточнение вокруг лучшего.
    s0, vh0, k0, yaw0 = best
    for vh in np.arange(vh0 - 4, vh0 + 4.01, 1):
        for k in (K_PRIOR,):
            for yaw in np.arange(yaw0 - 0.75, yaw0 + 0.76, 0.25):
                s = score(cam_from(vh, k, yaw), pts)
                if s > best[0]:
                    best = (s, float(vh), float(k), float(yaw))
    grid.sort(reverse=True)
    print("кадров на прямой:", len(rows), "в выборке:", len(sample))
    print("топ сетки:", grid[:5])
    print("лучшее: score=%.4f v_гор=%.1f k=%.2f рыскание=%.2f°" % best)
    # Горизонт и рыскание ищем в пикселях при f = 700 (на нём критерий
    # работает: при f ≈ 1100 низ кадра уже ~6 м и «ближней» полосы почти
    # нет), а затем переносим на фокус из линейки по скорости, сохраняя
    # строку горизонта и пиксельное смещение рыскания. Что строка горизонта
    # верна, подтверждает сама линейка: отношение сдвигов вблизи (6–12 м) и
    # вдали (12–20 м) совпало (0,637 и 0,641) — при неверном горизонте оно
    # менялось бы с дальностью.
    f_speed = speed_focal()
    yaw_px = 700.0 * math.tan(math.radians(best[3]))
    yaw = math.degrees(math.atan(yaw_px / f_speed))
    cam = cam_from(best[1], best[2], yaw, f_speed)
    res = {"vh": best[1], "k": best[2], "yaw": yaw, "yaw_px": yaw_px, "f": cam.f,
           "pitch_deg": cam.pitch_deg, "h": cam.h, "score": best[0],
           "hfov_deg": cam.hfov_deg(), "frames": len(sample)}
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "calib.json"), "w") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    print(res)


if __name__ == "__main__":
    main()
