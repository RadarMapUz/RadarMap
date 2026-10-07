"""Точка объекта на карте: трек сработок по соседним кадрам → триангуляция.

Модель объектива: направление на объект = курс машины + угол по горизонтали
в кадре + поправка установки (регистратор может смотреть чуть в сторону).
Угол по горизонтали — модель «равноудалённого» широкоугольника
α = (x − cx) / f, f = (W/2) / (HFOV/2); для угла обзора ~120° она ближе к
правде, чем точечная камера (у той края кадра растянуты). Параметры —
в calib.json рядом с каталогом (их пишет calibrate.py), по умолчанию 120°.

Один объект виден в нескольких кадрах подряд: сработки связываются в трек
(тот же класс, рамка сдвигается немного и растёт, объект уходит от центра
к краю). Лучи из точек машины пересекаются → точка объекта (МНК по
перпендикулярным расстояниям). Если лучи почти параллельны (объект прямо
по курсу, разброс углов < MIN_SPREAD_DEG) — расстояние по размеру рамки и
известному размеру объекта, с честно большой погрешностью.
"""
import json
import math
import os

import catalog
import frames as fr

EARTH_R = 6371000.0
CALIB_PATH = os.path.join(os.path.dirname(catalog.DB_PATH), 'calib.json')
DEFAULT_CALIB = {'hfov_deg': 120.0, 'yaw_deg': 0.0, 'cx': fr.SRC_W / 2, 'model': 'equidistant'}

# Реальные размеры, м: знак 3.24 Ø 0,7 (в городе 0,6–0,7), квадрат 5.19 — 0,6,
# горящая секция светофора — светящийся круг ~0,2 (секция 0,3 с козырьком).
REAL_SIZE_M = {'speed_limit': 0.7, 'crossing': 0.6, 'traffic_light': 0.2}
MIN_SPREAD_DEG = 2.5
MAX_RANGE_M = 120.0
BEARING_SIGMA_DEG = 1.0
TRACK_MAX_GAP_S = 3.0          # кадры дальше по времени — разные встречи…
TRACK_MAX_GAP_STOP_M = 15.0    # …если только машина не стояла (на стоянке кадр раз в 10 с)


def load_calib(path=CALIB_PATH):
    c = dict(DEFAULT_CALIB)
    try:
        with open(path) as f:
            c.update(json.load(f))
    except FileNotFoundError:
        pass
    return c


class Lens:
    def __init__(self, hfov_deg=120.0, yaw_deg=0.0, cx=fr.SRC_W / 2, model='equidistant', **_):
        self.hfov, self.yaw, self.cx, self.model = hfov_deg, yaw_deg, cx, model
        half = math.radians(hfov_deg) / 2
        if model == 'pinhole':
            self.f = (fr.SRC_W / 2) / math.tan(half)
        else:
            self.f = (fr.SRC_W / 2) / half

    def angle(self, x):
        """Пиксель по горизонтали исходного кадра → угол от оси объектива, ° (вправо +)."""
        u = (x - self.cx) / self.f
        return math.degrees(math.atan(u) if self.model == 'pinhole' else u) + self.yaw

    def pixel(self, angle_deg):
        a = math.radians(angle_deg - self.yaw)
        u = math.tan(a) if self.model == 'pinhole' else a
        return self.cx + u * self.f

    def local_f(self, x):
        """Пикселей на радиан в точке x (для оценки расстояния по размеру рамки)."""
        if self.model == 'pinhole':
            return self.f
        return self.f  # у равноудалённой модели масштаб по углу постоянен


# ---------- плоская система координат ----------

class Plane:
    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.ky = EARTH_R * math.pi / 180
        self.kx = self.ky * math.cos(math.radians(lat0))

    def xy(self, lat, lon):
        return (lon - self.lon0) * self.kx, (lat - self.lat0) * self.ky

    def ll(self, x, y):
        return self.lat0 + y / self.ky, self.lon0 + x / self.kx


def unit(bearing_deg):
    a = math.radians(bearing_deg)
    return math.sin(a), math.cos(a)  # x — восток, y — север


def triangulate(rays):
    """rays: [((x, y), азимут°)] → (x, y, rms м, разброс углов°) или None.
    МНК: точка, минимизирующая сумму квадратов расстояний до лучей."""
    if len(rays) < 2:
        return None
    a11 = a12 = a22 = b1 = b2 = 0.0
    for (px, py), brg in rays:
        dx, dy = unit(brg)
        # проектор на нормаль к лучу: I − d dᵀ
        m11, m12, m22 = 1 - dx * dx, -dx * dy, 1 - dy * dy
        a11 += m11
        a12 += m12
        a22 += m22
        b1 += m11 * px + m12 * py
        b2 += m12 * px + m22 * py
    det = a11 * a22 - a12 * a12
    if abs(det) < 1e-9:
        return None
    x = (b1 * a22 - b2 * a12) / det
    y = (a11 * b2 - a12 * b1) / det
    res, angs = [], []
    for (px, py), brg in rays:
        dx, dy = unit(brg)
        vx, vy = x - px, y - py
        along = vx * dx + vy * dy
        if along <= 0:
            return None  # точка позади машины — лучи разошлись, это не пересечение
        res.append(abs(vx * dy - vy * dx))
        angs.append(brg)
    rms = math.sqrt(sum(r * r for r in res) / len(res))
    return x, y, rms, angular_spread(angs)


def angular_spread(angles):
    """Разброс азимутов с учётом перехода 359→0, °."""
    ref = angles[0]
    rel = [((a - ref + 180) % 360) - 180 for a in angles]
    return max(rel) - min(rel)


# ---------- связывание сработок в треки ----------

def link_tracks(obs):
    """obs: [{'id','t','cls','value','x','y','w','h','dist'}] по времени; dist — путь
    машины (м) к моменту кадра (для «стояли ли»). → [[obs…], …].

    Жадно: сработка продолжает трек того же класса, если последний кадр трека
    недалеко по времени (или машина с тех пор почти не сдвинулась), рамка
    сдвинулась не больше нескольких своих размеров, размер изменился не больше
    чем вдвое и объект не перескочил через центр кадра."""
    tracks, active = [], []
    for o in sorted(obs, key=lambda o: o['t']):
        best, best_cost = None, None
        for tr in active:
            last = tr[-1]
            if last['cls'] != o['cls'] or last['t'] >= o['t']:
                continue
            if o['cls'] == 'speed_limit' and last['value'] != o['value']:
                continue
            gap = o['t'] - last['t']
            moved = abs(o.get('dist', 0) - last.get('dist', 0))
            if gap > TRACK_MAX_GAP_S and moved > TRACK_MAX_GAP_STOP_M:
                continue
            s0, s1 = max(last['w'], last['h']), max(o['w'], o['h'])
            ratio = s1 / s0 if s0 > 0 else 9
            if ratio < 0.6 or ratio > 2.2:
                continue
            cx0, cx1 = last['x'] + last['w'] / 2, o['x'] + o['w'] / 2
            cy0, cy1 = last['y'] + last['h'] / 2, o['y'] + o['h'] / 2
            lim_x = max(90.0, 4 * s1)
            lim_y = max(60.0, 3 * s1)
            dx, dy = abs(cx1 - cx0), abs(cy1 - cy0)
            if dx > lim_x or dy > lim_y:
                continue
            mid = fr.SRC_W / 2
            if (cx0 - mid) * (cx1 - mid) < 0 and min(abs(cx0 - mid), abs(cx1 - mid)) > 40:
                continue
            cost = dx / lim_x + dy / lim_y + abs(math.log(ratio))
            if best_cost is None or cost < best_cost:
                best, best_cost = tr, cost
        if best is None:
            tr = [o]
            tracks.append(tr)
            active.append(tr)
        else:
            best.append(o)
        # трек, давно не продолжавшийся, — из активных
        active = [tr for tr in active if o['t'] - tr[-1]['t'] <= 15]
    return tracks


# ---------- точка объекта ----------

def locate_track(track, lens, plane):
    """track: сработки с 'lat','lon','course' машины. → dict или None."""
    rays, pts = [], []
    for o in track:
        if o.get('lat') is None or o.get('course') is None:
            continue
        p = plane.xy(o['lat'], o['lon'])
        brg = (o['course'] + lens.angle(o['x'] + o['w'] / 2)) % 360
        rays.append((p, brg))
        pts.append((p, o))
    if not rays:
        return None
    # лучи из одной и той же точки (стоянка) базы не дают — оставляем один
    uniq = []
    for r in rays:
        if all(math.hypot(r[0][0] - u[0][0], r[0][1] - u[0][1]) >= 2.0 for u in uniq):
            uniq.append(r)
    tri = triangulate(uniq) if len(uniq) >= 2 else None
    if tri:
        x, y, rms, spread = tri
        rng = min(math.hypot(x - p[0], y - p[1]) for p, _ in uniq)
        if spread >= MIN_SPREAD_DEG and rng <= MAX_RANGE_M:
            geom = rng * math.radians(BEARING_SIGMA_DEG) / max(math.sin(math.radians(spread)), 0.05)
            err = math.sqrt(rms * rms + min(geom, 60) ** 2)
            lat, lon = plane.ll(x, y)
            return {'lat': lat, 'lon': lon, 'err_m': err, 'method': 'tri',
                    'spread': spread, 'range': rng}
    # По размеру рамки: ближайший (самый крупный) кадр.
    p, o = max(pts, key=lambda po: max(po[1]['w'], po[1]['h']))
    size_px = max(o['w'], o['h'])
    if size_px <= 0:
        return None
    d = lens.local_f(o['x']) * REAL_SIZE_M[o['cls']] / size_px
    if d > MAX_RANGE_M:
        return None
    brg = (o['course'] + lens.angle(o['x'] + o['w'] / 2)) % 360
    ux, uy = unit(brg)
    lat, lon = plane.ll(p[0] + ux * d, p[1] + uy * d)
    return {'lat': lat, 'lon': lon, 'err_m': max(5.0, 0.35 * d), 'method': 'size',
            'spread': 0.0, 'range': d}


def majority(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return None
    return max(set(vals), key=vals.count)


def trip_observations(conn, key):
    rows = conn.execute(
        'SELECT d.id, d.cls, d.value, d.color, d.x, d.y, d.w, d.h, d.conf, '
        'f.t, f.lat, f.lon, f.course, f.weight, f.id AS frame_id '
        'FROM detections d JOIN frames f ON f.id=d.frame_id WHERE f.trip_key=? ORDER BY f.t',
        (key,)).fetchall()
    return [dict(r) for r in rows]


def odometer_for(conn, key):
    import locate
    import sync
    return locate.Odometer(sync.clean_ocr(catalog.ocr_series(conn, key)))


def build_trip(conn, key, lens=None):
    """Треки и точки объектов поездки → таблица objects (поездка пересчитывается целиком)."""
    lens = lens or Lens(**load_calib())
    obs = trip_observations(conn, key)
    with conn:
        conn.execute('UPDATE detections SET obj=NULL WHERE frame_id IN '
                     '(SELECT id FROM frames WHERE trip_key=?)', (key,))
        conn.execute('DELETE FROM objects WHERE trip_key=?', (key,))
    if not obs:
        return 0
    odo = odometer_for(conn, key)
    for o in obs:
        o['dist'] = odo.at(o['t'])
    located = [o for o in obs if o['lat'] is not None]
    if located:
        plane = Plane(located[0]['lat'], located[0]['lon'])
    n = 0
    with conn:
        for tr in link_tracks(obs):
            loc = locate_track(tr, lens, plane) if located else None
            ws = [o['weight'] for o in tr if o['weight'] is not None]
            conf = sum(o['conf'] for o in tr) / len(tr) * min(1.0, len(tr) / 3)
            cur = conn.execute(
                'INSERT INTO objects(trip_key, cls, value, color, lat, lon, err_m, n_frames, method, '
                'weight, conf) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                (key, tr[0]['cls'], majority([o['value'] for o in tr]),
                 majority([o['color'] for o in tr]),
                 loc['lat'] if loc else None, loc['lon'] if loc else None,
                 loc['err_m'] if loc else None, len(tr), loc['method'] if loc else None,
                 sum(ws) / len(ws) if ws else None, conf))
            conn.executemany('UPDATE detections SET obj=? WHERE id=?',
                             [(cur.lastrowid, o['id']) for o in tr])
            n += 1
    return n
