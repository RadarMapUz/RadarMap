#!/usr/bin/env python3
"""Кандидаты на наложение светофоров, не вердикт о дефектах карты.

Плоская карта, север сверху; размер собственного значка 10×20 pt,
масштаб современного стиля, padding 1 px. Решения collision engine,
наклон, поворот, камеры и подписи здесь не моделируются.
"""
import argparse
import json
import math

from road_metrics import load_build, seg_distance_m


def audit(layers):
    lights = [p for kind, parts, props in layers.get('surface', [])
              if kind == 1 and props.get('kind') == 14 for part in parts for p in part]
    segments = [(props.get('kind'), a, b)
                for _, parts, props in layers.get('paint', [])
                if props.get('kind') in (1, 12)
                for part in parts for a, b in zip(part, part[1:])]
    overlaps = {}
    for zoom in (16, 17, 18, 19):
        scale = .7 + .1 * (zoom - 16)
        pairs = []
        for i, a in enumerate(lights):
            kx = 111320 * math.cos(math.radians(a[1]))
            metres_per_pixel = 40075016.7 * math.cos(math.radians(a[1])) / (512 * 2**zoom)
            for b in lights[i + 1:]:
                dx = abs(a[0] - b[0]) * kx / metres_per_pixel
                dy = abs(a[1] - b[1]) * 111320 / metres_per_pixel
                if dx < 10 * scale + 2 and dy < 20 * scale + 2:
                    pairs.append([a, b])
        overlaps[zoom] = {'count': len(pairs), 'pairs_lon_lat': pairs}
    near = []
    for point in lights:
        best = (math.inf, None)
        # Отсев по рамке сегмента, не по первому концу длинной линии.
        for kind, a, b in segments:
            if not (min(a[0], b[0]) - .002 <= point[0] <= max(a[0], b[0]) + .002
                    and min(a[1], b[1]) - .002 <= point[1] <= max(a[1], b[1]) + .002):
                continue
            distance = seg_distance_m(point, a, b)
            if distance < best[0]:
                best = distance, kind
        if best[0] < 3:
            near.append({'point_lon_lat': point, 'distance_metres': round(best[0], 2),
                         'paint_kind': best[1]})
    return {'signal_points': len(lights), 'approximate_overlap_candidates': overlaps,
            'within_3m_of_paint': near}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tiles')
    args = parser.parse_args()
    print(json.dumps(audit(load_build(args.tiles)), indent=2))


if __name__ == '__main__':
    main()
