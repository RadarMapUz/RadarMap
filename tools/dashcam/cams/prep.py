#!/usr/bin/env python3
"""Подготовка: исправленные проезды из GPX и место каждого кадра.

    python3 prep.py geo        — gt_passes + frame_geo для всех поездок с кадрами
    python3 prep.py lag        — проверка модели опоздания wpt по скорости

Место кадра строится тем же geo.build_trip_geo, что и в общем разборе, но
опоры — с исправленным временем (passes.pass_time). Маршруты OSRM — из своего
кэша (сначала копируется кэш общей БД: координаты опор те же, что и раньше).
"""
import statistics
import sys

import common
import geo
import passes


def copy_route_cache(sh, conn):
    rows = sh.execute('SELECT key, body, fetched FROM route_cache').fetchall()
    with conn:
        conn.executemany('INSERT OR IGNORE INTO route_cache(key, body, fetched) VALUES(?,?,?)',
                         [tuple(r) for r in rows])
    return len(rows)


def build_geo(log=print):
    sh, conn = common.shared(), common.own()
    log('кэш OSRM:', copy_route_cache(sh, conn))
    osrm = geo.OSRM(conn)
    trks, _ = common.all_trips()
    for trip in common.trips_with_frames(sh):
        key = trip['key']
        speed = common.speed_series(sh, key)
        odo = passes.Odo(speed)
        cw, info = common.corrected_wpts(trip, odo)
        g = geo.build_trip_geo(trip['start'], trip['end'], speed, cw, trks, osrm)
        frames = common.trip_frames(sh, key)
        rows = []
        for f in frames:
            p = g.locate(f['t']) if g.model else None
            if p:
                rows.append((f['id'], key, f['t'], p[0], p[1], p[2], p[3]))
        with conn:
            conn.execute('DELETE FROM gt_passes WHERE trip_key=?', (key,))
            conn.executemany('INSERT OR REPLACE INTO gt_passes VALUES(?,?,?,?,?,?,?)',
                             [(key,) + i for i in info])
            conn.execute('DELETE FROM frame_geo WHERE trip_key=?', (key,))
            conn.executemany('INSERT INTO frame_geo VALUES(?,?,?,?,?,?,?)', rows)
        log(key, 'проездов', len(info), 'кадров', len(frames), 'с местом', len(rows),
            g.summary().get('residual_median_m'))
    log('OSRM запросов', osrm.requests, 'из кэша', osrm.hits)


def lag_check(log=print):
    """Расхождение скорости wpt с OCR при разных допущениях о времени wpt."""
    sh = common.shared()
    res = {}
    for trip in common.trips_with_frames(sh):
        speed = common.speed_series(sh, trip['key'])
        odo = passes.Odo(speed)
        _, wpts = common.all_trips()
        for w in geo.anchors_for(wpts, trip['start'], trip['end']):
            cid, v = common.parse_wpt(w)
            if v is None or not odo.covers(w[0]):
                continue
            for name, radius in (('wpt=проезд', None), ('радиус 400', 400.0), ('радиус 600', 600.0),
                                 ('радиус 800', 800.0)):
                tp = w[0] if radius is None else passes.pass_time(odo, w[0], radius)
                if tp is None:
                    continue
                vs = [odo.speed(tp + d) for d in (-4, -3, -2, -1, 0, 1)]
                vs = [x for x in vs if x is not None]
                if vs:
                    res.setdefault(name, []).append(abs(min(vs) - v))
    out = {k: {'n': len(v), 'median_kmh': round(statistics.median(v), 1),
               'share_le5': round(sum(e <= 5 for e in v) / len(v), 3)} for k, v in res.items()}
    log(out)
    return out


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'geo'
    if cmd == 'geo':
        build_geo()
    elif cmd == 'lag':
        common.save_report(common.own(), 'lag_check', lag_check())
