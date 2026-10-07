"""Калибровка вида сверху по скорости: скорость вшита в кадр (OCR, таблица
ocr), это линейка вдоль движения.

На прямых при 20–70 км/ч берём 2 с ролика с полным fps, строим вид сверху
маски разметки/кромок и ищем сдвиг картинки вдоль Z между кадрами через
k кадров (взаимная корреляция). Путь за это время = v·Δt (Δt — по pts
кадров: у BYD средний fps 25,6, а не заявленные 30). Отношение
r = сдвиг_модели / путь показывает ошибку продольного масштаба:
Z ∝ f·h/(v − v_гор), а поперечный X ∝ h, так что при фиксированной h
(ширина полос её подтверждает) r даёт поправку фокуса f_истинный = f / r.
Отдельно по ближней (6–12 м) и дальней (12–20 м) полосе: если r различается,
неточен горизонт (наклон), а не фокус.

    python3 speedcal.py [число_отрезков]
"""
import json
import os
import random
import re
import sqlite3
import subprocess
import sys

import numpy as np
from scipy import ndimage

from camera import Camera, jpg_to_src
from framesdb import DB, MORNING, OUT, course_diff
from lanes import load_camera
from marking import tophat_rows

FFMPEG = "/opt/homebrew/bin/ffmpeg"
W, H = 1280, 529
K = 3                    # сравниваем кадр i и i+K
RES = 0.05
XS = np.arange(-6.0, 6.0, RES)
BANDS = {"6–12 м": (6.0, 12.0), "12–20 м": (12.0, 20.0)}


def clip_window(path, pos, dur=2.0):
    """Кадры ролика [pos, pos+dur) в геометрии JPEG детекторов + их pts."""
    cmd = [FFMPEG, "-v", "info", "-ss", f"{pos:.3f}", "-t", f"{dur:.3f}", "-i", path,
           "-vf", "crop=1920:794:0:70,scale=1280:529,showinfo",
           "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.run(cmd, capture_output=True)
    raw = np.frombuffer(p.stdout, np.uint8)
    n = len(raw) // (W * H * 3)
    frames = raw[: n * W * H * 3].reshape(n, H, W, 3).astype(np.float32)
    pts = [float(m) for m in re.findall(rb"pts_time:([0-9.]+)", p.stderr)]
    return frames, np.array(pts[:n]) + pos


def ocr_speed(con, clip_id):
    rows = con.execute("select t, kmh from ocr where clip_id=? and kmh is not null "
                       "order by t", (clip_id,)).fetchall()
    return np.array([r[0] for r in rows], float), np.array([r[1] for r in rows], float)


def bev_maps(cam, z0, z1):
    zs = np.arange(z1, z0, -RES)            # дальнее сверху
    X, Z = np.meshgrid(XS, zs)
    u, v = cam.ground_to_src(X, Z)
    x = u * (1280 / 1920)
    y = (v - 70) * (1280 / 1920)
    return y, x, zs


def edge_bev(rgb, maps):
    gray = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    th = tophat_rows(gray)
    # плюс вертикальный градиент: кромки, тени, швы — тоже признаки
    rows, cols, _ = maps
    ok = np.isfinite(rows)
    r = np.where(ok, rows, 0)
    c = np.where(ok, cols, 0)
    b = ndimage.map_coordinates(th, [r, c], order=1)
    b[~ok] = 0
    return b


def shift_m(a, b, max_px):
    """Сдвиг b относительно a вдоль строк (м): b — более поздний кадр, всё
    съезжает вниз (ближе). Корреляция нормированная, по целым px + парабола."""
    a = a - a.mean()
    b = b - b.mean()
    best = []
    for d in range(0, max_px):
        if d >= a.shape[0] - 20:
            break
        x = a[: a.shape[0] - d]
        y = b[d:]
        den = np.sqrt((x * x).sum() * (y * y).sum()) + 1e-9
        best.append(float((x * y).sum() / den))
    best = np.array(best)
    i = int(best.argmax())
    peak = best[i]
    if 0 < i < len(best) - 1:
        l, c, r = best[i - 1], best[i], best[i + 1]
        den = l - 2 * c + r
        off = 0.5 * (l - r) / den if den != 0 else 0
    else:
        off = 0
    return (i + off) * RES, peak


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    rows = con.execute(
        "select f.id, f.clip_id, f.pos, f.kmh, f.course, c.path from frames f "
        "join clips c on c.id=f.clip_id where f.trip_key=? order by f.t", (MORNING,)).fetchall()
    # Прямые 20–70 км/ч: курс соседей ±3 кадра в пределах 2°.
    cand = []
    for i in range(3, len(rows) - 3):
        r = rows[i]
        if r[3] is None or not (20 <= r[3] <= 70) or r[4] is None:
            continue
        if all(rows[j][4] is not None and course_diff(rows[j][4], r[4]) <= 2.0
               for j in range(i - 3, i + 4)):
            cand.append(r)
    # Берём кадры, где на виде сверху есть разметка (из прохода run.py).
    res_path = os.path.join(OUT, f"frames_{MORNING}.jsonl")
    good = set()
    for line in open(res_path):
        o = json.loads(line)
        if o.get("occluded", 1) <= 0.3 and len(o.get("lines", [])) >= 2:
            good.add(o["id"])
    cand = [r for r in cand if r[0] in good]
    random.seed(11)
    pick = random.sample(cand, min(n, len(cand)))
    cam = load_camera()
    maps = {k: bev_maps(cam, *z) for k, z in BANDS.items()}
    ratios = {k: [] for k in BANDS}
    per = []
    speeds = {}
    for fid, clip_id, pos, kmh, course, path in pick:
        if clip_id not in speeds:
            speeds[clip_id] = ocr_speed(con, clip_id)
        ts, vs = speeds[clip_id]
        frames, pts = clip_window(path, max(0.0, pos - 1.0))
        if len(frames) < K + 5 or len(pts) != len(frames):
            continue
        bevs = {}
        for k in BANDS:
            st = np.stack([edge_bev(f, maps[k]) for f in frames])
            # Неподвижное относительно камеры — блики в стекле, сетка динамика
            # с торпедо — тянуло бы корреляцию к нулевому сдвигу: вычитаем
            # медиану по времени, остаётся только то, что едет по дороге.
            st = np.clip(st - np.median(st, axis=0), 0, None)
            bevs[k] = list(st)
        out = {"id": fid, "kmh": kmh}
        for k in BANDS:
            rs = []
            for i in range(0, len(frames) - K, 2):
                dt = pts[i + K] - pts[i]
                v = float(np.interp((pts[i] + pts[i + K]) / 2, ts, vs)) / 3.6
                true = v * dt
                if true < 0.5:
                    continue
                d, peak = shift_m(bevs[k][i], bevs[k][i + K], int(true * 2.0 / RES) + 5)
                if peak < 0.5:
                    continue
                rs.append(d / true)
            if len(rs) >= 5:
                med = float(np.median(rs))
                ratios[k].append(med)
                out[k] = round(med, 3)
        per.append(out)
        print(out, flush=True)
    summary = {}
    for k, v in ratios.items():
        if v:
            summary[k] = {"n": len(v), "median": round(float(np.median(v)), 3),
                          "iqr": [round(float(np.percentile(v, 25)), 3),
                                  round(float(np.percentile(v, 75)), 3)]}
    # Согласованные отрезки: ближняя и дальняя полосы дали одно и то же
    # (±10 %). Несогласованные — это машина впереди с нашей скоростью
    # (сдвиг ~0) или периодичные штрихи, сбившие пик; их не усредняем.
    cons = [(o["6–12 м"], o["12–20 м"]) for o in per
            if "6–12 м" in o and "12–20 м" in o
            and abs(o["6–12 м"] - o["12–20 м"]) <= 0.1 * max(o["6–12 м"], o["12–20 м"])]
    allr = [x for p in cons for x in p]
    if allr:
        r = float(np.median(allr))
        summary["consistent_segments"] = len(cons)
        summary["ratio_consistent"] = round(r, 3)
        summary["ratio_iqr"] = [round(float(np.percentile(allr, 25)), 3),
                                round(float(np.percentile(allr, 75)), 3)]
        summary["f_model"] = cam.f
        summary["f_by_speed"] = round(cam.f / r, 1)
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    with open(os.path.join(OUT, "speedcal.json"), "w") as f:
        json.dump({"summary": summary, "segments": per}, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
