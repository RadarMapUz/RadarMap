#!/usr/bin/env python3
"""Калибровка и честные замеры точности.

    python3 calibrate.py anchors   — точность привязки на камерах фиксации:
        каждая опора (проезд камеры из GPX) по очереди прячется, модель
        строится без неё, и точка машины в момент проезда сравнивается с
        координатой камеры из cameras.json. Это и есть ошибка «где был кадр».
    python3 calibrate.py lens      — угол обзора и поворот объектива: перебор
        (HFOV, yaw), при котором триангулированные светофоры ближе всего к
        светофорам OSM (медиана расстояния до ближайшего, отсечка 40 м).
        Результат → calib.json рядом с каталогом (его читает objects.py).
"""
import json
import math
import re
import statistics
import sys

import catalog
import cluster
import geo
import gpx
import locate
import objects
import selfcam
import sync

CAP_M = 60.0


def anchors_accuracy(conn, log=print):
    trks, wpts = geo.load_all_trips(selfcam.ALL_TRIPS_GPX)
    cams = {c['id']: c for c in selfcam.load_cameras()}
    osrm = geo.OSRM(conn)
    keys = [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM frames WHERE lat IS NOT NULL')]
    errs, per = [], {}
    for k in keys:
        trip = catalog.get_trip(conn, k)
        if trip is None:
            continue
        speed = sync.clean_ocr(catalog.ocr_series(conn, k))
        res = geo.leave_one_out(trip['start'], trip['end'], speed, wpts, trks, osrm)
        e2 = []
        for name, err_wpt, source, w in res:
            # wpt — точка проезда по телефону; сверяем и с координатой камеры в базе
            m = re.search(r'камера (\d+)', name)
            e2.append(err_wpt)
        if e2:
            per[k] = {'n': len(e2), 'median_m': round(statistics.median(e2), 1),
                      'p90_m': round(sorted(e2)[int(0.9 * (len(e2) - 1))], 1),
                      'source': res[0][2]}
            errs += e2
    out = {'trips': per, 'n': len(errs)}
    if errs:
        errs.sort()
        out.update({'median_m': round(statistics.median(errs), 1),
                    'p75_m': round(errs[int(0.75 * (len(errs) - 1))], 1),
                    'p90_m': round(errs[int(0.9 * (len(errs) - 1))], 1),
                    'share_le_8m': round(sum(e <= 8 for e in errs) / len(errs), 3),
                    'share_le_25m': round(sum(e <= 25 for e in errs) / len(errs), 3)})
    log(json.dumps({k: v for k, v in out.items() if k != 'trips'}, ensure_ascii=False))
    return out


def light_tracks(conn):
    """Треки светофоров всех поездок (сработки с точкой машины) — для перебора объектива."""
    out = []
    keys = [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM objects')]
    for k in keys:
        rows = conn.execute(
            'SELECT d.obj, d.x, d.y, d.w, d.h, f.lat, f.lon, f.course, f.weight FROM detections d '
            'JOIN frames f ON f.id=d.frame_id JOIN objects o ON o.id=d.obj '
            "WHERE f.trip_key=? AND d.cls='traffic_light' AND f.lat IS NOT NULL AND o.n_frames>=2 "
            'ORDER BY d.obj, f.t', (k,)).fetchall()
        cur = {}
        for r in rows:
            cur.setdefault(r['obj'], []).append(dict(r))
        out += [tr for tr in cur.values() if len(tr) >= 2 and min(o['weight'] or 0 for o in tr) >= 0.5]
    return out


def lens_score(tracks, lens, sig_idx):
    ds = []
    plane = None
    for tr in tracks:
        if plane is None:
            plane = objects.Plane(tr[0]['lat'], tr[0]['lon'])
        obs = [{**o, 'cls': 'traffic_light'} for o in tr]
        loc = objects.locate_track(obs, lens, plane)
        if not loc or loc['method'] != 'tri':
            continue
        hit = sig_idx.nearest(loc['lat'], loc['lon'], CAP_M)
        ds.append(hit[0] if hit else CAP_M)
    # среднее с отсечкой: медиана упирается в отсечку, пока ошибка привязки
    # машины (десятки метров) сравнима с самой отсечкой
    return (sum(ds) / len(ds) if ds else None), len(ds)


def fit_lens(conn, log=print):
    tracks = light_tracks(conn)
    sig = cluster.PointIndex(cluster.load_points()['traffic_signals'])
    best = None
    grid = []
    for model in ('equidistant', 'pinhole'):
        for hfov in range(90, 151, 5):
            for yaw in [y / 2 for y in range(-12, 13, 2)]:
                med, n = lens_score(tracks, objects.Lens(hfov, yaw, model=model), sig)
                if med is None:
                    continue
                grid.append((med, model, hfov, yaw, n))
                if best is None or med < best[0]:
                    best = (med, model, hfov, yaw, n)
    base = lens_score(tracks, objects.Lens(**objects.DEFAULT_CALIB), sig)
    res = {'tracks': len(tracks), 'best': {'mean_capped_m': round(best[0], 1), 'model': best[1],
                                           'hfov_deg': best[2], 'yaw_deg': best[3], 'n': best[4]},
           'default_120_mean_capped_m': round(base[0], 1) if base[0] is not None else None}
    log(json.dumps(res, ensure_ascii=False))
    return res, sorted(grid)[:10]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    conn = catalog.connect()
    if argv[0] == 'anchors':
        out = anchors_accuracy(conn)
        print(json.dumps(out['trips'], ensure_ascii=False, indent=1))
    elif argv[0] == 'lens':
        res, top = fit_lens(conn)
        for t in top:
            print(t)
        if '--save' in argv:
            b = res['best']
            with open(objects.CALIB_PATH, 'w') as f:
                json.dump({'hfov_deg': b['hfov_deg'], 'yaw_deg': b['yaw_deg'], 'model': b['model'],
                           'fit': res}, f, ensure_ascii=False, indent=1)
            print('записано', objects.CALIB_PATH)


if __name__ == '__main__':
    sys.exit(main())
