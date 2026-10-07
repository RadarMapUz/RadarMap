"""Объединение находок по поездкам и сверка с нашей картой.

Объекты (objects.py — по одному на трек сработок в поездке) одного класса
ближе MERGE_M — один кластер. Уверенность кластера — «хоть одна встреча
настоящая»: 1 − Π(1 − qᵢ), где q встречи = уверенность детектора × вес
привязки × полнота трека (min(1, кадров/3)). Три встречи по 0,5 дают 0,88,
одна — 0,5: подтверждение другими поездками так и выглядит.

Сверка (статус):
  светофор — точка highway=traffic_signals из ~/RadarMapBuild/points.geojsonl:
    ≤ CONFIRM_M — «подтверждает», ≤ DIFFER_M — «расходится» (есть, но в другом
    месте), дальше — «новое»;
  переход — highway=crossing, те же пороги;
  знак ограничения — maxspeed дорог из roads.geojsonl рядом: то же число —
    «подтверждает», другое — «расходится», лимитов рядом нет — «новое».

Решения человека хранятся по месту (decisions), не по id кластера: кластеры
пересобираются, решение находит кластер того же класса рядом.
"""
import json
import math
import os
import time

import catalog
import frames as fr
import gpx

BASE = os.path.dirname(catalog.DB_PATH)
POINTS = os.path.expanduser('~/RadarMapBuild/points.geojsonl')
ROADS = os.path.expanduser('~/RadarMapBuild/roads.geojsonl')
LIMITS_CACHE = os.path.join(BASE, 'limits_cache.json')
CROPS_DIR = os.path.join(BASE, 'crops')

MERGE_M = 12.0
MAX_ERR_M = 60.0           # объект с погрешностью больше — в кластеры не идёт
CONFIRM_M = {'traffic_light': 30.0, 'crossing': 25.0, 'speed_limit': 30.0, 'speed_bump': 0.0}
DIFFER_M = {'traffic_light': 60.0, 'crossing': 50.0, 'speed_limit': 30.0, 'speed_bump': 0.0}
DECISION_M = 12.0
CROPS_PER_CLUSTER = 3


# ---------- данные карты ----------

class PointIndex:
    def __init__(self, pts, cell=0.005):
        self.cell, self.g = cell, {}
        for p in pts:
            self.g.setdefault((int(p[0] / cell), int(p[1] / cell)), []).append(p)

    def nearest(self, lat, lon, r_m):
        k = (int(lat / self.cell), int(lon / self.cell))
        span = int(r_m / (self.cell * 80000)) + 1
        best = None
        for a in range(k[0] - span, k[0] + span + 1):
            for b in range(k[1] - span, k[1] + span + 1):
                for p in self.g.get((a, b), ()):
                    d = gpx.haversine(lat, lon, p[0], p[1])
                    if d <= r_m and (best is None or d < best[0]):
                        best = (d, p)
        return best


def load_points(path=POINTS):
    """→ {'traffic_signals': [(lat, lon)], 'crossing': [...]} из OSM-точек."""
    out = {'traffic_signals': [], 'crossing': []}
    with open(path) as f:
        for line in f:
            line = line.strip().lstrip('\x1e')
            if not line:
                continue
            j = json.loads(line)
            hw = (j.get('properties') or {}).get('highway')
            if hw in out:
                lon, lat = j['geometry']['coordinates'][:2]
                out[hw].append((lat, lon))
    return out


def load_limits(bbox, path=ROADS, cache=LIMITS_CACHE):
    """Отрезки дорог с maxspeed в bbox (lat0, lon0, lat1, lon1) → [(lat, lon, lat, lon, км/ч)].
    Файл дорог страны большой (200+ МБ) — выжимка кэшируется."""
    try:
        with open(cache) as f:
            c = json.load(f)
        if all(c['bbox'][i] <= bbox[i] for i in (0, 1)) and all(c['bbox'][i] >= bbox[i] for i in (2, 3)):
            return [tuple(s) for s in c['segs']]
    except (FileNotFoundError, KeyError, json.JSONDecodeError):
        pass
    pad = 0.05
    box = (bbox[0] - pad, bbox[1] - pad, bbox[2] + pad, bbox[3] + pad)
    segs = []
    with open(path) as f:
        for line in f:
            if '"maxspeed"' not in line:
                continue
            line = line.strip().lstrip('\x1e')  # GeoJSONSeq: записи могут начинаться с RS
            if not line:
                continue
            j = json.loads(line)
            v = (j.get('properties') or {}).get('maxspeed', '')
            try:
                kmh = int(str(v).split()[0])
            except (ValueError, IndexError):
                continue
            g = j.get('geometry') or {}
            if g.get('type') != 'LineString':
                continue
            cs = g['coordinates']
            if not any(box[0] <= la <= box[2] and box[1] <= lo <= box[3] for lo, la in cs):
                continue
            for (lo1, la1), (lo2, la2) in zip(cs, cs[1:]):
                segs.append((la1, lo1, la2, lo2, kmh))
    with open(cache, 'w') as f:
        json.dump({'bbox': box, 'segs': segs}, f)
    return segs


class SegIndex:
    def __init__(self, segs, cell=0.005):
        self.cell, self.g = cell, {}
        for s in segs:
            for la, lo in ((s[0], s[1]), (s[2], s[3]), ((s[0] + s[2]) / 2, (s[1] + s[3]) / 2)):
                self.g.setdefault((int(la / cell), int(lo / cell)), set()).add(s)

    def near(self, lat, lon, r_m):
        """→ [(расстояние до отрезка, км/ч)] в радиусе."""
        k = (int(lat / self.cell), int(lon / self.cell))
        span = int(r_m / (self.cell * 80000)) + 1
        seen, out = set(), []
        ky = 111195.0
        kx = ky * math.cos(math.radians(lat))
        for a in range(k[0] - span, k[0] + span + 1):
            for b in range(k[1] - span, k[1] + span + 1):
                for s in self.g.get((a, b), ()):
                    if s in seen:
                        continue
                    seen.add(s)
                    x0, y0 = (s[1] - lon) * kx, (s[0] - lat) * ky
                    x1, y1 = (s[3] - lon) * kx, (s[2] - lat) * ky
                    dx, dy = x1 - x0, y1 - y0
                    L = dx * dx + dy * dy
                    u = max(0.0, min(1.0, -(x0 * dx + y0 * dy) / L)) if L > 0 else 0.0
                    d = math.hypot(x0 + dx * u, y0 + dy * u)
                    if d <= r_m:
                        out.append((d, s[4]))
        return out


# ---------- кластеризация ----------

def object_quality(o):
    return (o['conf'] or 0) * (o['weight'] if o['weight'] is not None else 0.3) * \
        min(1.0, (o['n_frames'] or 1) / 3)


def cluster_objects(objs, merge_m=MERGE_M):
    """objs: [dict(id, cls, value, lat, lon, err_m, conf, weight, n_frames, trip_key)].
    Жадно от самых надёжных: объект присоединяется к ближайшему кластеру своего
    класса в пределах merge_m (центр — взвешенное среднее), иначе — новый."""
    clusters = []
    grid = {}
    cell = 0.0005
    for o in sorted(objs, key=object_quality, reverse=True):
        k = (int(o['lat'] / cell), int(o['lon'] / cell))
        best = None
        for a in range(k[0] - 1, k[0] + 2):
            for b in range(k[1] - 1, k[1] + 2):
                for c in grid.get((a, b), ()):
                    if c['cls'] != o['cls']:
                        continue
                    d = gpx.haversine(o['lat'], o['lon'], c['lat'], c['lon'])
                    if d <= merge_m and (best is None or d < best[0]):
                        best = (d, c)
        if best is None:
            c = {'cls': o['cls'], 'lat': o['lat'], 'lon': o['lon'], 'members': [o], 'wsum': 0.0}
            w = max(object_quality(o), 1e-3) / max(o['err_m'] or 10, 2) ** 2
            c['wsum'] = w
            clusters.append(c)
            grid.setdefault(k, []).append(c)
        else:
            c = best[1]
            w = max(object_quality(o), 1e-3) / max(o['err_m'] or 10, 2) ** 2
            c['lat'] = (c['lat'] * c['wsum'] + o['lat'] * w) / (c['wsum'] + w)
            c['lon'] = (c['lon'] * c['wsum'] + o['lon'] * w) / (c['wsum'] + w)
            c['wsum'] += w
            c['members'].append(o)
    for c in clusters:
        m = c['members']
        c['n_trips'] = len({o['trip_key'] for o in m})
        c['n_frames'] = sum(o['n_frames'] or 1 for o in m)
        prod = 1.0
        for o in m:
            prod *= 1 - min(0.95, object_quality(o))
        c['confidence'] = 1 - prod
        vals = [o['value'] for o in m if o['value'] is not None]
        c['value'] = max(set(vals), key=vals.count) if vals else None
        errs = sorted(o['err_m'] or 10 for o in m)
        c['err_m'] = errs[len(errs) // 2] / math.sqrt(len(m))
    return clusters


def compare(c, pts_idx, seg_idx):
    """Статус кластера против нашей карты → (status, map_ref)."""
    cls = c['cls']
    if cls in ('traffic_light', 'crossing'):
        idx = pts_idx['traffic_signals' if cls == 'traffic_light' else 'crossing']
        hit = idx.nearest(c['lat'], c['lon'], DIFFER_M[cls])
        if hit is None:
            return 'new', {'near': None}
        d = hit[0]
        return ('confirms' if d <= CONFIRM_M[cls] else 'differs'), {
            'near': 'osm_' + ('signal' if cls == 'traffic_light' else 'crossing'),
            'dist_m': round(d, 1), 'lat': hit[1][0], 'lon': hit[1][1]}
    if cls == 'speed_bump':
        return 'new', {'near': None, 'note': 'неровностей в нашей карте нет — сверять не с чем'}
    if seg_idx is None:
        return 'new', {'near': None, 'note': 'лимиты не загружены'}
    near = seg_idx.near(c['lat'], c['lon'], CONFIRM_M[cls])
    if not near:
        return 'new', {'near': None}
    vals = sorted({v for _, v in near})
    dist = round(min(d for d, _ in near), 1)
    if c['value'] in vals:
        return 'confirms', {'near': 'maxspeed', 'values': vals, 'dist_m': dist}
    return 'differs', {'near': 'maxspeed', 'values': vals, 'dist_m': dist}


def rebuild(conn, log=print, with_limits=True, crops=True):
    objs = [dict(r) for r in conn.execute(
        'SELECT * FROM objects WHERE lat IS NOT NULL AND err_m <= ?', (MAX_ERR_M,))]
    if not objs:
        return {'clusters': 0}
    clusters = cluster_objects(objs)
    lats = [o['lat'] for o in objs]
    lons = [o['lon'] for o in objs]
    raw = load_points()
    pts_idx = {k: PointIndex(v) for k, v in raw.items()}
    seg_idx = None
    if with_limits and any(c['cls'] == 'speed_limit' for c in clusters):
        seg_idx = SegIndex(load_limits((min(lats), min(lons), max(lats), max(lons))))
    stats = {}
    with conn:
        conn.execute('UPDATE objects SET cluster=NULL')
        conn.execute('DELETE FROM clusters')
        for c in clusters:
            status, ref = compare(c, pts_idx, seg_idx)
            cur = conn.execute('INSERT INTO clusters(cls, value, lat, lon, err_m, n_trips, n_frames, '
                               'confidence, status, map_ref) VALUES(?,?,?,?,?,?,?,?,?,?)',
                               (c['cls'], c['value'], c['lat'], c['lon'], c['err_m'], c['n_trips'],
                                c['n_frames'], c['confidence'], status, json.dumps(ref, ensure_ascii=False)))
            conn.executemany('UPDATE objects SET cluster=? WHERE id=?',
                             [(cur.lastrowid, o['id']) for o in c['members']])
            stats[(c['cls'], status)] = stats.get((c['cls'], status), 0) + 1
    if crops:
        n = make_cluster_crops(conn)
        log(f'вырезок новых: {n}')
    out = {f'{a}/{b}': n for (a, b), n in sorted(stats.items())}
    out['clusters'] = len(clusters)
    return out


# ---------- вырезки для карточки ----------

def best_detections(conn, cluster_id, n=CROPS_PER_CLUSTER):
    """Лучшие сработки кластера: по одной-две с разных поездок, крупные и уверенные."""
    rows = conn.execute(
        'SELECT d.*, f.path, f.trip_key, f.t FROM detections d JOIN frames f ON f.id=d.frame_id '
        'JOIN objects o ON o.id=d.obj WHERE o.cluster=? ORDER BY d.conf * (d.w + d.h) DESC',
        (cluster_id,)).fetchall()
    out, trips = [], {}
    for r in rows:
        if trips.get(r['trip_key'], 0) >= 2 and len(rows) > n:
            continue
        trips[r['trip_key']] = trips.get(r['trip_key'], 0) + 1
        out.append(r)
        if len(out) >= n:
            break
    return out


def crop_box(d):
    """Рамка сработки (исходный кадр) → (вырезка, рамка объекта) в пикселях JPEG детекторов."""
    x, y = d['x'] * fr.SCALE, (d['y'] - fr.CROP_TOP) * fr.SCALE
    w, h = d['w'] * fr.SCALE, d['h'] * fr.SCALE
    side = max(80.0, 4.0 * max(w, h))
    cx, cy = x + w / 2, y + h / 2
    bx = max(0.0, min(fr.OUT_W - side, cx - side / 2))
    by = max(0.0, min(fr.OUT_H - side, cy - side / 2))
    side = min(side, fr.OUT_H)
    return [bx, by, side, side], [x, y, w, h]


def make_cluster_crops(conn):
    import detect
    os.makedirs(CROPS_DIR, exist_ok=True)
    have = {r[0] for r in conn.execute('SELECT det_id FROM crops')}
    specs, rows = [], []
    for (cid,) in conn.execute('SELECT id FROM clusters').fetchall():
        for d in best_detections(conn, cid):
            if d['id'] in have or not os.path.exists(d['path']):
                continue
            box, keep = crop_box(d)
            dst = os.path.join(CROPS_DIR, f"{d['id']}.jpg")
            specs.append({'src': d['path'], 'dst': dst, 'box': box, 'keep': keep})
            rows.append((d['id'], dst))
    if not specs:
        return 0
    detect.make_crops(specs)
    ok = [(i, p) for i, p in rows if os.path.exists(p)]
    with conn:
        conn.executemany('INSERT OR REPLACE INTO crops(det_id, path) VALUES(?,?)', ok)
    return len(ok)


def crop_for(conn, det_id):
    """Вырезка одной сработки (для разметки) — по запросу, с тем же размытием."""
    import detect
    r = conn.execute('SELECT path FROM crops WHERE det_id=?', (det_id,)).fetchone()
    if r and os.path.exists(r[0]):
        return r[0]
    d = conn.execute('SELECT d.*, f.path FROM detections d JOIN frames f ON f.id=d.frame_id '
                     'WHERE d.id=?', (det_id,)).fetchone()
    if d is None or not os.path.exists(d['path']):
        return None
    os.makedirs(CROPS_DIR, exist_ok=True)
    box, keep = crop_box(d)
    dst = os.path.join(CROPS_DIR, f'{det_id}.jpg')
    detect.make_crops([{'src': d['path'], 'dst': dst, 'box': box, 'keep': keep}])
    if not os.path.exists(dst):
        return None
    with conn:
        conn.execute('INSERT OR REPLACE INTO crops(det_id, path) VALUES(?,?)', (det_id, dst))
    return dst


def decision_for(conn, cls, lat, lon):
    rows = conn.execute('SELECT * FROM decisions WHERE cls=? AND lat BETWEEN ? AND ? '
                        'AND lon BETWEEN ? AND ? ORDER BY at DESC',
                        (cls, lat - 0.0003, lat + 0.0003, lon - 0.0004, lon + 0.0004)).fetchall()
    for r in rows:
        if gpx.haversine(lat, lon, r['lat'], r['lon']) <= DECISION_M:
            return r['decision']
    return None


def decide(conn, cluster_id, decision):
    c = conn.execute('SELECT * FROM clusters WHERE id=?', (cluster_id,)).fetchone()
    if c is None:
        return False
    with conn:
        conn.execute('DELETE FROM decisions WHERE cls=? AND abs(lat-?)<0.0002 AND abs(lon-?)<0.0003',
                     (c['cls'], c['lat'], c['lon']))
        if decision in ('accept', 'reject'):
            conn.execute('INSERT INTO decisions(cls, value, lat, lon, decision, at) VALUES(?,?,?,?,?,?)',
                         (c['cls'], c['value'], c['lat'], c['lon'], decision, time.time()))
    return True
