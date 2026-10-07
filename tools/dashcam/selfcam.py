#!/usr/bin/env python3
"""Опоры без GPX: регистратор сам узнаёт, что проезжает камеру фиксации.

1. Выборка без человека (dataset): «camera» — кадры за MIN_BEFORE…MAX_BEFORE с
   до проезда камеры из GPX (wpt) и в 8–70 м до неё по пути; «none» — кадры
   на ходу дальше NEG_MIN_M от любой камеры базы и от любого проезда.
   Train/val делятся ПО ПОЕЗДКАМ: соседние кадры одной поездки почти
   одинаковы, и деление по кадрам мерило бы память, а не умение.
2. Классификатор — Create ML MLImageClassifier (camclass.swift).
3. events: вероятность по кадрам поездки → всплески → «проезд неизвестной
   камеры» с временем (конец всплеска ≈ момент проезда).
4. Опознание — anchorhmm.py.

    python3 selfcam.py dataset        — собрать выборку (жёсткие ссылки на кадры)
    python3 selfcam.py train          — обучить, точность на val
    python3 selfcam.py predict KEY…   — вероятности по кадрам поездок → camprob
"""
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

import catalog
import geo
import gpx
import locate
import sync

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.dirname(catalog.DB_PATH)
DATA_DIR = os.path.join(BASE, 'selfcam')
MODEL = os.path.join(BASE, 'selfcam', 'camera.mlmodel')
SWIFT_SRC = os.path.join(HERE, 'camclass.swift')
BIN = os.path.join(BASE, 'bin', 'camclass')
SWIFTC = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
MACOS_SDK = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
CAMERAS_JSON = os.path.join(HERE, '..', '..', 'RadarMap', 'Resources', 'cameras.json')
ALL_TRIPS_GPX = os.path.join(BASE, 'all_trips.gpx')

MIN_BEFORE, MAX_BEFORE = 0.3, 3.0
POS_MIN_M, POS_MAX_M = 8.0, 70.0
NEG_MIN_M = 300.0
NEG_MIN_KMH = 10.0
NEG_PER_POS = 2
VAL_SHARE = 0.25

SCHEMA = """
CREATE TABLE IF NOT EXISTS camprob(frame_id INTEGER PRIMARY KEY, p REAL);
-- Проезды камер, найденные по видео: время (часы регистратора), опознанная
-- камера (NULL — не опознана), уверенность, метод.
CREATE TABLE IF NOT EXISTS video_anchors(
  id INTEGER PRIMARY KEY, trip_key TEXT NOT NULL, t REAL NOT NULL, p REAL,
  camera_id INTEGER, lat REAL, lon REAL, conf REAL, method TEXT, hidden_eval INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS video_anchors_trip ON video_anchors(trip_key);
CREATE TABLE IF NOT EXISTS video_geo(
  trip_key TEXT PRIMARY KEY, status TEXT, n INTEGER, detail TEXT, computed REAL
);
"""


def connect():
    conn = catalog.connect()
    conn.executescript(SCHEMA)
    return conn


def load_cameras(path=CAMERAS_JSON):
    with open(path) as f:
        return json.load(f)


class Grid:
    """Сетка 0,01° для «есть ли камера ближе R»."""

    def __init__(self, pts, cell=0.01):
        self.cell, self.g = cell, {}
        for p in pts:
            self.g.setdefault((int(p[0] / cell), int(p[1] / cell)), []).append(p)

    def near(self, lat, lon, r_m):
        k = (int(lat / self.cell), int(lon / self.cell))
        span = int(r_m / 1000 / (self.cell * 80)) + 1
        out = []
        for i in range(k[0] - span, k[0] + span + 1):
            for j in range(k[1] - span, k[1] + span + 1):
                for p in self.g.get((i, j), ()):
                    if gpx.haversine(lat, lon, p[0], p[1]) <= r_m:
                        out.append(p)
        return out


def ensure_binary():
    if os.path.exists(BIN) and os.path.getmtime(BIN) >= os.path.getmtime(SWIFT_SRC):
        return BIN
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    subprocess.run([SWIFTC, '-O', '-sdk', MACOS_SDK, SWIFT_SRC, '-o', BIN], check=True)
    return BIN


def label_frames(conn, key, wpts, cam_grid, wpt_grid):
    """Кадры поездки → [(путь, 'camera'|'none')] по правилам выборки."""
    trip = catalog.get_trip(conn, key)
    odo = locate.Odometer(sync.clean_ocr(catalog.ocr_series(conn, key)))
    anchors = geo.anchors_for(wpts, trip['start'], trip['end'])
    rows = conn.execute('SELECT t, path, lat, lon, kmh FROM frames WHERE trip_key=? ORDER BY t',
                        (key,)).fetchall()
    pos, neg = [], []
    for r in rows:
        lab = None
        for a in anchors:
            dt = a[0] - r['t']
            if MIN_BEFORE <= dt <= MAX_BEFORE:
                d = odo.at(a[0]) - odo.at(r['t'])
                if POS_MIN_M <= d <= POS_MAX_M:
                    lab = 'camera'
                    break
        if lab:
            pos.append(r['path'])
            continue
        if r['lat'] is None or (r['kmh'] or 0) < NEG_MIN_KMH:
            continue
        if any(MIN_BEFORE - 10 <= a[0] - r['t'] <= MAX_BEFORE + 10 for a in anchors):
            continue
        if cam_grid.near(r['lat'], r['lon'], NEG_MIN_M) or wpt_grid.near(r['lat'], r['lon'], NEG_MIN_M):
            continue
        neg.append(r['path'])
    return pos, neg


# Камера фиксации висит над дорогой: в выборку и в классификатор идёт верхняя
# полоса кадра — машины и асфальт только мешают (на целом кадре точность
# на val была на уровне монетки).
BAND = 0.55


def top_band(src, dst):
    subprocess.run([os.environ.get('FFMPEG', '/opt/homebrew/bin/ffmpeg'), '-v', 'error', '-y', '-i', src,
                    '-vf', f'crop=iw:ih*{BAND}:0:0', '-q:v', '4', dst], check=True)


def build_dataset(conn, seed=7, log=print):
    _, wpts = geo.load_all_trips(ALL_TRIPS_GPX)
    cams = [(c['lat'], c['lon']) for c in load_cameras()]
    cam_grid, wpt_grid = Grid(cams), Grid([(w[1], w[2]) for w in wpts])
    keys = [r[0] for r in conn.execute(
        'SELECT DISTINCT trip_key FROM frames WHERE lat IS NOT NULL ORDER BY trip_key')]
    per_trip = {}
    for k in keys:
        pos, neg = label_frames(conn, k, wpts, cam_grid, wpt_grid)
        if pos:
            per_trip[k] = (pos, neg)
    rnd = random.Random(seed)
    trips = sorted(per_trip)
    rnd.shuffle(trips)
    # val — четверть поездок, но не меньше одной
    nval = max(1, round(len(trips) * VAL_SHARE))
    split = {k: ('val' if i < nval else 'train') for i, k in enumerate(trips)}
    if os.path.isdir(DATA_DIR):
        for sub in ('train', 'val'):
            shutil.rmtree(os.path.join(DATA_DIR, sub), ignore_errors=True)
    counts = {}
    for k, (pos, neg) in per_trip.items():
        rnd.shuffle(neg)
        neg = neg[:NEG_PER_POS * len(pos)]
        for lab, paths in (('camera', pos), ('none', neg)):
            d = os.path.join(DATA_DIR, split[k], lab)
            os.makedirs(d, exist_ok=True)
            for p in paths:
                dst = os.path.join(d, k + '_' + os.path.basename(p))
                if not os.path.exists(dst):
                    top_band(p, dst)
            counts[(split[k], lab)] = counts.get((split[k], lab), 0) + len(paths)
    info = {'trips': {s: sorted(k for k in trips if split[k] == s) for s in ('train', 'val')},
            'counts': {f'{a}/{b}': n for (a, b), n in counts.items()}}
    with open(os.path.join(DATA_DIR, 'split.json'), 'w') as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    log(json.dumps(info['counts'], ensure_ascii=False), f"поездок train {len(info['trips']['train'])}, "
        f"val {len(info['trips']['val'])}")
    return info


def train(log=print):
    binary = ensure_binary()
    out = subprocess.run([binary, 'train', DATA_DIR, MODEL], capture_output=True, text=True, check=True)
    line = [l for l in out.stdout.splitlines() if l.startswith('{')][-1]
    res = json.loads(line)
    with open(os.path.join(DATA_DIR, 'metrics.json'), 'w') as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    log(json.dumps(res, ensure_ascii=False))
    return res


def predict(conn, key, only_new=True):
    binary = ensure_binary()
    q = ('SELECT f.id, f.path FROM frames f LEFT JOIN camprob c ON c.frame_id=f.id '
         'WHERE f.trip_key=?' + (' AND c.frame_id IS NULL' if only_new else ''))
    rows = conn.execute(q, (key,)).fetchall()
    if not rows:
        return 0
    by_path = {r['path']: r['id'] for r in rows}
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        f.write('\n'.join(p for p in by_path if os.path.exists(p)))
        lst = f.name
    try:
        out = subprocess.run([binary, 'predict', MODEL, lst], capture_output=True, text=True,
                             check=True).stdout
    finally:
        os.remove(lst)
    rows = []
    for line in out.splitlines():
        if '\t' not in line:
            continue
        p, v = line.rsplit('\t', 1)
        if p in by_path:
            rows.append((by_path[p], float(v)))
    with conn:
        conn.executemany('INSERT OR REPLACE INTO camprob(frame_id, p) VALUES(?,?)', rows)
    return len(rows)


# ---------- события «проезд неизвестной камеры» ----------

EVENT_P = 0.6          # кадр «камера близко»
EVENT_MIN_FRAMES = 2   # всплеск — хотя бы столько кадров подряд
EVENT_GAP_S = 2.5      # кадры всплеска не дальше друг от друга
EVENT_LEAD_S = 0.8     # проезд — чуть позже последнего «близкого» кадра


def events_from_series(series, p_min=EVENT_P, min_frames=EVENT_MIN_FRAMES, gap=EVENT_GAP_S,
                       lead=EVENT_LEAD_S):
    """series: [(t, p)] по времени (только кадры на ходу) → [(t_проезда, max p, кадров)]."""
    out, run = [], []
    for t, p in series:
        if p >= p_min and (not run or t - run[-1][0] <= gap):
            run.append((t, p))
            continue
        if len(run) >= min_frames:
            out.append((run[-1][0] + lead, max(q for _, q in run), len(run)))
        run = [(t, p)] if p >= p_min else []
    if len(run) >= min_frames:
        out.append((run[-1][0] + lead, max(q for _, q in run), len(run)))
    return out


def trip_events(conn, key, min_kmh=5.0):
    rows = conn.execute('SELECT f.t, c.p, f.kmh FROM frames f JOIN camprob c ON c.frame_id=f.id '
                        'WHERE f.trip_key=? ORDER BY f.t', (key,)).fetchall()
    return events_from_series([(r['t'], r['p']) for r in rows if (r['kmh'] or 0) >= min_kmh])


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    conn = connect()
    if argv[0] == 'dataset':
        build_dataset(conn)
    elif argv[0] == 'train':
        train()
    elif argv[0] == 'oracle':
        oracle_eval(conn, argv[1:] or None)
    elif argv[0] == 'mark':
        print(mark_unlocated(conn, ' '.join(argv[1:]) or 'классификатор «камера близко» не обучен'))
    elif argv[0] == 'predict':
        keys = argv[1:] or [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM frames')]
        for k in keys:
            print(k, predict(conn, k))



# ---------- честная проверка и статусы ----------

def oracle_eval(conn, keys=None, log=print):
    """Опознание при ИДЕАЛЬНЫХ событиях: времена проездов берутся из GPX, камеры —
    спрятаны. Если даже так цепочка не опознаётся верно, классификатор не спасёт.
    → [(поездка, статус, событий, найдено, верно)]."""
    import re
    import anchorhmm
    trks, wpts = geo.load_all_trips(ALL_TRIPS_GPX)
    cams = load_cameras()
    idx = anchorhmm.CamIndex(cams)
    osrm = geo.OSRM(conn)
    keys = keys or [r[0] for r in conn.execute('SELECT DISTINCT trip_key FROM frames WHERE lat IS NOT NULL')]
    out = []
    for key in keys:
        trip = catalog.get_trip(conn, key)
        odo = locate.Odometer(sync.clean_ocr(catalog.ocr_series(conn, key)))
        an = [a for a in geo.anchors_for(wpts, trip['start'], trip['end']) if odo.covers(a[0])]
        if len(an) < 3:
            continue
        res = anchorhmm.identify([(a[0], 1.0) for a in an], odo.at, idx, osrm)
        truth = {}
        for a in an:
            m = re.search(r'камера (\d+)', a[3])
            if m:
                truth[a[0]] = int(m.group(1))
        got = [(t, cams[j]['id']) for t, j, _ in res['anchors']]
        ok = sum(1 for t, cid in got if truth.get(t) == cid)
        out.append((key, res['status'], len(an), len(got), ok))
        log(key, res['status'], f'событий {len(an)}, опознано {len(got)}, верно {ok}')
    return out


def mark_unlocated(conn, reason):
    """Поездки без опор GPX: опоры по видео не найдены — честное «не привязана»."""
    import batch
    n = 0
    with conn:
        for t in batch.day_trips(conn):
            if batch.has_anchors(conn, t):
                continue
            conn.execute('INSERT OR REPLACE INTO video_geo(trip_key, status, n, detail, computed) '
                         'VALUES(?,?,?,?,strftime(\'%s\',\'now\'))', (t['key'], 'not_located', 0, reason))
            n += 1
    return n


if __name__ == '__main__':
    sys.exit(main())
