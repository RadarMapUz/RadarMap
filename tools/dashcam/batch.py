#!/usr/bin/env python3
"""Пакетный разбор дневных поездок с карты регистратора — идемпотентно и
с возобновлением: всё состояние в dashcam.db, повторный запуск продолжает
с места (готовый ролик, OCR, кадры, привязка, детекторы не повторяются).

    python3 batch.py register [/dev/disk12s1]      — ролики карты → каталог
    python3 batch.py run [--trips K1,K2] [--limit N] [--stages ingest,geo,detect,objects]
    python3 batch.py cluster                       — объединение по поездкам + сверка
    python3 batch.py status

Ролик с карты копируется во временную папку, разбирается (OCR полосы,
кадры по пути) и удаляется: на диске остаются только кадры детекторов.
Перед каждым роликом проверяется свободное место — меньше MIN_FREE_GB
означает стоп с записью причины, а не забитый диск.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time
import traceback

import catalog
import frames as fr
import overlay
import sync

DEVICE = os.environ.get('DASHCAM_CARD', '/dev/disk12s1')
BASE = os.path.dirname(catalog.DB_PATH)
FRAMES_DIR = os.path.join(BASE, 'frames')
TMP_DIR = os.path.join(BASE, 'tmp')
ALL_TRIPS_GPX = os.path.join(BASE, 'all_trips.gpx')
CARD_PREFIX = 'card:'
MIN_FREE_GB = 10.0
# Дневная поездка: старт с 08:00 до 17:30 по местному времени.
DAY_FROM_MIN, DAY_TO_MIN = 8 * 60, 17 * 60 + 30
# Ролик BYD — 120 с на ~87,5 МБ; до ffprobe длительность оцениваем по размеру.
CLIP_SECONDS, CLIP_BYTES = 120.033, 87.55e6


class DiskLow(Exception):
    pass


def free_gb(path=BASE):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1e9


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


# ---------- регистрация роликов карты ----------

def register_card(conn, device=DEVICE):
    """Ролики Recorder/Normal карты → clips с путём 'card:…'. Ролик, который
    уже есть в каталоге под тем же именем (скопирован в M1), не дублируется."""
    import fat32
    have = {r[0] for r in conn.execute('SELECT name FROM clips')}
    new = 0
    with fat32.FAT32(device) as fs:
        rows = []
        for path, isdir, _cl, size, _st in fs.walk():
            name = path.rsplit('/', 1)[-1]
            if isdir or not path.startswith('Recorder/Normal/') or not name.endswith('.mp4'):
                continue
            if name in have:
                continue
            start = catalog.parse_clip_name(name)
            if start is None or size < 1_000_000:
                continue
            dur = min(CLIP_SECONDS, size / CLIP_BYTES * CLIP_SECONDS)
            rows.append((CARD_PREFIX + path, name, start, start, dur, size, 1920, 1080))
    with conn:
        for r in rows:
            cur = conn.execute('INSERT OR IGNORE INTO clips(path, name, name_start, start, duration, '
                               'size, width, height) VALUES(?,?,?,?,?,?,?,?)', r)
            new += cur.rowcount
    n = catalog.regroup(conn)
    return new, n


def is_day_trip(trip):
    lt = time.gmtime(trip['start'] + 5 * 3600)
    m = lt.tm_hour * 60 + lt.tm_min
    return DAY_FROM_MIN <= m <= DAY_TO_MIN


def day_trips(conn):
    rows = conn.execute('SELECT * FROM trips ORDER BY start DESC').fetchall()
    return [t for t in rows if is_day_trip(t)]


def has_anchors(conn, trip):
    """Есть ли у поездки опоры (трек all_trips с проездами камер в окне)."""
    return any(tr['path'].split('#')[0].endswith('all_trips.gpx') or tr['kind'] == 'anchored'
               for tr in catalog.tracks_for_trip(conn, trip))


def plan(conn):
    """Порядок разбора: сначала поездки с опорами (без них кадры не привязать
    к месту), внутри — от новых к старым; остальные — в конце."""
    trips = day_trips(conn)
    return [t for t in trips if has_anchors(conn, t)] + [t for t in trips if not has_anchors(conn, t)]


def set_stage(conn, key, stage, error=None):
    with conn:
        conn.execute('INSERT INTO batch_state(trip_key, stage, error, updated) VALUES(?,?,?,?) '
                     'ON CONFLICT(trip_key) DO UPDATE SET stage=excluded.stage, '
                     'error=excluded.error, updated=excluded.updated',
                     (key, stage, error, time.time()))


def get_stage(conn, key):
    r = conn.execute('SELECT stage FROM batch_state WHERE trip_key=?', (key,)).fetchone()
    return r[0] if r else None


# ---------- A. ролик: копия → ffprobe → OCR → кадры → удалить ----------

class Card:
    """Ленивое открытие карты и индекс «путь → (кластер, размер)»."""

    def __init__(self, device=DEVICE):
        self.device, self.fs, self.index = device, None, None

    def open(self):
        if self.fs is None:
            import fat32
            self.fs = fat32.FAT32(self.device)
            self.index = {p: (cl, size) for p, isdir, cl, size, _ in self.fs.walk() if not isdir}
        return self.fs

    def copy(self, card_path, dest):
        fs = self.open()
        if card_path not in self.index:
            raise FileNotFoundError(f'на карте нет {card_path}')
        cl, size = self.index[card_path]
        fs.copy(cl, size, dest)

    def close(self):
        if self.fs:
            self.fs.close()


def clip_state(conn, clip_id):
    r = conn.execute('SELECT * FROM clip_state WHERE clip_id=?', (clip_id,)).fetchone()
    if r is None:
        with conn:
            conn.execute('INSERT OR IGNORE INTO clip_state(clip_id) VALUES(?)', (clip_id,))
        r = conn.execute('SELECT * FROM clip_state WHERE clip_id=?', (clip_id,)).fetchone()
    return r


def clip_ocr_rows(conn, clip_id):
    return [(r[0], r[1]) for r in conn.execute(
        'SELECT t, kmh FROM ocr WHERE clip_id=? ORDER BY t', (clip_id,))]


def process_clip(conn, card, clip):
    st = clip_state(conn, clip['id'])
    if st['frames'] is not None and st['probed']:
        return 0
    if free_gb() < MIN_FREE_GB + clip['size'] / 1e9:
        raise DiskLow(f'свободно {free_gb():.1f} ГБ < {MIN_FREE_GB} ГБ — стоп')
    os.makedirs(TMP_DIR, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='clip_', dir=TMP_DIR)
    try:
        if clip['path'].startswith(CARD_PREFIX):
            local = os.path.join(tmp, clip['name'])
            card.copy(clip['path'][len(CARD_PREFIX):], local)
        else:
            local = clip['path']
            if not os.path.isfile(local):
                raise FileNotFoundError(local)
        if not st['probed']:
            info = catalog.probe(local)
            start = catalog.initial_start(clip['name_start'], info['duration'], info.get('end'))
            with conn:
                # OCR уже был (M1) — его старт точнее, не перетираем
                done = conn.execute('SELECT 1 FROM ocr_done WHERE clip_id=?', (clip['id'],)).fetchone()
                if done:
                    conn.execute('UPDATE clips SET duration=? WHERE id=?', (info['duration'], clip['id']))
                else:
                    conn.execute('UPDATE clips SET duration=?, start=?, width=?, height=? WHERE id=?',
                                 (info['duration'], start, info.get('width'), info.get('height'),
                                  clip['id']))
                conn.execute('UPDATE clip_state SET probed=1 WHERE clip_id=?', (clip['id'],))
        clip = conn.execute('SELECT * FROM clips WHERE id=?', (clip['id'],)).fetchone()
        overlay.ocr_clip(conn, clip, log=lambda *_: None, path=local)
        clip = conn.execute('SELECT * FROM clips WHERE id=?', (clip['id'],)).fetchone()
        n = 0
        if st['frames'] is None:
            prof = fr.speed_profile(clip_ocr_rows(conn, clip['id']), clip['duration'])
            pos = fr.select_positions(prof, clip['duration'])
            times = fr.frame_times(local)
            picks = fr.nearest_indices(times, pos)
            outdir = os.path.join(FRAMES_DIR, clip['trip_key'])
            paths = [os.path.join(outdir, fr.frame_name(clip['start'] + t)) for _, t in picks]
            n = fr.extract(local, [i for i, _ in picks], paths, tmp)
            rows = []
            for (i, t), p in zip(picks, paths):
                kmh = prof[min(int(t), len(prof) - 1)] if prof else None
                rows.append((clip['trip_key'], clip['id'], round(t, 3), clip['start'] + t, kmh, p))
            with conn:
                conn.executemany('INSERT OR IGNORE INTO frames(trip_key, clip_id, pos, t, kmh, path) '
                                 'VALUES(?,?,?,?,?,?)', rows)
                conn.execute('UPDATE clip_state SET frames=?, error=NULL WHERE clip_id=?',
                             (n, clip['id']))
        return n
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def ingest_trip(conn, card, key):
    clips = catalog.trip_clips(conn, key)
    total = 0
    for i, c in enumerate(clips):
        t = time.time()
        try:
            n = process_clip(conn, card, c)
        except DiskLow:
            raise
        except Exception as e:
            traceback.print_exc()
            with conn:
                conn.execute('UPDATE clip_state SET error=? WHERE clip_id=?', (str(e)[:500], c['id']))
            log(f'  ролик {c["name"]}: ошибка {e}')
            continue
        total += n
        if n:
            log(f'  {i + 1}/{len(clips)} {c["name"]}: {n} кадров, {time.time() - t:.0f} с, '
                f'свободно {free_gb():.1f} ГБ')
    catalog.regroup(conn)
    return total


# ---------- B. привязка кадров к месту ----------

_ALL = None


def all_trips_data():
    global _ALL
    if _ALL is None:
        import geo
        _ALL = geo.load_all_trips(ALL_TRIPS_GPX)
    return _ALL


def trip_geo(conn, key, osrm=None):
    import geo
    trip = catalog.get_trip(conn, key)
    trks, wpts = all_trips_data()
    speed = sync.clean_ocr(catalog.ocr_series(conn, key))
    osrm = osrm or geo.OSRM(conn)
    return geo.build_trip_geo(trip['start'], trip['end'], speed, wpts, trks, osrm), osrm


def geo_trip(conn, key):
    import json
    g, osrm = trip_geo(conn, key)
    summ = g.summary()
    rows = conn.execute('SELECT id, t FROM frames WHERE trip_key=?', (key,)).fetchall()
    upd = []
    located = 0
    for r in rows:
        p = g.locate(r['t'])
        if p is None:
            upd.append((None, None, None, None, None, r['id']))
        else:
            located += 1
            upd.append((p[0], p[1], p[2], p[3], p[4], r['id']))
    summ['frames'] = len(rows)
    summ['located'] = located
    summ['osrm_requests'] = osrm.requests
    shape = [[round(a, 6), round(b, 6)] for a, b in g.model.line.pts] if g.model else []
    anchors = ([{'t': a['t'], 'lat': a['lat'], 'lon': a['lon'], 'name': a['name'],
                 'used': a['used'], 'offset_m': round(a['offset_m'], 1)} for a in g.model.anchors]
               if g.model else [])
    with conn:
        conn.executemany('UPDATE frames SET lat=?, lon=?, course=?, weight=?, seg=? WHERE id=?', upd)
        conn.execute('DELETE FROM segments WHERE trip_key=?', (key,))
        conn.executemany('INSERT INTO segments(trip_key, idx, t0, t1, line_m, odo_m, residual_m, '
                         'reliable, source) VALUES(?,?,?,?,?,?,?,?,?)',
                         [(key, s['idx'], s['t0'], s['t1'], s['line_m'], s['odo_m'], s['residual_m'],
                           int(s['reliable']), g.source) for s in g.segments])
        conn.execute('INSERT OR REPLACE INTO trip_geo(trip_key, source, shape, anchors, summary, computed) '
                     'VALUES(?,?,?,?,?,?)', (key, g.source, json.dumps(shape), json.dumps(anchors),
                                            json.dumps(summ), time.time()))
    return summ


# ---------- оркестровка ----------

STAGES = ('ingest', 'geo', 'detect', 'objects')


def run(conn, keys=None, limit=None, stages=STAGES):
    card = Card()
    trips = plan(conn)
    if keys:
        trips = [t for t in trips if t['key'] in keys] + \
            [catalog.get_trip(conn, k) for k in keys if k not in {t['key'] for t in trips}
             and catalog.get_trip(conn, k)]
        order = {k: i for i, k in enumerate(keys)}
        trips.sort(key=lambda t: order.get(t['key'], 999))
    if limit:
        trips = trips[:limit]
    try:
        for trip in trips:
            key = trip['key']
            done = get_stage(conn, key)
            log(f'поездка {key} ({trip["n_clips"]} рол.), стадия {done or "—"}')
            try:
                if 'ingest' in stages:
                    n = ingest_trip(conn, card, key)
                    set_stage(conn, key, 'ingested')
                    log(f'  кадров новых: {n}')
                    key = _rekey(conn, trip)
                    # окна поездок уточнились — опоры раскладываем заново
                    if os.path.exists(ALL_TRIPS_GPX):
                        catalog.import_all_trips(conn, ALL_TRIPS_GPX, log=lambda *_: None)
                    for tr in catalog.tracks_for_trip(conn, catalog.get_trip(conn, key)):
                        sync.sync_trip(conn, key, tr['id'])
                if 'geo' in stages:
                    s = geo_trip(conn, key)
                    set_stage(conn, key, 'located')
                    log(f'  привязка: {s}')
                if 'detect' in stages:
                    import detect
                    n = detect.detect_trip(conn, key, log=log)
                    set_stage(conn, key, 'detected')
                    log(f'  детекторы: {n}')
                if 'objects' in stages:
                    import objects
                    n = objects.build_trip(conn, key)
                    set_stage(conn, key, 'objects')
                    log(f'  объекты: {n}')
            except DiskLow as e:
                set_stage(conn, key, 'stopped', str(e))
                log(f'СТОП: {e}')
                return False
            except Exception as e:
                traceback.print_exc()
                set_stage(conn, key, 'error', str(e)[:500])
                log(f'  ошибка поездки {key}: {e}')
    finally:
        card.close()
    return True


def _rekey(conn, trip):
    """После ffprobe/OCR границы поездок уточняются; ключ (первый ролик) обычно
    тот же, но если поездка слилась с соседней — берём ключ той, где теперь её ролики."""
    r = conn.execute('SELECT trip_key FROM clips WHERE name=?', (trip['key'] + '.mp4',)).fetchone()
    return r[0] if r else trip['key']


def status(conn):
    trips = day_trips(conn)
    st = {r[0]: (r[1], r[2]) for r in conn.execute('SELECT trip_key, stage, error FROM batch_state')}
    nfr = dict(conn.execute('SELECT trip_key, COUNT(*) FROM frames GROUP BY trip_key').fetchall())
    for t in trips:
        s = st.get(t['key'], ('—', None))
        print(f"{t['key']}  {t['n_clips']:3d} рол.  кадров {nfr.get(t['key'], 0):5d}  {s[0]}"
              + (f'  ({s[1]})' if s[1] else ''))
    print(f'дневных поездок {len(trips)}, свободно {free_gb():.1f} ГБ')


def main(argv=None):
    ap = argparse.ArgumentParser(description='Пакетный разбор видео регистратора')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('register')
    p.add_argument('device', nargs='?', default=DEVICE)
    p = sub.add_parser('run')
    p.add_argument('--trips')
    p.add_argument('--limit', type=int)
    p.add_argument('--stages', default=','.join(STAGES))
    sub.add_parser('cluster')
    sub.add_parser('status')
    a = ap.parse_args(argv)
    conn = catalog.connect()
    if a.cmd == 'register':
        new, n = register_card(conn, a.device)
        if os.path.exists(ALL_TRIPS_GPX):
            catalog.import_all_trips(conn, ALL_TRIPS_GPX, log=log)
        log(f'новых роликов с карты: {new}, поездок всего: {n}, дневных: {len(day_trips(conn))}')
    elif a.cmd == 'run':
        keys = a.trips.split(',') if a.trips else None
        ok = run(conn, keys, a.limit, tuple(a.stages.split(',')))
        return 0 if ok else 2
    elif a.cmd == 'cluster':
        import cluster
        print(cluster.rebuild(conn))
    elif a.cmd == 'status':
        status(conn)


if __name__ == '__main__':
    sys.exit(main())
