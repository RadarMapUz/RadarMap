"""Чистая логика: когда машина на самом деле проезжала камеру из GPX и какие
кадры брать в обучающую выборку.

ГЛАВНОЕ (08.10.2026): время wpt в выгрузке «все поездки» — НЕ момент
проезда. Приложение пишет проезд (`TripRecorder.registerPass`, `date: Date()`)
в момент, когда PassTracking отпускает камеру: прямое расстояние до неё стало
больше радиуса оповещения + `passReleaseHysteresisMeters` (120 м). Радиус —
«умный»: max(радиус из настроек, скорость × 22 с), у владельца в настройках
600 м. То есть wpt опаздывает на ~720 м пути — 40–50 с в городе. Отсюда
прежние беды: классификатор на кадрах «за 0,3–3 с до wpt» учился на пустых
кадрах (val 55 %), а опознание при «идеальных» событиях давало 0 верных.

Подтверждение — скорость: wpt несёт минимум скорости в зоне 80 м перед
камерой. Сверка с OCR-скоростью регистратора: если считать wpt моментом
проезда, медиана расхождения 17 км/ч; если отмотать путь на модель ниже —
5 км/ч, и минимум ошибки ровно там, где радиус = 600 м (скан −100…+850 м).
"""
import bisect
import math
import os

# Параметры приложения (RadarMap/Support/AppConfig.swift) + настройка владельца.
ALERT_RADIUS_M = 600.0           # settings.alertRadius у владельца (по скорости из wpt)
RELEASE_HYST_M = 120.0           # passReleaseHysteresisMeters
LEAD_CITY_S, LEAD_HWY_S = 22.0, 29.0
LEAD_RAMP = (80.0, 100.0)
MAX_DYNAMIC_RADIUS_M = 1500.0
# Путь длиннее прямой (повороты после камеры) и GPS-тик (≈1 с) — подобрано
# по минимуму расхождения скорости (скан шагом 20 м: 0…40 м одинаково хороши).
RELEASE_EXTRA_M = 20.0


def lead_time(kmh):
    lo, hi = LEAD_RAMP
    if kmh <= lo:
        return LEAD_CITY_S
    if kmh >= hi:
        return LEAD_HWY_S
    return LEAD_CITY_S + (LEAD_HWY_S - LEAD_CITY_S) * (kmh - lo) / (hi - lo)


def release_path_m(kmh_at_release, radius=ALERT_RADIUS_M):
    """Сколько метров пути машина проехала от камеры до записи wpt."""
    r = min(MAX_DYNAMIC_RADIUS_M, max(radius, kmh_at_release / 3.6 * lead_time(kmh_at_release)))
    return r + RELEASE_HYST_M + RELEASE_EXTRA_M


class Odo:
    """Путь по скорости [(t, км/ч)] — трапеции; at(t) и обратная time_at(s)."""

    def __init__(self, speed_points):
        pts = sorted((t, v) for t, v in speed_points if v is not None)
        self.t = [p[0] for p in pts]
        self.v = [p[1] for p in pts]
        self.d = [0.0]
        for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
            self.d.append(self.d[-1] + (v0 + v1) / 2 / 3.6 * (t1 - t0))

    def covers(self, t, tol=5.0):
        return bool(self.t) and self.t[0] - tol <= t <= self.t[-1] + tol

    def at(self, t):
        ts = self.t
        if not ts or t <= ts[0]:
            return 0.0
        if t >= ts[-1]:
            return self.d[-1]
        i = bisect.bisect_right(ts, t) - 1
        k = (t - ts[i]) / (ts[i + 1] - ts[i])
        return self.d[i] + (self.d[i + 1] - self.d[i]) * k

    def speed(self, t):
        ts = self.t
        if not ts:
            return None
        i = bisect.bisect_left(ts, t)
        if i < len(ts) and ts[i] == t:
            return self.v[i]
        if i == 0 or i == len(ts) or ts[i] - ts[i - 1] > 5:
            return None
        k = (t - ts[i - 1]) / (ts[i] - ts[i - 1])
        return self.v[i - 1] + (self.v[i] - self.v[i - 1]) * k

    def dense(self, t0, t1, max_gap=5.0):
        """Ряд скорости без дыр длиннее max_gap на [t0, t1]: иначе путь — догадка."""
        ts = self.t
        if not ts or t0 < ts[0] - max_gap or t1 > ts[-1] + max_gap:
            return False
        i = max(0, bisect.bisect_left(ts, t0) - 1)
        j = min(len(ts) - 1, bisect.bisect_right(ts, t1))
        return all(ts[k + 1] - ts[k] <= max_gap for k in range(i, j))

    def time_at(self, s):
        """Момент, когда пройдено s метров (первый). None — вне ряда."""
        d = self.d
        if not self.t or s < 0 or s > d[-1]:
            return None
        i = bisect.bisect_left(d, s)
        if i == 0:
            return self.t[0]
        d0, d1 = d[i - 1], d[i]
        if d1 - d0 < 1e-9:
            return self.t[i]
        return self.t[i - 1] + (self.t[i] - self.t[i - 1]) * (s - d0) / (d1 - d0)


def pass_time(odo, t_wpt, radius=ALERT_RADIUS_M):
    """Момент проезда камеры по времени wpt. None — видео не покрывает."""
    if not odo.covers(t_wpt):
        return None
    v = odo.speed(t_wpt) or 0.0
    tp = odo.time_at(odo.at(t_wpt) - release_path_m(v, radius))
    if tp is None or not odo.dense(tp, t_wpt):
        return None
    return tp


# ---------- выборка ----------

POS_DT = tuple(float(x) for x in os.environ.get('CAMS_POS_DT', '0.5,3.0').split(','))   # секунд до проезда
POS_D = tuple(float(x) for x in os.environ.get('CAMS_POS_D', '8,70').split(','))   # метров пути до проезда
POS_MIN_KMH = 5.0
NEG_PASS_M = 300.0         # по пути от любого проезда
NEG_CAM_M = 300.0          # по месту от любой камеры базы
NEG_MIN_KMH = 10.0


def label_positive(t, kmh, t_pass, odo):
    """Кадр t — «камера близко» для проезда t_pass?"""
    dt = t_pass - t
    if not (POS_DT[0] <= dt <= POS_DT[1]) or (kmh or 0) < POS_MIN_KMH:
        return False
    d = odo.at(t_pass) - odo.at(t)
    return POS_D[0] <= d <= POS_D[1]


def label_negative(t, kmh, pass_times, odo, dist_to_camera_m):
    """Кадр t — «камеры нет»: далеко по пути от всех проездов поездки и далеко
    по месту от всех камер базы (dist_to_camera_m — None, если места нет:
    тогда не берём — без места нельзя доказать, что камеры рядом нет)."""
    if (kmh or 0) < NEG_MIN_KMH or dist_to_camera_m is None or dist_to_camera_m < NEG_CAM_M:
        return False
    s = odo.at(t)
    return all(abs(s - odo.at(tp)) >= NEG_PASS_M for tp in pass_times)


def split_by_trip(keys, val_share=0.25, seed=7):
    """Train/val — по поездкам: соседние кадры одной поездки почти одинаковы."""
    import random
    ks = sorted(keys)
    random.Random(seed).shuffle(ks)
    nval = max(1, round(len(ks) * val_share))
    return {k: ('val' if i < nval else 'train') for i, k in enumerate(ks)}


def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def bearing(lat1, lon1, lat2, lon2):
    kx = math.cos(math.radians(lat1))
    return math.degrees(math.atan2((lon2 - lon1) * kx, lat2 - lat1)) % 360


def angle_diff(a, b):
    return abs((a - b + 180) % 360 - 180)


class CamGrid:
    """Сетка 0,01° по камерам базы: ближайшие в радиусе."""

    def __init__(self, cams, cell=0.01):
        self.cell, self.g, self.cams = cell, {}, cams
        for i, c in enumerate(cams):
            self.g.setdefault((int(c['lat'] / cell), int(c['lon'] / cell)), []).append(i)

    def near(self, lat, lon, r_m):
        """→ [(расстояние, индекс)] по возрастанию."""
        k = (int(lat / self.cell), int(lon / self.cell))
        span = int(r_m / (self.cell * 80000)) + 1
        out = []
        for i in range(k[0] - span, k[0] + span + 1):
            for j in range(k[1] - span, k[1] + span + 1):
                for n in self.g.get((i, j), ()):
                    c = self.cams[n]
                    d = haversine(lat, lon, c['lat'], c['lon'])
                    if d <= r_m:
                        out.append((d, n))
        out.sort()
        return out

    def nearest_dist(self, lat, lon, r_m=2000):
        n = self.near(lat, lon, r_m)
        return n[0][0] if n else r_m
