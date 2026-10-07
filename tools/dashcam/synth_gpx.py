#!/usr/bin/env python3
"""Синтетический подробный GPX для отладки синхронизации — НЕ правда о поездке.

Берёт скорость из полосы кадра (CSV «time,speed», время регистратора) и
раздаёт её по форме маршрута: форма — из настоящего GPX старой поездки,
если он дан (--shape), иначе ломаная по Ташкенту (Беруни → Навои → Амира
Темура → Мирзо Улугбека). Путь по скорости растягивается на длину формы.
Часы «телефона» сдвинуты на --shift секунд (по умолчанию +7) — чтобы
синхронизации было что находить. Файл помечен creator="RadarMap-synthetic",
страница показывает его как синтетику.

    python3 synth_gpx.py ~/RadarMapBuild/dashcam/morning_speed.csv OUT.gpx \
        [--shape ~/RadarMapBuild/dashcam/morning.gpx] [--shift 7]
"""
import argparse
import csv
import random
import sys
from datetime import datetime

import catalog
import gpx
import locate

# Ломаная по Ташкенту на случай, когда настоящей формы нет.
TASHKENT_ROUTE = [
    (41.3295, 69.2210), (41.3245, 69.2330), (41.3200, 69.2420),  # Беруни → Навои
    (41.3170, 69.2490), (41.3130, 69.2620), (41.3110, 69.2790),  # Навои → сквер
    (41.3180, 69.2820), (41.3260, 69.2850),                      # Амира Темура
    (41.3255, 69.3000), (41.3240, 69.3150), (41.3290, 69.3400),  # Мирзо Улугбека
]


def read_speed_csv(path):
    """→ [(время регистратора, км/ч или None)]."""
    out = []
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            if not row.get('time'):
                continue
            t = datetime.strptime(row['time'], '%Y-%m-%d %H:%M:%S').replace(
                tzinfo=catalog.DASHCAM_TZ).timestamp()
            out.append((t, float(row['speed']) if row.get('speed') else None))
    return out


def synthesize(speed_rows, shape, shift=7.0, noise_kmh=0.7, seed=1):
    """→ [(время телефона, lat, lon, км/ч)] раз в секунду.

    Секунда в полосе — усечение, поэтому точка ставится в середину секунды
    (+0,5): так найденный сдвиг и есть shift, без систематической полсекунды."""
    rows = {}
    for t, v in speed_rows:
        if v is not None:
            rows.setdefault(t, []).append(v)
    series = sorted((t, sum(v) / len(v)) for t, v in rows.items())
    if len(series) < 2:
        raise ValueError('в CSV меньше двух прочитанных скоростей')
    rnd = random.Random(seed)
    line = locate.Polyline(shape)
    odo = locate.Odometer(series)
    total = odo.at(series[-1][0]) or 1.0
    out = []
    for t, v in series:
        lat, lon, _ = line.point_at(line.length * odo.at(t) / total)
        kmh = max(0.0, v + rnd.uniform(-noise_kmh, noise_kmh)) if v > 0 else 0.0
        out.append((t + 0.5 + shift, lat, lon, kmh))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description='Синтетический GPX по скорости из кадра')
    ap.add_argument('speed_csv')
    ap.add_argument('out')
    ap.add_argument('--shape', help='GPX, из которого взять форму маршрута')
    ap.add_argument('--shift', type=float, default=7.0, help='сдвиг часов телефона, с')
    a = ap.parse_args(argv)
    shape = TASHKENT_ROUTE
    if a.shape:
        shape = gpx.parse(a.shape)['shape'] or TASHKENT_ROUTE
    pts = synthesize(read_speed_csv(a.speed_csv), shape, a.shift)
    gpx.write(a.out, f'СИНТЕТИКА, сдвиг {a.shift:+.0f} с', pts, synthetic=True,
              desc=f'Синтетический трек: скорость из кадра, форма '
                   f'{"из " + a.shape if a.shape else "ломаная по Ташкенту"}, сдвиг {a.shift:+.1f} с')
    print(f'{len(pts)} точек → {a.out}')


if __name__ == '__main__':
    sys.exit(main())
