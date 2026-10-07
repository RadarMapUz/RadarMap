"""Где был кадр: время (часы телефона) → точка и курс на треке.

Два вида трека (gpx.parse → kind):

- **timed** — подробный трек, у каждой точки время. Позиция — линейная
  интерполяция между соседними точками, курс — направление отрезка
  (на стоянке, где отрезок короче метра, — ближайший отрезок с движением).

- **anchored** — старая поездка: форма маршрута без времени + опоры (проезды
  камер: время и место). Опоры проецируются на ломаную (расстояние вдоль
  неё, строго по порядку — маршрут не идёт назад). Между соседними опорами
  машина едет по интегралу скорости из кадра (OCR), растянутому или
  сжатому так, чтобы ровно попасть в следующую опору; до первой и после
  последней — по скорости от ближайшей опоры. Невязка — насколько путь по
  скорости между опорами расходится с расстоянием по ломаной; это честная
  оценка точности привязки в метрах (её и показывает страница).

Время кадра = старт ролика (часы регистратора) + позиция в ролике + сдвиг.
"""
import bisect
import math
import statistics

EARTH_R = 6371000.0
# Отрезок короче этого — стоянка, курс по нему не определить.
MIN_COURSE_SEGMENT_M = 1.0
# Опора вне покрытия скорости дальше этого — в модель не берётся
# (между ней и соседней путь по скорости неизвестен).
ANCHOR_COVERAGE_TOL_S = 5.0


def frame_time(clip_start, position, offset):
    return clip_start + position + offset


class Polyline:
    """Ломаная в локальной плоской проекции (метры); для города точности хватает."""

    def __init__(self, pts):
        clean = []
        for p in pts:
            if not clean or (p[0], p[1]) != clean[-1]:
                clean.append((p[0], p[1]))
        if len(clean) < 2:
            raise ValueError('в ломаной меньше двух разных точек')
        self.pts = clean
        lat0 = sum(p[0] for p in clean) / len(clean)
        self.ky = EARTH_R * math.pi / 180
        self.kx = self.ky * math.cos(math.radians(lat0))
        self.xy = [(lon * self.kx, lat * self.ky) for lat, lon in clean]
        self.cum = [0.0]
        for (x0, y0), (x1, y1) in zip(self.xy, self.xy[1:]):
            self.cum.append(self.cum[-1] + math.hypot(x1 - x0, y1 - y0))
        self.length = self.cum[-1]

    def _seg_course(self, i):
        (x0, y0), (x1, y1) = self.xy[i], self.xy[i + 1]
        return math.degrees(math.atan2(x1 - x0, y1 - y0)) % 360

    def point_at(self, s):
        """Расстояние вдоль ломаной → (lat, lon, курс°)."""
        s = min(max(s, 0.0), self.length)
        i = min(max(bisect.bisect_right(self.cum, s) - 1, 0), len(self.cum) - 2)
        while i < len(self.cum) - 2 and self.cum[i + 1] - self.cum[i] <= 0:
            i += 1
        seg = self.cum[i + 1] - self.cum[i]
        k = (s - self.cum[i]) / seg if seg > 0 else 0.0
        (x0, y0), (x1, y1) = self.xy[i], self.xy[i + 1]
        x, y = x0 + (x1 - x0) * k, y0 + (y1 - y0) * k
        return y / self.ky, x / self.kx, self._seg_course(i)

    def project(self, lat, lon, min_s=0.0):
        """Ближайшая точка ломаной не раньше min_s → (s, расстояние до неё в м)."""
        px, py = lon * self.kx, lat * self.ky
        best = None
        for i in range(len(self.xy) - 1):
            if self.cum[i + 1] < min_s:
                continue
            (x0, y0), (x1, y1) = self.xy[i], self.xy[i + 1]
            dx, dy = x1 - x0, y1 - y0
            seg2 = dx * dx + dy * dy
            u = ((px - x0) * dx + (py - y0) * dy) / seg2 if seg2 > 0 else 0.0
            u = min(max(u, 0.0), 1.0)
            s = self.cum[i] + u * (self.cum[i + 1] - self.cum[i])
            if s < min_s:
                s = min_s
                u = (s - self.cum[i]) / (self.cum[i + 1] - self.cum[i])
            d = math.hypot(x0 + dx * u - px, y0 + dy * u - py)
            if best is None or d < best[1]:
                best = (s, d)
        return best


# ---------- подробный трек (время у каждой точки) ----------

def _flat(lat0):
    ky = EARTH_R * math.pi / 180
    return ky * math.cos(math.radians(lat0)), ky


def position_at(points, t):
    """points: [(t, lat, lon, …)] по времени → (lat, lon, курс°) или None вне трека."""
    if not points or t < points[0][0] or t > points[-1][0]:
        return None
    ts = [p[0] for p in points]
    i = bisect.bisect_right(ts, t) - 1
    i = min(max(i, 0), len(points) - 2) if len(points) > 1 else 0
    if len(points) == 1:
        return points[0][1], points[0][2], None
    a, b = points[i], points[i + 1]
    k = (t - a[0]) / (b[0] - a[0]) if b[0] > a[0] else 0.0
    lat = a[1] + (b[1] - a[1]) * k
    lon = a[2] + (b[2] - a[2]) * k
    return lat, lon, course_near(points, i)


def course_near(points, i):
    """Курс отрезка i; на стоянке — последний отрезок с движением до неё (машина
    стоит лицом туда, куда приехала), а в самом начале трека — первый после."""
    kx, ky = _flat(points[i][1])
    n = len(points) - 1
    for j in list(range(i, -1, -1)) + list(range(i + 1, n)):
        a, b = points[j], points[j + 1]
        dx, dy = (b[2] - a[2]) * kx, (b[1] - a[1]) * ky
        if math.hypot(dx, dy) >= MIN_COURSE_SEGMENT_M:
            return math.degrees(math.atan2(dx, dy)) % 360
    return None


def nearest_time(points, lat, lon):
    """Клик по треку → время ближайшей точки трека (с интерполяцией внутри отрезка)."""
    kx, ky = _flat(lat)
    px, py = lon * kx, lat * ky
    best = None
    for a, b in zip(points, points[1:]):
        x0, y0, x1, y1 = a[2] * kx, a[1] * ky, b[2] * kx, b[1] * ky
        dx, dy = x1 - x0, y1 - y0
        seg2 = dx * dx + dy * dy
        u = min(max(((px - x0) * dx + (py - y0) * dy) / seg2, 0.0), 1.0) if seg2 > 0 else 0.0
        d = math.hypot(x0 + dx * u - px, y0 + dy * u - py)
        if best is None or d < best[1]:
            best = (a[0] + (b[0] - a[0]) * u, d)
    return best[0] if best else None


# ---------- старая поездка: форма + опоры + скорость из кадра ----------

class Odometer:
    """Путь по скорости: интеграл (трапеции) ряда [(t, км/ч)]. Вне ряда — постоянен."""

    def __init__(self, speed_points):
        pts = sorted((t, v) for t, v in speed_points if v is not None)
        self.t = [p[0] for p in pts]
        self.d = [0.0]
        for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
            self.d.append(self.d[-1] + (v0 + v1) / 2 / 3.6 * (t1 - t0))

    def covers(self, t, tol=ANCHOR_COVERAGE_TOL_S):
        return bool(self.t) and self.t[0] - tol <= t <= self.t[-1] + tol

    def at(self, t):
        ts = self.t
        if not ts:
            return 0.0
        if t <= ts[0]:
            return 0.0
        if t >= ts[-1]:
            return self.d[-1]
        i = bisect.bisect_right(ts, t) - 1
        k = (t - ts[i]) / (ts[i + 1] - ts[i])
        return self.d[i] + (self.d[i + 1] - self.d[i]) * k


class AnchoredTrack:
    def __init__(self, shape, anchors, speed_points):
        """shape: [(lat, lon)]; anchors: [(t, lat, lon, name)] (часы телефона);
        speed_points: [(t, км/ч)] — скорость из кадра уже в часах телефона."""
        self.line = Polyline(shape)
        self.odo = Odometer(speed_points)
        self.anchors = []
        last_s, last_t = 0.0, None
        for t, lat, lon, name in sorted(anchors, key=lambda a: a[0]):
            if last_t is not None and t <= last_t:
                continue  # две опоры в одну секунду — модели нечего с ними делать
            s, off = self.line.project(lat, lon, last_s)
            self.anchors.append({'t': t, 'lat': lat, 'lon': lon, 'name': name, 's': s,
                                 'offset_m': off, 'used': self.odo.covers(t)})
            last_s, last_t = s, t
        self.used = [a for a in self.anchors if a['used']]

    def s_at(self, t):
        """Время → расстояние вдоль ломаной. None — без опор в покрытии видео."""
        A, odo = self.used, self.odo
        if not A:
            return None
        if t <= A[0]['t']:
            s = A[0]['s'] - (odo.at(A[0]['t']) - odo.at(t))
        elif t >= A[-1]['t']:
            s = A[-1]['s'] + (odo.at(t) - odo.at(A[-1]['t']))
        else:
            i = bisect.bisect_right([a['t'] for a in A], t) - 1
            a, b = A[i], A[i + 1]
            dd = odo.at(b['t']) - odo.at(a['t'])
            if dd > 1.0:
                frac = (odo.at(t) - odo.at(a['t'])) / dd
            else:  # по скорости не ехали, а опоры разные — равномерно по времени
                frac = (t - a['t']) / (b['t'] - a['t'])
            s = a['s'] + (b['s'] - a['s']) * frac
        return min(max(s, 0.0), self.line.length)

    def position(self, t):
        s = self.s_at(t)
        if s is None:
            return None
        return self.line.point_at(s)

    def residuals(self):
        """Невязка между соседними опорами: путь по скорости − путь по ломаной, м."""
        out = []
        for a, b in zip(self.used, self.used[1:]):
            out.append((self.odo.at(b['t']) - self.odo.at(a['t'])) - (b['s'] - a['s']))
        return out

    def summary(self):
        res = [abs(r) for r in self.residuals()]
        return {'anchors': len(self.anchors), 'anchors_used': len(self.used),
                'residual_median_m': round(statistics.median(res), 1) if res else None,
                'residual_max_m': round(max(res), 1) if res else None,
                'anchor_offset_max_m': round(max((a['offset_m'] for a in self.anchors),
                                                 default=0.0), 1)}

    def timed(self, times, speeds=None):
        """Плотный трек для страницы: [(t, lat, lon, км/ч)] в заданные моменты."""
        out = []
        for i, t in enumerate(times):
            p = self.position(t)
            if p is not None:
                out.append((t, p[0], p[1], speeds[i] if speeds else None))
        return out
