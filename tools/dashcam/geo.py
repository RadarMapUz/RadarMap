"""Привязка поездки к месту для пакетного разбора: опоры + форма + скорость.

Опоры — проезды камер (wpt из выгрузки «все поездки»): время телефона и
место. Форма маршрута:

- **trk** — у поездки есть линия из GPX (точки без времени, упрощённая) —
  как в M1 (locate.AnchoredTrack);
- **osrm** — линии нет: маршрут между соседними опорами восстанавливается
  НАШИМ OSRM (https://soulmed.uz/radarmap/osrm), отрезки склеиваются в одну
  ломаную через опоры. Ответы кэшируются в БД, запросы — не чаще 2 в секунду.

Между опорами машина едет по интегралу скорости из кадра, растянутому до
следующей опоры (locate.AnchoredTrack). Перегон проверяется: длина по форме
против пути по скорости; расхождение больше UNRELIABLE_SHARE — перегон
«ненадёжный», его кадры получают низкий вес. Невязка в метрах хранится.

Часы регистратора и телефона — обе от сети, сдвиг 0 (см. sync.sync_trip).
"""
import json
import math
import re
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

import gpx
import locate

OSRM_URL = ('https://soulmed.uz/radarmap/osrm/route/v1/driving/'
            '{lon1:.6f},{lat1:.6f};{lon2:.6f},{lat2:.6f}?overview=full&geometries=geojson')
OSRM_MIN_INTERVAL = 0.5          # не чаще 2 запросов в секунду
OSRM_TIMEOUT = 20
UNRELIABLE_SHARE = 0.35          # |путь по скорости − длина формы| / длина > этого — ненадёжно
SHORT_SEGMENT_M = 60             # на коротких перегонах доля шумная — там порог в метрах
SHORT_SEGMENT_TOL_M = 25
WEIGHT_UNRELIABLE = 0.15
# Трек GPX относится к поездке, если время в его имени — от TRK_BEFORE до
# конца поездки (приложение стартует поездку позже регистратора).
TRK_BEFORE = 15 * 60
ANCHOR_SLACK = 5
# Опоры ближе по месту — одна (две камеры на одной опоре, одна секунда).
ANCHOR_DUP_M = 8
DASHCAM_TZ = timezone(timedelta(hours=5))
NAME_TIME_RE = re.compile(r'(\d{4})-(\d{2})-(\d{2})T(\d{2})(\d{2})(\d{2})')


# ---------- выгрузка «все поездки» ----------

def load_all_trips(path):
    """→ (trks, wpts). trks: [{'name', 't' (время из имени, местное → Unix), 'shape'}];
    wpts: [(t, lat, lon, name)] по времени. Точки trk без времени — только форма."""
    root = ET.parse(path).getroot()

    def local(tag):
        return tag.rsplit('}', 1)[-1]
    trks, wpts = [], []
    for el in root:
        tag = local(el.tag)
        if tag == 'wpt':
            t = name = None
            for ch in el:
                if local(ch.tag) == 'time' and ch.text:
                    t = gpx.parse_time(ch.text)
                elif local(ch.tag) == 'name' and ch.text:
                    name = ch.text.strip()
            if t is not None:
                wpts.append((t, float(el.get('lat')), float(el.get('lon')), name or ''))
        elif tag == 'trk':
            name, shape = '', []
            for ch in el.iter():
                ct = local(ch.tag)
                if ct == 'name' and ch.text and not name:
                    name = ch.text.strip()
                elif ct == 'trkpt':
                    shape.append((float(ch.get('lat')), float(ch.get('lon'))))
            m = NAME_TIME_RE.search(name)
            t = datetime(*map(int, m.groups()), tzinfo=DASHCAM_TZ).timestamp() if m else None
            trks.append({'name': name, 't': t, 'shape': shape})
    wpts.sort(key=lambda w: w[0])
    return trks, wpts


def anchors_for(wpts, t0, t1, slack=ANCHOR_SLACK):
    """Опоры внутри [t0, t1]: строго по времени, без дублей по месту и секунде."""
    out = []
    for w in wpts:
        if not (t0 - slack <= w[0] <= t1 + slack):
            continue
        if out and (w[0] <= out[-1][0] or
                    gpx.haversine(w[1], w[2], out[-1][1], out[-1][2]) < ANCHOR_DUP_M):
            continue
        out.append(w)
    return out


def trks_for(trks, t0, t1):
    return [tr for tr in trks if tr['t'] is not None and t0 - TRK_BEFORE <= tr['t'] <= t1
            and len(tr['shape']) >= 2]


# ---------- OSRM с кэшем ----------

def _fetch_url(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'radarmap-dashcam/1'})
    with urllib.request.urlopen(req, timeout=OSRM_TIMEOUT) as r:
        return r.read().decode('utf-8')


class OSRM:
    """Маршрут между двумя точками. fetch(url) → текст ответа (в тестах — мок)."""

    def __init__(self, conn, fetch=None, min_interval=OSRM_MIN_INTERVAL, sleep=time.sleep,
                 clock=time.monotonic):
        self.conn, self.fetch = conn, fetch or _fetch_url
        self.min_interval, self.sleep, self.clock = min_interval, sleep, clock
        self.last = None
        self.requests = self.hits = 0

    @staticmethod
    def key(a, b):
        return f'{a[0]:.5f},{a[1]:.5f};{b[0]:.5f},{b[1]:.5f}'

    def route(self, a, b):
        """a, b: (lat, lon) → ([(lat, lon)…], метры) или None (маршрута нет / ошибка)."""
        k = self.key(a, b)
        row = self.conn.execute('SELECT body FROM route_cache WHERE key=?', (k,)).fetchone()
        if row is not None:
            self.hits += 1
            body = row[0]
        else:
            if self.last is not None:
                wait = self.min_interval - (self.clock() - self.last)
                if wait > 0:
                    self.sleep(wait)
            url = OSRM_URL.format(lat1=a[0], lon1=a[1], lat2=b[0], lon2=b[1])
            try:
                body = self.fetch(url)
            except Exception as e:  # сеть — не повод валить разбор; перегон станет ненадёжным
                body = json.dumps({'code': 'FetchError', 'message': str(e)})
                self.last = self.clock()
                self.requests += 1
                return None  # ошибку сети не кэшируем: в следующий раз спросим снова
            self.last = self.clock()
            self.requests += 1
            with self.conn:
                self.conn.execute('INSERT OR REPLACE INTO route_cache(key, body, fetched) '
                                  'VALUES(?,?,?)', (k, body, time.time()))
        try:
            j = json.loads(body)
        except json.JSONDecodeError:
            return None
        if j.get('code') != 'Ok' or not j.get('routes'):
            return None
        r = j['routes'][0]
        coords = [(lat, lon) for lon, lat in r['geometry']['coordinates']]
        return coords, float(r['distance'])


def osrm_shape(anchors, osrm):
    """Ломаная через опоры по маршрутам OSRM. → (shape, failed: множество номеров
    перегонов без маршрута — там прямая)."""
    shape, failed = [], set()
    for i, (a, b) in enumerate(zip(anchors, anchors[1:])):
        pa, pb = (a[1], a[2]), (b[1], b[2])
        r = osrm.route(pa, pb)
        part = r[0] if r else [pa, pb]
        if not r:
            failed.add(i)
        # Опора — начало и конец каждого отрезка: OSRM садит точку на дорогу,
        # а камера и так на оси дороги, поэтому разрыв — метры.
        part = [pa] + part + [pb]
        if shape and shape[-1] == part[0]:
            part = part[1:]
        shape.extend(part)
    return shape, failed


# ---------- модель поездки ----------

class TripGeo:
    """Где машина в момент t (часы телефона): точка, курс, вес привязки, перегон."""

    def __init__(self, source, model, segments, edge_ok):
        self.source, self.model, self.segments = source, model, segments
        self.edge_ok = edge_ok  # можно ли продолжать форму до первой / после последней опоры
        self.used = model.used if model else []

    def segment_at(self, t):
        for i, s in enumerate(self.segments):
            if s['t0'] <= t <= s['t1']:
                return i
        return None

    def locate(self, t):
        """→ (lat, lon, курс, вес, номер перегона или -1 вне опор) или None."""
        if not self.model or len(self.used) < 1:
            return None
        A = self.used
        if t < A[0]['t'] or t > A[-1]['t']:
            if not self.edge_ok:
                return None
            ref = A[0]['t'] if t < A[0]['t'] else A[-1]['t']
            d = abs(self.model.odo.at(t) - self.model.odo.at(ref))
            w = max(0.2, 0.6 * (1 - d / 3000))
            seg = -1
        else:
            seg = self.segment_at(t)
            s = self.segments[seg] if seg is not None else None
            if s is None:
                w = WEIGHT_UNRELIABLE
            elif not s['reliable']:
                w = WEIGHT_UNRELIABLE
            else:
                w = max(0.3, min(1.0, 1.0 / (1.0 + abs(s['residual_m']) / 40.0)))
        p = self.model.position(t)
        if p is None:
            return None
        return p[0], p[1], p[2], w, seg

    def summary(self):
        if not self.model:
            return {'source': self.source, 'anchors_used': 0}
        res = [abs(s['residual_m']) for s in self.segments]
        res.sort()
        return {'source': self.source, 'anchors': len(self.model.anchors),
                'anchors_used': len(self.used), 'segments': len(self.segments),
                'unreliable': sum(1 for s in self.segments if not s['reliable']),
                'residual_median_m': round(res[len(res) // 2], 1) if res else None,
                'residual_max_m': round(res[-1], 1) if res else None,
                'length_m': round(self.model.line.length)}


def segment_reliable(line_m, odo_m):
    diff = abs(odo_m - line_m)
    base = max(line_m, odo_m)
    if base < SHORT_SEGMENT_M:
        return diff <= SHORT_SEGMENT_TOL_M
    return diff / base <= UNRELIABLE_SHARE


def build_segments(model, failed=()):
    segs = []
    for i, (a, b) in enumerate(zip(model.used, model.used[1:])):
        line_m = b['s'] - a['s']
        odo_m = model.odo.at(b['t']) - model.odo.at(a['t'])
        ok = segment_reliable(line_m, odo_m)
        segs.append({'idx': i, 't0': a['t'], 't1': b['t'], 'line_m': line_m, 'odo_m': odo_m,
                     'residual_m': odo_m - line_m, 'reliable': ok and i not in failed})
    return segs


def build_trip_geo(t0, t1, speed_pts, wpts, trks, osrm):
    """speed_pts: [(t телефона, км/ч)] — скорость из кадра; wpts/trks — load_all_trips.
    → TripGeo (model None — опор нет, привязать нечем)."""
    anchors = anchors_for(wpts, t0, t1)
    my_trks = trks_for(trks, t0, t1)
    if my_trks and anchors:
        shape = [p for tr in sorted(my_trks, key=lambda x: x['t']) for p in tr['shape']]
        try:
            model = locate.AnchoredTrack(shape, anchors, speed_pts)
        except ValueError:
            model = None
        if model and model.used:
            return TripGeo('trk', model, build_segments(model), edge_ok=True)
    if len(anchors) < 2:
        return TripGeo(None, None, [], False)
    # Без линии: опоры только внутри покрытия видео, иначе маршрут строить незачем.
    odo = locate.Odometer(speed_pts)
    inside = [a for a in anchors if odo.covers(a[0])]
    if len(inside) < 2:
        return TripGeo(None, None, [], False)
    shape, failed_pairs = osrm_shape(inside, osrm)
    try:
        model = locate.AnchoredTrack(shape, inside, speed_pts)
    except ValueError:
        return TripGeo(None, None, [], False)
    # Номера перегонов модели совпадают с парами inside, если все опоры взяты.
    failed = failed_pairs if len(model.used) == len(inside) else set()
    return TripGeo('osrm', model, build_segments(model, failed), edge_ok=False)


def leave_one_out(t0, t1, speed_pts, wpts, trks, osrm):
    """Точность привязки на камерах фиксации: каждая внутренняя опора по очереди
    выбрасывается, модель строится без неё, и позиция в её момент сравнивается
    с координатой камеры. → [(имя, ошибка м, вдоль/поперёк не различаем)]."""
    anchors = anchors_for(wpts, t0, t1)
    out = []
    for k in range(1, len(anchors) - 1):
        a = anchors[k]
        rest = [w for w in wpts if w is not a and not (w[0] == a[0] and w[1] == a[1])]
        g = build_trip_geo(t0, t1, speed_pts, rest, trks, osrm)
        p = g.locate(a[0])
        if p is None:
            continue
        out.append((a[3], gpx.haversine(p[0], p[1], a[1], a[2]), g.source, p[3]))
    return out


def bearing(lat1, lon1, lat2, lon2):
    kx = math.cos(math.radians(lat1))
    return math.degrees(math.atan2((lon2 - lon1) * kx, lat2 - lat1)) % 360
