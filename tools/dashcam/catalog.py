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
"""


def connect(path=None):
    path = path or DB_PATH
    if path != ':memory:':
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    conn.executescript(SCHEMA)
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


def import_paths(conn, paths, probe_fn=probe, log=print):
    """Папки и файлы: *.mp4 с именем-временем → ролики, *.gpx → треки."""
    clips = tracks = 0
    files = []
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
        elif low.endswith('.gpx'):
            if import_gpx(conn, f):
                tracks += 1
                log(f'трек {os.path.basename(f)}')
    regroup(conn)
    return clips, tracks


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
        stage = 'no_gpx'
    elif done < len(clips):
        stage = 'ocr'
    elif sync is None:
        stage = 'sync'
    elif not sync['good']:
        stage = 'bad_sync'
    else:
        stage = 'ready'
    return {'key': trip['key'], 'start': trip['start'], 'end': trip['end'],
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
