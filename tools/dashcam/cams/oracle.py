#!/usr/bin/env python3
"""Опознание при ИДЕАЛЬНЫХ событиях: моменты проездов — из GPX (исправленные),
камеры спрятаны. Потолок для HMM: если даже так цепочка не сходится верно,
классификатор её не спасёт.

    python3 oracle.py [--wpt]   — --wpt: как раньше, время wpt без поправки
"""
import json
import sys

import common
import geo
import hmm
import passes


def main(use_wpt=False, log=print):
    sh, conn = common.shared(), common.own()
    cams = common.cameras()
    idx = hmm.index(cams)
    osrm = geo.OSRM(conn)
    tot = {'trips': 0, 'events': 0, 'claimed': 0, 'correct': 0}
    per = []
    for trip in common.trips_with_frames(sh):
        key = trip['key']
        gp = conn.execute('SELECT camera_id, t_wpt, t_pass FROM gt_passes WHERE trip_key=? ORDER BY t_pass',
                          (key,)).fetchall()
        odo = passes.Odo(common.speed_series(sh, key))
        ev = []
        for g in gp:
            t = g['t_wpt'] if use_wpt else g['t_pass']
            if ev and t - ev[-1][0] < 2:      # две камеры на одной опоре — одно событие
                ev[-1][2].add(g['camera_id'])
                continue
            ev.append((t, 1.0, {g['camera_id']}))
        if len(ev) < 3:
            continue
        res = hmm.identify([(t, p) for t, p, _ in ev], odo.at, idx, osrm)
        truth = {t: ids for t, _, ids in ev}
        got = [(t, cams[j]['id']) for t, j, _ in res['anchors']]
        ok = sum(1 for t, cid in got if cid in truth.get(t, ()))
        per.append({'trip': key, 'status': res['status'], 'events': len(ev), 'claimed': len(got), 'correct': ok})
        tot['trips'] += 1
        tot['events'] += len(ev)
        tot['claimed'] += len(got)
        tot['correct'] += ok
        log(key, res['status'], f'событий {len(ev)}, заявлено {len(got)}, верно {ok}', 'OSRM', osrm.requests)
    log(tot)
    return {'total': tot, 'trips': per, 'mode': 'wpt' if use_wpt else 'pass'}


if __name__ == '__main__':
    w = '--wpt' in sys.argv
    out = main(w)
    common.save_report(common.own(), 'oracle_wpt' if w else 'oracle', out)
    print(json.dumps(out['total'], ensure_ascii=False))
