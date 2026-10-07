#!/usr/bin/env python3
"""Обучающая выборка «камера близко / нет» — без человека.

    python3 dataset.py build      — отобрать кадры (positives/negatives) → cams.db + каталог
    python3 dataset.py sheet N    — контактные листы N случайных положительных (проверка глазами)

Положительные: 0,5–3 с и 8–70 м пути до ИСПРАВЛЕННОГО момента проезда камеры
из GPX (passes.py). Отрицательные: те же поездки, > 300 м пути от любого
проезда и > 300 м по месту (frame_geo) от любой камеры базы, на ходу.
Train/val — по поездкам.

Картинка для классификатора — верхняя часть кадра до горизонта (камера висит
над дорогой; машины и асфальт — шум), см. CROP_*.
"""
import json
import os
import random
import shutil
import sys

import common
import passes

DATA = os.path.join(common.OUT, os.environ.get('CAMS_DATA', 'data'))
NEG_PER_POS = 2
# Кадр детекторов 1280×529 (исходный 1920×1080 без верхних 70 px, масштаб 2/3);
# горизонт ≈ 615 px исходного → (615−70)·2/3 ≈ 363. Берём чуть ниже горизонта.
CROP_BOTTOM = 380

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples(
  frame_id INTEGER PRIMARY KEY, trip_key TEXT, t REAL, label TEXT, split TEXT,
  camera_id INTEGER, dt REAL, dist_m REAL, path TEXT, rejected INTEGER DEFAULT 0);
"""


def crop(src, dst):
    from PIL import Image
    im = Image.open(src)
    im.crop((0, 0, im.width, min(CROP_BOTTOM, im.height))).save(dst, quality=90)


def select(sh, conn, log=print):
    cams = common.cameras()
    grid = passes.CamGrid(cams)
    rows = []
    for trip in common.trips_with_frames(sh):
        key = trip['key']
        gp = conn.execute('SELECT camera_id, t_pass FROM gt_passes WHERE trip_key=?', (key,)).fetchall()
        if not gp:
            continue
        odo = passes.Odo(common.speed_series(sh, key))
        geo = {r['frame_id']: r for r in conn.execute(
            'SELECT frame_id, lat, lon FROM frame_geo WHERE trip_key=?', (key,))}
        pts = [g['t_pass'] for g in gp]
        pos, neg = [], []
        for f in common.trip_frames(sh, key):
            hit = None
            for g in gp:
                if passes.label_positive(f['t'], f['kmh'], g['t_pass'], odo):
                    hit = g
                    break
            if hit:
                pos.append((f, hit['camera_id'], hit['t_pass'] - f['t'],
                            odo.at(hit['t_pass']) - odo.at(f['t'])))
                continue
            gg = geo.get(f['id'])
            dist = grid.nearest_dist(gg['lat'], gg['lon'], 1000) if gg else None
            if passes.label_negative(f['t'], f['kmh'], pts, odo, dist):
                neg.append(f)
        rows.append((key, pos, neg, len(gp)))
        log(key, 'проездов', len(gp), 'положительных', len(pos), 'отрицательных', len(neg))
    return rows


def build(log=print, seed=7):
    sh, conn = common.shared(), common.own()
    conn.executescript(SCHEMA)
    rows = select(sh, conn, log)
    split = passes.split_by_trip([r[0] for r in rows if r[1]], seed=seed)
    rnd = random.Random(seed)
    shutil.rmtree(DATA, ignore_errors=True)
    out, counts = [], {}
    for key, pos, neg, _ in rows:
        if key not in split:
            continue
        s = split[key]
        rnd.shuffle(neg)
        neg = neg[:NEG_PER_POS * len(pos)]
        items = [(f, 'camera', cid, dt, d) for f, cid, dt, d in pos] + [(f, 'none', None, None, None) for f in neg]
        for f, lab, cid, dt, d in items:
            dd = os.path.join(DATA, s, lab)
            os.makedirs(dd, exist_ok=True)
            dst = os.path.join(dd, f"{key}_{f['id']}.jpg")
            crop(f['path'], dst)
            out.append((f['id'], key, f['t'], lab, s, cid, dt, d, dst))
            counts[f'{s}/{lab}'] = counts.get(f'{s}/{lab}', 0) + 1
    with conn:
        conn.execute('DELETE FROM samples')
        conn.executemany('INSERT INTO samples(frame_id, trip_key, t, label, split, camera_id, dt, dist_m, path) '
                         'VALUES(?,?,?,?,?,?,?,?,?)', out)
    info = {'counts': counts, 'trips': {v: sorted(k for k in split if split[k] == v) for v in ('train', 'val')},
            'passes_with_pos': sum(1 for r in rows for _ in [0] if r[1])}
    with open(os.path.join(DATA, 'split.json'), 'w') as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    log(json.dumps(counts, ensure_ascii=False))
    return info


if __name__ == '__main__':
    if sys.argv[1] == 'build':
        build()
