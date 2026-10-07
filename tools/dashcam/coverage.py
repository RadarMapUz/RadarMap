"""Покрытие дорог видео: что уже снято достаточно, чтобы не разбирать снова.

Дорога режется на участки ~50 м с направлением: ключ — клетка сетки
CELL_M × CELL_M плюс курс, квантованный по 45° (туда и обратно — разные
участки: знаки и светофоры у каждого направления свои).

Хороший проезд участка — поездка, у которой там есть кадр днём, на ходу
(> GOOD_KMH) и с надёжной привязкой (вес ≥ GOOD_WEIGHT). Участок
«закреплён», когда хороших проездов ≥ PIN_PASSES в разные дни И находки
стабильны: последние STABLE_LAST проезда не добавили ни одного нового
кластера (объекта или знака), которого не видели раньше. Закреплённые
участки в новых поездках не разбираются (кадры не вынимаются, детекторы
не гоняются) — повторные поездки дом↔работа не тратят ночь.

Всё считается из уже разобранных кадров — и задним числом тоже.
"""
import json
import math
import time

import catalog

CELL_M = 50.0
GOOD_KMH = 15.0
GOOD_WEIGHT = 0.5
PIN_PASSES = 4
STABLE_LAST = 2
REPEAT_NOVELTY = 0.05   # меньше этой доли нового пути — поездка «повтор»

SCHEMA = """
CREATE TABLE IF NOT EXISTS coverage(
  key TEXT PRIMARY KEY, lat REAL, lon REAL, course INTEGER,
  passes INTEGER, days INTEGER, frames INTEGER, pinned INTEGER, detail TEXT, updated REAL
);
"""

_LAT_STEP = CELL_M / 111195.0


def cell_key(lat, lon, course):
    """(lat, lon, курс°) → ключ участка «i:j:c». Шаг по долготе — по широте
    Ташкента: на сотню км вокруг ошибка размера клетки — проценты."""
    lon_step = CELL_M / (111195.0 * math.cos(math.radians(41.3)))
    i, j = int(math.floor(lat / _LAT_STEP)), int(math.floor(lon / lon_step))
    c = int(round((course or 0) / 45.0)) % 8
    return f'{i}:{j}:{c}'


def cell_center(key):
    i, j, c = (int(x) for x in key.split(':'))
    lon_step = CELL_M / (111195.0 * math.cos(math.radians(41.3)))
    return (i + 0.5) * _LAT_STEP, (j + 0.5) * lon_step, c * 45


def connect(conn):
    conn.executescript(SCHEMA)
    return conn


def compute(rows):
    """rows: [(trip_key, день, t, lat, lon, course, kmh, weight, [кластеры кадра])] по времени.
    → {ключ: dict(passes, days, frames, pinned, new_by_pass)} — чистая функция."""
    cells = {}
    for trip, day, t, lat, lon, course, kmh, w, clus in rows:
        if lat is None or course is None:
            continue
        k = cell_key(lat, lon, course)
        c = cells.setdefault(k, {'frames': 0, 'trips': {}})
        c['frames'] += 1
        good = (kmh or 0) > GOOD_KMH and (w or 0) >= GOOD_WEIGHT
        tr = c['trips'].setdefault(trip, {'day': day, 't': t, 'good': False, 'clusters': set()})
        tr['good'] = tr['good'] or good
        tr['clusters'].update(clus)
    out = {}
    for k, c in cells.items():
        goods = sorted((v for v in c['trips'].values() if v['good']), key=lambda v: v['t'])
        seen, new_by_pass = set(), []
        for v in goods:
            new = v['clusters'] - seen
            new_by_pass.append(len(new))
            seen |= v['clusters']
        days = len({v['day'] for v in goods})
        stable = len(new_by_pass) >= STABLE_LAST + 1 and not any(new_by_pass[-STABLE_LAST:])
        out[k] = {'passes': len(goods), 'days': days, 'frames': c['frames'],
                  'pinned': days >= PIN_PASSES and stable, 'new_by_pass': new_by_pass}
    return out


def rebuild(conn):
    """Покрытие по всем разобранным кадрам → таблица coverage."""
    connect(conn)
    # кластеры объектов и знаков, увиденные с кадра
    obj_cl = {}
    for fid, cl in conn.execute('SELECT d.frame_id, o.cluster FROM detections d JOIN objects o '
                                'ON o.id=d.obj WHERE o.cluster IS NOT NULL'):
        obj_cl.setdefault(fid, set()).add(('o', cl))
    for fid, cl in conn.execute('SELECT frame_id, cluster FROM sign_crops WHERE cluster IS NOT NULL'):
        obj_cl.setdefault(fid, set()).add(('s', cl))
    rows = []
    for r in conn.execute('SELECT id, trip_key, t, lat, lon, course, kmh, weight FROM frames '
                          'WHERE lat IS NOT NULL ORDER BY t'):
        day = time.strftime('%Y-%m-%d', time.gmtime(r['t'] + 5 * 3600))
        rows.append((r['trip_key'], day, r['t'], r['lat'], r['lon'], r['course'], r['kmh'],
                     r['weight'], obj_cl.get(r['id'], ())))
    cells = compute(rows)
    now = time.time()
    with conn:
        conn.execute('DELETE FROM coverage')
        conn.executemany('INSERT INTO coverage(key, lat, lon, course, passes, days, frames, pinned, detail, '
                         'updated) VALUES(?,?,?,?,?,?,?,?,?,?)',
                         [(k, *cell_center(k), v['passes'], v['days'], v['frames'], int(v['pinned']),
                           json.dumps(v['new_by_pass']), now) for k, v in cells.items()])
    return {'cells': len(cells), 'pinned': sum(1 for v in cells.values() if v['pinned'])}


def pinned_keys(conn):
    connect(conn)
    return {r[0] for r in conn.execute('SELECT key FROM coverage WHERE pinned=1')}


def path_cells(shape):
    """Ломаная [(lat, lon)] → [(ключ, длина м)] по шагам ~10 м (курс — по отрезку)."""
    import gpx
    out = []
    for (a, b), (c, d) in zip(shape, shape[1:]):
        seg = gpx.haversine(a, b, c, d)
        if seg <= 0:
            continue
        kx = math.cos(math.radians(a))
        course = math.degrees(math.atan2((d - b) * kx, c - a)) % 360
        n = max(1, int(seg / 10))
        for k in range(n):
            f = (k + 0.5) / n
            out.append((cell_key(a + (c - a) * f, b + (d - b) * f, course), seg / n))
    return out


def novelty(shape, pinned):
    """Доля пути по ломаной, не лежащая на закреплённых участках (1 — всё новое)."""
    cells = path_cells(shape)
    total = sum(m for _, m in cells)
    if total <= 0:
        return 1.0, 0.0
    new = sum(m for k, m in cells if k not in pinned)
    return new / total, total
