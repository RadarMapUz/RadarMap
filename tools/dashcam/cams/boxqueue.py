#!/usr/bin/env python3
"""Очередь разметки рамкой с ИСПРАВЛЕННЫМ временем проездов.

Общая box_queue (selfcam.py boxqueue) построена от времени wpt — а wpt опаздывает
на ~740 м пути (passes.py), так что её кадры в основном без камеры. Здесь —
проверка старой очереди и новая: на каждый проезд до 2 кадров за 25–60 м пути
до исправленного момента проезда (камера крупно и ещё целиком в кадре).

    python3 boxqueue.py check    — где кадры общей очереди относительно настоящего проезда
    python3 boxqueue.py build    — новая очередь → cams.db box_queue_fixed + box_queue_fixed.json

Общую БД не трогаем (только чтение): заменить очередь в ней — решение владельца
(SQL в отчёте: DELETE FROM box_queue; INSERT … FROM box_queue_fixed).
"""
import json
import os
import sys

import common
import evaluate

DIST = (25.0, 60.0)
TARGET = 38.0


def check(log=print):
    ctx = evaluate.Ctx()
    q = [dict(r) for r in ctx.sh.execute('SELECT frame_id, camera_id, trip_key FROM box_queue')]
    out = {'n': len(q), 'within_15_70m_before_true_pass': 0, 'no_pass': 0}
    for r in q:
        f = ctx.fr.get(r['frame_id'])
        tps = [t for t, c in ctx.gp.get(r['trip_key'], []) if c == r['camera_id']]
        if not f or not tps:
            out['no_pass'] += 1
            continue
        odo = ctx.odo(r['trip_key'])
        d = min((odo.at(tp) - odo.at(f['t']) for tp in tps), key=abs)
        if 15 <= d <= 70:
            out['within_15_70m_before_true_pass'] += 1
    log(out)
    return out


def build(per_pass=2, log=print):
    ctx = evaluate.Ctx()
    rows = []
    for key, tps in ctx.gp.items():
        odo = ctx.odo(key)
        frs = ctx.by_trip.get(key, [])
        for tp, cid in tps:
            cand = []
            for f in frs:
                if not (0 < tp - f['t'] < 10) or (f['kmh'] or 0) < 3:
                    continue
                d = odo.at(tp) - odo.at(f['t'])
                if DIST[0] <= d <= DIST[1]:
                    cand.append((abs(d - TARGET), f['id'], d))
            for _, fid, d in sorted(cand)[:per_pass]:
                rows.append((fid, 'camera', cid, round(d, 1), key))
    with ctx.conn:
        ctx.conn.execute('CREATE TABLE IF NOT EXISTS box_queue_fixed(frame_id INTEGER PRIMARY KEY, task TEXT, '
                         'camera_id INTEGER, dist_m REAL, trip_key TEXT)')
        ctx.conn.execute('DELETE FROM box_queue_fixed')
        ctx.conn.executemany('INSERT OR IGNORE INTO box_queue_fixed VALUES(?,?,?,?,?)', rows)
    with open(os.path.join(common.OUT, 'box_queue_fixed.json'), 'w') as f:
        json.dump([dict(zip(('frame_id', 'task', 'camera_id', 'dist_m', 'trip_key'), r)) for r in rows], f)
    log('новая очередь', len(rows))
    return len(rows)


if __name__ == '__main__':
    {'check': check, 'build': build}[sys.argv[1]]()
