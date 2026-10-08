#!/usr/bin/env python3
"""Сдвиг часов регистратора относительно трека телефона.

Часы регистратора уходят от часов телефона на секунды–минуты. Сдвиг ищем
по самой скорости: скорость из полосы кадра (OCR раз в секунду) против
скорости трека — максимум взаимной корреляции Пирсона. Остановки у
светофоров дают резкие «ступеньки», поэтому пик острый.

    offset: время телефона = время регистратора + offset

Сетка ±120 с с шагом 1 с, затем уточнение ±1 с с шагом 0,1 с. Качество —
корреляция Пирсона в пике; «годится» — если она не ниже GOOD_R, общих
секунд не меньше MIN_SAMPLES и пик не упёрся в край сетки (на краю это
не максимум, а обрыв поиска).

    python3 sync.py            — синхронизировать все поездки, у которых есть OCR и трек
"""
import bisect
import json
import math
import sys
import time

WINDOW_SECONDS = 120
REFINE_STEP = 0.1
GOOD_R = 0.85
MIN_SAMPLES = 120
# Дыра в треке длиннее этого — между точками не интерполируем.
MAX_TRACK_GAP = 5.0
# Старая поездка: медианная невязка между опорами, при которой привязка годится.
# Форма маршрута упрощена (срезает углы), скорость в кадре — целые км/ч,
# поэтому десятки метров на перегон — норма; сотни — что-то не так.
ANCHOR_GOOD_M = 150
# OCR иногда читает «146» вместо «46»; быстрее этого регистратор не ездит.
MAX_PLAUSIBLE_KMH = 200


class Series:
    """Ряд (t, v) с линейной интерполяцией; дыры длиннее max_gap — None."""

    def __init__(self, points, max_gap=MAX_TRACK_GAP):
        pts = sorted(points)
        self.t = [p[0] for p in pts]
        self.v = [p[1] for p in pts]
        self.max_gap = max_gap

    def at(self, t):
        ts = self.t
        i = bisect.bisect_left(ts, t)
        if i < len(ts) and ts[i] == t:
            return self.v[i]
        if i == 0 or i == len(ts):
            return None
        t0, t1 = ts[i - 1], ts[i]
        if t1 - t0 > self.max_gap:
            return None
        k = (t - t0) / (t1 - t0)
        return self.v[i - 1] + (self.v[i] - self.v[i - 1]) * k


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sxy = syy = 0.0
    for x, y in zip(xs, ys):
        dx, dy = x - mx, y - my
        sxx += dx * dx
        syy += dy * dy
        sxy += dx * dy
    if sxx <= 0 or syy <= 0:
        return None  # постоянный ряд (вся поездка стоим) — корреляции нет
    return sxy / math.sqrt(sxx * syy)


def clean_ocr(points):
    """Отбрасывает невозможные скорости и усредняет повторы одной секунды."""
    acc = {}
    for t, v in points:
        if v is None or v < 0 or v > MAX_PLAUSIBLE_KMH:
            continue
        acc.setdefault(round(t, 3), []).append(v)
    return [(t, sum(vs) / len(vs)) for t, vs in sorted(acc.items())]


def score(ocr, track, shift):
    """Корреляция OCR(t) с трек(t + shift) по общим секундам → (r, n)."""
    xs, ys = [], []
    for t, v in ocr:
        w = track.at(t + shift)
        if w is not None:
            xs.append(v)
            ys.append(w)
    return pearson(xs, ys), len(xs)


def find_offset(ocr_points, track_points, window=WINDOW_SECONDS, step=REFINE_STEP):
    """ocr_points: [(время регистратора, км/ч)], track_points: [(время телефона, км/ч)].
    → dict(offset, quality, n, good, edge, curve=[(сдвиг, r)]) или None, если общих
    данных нет совсем."""
    ocr = clean_ocr(ocr_points)
    track = Series(track_points)
    curve = []
    best = None
    for s in range(-window, window + 1):
        r, n = score(ocr, track, s)
        curve.append((s, r))
        if r is not None and n >= MIN_SAMPLES // 2 and (best is None or r > best[1]):
            best = (s, r, n)
    if best is None:
        return None
    # Уточнение до десятых секунды вокруг целого пика.
    fine = best
    k = -int(round(1 / step))
    while k <= int(round(1 / step)):
        s = best[0] + k * step
        r, n = score(ocr, track, s)
        if r is not None and r > fine[1]:
            fine = (round(s, 3), r, n)
        k += 1
    edge = abs(best[0]) >= window
    good = fine[1] >= GOOD_R and fine[2] >= MIN_SAMPLES and not edge
    return {'offset': fine[0], 'quality': fine[1], 'n': fine[2], 'good': good,
            'edge': edge, 'curve': curve}


def anchored_model(conn, key, track, offset=0.0):
    """Модель старой поездки: форма трека + опоры + скорость из кадра (в часах телефона).
    Опоры — на исправленный момент проезда (passtime: время wpt — «отпускание»
    камеры, ~740 м пути после неё)."""
    import catalog
    import locate
    import passtime
    speed = [(t + offset, v) for t, v in clean_ocr(catalog.ocr_series(conn, key))]
    anchors = [a[:4] for a in passtime.correct(catalog.track_waypoints(conn, track['id']),
                                                passtime.Odo(speed))]
    return locate.AnchoredTrack(catalog.track_shape(conn, track['id']), anchors, speed)


def anchors_quality(summary):
    """«Годится» для привязки по опорам: хотя бы две опоры внутри видео и
    медианная невязка между ними не больше ANCHOR_GOOD_M."""
    med = summary['residual_median_m']
    return summary['anchors_used'] >= 2 and med is not None and med <= ANCHOR_GOOD_M


def _store(conn, key, track_id, method, offset, quality, n, good, detail):
    with conn:
        conn.execute('INSERT OR REPLACE INTO sync(trip_key, track_id, method, offset, quality, n, '
                     'good, detail, computed) VALUES(?,?,?,?,?,?,?,?,?)',
                     (key, track_id, method, offset, quality, n, int(good),
                      json.dumps(detail), time.time()))


def sync_trip(conn, key, track_id=None):
    """Считает и сохраняет сдвиг поездки к треку (по умолчанию — к настоящему).

    Подробный трек — корреляция скорости. Старая поездка (время только у опор) —
    скорость проезда камеры там — минимум в зоне 80 м, а не мгновенная, и
    корреляция по 17 проездам «скачет» на десятки секунд; поэтому сдвиг 0
    (часы регистратора и телефона обе от сети), а качество — невязка по опорам."""
    import catalog
    trip = catalog.get_trip(conn, key)
    tr = catalog.track_for_trip(conn, trip, track_id)
    if tr is None:
        return None
    if tr['kind'] == 'anchored':
        summary = anchored_model(conn, key, tr).summary()
        good = anchors_quality(summary)
        _store(conn, key, tr['id'], 'anchors', 0.0, None, summary['anchors_used'], good, summary)
        return {'method': 'anchors', 'offset': 0.0, 'good': good, **summary}
    ocr = catalog.ocr_series(conn, key)
    pts = catalog.track_points(conn, tr['id'], trip['start'] - 2 * WINDOW_SECONDS,
                               trip['end'] + 2 * WINDOW_SECONDS)
    res = find_offset(ocr, [(p[0], p[3]) for p in pts])
    if res is None:
        _store(conn, key, tr['id'], 'speed', None, None, 0, False, {})
        return None
    detail = {'edge': res['edge'],
              'curve': [(s, None if r is None else round(r, 4)) for s, r in res['curve']]}
    _store(conn, key, tr['id'], 'speed', res['offset'], res['quality'], res['n'], res['good'], detail)
    return {'method': 'speed', **res}


def describe(res):
    if res is None:
        return 'нет общих данных'
    verdict = 'годится' if res['good'] else 'НЕ годится'
    if res['method'] == 'anchors':
        return (f"по опорам: {res['anchors_used']} из {res['anchors']}, невязка медиана "
                f"{res['residual_median_m']} м, макс {res['residual_max_m']} м — {verdict}")
    return f"сдвиг {res['offset']:+.1f} с, r={res['quality']:.3f}, n={res['n']} — {verdict}"


def main():
    import catalog
    conn = catalog.connect()
    for t in catalog.trips(conn):
        if t['ocr_done'] < t['clips']:
            continue
        for tr in t['tracks']:
            print(f"{t['key']} × {tr['name']}: {describe(sync_trip(conn, t['key'], tr['id']))}")


if __name__ == '__main__':
    sys.exit(main())
