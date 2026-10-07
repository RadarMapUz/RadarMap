#!/usr/bin/env python3
"""Векторы FeaturePrint для всех кадров (featx.swift, параллельно по частям).

    python3 features.py [--jobs 4]   — досчитать новые кадры → feats/<часть>.f32 + .ids

Хранится по частям: новые кадры (ночной разбор добавляет поездки) считаются
отдельной частью, старые не пересчитываются.
"""
import os
import subprocess
import sys
import time

import common

FEATS = os.path.join(common.OUT, 'feats')
FEATS_FINE = os.path.join(common.OUT, 'feats_fine')
FINE_REGIONS = 27   # 9×3 плитки 256×190, шаг 128×95 (featx.swift fine)
BIN = os.path.join(common.OUT, 'bin', 'featx')
SRC = os.path.join(common.HERE, 'featx.swift')
REGIONS = 4
DIM = 768


def ensure_bin():
    if os.path.exists(BIN) and os.path.getmtime(BIN) >= os.path.getmtime(SRC):
        return BIN
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    subprocess.run([common.SWIFTC, '-O', '-sdk', common.MACOS_SDK, SRC, '-o', BIN + '.new'], check=True)
    os.replace(BIN + '.new', BIN)
    return BIN


def done_ids(d=FEATS):
    ids = set()
    if os.path.isdir(d):
        for n in os.listdir(d):
            if n.endswith('.ids'):
                with open(os.path.join(d, n)) as f:
                    ids.update(int(x) for x in f.read().split())
    return ids


def run(jobs=4, log=print, only=None, fine=False):
    """only — множество id кадров (None — все); fine — мелкая сетка в FEATS_FINE."""
    ensure_bin()
    d = FEATS_FINE if fine else FEATS
    os.makedirs(d, exist_ok=True)
    sh = common.shared()
    have = done_ids(d)
    todo = [(r['id'], r['path']) for r in sh.execute('SELECT id, path FROM frames ORDER BY id')
            if r['id'] not in have and (only is None or r['id'] in only) and os.path.exists(r['path'])]
    log('кадров к расчёту', len(todo))
    if not todo:
        return 0
    stamp = time.strftime('%Y%m%d%H%M%S')
    procs = []
    for j in range(jobs):
        part = todo[j::jobs]
        if not part:
            continue
        base = os.path.join(d, f'{stamp}_{j}')
        with open(base + '.list', 'w') as f:
            f.write('\n'.join(p for _, p in part))
        with open(base + '.ids.tmp', 'w') as f:
            f.write('\n'.join(str(i) for i, _ in part))
        cmd = [BIN, base + '.list', base + '.f32'] + (['fine'] if fine else [])
        procs.append((subprocess.Popen(cmd, stderr=subprocess.DEVNULL), base))
    for p, base in procs:
        if p.wait() != 0:
            raise RuntimeError(f'featx упал: {base}')
        os.replace(base + '.ids.tmp', base + '.ids')
        os.remove(base + '.list')
    return len(todo)


def load(np, fine=False):
    """→ (ids: int64[N], X: float32[N, REGIONS, DIM]); fine — float16, 27 плиток."""
    d, R = (FEATS_FINE, FINE_REGIONS) if fine else (FEATS, REGIONS)
    ids, xs = [], []
    for n in sorted(os.listdir(d)):
        if not n.endswith('.ids'):
            continue
        base = os.path.join(d, n[:-4])
        with open(base + '.ids') as f:
            part = [int(x) for x in f.read().split()]
        x = np.fromfile(base + '.f32', dtype=np.float32).reshape(-1, R, DIM)
        if fine:
            x = x.astype(np.float16)
        assert len(x) == len(part), base
        ids += part
        xs.append(x)
    ids = np.array(ids, dtype=np.int64)
    X = np.concatenate(xs) if xs else np.zeros((0, R, DIM), np.float32)
    order = np.argsort(ids)
    return ids[order], X[order]


def fine_selection(n_neg=6000, seed=7):
    """Кадры для мелкой сетки: все кадры val-поездок (оценка по событиям), в
    train-поездках — окна проездов (−6…+1,5 с) и случайные n_neg прочих кадров."""
    import random
    import evaluate
    ctx = evaluate.Ctx()
    val = set(ctx.split()['val'])
    keep, rest = set(), []
    for key, frs in ctx.by_trip.items():
        if key not in ctx.gp:
            continue
        tps = [t for t, _ in ctx.gp[key]]
        for f in frs:
            if key in val or any(-1.5 <= tp - f['t'] <= 6 for tp in tps):
                keep.add(f['id'])
            else:
                rest.append(f['id'])
    random.Random(seed).shuffle(rest)
    return keep | set(rest[:n_neg])


if __name__ == '__main__':
    jobs = int(sys.argv[sys.argv.index('--jobs') + 1]) if '--jobs' in sys.argv else 4
    if '--fine' in sys.argv:
        sel = fine_selection()
        print('посчитано (мелкая сетка)', run(jobs, only=sel, fine=True))
    else:
        print('посчитано', run(jobs))
