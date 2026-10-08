"""Разметка полос «классификацией кандидатов»: человек (или Claude) не
рисует пиксели, а решает про каждую линию-кандидата v2 — что это.

    python3 seg_selflabel.py cands               → selflabel/cands/<ключ>.json
    python3 seg_selflabel.py panel <ключ>...     → selflabel/panels/<ключ>.png
    python3 seg_selflabel.py apply [<ключ>...]   → labels/<ключ>.json (из решений)
    python3 seg_selflabel.py check <ключ>...     → selflabel/check/<ключ>.png (итог поверх кадра)
    python3 seg_selflabel.py audit N [seed]      → N случайных размеченных ключей
    python3 seg_selflabel.py stats
    python3 seg_selflabel.py export | import     ↔ selflabel_decisions.json (в репо)

Кандидаты кадра:
- кадр окна — ВСЕ треки v2 (window.analyze_window), принятые и отброшенные
  фильтрами (причина — в why), плюс края окна (бордюр/машины) и пики
  гистограммы этого кадра, не попавшие ни в один трек. Номер трека общий
  для всех кадров окна: решение по треку переносится на соседние кадры
  окна ПО ТРЕКУ (тот же номер — та же линия), это и есть перенос «T» из
  label_ui, только точнее — без пересчёта через общий сдвиг;
- кадр БД — v1 (lanes.analyze): принятые линии, отброшенные (lanes.DEBUG),
  края проезжей, пики гистограммы.
Геометрия — прямая на земле X = x + s·(Z − 8), как у предзаполнения; для
линий краски она уточняется по точкам пороговой маски этого кадра
(подгонка в сужающемся коридоре 0,5 → 0,2 м, с изгибом), иначе
остаётся прямой. Классификатор геометрию не трогает.

Решение — selflabel/decisions/<ключ>.json (ключ кадра или «w<окно>» —
общее для кадров окна):

    {"c": {"3": "dashed", "7": "curb"}, "synth": [{"side": "left", "cls": "dashed"}],
     "skip": false, "why": "...", "note": "..."}

Номер, которого нет в "c", — мусор. synth — пропущенная линия
(закрыта машиной/тенью): параллельно крайней принятой линии краски с этой
стороны со смещением на ширину соседней полосы (или 3,5 м, если ширину
не измерить); не больше одной с каждой стороны, у линии synthetic=true.
Решение кадра перекрывает решение окна целиком.
"""
import json
import os
import random
import sys
from multiprocessing import Pool

import numpy as np

from framesdb import OUT
from lanes import Z_LINES, Z_NEAR, Z_REF, load_camera, visible_z_range
from seg_common import LABELS, LINE_CLASSES, SELECTION, WIN, ground_line_to_jpg, image_path, \
    load_label, save_label

SL = os.path.join(OUT, "selflabel")
CANDS = os.path.join(SL, "cands")
PANELS = os.path.join(SL, "panels")
CHECK = os.path.join(SL, "check")
DEC = os.path.join(SL, "decisions")

LINE_Z1 = 22.0
EDGE_Z1 = 18.0
PEAK_MIN_DB = 6.0
PEAK_DUP = 0.5          # пик ближе к кандидату — тот же, не показываем
MAX_ABS_X = 10.0
REFINE_PASSES = ((0.5, False), (0.35, True), (0.2, True))
REFINE_MIN = 25
REFINE_SPAN = 5.0
REFINE_MAX_MOVE = 0.4
CURV_MAX = 0.003         # изгиб: радиус от ~170 м (на 22 м до 0,6 м от прямой)
GHOST_SNAP = 0.4         # трек окна не живёт в кадре — берём кандидата этого кадра ближе
SYNTH_W = 3.5
SYNTH_W_RANGE = (2.6, 4.6)   # измеренная ширина соседней полосы вне этого — берём 3,5
PAINT = ("solid", "dashed", "double")
CHOICES = (*LINE_CLASSES, "junk")


# ── геометрия ────────────────────────────────────────────────────────

def refine(X, Z, x, s, paint=True):
    """Коридор вокруг прямой x + s·(Z−8), сужающийся по проходам (0,5 →
    0,35 → 0,2 м), → коэффициенты (a, b, c) для X = a + b·d + c·d²,
    d = Z − 8, и дальность конца точек; None — точек мало (остаётся прямая).
    Изгиб — только если точки тянутся ≥ 10 м и есть дальше 14 м; изгиб
    ограничен CURV_MAX, и тогда a, b подгоняются заново при этом изгибе."""
    if not paint or X is None or len(X) == 0:
        return None
    a, b, c = x, s, 0.0
    sel = None
    for half, quad in REFINE_PASSES:
        d = Z - Z_REF
        sel = (np.abs(X - (a + b * d + c * d * d)) <= half) & (Z >= Z_NEAR) & (Z < Z_LINES)
        if sel.sum() < REFINE_MIN or np.ptp(Z[sel]) < REFINE_SPAN:
            return None
        dd, xx = d[sel], X[sel]
        if quad and np.ptp(Z[sel]) >= 10.0 and (Z[sel] > 14.0).sum() >= 15:
            c = float(np.clip(np.polyfit(dd, xx, 2)[0], -CURV_MAX, CURV_MAX))
        else:
            c = 0.0
        b, a = np.polyfit(dd, xx - c * dd * dd, 1)
    if abs(a - x) > REFINE_MAX_MOVE:
        return None
    return (float(a), float(b), float(c)), float(Z[sel].max())


def cand_geom(cam, x, s, z1, coef=None, zmax=None):
    vis = visible_z_range(cam, x)
    if vis is None:
        return None
    z0 = max(Z_NEAR + 0.5, vis[0])
    if coef is not None and zmax is not None:
        z1 = min(z1, max(zmax + 1.5, z0 + 4.0))
    if z0 >= z1 - 1.0:
        return None
    zs = np.array(sorted({z0, z1, *[z for z in (8.0, 10.0, 12.0, 14.0, 17.0, 20.0) if z0 < z < z1]}), float)
    a, b, c = coef if coef is not None else (x, s, 0.0)
    d = zs - Z_REF
    pts = ground_line_to_jpg(cam, a + b * d + c * d * d, zs)
    if len(pts) < 2:
        return None
    return {"pts": pts, "coef": [round(a, 3), round(b, 4), round(c, 5)], "z": [round(z0, 2), round(float(z1), 2)]}


def make_cand(cam, cid, x, s, hint, why, status, X=None, Z=None, kind="line"):
    paint = kind == "line"
    r = refine(X, Z, x, s, paint) if paint else None
    z1 = EDGE_Z1 if kind == "edge" else LINE_Z1
    g = cand_geom(cam, x, s, z1, *(r if r else (None, None)))
    if g is None:
        return None
    return {"id": cid, "x": round(float(x), 2), "s": round(float(s), 4), "hint": hint, "why": why,
            "status": status, "kind": kind, "refined": r is not None, **g}


def extra_peaks(X0, w, known, z_ok):
    from track import frame_peaks
    from window import EDGES, X_LIM
    h, _ = np.histogram(X0[z_ok], EDGES, weights=w[z_ok])
    out = []
    for x, _ in frame_peaks(list(h), -X_LIM, PEAK_MIN_DB):
        if abs(x) <= MAX_ABS_X and all(abs(x - k) >= PEAK_DUP for k in known):
            out.append(x)
    return out


# ── кандидаты ────────────────────────────────────────────────────────

_cam = None
_static = {}


def _init():
    global _cam
    _cam = load_camera()


def window_cands(win, trip, t, names_sel, cam, static):
    """→ {имя кадра: {"s", "cands"}}; номера треков общие по окну."""
    from track import track_x_at
    from window import analyze_window, load_window
    res = analyze_window(win, trip, t, cam, static, keep_debug=True)
    _, names, _, _ = load_window(win)
    data, cum, k_ref = res["_data"], res["_cum"], res["_k_ref"]
    lines = res["_lines"]
    # Номера треков — по поперечному положению в опорном кадре.
    order = sorted(range(len(lines)), key=lambda i: lines[i]["x_ref"])
    out = {}
    lk, lx = res["left_edge"]
    rk, rx = res["right_edge"]
    for name in names_sel:
        k = names.index(name) // 2
        f = data[k]
        s = f["s"]
        cands = []
        known = []
        for n, i in enumerate(order, 1):
            l = lines[i]
            tr = l["track"]
            # Трек не живёт в этом кадре — «призрак»: положение переносится
            # общим сдвигом кадров; на панели не рисуется, но решение по нему
            # переходит на кандидата этого кадра рядом (build_label).
            alive = tr["k"][0] - 2 <= k <= tr["k"][-1] + 2
            x = track_x_at(tr, k, cum)
            if abs(x) > MAX_ABS_X:
                continue
            kind = "edge" if l["kind"] == "edge" else "line"
            hint = {"solid": "solid", "dashed": "dashed", "edge": "curb"}.get(l["kind"])
            status = ("v2" if l["kind"] else "rej") if alive else "ghost"
            c = make_cand(cam, n, x, s, hint, l["why"], status, f["X"], f["Z"], kind)
            if c:
                cands.append(c)
                if alive:
                    known.append(x)
        nid = len(order)
        for kind_, x0, side in ((lk, lx, "L"), (rk, rx, "R")):
            nid += 1
            if x0 is None:
                continue
            x = x0 + cum[k] - cum[k_ref]
            c = make_cand(cam, nid, x, s, "curb" if kind_ == "curb" else None,
                          f"край {side}: {kind_}", "v2" if kind_ == "curb" else "rej", kind="edge")
            if c:
                cands.append(c)
                known.append(x)
        w = np.clip(f["Z"] / 8.0, 0.7, 1.6)
        z_ok = np.ones(len(f["X0"]), bool)
        nid = 100
        for x in extra_peaks(f["X0"], w, known, z_ok):
            nid += 1
            c = make_cand(cam, nid, x, s, None, "пик кадра", "peak", f["X"], f["Z"])
            if c:
                cands.append(c)
        out[name] = {"s": round(float(s), 4), "cands": cands,
                     "window": {"lanes": res["lanes"], "own": res["own"]}}
    return out


def db_cands(path, cam):
    import lanes
    from marking import load_rgb
    lanes.DEBUG.clear()
    res = lanes.analyze(load_rgb(path), cam)
    s = res["slope"]
    X, Z = res["points"]
    items = []
    for c, kind, fill, yel in res["lines"]:
        items.append((c, {"solid": "solid", "dashed": "dashed", "edge": "curb"}.get(kind),
                      f"v1 {kind} {fill}", "v2", "edge" if kind == "edge" else "line"))
    # v1 пишет отказ на каждом бине вокруг пика — схлопываем соседние.
    for d in lanes.DEBUG:
        if all(abs(d[0] - it[0]) >= PEAK_DUP for it in items):
            why = " ".join(str(round(v, 2) if isinstance(v, float) else v) for v in d[1:])
            items.append((d[0], None, "v1: " + why, "rej", "line"))
    side = res["side"]
    for key, strip in (("left_edge", "left_strip"), ("right_edge", "right_strip")):
        x = side.get(key)
        if x is not None and all(abs(x - it[0]) >= PEAK_DUP for it in items):
            st = side.get(strip)
            items.append((x, "curb" if st in ("бордюр", "газон", "ограждение") else None,
                          f"край: {st}", "v2" if st in ("бордюр", "газон", "ограждение") else "rej", "edge"))
    items = [it for it in items if abs(it[0]) <= MAX_ABS_X]
    items.sort(key=lambda it: it[0])
    cands = []
    for n, (x, hint, why, status, kind) in enumerate(items, 1):
        c = make_cand(cam, n, x, s, hint, why, status, X, Z, kind)
        if c:
            cands.append(c)
    sel = (Z >= Z_NEAR) & (Z < Z_LINES) & (np.abs(X) < 12.5)
    X0 = X[sel] - s * (Z[sel] - Z_REF)
    w = np.clip(Z[sel] / 8.0, 0.7, 1.6)
    nid = 100
    for x in extra_peaks(X0, w, [it[0] for it in items], np.ones(len(X0), bool)):
        nid += 1
        c = make_cand(cam, nid, x, s, None, "пик кадра", "peak", X, Z)
        if c:
            cands.append(c)
    return {"s": round(float(s), 4), "cands": cands}


def _job(job):
    import reflect
    try:
        if job[0] == "w":
            _, win, trip, t, names = job
            if trip not in _static:
                _static[trip] = reflect.load(trip)
            res = window_cands(win, trip, t, names, _cam, _static[trip])
            return [(f"w{win}_{os.path.splitext(n)[0]}", v) for n, v in res.items()]
        _, key, path = job
        return [(key, db_cands(path, _cam))]
    except Exception as e:  # одно окно не роняет прогон
        import traceback
        return [("error", {"job": str(job[:2]), "error": repr(e), "tb": traceback.format_exc()})]


def selection():
    with open(SELECTION) as f:
        return json.load(f)


def window_center_t(win, trip):
    import sqlite3
    from framesdb import DB
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        return con.execute("select t from frames where id=?", (win,)).fetchone()[0]
    finally:
        con.close()


def cmd_cands(force=False):
    sel = selection()
    os.makedirs(CANDS, exist_ok=True)
    wins = {}
    jobs = []
    for it in sel:
        if it["src"] == "window":
            wins.setdefault((it["win"], it["trip"]), []).append(it["name"])
    for (win, trip), names in sorted(wins.items()):
        if not force and all(os.path.exists(os.path.join(CANDS, f"w{win}_{os.path.splitext(n)[0]}.json"))
                             for n in names):
            continue
        jobs.append(("w", win, trip, window_center_t(win, trip), names))
    for it in sel:
        if it["src"] == "db" and (force or not os.path.exists(os.path.join(CANDS, it["key"] + ".json"))):
            jobs.append(("d", it["key"], it["path"]))
    print(f"заданий: {len(jobs)}", flush=True)
    errs = 0
    with Pool(6, initializer=_init) as pool:
        for res in pool.imap_unordered(_job, jobs):
            for key, obj in res:
                if key == "error":
                    errs += 1
                    print(obj["job"], obj["error"], flush=True)
                    continue
                path = os.path.join(CANDS, key + ".json")
                with open(path + ".tmp", "w") as f:
                    json.dump(obj, f, ensure_ascii=False)
                os.replace(path + ".tmp", path)
    print(f"готово, ошибок {errs} → {CANDS}")


def load_cands(key):
    with open(os.path.join(CANDS, key + ".json")) as f:
        return json.load(f)


# ── решения → разметка ────────────────────────────────────────────────

def win_key(key):
    return key.split("_")[0] if key.startswith("w") else None


def load_decision(key):
    for k in (key, win_key(key)):
        if k is None:
            continue
        p = os.path.join(DEC, k + ".json")
        if os.path.exists(p):
            with open(p) as f:
                d = json.load(f)
            d["_from"] = k
            return d
    return None


def synth_line(cam, accepted, side):
    """Пропущенная линия рядом с крайней принятой линией краски этой
    стороны: смещение — ширина соседней полосы (по двум крайним линиям),
    иначе 3,5 м. accepted — [(coef, z, cls)] линий краски. → (coef, z)."""
    if not accepted:
        return None
    by_x = sorted(accepted, key=lambda a: a[0][0])
    sign = -1 if side == "left" else 1
    edge = by_x[0] if side == "left" else by_x[-1]
    nxt = by_x[1] if side == "left" and len(by_x) > 1 else (by_x[-2] if len(by_x) > 1 else None)
    w = SYNTH_W
    if nxt is not None:
        ww = abs(edge[0][0] - nxt[0][0])
        if SYNTH_W_RANGE[0] <= ww <= SYNTH_W_RANGE[1]:
            w = ww
    a, b, c = edge[0]
    return (a + sign * w, b, c), edge[1]


def snap_ghost(g, cands, decided):
    """Решённый трек окна не живёт в этом кадре: кандидат этого кадра ближе
    GHOST_SNAP (и сам не решённый отдельно) — его геометрия; иначе — перенос
    общим сдвигом (геометрия призрака)."""
    near = [c for c in cands if c["status"] != "ghost" and str(c["id"]) not in decided
            and c["kind"] == g["kind"] and abs(c["x"] - g["x"]) <= GHOST_SNAP]
    if near:
        return min(near, key=lambda c: abs(c["x"] - g["x"]))
    for c in cands:
        if c["status"] != "ghost" and str(c["id"]) in decided and abs(c["x"] - g["x"]) <= GHOST_SNAP:
            return None      # на этом месте уже есть решённая линия
    return g


def build_label(key, item, dec, cands, cam):
    """Решение + кандидаты → разметка в формате label_ui (save_label)."""
    by_id = {str(c["id"]): c for c in cands["cands"]}
    lines, synth_flags = [], []
    paint = []
    for cid, cls in (dec.get("c") or {}).items():
        if cls == "junk":
            continue
        if cls not in LINE_CLASSES:
            raise ValueError(f"{key}: класс {cls}")
        c = by_id.get(str(cid))
        if c is None:
            continue
        if c["status"] == "ghost":
            c = snap_ghost(c, cands["cands"], dec.get("c") or {})
            if c is None:
                continue
        lines.append({"cls": cls, "pts": c["pts"]})
        synth_flags.append(False)
        if cls in PAINT:
            paint.append((tuple(c["coef"]), c["z"], cls))
    sides = [s["side"] for s in dec.get("synth") or []]
    if len(sides) != len(set(sides)):
        raise ValueError(f"{key}: больше одной досочинённой линии с одной стороны")
    for sy in dec.get("synth") or []:
        r = synth_line(cam, paint, sy["side"])
        if r is None:
            continue
        (a, b, c), z = r
        g = cand_geom(cam, a, b, z[1], (a, b, c), None)
        if g is None:
            continue
        lines.append({"cls": sy.get("cls", "dashed"), "pts": g["pts"]})
        synth_flags.append(True)
    origin = "transfer" if dec["_from"] != key else "manual"
    lab = {"key": key, "src": item["src"], "trip": item["trip"], "win": item["win"],
           "name": item["name"], "frame_id": item["frame_id"], "lines": lines, "boxes": [],
           "skip": bool(dec.get("skip")), "origin": origin}
    return lab, synth_flags


def cmd_apply(keys=None):
    cam = load_camera()
    sel = {it["key"]: it for it in selection()}
    keys = keys or list(sel)
    n = 0
    for key in keys:
        dec = load_decision(key)
        if dec is None or key not in sel:
            continue
        cands = load_cands(key)
        lab, synth = build_label(key, sel[key], dec, cands, cam)
        path = save_label(lab, LABELS)
        # save_label не знает про synthetic — дописываем флаг линиям
        # (validate пропускает только известные поля, поэтому после записи).
        with open(path) as f:
            saved = json.load(f)
        for ln, fl in zip(saved["lines"], synth):
            if fl:
                ln["synthetic"] = True
        saved["selflabel"] = {"decision": dec["_from"], "why": dec.get("why"), "note": dec.get("note")}
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(saved, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
        n += 1
    print(f"записано разметок: {n}")


# ── панели ───────────────────────────────────────────────────────────

FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
HINT_COL = {"solid": (255, 60, 60), "dashed": (60, 220, 255), "curb": (255, 170, 0),
            "double": (255, 230, 0)}
STATUS_GREY = {"rej": (150, 150, 150), "peak": (120, 200, 120)}
LAB_COL = {"solid": (255, 40, 40), "dashed": (40, 200, 255), "double": (255, 230, 0),
           "curb": (255, 140, 0)}


def _font(size):
    from PIL import ImageFont
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


_bev = {}


def bev_image(rgb, cam):
    from camera import bev_map, warp
    if id(cam) not in _bev:
        _bev[id(cam)] = bev_map(cam)
    rows, cols = _bev[id(cam)]
    return np.nan_to_num(warp(rgb.astype(np.float32), rows, cols)).clip(0, 255).astype(np.uint8)


BEV_ZMAX = 30.0


CROP_Y0 = 300           # полоса кадра с дорогой (строки 300…528), увеличение ×1,25
CROP_SC = 1.25
PANEL_W = 1600


def render(key, item, cands, cam, label=None, title=""):
    """Панель: (1) чистая полоса дороги кадра, (2) она же с кандидатами и
    крупными номерами (принятые v2 — цветом подсказки, отброшенные —
    серым, пики — зелёно-серым; label — итог толстыми линиями цвета класса,
    досочинённые — с лиловой каймой), (3) вид сверху чистый и с
    кандидатами + список кандидатов с причинами отказа."""
    from PIL import Image, ImageDraw
    from camera import JPG_H, RES, X_MIN, Z_MAX
    from marking import load_rgb
    from seg_common import jpg_to_ground
    rgb = load_rgb(image_path(item))
    u8 = rgb.clip(0, 255).astype(np.uint8)
    ch = JPG_H - CROP_Y0
    crop = Image.fromarray(u8[CROP_Y0:]).resize((PANEL_W, int(ch * CROP_SC)), Image.LANCZOS)
    over = crop.copy()
    bev_full = bev_image(rgb, cam)
    top = int((Z_MAX - BEV_ZMAX) / RES)
    xc0, xc1 = int((-10 - X_MIN) / RES), int((10 - X_MIN) / RES)
    bev_clean = Image.fromarray(bev_full[top:, xc0:xc1])
    bev = bev_clean.copy()
    fd, bd = ImageDraw.Draw(over), ImageDraw.Draw(bev)
    bcd = ImageDraw.Draw(bev_clean)

    def fpx(p):
        return (p[0] * CROP_SC, (p[1] - CROP_Y0) * CROP_SC)

    def bev_px(x, z):
        return ((x + 10) / RES, (BEV_ZMAX - z) / RES)

    for dr in (bd, bcd):
        for z in range(10, 31, 5):
            dr.line([bev_px(-10, z), bev_px(-9.4, z)], fill=(255, 255, 0), width=2)
            dr.text(bev_px(-9.3, z + 0.3), f"{z}", fill=(255, 255, 0), font=_font(13))
        for x in range(-10, 11, 2):
            dr.line([bev_px(x, 6), bev_px(x, 6.5)], fill=(255, 255, 0), width=2)
    for x in range(-10, 11, 1):
        bd.line([bev_px(x, 6), bev_px(x, BEV_ZMAX)], fill=(255, 255, 0) if x == 0 else (60, 60, 60), width=1)
    f_big, f_mid = _font(30), _font(22)

    def poly_bev(c):
        a, b, cc = c["coef"]
        z0, z1 = c["z"]
        zs = np.linspace(z0, min(z1, BEV_ZMAX), 20)
        d = zs - Z_REF
        return [bev_px(a + b * dd + cc * dd * dd, z) for dd, z in zip(d, zs)]

    def tag(draw, xy, text, col, font):
        x, y = xy
        bb = draw.textbbox((x, y), text, font=font, anchor="mm")
        draw.rectangle([bb[0] - 3, bb[1] - 2, bb[2] + 3, bb[3] + 2], fill=(0, 0, 0), outline=col, width=2)
        draw.text((x, y), text, fill=col, font=font, anchor="mm")

    def ccol(c):
        return STATUS_GREY.get(c["status"]) or HINT_COL.get(c["hint"], (230, 230, 230))

    cs = sorted((c for c in cands["cands"] if c["status"] != "ghost"), key=lambda c: c["x"])
    order = {"peak": 0, "rej": 1, "v2": 2}
    for c in sorted(cs, key=lambda c: order[c["status"]]):
        w = 2 if c["status"] != "v2" else 3
        fd.line([fpx(p) for p in c["pts"]], fill=ccol(c), width=w)
        bd.line(poly_bev(c), fill=ccol(c), width=w)
    if label is not None:
        for ln in label["lines"]:
            col = LAB_COL[ln["cls"]]
            pts = [fpx(p) for p in ln["pts"]]
            X, Z = jpg_to_ground(cam, ln["pts"])
            ok = np.isfinite(X) & np.isfinite(Z)
            bpts = [bev_px(x, z) for x, z in zip(X[ok], Z[ok])]
            if ln.get("synthetic"):
                fd.line(pts, fill=(255, 0, 255), width=11)
                if len(bpts) > 1:
                    bd.line(bpts, fill=(255, 0, 255), width=9)
            fd.line(pts, fill=col, width=6)
            if len(bpts) > 1:
                bd.line(bpts, fill=col, width=5)
    used = []
    H_OV = over.height
    for i, c in enumerate(cs):
        p = [fpx(q) for q in c["pts"]]
        best = None
        for ty in (H_OV - 25, H_OV - 60, H_OV - 95, H_OV - 130, H_OV - 160, H_OV - 190):
            for a, b in zip(p[:-1], p[1:]):
                if (a[1] - ty) * (b[1] - ty) <= 0 and a[1] != b[1]:
                    t = (ty - a[1]) / (b[1] - a[1])
                    xy = (a[0] + t * (b[0] - a[0]), ty)
                    if 20 < xy[0] < PANEL_W - 20 and all(abs(xy[0] - u[0]) > 46 or abs(xy[1] - u[1]) > 32
                                                        for u in used):
                        best = xy
                        break
            if best:
                break
        if best is None:
            best = (min(max(p[0][0], 20), PANEL_W - 20), min(p[0][1], H_OV - 20))
        used.append(best)
        tag(fd, best, str(c["id"]), ccol(c), f_big)
        a, b, cc = c["coef"]
        z = (9.0, 12.5, 16.0, 19.5)[i % 4]
        d = z - Z_REF
        tag(bd, bev_px(a + b * d + cc * d * d, z), str(c["id"]), ccol(c), f_mid)
    head = 34
    W = PANEL_W
    H = head + crop.height * 2 + 8 + bev.height
    out = Image.new("RGB", (W, H), (20, 20, 20))
    d = ImageDraw.Draw(out)
    d.text((8, 5), f"{key} · {item['trip']} · {title}", fill=(230, 230, 230), font=_font(22))
    out.paste(crop, (0, head))
    out.paste(over, (0, head + crop.height))
    y3 = head + crop.height * 2 + 8
    out.paste(bev_clean, (0, y3))
    out.paste(bev, (bev.width + 8, y3))
    tx = bev.width * 2 + 24
    ty = y3
    small = len(cs) > 20
    fl, fs = _font(19), _font(16)
    for c in cs:
        hint = c["hint"] if c["status"] == "v2" else c["status"]
        s = f"{c['id']:>3}  x={c['x']:+.1f}  {hint or '?':7s} {'уточн.' if c['refined'] else 'прямая'}  {c['why']}"
        d.text((tx, ty), s[:80], fill=ccol(c), font=fs if small else fl)
        ty += 19 if small else 22
    if label is not None:
        ty += 10
        d.text((tx, ty), "ИТОГ: " + ("SKIP" if label.get("skip") else ", ".join(
            ln["cls"] + ("(синт)" if ln.get("synthetic") else "") for ln in label["lines"])),
            fill=(255, 255, 255), font=fl)
    return out


def cmd_panel(keys, check=False):
    cam = load_camera()
    sel = {it["key"]: it for it in selection()}
    d = CHECK if check else PANELS
    os.makedirs(d, exist_ok=True)
    for key in keys:
        cands = load_cands(key)
        lab = load_label(key, LABELS) if check else None
        title = ""
        w = cands.get("window")
        if w:
            title = f"v2 окна: {w['lanes']}/{w['own']}"
        if check:
            dec = load_decision(key)
            title += f" · решение {dec['_from'] if dec else '—'}" + (" · SKIP" if lab and lab.get("skip") else "")
        img = render(key, sel[key], cands, cam, lab, title)
        p = os.path.join(d, key + ".png")
        img.save(p)
        print(p)


def labeled_keys():
    out = []
    for it in selection():
        lab = load_label(it["key"], LABELS)
        if lab is not None and not lab.get("skip"):
            out.append(it["key"])
    return out


def cmd_stats():
    sel = selection()
    done = skip = 0
    trips = set()
    synth = lines = 0
    cls = {}
    for it in sel:
        lab = load_label(it["key"], LABELS)
        if lab is None:
            continue
        if lab.get("skip"):
            skip += 1
            continue
        done += 1
        trips.add(it["trip"])
        for ln in lab["lines"]:
            lines += 1
            synth += bool(ln.get("synthetic"))
            cls[ln["cls"]] = cls.get(ln["cls"], 0) + 1
    print(json.dumps({"отбор": len(sel), "размечено": done, "skip": skip, "поездок": len(trips),
                      "линий": lines, "досочинено": synth, "классы": cls}, ensure_ascii=False))


EXPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "selflabel_decisions.json")


def cmd_export():
    """Все решения → один JSON в репо: разметку можно пересобрать из них
    (cands + apply), сами кадры в репозиторий не кладём."""
    out = {}
    for n in sorted(os.listdir(DEC)):
        if n.endswith(".json"):
            with open(os.path.join(DEC, n)) as f:
                out[n[:-5]] = json.load(f)
    with open(EXPORT, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=0, sort_keys=True)
    print(f"решений: {len(out)} → {EXPORT}")


def cmd_import():
    with open(EXPORT) as f:
        data = json.load(f)
    os.makedirs(DEC, exist_ok=True)
    for k, v in data.items():
        if not k[:1] in ("w", "d") or "/" in k or "." in k:
            continue
        with open(os.path.join(DEC, k + ".json"), "w") as f:
            json.dump(v, f, ensure_ascii=False)
    print(f"решений: {len(data)} → {DEC}")


def main():
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)
    if a[0] == "cands":
        cmd_cands("--force" in a)
    elif a[0] == "panel":
        cmd_panel(a[1:])
    elif a[0] == "check":
        cmd_panel(a[1:], check=True)
    elif a[0] == "apply":
        cmd_apply(a[1:] or None)
    elif a[0] == "audit":
        n = int(a[1])
        rng = random.Random(int(a[2]) if len(a) > 2 else 0)
        keys = labeled_keys()
        print(" ".join(rng.sample(keys, min(n, len(keys)))))
    elif a[0] == "stats":
        cmd_stats()
    elif a[0] == "export":
        cmd_export()
    elif a[0] == "import":
        cmd_import()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
