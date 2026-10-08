#!/usr/bin/env python3
"""Знаки на карте: вырезки одного класса → трек → точка → объединение по поездкам.

    python3 signmap.py build [--trips K1,K2]   — sign_objects + sign_finds заново

Класс вырезки: подпись человека (sign_label_fix, иначе sign_crops.label) старше
классификатора; ответ классификатора берётся только с вероятностью ≥
signs.PRED_MIN. Место — по кадрам с ИСПРАВЛЕННОЙ привязкой (frames.lat/lon/course
после поправки времени wpt, passtime.py), а не по sign_crops.lat: те записаны
в момент детекции и после relocate устарели на ~700 м.

Трек и точка — тем же кодом, что у светофоров (objects.link_tracks,
objects.locate_track): лучи из точек машины пересекаются, при почти
параллельных лучах — расстояние по размеру рамки (знак ~0,7 м).

Сторона дороги: поперечное смещение знака от машины по курсу (вправо +).
Знак, смещённый влево больше OPPOSITE_LEFT_M, — за осью дороги, на встречной
стороне: он для встречного потока (лицом к нам его видно на развязках и
широких проспектах под углом), и наш манёвр он не регулирует — отбрасывается.
Знаки на разделительной своей проезжей части (дублирующие слева) ближе
этого порога и остаются.
"""
import argparse
import json
import math
import sys

import catalog
import gpx
import objects
import signs

# Классы, у которых есть смысл для карты (остальные — указатели, «другой
# знак», мусор — на карту не идут).
MAP_LABELS = ('crossing', 'keep_right', 'main_road', 'give_way', 'uturn', 'no_uturn', 'only_straight',
              'no_stopping', 'no_parking', 'speed_limit', 'radar_sign')
# Влево дальше этого — встречная сторона. Ось двусторонней городской дороги
# 2+2 полосы от машины в правом ряду — ~5–7 м, проспекта 3+3 с разделительной —
# 9–12 м; 12 м оставляет дублирующий знак на своей разделительной.
OPPOSITE_LEFT_M = 12.0
# Вправо дальше этого — уже не наша дорога (дублёр, двор), но знак может
# стоять за тротуаром и карманом: только помечаем.
FAR_RIGHT_M = 25.0
# Две находки одного класса и направления ближе — один знак. Больше, чем у
# светофоров (12 м): знак видно в 1–3 кадрах, место грубее.
SIGN_MERGE_M = 15.0
SIGN_COURSE_DEG = 60.0
MAX_ERR_M = 60.0


def label_of(eff, pred, conf, min_conf=signs.PRED_MIN):
    """Действующий класс вырезки → (класс, источник) или (None, None)."""
    if eff:
        return eff, 'human'
    if pred and conf is not None and conf >= min_conf:
        return pred, 'model'
    return None, None


def map_label(label):
    return label is not None and label.split(':')[0] in MAP_LABELS


def lateral(car_lat, car_lon, course, lat, lon):
    """Поперечное (вправо +) и продольное смещение точки от машины по курсу, м."""
    pl = objects.Plane(car_lat, car_lon)
    x, y = pl.xy(lat, lon)
    ux, uy = objects.unit(course)
    return x * uy - y * ux, x * ux + y * uy


def side_of(lat_m):
    if lat_m is None:
        return None
    if lat_m < -OPPOSITE_LEFT_M:
        return 'opposite'
    if lat_m > FAR_RIGHT_M:
        return 'far_right'
    return 'right' if lat_m >= 0 else 'left'


def trip_crops(conn, key):
    rows = conn.execute(
        'SELECT s.id, s.x, s.y, s.w, s.h, s.shape, s.value AS ocr_value, COALESCE(fx.label, s.label) AS eff, '
        'p.label AS pred, p.conf AS pconf, f.t, f.lat, f.lon, f.course, f.weight, f.id AS frame_id '
        'FROM sign_crops s JOIN frames f ON f.id=s.frame_id '
        'LEFT JOIN sign_label_fix fx ON fx.crop_id=s.id LEFT JOIN sign_pred p ON p.crop_id=s.id '
        'WHERE f.trip_key=? ORDER BY f.t', (key,)).fetchall()
    out = []
    for r in rows:
        lab, src = label_of(r['eff'], r['pred'], r['pconf'])
        if not map_label(lab):
            continue
        base, _, val = lab.partition(':')
        d = dict(r)
        d.update(cls=base, value=int(val) if val.isdigit() else r['ocr_value'], src=src,
                 conf=1.0 if src == 'human' else r['pconf'])
        out.append(d)
    return out


def build_trip(conn, key, lens=None):
    lens = lens or objects.Lens(**objects.load_calib())
    obs = trip_crops(conn, key)
    with conn:
        conn.execute('DELETE FROM sign_objects WHERE trip_key=?', (key,))
    located = [o for o in obs if o['lat'] is not None and o['course'] is not None]
    if not located:
        return 0
    odo = objects.odometer_for(conn, key)
    for o in located:
        o['dist'] = odo.at(o['t'])
    plane = objects.Plane(located[0]['lat'], located[0]['lon'])
    n = 0
    with conn:
        for tr in objects.link_tracks(located):
            loc = objects.locate_track(tr, lens, plane)
            if loc is None:
                continue
            ws = [o['weight'] for o in tr if o['weight'] is not None]
            w = sum(ws) / len(ws) if ws else 0.3
            loc['err_m'] = math.hypot(loc['err_m'], objects.LOC_ERR_BASE_M + objects.LOC_ERR_SPAN_M * (1 - w))
            near = max(tr, key=lambda o: max(o['w'], o['h']))   # ближайший кадр
            lat_m, _ = lateral(near['lat'], near['lon'], near['course'], loc['lat'], loc['lon'])
            src = 'human' if any(o['src'] == 'human' for o in tr) else 'model'
            conf = sum(o['conf'] for o in tr) / len(tr)
            conn.execute(
                'INSERT INTO sign_objects(trip_key, label, value, lat, lon, err_m, n_frames, method, weight, '
                'conf, course, lateral_m, side, source, crop_ids) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                (key, tr[0]['cls'], objects.majority([o['value'] for o in tr]), loc['lat'], loc['lon'],
                 loc['err_m'], len(tr), loc['method'], w, conf, near['course'], lat_m, side_of(lat_m), src,
                 json.dumps([o['id'] for o in tr])))
            n += 1
    return n


def _course_diff(a, b):
    d = abs((a - b) % 360)
    return min(d, 360 - d)


def object_quality(o):
    return (o['conf'] or 0) * (o['weight'] if o['weight'] is not None else 0.3) * min(1.0, (o['n_frames'] or 1) / 2)


def cluster_signs(objs, merge_m=SIGN_MERGE_M):
    """Объекты-знаки → находки: тот же класс и число, ближе merge_m, курс
    машины ± SIGN_COURSE_DEG (знаки двух направлений на одном столбе — разные)."""
    finds = []
    for o in sorted(objs, key=object_quality, reverse=True):
        best = None
        for f in finds:
            if f['label'] != o['label'] or f['value'] != o['value']:
                continue
            if _course_diff(f['course'], o['course']) > SIGN_COURSE_DEG:
                continue
            d = gpx.haversine(f['lat'], f['lon'], o['lat'], o['lon'])
            if d <= merge_m and (best is None or d < best[0]):
                best = (d, f)
        w = max(object_quality(o), 1e-3) / max(o['err_m'] or 10, 2) ** 2
        if best is None:
            finds.append({'label': o['label'], 'value': o['value'], 'lat': o['lat'], 'lon': o['lon'],
                          'course': o['course'], 'members': [o], 'wsum': w})
        else:
            f = best[1]
            f['lat'] = (f['lat'] * f['wsum'] + o['lat'] * w) / (f['wsum'] + w)
            f['lon'] = (f['lon'] * f['wsum'] + o['lon'] * w) / (f['wsum'] + w)
            f['wsum'] += w
            f['members'].append(o)
    for f in finds:
        m = f['members']
        f['n_trips'] = len({o['trip_key'] for o in m})
        f['n_frames'] = sum(o['n_frames'] or 1 for o in m)
        prod = 1.0
        for o in m:
            prod *= 1 - min(0.95, object_quality(o))
        f['confidence'] = 1 - prod
        errs = sorted(o['err_m'] or 10 for o in m)
        f['err_m'] = errs[len(errs) // 2] / math.sqrt(len(m))
        f['course'] = objects_course([o['course'] for o in m])
        sides = [o['side'] for o in m if o['side']]
        f['side'] = max(set(sides), key=sides.count) if sides else None
        f['human'] = int(any(o['source'] == 'human' for o in m))
    return finds


def objects_course(courses):
    x = sum(math.sin(math.radians(c)) for c in courses)
    y = sum(math.cos(math.radians(c)) for c in courses)
    return math.degrees(math.atan2(x, y)) % 360


def rebuild_finds(conn):
    objs = [dict(r) for r in conn.execute(
        "SELECT * FROM sign_objects WHERE lat IS NOT NULL AND err_m <= ? AND side IS NOT 'opposite'",
        (MAX_ERR_M,))]
    finds = cluster_signs(objs)
    stats = {}
    with conn:
        conn.execute('UPDATE sign_objects SET find=NULL')
        conn.execute('DELETE FROM sign_finds')
        for f in finds:
            cur = conn.execute(
                'INSERT INTO sign_finds(label, value, lat, lon, err_m, n_trips, n_frames, confidence, course, '
                'side, human, status, map_ref) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
                (f['label'], f['value'], f['lat'], f['lon'], f['err_m'], f['n_trips'], f['n_frames'],
                 f['confidence'], f['course'], f['side'], f['human'], None, None))
            conn.executemany('UPDATE sign_objects SET find=? WHERE id=?', [(cur.lastrowid, o['id'])
                                                                         for o in f['members']])
            stats[f['label']] = stats.get(f['label'], 0) + 1
    opp = conn.execute("SELECT COUNT(*) FROM sign_objects WHERE side='opposite'").fetchone()[0]
    return {'finds': len(finds), 'by_label': stats, 'opposite_dropped': opp}


def build(conn, keys=None, log=print):
    keys = keys or [r[0] for r in conn.execute('SELECT DISTINCT f.trip_key FROM sign_crops s '
                                               'JOIN frames f ON f.id=s.frame_id')]
    n = sum(build_trip(conn, k) for k in keys)
    st = rebuild_finds(conn)
    log(f'знаков-объектов {n}; находок: {json.dumps(st, ensure_ascii=False)}')
    return st


def main(argv=None):
    ap = argparse.ArgumentParser(description='Знаки на карте')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('build')
    p.add_argument('--trips')
    a = ap.parse_args(argv)
    conn = catalog.connect()
    if a.cmd == 'build':
        build(conn, a.trips.split(',') if a.trips else None)


if __name__ == '__main__':
    sys.exit(main())
