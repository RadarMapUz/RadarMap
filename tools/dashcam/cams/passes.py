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

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Поправка времени проезда вынесена в общий модуль (tools/dashcam/passtime.py):
# ею же пользуется привязка кадров общего конвейера. Имена — для старых вызовов.
from passtime import (ALERT_RADIUS_M, LEAD_CITY_S, LEAD_HWY_S, LEAD_RAMP,  # noqa: F401,E402
                      MAX_DYNAMIC_RADIUS_M, Odo, RELEASE_EXTRA_M, RELEASE_HYST_M,
                      lead_time, pass_time, release_path_m)


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
