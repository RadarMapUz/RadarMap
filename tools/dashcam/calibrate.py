#!/usr/bin/env python3
"""Калибровка и честные замеры точности.

    python3 calibrate.py anchors   — точность привязки на камерах фиксации:
        каждая опора (проезд камеры из GPX) по очереди прячется, модель
        строится без неё, и точка машины в момент проезда сравнивается с
        координатой камеры из cameras.json. Это и есть ошибка «где был кадр».
    python3 calibrate.py accuracy [DB] — точность ДО/ПОСЛЕ поправки времени
        wpt (passtime): камеры фиксации (выброс опоры, точка машины в
        ИСПРАВЛЕННЫЙ момент проезда против камеры из cameras.json, для
        модели с сырыми и с исправленными опорами) и светофоры (кластеры
        «подтверждает» против highway=traffic_signals OSM).
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


def _q(xs, k):
    xs = sorted(xs)
    return round(xs[int(k * (len(xs) - 1))], 1) if xs else None


def _dist_stats(errs):
    if not errs:
        return {'n': 0}
    return {'n': len(errs), 'median_m': round(statistics.median(errs), 1), 'p75_m': _q(errs, 0.75),
            'p90_m': _q(errs, 0.9), 'share_le_12m': round(sum(e <= 12 for e in errs) / len(errs), 3),
            'share_le_25m': round(sum(e <= 25 for e in errs) / len(errs), 3),
            'share_le_100m': round(sum(e <= 100 for e in errs) / len(errs), 3)}


def camera_accuracy(conn, log=print):
    """Камеры фиксации, честно: опора проезда прячется, модель строится без неё,
    точка машины в ИСПРАВЛЕННЫЙ момент проезда (passtime) сравнивается с камерой
    базы (cameras.json, id из имени wpt). Две модели на одних и тех же проездах:
    «до» — опоры по сырому времени wpt (как было), «после» — по исправленному.
    Дополнительно «до, в момент wpt» — как это мерил прежний anchors_accuracy
    (модель сама с собой согласна, а с жизнью — нет)."""
    import passtime
    trks, wpts = geo.load_all_trips(selfcam.ALL_TRIPS_GPX)
    cams = {c['id']: c for c in selfcam.load_cameras()}
    osrm = geo.OSRM(conn)
    keys = [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM frames')]
    before, after, before_wpt = [], [], []
    for k in keys:
        trip = catalog.get_trip(conn, k)
        if trip is None:
            continue
        t0, t1 = trip['start'], trip['end']
        speed = sync.clean_ocr(catalog.ocr_series(conn, k))
        raw = geo.anchors_for(wpts, t0, t1)
        fixed = passtime.correct(raw, passtime.Odo(speed))      # (t_pass, lat, lon, name, t_wpt)
        new = geo.anchors_for([a[:4] for a in fixed], t0, t1)
        t_pass = {(a[3], a[4]): a[0] for a in fixed}
        for j in range(1, len(new) - 1):
            a = new[j]
            m = re.search(r'камера (\d+)', a[3])
            cam = cams.get(int(m.group(1))) if m else None
            if cam is None:
                continue
            t_wpt = next((w for (n, w), tp in t_pass.items() if n == a[3] and tp == a[0]), None)
            ri = next((i for i, w in enumerate(raw) if w[3] == a[3] and w[0] == t_wpt), None)
            if ri is None or ri == 0 or ri == len(raw) - 1:
                continue                                      # сравниваем только общие внутренние
            g_new = geo.build_trip_geo(t0, t1, speed, new[:j] + new[j + 1:], trks, osrm, release=False)
            g_old = geo.build_trip_geo(t0, t1, speed, raw[:ri] + raw[ri + 1:], trks, osrm, release=False)
            p_new, p_old, p_old_w = g_new.locate(a[0]), g_old.locate(a[0]), g_old.locate(t_wpt)
            if p_new is None or p_old is None:
                continue
            after.append(gpx.haversine(p_new[0], p_new[1], cam['lat'], cam['lon']))
            before.append(gpx.haversine(p_old[0], p_old[1], cam['lat'], cam['lon']))
            if p_old_w is not None:
                before_wpt.append(gpx.haversine(p_old_w[0], p_old_w[1], cam['lat'], cam['lon']))
        log(k, len(after))
    out = {'before': _dist_stats(before), 'after': _dist_stats(after),
           'before_at_wpt_time': _dist_stats(before_wpt), 'osrm_requests': osrm.requests}
    log(json.dumps(out, ensure_ascii=False))
    return out


def light_accuracy(conn):
    """Светофоры: доля «подтверждает» среди кластеров светофоров и расстояние до
    ближайшего highway=traffic_signals OSM (у «подтверждает» и у всех, с отсечкой)."""
    sig = cluster.PointIndex(cluster.load_points()['traffic_signals'])
    rows = conn.execute("SELECT * FROM clusters WHERE cls='traffic_light'").fetchall()
    out = {}
    for name, sel in (('all', rows), ('trips2', [r for r in rows if r['n_trips'] >= 2])):
        conf, near = [], []
        for r in sel:
            hit = sig.nearest(r['lat'], r['lon'], 200.0)
            d = hit[0] if hit else 200.0
            near.append(d)
            if r['status'] == 'confirms':
                conf.append(d)
        out[name] = {'clusters': len(sel), 'confirms': len(conf),
                     'confirms_share': round(len(conf) / len(sel), 3) if sel else None,
                     'confirms_median_m': round(statistics.median(conf), 1) if conf else None,
                     'nearest_signal_median_m_cap200': round(statistics.median(near), 1) if near else None,
                     'share_le_30m': round(sum(d <= 30 for d in near) / len(near), 3) if near else None}
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
    if argv[0] == 'accuracy':
        paths = [a for a in argv[1:] if not a.startswith('--')]
        conn = catalog.connect(paths[0]) if paths else catalog.connect()
        out = {'lights': light_accuracy(conn)}
        if '--no-cams' not in argv:
            out['cameras'] = camera_accuracy(conn, log=lambda *a: None)
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return
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
