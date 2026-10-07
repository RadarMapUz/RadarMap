"""GPX из приложения RadarMap (TimedTrack.swift): чтение и запись.

Формат приложения: <trk><trkseg><trkpt lat lon><time>ISO-8601 UTC</time>
<extensions><speed>м/с</speed></extensions></trkpt>, плюс <wpt> — проезды
камер с временем. Время — секунды Unix (UTC), скорость — км/ч.
Синтетический трек помечается creator="RadarMap-synthetic": такой трек
нельзя принимать за правду, и страница обязана это сказать.
"""
import math
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from xml.sax.saxutils import escape

SYNTHETIC_CREATOR = 'RadarMap-synthetic'


def _local(tag):
    return tag.rsplit('}', 1)[-1]


def parse_time(s):
    """ISO-8601 → секунды Unix. Без зоны считаем UTC (так пишет приложение)."""
    dt = datetime.fromisoformat(s.strip().replace('Z', '+00:00'))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def format_time(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def parse(source):
    """→ dict(name, synthetic, kind, points=[(t, lat, lon, kmh)], shape=[(lat, lon)],
    waypoints=[(t, lat, lon, name)]).

    kind: «timed» — у точек трека есть время (подробный трек раз в секунду);
    «anchored» — старая поездка: точки трека без времени (упрощённая форма
    маршрута), время есть только у проездов камер (wpt) — они и есть опоры.
    """
    root = ET.parse(source).getroot()
    synthetic = root.get('creator') == SYNTHETIC_CREATOR
    name = ''
    points, waypoints, shape = [], [], []
    for el in root.iter():
        tag = _local(el.tag)
        if tag == 'trk':
            for ch in el:
                if _local(ch.tag) == 'name' and ch.text:
                    name = ch.text.strip()
        elif tag in ('trkpt', 'wpt'):
            t = speed = label = None
            for ch in el.iter():
                ct = _local(ch.tag)
                if ct == 'time' and ch.text:
                    t = parse_time(ch.text)
                elif ct == 'speed' and ch.text:
                    speed = float(ch.text) * 3.6
                elif ct == 'name' and ch.text:
                    label = ch.text.strip()
            lat, lon = float(el.get('lat')), float(el.get('lon'))
            if tag == 'trkpt':
                shape.append((lat, lon))
            if t is None:
                continue
            if tag == 'trkpt':
                points.append([t, lat, lon, speed])
            else:
                waypoints.append((t, lat, lon, label or ''))
    points.sort(key=lambda p: p[0])
    # Скорости нет — считаем по соседним точкам.
    for i, p in enumerate(points):
        if p[3] is None:
            j = i - 1 if i else min(1, len(points) - 1)
            q = points[j]
            dt = abs(p[0] - q[0])
            p[3] = haversine(p[1], p[2], q[1], q[2]) / dt * 3.6 if dt > 0 else 0.0
    waypoints.sort(key=lambda w: w[0])
    if len(points) >= 2:
        kind = 'timed'
    elif len(shape) >= 2 and waypoints:
        kind = 'anchored'
    else:
        kind = None  # ни времени у точек, ни опор — для разбора видео бесполезен
    return {'name': name, 'synthetic': synthetic, 'kind': kind, 'shape': shape,
            'points': [tuple(p) for p in points], 'waypoints': waypoints}


def write(path, name, points, waypoints=(), synthetic=False, desc=''):
    """points: (t, lat, lon, kmh). Формат — как у приложения."""
    creator = SYNTHETIC_CREATOR if synthetic else 'RadarMap'
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<gpx version="1.1" creator="{creator}" xmlns="http://www.topografix.com/GPX/1/1">']
    if desc:
        out.append(f'<metadata><desc>{escape(desc)}</desc></metadata>')
    for t, lat, lon, label in waypoints:
        out.append(f'<wpt lat="{lat:.6f}" lon="{lon:.6f}"><time>{format_time(t)}</time>'
                   f'<name>{escape(label)}</name></wpt>')
    out.append(f'<trk><name>{escape(name)}</name><trkseg>')
    for t, lat, lon, kmh in points:
        # Время с долями секунды: синтетика кладёт точку в середину секунды.
        stamp = datetime.fromtimestamp(t, timezone.utc).isoformat(timespec='milliseconds')
        stamp = stamp.replace('+00:00', 'Z')
        out.append(f'<trkpt lat="{lat:.6f}" lon="{lon:.6f}"><time>{stamp}</time>'
                   f'<extensions><speed>{kmh / 3.6:.2f}</speed></extensions></trkpt>')
    out.append('</trkseg></trk>')
    out.append('</gpx>')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
