"""Время проезда камеры по wpt из выгрузки «все поездки» — общее для всего разбора.

ГЛАВНОЕ (08.10.2026): время wpt — НЕ момент проезда. Приложение до a2431a8
писало проезд (`TripRecorder.registerPass`, `date: Date()`) в момент, когда
PassTracking отпускает камеру: прямое расстояние до неё стало больше радиуса
оповещения + `passReleaseHysteresisMeters` (120 м). Радиус «умный»:
max(радиус из настроек, скорость × 22 с), у владельца в настройках 600 м.
То есть wpt опаздывает на ~740 м пути — 40–50 с в городе, и опора,
поставленная по времени wpt, тянет всю привязку кадров назад по маршруту.

Проверка — скорость: wpt несёт минимум скорости в зоне 80 м перед камерой.
Сверка с OCR-скоростью регистратора: если считать wpt моментом проезда,
медиана расхождения 17 км/ч; если отмотать путь на модель ниже — 5 км/ч,
и минимум ошибки ровно там, где радиус = 600 м (скан −100…+850 м).

Отмотка — по пути (интеграл OCR-скорости), а не по времени: «отпускание» —
это расстояние, а машина между проездом и wpt могла стоять на светофоре.
Расстояние по прямой приложение меряет до камеры, а мы — по пути; разницу
(повороты после камеры) и GPS-тик покрывает RELEASE_EXTRA_M.

Модуль — единственное место этой логики: им пользуются и общий конвейер
(geo.build_trip_geo, sync.anchored_model), и этап камер (cams/passes.py).
"""
import bisect

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


def correct(wpts, odo, radius=ALERT_RADIUS_M):
    """wpt [(t, lat, lon, name, …)] → [(t_проезда, lat, lon, name, t_wpt)] по времени.

    wpt, для которого момент проезда не восстановить (видео не покрывает
    отмотку или в скорости дыра), ОТБРАСЫВАЕТСЯ: опора на 740 м не там хуже,
    чем отсутствие опоры — без неё перегон просто длиннее."""
    out = []
    for w in wpts:
        tp = pass_time(odo, w[0], radius)
        if tp is not None:
            out.append((tp, w[1], w[2], w[3], w[0]))
    out.sort(key=lambda a: a[0])
    return out
