#!/usr/bin/env python3
"""Находки видео → готовые правки карты (только локальные файлы, ничего не отправляет).

    python3 mapready.py export [--out DIR] [--tiles DIR]

«Готово к карте» — кластер, который можно отдать человеку на одно нажатие
«принять», а не на расследование. Отбор строгий, потому что цена ошибки
несимметрична: лишний светофор на схеме и в OSRM (штраф за перекрёсток) —
враньё водителю, а пропущенный — всего лишь то, что и так было.

Пороги (обоснование — у каждой константы) и результат:

- drafts.json — черновики в формате конструктора (server/map_edits.py):
  kind="point", raw — точка находки, geom — посадка магнитом map_edits.snap на
  НАШИ тайлы дорог (светофор — к узлу, переход — к оси дороги). Магнит не
  угадывает: две дороги на равном удалении — черновик помечен
  «неоднозначно», geom = raw, в changes.osc он не идёт.
- changes.osc — те же объекты для JOSM (osmChange, отрицательные id).
  map_edits.as_osm умеет только линии (нарисованные дороги) — для точек здесь
  тонкая обёртка того же вида.
- review_limits.csv — знаки ограничения «расходится» с лимитами OSM (из них
  собрана наша база лимитов speed_limits*.json): только на проверку, без
  применения — знак мог висеть на дублёре, на въезде во двор или быть
  временным.
- README.md — что внутри и как это загрузить; ничего из этого НЕ применено.
"""
import argparse
import csv
import json
import math
import os
import sys
import time

import catalog
import cluster
import gpx

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'server'))
import map_edits  # noqa: E402

BASE = os.path.dirname(catalog.DB_PATH)
OUT_DIR = os.path.join(BASE, 'export')
TILES_DIR = os.path.expanduser(os.environ.get('DASHCAM_TILES', '~/RadarMapBuild/cand'))
UI = 'http://127.0.0.1:8780'

# ---------- пороги «готово к карте» ----------

# Классы, которые вообще можно предлагать как новую точку. Знаки ограничения
# сюда не входят: лимит — свойство дороги, а не точка, и меняется только
# человеком (review_limits.csv). Неровности — по рывку, без кадра объекта.
READY_CLASSES = ('traffic_light', 'crossing')
# Принятое человеком на странице разбора (по кадру) — ещё и лежачие: на кадре
# видно сам бугор и знак, а не только рывок.
ACCEPTED_CLASSES = READY_CLASSES + ('speed_bump',)
# Видели хотя бы в двух РАЗНЫХ поездках. Одна поездка — это одна привязка:
# ошибка опор сдвигает все её кадры разом, и триангуляция этого не видит.
# Вторая поездка — независимая привязка и независимый взгляд детектора
# (блик, вывеска, светофор трамвая не повторяются в том же месте).
MIN_TRIPS = 2
# Оценка точности места кластера (медиана по встречам / √n), м. 12 м — это
# «тот же перекрёсток, та же сторона»: магнит узла (map_edits.NODE_METERS 15 м)
# и захват дороги (SNAP_METERS 25 м) дальше всё равно посадят точку на ось.
# Оценка оптимистична (честная ошибка привязки на камерах — в docs/
# plan_dashcam_ml.md, «Точность привязки»), поэтому порог не ослабляем.
MAX_ERR_M = 12.0
# Уверенность кластера = 1 − Π(1 − qᵢ), q встречи = детектор × вес привязки ×
# полнота трека. 0,7 при двух поездках требует от каждой q ≈ 0,45 — полный трек
# (≥ 3 кадра для светофора) уверенного детектора на надёжном перегоне. Ниже
# этого в выборке остаются одно-двухкадровые встречи — именно там блики.
MIN_CONFIDENCE = 0.7
# Не ближе к уже существующему объекту того же класса (OSM и наши тайлы), м.
# Статус «новое» уже значит «в 60/50 м ничего» (cluster.DIFFER_M); это — вторая,
# независимая проверка по тайлам: на них тот же объект может стоять со сдвигом.
MIN_GAP_EXISTING_M = 25.0
# Две готовые находки одного класса ближе этого — один объект. Было 25 м, и
# проверка глазами (08.10.2026) нашла дубль: один и тот же светофор у перехода
# на Nurafshon aylanma двумя кластерами в 39 м друг от друга (поездки 23/26.09
# против 28.09/07.10). Честная ошибка привязки — медиана 23 м на камерах
# (выброс опоры), так что две независимые оценки одного объекта расходятся
# до ~2 × 23 м; два разных светофора одного класса ближе 50 м на одной
# стороне — редкость, а лишний дубль на карте — враньё.
MERGE_READY_M = 50.0
# Светофор у перехода ближе этого — переход регулируемый.
CROSSING_SIGNAL_M = 30.0
# Знак ограничения: лимит дороги «по курсу» — отрезок не дальше этого и под
# углом к курсу машины не больше LIMIT_COURSE_DEG (направление отрезка в OSM
# произвольное, поэтому угол — по модулю 180°).
LIMIT_NEAR_M = 30.0
LIMIT_COURSE_DEG = 30.0

POINT_CODE = {'traffic_light': 1, 'crossing': 5, 'speed_bump': 2}   # map_edits.POINT_NAMES
OSM_TAGS = {'traffic_light': {'highway': 'traffic_signals'}, 'crossing': {'highway': 'crossing'},
            'speed_bump': {'traffic_calming': 'bump'}}
CLS_RU = {'traffic_light': 'светофор', 'crossing': 'пешеходный переход', 'speed_limit': 'знак ограничения',
          'speed_bump': 'лежачий полицейский'}


def ready_reasons(c, gap_m, decision=None):
    """Почему кластер НЕ готов (пусто — готов). c: dict кластера; gap_m —
    расстояние до ближайшего существующего объекта того же класса (None — нет
    в пределах поиска); decision — решение человека на странице.

    «Принято» человеком — готово при любых порогах автоматики: они отвечают на
    вопрос «можно ли верить без человека», а он уже посмотрел кадр. Из 84
    светофоров, принятых владельцем 08.10.2026, пороги пропускали 4 — остальные
    видели в одной поездке, и на карту они не попадали никак."""
    if decision == 'accept':
        return [] if c['cls'] in ACCEPTED_CLASSES else ['класс не предлагается точкой']
    out = []
    if c['cls'] not in READY_CLASSES:
        out.append('класс не предлагается точкой')
    if c['status'] != 'new':
        out.append(f"статус {c['status']}")
    if (c['n_trips'] or 0) < MIN_TRIPS:
        out.append(f"поездок {c['n_trips']} < {MIN_TRIPS}")
    if c['err_m'] is None or c['err_m'] > MAX_ERR_M:
        out.append(f"точность ±{c['err_m'] if c['err_m'] is None else round(c['err_m'], 1)} м > {MAX_ERR_M:g}")
    if (c['confidence'] or 0) < MIN_CONFIDENCE:
        out.append(f"уверенность {c['confidence']:.2f} < {MIN_CONFIDENCE}")
    if gap_m is not None and gap_m < MIN_GAP_EXISTING_M:
        out.append(f'в {gap_m:.0f} м уже есть такой объект')
    if decision == 'reject':
        out.append('отклонено человеком')
    return out


# ---------- существующие объекты ----------

class Existing:
    """Объекты того же класса, которые уже есть: точки OSM (points.geojsonl) и
    точки наших тайлов (набор p — то, что уже едет на телефон)."""

    def __init__(self, osm=None, tiles_dir=TILES_DIR):
        osm = osm if osm is not None else cluster.load_points()
        self.tiles_dir = tiles_dir
        self.idx = {'traffic_light': cluster.PointIndex(osm['traffic_signals']),
                    'crossing': cluster.PointIndex(osm['crossing'])}
        self._tile_pts = {}

    def _tiles(self, lat, lon):
        k = (round(lat, 2), round(lon, 2))
        if k not in self._tile_pts:
            pts = map_edits.load_points(self.tiles_dir, lat - 0.01, lon - 0.013, lat + 0.01, lon + 0.013) \
                if self.tiles_dir and os.path.isdir(self.tiles_dir) else []
            self._tile_pts[k] = pts
        return self._tile_pts[k]

    def gap(self, cls, lat, lon, r=200.0):
        best = None
        if cls in self.idx:
            hit = self.idx[cls].nearest(lat, lon, r)
            best = hit[0] if hit else None
        code = POINT_CODE.get(cls)
        for p in self._tiles(lat, lon):
            if p['kind'] != code:
                continue
            d = gpx.haversine(lat, lon, p['point'][1], p['point'][0])
            if d <= r and (best is None or d < best):
                best = d
        return best


# ---------- отбор ----------

def trip_date(key):
    return key[:10]


def cluster_rows(conn):
    return [dict(r) for r in conn.execute('SELECT * FROM clusters ORDER BY confidence DESC')]


def evaluate(conn, existing=None):
    """Все кластеры классов READY_CLASSES → [(кластер, причины «не готов»)]."""
    existing = existing or Existing()
    out = []
    for c in cluster_rows(conn):
        if c['cls'] not in ACCEPTED_CLASSES:
            continue
        c['decision'] = cluster.decision_for(conn, c['cls'], c['lat'], c['lon'])
        c['gap_m'] = existing.gap(c['cls'], c['lat'], c['lon'])
        out.append((c, ready_reasons(c, c['gap_m'], c['decision'])))
    return out


def merge_ready(clusters, merge_m=MERGE_READY_M):
    """Готовые одного класса ближе merge_m (по месту находки, до магнита) — один
    объект: остаётся самый уверенный, остальные — в его 'merged'.

    Принятые человеком сливаются только в радиусе его же решения
    (cluster.DECISION_M): каждое «принять» — светофор, который он видел, и
    50 м сольют светофоры разных подходов одного перекрёстка."""
    out = []
    for c in sorted(clusters, key=lambda x: -(x['confidence'] or 0)):
        twin = next((o for o in out if o['cls'] == c['cls'] and
                     gpx.haversine(o['lat'], o['lon'], c['lat'], c['lon']) <
                     (cluster.DECISION_M if 'accept' in (o.get('decision'), c.get('decision'))
                      else merge_m)), None)
        if twin is None:
            out.append(dict(c, merged=[]))
        else:
            twin['merged'].append(c)
    return out


def ready_clusters(conn, existing=None):
    return merge_ready([c for c, why in evaluate(conn, existing) if not why])


def ready_ids(conn, existing=None):
    """Для страницы: id кластеров, которые уйдут черновиками (после слияния дублей)."""
    return {c['id'] for c in ready_clusters(conn, existing)}


# ---------- магнит ----------

def snap_point(cls, lat, lon, tiles_dir=TILES_DIR):
    """Посадка на наши тайлы. → dict(status, point [lon, lat], anchor, candidates, fingerprint).

    status: node — светофор на узле перекрёстка; road — на оси дороги;
    junction — магнит увидел несколько дорог, но все они сходятся в один узел
    рядом (это сам перекрёсток, выбирать не из чего); ambiguous — две дороги на
    равном удалении и не один узел: НЕ угадываем; off_road — дорог в радиусе нет."""
    raw = (lon, lat)
    roads = map_edits.roads_near(tiles_dir, raw, 200.0)
    node = cls == 'traffic_light'
    s = map_edits.snap(raw, roads, prefer_node=node)
    fp = map_edits.fingerprint(raw, roads)
    names = sorted({r.get('name') or '' for r in (s.ambiguous or [])} - {''})
    if s.road is None:
        return {'status': 'off_road', 'point': list(raw), 'anchor': None, 'candidates': [], 'fingerprint': fp}
    if s.ambiguous:
        if node:
            ends = [map_edits.nearest_node(raw, r['points']) for r in s.ambiguous]
            if all(e is not None for e in ends) and \
                    max(map_edits.meters_between(ends[0], e) for e in ends) < 1.0:
                anchor = dict(s.anchor, atNode=True)
                return {'status': 'junction', 'point': list(ends[0]), 'anchor': anchor,
                        'candidates': names, 'fingerprint': fp}
        return {'status': 'ambiguous', 'point': list(raw), 'anchor': None, 'candidates': names,
                'fingerprint': fp}
    return {'status': 'node' if s.at_node else 'road', 'point': [s.point[0], s.point[1]],
            'anchor': s.anchor, 'candidates': names, 'fingerprint': fp,
            'snap_m': round(map_edits.meters_between(raw, s.point), 1)}


# ---------- черновики ----------

def cluster_evidence(conn, cid):
    """Поездки, кадры и лучшая сработка кластера (для note и проверки глазами)."""
    trips = sorted({r[0] for r in conn.execute('SELECT trip_key FROM objects WHERE cluster=?', (cid,))})
    best = cluster.best_detections(conn, cid)
    return trips, [dict(b) for b in best]


def crossing_kind(conn, c, existing):
    """crossing=traffic_signals, если рядом светофор (наш кластер любого статуса
    с ≥ 2 поездками или OSM); иначе тег не ставим — «нерегулируемый» видео не
    доказывает: светофор мог просто не попасть в кадр."""
    if existing.gap('traffic_light', c['lat'], c['lon'], CROSSING_SIGNAL_M) is not None:
        return 'traffic_signals'
    for r in conn.execute("SELECT lat, lon FROM clusters WHERE cls='traffic_light' AND n_trips>=2 "
                          'AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?',
                          (c['lat'] - 0.0005, c['lat'] + 0.0005, c['lon'] - 0.0007, c['lon'] + 0.0007)):
        if gpx.haversine(c['lat'], c['lon'], r[0], r[1]) <= CROSSING_SIGNAL_M:
            return 'traffic_signals'
    return None


def make_draft(conn, c, snap, existing):
    trips, best = cluster_evidence(conn, c['id'])
    props = {'point': POINT_CODE[c['cls']], **OSM_TAGS[c['cls']], 'source': 'dashcam',
             'survey:date': max(trip_date(k) for k in trips), 'confidence': round(c['confidence'] or 0, 2),
             'trips': len(trips), 'frames': c['n_frames']}
    if c['cls'] == 'crossing':
        kind = crossing_kind(conn, c, existing)
        if kind:
            props['crossing'] = kind
    # Светофор у перехода: регулируемый переход (так и оказалось у всех
    # проверенных глазами). В OSM это теги узла перехода, а не второй узел рядом.
    xing = existing.gap('crossing', c['lat'], c['lon'], CROSSING_SIGNAL_M) \
        if c['cls'] == 'traffic_light' else None
    if xing is not None:
        props['crossing'] = 'traffic_signals'
    frame = best[0] if best else None
    note = (f"Видео регистратора: {CLS_RU[c['cls']]}, {len(trips)} поездки "
            f"({', '.join(trip_date(k) for k in trips)}), кадров {c['n_frames']}, "
            f"уверенность {c['confidence'] or 0:.0%}"
            + (f", точность места ±{c['err_m']:.0f} м." if c['err_m'] is not None else '.'))
    if c.get('decision') == 'accept':
        note += ' Принято человеком по кадру.'
    if frame:
        note += f" Кадр: {UI}/frame/{frame['frame_id']}.jpg (вырезка {UI}/crop/{frame['id']}.jpg)."
    if snap['status'] == 'ambiguous':
        note += ' МАГНИТ НЕОДНОЗНАЧЕН (' + ', '.join(snap['candidates'] or ['безымянные']) + \
            ') — точка не посажена, выберите дорогу.'
    elif snap['status'] == 'off_road':
        note += ' Дорог в 25 м нет — точка не посажена.'
    if xing is not None:
        note += (f' В {xing:.0f} м переход OSM — это регулируемый переход: в OSM поставить '
                 'crossing=traffic_signals (+ highway=traffic_signals) на узел перехода, '
                 'а не второй узел рядом.')
    return {
        # поля, которые принимает POST /api/edit панели (admin.edit_save_json)
        'kind': 'point', 'status': map_edits.DRAFT,
        'geom': snap['point'], 'raw': [c['lon'], c['lat']], 'anchor': snap['anchor'],
        'props': props, 'note': note, 'fingerprint': snap['fingerprint'],
        # только для человека и для проверки — панель их не читает
        'dashcam': {'cluster_id': c['id'], 'cls': c['cls'], 'snap': snap['status'],
                    'snap_candidates': snap['candidates'], 'snap_m': snap.get('snap_m'),
                    'err_m': round(c['err_m'], 1) if c['err_m'] is not None else None, 'trips': trips,
                    'decision': c.get('decision'),
                    'gap_m': round(c['gap_m'], 1) if c.get('gap_m') is not None else None,
                    'osm_crossing_m': round(xing, 1) if xing is not None else None,
                    'frame_id': frame['frame_id'] if frame else None,
                    'frame_path': frame['path'] if frame else None,
                    'det_id': frame['id'] if frame else None,
                    'box': [frame['x'], frame['y'], frame['w'], frame['h']] if frame else None},
    }


def build_drafts(conn, tiles_dir=TILES_DIR, existing=None):
    existing = existing or Existing(tiles_dir=tiles_dir)
    drafts = []
    for c in ready_clusters(conn, existing):
        d = make_draft(conn, c, snap_point(c['cls'], c['lat'], c['lon'], tiles_dir), existing)
        # место — у самого уверенного; поездки и кадры — общие (это один объект)
        d['dashcam']['merged'] = [m['id'] for m in c['merged']]
        for m in c['merged']:
            trips, _ = cluster_evidence(conn, m['id'])
            d['dashcam']['trips'] = sorted(set(d['dashcam']['trips']) | set(trips))
            d['props']['frames'] += m['n_frames']
        d['props']['trips'] = len(d['dashcam']['trips'])
        d['props']['survey:date'] = max(trip_date(k) for k in d['dashcam']['trips'])
        if c['merged']:
            d['note'] += (f" Тот же объект — ещё {len(c['merged'])} кластер(а) в пределах "
                          f"{MERGE_READY_M:g} м; всего поездок {d['props']['trips']}.")
        drafts.append(d)
    return drafts


# ---------- OSM ----------

def _esc(v):
    return (str(v).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;'))


def osm_change(drafts):
    """Точечные черновики → osmChange для JOSM. Тот же вид, что у map_edits.as_osm
    (отрицательные id — «ещё нет на сервере»), но для узлов: as_osm собирает
    только линии. В OSM уходят только теги объекта (highway, crossing);
    source/survey:date — тегами пакета правок при загрузке, а уверенность и
    число поездок — наше внутреннее, OSM их не ждёт. Неоднозначные и вне дорог
    не выгружаются, как и принятое человеком рядом с таким же объектом
    (gap_m < MIN_GAP_EXISTING_M): это подтверждение, а не новый узел — в
    черновики панели оно идёт, чтобы сборка нарисовала его при любом числе
    светофоров у узла."""
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<osmChange version="0.6" generator="RadarMap dashcam">', '  <create>']
    n = 0
    for d in drafts:
        if d['dashcam']['snap'] in ('ambiguous', 'off_road'):
            continue
        gap = d['dashcam'].get('gap_m')
        if gap is not None and gap < MIN_GAP_EXISTING_M:
            continue
        n += 1
        lon, lat = d['geom']
        tags = {k: d['props'][k] for k in ('highway', 'crossing') if d['props'].get(k)}
        lines.append(f'    <node id="-{n}" version="0" lat="{lat:.7f}" lon="{lon:.7f}">')
        for k, v in sorted(tags.items()):
            lines.append(f'      <tag k="{_esc(k)}" v="{_esc(v)}" />')
        lines.append('    </node>')
    lines += ['  </create>', '</osmChange>']
    return '\n'.join(lines) + '\n', n


# ---------- знаки ограничения на проверку ----------

def _axis_diff(a, b):
    d = abs((a - b) % 180)
    return min(d, 180 - d)


def limits_along(segs, lat, lon, course, r=LIMIT_NEAR_M):
    """Лимит дороги по курсу: ближайший отрезок с maxspeed в r м, идущий вдоль
    курса (± LIMIT_COURSE_DEG по модулю 180°). → (км/ч, м) или None."""
    ky = 111195.0
    kx = ky * math.cos(math.radians(lat))
    best = None
    for s in segs:
        if abs(s[0] - lat) > 0.001 or abs(s[1] - lon) > 0.0015:
            continue
        x0, y0 = (s[1] - lon) * kx, (s[0] - lat) * ky
        x1, y1 = (s[3] - lon) * kx, (s[2] - lat) * ky
        dx, dy = x1 - x0, y1 - y0
        L = dx * dx + dy * dy
        if L <= 0:
            continue
        if course is not None and _axis_diff(math.degrees(math.atan2(dx, dy)) % 360, course) > LIMIT_COURSE_DEG:
            continue
        u = max(0.0, min(1.0, -(x0 * dx + y0 * dy) / L))
        d = math.hypot(x0 + dx * u, y0 + dy * u)
        if d <= r and (best is None or d < best[1]):
            best = (s[4], d)
    return best


def circular_mean(angles):
    if not angles:
        return None
    x = sum(math.sin(math.radians(a)) for a in angles)
    y = sum(math.cos(math.radians(a)) for a in angles)
    return math.degrees(math.atan2(x, y)) % 360


def review_limits(conn):
    rows = [dict(r) for r in conn.execute(
        "SELECT * FROM clusters WHERE cls='speed_limit' AND status='differs' ORDER BY confidence DESC")]
    if not rows:
        return []
    segs = cluster.load_limits((min(r['lat'] for r in rows), min(r['lon'] for r in rows),
                                max(r['lat'] for r in rows), max(r['lon'] for r in rows)))
    out = []
    for c in rows:
        ref = json.loads(c['map_ref'] or '{}')
        courses = [r[0] for r in conn.execute(
            'SELECT f.course FROM detections d JOIN frames f ON f.id=d.frame_id JOIN objects o ON o.id=d.obj '
            'WHERE o.cluster=? AND f.course IS NOT NULL', (c['id'],))]
        course = circular_mean(courses)
        along = limits_along(segs, c['lat'], c['lon'], course)
        trips, best = cluster_evidence(conn, c['id'])
        b = best[0] if best else None
        out.append({'cluster_id': c['id'], 'lat': round(c['lat'], 6), 'lon': round(c['lon'], 6),
                    'video_kmh': c['value'], 'base_kmh_along_course': along[0] if along else '',
                    'base_kmh_nearby': ' '.join(str(v) for v in ref.get('values', [])),
                    'base_dist_m': ref.get('dist_m'), 'course': round(course) if course is not None else '',
                    'err_m': round(c['err_m'], 1), 'trips': len(trips),
                    'trip_dates': ' '.join(trip_date(k) for k in trips), 'frames': c['n_frames'],
                    'confidence': round(c['confidence'], 2),
                    'frame_url': f"{UI}/frame/{b['frame_id']}.jpg" if b else '',
                    'crop_url': f"{UI}/crop/{b['id']}.jpg" if b else '',
                    'frame_path': b['path'] if b else ''})
    return out


# ---------- экспорт ----------

README = """# Находки видео регистратора → правки карты

Собрано {when} командой `python3 tools/dashcam/mapready.py export`
из `~/RadarMapBuild/dashcam/dashcam.db` (привязка кадров с поправкой времени
wpt, см. `tools/dashcam/passtime.py`).

**Ничего из этого НЕ применено**: ни в панель, ни в тайлы, ни в OSM. Это
черновики на решение человека.

## Что внутри

| Файл | Что | Сколько |
|---|---|---|
| `drafts.json` | черновики конструктора (`kind: "point"`), формат `POST /api/edit` панели | {n_drafts} ({by_cls}) |
| `changes.osc` | те же точки для JOSM (osmChange), кроме неоднозначных и подтверждений уже существующих | {n_osc} |
| `review_limits.csv` | знаки ограничения, расходящиеся с лимитами OSM — **на проверку** | {n_limits} |

Посадка магнитом (`map_edits.snap` к тайлам `{tiles}`): {snap_stats}.
«ambiguous» — две дороги на равном удалении, точка НЕ посажена (geom = raw),
в `changes.osc` не попала: выберите дорогу в панели руками.

Отбор «готово к карте» (пороги — константы в `tools/dashcam/mapready.py`):
статус «новое», ≥ {min_trips} разных поездки, точность места ≤ {max_err:g} м,
уверенность ≥ {min_conf}, не ближе {gap:g} м к такому же объекту OSM или наших
тайлов; готовые одного класса ближе {merge:g} м слиты в одну.

**Принятое человеком** на странице разбора («принять» по кадру) — готово
всегда, без этих порогов: их {n_accepted}. Принятое рядом с таким же объектом
OSM — подтверждение: в черновики идёт (сборка рисует подтверждённый человеком
светофор при любом числе светофоров у узла), в `changes.osc` — нет.

## Как проверить

Проверка глазами 08.10.2026 (кадр каждой находки): все черновики — настоящие
светофоры, три из четырёх — светофоры пешеходного перехода (узел перехода
OSM в 11–19 м), место совпадает с перекрёстком/переходом на кадре. Первый
прогон с порогом слияния 25 м дал дубль одного светофора в 39 м — порог
поднят до 50 м. Выборка маленькая: честная точность места — медиана ~23 м
на камерах фиксации (`docs/plan_dashcam_ml.md`, «Точность привязки»).

Страница разбора `http://127.0.0.1:8780` → «Находки» → статус «готово к
карте». В каждом черновике `note` — ссылка на кадр, `dashcam.frame_path` —
сам кадр на диске.

## В панель (черновиками конструктора) — команда для владельца

Вход и куки — как в `~/.claude/skills/radarmap-admin` (`login.sh`). Затем:

```sh
BASE=https://soulmed.uz/radarmap/admin
jq -c '.[] | {{kind, status, geom, raw, anchor, props, note, fingerprint}}' drafts.json |
while read -r e; do
  curl -sS -b ~/.radarmap/admin-cookies -H 'Content-Type: application/json' \\
       -H "Origin: https://soulmed.uz" -d "$e" "$BASE/api/edit"; echo
done
```

Каждая строка станет черновиком (status 0) в `/editor`; принимать — там же,
по одной, глядя на кадр из `note`.

## В OSM через JOSM

1. JOSM → Файл → Открыть → `changes.osc` (слой новых узлов).
2. Загрузить данные OSM вокруг (Файл → Загрузить данные, рамка по слою).
3. Для каждого узла: светофор должен стать **узлом дороги** — выделить
   новый узел и узел перекрёстка, «Объединить узлы» (M); если узла нет —
   «Присоединить узел к линии» (J). Переход — тоже на линию дороги (J).
   Сверить с кадром из `drafts.json` (`note`). Если рядом уже есть узел
   перехода (`dashcam.osm_crossing_m` в черновике) — объединять с НИМ и
   оставить `highway=traffic_signals` + `crossing=traffic_signals`: это
   регулируемый переход, второй узел в паре метров от первого не нужен.
4. Выгрузить с тегами пакета: `source=survey;dashcam`,
   `comment=Светофоры/переходы по видео регистратора, проверены по кадрам`.
   По правилам организованной правки — с учётки владельца, небольшими пакетами.

## Знаки ограничения

`review_limits.csv`: `video_kmh` — число на знаке (по видео),
`base_kmh_along_course` — лимит OSM ближайшей дороги по курсу машины,
`base_kmh_nearby` — все лимиты в {near:g} м. Автоматически не применяется:
знак мог стоять на дублёре, на въезде во двор или быть временным.

Детектор знаков пока видит их в 1 кадре одной поездки, и список шумный:
при проверке глазами 08.10.2026 из 9 строк 3 — настоящий знак с верным
числом, 3 — настоящий знак, но число прочитано неверно (60 → 80, 60 → 50,
30 → 50), 3 — не знак (номер автобуса «110», реклама «−50 %», пусто).
Каждую строку — только по кадру (`frame_url`).
"""


def export(out_dir=OUT_DIR, tiles_dir=TILES_DIR, conn=None, log=print):
    conn = conn or catalog.connect()
    os.makedirs(out_dir, exist_ok=True)
    drafts = build_drafts(conn, tiles_dir)
    with open(os.path.join(out_dir, 'drafts.json'), 'w') as f:
        json.dump(drafts, f, ensure_ascii=False, indent=1)
    osc, n_osc = osm_change(drafts)
    with open(os.path.join(out_dir, 'changes.osc'), 'w') as f:
        f.write(osc)
    lim = review_limits(conn)
    cols = ['cluster_id', 'lat', 'lon', 'video_kmh', 'base_kmh_along_course', 'base_kmh_nearby',
            'base_dist_m', 'course', 'err_m', 'trips', 'trip_dates', 'frames', 'confidence',
            'frame_url', 'crop_url', 'frame_path']
    with open(os.path.join(out_dir, 'review_limits.csv'), 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(lim)
    by_cls, snaps = {}, {}
    for d in drafts:
        by_cls[d['dashcam']['cls']] = by_cls.get(d['dashcam']['cls'], 0) + 1
        snaps[d['dashcam']['snap']] = snaps.get(d['dashcam']['snap'], 0) + 1
    n_accepted = sum(1 for d in drafts if d['dashcam'].get('decision') == 'accept')
    summary = {'drafts': len(drafts), 'accepted': n_accepted, 'by_cls': by_cls, 'snap': snaps,
               'osc_nodes': n_osc, 'review_limits': len(lim)}
    with open(os.path.join(out_dir, 'README.md'), 'w') as f:
        f.write(README.format(
            when=time.strftime('%d.%m.%Y %H:%M'), n_drafts=len(drafts), n_accepted=n_accepted,
            by_cls=', '.join(f'{CLS_RU[k]} {v}' for k, v in sorted(by_cls.items())) or 'нет',
            n_osc=n_osc, n_limits=len(lim), tiles=tiles_dir,
            snap_stats=', '.join(f'{k} {v}' for k, v in sorted(snaps.items())) or 'нет',
            min_trips=MIN_TRIPS, max_err=MAX_ERR_M, min_conf=MIN_CONFIDENCE, gap=MIN_GAP_EXISTING_M,
            merge=MERGE_READY_M, near=LIMIT_NEAR_M))
    log(json.dumps(summary, ensure_ascii=False))
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description='Находки видео → черновики правок карты (локально)')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('export')
    p.add_argument('--out', default=OUT_DIR)
    p.add_argument('--tiles', default=TILES_DIR)
    sub.add_parser('why')
    a = ap.parse_args(argv)
    if a.cmd == 'export':
        export(a.out, a.tiles)
    elif a.cmd == 'why':
        conn = catalog.connect()
        cnt = {}
        for c, why in evaluate(conn):
            for w in (why or ['ГОТОВО']):
                key = (c['cls'], w.split(' ')[0] if why else w)
                cnt[key] = cnt.get(key, 0) + 1
        for k, v in sorted(cnt.items()):
            print(k, v)


if __name__ == '__main__':
    sys.exit(main())
