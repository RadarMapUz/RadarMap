"""Общее для сегментации полос: классы, формат разметки, пути, геометрия.

Разметка кадра — JSON в ~/RadarMapBuild/dashcam/lanes/labels/<key>.json:

    {"version": 1, "key": "w15474_f_0041", "src": "window"|"db",
     "win": 15474 | null, "name": "f_0041.jpg" | null, "frame_id": 15474 | null,
     "trip": "2026-09-26-12-48-06",
     "lines": [{"cls": "solid"|"dashed"|"double"|"curb", "pts": [[x, y], ...]}],
     "boxes": [{"cls": "car_parked"|"car_moving", "box": [x0, y0, x1, y1]}],
     "skip": false, "seconds": 41.5, "origin": "prefill"|"transfer"|"manual"|"pseudo",
     "saved": "2026-10-08T03:12:00"}

Координаты — пиксели кадра JPEG 1280×529 (тот же срез, что у frames.py
и clips.py), поэтому разметка не зависит от калибровки: калибровка нужна
только при переводе в маски (ширина линии в метрах) и на вид сверху.
Ключ кадра: w<окно>_<имя кадра> — кадр окна полного fps, d<id> — кадр из БД.
"""
import json
import os
import re
import time

import numpy as np

from camera import JPG_H, JPG_W, jpg_to_src, src_to_jpg
from framesdb import OUT

LABELS = os.path.join(OUT, "labels")
PREFILL = os.path.join(OUT, "prefill")
PSEUDO = os.path.join(OUT, "pseudo")
MODELS = os.path.join(OUT, "models")
WIN = os.path.join(OUT, "windows")
SELECTION = os.path.join(LABELS, "selection.json")

LINE_CLASSES = ("solid", "dashed", "double", "curb")
BOX_CLASSES = ("car_parked", "car_moving")
# Индексы классов маски. 255 — «не знаем»: в потерю не идёт.
CLASSES = ("bg", "solid", "dashed", "double", "curb", "road", "car_parked", "car_moving")
CLS = {c: i for i, c in enumerate(CLASSES)}
IGNORE = 255
# Ширина полосы маски на земле, м. Двойная — две линии по 0,15 с зазором
# 0,15: маска накрывает обе одной полосой.
WIDTH_M = {"solid": 0.15, "dashed": 0.15, "double": 0.45, "curb": 0.15}
MIN_HALF_PX = 1.0         # вдали 0,15 м < 1 px: полоса маски не тоньше 2 px

_KEY = re.compile(r"^(w\d+_f_\d{4}|d\d+)$")


def key_for(win=None, name=None, frame_id=None):
    if win is not None:
        return f"w{int(win)}_{os.path.splitext(name)[0]}"
    return f"d{int(frame_id)}"


def valid_key(key):
    return bool(_KEY.match(key or ""))


def validate(lab):
    """Разметка → (нормализованная копия, None) или (None, причина). Всё,
    что пришло со страницы, проходит здесь: классы из списка, точки в
    пределах кадра, числа — числа."""
    if not isinstance(lab, dict) or not valid_key(lab.get("key")):
        return None, "ключ"
    out = {"version": 1, "key": lab["key"], "lines": [], "boxes": [],
           "skip": bool(lab.get("skip", False))}
    for k in ("src", "trip", "name", "origin"):
        v = lab.get(k)
        out[k] = v if isinstance(v, str) and len(v) < 200 else None
    for k in ("win", "frame_id"):
        v = lab.get(k)
        out[k] = int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    sec = lab.get("seconds")
    out["seconds"] = round(float(sec), 1) if isinstance(sec, (int, float)) and 0 <= sec < 36000 else None
    for ln in lab.get("lines") or []:
        if not isinstance(ln, dict) or ln.get("cls") not in LINE_CLASSES:
            return None, "класс линии"
        pts = ln.get("pts")
        if not isinstance(pts, list) or len(pts) < 2 or len(pts) > 200:
            return None, "точки линии"
        clean = []
        for p in pts:
            if not (isinstance(p, list) and len(p) == 2 and all(isinstance(c, (int, float)) for c in p)):
                return None, "точка"
            x, y = float(p[0]), float(p[1])
            if not (-50 <= x <= JPG_W + 50 and -50 <= y <= JPG_H + 50):
                return None, "точка вне кадра"
            clean.append([round(x, 1), round(y, 1)])
        out["lines"].append({"cls": ln["cls"], "pts": clean})
    for b in lab.get("boxes") or []:
        if not isinstance(b, dict) or b.get("cls") not in BOX_CLASSES:
            return None, "класс рамки"
        bx = b.get("box")
        if not (isinstance(bx, list) and len(bx) == 4 and all(isinstance(c, (int, float)) for c in bx)):
            return None, "рамка"
        x0, y0, x1, y1 = (float(c) for c in bx)
        x0, x1 = sorted((x0, x1))
        y0, y1 = sorted((y0, y1))
        out["boxes"].append({"cls": b["cls"], "box": [round(x0, 1), round(y0, 1), round(x1, 1), round(y1, 1)]})
    return out, None


def save_label(lab, root=LABELS):
    """Проверка + атомарная запись. → путь."""
    clean, err = validate(lab)
    if clean is None:
        raise ValueError(f"разметка не принята: {err}")
    clean["saved"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    os.makedirs(root, exist_ok=True)
    path = os.path.join(root, clean["key"] + ".json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(clean, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return path


def load_label(key, root=LABELS):
    path = os.path.join(root, key + ".json")
    if not valid_key(key) or not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def all_labels(root=LABELS):
    if not os.path.isdir(root):
        return []
    out = []
    for n in sorted(os.listdir(root)):
        if n.endswith(".json") and valid_key(n[:-5]):
            with open(os.path.join(root, n)) as f:
                out.append(json.load(f))
    return out


def image_path(lab_or_item):
    """Путь к JPEG кадра по записи разметки/отбора."""
    if lab_or_item.get("win") is not None:
        return os.path.join(WIN, str(lab_or_item["win"]), lab_or_item["name"])
    if lab_or_item.get("path"):
        return lab_or_item["path"]
    # Разметка кадра БД пути не хранит (validate его не пропускает: путь со
    # страницы не берём) — берём из отбора по ключу.
    return _selection_paths()[lab_or_item["key"]]


_paths = None


def _selection_paths():
    global _paths
    if _paths is None:
        with open(SELECTION) as f:
            _paths = {it["key"]: it["path"] for it in json.load(f) if it.get("path")}
    return _paths


# ── геометрия: ломаная в кадре ↔ земля ───────────────────────────────

def ground_line_to_jpg(cam, X, Z):
    """Точки земли → [[x, y]] кадра JPEG; невидимые выкинуты."""
    u, v = cam.ground_to_src(np.asarray(X, float), np.asarray(Z, float))
    x, y = src_to_jpg(u, v)
    ok = np.isfinite(x) & np.isfinite(y) & (x >= -2) & (x <= JPG_W + 1) & (y >= 0) & (y <= JPG_H + 1)
    return [[round(float(a), 1), round(float(b), 1)] for a, b in zip(x[ok], y[ok])]


def jpg_to_ground(cam, pts):
    """[[x, y]] кадра → (X, Z) на земле (nan выше горизонта)."""
    p = np.asarray(pts, float).reshape(-1, 2)
    u, v = jpg_to_src(p[:, 0], p[:, 1])
    return cam.src_to_ground(u, v)


def densify(pts, step=2.0):
    """Ломаная кадра → точки через ~step px (для маски и переноса)."""
    p = np.asarray(pts, float).reshape(-1, 2)
    out = [p[:1]]
    for a, b in zip(p[:-1], p[1:]):
        n = max(1, int(np.ceil(np.hypot(*(b - a)) / step)))
        t = (np.arange(1, n + 1) / n)[:, None]
        out.append(a + (b - a) * t)
    return np.concatenate(out)


def straight_line(cam, x_ref, s, z0, z1=22.0, z_ref=8.0, mid=(8.0, 11.0, 15.0)):
    """Прямая на земле X = x_ref + s·(Z − z_ref), Z от z0 до z1 → узлы
    ломаной в кадре (до 5 узлов: человеку двигать мало, изгиб держат)."""
    zs = np.array(sorted({z0, z1, *[z for z in mid if z0 < z < z1]}), float)
    return ground_line_to_jpg(cam, x_ref + s * (zs - z_ref), zs)


def transfer_lines(cam, lines, shift, s_from, s_to, z_ref=8.0):
    """Перенос ломаных с кадра A на кадр B того же окна по трекам: на земле
    X0 = X − s_A·(Z − z_ref) сдвигается общим сдвигом кадров (shift = cum[B]
    − cum[A]) и снова наклоняется наклонкой B; Z остаётся (линия — линия)."""
    out = []
    for ln in lines:
        X, Z = jpg_to_ground(cam, ln["pts"])
        ok = np.isfinite(X) & np.isfinite(Z)
        if ok.sum() < 2:
            continue
        X, Z = X[ok], Z[ok]
        X2 = X - s_from * (Z - z_ref) + shift + s_to * (Z - z_ref)
        pts = ground_line_to_jpg(cam, X2, Z)
        if len(pts) >= 2:
            out.append({"cls": ln["cls"], "pts": pts})
    return out
