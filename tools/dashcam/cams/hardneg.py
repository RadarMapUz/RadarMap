#!/usr/bin/env python3
"""Жёсткие отрицательные: раунды «обучить → найти самые уверенные ложные
кадры вдали от камер → добавить их в «нет» → переобучить» (Create ML).

    python3 hardneg.py DATA_DIR NAME [--rounds 3] [--per-round 1500]

Ложный кадр — тот, что проходит правило отрицательных (passes.label_negative:
> 300 м пути от проездов GPX и > 300 м по месту от любой камеры базы), а
модель даёт ему ≥ 0,5. Берутся только train-поездки: val остаётся честным.
"""
import os
import shutil
import subprocess
import sys

import cmlpredict
import common
import dataset
import evaluate
import passes

BIN = os.path.join(common.OUT, 'bin', 'camnet')


def eligible_negatives(ctx, keys):
    out = []
    for key in keys:
        if key not in ctx.gp:
            continue
        odo = ctx.odo(key)
        pts = [t for t, _ in ctx.gp[key]]
        for f in ctx.by_trip.get(key, []):
            g = ctx.geo.get(f['id'])
            dist = ctx.grid.nearest_dist(g[0], g[1], 1000) if g else None
            if passes.label_negative(f['t'], f['kmh'], pts, odo, dist):
                out.append(f['id'])
    return out


def main(data, name, rounds=3, per_round=1500, log=print):
    ctx = evaluate.Ctx()
    split = ctx.split()
    train_keys = split['train']
    val_keys = split['val']
    paths = {r[0]: r[1] for r in ctx.sh.execute('SELECT id, path FROM frames')}
    have = {int(n.rsplit('_', 1)[1][:-4]) for n in os.listdir(os.path.join(data, 'train', 'none'))}
    elig = set(eligible_negatives(ctx, train_keys)) - have
    model = os.path.join(common.OUT, f'{name}_r0.mlmodel')
    res = subprocess.run([BIN, 'train', data, model, '80'], capture_output=True, text=True, check=True).stdout
    log('раунд 0', res.strip().splitlines()[-1])
    reps = []
    for r in range(1, rounds + 1):
        cmlpredict.run(model, f'{name}_tmp', trips=set(train_keys))
        prob = evaluate.model_prob(ctx.conn, f'{name}_tmp')
        hard = sorted((prob[i], i) for i in elig if prob.get(i, 0) >= 0.5)[::-1][:per_round]
        for _, fid in hard:
            key = ctx.fr[fid]['trip_key']
            dataset.crop(paths[fid], os.path.join(data, 'train', 'none', f'{key}_{fid}.jpg'))
            elig.discard(fid)
        model = os.path.join(common.OUT, f'{name}_r{r}.mlmodel')
        res = subprocess.run([BIN, 'train', data, model, '80'], capture_output=True, text=True, check=True).stdout
        log(f'раунд {r}: +{len(hard)} жёстких', res.strip().splitlines()[-1])
        cmlpredict.run(model, f'{name}_r{r}', trips=set(val_keys))
        rep = evaluate.report(ctx, evaluate.model_prob(ctx.conn, f'{name}_r{r}'), val_keys, f'{name}_r{r}')
        rep['hard_added'] = len(hard)
        common.save_report(ctx.conn, f'eval_{name}_r{r}', rep)
        reps.append(rep)
        for k in ('events_p0.5', 'events_p0.7', 'events_p0.9'):
            v = rep[k]
            log('  ', k, {x: v[x] for x in ('events', 'hit', 'fp', 'fp_db_cam', 'recall', 'precision', 'fp_per_10km')})
    with ctx.conn:
        ctx.conn.execute('DELETE FROM camprob WHERE model=?', (f'{name}_tmp',))
    return reps


if __name__ == '__main__':
    a = sys.argv
    rounds = int(a[a.index('--rounds') + 1]) if '--rounds' in a else 3
    per = int(a[a.index('--per-round') + 1]) if '--per-round' in a else 1500
    main(os.path.join(common.OUT, a[1]), a[2], rounds, per)
