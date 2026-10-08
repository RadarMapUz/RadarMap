"""Полосы по отрезку полного fps (v2): кадры → треки линий → раскладка → ответ.

Отрезок — кадры windows/<id>/ (clips.py) с временем из pts. Для каждого
кадра (через STRIDE): маска разметки за вычетом неподвижных отражений
(reflect.py) → точки на земле → общая наклонка → гистограмма поперечного
положения. Дальше track.py: пики, общий сдвиг кадров, треки. Трек живёт
≥ 1 с — кандидат в линии; дальше его проверяют по кадрам его жизни:
ширина краски, асфальт по обе стороны и контраст (разметка) или с одной
(край), «бегут ли штрихи» со скоростью машины (прерывистая) или стоят
(отражение — долой). Края дороги — по полосам дальности в каждом кадре
(logic.edge_kind: бордюр или припаркованные машины). Раскладка
(logic.lane_layout2) считается в каждом кадре по положениям треков в нём,
ответ окна — голосование (logic.vote).
"""
import bisect
import json
import os

import numpy as np

from camera import jpg_to_src
from framesdb import OUT, frames
from lanes import (LINE_W, LUMA, PROF_BANDS, SLOPES, Z_LINES, Z_NEAR, Z_REF, asphalt_ref,
                   features, is_asphalt, paint_width, sample, side_asphalt, side_contrast,
                   strip_stats, visible_z_range)
from logic import UNDER_CAR, classify, edge_kind, lane_layout2, strip_kind, vote
from marking import load_rgb, marking_masks, model_masks
from track import (BIN, cumulative, dash_like, frame_peaks, frame_shift, is_line_track, link_tracks,
                   motion_test, path_from_speed, profile, track_x_at)

WIN = os.path.join(OUT, "windows")
STRIDE = 2               # каждый второй кадр: ~12,8 к/с, на 60 км/ч 1,3 м между кадрами
X_LIM = 12.5
EDGES = np.arange(-X_LIM, X_LIM + 1e-9, BIN)
PEAK_MIN = 6.0           # пик гистограммы (взвешенные точки в бине после сглаживания)
SLOPE_SMOOTH = 5         # медиана наклонки по ±кадрам
LINE_HALF = 0.18
OCC_STEP = 0.5
SAMPLE_EVERY = 3         # проверки трека — по каждому такому кадру его жизни
CONTRAST = 6.0
SIDE_PAINT = 0.3
SIDE_ROAD = 0.45
SIDE_EDGE = (0.25, 0.55)   # край: с одной стороны < 0,25 асфальта, с другой ≥ 0,55
# Ближняя полоса 6–8,5 м отброшена: на краях кадра там видна лишь кромка
# по углам, и край в ней промахивался на метр против трёх дальних.
EDGE_BANDS = ((8.5, 11.0), (11.0, 14.0), (14.0, 18.0))
EDGE_RUN = 0.6
EDGE_A = 0.2
EDGE_TRACK_LIFE = 1.5
SIDE_TEX = 10.0          # фактура «асфальта» сбоку от линии: вдвое мягче v1 —
                         # справа от своей полосы лежит отражение сетки динамика,
                         # и с порогом 5 асфальт там не узнавался вовсе
MOVE_ROAD = 0.35         # бегущим штрихам нужен асфальт хотя бы с одной стороны:
                         # стоящие машины и бордюр «бегут» с землёй так же
FAR_X = 6.5              # дальше от оси линия принимается только по бегущим штрихам
OWN_X = 2.6              # линия ближе — кандидат в границы своей полосы
VOTE_SHARE = 0.5         # ответ окна: за число полос не меньше этой доли кадров
MAX_X = 9.0              # дальше линии не берём совсем: там на кадре уже обочина
MERGE_X = 0.6            # два трека ближе — одна линия (оставляем дольше живший)


def load_window(fid):
    d = os.path.join(WIN, str(fid))
    with open(os.path.join(d, "pts.json")) as f:
        meta = json.load(f)
    names = sorted(n for n in os.listdir(d) if n.startswith("f_"))
    return d, names, meta["pts"], meta["pos"]


def speed_series(trip, t_center, pos, pts):
    """км/ч на каждый кадр отрезка: линейно по кадрам поездки из БД
    (скорость с полосы регистратора), время кадра = t_center + (pts − pos)."""
    rows = [(r[1], r[2]) for r in frames(trip) if r[2] is not None]
    ts = [r[0] for r in rows]
    out = []
    for p in pts:
        t = t_center + (p - pos)
        j = bisect.bisect_left(ts, t)
        if j <= 0:
            out.append(rows[0][1])
        elif j >= len(ts):
            out.append(rows[-1][1])
        else:
            (t0, v0), (t1, v1) = rows[j - 1], rows[j]
            out.append(v0 + (v1 - v0) * (t - t0) / (t1 - t0) if t1 > t0 else v0)
    return out


def frame_points(rgb, cam, static, mask="thr"):
    """mask: "thr" — пороговая маска (marking_masks), "model" — маска
    обученной сегментации (marking.model_masks, seg_model.py), "hybrid" —
    пороговая, но к каждой точке — класс модели в её пикселе (последний
    элемент ответа; для остальных масок — None)."""
    if mask == "model":
        white, yellow, _, ghost = model_masks(rgb, return_ghost=True)
    else:
        white, yellow, _, ghost = marking_masks(rgb, static, return_ghost=True)
    m = white | yellow
    ys, xs = np.nonzero(m)
    keep = ys >= 360
    ys, xs = ys[keep], xs[keep]
    u, v = jpg_to_src(xs.astype(float), ys.astype(float))
    X, Z = cam.src_to_ground(u, v)
    ok = np.isfinite(X) & (Z >= Z_NEAR) & (Z < Z_LINES) & (np.abs(X) < X_LIM)
    out = (X[ok], Z[ok], yellow[ys[ok], xs[ok]])
    mc = None
    if mask == "hybrid":
        from seg_model import predictor
        mc = predictor().classes(rgb)[ys[ok], xs[ok]]
    if ghost is None:
        return out + (np.zeros(0), np.zeros(0), mc)
    gy, gx = np.nonzero(ghost[::2, ::2])
    gy, gx = gy * 2, gx * 2
    k = gy >= 360
    gu, gv = jpg_to_src(gx[k].astype(float), gy[k].astype(float))
    GX, GZ = cam.src_to_ground(gu, gv)
    g = np.isfinite(GX) & (GZ >= Z_NEAR) & (GZ < Z_LINES) & (np.abs(GX) < X_LIM)
    return out + (GX[g], GZ[g], mc)


def best_slope(X, Z):
    if len(X) < 30:
        return 0.0
    w = np.clip(Z / 8.0, 0.7, 1.6)
    best = None
    for s in SLOPES:
        h, _ = np.histogram(X - s * (Z - Z_REF), EDGES, weights=w)
        sc = float((h * h).sum())
        if best is None or sc > best[0]:
            best = (sc, s)
    return float(best[1])


def band_edges(feat, cam, ref, s, start, direction):
    """Край асфальта в каждой полосе дальности: от start наружу первое
    место, где EDGE_RUN м подряд не асфальт. → [x|None] по EDGE_BANDS."""
    xs = np.arange(start, direction * 12.0, direction * 0.2)
    need = int(round(EDGE_RUN / 0.2))
    out = []
    for z0, z1 in EDGE_BANDS:
        zs = np.arange(z0, z1, 0.4)
        run, edge = 0, None
        for x in xs:
            px = sample(feat, cam, x + s * (zs - Z_REF), zs)
            if len(px) < 3:
                break               # дальше кадр кончился
            a = float(is_asphalt(px, ref).mean())
            if a < EDGE_A:
                run += 1
                if run >= need:
                    edge = float(x - direction * 0.2 * (need - 1))
                    break
            else:
                run = 0
        out.append(edge)
    return out


def analyze_window(fid, trip, t_center, cam, static, stride=STRIDE, keep_debug=False, mask="thr"):
    d, names, pts, pos = load_window(fid)
    idx = list(range(0, len(names), stride))
    times = [pts[i] for i in idx]
    kmh = speed_series(trip, t_center, pos, times)
    path = path_from_speed(times, kmh)
    k_ref = min(range(len(times)), key=lambda k: abs(times[k] - pos))
    data = []
    for i in idx:
        rgb = load_rgb(os.path.join(d, names[i]))
        X, Z, yf, GX, GZ, mc = frame_points(rgb, cam, static, mask)
        data.append({"X": X, "Z": Z, "yf": yf, "mc": mc, "s": best_slope(X, Z), "GX": GX, "GZ": GZ,
                     "rgb": rgb.astype(np.uint8)})
    # Наклонка — общая для соседних кадров: медиана по ±SLOPE_SMOOTH.
    raw_s = [f["s"] for f in data]
    for k, f in enumerate(data):
        lo, hi = max(0, k - SLOPE_SMOOTH), min(len(data), k + SLOPE_SMOOTH + 1)
        f["s"] = float(np.median(raw_s[lo:hi]))
        w = np.clip(f["Z"] / 8.0, 0.7, 1.6)
        f["X0"] = f["X"] - f["s"] * (f["Z"] - Z_REF)
        f["h"], _ = np.histogram(f["X0"], EDGES, weights=w)
    peaks = [frame_peaks(list(f["h"]), -X_LIM, PEAK_MIN) for f in data]
    shifts = [frame_shift(list(data[k]["h"]), list(data[k + 1]["h"]))
              for k in range(len(data) - 1)]
    cum = cumulative(shifts)
    tracks = [t for t in link_tracks(peaks, times, shifts) if is_line_track(t, times)]
    # Признаки кадров, нужные проверкам (дорого — только по выборке кадров).
    feats = {}

    def feat(k):
        if k not in feats:
            fe = features(data[k]["rgb"].astype(np.float32))
            feats[k] = (fe, asphalt_ref(fe, cam))
        return feats[k]

    lines = []
    for t in tracks:
        ks = t["k"][::SAMPLE_EVERY] or t["k"][:1]
        widths, la_ra, contr, kinds, yel = [], [], [], [], []
        mvotes = []          # классы модели у точек трека (только hybrid)
        profiles = [None] * len(data)
        # Продольный профиль — только по видимой части линии: край кадра
        # тоже «стоит», и обрезанная им линия иначе выглядела бы отражением.
        vis = visible_z_range(cam, float(np.median(t["x"])))
        pz0 = max(5.0, vis[0] + 0.3) if vis else None
        for k, x in zip(t["k"], t["x"]):
            f = data[k]
            near = np.abs(f["X0"] - x) <= LINE_HALF
            if pz0 is not None and 17.0 - pz0 >= 6.0 and near.sum() >= 4:
                gx0 = f["GX"] - f["s"] * (f["GZ"] - Z_REF)
                gnear = np.abs(gx0 - x) <= LINE_HALF
                profiles[k] = profile(list(f["Z"][near]), pz0, 17.0,
                                      unknown=list(f["GZ"][gnear]))
        for k in ks:
            f = data[k]
            x = t["x"][t["k"].index(k)]
            near = np.abs(f["X0"] - x) <= LINE_HALF
            if near.sum() < 10:
                continue
            fe, ref = feat(k)
            z0 = Z_NEAR
            pw = paint_width(f["X0"], f["Z"], x, z0)
            if pw is not None:
                widths.append(pw)
            la_ra.append(side_asphalt(fe, cam, ref, x, f["s"], SIDE_TEX))
            cells = np.arange(z0, Z_LINES, OCC_STEP)
            ii = np.floor((f["Z"][near] - z0) / OCC_STEP).astype(int)
            ii = ii[(ii >= 0) & (ii < len(cells))]
            occ = np.zeros(len(cells), bool)
            occ[ii] = True
            kind, _ = classify(list(occ), OCC_STEP)
            kinds.append(kind)
            cl, cr = side_contrast(fe, cam, x, f["s"], cells[occ] + OCC_STEP / 2)
            contr.append(min(cl, cr))
            yel.append(float(f["yf"][near].mean()))
            if f["mc"] is not None:
                mvotes.append(np.bincount(f["mc"][near], minlength=8))
        n_pairs, moving, static_ = motion_test(profiles, path)
        dash, stroke, gap = dash_like(profiles)
        info = {"x_ref": track_x_at(t, k_ref, cum), "life": times[t["k"][-1]] - times[t["k"][0]],
                "n": len(t["k"]), "moving": moving, "static": static_, "pairs": n_pairs, "dash": dash, "stroke": stroke, "gap": gap,
                "width": float(np.median(widths)) if widths else None,
                "la": float(np.median([a for a, _ in la_ra])) if la_ra else None,
                "ra": float(np.median([b for _, b in la_ra])) if la_ra else None,
                "contrast": float(np.median(contr)) if contr else None,
                "kinds": kinds, "yellow": bool(yel and np.mean(yel) > 0.5), "track": t}
        info["kind"], info["why"] = judge_track(info)
        if mask == "hybrid":
            info["model"] = model_support(mvotes)
            info["kind"], info["why"] = judge_hybrid(info, info["kind"], info["why"])
        lines.append(info)
    for l in lines:
        if l["kind"] is not None and abs(l["x_ref"]) > FAR_X and l["why"] != "штрихи бегут" \
                and l["kind"] != "edge":
            l["kind"], l["why"] = None, "далеко, штрихи не подтверждены"
        elif l["kind"] is not None and abs(l["x_ref"]) > MAX_X:
            l["kind"], l["why"] = None, "дальше трёх рядов"
    good = []
    for l in sorted((l for l in lines if l["kind"] is not None), key=lambda l: -l["n"]):
        if all(abs(l["x_ref"] - g["x_ref"]) >= MERGE_X for g in good):
            good.append(l)
        else:
            l["kind"], l["why"] = None, "дубль соседнего трека"
    good.sort(key=lambda l: l["x_ref"])
    # Края дороги по выборке кадров.
    sample_ks = list(range(0, len(data), 3))
    left_e, right_e, strips = [], [], {"l": [], "r": []}
    for k in sample_ks:
        fe, ref = feat(k)
        xs_k = [track_x_at(l["track"], k, cum) for l in good if l["kind"] != "edge"]
        r_start = max([x for x in xs_k if x > 0] + [0.6]) + 0.4
        l_start = min([x for x in xs_k if x < 0] + [-0.6]) - 0.4
        s = data[k]["s"]
        re_ = band_edges(fe, cam, ref, s, r_start, 1)
        le_ = band_edges(fe, cam, ref, s, l_start, -1)
        right_e.append(re_)
        left_e.append(le_)
        for key, edges, sign in (("l", le_, -1), ("r", re_, 1)):
            e = [x for x in edges if x is not None]
            if e:
                st = strip_stats(fe, cam, ref, s, float(np.median(e)), sign)
                strips[key].append(strip_kind(*st) if st else None)
    def mode(v):
        v = [x for x in v if x is not None]
        return max(set(v), key=v.count) if v else None
    rk, rx = edge_kind(right_e, mode(strips["r"]))
    lk, lx = edge_kind(left_e, mode(strips["l"]))
    # Трек-край, проживший EDGE_TRACK_LIFE и выше: асфальт с внутренней
    # стороны, не асфальт с внешней, на одном месте секундами — это и есть
    # «длинная непрерывная граница». Он точнее края асфальта по полосам.
    for side, sign in (("r", 1), ("l", -1)):
        cand = [l for l in good if l["kind"] == "edge" and sign * l["x_ref"] > UNDER_CAR
                and l["life"] >= EDGE_TRACK_LIFE
                and ((l["la"] > l["ra"]) if sign > 0 else (l["ra"] > l["la"]))]
        if cand:
            x = min(cand, key=lambda l: abs(l["x_ref"]))["x_ref"]
            # Борт автобуса или фуры тоже длинная ровная граница; если края по
            # полосам дальности там же сказали «машины», верим им.
            k0, x0 = (rk, rx) if side == "r" else (lk, lx)
            if k0 == "cars" and x0 is not None and abs(x0 - x) < 1.0:
                continue
            if side == "r":
                rk, rx = "curb", x
            else:
                lk, lx = "curb", x
    # Раскладка в каждом кадре по положениям треков в нём → голосование.
    layouts = []
    for k in range(len(data)):
        ls = []
        for l in good:
            t = l["track"]
            if not (t["k"][0] <= k <= t["k"][-1]):
                continue
            ls.append((track_x_at(t, k, cum), l["kind"]))
        # Края — в координатах кадра k: их положение переносится общим сдвигом.
        off = cum[k] - cum[k_ref]
        lb = lx + off if lk == "curb" and lx is not None else None
        rb = rx + off if rk == "curb" and rx is not None else None
        layouts.append(lane_layout2(ls, lb, rb))
    lanes, own, share = vote(layouts, VOTE_SHARE)
    ref_layout = layouts[k_ref]
    res = {"id": fid, "lanes": lanes, "own": own, "share": round(share, 2),
           "frames": len(data), "tracks": len(tracks),
           "kmh": round(float(np.median(kmh)), 1),
           "lines": [{k: (round(v, 2) if isinstance(v, float) else v)
                      for k, v in l.items() if k not in ("track",)} for l in lines],
           "left_edge": [lk, None if lx is None else round(lx, 2)],
           "right_edge": [rk, None if rx is None else round(rx, 2)],
           "ref_layout": ref_layout}
    if keep_debug:
        res["_data"] = data
        res["_k_ref"] = k_ref
        res["_cum"] = cum
        res["_good"] = good
        res["_lines"] = lines      # все треки с причинами (seg_selflabel.py)
    return res


# ── гибрид: v2 + модель ────────────────────────────────────────────────
# Пороги выбираются на половине настройки по фолдам поездок (модель фолда
# не видела этих поездок), не на проверке.
HYB_VETO = 0.15          # принятая v2 линия краски, где модель видит линию реже, — долой
HYB_RESCUE = 0.6         # отброшенная v2 линия, где модель видит линию чаще, — возвращаем
HYB_RESCUE_WHY = ("контраст", "асфальт с одной стороны мало", "не на дороге",
                  "обрывки, не штрихи", "заполнение")


def model_support(votes):
    """Голоса классов модели у точек трека → {line, curb, kind}: доля точек,
    которые модель считает линией краски / бордюром, и её класс линии."""
    if not votes:
        return None
    v = np.sum(votes, axis=0).astype(float)
    n = v.sum()
    if n <= 0:
        return None
    line = v[1] + v[2] + v[3]
    kind = None
    if line > 0:
        kind = ("solid", "dashed", "double")[int(np.argmax(v[1:4]))]
    return {"line": float(line / n), "curb": float(v[4] / n), "kind": kind}


def judge_hybrid(l, kind, why, veto=None, rescue=None):
    """Решение v2 по треку + опора модели → (kind, why). Модель только
    подтверждает/снимает и возвращает отброшенное «мягкими» фильтрами;
    «стоит в кадре» (отражение) и края v2 модель не переигрывает."""
    veto = HYB_VETO if veto is None else veto
    rescue = HYB_RESCUE if rescue is None else rescue
    m = l.get("model")
    if m is None:
        return kind, why
    if kind in ("solid", "dashed") and m["line"] < veto:
        return None, f"модель: не линия ({m['line']:.2f})"
    if kind is None and why in HYB_RESCUE_WHY and m["line"] >= rescue:
        w = l.get("width")
        if w is not None and LINE_W[0] <= w <= LINE_W[1]:
            k = "dashed" if m["kind"] == "dashed" else "solid"
            return k, f"модель: линия ({m['line']:.2f})"
    return kind, why


def judge_track(l):
    """Трек → ('solid'|'dashed'|'edge'|None, причина). Пороги — те же, что
    в v1 для одного кадра, но по медиане кадров жизни трека."""
    kinds = [k for k in l["kinds"] if k]
    solid = kinds.count("solid") / len(kinds) if kinds else 0.0
    # «Стоит»: картина линии не сдвигается, хотя машина проехала метры —
    # отражение или борт машины, едущей рядом с нашей скоростью. Для
    # сплошной структуры мало (тест молчит), поэтому требуем, чтобы «стоит»
    # было заметной долей сравнимых пар.
    if l["static"] >= max(3, 0.4 * l["pairs"]) and l["static"] >= 2 * l["moving"]:
        return None, "стоит в кадре"
    if l["static"] >= 2 and l["static"] > l["moving"] and solid < 0.5:
        return None, "стоит в кадре"
    la, ra = l["la"], l["ra"]
    if la is None:
        return None, "не проверить"
    # Край (бордюр, кромка): асфальта нет с ВНЕШНЕЙ стороны (от машины), а
    # с внутренней есть. Наоборот (пусто со стороны своей полосы) — это не
    # край, а машина в соседнем ряду или отражение у самой линии.
    outer, inner = (la, ra) if l["x_ref"] < 0 else (ra, la)
    if outer < SIDE_EDGE[0] and inner >= SIDE_EDGE[1]:
        return "edge", "асфальт с одной стороны"
    # Чёткие штрихи с разрывами, бегущие с машиной, — краска: асфальт сбоку
    # от них «пропадает» из-за машины в соседнем ряду.
    if l["dash"] and (l["gap"] or 0) >= 1.5 and l["moving"] >= 3 \
            and l["moving"] >= 1.5 * l["static"] and l["width"] and l["width"] <= LINE_W[1] \
            and max(la, ra) >= MOVE_ROAD:
        return "dashed", "штрихи бегут"
    w = l["width"]
    if w is None or not (LINE_W[0] <= w <= LINE_W[1]):
        return None, f"ширина {w}"
    # Штрихи разметки, бегущие ровно со скоростью машины, — самый сильный
    # признак: машина рядом и отражение в стекле портят контраст и асфальт
    # сбоку, но не это.
    if l["dash"] and l["moving"] >= 3 and l["moving"] >= 1.5 * l["static"] \
            and max(la, ra) >= MOVE_ROAD:
        return "dashed", "штрихи бегут"
    if max(la, ra) < SIDE_ROAD:
        return None, "не на дороге"
    # У линий своей полосы внутренняя сторона — своя полоса, а её на 5–16 м
    # часто закрывает машина впереди или отражение в стекле: судим по внешней.
    side_min = outer if abs(l["x_ref"]) < OWN_X else min(la, ra)
    if side_min < SIDE_PAINT:
        return None, "асфальт с одной стороны мало"
    if l["contrast"] is None or l["contrast"] < CONTRAST:
        return None, "контраст"
    if not kinds:
        return None, "заполнение"
    if solid >= 0.5:
        return "solid", "по заполнению"
    if l["dash"] is False:
        return None, "обрывки, не штрихи"
    return "dashed", "по заполнению"
