"""Общее для этапа «камеры фиксации по видео»: пути, базы, данные поездок.

Общая БД разбора (dashcam.db) — ТОЛЬКО чтение: параллельно в неё пишет
ночной разбор. Всё своё — в ~/RadarMapBuild/dashcam/cams/cams.db.
"""
import json
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DASHCAM = os.path.dirname(HERE)
sys.path.insert(0, DASHCAM)

import geo  # noqa: E402
import sync  # noqa: E402

import passes  # noqa: E402

BASE = os.path.expanduser('~/RadarMapBuild/dashcam')
SHARED_DB = os.environ.get('DASHCAM_DB', os.path.join(BASE, 'dashcam.db'))
OUT = os.path.join(BASE, 'cams')
CAMS_DB = os.path.join(OUT, 'cams.db')
ALL_TRIPS_GPX = os.path.join(BASE, 'all_trips.gpx')
CAMERAS_JSON = os.path.join(DASHCAM, '..', '..', 'RadarMap', 'Resources', 'cameras.json')
FFMPEG = os.environ.get('FFMPEG', '/opt/homebrew/bin/ffmpeg')
SWIFTC = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
MACOS_SDK = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'

SCHEMA = """
CREATE TABLE IF NOT EXISTS route_cache(key TEXT PRIMARY KEY, body TEXT, fetched REAL);
-- Проезд камеры из GPX с исправленным временем (см. passes.py).
CREATE TABLE IF NOT EXISTS gt_passes(
  trip_key TEXT, camera_id INTEGER, t_wpt REAL, t_pass REAL, kmh_wpt REAL,
  lat REAL, lon REAL, PRIMARY KEY(trip_key, t_wpt));
-- Место кадра по опорам с исправленным временем (общий frames.lat/lon сдвинут на ~720 м).
CREATE TABLE IF NOT EXISTS frame_geo(
  frame_id INTEGER PRIMARY KEY, trip_key TEXT, t REAL, lat REAL, lon REAL, course REAL, weight REAL);
CREATE INDEX IF NOT EXISTS frame_geo_trip ON frame_geo(trip_key);
-- Вероятность «камера близко» по кадрам.
CREATE TABLE IF NOT EXISTS camprob(frame_id INTEGER, trip_key TEXT, t REAL, p REAL, model TEXT,
  PRIMARY KEY(frame_id, model));
CREATE INDEX IF NOT EXISTS camprob_trip ON camprob(trip_key);
-- События «проезд камеры» по видео.
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY, trip_key TEXT, t REAL, p REAL, n INTEGER, frame_id INTEGER,
  lat REAL, lon REAL, course REAL, camera_id INTEGER, cam_dist REAL, method TEXT, run TEXT);
CREATE INDEX IF NOT EXISTS events_trip ON events(trip_key, run);
-- Кандидаты для продукта: «новая» и «возможно, снята».
CREATE TABLE IF NOT EXISTS candidates(
  id INTEGER PRIMARY KEY, kind TEXT, camera_id INTEGER, lat REAL, lon REAL, course REAL,
  n_trips INTEGER, n_events INTEGER, n_passes INTEGER, p REAL, crops TEXT, detail TEXT, at REAL);
CREATE TABLE IF NOT EXISTS reports(name TEXT PRIMARY KEY, body TEXT, at REAL);
"""


def shared():
    """Общая БД — только чтение (mode=ro), ждём блокировку до 30 с."""
    c = sqlite3.connect(f'file:{SHARED_DB}?mode=ro', uri=True, timeout=30)
    c.row_factory = sqlite3.Row
    return c


def own(path=None):
    path = path or CAMS_DB
    if path != ':memory:':
        os.makedirs(os.path.dirname(path), exist_ok=True)
    c = sqlite3.connect(path, timeout=60)
    c.row_factory = sqlite3.Row
    c.execute('PRAGMA journal_mode=WAL')
    c.executescript(SCHEMA)
    return c


def save_report(conn, name, obj):
    import time
    with conn:
        conn.execute('INSERT OR REPLACE INTO reports(name, body, at) VALUES(?,?,?)',
                     (name, json.dumps(obj, ensure_ascii=False), time.time()))
    with open(os.path.join(OUT, name + '.json'), 'w') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)


_cams = None


def cameras():
    global _cams
    if _cams is None:
        with open(CAMERAS_JSON) as f:
            _cams = json.load(f)
    return _cams


_all = None


def all_trips():
    global _all
    if _all is None:
        _all = geo.load_all_trips(ALL_TRIPS_GPX)
    return _all


WPT_RE = re.compile(r'камера (\d+), (\d+) км/ч')


def parse_wpt(w):
    m = WPT_RE.search(w[3])
    return (int(m.group(1)), float(m.group(2))) if m else (None, None)


def trips_with_frames(sh):
    return [dict(r) for r in sh.execute(
        'SELECT t.key, t.start, t.end, COUNT(f.id) n FROM trips t JOIN frames f ON f.trip_key=t.key '
        'GROUP BY t.key HAVING n >= 50 ORDER BY t.key')]


def speed_series(sh, key):
    rows = sh.execute(
        'SELECT c.start + o.t AS ts, o.kmh FROM ocr o JOIN clips c ON c.id=o.clip_id '
        'WHERE c.trip_key=? AND o.kmh IS NOT NULL ORDER BY ts', (key,)).fetchall()
    return sync.clean_ocr([(r[0], r[1]) for r in rows])


def trip_frames(sh, key):
    return [dict(r) for r in sh.execute(
        'SELECT id, t, kmh, path, clip_id, pos FROM frames WHERE trip_key=? ORDER BY t', (key,))]


def corrected_wpts(trip, odo):
    """wpt поездки → [(t_проезда, lat, lon, name)] (для geo.build_trip_geo) и
    подробности [(camera_id, t_wpt, t_pass, kmh_wpt, lat, lon)]."""
    _, wpts = all_trips()
    out, info = [], []
    for w in geo.anchors_for(wpts, trip['start'], trip['end']):
        tp = passes.pass_time(odo, w[0])
        if tp is None:
            continue
        cid, v = parse_wpt(w)
        out.append((tp, w[1], w[2], w[3]))
        info.append((cid, w[0], tp, v, w[1], w[2]))
    return out, info
