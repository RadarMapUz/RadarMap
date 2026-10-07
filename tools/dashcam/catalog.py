#!/usr/bin/env python3
"""Каталог «Разбора видео»: ролики регистратора, поездки, треки GPX, OCR
полосы кадра и найденный сдвиг часов — в одном SQLite.

    python3 catalog.py import ~/RadarMapBuild/dashcam/morning [file.gpx …]
    python3 catalog.py card /dev/disk12s1 DEST [--date 2026-10-07]
    python3 catalog.py list

Время везде — секунды Unix (UTC). Регистратор BYD пишет местное время
Ташкента (UTC+5, без перехода на летнее) — в имени файла (время СТАРТА
ролика) и в полосе кадра; тег creation_time в mp4 — UTC, время КОНЦА.
Все «времена ролика» здесь — по часам регистратора; к часам телефона их
приводит сдвиг синхронизации (sync.py), который хранится отдельно.

Исходники не трогаем: каталог хранит пути и только читает файлы.
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone

import gpx

DB_PATH = os.environ.get('DASHCAM_DB', os.path.expanduser('~/RadarMapBuild/dashcam/dashcam.db'))
FFPROBE = os.environ.get('FFPROBE', '/opt/homebrew/bin/ffprobe')
# Часовой пояс часов регистратора.
DASHCAM_TZ = timezone(timedelta(hours=5))
# Поездка — подряд идущие ролики с разрывом не больше этого.
TRIP_GAP_SECONDS = 300
# Трек относится к поездке, если пересекается с ней по времени с таким запасом:
# сдвиг часов регистратора ищется в пределах ±120 с, берём с запасом.
TRACK_MATCH_SLACK = 600
# creation_time ролика доверяем, только если он согласуется с именем.
CREATION_TRUST_SECONDS = 10

NAME_RE = re.compile(r'(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})')

SCHEMA = """
CREATE TABLE IF NOT EXISTS clips(
  id INTEGER PRIMARY KEY,
  path TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  name_start REAL NOT NULL,      -- время из имени файла (часы регистратора)
  start REAL NOT NULL,           -- уточнённый старт: creation_time−длительность, затем OCR
  duration REAL NOT NULL,
  size INTEGER NOT NULL,
  width INTEGER, height INTEGER,
  trip_key TEXT
);
CREATE INDEX IF NOT EXISTS clips_start ON clips(start);
CREATE TABLE IF NOT EXISTS trips(
  key TEXT PRIMARY KEY,          -- имя первого ролика: устойчиво между импортами
  start REAL NOT NULL, end REAL NOT NULL, n_clips INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tracks(
  id INTEGER PRIMARY KEY,
  path TEXT UNIQUE NOT NULL,
  name TEXT, synthetic INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL,            -- timed: время у точек; anchored: время только у опор (wpt)
  start REAL, end REAL, n INTEGER
);
-- Форма маршрута старой поездки (точки трека без времени), по порядку.
CREATE TABLE IF NOT EXISTS track_shape(
  track_id INTEGER NOT NULL, seq INTEGER NOT NULL, lat REAL, lon REAL
);
CREATE TABLE IF NOT EXISTS track_points(
  track_id INTEGER NOT NULL, t REAL NOT NULL, lat REAL, lon REAL, kmh REAL
);
CREATE INDEX IF NOT EXISTS track_points_t ON track_points(track_id, t);
CREATE TABLE IF NOT EXISTS waypoints(
  track_id INTEGER NOT NULL, t REAL, lat REAL, lon REAL, name TEXT
);
-- OCR полосы кадра раз в секунду: t — секунда ролика, clock — время из
-- полосы (часы регистратора), kmh — скорость из полосы. NULL — не прочиталось.
CREATE TABLE IF NOT EXISTS ocr(
  clip_id INTEGER NOT NULL, t INTEGER NOT NULL, clock REAL, kmh REAL,
  PRIMARY KEY(clip_id, t)
);
CREATE TABLE IF NOT EXISTS ocr_done(clip_id INTEGER PRIMARY KEY, frames INTEGER, read INTEGER);
-- offset: время телефона = время регистратора + offset.
-- method «speed» — корреляция скорости (quality = r Пирсона);
-- method «anchors» — по опорам (quality = NULL, точность — невязка в метрах в detail).
CREATE TABLE IF NOT EXISTS sync(
  trip_key TEXT NOT NULL, track_id INTEGER NOT NULL, method TEXT,
  offset REAL, quality REAL, n INTEGER, good INTEGER, detail TEXT, computed REAL,
  PRIMARY KEY(trip_key, track_id)
);

-- ===== Пакетный разбор (batch.py) =====
-- Ролик «на карте»: clips.path = 'card:Recorder/Normal/ИМЯ'. Сам ролик после
-- разбора не хранится — только этот путь и признаки стадий.
CREATE TABLE IF NOT EXISTS clip_state(
  clip_id INTEGER PRIMARY KEY,
  probed INTEGER NOT NULL DEFAULT 0,   -- длительность/старт уточнены ffprobe
  frames INTEGER,                      -- сколько кадров вынуто (NULL — ещё нет)
  error TEXT
);
-- Кадр для детекторов: JPEG без полосы и капота. t — время кадра по часам
-- регистратора; lat/lon/course — где была машина (NULL — привязать не удалось);
-- weight — вес привязки 0…1 (ненадёжный перегон — низкий).
CREATE TABLE IF NOT EXISTS frames(
  id INTEGER PRIMARY KEY,
  trip_key TEXT NOT NULL, clip_id INTEGER NOT NULL, pos REAL NOT NULL, t REAL NOT NULL,
  kmh REAL, path TEXT NOT NULL,
  lat REAL, lon REAL, course REAL, weight REAL, seg INTEGER,
  detected INTEGER NOT NULL DEFAULT 0,
  UNIQUE(clip_id, pos)
);
CREATE INDEX IF NOT EXISTS frames_trip ON frames(trip_key, t);
-- Ответы OSRM: ключ — пара опор, округлённых до 1e-5°.
CREATE TABLE IF NOT EXISTS route_cache(
  key TEXT PRIMARY KEY, body TEXT, fetched REAL
);
-- Привязка поездки: источник формы (trk — линия из GPX, osrm — восстановлена
-- по опорам), перегоны между опорами с невязкой и признаком надёжности.
CREATE TABLE IF NOT EXISTS trip_geo(
  trip_key TEXT PRIMARY KEY, source TEXT, shape TEXT, anchors TEXT, summary TEXT, computed REAL
);
CREATE TABLE IF NOT EXISTS segments(
  trip_key TEXT NOT NULL, idx INTEGER NOT NULL, t0 REAL, t1 REAL,
  line_m REAL, odo_m REAL, residual_m REAL, reliable INTEGER, source TEXT,
  PRIMARY KEY(trip_key, idx)
);
-- Сработки детекторов на кадре. Рамка — в пикселях исходного кадра 1920×1080.
-- value — число на знаке (только из допустимого ряда); никакого иного текста.
CREATE TABLE IF NOT EXISTS detections(
  id INTEGER PRIMARY KEY,
  frame_id INTEGER NOT NULL, cls TEXT NOT NULL, value INTEGER, color TEXT,
  x REAL, y REAL, w REAL, h REAL, conf REAL, obj INTEGER
);
CREATE INDEX IF NOT EXISTS detections_frame ON detections(frame_id);
CREATE INDEX IF NOT EXISTS detections_obj ON detections(obj);
-- Объект одной поездки: трек сработок по соседним кадрам → точка (триангуляция).
CREATE TABLE IF NOT EXISTS objects(
  id INTEGER PRIMARY KEY,
  trip_key TEXT NOT NULL, cls TEXT NOT NULL, value INTEGER, color TEXT,
  lat REAL, lon REAL, err_m REAL, n_frames INTEGER, method TEXT, weight REAL, conf REAL,
  cluster INTEGER
);
CREATE INDEX IF NOT EXISTS objects_trip ON objects(trip_key);
-- Кластер = объект, увиденный в одной или нескольких поездках.
CREATE TABLE IF NOT EXISTS clusters(
  id INTEGER PRIMARY KEY,
  cls TEXT NOT NULL, value INTEGER, lat REAL, lon REAL, err_m REAL,
  n_trips INTEGER, n_frames INTEGER, confidence REAL,
  status TEXT,             -- confirms | new | differs
  map_ref TEXT             -- JSON: что нашлось в нашей карте рядом
);
-- Решения человека по находке — по месту, а не по id кластера: кластеры
-- пересобираются, решение переносится на кластер того же класса рядом.
CREATE TABLE IF NOT EXISTS decisions(
  id INTEGER PRIMARY KEY, cls TEXT NOT NULL, value INTEGER, lat REAL, lon REAL,
  decision TEXT NOT NULL, at REAL
);
-- Разметка для обучения: да/нет по отдельной сработке.
CREATE TABLE IF NOT EXISTS labels(
  det_id INTEGER PRIMARY KEY, answer TEXT NOT NULL, at REAL
);
-- Вырезки для карточки находки (номера и лица размыты).
CREATE TABLE IF NOT EXISTS crops(
  det_id INTEGER PRIMARY KEY, path TEXT NOT NULL
);
-- Выгрузка «все поездки» (all_trips.gpx), разложенная по поездкам: период
-- её опор — чтобы отличить «до начала истории» от «опор в окне нет».
CREATE TABLE IF NOT EXISTS gpx_imports(
  path TEXT PRIMARY KEY, first_t REAL, last_t REAL, n_trk INTEGER, n_wpt INTEGER, imported REAL
);
-- Кандидаты всех дорожных знаков (форма + цвет): вырезка 96×96 для подписи
-- кластерами. Рамка — в пикселях исходного кадра; side — слева/справа/над.
CREATE TABLE IF NOT EXISTS sign_crops(
  id INTEGER PRIMARY KEY, frame_id INTEGER NOT NULL, shape TEXT NOT NULL,
  x REAL, y REAL, w REAL, h REAL, score REAL, t REAL, lat REAL, lon REAL, course REAL,
  side TEXT, path TEXT, cluster INTEGER, label TEXT, labeled_at REAL
);
CREATE INDEX IF NOT EXISTS sign_crops_frame ON sign_crops(frame_id);
CREATE INDEX IF NOT EXISTS sign_crops_cluster ON sign_crops(cluster);
CREATE TABLE IF NOT EXISTS sign_clusters(
  id INTEGER PRIMARY KEY, shape TEXT NOT NULL, size INTEGER, reps TEXT, label TEXT, parent INTEGER
);
-- Сколько кадров ролика не вынуто, потому что участок уже закреплён (coverage.py).
CREATE TABLE IF NOT EXISTS coverage_skips(clip_id INTEGER PRIMARY KEY, skipped INTEGER, total INTEGER);
-- Рывки картинки по вертикали (кандидаты «лежачий полицейский»): t — часы регистратора.
CREATE TABLE IF NOT EXISTS jolts(
  id INTEGER PRIMARY KEY, trip_key TEXT, clip_id INTEGER, t REAL, score REAL, kmh REAL,
  lat REAL, lon REAL, course REAL, weight REAL, UNIQUE(clip_id, t)
);
CREATE TABLE IF NOT EXISTS jolt_done(clip_id INTEGER PRIMARY KEY, n INTEGER);
CREATE TABLE IF NOT EXISTS batch_state(
  trip_key TEXT PRIMARY KEY, stage TEXT, error TEXT, updated REAL
);
"""


def connect(path=None):
    path = path or DB_PATH
    if path != ':memory:':
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    conn.executescript(SCHEMA)
    # Поля, добавленные после первых запусков (CREATE IF NOT EXISTS их не добавит).
    for table, col in (('sign_crops', 'text TEXT'),):
        try:
            conn.execute(f'ALTER TABLE {table} ADD COLUMN {col}')
        except sqlite3.OperationalError:
            pass  # уже есть
    return conn


def parse_clip_name(name):
    """«2026-10-07-08-05-24.mp4» → секунды Unix (часы регистратора) или None."""
    m = NAME_RE.search(os.path.basename(name))
    if not m:
        return None
    try:
        dt = datetime(*map(int, m.groups()), tzinfo=DASHCAM_TZ)
    except ValueError:
        return None
    return dt.timestamp()


def local_str(t, fmt='%Y-%m-%d %H:%M:%S'):
    return datetime.fromtimestamp(t, DASHCAM_TZ).strftime(fmt)


def probe(path):
    """ffprobe → dict(duration, end (creation_time, UTC) или None, width, height)."""
    out = subprocess.run(
        [FFPROBE, '-v', 'error', '-select_streams', 'v:0',
         '-show_entries', 'format=duration:format_tags=creation_time:stream=width,height',
         '-of', 'json', path], capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    fmt = j.get('format', {})
    stream = (j.get('streams') or [{}])[0]
    created = fmt.get('tags', {}).get('creation_time')
    return {'duration': float(fmt['duration']),
            'end': gpx.parse_time(created) if created else None,
            'width': stream.get('width'), 'height': stream.get('height')}


def initial_start(name_start, duration, end):
    """Старт ролика до OCR. Имя округлено до секунды и у BYD отстаёт на ~1 с;
    creation_time (конец) минус длительность точнее — если они согласуются."""
    if end is not None:
        guess = end - duration
        if abs(guess - name_start) <= CREATION_TRUST_SECONDS:
            return guess
    return name_start


def group_trips(clips, gap=TRIP_GAP_SECONDS):
    """clips: [(id, start, duration)] → [[id, …], …]. Разрыв больше gap — новая поездка."""
    groups, last_end = [], None
    for cid, start, dur in sorted(clips, key=lambda c: c[1]):
        if last_end is None or start - last_end > gap:
            groups.append([])
        groups[-1].append(cid)
        last_end = max(last_end or start, start + dur)
    return groups


def regroup(conn):
    rows = conn.execute('SELECT id, name, start, duration FROM clips').fetchall()
    by_id = {r['id']: r for r in rows}
    groups = group_trips([(r['id'], r['start'], r['duration']) for r in rows])
    keys = []
    with conn:
        for g in groups:
            first = by_id[g[0]]
            key = os.path.splitext(first['name'])[0]
            keys.append(key)
            start = min(by_id[c]['start'] for c in g)
            end = max(by_id[c]['start'] + by_id[c]['duration'] for c in g)
            conn.execute('INSERT INTO trips(key, start, end, n_clips) VALUES(?,?,?,?) '
                         'ON CONFLICT(key) DO UPDATE SET start=excluded.start, end=excluded.end, '
                         'n_clips=excluded.n_clips', (key, start, end, len(g)))
            conn.executemany('UPDATE clips SET trip_key=? WHERE id=?', [(key, c) for c in g])
        stale = [r[0] for r in conn.execute('SELECT key FROM trips') if r[0] not in keys]
        conn.executemany('DELETE FROM trips WHERE key=?', [(k,) for k in stale])
    return len(groups)


def import_clip(conn, path, probe_fn=probe):
    path = os.path.abspath(path)
    name = os.path.basename(path)
    name_start = parse_clip_name(name)
    if name_start is None:
        return False
    if conn.execute('SELECT 1 FROM clips WHERE path=?', (path,)).fetchone():
        return False
    info = probe_fn(path)
    start = initial_start(name_start, info['duration'], info.get('end'))
    with conn:
        conn.execute('INSERT INTO clips(path, name, name_start, start, duration, size, width, height) '
                     'VALUES(?,?,?,?,?,?,?,?)',
                     (path, name, name_start, start, info['duration'], os.path.getsize(path),
                      info.get('width'), info.get('height')))
    return True


def import_gpx(conn, path):
    path = os.path.abspath(path)
    if conn.execute('SELECT 1 FROM tracks WHERE path=?', (path,)).fetchone():
        return False
    g = gpx.parse(path)
    pts, wpts = g['points'], g['waypoints']
    if g['kind'] is None:
        raise ValueError(f'в треке нет ни точек со временем, ни опор (wpt со временем): {path}')
    span = pts if g['kind'] == 'timed' else wpts
    with conn:
        cur = conn.execute('INSERT INTO tracks(path, name, synthetic, kind, start, end, n) '
                           'VALUES(?,?,?,?,?,?,?)',
                           (path, g['name'] or os.path.basename(path), int(g['synthetic']),
                            g['kind'], span[0][0], span[-1][0], len(pts) or len(g['shape'])))
        tid = cur.lastrowid
        conn.executemany('INSERT INTO track_points(track_id, t, lat, lon, kmh) VALUES(?,?,?,?,?)',
                         [(tid, *p) for p in pts])
        conn.executemany('INSERT INTO track_shape(track_id, seq, lat, lon) VALUES(?,?,?,?)',
                         [(tid, i, lat, lon) for i, (lat, lon) in enumerate(g['shape'])])
        conn.executemany('INSERT INTO waypoints(track_id, t, lat, lon, name) VALUES(?,?,?,?,?)',
                         [(tid, *w) for w in g['waypoints']])
    return True


def _is_multi_trip(path):
    """Выгрузка «все поездки»: несколько <trk>, у точек нет времени."""
    with open(path, 'rb') as f:
        head = f.read()
    return head.count(b'<trk>') > 1 and b'<trkpt' in head and b'</time></trkpt>' not in head


def import_paths(conn, paths, probe_fn=probe, log=print):
    """Папки и файлы: *.mp4 с именем-временем → ролики, *.gpx → треки."""
    clips = tracks = 0
    files, multi = [], []
    for p in paths:
        p = os.path.expanduser(p)
        if os.path.isdir(p):
            files += [os.path.join(p, n) for n in sorted(os.listdir(p)) if not n.startswith('.')]
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise FileNotFoundError(p)
    for f in files:
        low = f.lower()
        if low.endswith('.mp4'):
            if import_clip(conn, f, probe_fn):
                clips += 1
        elif low.endswith('.gpx') and _is_multi_trip(f):
            multi.append(f)
        elif low.endswith('.gpx'):
            if import_gpx(conn, f):
                tracks += 1
                log(f'трек {os.path.basename(f)}')
    regroup(conn)
    for f in multi:  # по поездкам — после того, как поездки собраны
        import_all_trips(conn, f, log)
        tracks += 1
    return clips, tracks


# Опора относится к поездке, если её время внутри окна поездки с таким запасом.
ALL_TRIPS_SLACK = 120


def import_all_trips(conn, path, log=print):
    """Выгрузка «все поездки» (много trk без времени + wpt-проезды камер со
    временем UTC) → по треку на каждую поездку регистратора: её опоры — wpt
    в окне поездки ±ALL_TRIPS_SLACK; её линия — trk, чьё время из имени
    («RadarMap 2026-10-06T090904», местное) попадает в окно поездки (с запасом
    15 мин до старта: приложение стартует поездку позже регистратора).
    Без линии форма — ломаная через опоры (для страницы; пакетный разбор
    восстанавливает маршрут через OSRM). Повторный импорт пересобирает всё."""
    import geo
    path = os.path.abspath(path)
    trks, wpts = geo.load_all_trips(path)
    prefix = path + '#'
    with conn:
        old = [r[0] for r in conn.execute('SELECT id FROM tracks WHERE path LIKE ?', (prefix + '%',))]
        for tid in old:
            for tbl in ('track_points', 'track_shape', 'waypoints', 'sync'):
                conn.execute(f'DELETE FROM {tbl} WHERE track_id=?', (tid,))
            conn.execute('DELETE FROM tracks WHERE id=?', (tid,))
        conn.execute('INSERT OR REPLACE INTO gpx_imports(path, first_t, last_t, n_trk, n_wpt, imported) '
                     'VALUES(?,?,?,?,?,strftime(\'%s\',\'now\'))',
                     (path, wpts[0][0] if wpts else None, wpts[-1][0] if wpts else None,
                      len(trks), len(wpts)))
        made = 0
        for trip in conn.execute('SELECT * FROM trips ORDER BY start').fetchall():
            lo, hi = trip['start'] - ALL_TRIPS_SLACK, trip['end'] + ALL_TRIPS_SLACK
            mine = [w for w in wpts if lo <= w[0] <= hi]
            lines = geo.trks_for(trks, trip['start'], trip['end'])
            if not mine:
                continue
            shape = [p for tr in sorted(lines, key=lambda x: x['t']) for p in tr['shape']]
            name = (f'опоры из GPX {len(mine)} + линия' if shape else f'опоры из GPX {len(mine)}')
            if not shape:
                shape = [(w[1], w[2]) for w in mine]
            if len(set(shape)) < 2:
                continue  # одна опора: формы нет, привязать нечем
            cur = conn.execute('INSERT INTO tracks(path, name, synthetic, kind, start, end, n) '
                               'VALUES(?,?,0,?,?,?,?)',
                               (prefix + trip['key'], name, 'anchored', trip['start'], trip['end'],
                                len(shape)))
            tid = cur.lastrowid
            conn.executemany('INSERT INTO track_shape(track_id, seq, lat, lon) VALUES(?,?,?,?)',
                             [(tid, i, a, b) for i, (a, b) in enumerate(shape)])
            conn.executemany('INSERT INTO waypoints(track_id, t, lat, lon, name) VALUES(?,?,?,?,?)',
                             [(tid, *w) for w in mine])
            made += 1
    # Треки пересозданы — синхронизация к ним считается заново (иначе поездка
    # с готовым OCR показывалась бы «не синхронизировано»).
    import sync
    for trip in conn.execute('SELECT * FROM trips').fetchall():
        st = trip_status(conn, trip)
        if st['ocr_done'] >= st['clips'] and st['track'] is not None:
            for tr in tracks_for_trip(conn, trip):
                try:
                    sync.sync_trip(conn, trip['key'], tr['id'])
                except Exception as e:  # одна плохая поездка не должна ронять импорт
                    log(f'синхронизация {trip["key"]}: {e}')
    log(f'all_trips: поездок с опорами {made}, trk {len(trks)}, wpt {len(wpts)}')
    return made


def history_start(conn):
    r = conn.execute('SELECT MIN(first_t) FROM gpx_imports').fetchone()
    return r[0] if r else None


def trip_clips(conn, key):
    return conn.execute('SELECT * FROM clips WHERE trip_key=? ORDER BY start', (key,)).fetchall()


def tracks_for_trip(conn, trip):
    """Треки, пересекающиеся с поездкой по времени (с запасом на сдвиг часов).
    Порядок: настоящие раньше синтетических, затем по пересечению — первый
    и есть трек по умолчанию: синтетика нужна для тестов, не для разбора."""
    lo, hi = trip['start'] - TRACK_MATCH_SLACK, trip['end'] + TRACK_MATCH_SLACK
    rows = conn.execute('SELECT * FROM tracks WHERE end>=? AND start<=?', (lo, hi)).fetchall()

    def rank(tr):
        overlap = min(tr['end'], trip['end']) - max(tr['start'], trip['start'])
        return (tr['synthetic'], -overlap, tr['id'])
    return sorted(rows, key=rank)


def track_for_trip(conn, trip, track_id=None):
    rows = tracks_for_trip(conn, trip)
    if track_id is not None:
        rows = [r for r in rows if r['id'] == track_id]
    return rows[0] if rows else None


def track_shape(conn, track_id):
    return [(r['lat'], r['lon']) for r in conn.execute(
        'SELECT lat, lon FROM track_shape WHERE track_id=? ORDER BY seq', (track_id,))]


def track_waypoints(conn, track_id):
    return [tuple(r) for r in conn.execute(
        'SELECT t, lat, lon, name FROM waypoints WHERE track_id=? ORDER BY t', (track_id,))]


def track_points(conn, track_id, lo=None, hi=None):
    q = 'SELECT t, lat, lon, kmh FROM track_points WHERE track_id=?'
    args = [track_id]
    if lo is not None:
        q += ' AND t>=? AND t<=?'
        args += [lo, hi]
    return [tuple(r) for r in conn.execute(q + ' ORDER BY t', args)]


def ocr_series(conn, key):
    """Скорость из полосы кадра: [(время регистратора, км/ч)] по всей поездке."""
    rows = conn.execute(
        'SELECT c.start + o.t AS ts, o.kmh FROM ocr o JOIN clips c ON c.id=o.clip_id '
        'WHERE c.trip_key=? AND o.kmh IS NOT NULL ORDER BY ts', (key,)).fetchall()
    return [(r['ts'], r['kmh']) for r in rows]


def sync_row(conn, key, track_id):
    row = conn.execute('SELECT * FROM sync WHERE trip_key=? AND track_id=?',
                       (key, track_id)).fetchone()
    if not row:
        return None
    detail = json.loads(row['detail'] or '{}')
    detail.pop('curve', None)
    return {'method': row['method'], 'offset': row['offset'], 'quality': row['quality'],
            'n': row['n'], 'good': bool(row['good']), **detail}


def track_brief(tr):
    return {'id': tr['id'], 'name': tr['name'], 'synthetic': bool(tr['synthetic']),
            'kind': tr['kind']}


def trip_status(conn, trip, track_id=None):
    """Статус поездки для списка: импорт → OCR → синхронизация → готово."""
    clips = trip_clips(conn, trip['key'])
    done = conn.execute(
        'SELECT COUNT(*) FROM ocr_done d JOIN clips c ON c.id=d.clip_id WHERE c.trip_key=?',
        (trip['key'],)).fetchone()[0]
    candidates = tracks_for_trip(conn, trip)
    tr = track_for_trip(conn, trip, track_id)
    sync = sync_row(conn, trip['key'], tr['id']) if tr is not None else None
    if tr is None:
        hs = history_start(conn)
        if hs is None:
            stage = 'no_gpx'
        elif trip['end'] < hs - ALL_TRIPS_SLACK:
            stage = 'before_history'   # выгрузка начинается позже этой поездки
        else:
            stage = 'no_anchors'       # выгрузка есть, но проездов камер в окне нет
    elif done < len(clips):
        stage = 'ocr'
    elif sync is None:
        stage = 'sync'
    elif not sync['good']:
        stage = 'bad_sync'
    else:
        stage = 'ready'
    b = conn.execute('SELECT stage, error FROM batch_state WHERE trip_key=?', (trip['key'],)).fetchone()
    vg = None
    try:
        vg = conn.execute('SELECT status, n FROM video_geo WHERE trip_key=?', (trip['key'],)).fetchone()
    except sqlite3.OperationalError:
        pass  # таблицы ещё нет — этап «опоры по видео» не запускался
    return {'key': trip['key'], 'start': trip['start'], 'end': trip['end'],
            'batch': {'stage': b['stage'], 'note': b['error']} if b else None,
            'video_geo': {'status': vg['status'], 'n': vg['n']} if vg else None,
            'clips': len(clips), 'ocr_done': done, 'stage': stage, 'sync': sync,
            'track': None if tr is None else track_brief(tr),
            'tracks': [track_brief(t) for t in candidates]}


def trips(conn):
    return [trip_status(conn, t) for t in conn.execute('SELECT * FROM trips ORDER BY start DESC')]


def get_trip(conn, key):
    return conn.execute('SELECT * FROM trips WHERE key=?', (key,)).fetchone()


def main(argv=None):
    ap = argparse.ArgumentParser(description='Каталог роликов регистратора и треков')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('import', help='папки с роликами и/или файлы GPX')
    p.add_argument('paths', nargs='+')
    p = sub.add_parser('card', help='скопировать ролики с карты BYD и импортировать')
    p.add_argument('device')
    p.add_argument('dest')
    p.add_argument('--date')
    sub.add_parser('list')
    a = ap.parse_args(argv)
    conn = connect()
    if a.cmd == 'card':
        import fat32
        with fat32.FAT32(a.device) as fs:
            copied, skipped = fat32.copy_videos(fs, a.dest, a.date)
        print(f'с карты: скопировано {copied}, уже было {skipped}')
        a.paths, a.cmd = [a.dest], 'import'
    if a.cmd == 'import':
        clips, tracks = import_paths(conn, a.paths)
        print(f'новых роликов {clips}, треков {tracks}')
    import sync
    for t in trips(conn):
        s = sync.describe(t['sync']) if t['sync'] else '—'
        track = t['track']['name'] if t['track'] else 'нет трека'
        print(f"{local_str(t['start'])}  {t['clips']:3d} рол.  OCR {t['ocr_done']}/{t['clips']}  "
              f"{t['stage']:8s} {track}: {s}")


if __name__ == '__main__':
    sys.exit(main())
