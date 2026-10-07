"""Отбор кадров для ручной разметки сегментации — без утечки проверки.

    python3 seg_select.py          → ~/RadarMapBuild/dashcam/lanes/labels/selection.json

Проверочная половина истины (truth.json, half=test) делится ПО ПОЕЗДКАМ,
поэтому из её поездок не берём ничего — ни окна истины, ни случайные окна
(все 30 «случайных» окон на диске как раз из проверочных поездок), ни
кадры БД: соседние кадры одной поездки похожи, и модель, видевшая ту же
улицу в то же утро, «подсказала» бы ответ проверке.

Что берём:
- окна полного fps поездок настройки (50 окон, 7 поездок): по 4 кадра
  на −1,5/−0,5/+0,5/+1,5 с от центра — через 1 с, чтобы работал перенос
  разметки с соседнего кадра по трекам. Кадр — чётный (window.py берёт
  каждый второй, предзаполнение есть только для них);
- кадры БД (раз в ~5 м пути) поездок, которых нет в истине совсем: по
  PER_TRIP равномерно по времени, на ходу, днём (средняя яркость дороги).
  Треков у них нет — предзаполнение по одному кадру (v1).

Порядок разметки — по кругам: сначала по одному кадру каждого окна,
поездки вперемешку, потом второй кадр… — если разметят только сотню,
она всё равно из всех поездок, а у кадров второго круга уже есть
размеченный сосед через секунду.
"""
import json
import os
import sqlite3

import numpy as np

from framesdb import DB, OUT
from seg_common import SELECTION, WIN, key_for

OFFSETS = (-1.5, -0.5, 0.5, 1.5)
PER_TRIP = 15
MIN_KMH = 20.0
MIN_LUMA = 55.0        # средняя яркость низа кадра: ночь и тоннели — мимо
STRIDE = 2


def test_trips(truth):
    return {r["trip"] for r in truth if r["half"] == "test"}


def window_frames(names, pts, pos, offsets=OFFSETS, stride=STRIDE):
    """Имена кадров окна, ближайших к pos + смещение, только с шагом stride."""
    idx = list(range(0, len(names), stride))
    out = []
    for off in offsets:
        k = min(idx, key=lambda i: abs(pts[i] - (pos + off)))
        if names[k] not in out:
            out.append(names[k])
    return out


def interleave(groups):
    """{группа: [элементы]} → по кругу: по одному из каждой группы."""
    keys = sorted(groups)
    out, i = [], 0
    while any(i < len(groups[k]) for k in keys):
        for k in keys:
            if i < len(groups[k]):
                out.append(groups[k][i])
        i += 1
    return out


def select(windows, truth, db_frames, per_trip=PER_TRIP):
    """Чистая логика отбора.

    windows: [{"win", "trip", "names", "pts", "pos"}] — окна на диске;
    truth: строки truth.json; db_frames: {trip: [(id, t, kmh, path, luma)]}.
    → список элементов {"key", "src", "trip", "win", "name", "frame_id", "path", "round"}.
    """
    banned = test_trips(truth)
    known = {r["trip"] for r in truth}
    banned_ids = {r["id"] for r in truth if r["half"] == "test"}
    # Окна: по кругам, внутри круга — поездки вперемешку.
    by_round = {}
    for w in windows:
        if w["trip"] in banned or w["win"] in banned_ids:
            continue
        for r, name in enumerate(window_frames(w["names"], w["pts"], w["pos"])):
            by_round.setdefault(r, {}).setdefault(w["trip"], []).append(
                {"key": key_for(win=w["win"], name=name), "src": "window", "trip": w["trip"],
                 "win": w["win"], "name": name, "frame_id": None, "path": None, "round": r})
    win_items = []
    for r in sorted(by_round):
        win_items += interleave(by_round[r])
    # Кадры БД — только поездок вне истины.
    db_groups = {}
    for trip, rows in db_frames.items():
        if trip in known or trip in banned:
            continue
        ok = [x for x in rows if x[2] is not None and x[2] >= MIN_KMH and x[4] >= MIN_LUMA]
        if not ok:
            continue
        take = np.unique(np.linspace(0, len(ok) - 1, min(per_trip, len(ok))).astype(int))
        db_groups[trip] = [{"key": key_for(frame_id=ok[i][0]), "src": "db", "trip": trip,
                            "win": None, "name": None, "frame_id": ok[i][0], "path": ok[i][3],
                            "round": n} for n, i in enumerate(take)]
    db_items = interleave(db_groups)
    # Кадры БД — между кругами окон: первые 100 размеченных уже из всех поездок.
    out, j = [], 0
    step = max(1, len(win_items) // max(1, len(db_items)))
    for i, it in enumerate(win_items):
        out.append(it)
        if (i + 1) % step == 0 and j < len(db_items):
            out.append(db_items[j])
            j += 1
    out += db_items[j:]
    return out


def road_luma(path):
    from PIL import Image
    im = Image.open(path).convert("L").crop((320, 400, 960, 529)).reduce(4)
    return float(np.asarray(im, np.float32).mean())


def main():
    from truth import load
    truth = load()
    trip_of = {r["id"]: r["trip"] for r in truth}
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    windows = []
    for d in sorted(os.listdir(WIN), key=int):
        fid = int(d)
        meta_p = os.path.join(WIN, d, "pts.json")
        if not os.path.exists(meta_p):
            continue
        trip = trip_of.get(fid) or con.execute("select trip_key from frames where id=?", (fid,)).fetchone()[0]
        with open(meta_p) as f:
            meta = json.load(f)
        names = sorted(n for n in os.listdir(os.path.join(WIN, d)) if n.startswith("f_"))
        windows.append({"win": fid, "trip": trip, "names": names, "pts": meta["pts"], "pos": meta["pos"]})
    known = {r["trip"] for r in truth}
    db_frames = {}
    for (trip,) in con.execute("select distinct trip_key from frames"):
        if trip in known:
            continue
        rows = con.execute("select id, t, kmh, path from frames where trip_key=? and kmh >= ? order by t",
                           (trip, MIN_KMH)).fetchall()
        # Яркость считаем только у кандидатов (берём втрое больше нужного).
        if not rows:
            continue
        cand = np.unique(np.linspace(0, len(rows) - 1, min(len(rows), PER_TRIP * 3)).astype(int))
        db_frames[trip] = [(*rows[i], road_luma(rows[i][3])) for i in cand]
    con.close()
    items = select(windows, truth, db_frames)
    os.makedirs(os.path.dirname(SELECTION), exist_ok=True)
    with open(SELECTION, "w") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    trips = {}
    for it in items:
        trips.setdefault(it["trip"], 0)
        trips[it["trip"]] += 1
    print(f"отобрано кадров: {len(items)} (окна: {sum(i['src'] == 'window' for i in items)}, "
          f"БД: {sum(i['src'] == 'db' for i in items)}), поездок: {len(trips)} → {SELECTION}")
    for t, n in sorted(trips.items()):
        print(f"  {t}: {n}")


if __name__ == "__main__":
    main()
