"""Маски классов из ломаных разметки — в кадре и на виде сверху.

    python3 seg_masks.py <key> [--root labels|pseudo]   → PNG-превью маски в OUT/tmp/

Классы (seg_common.CLASSES): фон, сплошная, прерывистая, двойная, бордюр,
проезжая часть, припаркованная и движущаяся машина; 255 — «не знаем»
(в потерю не идёт).

Как рисуем:
- линия — полоса постоянной ширины НА ЗЕМЛЕ (WIDTH_M: разметка 0,15 м,
  двойная 0,45, бордюр — верхняя кромка, полоса 0,15 м). Ломаная из
  кадра переводится на землю, у каждого пикселя — поперечное расстояние
  до неё на его дальности. Вдали 0,15 м уже меньше пикселя, поэтому в
  кадре полоса не тоньше 2 px (проверка ещё и в координатах кадра).
  Прерывистая размечается сплошной полосой через разрывы — как в
  CULane/TuSimple: класс «прерывистая линия», а не «штрих краски»; сами
  штрихи для v2 выделяет порог яркости внутри маски модели (marking.py).
- проезжая часть — между крайними границами: слева/справа бордюр, если
  он есть; если нет — крайняя линия, но тогда за ней «не знаем» (дорога
  там может продолжаться). Нет ни одной границы — вся земля «не знаем»
  (кроме линий и машин). Дальше, чем размечены обе границы, — «не знаем».
- машины — рамки в кадре; на виде сверху — пиксели, чья точка кадра
  попала в рамку (машина «размазывается» по земле, как и на картинке).

Допущение: линии идут от машины вдаль (Z растёт вдоль ломаной кусками).
Ломаная, где Z меняет направление, режется на монотонные куски —
поперечная линия (стоп-линия) этой схемой не рисуется, её классов пока нет.
"""
import functools
import os
import sys

import numpy as np

from camera import JPG_H, JPG_W, bev_axes, bev_map, jpg_to_src
from seg_common import CLS, IGNORE, MIN_HALF_PX, WIDTH_M, densify, jpg_to_ground

Z_MAX = 60.0      # дальше — не размечаем вовсе (фон по умолчанию)


@functools.lru_cache(maxsize=4)
def frame_ground(cam):
    """Земля под каждым пикселем кадра JPEG: (GX, GZ), nan выше горизонта."""
    ys, xs = np.mgrid[0:JPG_H, 0:JPG_W].astype(np.float64)
    u, v = jpg_to_src(xs + 0.5, ys + 0.5)
    X, Z = jpg_to_src_ground(cam, u, v)
    return X.astype(np.float32), Z.astype(np.float32)


def jpg_to_src_ground(cam, u, v):
    X, Z = cam.src_to_ground(u, v)
    bad = ~np.isfinite(Z) | (Z <= 0) | (Z > Z_MAX)
    return np.where(bad, np.nan, X), np.where(bad, np.nan, Z)


@functools.lru_cache(maxsize=4)
def bev_ground(cam):
    """Вид сверху: (GX, GZ) каждого пикселя и (row, col) его точки в кадре."""
    xs, zs = bev_axes()
    GX, GZ = np.meshgrid(xs, zs)
    rows, cols = bev_map(cam)
    vis = np.isfinite(rows)
    return (GX.astype(np.float32), GZ.astype(np.float32), rows, cols, vis)


def monotonic_pieces(X, Z):
    """Ломаная → куски, где Z строго растёт (порядок узлов любой)."""
    pieces, cur = [], [0]
    sign = 0
    for i in range(1, len(Z)):
        d = Z[i] - Z[i - 1]
        s = 1 if d > 0 else (-1 if d < 0 else 0)
        if s == 0:
            continue
        if sign == 0 or s == sign:
            sign = s
            cur.append(i)
        else:
            pieces.append(cur)
            cur, sign = [i - 1, i], s
    pieces.append(cur)
    out = []
    for p in pieces:
        if len(p) < 2:
            continue
        x, z = X[p], Z[p]
        if z[0] > z[-1]:
            x, z = x[::-1], z[::-1]
        out.append((x, z))
    return out


def ground_curve(cam, pts):
    """Ломаная кадра → монотонные по Z куски на земле [(X, Z)] (плотно)."""
    d = densify(pts, 2.0)
    X, Z = jpg_to_ground(cam, d)
    ok = np.isfinite(X) & np.isfinite(Z) & (Z > 0) & (Z <= Z_MAX)
    if ok.sum() < 2:
        return []
    return monotonic_pieces(X[ok], Z[ok])


def band(GX, GZ, curve, half_m):
    """Пиксели в ±half_m поперёк от куска кривой на его дальностях."""
    x, z = curve
    inz = (GZ >= z[0]) & (GZ <= z[-1])
    xl = np.interp(np.where(inz, GZ, z[0]), z, x)
    return inz & (np.abs(GX - xl) <= half_m)


def band_img(pts, half_px=MIN_HALF_PX):
    """Та же полоса в координатах кадра: в каждой строке ±half_px от
    ломаной — чтобы вдали линия не пропадала тоньше пикселя."""
    d = densify(pts, 1.0)
    m = np.zeros((JPG_H, JPG_W), bool)
    order = np.argsort(d[:, 1], kind="stable")
    y, x = d[order, 1], d[order, 0]
    for row in range(max(0, int(np.floor(y.min()))), min(JPG_H, int(np.ceil(y.max())) + 1)):
        sel = np.abs(y - (row + 0.5)) <= 0.75
        if not sel.any():
            continue
        x0, x1 = x[sel].min() - half_px, x[sel].max() + half_px
        m[row, max(0, int(np.floor(x0))):min(JPG_W, int(np.ceil(x1)) + 1)] = True
    return m


def bounds(cam, lab):
    """Левая и правая граница проезжей: [(кусок кривой), бордюр ли] или None."""
    cand = []
    for ln in lab.get("lines", []):
        for c in ground_curve(cam, ln["pts"]):
            cand.append((float(np.median(c[0])), ln["cls"] == "curb", c))
    if not cand:
        return None, None
    curbs_l = [c for c in cand if c[1] and c[0] < 0]
    curbs_r = [c for c in cand if c[1] and c[0] > 0]
    left = min(curbs_l, key=lambda c: c[0]) if curbs_l else min(cand, key=lambda c: c[0])
    right = max(curbs_r, key=lambda c: c[0]) if curbs_r else max(cand, key=lambda c: c[0])
    left = (left[2], left[1]) if left[0] < 0 or left[1] else None
    right = (right[2], right[1]) if right[0] > 0 or right[1] else None
    return left, right


def paint(lab, cam, GX, GZ, JR, JC, img_lines=False):
    """Маска uint8 по сетке точек земли (GX, GZ) и их пикселям в кадре
    (JR, JC — строка/столбец, nan — не видно)."""
    m = np.zeros(GX.shape, np.uint8)
    ground = np.isfinite(GZ)
    if lab.get("skip"):
        m[:] = IGNORE
        return m
    left, right = bounds(cam, lab)
    if left is None or right is None:
        # Нет хотя бы одной границы — где кончается дорога, не знаем.
        # За известным бордюром — точно не дорога (фон); всё остальное — 255.
        unknown = ground.copy()
        if left is not None and left[1]:
            x, z = left[0]
            unknown &= ~(GX < np.interp(GZ, z, x))
        if right is not None and right[1]:
            x, z = right[0]
            unknown &= ~(GX > np.interp(GZ, z, x))
        m[unknown] = IGNORE
    else:
        (lx, lz), lcurb = left
        (rx, rz), rcurb = right
        z0, z1 = max(lz[0], rz[0]), min(lz[-1], rz[-1])
        gz = np.where(ground, GZ, 0)
        L = np.interp(gz, lz, lx)
        R = np.interp(gz, rz, rx)
        if z1 > z0:
            inz = ground & (GZ >= z0) & (GZ <= z1)
            m[inz & (GX >= L) & (GX <= R)] = CLS["road"]
            if not lcurb:
                m[inz & (GX < L)] = IGNORE
            if not rcurb:
                m[inz & (GX > R)] = IGNORE
            # Дальше размеченного — не знаем; ближе — тоже (низ кадра у капота).
            m[ground & ((GZ > z1) | (GZ < z0)) & (GX >= L - 1.0) & (GX <= R + 1.0)] = IGNORE
        else:
            m[ground] = IGNORE
    vis = np.isfinite(JR)
    for b in lab.get("boxes", []):
        x0, y0, x1, y1 = b["box"]
        inb = vis & (JC >= x0) & (JC <= x1) & (JR >= y0) & (JR <= y1)
        m[inb] = CLS[b["cls"]]
    # Бордюры раньше линий: линия у самого бордюра важнее.
    for cls_order in (("curb",), ("solid", "dashed", "double")):
        for ln in lab.get("lines", []):
            if ln["cls"] not in cls_order:
                continue
            hw = WIDTH_M[ln["cls"]] / 2
            sel = np.zeros(GX.shape, bool)
            for c in ground_curve(cam, ln["pts"]):
                sel |= band(GX, GZ, c, hw)
            if img_lines:
                sel |= band_img(ln["pts"])
            m[sel] = CLS[ln["cls"]]
    return m


def frame_mask(lab, cam):
    GX, GZ = frame_ground(cam)
    JR, JC = np.mgrid[0:JPG_H, 0:JPG_W].astype(np.float32) + 0.5
    return paint(lab, cam, GX, GZ, JR, JC, img_lines=True)


def bev_mask(lab, cam):
    GX, GZ, rows, cols, vis = bev_ground(cam)
    m = paint(lab, cam, GX, GZ, rows, cols)
    m[~vis] = IGNORE
    return m


PALETTE = np.array([[0, 0, 0], [255, 255, 255], [80, 160, 255], [255, 200, 0], [255, 60, 60],
                    [60, 90, 60], [170, 0, 170], [0, 220, 220]], np.uint8)


def colorize(m, rgb=None, alpha=0.55):
    out = np.zeros(m.shape + (3,), np.uint8)
    ok = m != IGNORE
    out[ok] = PALETTE[np.minimum(m[ok], len(PALETTE) - 1)]
    out[~ok] = (90, 90, 90)
    if rgb is not None:
        base = np.asarray(rgb, np.float32)
        show = (m != 0)
        mix = base.copy()
        mix[show] = base[show] * (1 - alpha) + out[show] * alpha
        return mix.clip(0, 255).astype(np.uint8)
    return out


def main():
    from PIL import Image
    from framesdb import OUT
    from lanes import load_camera
    from marking import load_rgb
    from seg_common import LABELS, PSEUDO, image_path, load_label
    key = sys.argv[1]
    root = PSEUDO if "pseudo" in sys.argv[2:] else LABELS
    lab = load_label(key, root)
    if lab is None:
        raise SystemExit(f"нет разметки {key}")
    cam = load_camera()
    rgb = load_rgb(image_path(lab))
    os.makedirs(os.path.join(OUT, "tmp"), exist_ok=True)
    fm = frame_mask(lab, cam)
    Image.fromarray(colorize(fm, rgb)).save(os.path.join(OUT, "tmp", f"mask_{key}.png"))
    Image.fromarray(colorize(bev_mask(lab, cam))).save(os.path.join(OUT, "tmp", f"bev_{key}.png"))
    print(os.path.join(OUT, "tmp", f"mask_{key}.png"))


if __name__ == "__main__":
    main()
