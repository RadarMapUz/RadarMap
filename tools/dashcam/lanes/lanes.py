"""Полосы одного кадра: маска разметки → точки на земле → линии → полосы.

Линии ищем не на картинке вида сверху, а на облаке точек разметки,
пересчитанных на землю: одна общая «наклонка» s (все линии на участке
почти параллельны, на повороте наклонены одинаково), затем гистограмма
поперечного положения X0 = X − s·(Z − 8) и пики в ней.
"""
import json
import math
import os

import numpy as np
from scipy import ndimage

from camera import Camera, jpg_to_src, src_to_jpg
from framesdb import OUT
from logic import (UNDER_CAR, carriageway_width, classify, dash_runs, lane_layout,
                   median_kind, road_extent, strip_kind)
from marking import marking_masks

Z_NEAR, Z_FAR = 4.0, 40.0  # линии ищем и ближе окна вида сверху: низ кадра ≈ 3,7 м
Z_LINES = 22.0           # дальше линии слишком размазаны по X
Z_REF = 8.0              # положение линии отсчитываем здесь
BIN = 0.1
OCC_STEP = 0.5           # шаг ячеек заполнения вдоль линии, м
LINE_HALF = 0.18         # точка принадлежит линии в ±этого, м
MIN_SEP = 1.2            # две линии ближе — одна (двойная сплошная тоже одна)
SLOPES = np.arange(-0.25, 0.2501, 0.0125)

OCC_ZONE = (-1.6, 1.6, 6.0, 20.0)   # своя полоса 6–20 м: закрыта ли машинами
OCC_MAX = 0.25


def load_camera(path=None):
    path = path or os.path.join(OUT, "calib.json")
    with open(path) as f:
        c = json.load(f)
    return Camera(f=c["f"], k=c["k"], pitch_deg=c["pitch_deg"],
                  yaw_deg=c["yaw"], h=c.get("h", 1.3))


def visible_z_range(cam, x):
    """Видимая полоса Z для линии на поперечном x (кадр ограничен по краям
    и снизу): ближайшее Z, которое ещё в кадре, и Z_LINES."""
    zs = np.arange(Z_NEAR, Z_LINES, OCC_STEP)
    u, v = cam.ground_to_src(np.full_like(zs, x), zs)
    ok = (u >= 15) & (u <= 1905) & (v <= 862)
    if not ok.any():
        return None
    return float(zs[ok].min()), Z_LINES


LUMA = np.array([0.299, 0.587, 0.114], np.float32)


def sample(rgb, cam, X, Z):
    """Пиксели кадра в точках земли (ближайший сосед); невидимые выкинуты."""
    u, v = cam.ground_to_src(X, Z)
    x, y = src_to_jpg(u, v)
    ok = np.isfinite(x) & (x >= 0) & (x < 1280) & (y >= 0) & (y < 529)
    return rgb[y[ok].astype(int), x[ok].astype(int)]


TEX_MAX = 5.0      # асфальт гладкий: σ размытой яркости в окне 9×9 не больше


def features(rgb):
    """RGB + локальная σ яркости (4-й канал): машины, заборы, тени листвы —
    фактурные, асфальт — гладкий. σ считаем по размытой яркости: на солнце
    в стекле отражается сетка динамика с торпедо (мелкая решётка с шагом
    ~8 px в правой половине кадра), и без размытия она «закрывает» дорогу."""
    gray = ndimage.gaussian_filter(rgb @ LUMA, 2.5)
    m = ndimage.uniform_filter(gray, 9)
    m2 = ndimage.uniform_filter(gray * gray, 9)
    std = np.sqrt(np.clip(m2 - m * m, 0, None))
    return np.dstack([rgb, std]).astype(np.float32)


def asphalt_ref(feat, cam):
    """Яркость асфальта: медиана гладких пикселей зоны 5–20 м перед машиной."""
    Xr, Zr = np.meshgrid(np.arange(-5, 5, 0.25), np.arange(5, 20, 0.5))
    px = sample(feat, cam, Xr, Zr)
    px = px[px[:, 3] <= TEX_MAX]
    return float(np.median(px[:, :3] @ LUMA)) if len(px) > 20 else 100.0


def is_asphalt(px, ref):
    """Асфальт — серый, гладкий и близкий по яркости к опоре."""
    rgb = px[:, :3]
    gray = rgb @ LUMA
    sat = rgb.max(1) - rgb.min(1)
    return (np.abs(gray - ref) <= 32) & (sat <= 38) & (px[:, 3] <= TEX_MAX)


def occlusion(rgb, cam, ref):
    """Доля не-асфальта в зоне своей полосы 6–20 м."""
    x0, x1, z0, z1 = OCC_ZONE
    X, Z = np.meshgrid(np.arange(x0, x1, 0.2), np.arange(z0, z1, 0.4))
    px = sample(rgb, cam, X, Z)
    if len(px) < 50:
        return 1.0
    return float(1 - is_asphalt(px, ref).mean())


SIDE_OFF = (0.35, 0.9)     # полоса проверки сбоку от линии, м
SIDE_PAINT = 0.3           # разметка: асфальта с КАЖДОЙ стороны не меньше
SIDE_ROAD = 0.45           # хотя бы с одной стороны столько асфальта — линия на дороге
SIDE_EDGE = (0.15, 0.55)   # с одной стороны < 0,15, с другой ≥ 0,55 — край проезжей
                           # части (машина в соседнем ряду даёт ~0,35, не край)


def side_asphalt(rgb, cam, ref, c, s):
    """Доли асфальта слева и справа от линии x = c + s(Z − Z_REF) на 5–16 м.
    Линия между полосами — асфальт с обеих сторон; бордюр или край —
    с одной; ни с одной — не дорога вовсе (забор, машина, тротуар)."""
    zs = np.arange(5.0, 16.0, 0.5)
    offs = np.arange(SIDE_OFF[0], SIDE_OFF[1], 0.15)
    Zg, Og = np.meshgrid(zs, offs)
    xc = c + s * (Zg - Z_REF)
    out = []
    for sign in (-1, 1):
        px = sample(rgb, cam, xc + sign * Og, Zg)
        out.append(float(is_asphalt(px, ref).mean()) if len(px) >= 10 else 0.0)
    return out


DASH_ZMAX = 17.0          # длины штрихов меряем ближе: дальше строка кадра > 0,3 м
DEBUG = []                # причины отказа линиям (для отладки панелей)
LINE_W = (0.05, 0.40)     # ширина краски на виде сверху, м: норма 0,10–0,20,
                          # плюс размытие JPEG и top-hat (настоящие линии
                          # меряются 0,25–0,39; бок машины, бордюр — 0,40–0,60)
WIDTH_ZMAX = 14.0         # ширину меряем только вблизи — там геометрия точнее
CONTRAST = 6.0           # краска светлее асфальта по ОБЕ стороны хотя бы на


def paint_width(X0, Z, c, z0):
    """Медианная ширина краски по ячейкам вдоль линии: размах X точек маски
    в ±0,3 м от оси в каждой ячейке 0,5 м."""
    near = (np.abs(X0 - c) <= 0.3) & (Z < WIDTH_ZMAX)
    if near.sum() < 5:
        near = np.abs(X0 - c) <= 0.3
    if near.sum() < 5:
        return None
    cell = np.floor((Z[near] - z0) / OCC_STEP).astype(int)
    xs = X0[near]
    ws = []
    for k in np.unique(cell):
        v = xs[cell == k]
        if len(v) >= 4:
            # 10–90 % вместо min–max: ореол JPEG и соседняя фактура не
            # раздувают ширину одной точкой
            p10, p90 = np.percentile(v, [10, 90])
            ws.append(float(p90 - p10) + 0.02)
    return float(np.median(ws)) if ws else None


def side_contrast(feat, cam, c, s, zs):
    """Яркость на линии минус яркость асфальта слева и справа (0,35–0,6 м)
    в ячейках zs, где есть краска. Перепад «светлое → тёмное» с одной
    стороны (кромка, тень) даёт контраст только с одной стороны."""
    if len(zs) == 0:
        return -99.0, -99.0
    zs = np.asarray(zs, float)
    def g(off, q=50):
        Zg, Og = np.meshgrid(zs, np.asarray(off, float))
        px = sample(feat, cam, c + Og + s * (Zg - Z_REF), Zg)
        return float(np.percentile(px[:, :3] @ LUMA, q)) if len(px) >= 3 else None
    # Ячейки по 0,5 м захватывают и края штрихов — берём верхнюю квартиль.
    mid = g([-0.04, 0.0, 0.04], 75)
    lft = g([-0.6, -0.5, -0.4])
    rgt = g([0.4, 0.5, 0.6])
    if mid is None or lft is None or rgt is None:
        return -99.0, -99.0
    return mid - lft, mid - rgt


def find_lines(X, Z, cam, yellow_flag, rgb=None, ref=None):
    """Облако точек разметки → [(x@Z_REF, kind, fill, yellow, s)] и s."""
    sel = (Z >= Z_NEAR) & (Z < Z_LINES) & (np.abs(X) < 12.5)
    X, Z, yf = X[sel], Z[sel], yellow_flag[sel]
    if len(X) < 30:
        return [], 0.0, []
    bins = np.arange(-12.5, 12.5001, BIN)
    # Вес точки: дальние точки реже (меньше px на метр) — уравниваем.
    w = np.clip(Z / 8.0, 0.7, 1.6)
    best = None
    for s in SLOPES:
        h, _ = np.histogram(X - s * (Z - Z_REF), bins, weights=w)
        sc = float((h * h).sum())
        if best is None or sc > best[0]:
            best = (sc, s, h)
    _, s, h = best
    hs = np.convolve(h, np.array([1, 2, 3, 2, 1], float) / 9, "same")
    X0 = X - s * (Z - Z_REF)
    lines = []
    dashes = []        # (x, штрихи, разрывы) прерывистых — длины по пути, м
    order = np.argsort(-hs)
    taken = []
    centers = (bins[:-1] + bins[1:]) / 2
    for i in order[:60]:
        if hs[i] <= 0:
            break
        c = centers[i]
        if any(abs(c - t) < MIN_SEP for t in taken):
            continue
        near = np.abs(X0 - c) <= LINE_HALF
        if near.sum() < 15:
            continue
        # Уточняем центр — медиана точек линии.
        c = float(np.median(X0[near]))
        near = np.abs(X0 - c) <= LINE_HALF
        rng = visible_z_range(cam, c)
        if rng is None:
            continue
        z0, z1 = rng
        cells = np.arange(z0, z1, OCC_STEP)
        if len(cells) < 6:
            continue
        idx = np.floor((Z[near] - z0) / OCC_STEP).astype(int)
        idx = idx[(idx >= 0) & (idx < len(cells))]
        occ = np.zeros(len(cells), bool)
        occ[idx] = True
        # Ширина «линии»: настоящая разметка 0,1–0,2 м; бок машины, бордюр,
        # забор дают облако шире.
        pw = paint_width(X0, Z, c, z0)
        if pw is None or not (LINE_W[0] <= pw <= LINE_W[1]):
            DEBUG.append((round(c, 2), "ширина", pw))
            continue
        span = (idx.max() - idx.min() + 1) * OCC_STEP if len(idx) else 0
        if span < 1.0:
            continue
        kind, fill = classify(list(occ), OCC_STEP)
        if kind is None:
            DEBUG.append((round(c, 2), "заполнение", round(fill, 2)))
            continue
        yellow = float(yf[near].mean()) > 0.5
        if rgb is not None:
            la, ra = side_asphalt(rgb, cam, ref, c, s)
            if max(la, ra) < SIDE_ROAD:
                continue
            if min(la, ra) < SIDE_EDGE[0] and max(la, ra) >= SIDE_EDGE[1]:
                kind = "edge"      # край проезжей части: дальше в ту сторону не дорога
            else:
                # Разметка — только на асфальте с обеих сторон и светлее его
                # с обеих сторон; иначе это забор/плитка/бок машины.
                if min(la, ra) < SIDE_PAINT:
                    DEBUG.append((round(c, 2), "асфальт", round(la, 2), round(ra, 2)))
                    continue
                cl, cr = side_contrast(rgb, cam, c, s, cells[occ] + OCC_STEP / 2)
                if min(cl, cr) < CONTRAST:
                    DEBUG.append((round(c, 2), "контраст", round(cl), round(cr)))
                    continue
        taken.append(c)
        lines.append((c, kind, round(fill, 2), yellow))
        if kind == "dashed":
            fj = cam.f * 2 / 3          # фокус в px JPEG
            zz = Z[near]
            zz = zz[zz <= DASH_ZMAX]
            st, gp = dash_runs(list(zz), z0, DASH_ZMAX,
                               row_step=lambda z: z * z / (fj * cam.h))
            if st:
                dashes.append((round(c, 2), [round(x, 2) for x in st],
                               [round(x, 2) for x in gp]))
    lines.sort()
    return lines, float(s), dashes


PROF_STEP = 0.2


PROF_BANDS = ((6.0, 8.5), (8.5, 11.0), (11.0, 14.0))


def asphalt_profile(feat, cam, ref, s):
    """Доля асфальта по столбцам x (вдоль наклонки s) на 6–14 м. Берём
    лучшую из трёх полос по дальности: машина в соседнем ряду закрывает
    часть дальности, бордюр и газон — всю."""
    xs = np.arange(-12.0, 12.0001, PROF_STEP)
    a = []
    for x in xs:
        best = float("nan")
        for z0, z1 in PROF_BANDS:
            zs = np.arange(z0, z1, 0.3)
            px = sample(feat, cam, x + s * (zs - Z_REF), zs)
            if len(px) >= 4:
                f = float(is_asphalt(px, ref).mean())
                best = f if best != best else max(best, f)
        a.append(best)
    return xs, np.array(a)


def strip_stats(feat, cam, ref, s, edge, direction):
    """Доли (зелень, светлый бетон, асфальт, фактура) в полосе 0,3–2 м
    за краем edge в сторону direction (−1 влево, +1 вправо), 6–14 м."""
    zs = np.arange(6.0, 14.0, 0.4)
    offs = np.arange(0.3, 2.0, 0.15)
    Zg, Og = np.meshgrid(zs, offs)
    px = sample(feat, cam, edge + direction * Og + s * (Zg - Z_REF), Zg)
    if len(px) < 15:
        return None
    rgb = px[:, :3]
    r, g, b = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    gray = rgb @ LUMA
    sat = rgb.max(1) - rgb.min(1)
    green = (g > r + 6) & (g > b + 6)
    bright = (gray > ref + 30) & (sat < 40)
    asph = is_asphalt(px, ref)
    tex = (px[:, 3] > TEX_MAX * 1.5) & ~green
    return float(green.mean()), float(bright.mean()), float(asph.mean()), float(tex.mean())


def roadside(feat, cam, ref, s, lines, extent, layout):
    """Края проезжей части, ширина, разделительная слева, тротуар справа."""
    le, re_ = extent
    # «Край»-линия (асфальт с одной стороны) ближе края профиля — точнее
    # его: светлый бордюрный камень даёт узкую чёткую линию.
    for c, kind, _, _ in lines:
        if kind != "edge":
            continue
        if c < 0 and (le is None or c > le) and c > -12:
            le = c
        if c > 0 and (re_ is None or c < re_):
            re_ = c
    st_l = strip_stats(feat, cam, ref, s, le, -1) if le is not None else None
    st_r = strip_stats(feat, cam, ref, s, re_, 1) if re_ is not None else None
    kl = strip_kind(*st_l) if st_l else None
    kr = strip_kind(*st_r) if st_r else None
    left_axis = layout["left_line"] if layout else None
    left_kind = layout["left_kind"] if layout else None
    left_yellow = False
    med = median_kind(left_kind, left_yellow, kl)
    width = carriageway_width(le if kl in ("газон", "бордюр", "ограждение") else None,
                              re_, left_axis if left_kind == "solid" else None)
    sidewalk = None
    if st_r is not None:
        sidewalk = kr in ("бордюр",) or (st_r[1] >= 0.2 and st_r[0] < 0.25)
    return {"left_edge": le, "right_edge": re_, "left_strip": kl, "right_strip": kr,
            "median": med, "width": width, "sidewalk": sidewalk}


def analyze(rgb, cam):
    """Кадр (RGB float) → результат: линии, раскладка полос, закрытость."""
    white, yellow, _ = marking_masks(rgb)
    m = white | yellow
    ys, xs = np.nonzero(m)
    keep = ys >= 360
    ys, xs = ys[keep], xs[keep]
    u, v = jpg_to_src(xs.astype(float), ys.astype(float))
    X, Z = cam.src_to_ground(u, v)
    ok = np.isfinite(X)
    X, Z = X[ok], Z[ok]
    yflag = yellow[ys[ok], xs[ok]]
    feat = features(rgb)
    ref = asphalt_ref(feat, cam)
    lines, s, dashes = find_lines(X, Z, cam, yflag, feat, ref)
    pxs, prof = asphalt_profile(feat, cam, ref, s)
    extent = road_extent(list(pxs), list(prof), PROF_STEP)
    layout = lane_layout([(c, kind, fill) for c, kind, fill, _ in lines], extent)
    side = roadside(feat, cam, ref, s, lines, extent, layout)
    return {
        "lines": lines,
        "slope": s,
        "layout": layout,
        "extent": (side["left_edge"], side["right_edge"]),
        "side": side,
        "dashes": dashes,
        "occluded": occlusion(feat, cam, ref),
        "points": (X, Z),
    }
