#!/usr/bin/env python3
"""Пакетный разбор дневных поездок с карты регистратора — идемпотентно и
с возобновлением: всё состояние в dashcam.db, повторный запуск продолжает
с места (готовый ролик, OCR, кадры, привязка, детекторы не повторяются).

    python3 batch.py register [/dev/disk12s1]      — ролики карты → каталог
    python3 batch.py run [--trips K1,K2] [--limit N] [--stages ingest,geo,detect,objects]
    python3 batch.py cluster                       — объединение по поездкам + сверка
    python3 batch.py status
    python3 batch.py relocate [--trips K1,K2]      — привязка кадров заново (поправка времени
                                                     wpt) → объекты → кластеры → покрытие

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


def trip_shape(conn, trip):
    """Оценка пути поездки до разбора: линия трека all_trips (или ломаная по опорам)."""
    for tr in catalog.tracks_for_trip(conn, trip):
        sh = catalog.track_shape(conn, tr['id'])
        if len(sh) >= 2:
            return sh
    return []


def plan(conn, pinned=None):
    """Порядок разбора — по новизне: сначала поездки с опорами и с наибольшим
    НЕзакреплённым путём; поездки целиком по закреплённым участкам — «повтор»
    (в конце списка, разбор их пропускает); без опор — в самом конце.
    → [(поездка, доля нового, длина нового м)]."""
    import coverage
    pinned = coverage.pinned_keys(conn) if pinned is None else pinned
    with_a, without = [], []
    for t in day_trips(conn):
        if not has_anchors(conn, t):
            without.append((t, 1.0, 0.0))
            continue
        nov, total = coverage.novelty(trip_shape(conn, t), pinned)
        with_a.append((t, nov, nov * total))
    with_a.sort(key=lambda x: -x[2])
    return with_a + without


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


# Лежачий полицейский: сильный рывок (сумма сдвигов строк за 1 с) на малой
# скорости — перед неровностью тормозят. На ходу 50+ км/ч рывки — обычная
# тряска дороги, их не берём.
JOLT_MIN_SCORE = 40
JOLT_MAX_KMH = 30


def jolt_clip(conn, clip, local):
    if conn.execute('SELECT 1 FROM jolt_done WHERE clip_id=?', (clip['id'],)).fetchone():
        return 0
    prof = fr.speed_profile(clip_ocr_rows(conn, clip['id']), clip['duration'])

    def speed_at(t):
        return prof[min(int(t), len(prof) - 1)] if prof else None
    try:
        profiles = fr.vertical_profile(local)
        times = fr.frame_times(local)
        n = min(len(profiles), len(times))
        ev = fr.jolts(times[:n], profiles[:n], speed_at, min_score=JOLT_MIN_SCORE)
    except Exception as e:  # рывки — второстепенное; ролик из-за них не теряем
        log(f'  рывки {clip["name"]}: {e}')
        ev = []
    ev = [(t, s) for t, s in ev if (speed_at(t) or 0) <= JOLT_MAX_KMH]
    with conn:
        conn.executemany('INSERT OR IGNORE INTO jolts(trip_key, clip_id, t, score, kmh) VALUES(?,?,?,?,?)',
                         [(clip['trip_key'], clip['id'], clip['start'] + t, s, speed_at(t)) for t, s in ev])
        conn.execute('INSERT OR REPLACE INTO jolt_done(clip_id, n) VALUES(?,?)', (clip['id'], len(ev)))
    return len(ev)


def clip_positions(conn, clip, keep=None):
    """Позиции кадров ролика по OCR (путь) → (все позиции, оставленные фильтром keep(t))."""
    prof = fr.speed_profile(clip_ocr_rows(conn, clip['id']), clip['duration'])
    pos = fr.select_positions(prof, clip['duration'])
    kept = [p for p in pos if keep is None or keep(clip['start'] + p)]
    return prof, pos, kept


def process_clip(conn, card, clip, ocr_only=False, keep=None):
    """Ролик: копия с карты → ffprobe → OCR полосы → кадры → удалить копию.
    ocr_only — только OCR (первый проход поездки с закреплёнными участками);
    keep(t) — какие моменты разбирать (False — участок закреплён, кадр не нужен).
    Если OCR уже есть и все кадры отфильтрованы — ролик даже не копируется."""
    st = clip_state(conn, clip['id'])
    if st['frames'] is not None and st['probed']:
        return 0
    ocr_done = conn.execute('SELECT 1 FROM ocr_done WHERE clip_id=?', (clip['id'],)).fetchone()
    if ocr_only and ocr_done and st['probed']:
        return 0
    if not ocr_only and ocr_done and st['probed'] and keep is not None:
        _, pos, kept = clip_positions(conn, clip, keep)
        if not kept:
            with conn:
                conn.execute('UPDATE clip_state SET frames=0, error=NULL WHERE clip_id=?', (clip['id'],))
                conn.execute('INSERT OR REPLACE INTO coverage_skips(clip_id, skipped, total) VALUES(?,?,?)',
                             (clip['id'], len(pos), len(pos)))
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
                if ocr_done:
                    conn.execute('UPDATE clips SET duration=? WHERE id=?', (info['duration'], clip['id']))
                else:
                    conn.execute('UPDATE clips SET duration=?, start=?, width=?, height=? WHERE id=?',
                                 (info['duration'], start, info.get('width'), info.get('height'),
                                  clip['id']))
                conn.execute('UPDATE clip_state SET probed=1 WHERE clip_id=?', (clip['id'],))
        clip = conn.execute('SELECT * FROM clips WHERE id=?', (clip['id'],)).fetchone()
        overlay.ocr_clip(conn, clip, log=lambda *_: None, path=local)
        clip = conn.execute('SELECT * FROM clips WHERE id=?', (clip['id'],)).fetchone()
        jolt_clip(conn, clip, local)
        if ocr_only:
            return 0
        n = 0
        if st['frames'] is None:
            prof, pos, kept = clip_positions(conn, clip, keep)
            times = fr.frame_times(local)
            picks = fr.nearest_indices(times, kept)
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
                if keep is not None:
                    conn.execute('INSERT OR REPLACE INTO coverage_skips(clip_id, skipped, total) '
                                 'VALUES(?,?,?)', (clip['id'], len(pos) - len(kept), len(pos)))
        return n
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def ingest_trip(conn, card, key, pinned=None):
    """Разбор роликов поездки. Если на её пути есть закреплённые участки —
    два прохода: сначала OCR всех роликов (нужен для пути между опорами),
    затем привязка и кадры только там, где участок не закреплён."""
    clips = catalog.trip_clips(conn, key)
    keep = None
    if pinned:
        for i, c in enumerate(clips):
            try:
                process_clip(conn, card, c, ocr_only=True)
            except DiskLow:
                raise
            except Exception as e:
                log(f'  OCR {c["name"]}: ошибка {e}')
        catalog.regroup(conn)
        g, _ = trip_geo(conn, key)
        import coverage

        def keep(t):
            p = g.locate(t)
            # без привязки участок неизвестен — разбираем (лучше лишний кадр)
            return p is None or coverage.cell_key(p[0], p[1], p[2]) not in pinned
    total = 0
    for i, c in enumerate(clips):
        t = time.time()
        try:
            n = process_clip(conn, card, c, keep=keep)
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
    jupd = []
    for r in conn.execute('SELECT id, t FROM jolts WHERE trip_key=?', (key,)).fetchall():
        p = g.locate(r['t'])
        jupd.append((p[0], p[1], p[2], p[3], r['id']) if p else (None, None, None, None, r['id']))
    with conn:
        conn.executemany('UPDATE jolts SET lat=?, lon=?, course=?, weight=? WHERE id=?', jupd)
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
    import coverage
    card = Card()
    pinned = coverage.pinned_keys(conn)
    planned = plan(conn, pinned)
    novelty = {t['key']: (n, m) for t, n, m in planned}
    trips = [t for t, _, _ in planned]
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
            nov, new_m = novelty.get(key, (1.0, 0.0))
            log(f'поездка {key} ({trip["n_clips"]} рол.), стадия {done or "—"}, нового пути '
                f'{nov:.0%} ({new_m / 1000:.1f} км)')
            if nov < coverage.REPEAT_NOVELTY and done in (None, 'repeat') and not keys:
                set_stage(conn, key, 'repeat', f'нового пути {nov:.0%}')
                log('  повтор: путь целиком по закреплённым участкам — пропуск')
                continue
            try:
                if 'ingest' in stages:
                    trip_pinned = pinned if nov < 0.98 else None
                    n = ingest_trip(conn, card, key, trip_pinned)
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
                    log(f'  знаки ограничения «текст сначала»: +{detect.textscan_trip(conn, key)}')
                    import signs
                    log(f'  классификатор знаков: {signs.classify(conn, log=log)} вырезок')
                    set_stage(conn, key, 'detected')
                    log(f'  детекторы: {n}')
                if 'objects' in stages:
                    import objects
                    n = objects.build_trip(conn, key)
                    import signmap
                    n += signmap.build_trip(conn, key)
                    set_stage(conn, key, 'objects')
                    log(f'  объекты: {n}')
                    # кластеры и покрытие — задним числом по всему разобранному
                    import cluster
                    log(f'  кластеры: {cluster.rebuild(conn, log=lambda *_: None)}')
                    log(f'  знаки: {signmap.rebuild_finds(conn)}')
                    log(f'  покрытие: {coverage.rebuild(conn)}')
                    pinned = coverage.pinned_keys(conn)
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


def redetect(conn, keys=None, log=log):
    """Детекторы обновились — пересчитать сработки, объекты, кластеры и знаки по уже
    вынутым кадрам (ролики не читаются)."""
    import detect
    import objects
    keys = keys or [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM frames')]
    for k in keys:
        with conn:
            conn.execute('UPDATE frames SET detected=0 WHERE trip_key=?', (k,))
        n = detect.detect_trip(conn, k, log=log)
        n += detect.textscan_trip(conn, k)
        m = objects.build_trip(conn, k)
        log(f'{k}: сработок {n}, объектов {m}')
    import cluster
    import coverage
    import signs
    log(f'кластеры: {cluster.rebuild(conn, log=log)}')
    signs.cluster_all(conn, log=log)
    import signmap
    log(f'классификатор знаков: {signs.classify(conn, log=log)}')
    signmap.build(conn, log=log)
    log(f'покрытие: {coverage.rebuild(conn)}')


def relimit(conn, log=log):
    """Знаки ограничения пересчитать только на «подозрительных» кадрах (где были
    сработки ограничения или кандидаты «красный круг»): детекторы — заново,
    текст сначала — заново с проверкой канта. Остальные кадры не трогаются."""
    import detect
    import objects
    rows = conn.execute("SELECT DISTINCT f.id, f.trip_key FROM frames f WHERE f.id IN "
                        "(SELECT frame_id FROM detections WHERE cls='speed_limit' UNION "
                        "SELECT frame_id FROM sign_crops WHERE shape='red_circle')").fetchall()
    trips = sorted({r['trip_key'] for r in rows})
    with conn:
        conn.executemany('UPDATE frames SET detected=0 WHERE id=?', [(r['id'],) for r in rows])
        conn.execute('CREATE TABLE IF NOT EXISTS text_done(frame_id INTEGER PRIMARY KEY)')
        conn.executemany('DELETE FROM text_done WHERE frame_id=?', [(r['id'],) for r in rows])
    log(f'кадров на пересчёт: {len(rows)}, поездок {len(trips)}')
    for k in trips:
        detect.detect_trip(conn, k, log=log)
        # текст сначала — на всех кадрах из пересчёта (без прореживания)
        save = detect.TEXT_EVERY
        detect.TEXT_EVERY = 1
        try:
            ids = {r['id'] for r in rows if r['trip_key'] == k}
            with conn:
                conn.executemany('INSERT OR IGNORE INTO text_done(frame_id) SELECT id FROM frames '
                                 'WHERE trip_key=? AND id NOT IN (%s)' % ','.join('?' * len(ids)),
                                 [(k, *ids)])
            n = detect.textscan_trip(conn, k)
        finally:
            detect.TEXT_EVERY = save
        objects.build_trip(conn, k)
        log(f'{k}: текст сначала +{n}')
    import cluster
    log(f'кластеры: {cluster.rebuild(conn, log=log)}')


def relocate(conn, keys=None, log=log):
    """Привязка поменялась (08.10.2026: время wpt — «отпускание» камеры, а не
    проезд, см. passtime) — пересчитать место всех кадров и рывков, затем
    триангуляцию объектов, кластеры со сверкой и покрытие. Детекторы и кадры
    не трогаются: сработки — пиксели, от места не зависят."""
    import cluster
    import coverage
    import objects
    keys = keys or [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM frames ORDER BY trip_key')]
    import signmap
    for k in keys:
        s = geo_trip(conn, k)
        m = objects.build_trip(conn, k) + signmap.build_trip(conn, k)
        log(f'{k}: {s.get("source")}, опор {s.get("anchors_used")}, кадров с местом '
            f'{s.get("located")}/{s.get("frames")}, объектов {m}')
    log(f'кластеры: {cluster.rebuild(conn, log=log)}')
    log(f'знаки: {signmap.rebuild_finds(conn)}')
    log(f'покрытие: {coverage.rebuild(conn)}')


def backfill_jolts(conn, log=log):
    """Рывки для роликов, разобранных до появления детектора рывков: копия с
    карты → профиль строк → удалить (кадры не трогаются)."""
    card = Card()
    rows = conn.execute('SELECT c.* FROM clips c JOIN clip_state s ON s.clip_id=c.id '
                        'LEFT JOIN jolt_done j ON j.clip_id=c.id WHERE s.frames IS NOT NULL '
                        'AND j.clip_id IS NULL ORDER BY c.start').fetchall()
    log(f'роликов без рывков: {len(rows)}')
    try:
        for c in rows:
            if free_gb() < MIN_FREE_GB + c['size'] / 1e9:
                log('СТОП: мало места')
                return
            tmp = tempfile.mkdtemp(prefix='jolt_', dir=TMP_DIR)
            try:
                if c['path'].startswith(CARD_PREFIX):
                    local = os.path.join(tmp, c['name'])
                    card.copy(c['path'][len(CARD_PREFIX):], local)
                else:
                    local = c['path']
                jolt_clip(conn, c, local)
            except Exception as e:
                log(f'  {c["name"]}: {e}')
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
    finally:
        card.close()
    for (k,) in conn.execute('SELECT DISTINCT trip_key FROM jolts').fetchall():
        g, _ = trip_geo(conn, k)
        with conn:
            for r in conn.execute('SELECT id, t FROM jolts WHERE trip_key=?', (k,)).fetchall():
                p = g.locate(r['t'])
                conn.execute('UPDATE jolts SET lat=?, lon=?, course=?, weight=? WHERE id=?',
                             (p[0], p[1], p[2], p[3], r['id']) if p else (None, None, None, None, r['id']))


def summary(conn):
    """Счётчики для отчёта: что разобрано и что найдено."""
    q = lambda sql, *a: conn.execute(sql, a).fetchone()[0]
    out = {
        'поездок_разобрано': q("SELECT COUNT(DISTINCT trip_key) FROM frames"),
        'поездок_с_привязкой': q("SELECT COUNT(DISTINCT trip_key) FROM frames WHERE lat IS NOT NULL"),
        'роликов_разобрано': q("SELECT COUNT(*) FROM clip_state WHERE frames IS NOT NULL"),
        'кадров': q("SELECT COUNT(*) FROM frames"),
        'кадров_с_привязкой': q("SELECT COUNT(*) FROM frames WHERE lat IS NOT NULL"),
        'часов_видео': round(q("SELECT COALESCE(SUM(c.duration),0) FROM clips c JOIN clip_state s "
                               "ON s.clip_id=c.id WHERE s.frames IS NOT NULL") / 3600, 1),
        'повторов_пропущено': q("SELECT COUNT(*) FROM batch_state WHERE stage='repeat'"),
        'кадров_сэкономлено_покрытием': q("SELECT COALESCE(SUM(skipped),0) FROM coverage_skips"),
        'роликов_не_скопировано_покрытием': q("SELECT COUNT(*) FROM coverage_skips WHERE skipped=total "
                                              "AND total>0"),
    }
    km = 0.0
    for (k,) in conn.execute('SELECT DISTINCT trip_key FROM frames').fetchall():
        o = sync_odometer(conn, k)
        km += o
    out['км_по_скорости'] = round(km / 1000, 1)
    out['сработок'] = {r[0]: r[1] for r in conn.execute('SELECT cls, COUNT(*) FROM detections GROUP BY cls')}
    out['кластеров'] = {f'{r[0]}/{r[1]}': r[2] for r in conn.execute(
        'SELECT cls, status, COUNT(*) FROM clusters GROUP BY cls, status')}
    out['кандидатов_знаков'] = {r[0]: r[1] for r in conn.execute(
        'SELECT shape, COUNT(*) FROM sign_crops GROUP BY shape')}
    out['кластеров_знаков'] = q('SELECT COUNT(*) FROM sign_clusters')
    out['рывков'] = q('SELECT COUNT(*) FROM jolts')
    try:
        import coverage
        coverage.connect(conn)
        out['участков'] = q('SELECT COUNT(*) FROM coverage')
        out['участков_закреплено'] = q('SELECT COUNT(*) FROM coverage WHERE pinned=1')
    except Exception:
        pass
    return out


def sync_odometer(conn, key):
    import locate
    o = locate.Odometer(sync.clean_ocr(catalog.ocr_series(conn, key)))
    return o.d[-1] if o.d else 0.0


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
    p = sub.add_parser('redetect')
    p.add_argument('--trips')
    sub.add_parser('backfill-jolts')
    sub.add_parser('relimit')
    sub.add_parser('summary')
    p = sub.add_parser('relocate')
    p.add_argument('--trips')
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
    elif a.cmd == 'redetect':
        redetect(conn, a.trips.split(',') if a.trips else None)
    elif a.cmd == 'relimit':
        relimit(conn)
    elif a.cmd == 'backfill-jolts':
        backfill_jolts(conn)
    elif a.cmd == 'relocate':
        relocate(conn, a.trips.split(',') if a.trips else None)
    elif a.cmd == 'summary':
        import json
        print(json.dumps(summary(conn), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    sys.exit(main())
