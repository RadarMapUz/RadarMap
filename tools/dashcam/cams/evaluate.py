#!/usr/bin/env python3
"""Оценка классификатора: по кадрам выборки и по событиям против GPX.

    python3 evaluate.py MODEL_NAME [--split val]   — по camprob (model=MODEL_NAME)
"""
import json
import statistics
import sys

import common
import events
import passes


class Ctx:
    """Всё, что нужно для оценки, читается один раз."""

    def __init__(self):
        self.sh, self.conn = common.shared(), common.own()
        self.fr = {r['id']: dict(r) for r in self.sh.execute('SELECT id, trip_key, t, kmh FROM frames')}
        self.gp = {}
        for r in self.conn.execute('SELECT trip_key, camera_id, t_pass FROM gt_passes ORDER BY t_pass'):
            self.gp.setdefault(r['trip_key'], []).append((r['t_pass'], r['camera_id']))
        self.geo = {r['frame_id']: (r['lat'], r['lon'], r['course']) for r in self.conn.execute(
            'SELECT frame_id, lat, lon, course FROM frame_geo')}
        self.samples = [dict(r) for r in self.conn.execute('SELECT frame_id, label, split, trip_key FROM samples')]
        self.grid = passes.CamGrid(common.cameras())
        self._odo = {}
        self.by_trip = {}
        for f in self.fr.values():
            self.by_trip.setdefault(f['trip_key'], []).append(f)
        for v in self.by_trip.values():
            v.sort(key=lambda f: f['t'])

    def odo(self, key):
        if key not in self._odo:
            self._odo[key] = passes.Odo(common.speed_series(self.sh, key))
        return self._odo[key]

    def split(self):
        import os
        with open(os.path.join(common.OUT, 'data', 'split.json')) as f:
            return json.load(f)['trips']

    def series(self, key, prob, min_kmh=5):
        return [(f['t'], prob[f['id']], f['id']) for f in self.by_trip.get(key, [])
                if f['id'] in prob and (f['kmh'] or 0) >= min_kmh]

    def truth(self, key):
        frs = self.by_trip.get(key, [])
        ts = [f['t'] for f in frs]
        import bisect
        out = []
        for t, ids in events.dedup_truth(self.gp.get(key, [])):
            i = bisect.bisect_left(ts, t - 4)
            if i < len(ts) and ts[i] <= t + 4:   # видео покрывает момент проезда
                out.append((t, ids))
        return out


def frame_eval(ctx, prob, split='val', thr=0.5):
    s = [x for x in ctx.samples if x['split'] == split and x['frame_id'] in prob]
    if not s:
        return None
    tp = sum(1 for x in s if x['label'] == 'camera' and prob[x['frame_id']] >= thr)
    npos = sum(1 for x in s if x['label'] == 'camera')
    tn = sum(1 for x in s if x['label'] == 'none' and prob[x['frame_id']] < thr)
    return {'n': len(s), 'acc': round((tp + tn) / len(s), 4), 'recall_camera': round(tp / max(1, npos), 4),
            'specificity': round(tn / max(1, len(s) - npos), 4)}


def event_eval(ctx, prob, keys, p_min=events.EVENT_P, tol_s=5.0, detail=False):
    res = {'truth': 0, 'events': 0, 'hit': 0, 'fp': 0, 'fp_db_cam': 0, 'km': 0.0}
    per, dts = {}, []
    for key in keys:
        odo = ctx.odo(key)
        evs = events.events_from_series(ctx.series(key, prob), odo, p_min=p_min)
        tt = [t for t, _ in ctx.truth(key)]
        pairs, extra, miss = events.match([e['t'] for e in evs], tt, tol_s)
        fp_db = sum(1 for i in extra if (g := ctx.geo.get(evs[i]['frame_id'])) and ctx.grid.near(g[0], g[1], 80))
        frs = ctx.by_trip.get(key, [])
        km = sum(odo.at(b['t']) - odo.at(a['t']) for a, b in zip(frs, frs[1:]) if b['t'] - a['t'] < 10) / 1000
        dts += [evs[i]['t'] - tt[j] for i, j in pairs]
        per[key] = {'truth': len(tt), 'events': len(evs), 'hit': len(pairs), 'fp': len(extra), 'fp_db_cam': fp_db,
                    'km': round(km, 1)}
        for k in ('truth', 'hit', 'fp', 'fp_db_cam'):
            res[k] += per[key][k]
        res['events'] += len(evs)
        res['km'] += km
    res['recall'] = round(res['hit'] / max(1, res['truth']), 3)
    res['precision'] = round(res['hit'] / max(1, res['events']), 3)
    # «Лишнее» событие у камеры базы, которой нет в wpt (wpt пишется только для
    # камер по курсу и на своей дороге), — камера там есть: видео не ошиблось.
    res['precision_db'] = round((res['hit'] + res['fp_db_cam']) / max(1, res['events']), 3)
    res['fp_per_10km'] = round(res['fp'] / max(0.1, res['km']) * 10, 2)
    res['dt_median_s'] = round(statistics.median(dts), 2) if dts else None
    res['km'] = round(res['km'], 1)
    if detail:
        res['per_trip'] = per
    return res


def model_prob(conn, name):
    return {r[0]: r[1] for r in conn.execute('SELECT frame_id, p FROM camprob WHERE model=?', (name,))}


def report(ctx, prob, keys, name):
    rep = {'model': name, 'frames_val': frame_eval(ctx, prob)}
    for pm in (0.5, 0.6, 0.7, 0.8, 0.9):
        rep[f'events_p{pm}'] = event_eval(ctx, prob, keys, p_min=pm)
    return rep


if __name__ == '__main__':
    name = sys.argv[1]
    ctx = Ctx()
    keys = ctx.split()['val']
    rep = report(ctx, model_prob(ctx.conn, name), keys, name)
    print(json.dumps(rep, ensure_ascii=False, indent=1))
    common.save_report(ctx.conn, f'eval_{name}', rep)
