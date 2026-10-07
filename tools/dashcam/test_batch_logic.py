#!/usr/bin/env python3
"""Тесты чистой логики пакетного разбора: выбор кадров по пути, восстановление
маршрута по опорам с кэшем OSRM (мок), надёжность перегонов, триангуляция,
связывание сработок, кластеризация и сверка, события и опознание камер,
приватность сработок."""
import json
import math
import os
import tempfile
import unittest

import anchorhmm
import catalog
import cluster
import detect
import frames
import geo
import objects
import selfcam

LAT0, LON0 = 41.31, 69.25
M_LAT = 1 / 111195.0
M_LON = 1 / (111195.0 * math.cos(math.radians(LAT0)))


def at(east_m, north_m):
    return LAT0 + north_m * M_LAT, LON0 + east_m * M_LON


class FrameSelectionTest(unittest.TestCase):
    def test_step_by_distance(self):
        # 36 км/ч = 10 м/с → кадр каждые 0,8 с, за 10 с — ~12 кадров + первый
        prof = frames.speed_profile([(t, 36.0) for t in range(11)], 10.0)
        pos = frames.select_positions(prof, 10.0)
        self.assertEqual(pos[0], 0.0)
        self.assertTrue(11 <= len(pos) <= 14, pos)
        gaps = [b - a for a, b in zip(pos, pos[1:])]
        self.assertTrue(all(abs(g - 0.8) < 0.11 for g in gaps), gaps)

    def test_faster_means_denser(self):
        slow = frames.select_positions(frames.speed_profile([(t, 20.0) for t in range(61)], 60), 60)
        fast = frames.select_positions(frames.speed_profile([(t, 80.0) for t in range(61)], 60), 60)
        self.assertGreater(len(fast), 3 * len(slow))

    def test_standstill_at_most_one_per_10s(self):
        prof = frames.speed_profile([(t, 0.0) for t in range(121)], 120)
        pos = frames.select_positions(prof, 120)
        gaps = [b - a for a, b in zip(pos, pos[1:])]
        self.assertTrue(all(g >= 9.99 for g in gaps), gaps)
        self.assertTrue(10 <= len(pos) <= 13)

    def test_ocr_gaps_interpolated(self):
        prof = frames.speed_profile([(0, 0.0), (10, 36.0), (5, None)], 10)
        self.assertAlmostEqual(prof[5], 18.0)
        self.assertIsNone(frames.speed_profile([(0, None)], 10))

    def test_no_ocr_every_2s(self):
        self.assertEqual(frames.select_positions(None, 9.0), [0.0, 2.0, 4.0, 6.0, 8.0])

    def test_nearest_indices_dedup(self):
        times = [0.0, 0.04, 0.1, 0.5, 0.9]
        self.assertEqual(frames.nearest_indices(times, [0.0, 0.03, 0.45, 2.0]),
                         [(0, 0.0), (1, 0.04), (3, 0.5), (4, 0.9)])

    def test_select_expression_is_balanced(self):
        expr = frames._sum_tree([f'e{i}' for i in range(200)])
        depth = max_depth = 0
        for ch in expr:
            depth += ch == '('
            depth -= ch == ')'
            max_depth = max(max_depth, depth)
        self.assertLessEqual(max_depth, 9)
        self.assertEqual(expr.count('e'), 200)

    def test_frame_name_is_local_time(self):
        t = catalog.parse_clip_name('2026-10-07-08-05-10.mp4') + 0.25
        self.assertEqual(frames.frame_name(t), '20261007-080510-250.jpg')

    def test_to_src(self):
        x, y = frames.to_src(640, 0)
        self.assertAlmostEqual(x, 960)
        self.assertAlmostEqual(y, frames.CROP_TOP)


class FakeFetch:
    """OSRM-мок: маршрут — прямая через середину, смещённую в сторону (длиннее прямой)."""

    def __init__(self, detour_m=0.0, fail=()):
        self.calls, self.detour, self.fail = [], detour_m, set(fail)

    def __call__(self, url):
        self.calls.append(url)
        coords = url.split('/driving/')[1].split('?')[0]
        (lon1, lat1), (lon2, lat2) = [tuple(map(float, p.split(','))) for p in coords.split(';')]
        if (round(lat1, 5), round(lon1, 5)) in self.fail:
            return json.dumps({'code': 'NoRoute'})
        mid = ((lat1 + lat2) / 2 + self.detour * M_LAT, (lon1 + lon2) / 2)
        pts = [(lat1, lon1), mid, (lat2, lon2)]
        d = sum(geo.gpx.haversine(a[0], a[1], b[0], b[1]) for a, b in zip(pts, pts[1:]))
        return json.dumps({'code': 'Ok', 'routes': [{'distance': d,
                           'geometry': {'coordinates': [[lo, la] for la, lo in pts]}}]})


class OsrmCacheTest(unittest.TestCase):
    def setUp(self):
        self.conn = catalog.connect(':memory:')
        self.clock = [0.0]
        self.slept = []

    def osrm(self, fetch):
        def sleep(s):
            self.slept.append(s)
            self.clock[0] += s
        return geo.OSRM(self.conn, fetch=fetch, sleep=sleep, clock=lambda: self.clock[0])

    def test_cache_and_rate_limit(self):
        f = FakeFetch()
        o = self.osrm(f)
        a, b, c = at(0, 0), at(500, 0), at(1000, 0)
        r1 = o.route(a, b)
        r2 = o.route(b, c)
        self.assertEqual(len(f.calls), 2)
        self.assertAlmostEqual(sum(self.slept), 0.5, places=6)   # второй запрос ждал
        self.assertAlmostEqual(r1[1], 500, delta=1)
        o2 = self.osrm(f)                                         # новый объект — тот же кэш в БД
        self.assertEqual(o2.route(a, b), r1)
        self.assertEqual(len(f.calls), 2)
        self.assertEqual(o2.hits, 1)
        self.assertIsNotNone(r2)

    def test_network_error_not_cached(self):
        def boom(url):
            raise OSError('нет сети')
        o = self.osrm(boom)
        self.assertIsNone(o.route(at(0, 0), at(100, 0)))
        self.assertEqual(self.conn.execute('SELECT COUNT(*) FROM route_cache').fetchone()[0], 0)

    def test_bearings_change_key_and_url(self):
        f = FakeFetch()
        o = self.osrm(f)
        o.route(at(0, 0), at(500, 0))
        o.route(at(0, 0), at(500, 0), bearings=(90, None))
        self.assertEqual(len(f.calls), 2)
        self.assertIn('&bearings=90,45;', f.calls[1])


class RouteFromAnchorsTest(unittest.TestCase):
    def setUp(self):
        self.conn = catalog.connect(':memory:')

    def trip(self, detour, speed_kmh=36.0, fail=()):
        # опоры через 500 м на восток, едем 10 м/с: опора каждые 50 с
        anchors = [(1000 + 50 * i, *at(500 * i, 0), f'камера {i}') for i in range(4)]
        speed = [(t, speed_kmh) for t in range(990, 1170)]
        o = geo.OSRM(self.conn, fetch=FakeFetch(detour, fail), min_interval=0)
        return geo.build_trip_geo(995, 1160, speed, anchors, [], o), o

    def test_osrm_reconstruction_reliable(self):
        g, _ = self.trip(detour=10)
        self.assertEqual(g.source, 'osrm')
        self.assertEqual(len(g.segments), 3)
        self.assertTrue(all(s['reliable'] for s in g.segments))
        lat, lon, course, w, seg = g.locate(1025)                # середина первого перегона
        self.assertAlmostEqual((lon - LON0) / M_LON, 250, delta=15)
        self.assertGreater(w, 0.5)
        self.assertEqual(seg, 0)
        self.assertIsNone(g.locate(990))                          # до первой опоры формы нет

    def test_long_detour_is_unreliable(self):
        g, _ = self.trip(detour=400)                              # маршрут ~1000 м против 500 по скорости
        self.assertTrue(all(not s['reliable'] for s in g.segments))
        self.assertAlmostEqual(g.locate(1025)[3], geo.WEIGHT_UNRELIABLE)
        self.assertLess(g.segments[0]['residual_m'], -300)

    def test_failed_route_is_straight_and_unreliable(self):
        g, _ = self.trip(detour=0, fail={tuple(round(x, 5) for x in at(500, 0))})
        self.assertFalse(g.segments[1]['reliable'])
        self.assertTrue(g.segments[0]['reliable'])

    def test_second_run_uses_cache(self):
        _, o1 = self.trip(detour=10)
        _, o2 = self.trip(detour=10)
        self.assertEqual(o1.requests, 3)
        self.assertEqual(o2.requests, 0)

    def test_segment_reliability_threshold(self):
        self.assertTrue(geo.segment_reliable(1000, 1300))
        self.assertFalse(geo.segment_reliable(1000, 1400))
        self.assertTrue(geo.segment_reliable(30, 50))
        self.assertFalse(geo.segment_reliable(10, 50))

    def test_trk_name_time_and_anchor_dedup(self):
        trk = {'name': 'RadarMap 2026-10-06T090904', 't': None, 'shape': [(1, 1), (2, 2)]}
        m = geo.NAME_TIME_RE.search(trk['name'])
        self.assertIsNotNone(m)
        w = [(100, *at(0, 0), 'a'), (100, *at(50, 0), 'b'), (101, *at(2, 0), 'c'), (130, *at(300, 0), 'd')]
        self.assertEqual([x[3] for x in geo.anchors_for(w, 90, 140)], ['a', 'd'])


class LensTriangulationTest(unittest.TestCase):
    def test_lens_round_trip(self):
        for model in ('equidistant', 'pinhole'):
            lens = objects.Lens(hfov_deg=120, yaw_deg=1.5, model=model)
            for x in (100, 700, 960, 1500, 1850):
                self.assertAlmostEqual(lens.pixel(lens.angle(x)), x, places=6)
            self.assertAlmostEqual(lens.angle(1920) - lens.angle(0), 120, places=6)

    def test_triangulate_exact(self):
        target = (12.0, 60.0)
        rays = []
        for y in (0.0, 10.0, 20.0, 30.0):
            brg = math.degrees(math.atan2(target[0], target[1] - y)) % 360
            rays.append(((0.0, y), brg))
        x, y, rms, spread = objects.triangulate(rays)
        self.assertAlmostEqual(x, 12.0, places=6)
        self.assertAlmostEqual(y, 60.0, places=6)
        self.assertLess(rms, 1e-6)
        self.assertGreater(spread, 5)

    def test_triangulate_rejects_behind_and_parallel(self):
        self.assertIsNone(objects.triangulate([((0, 0), 0.0), ((0, 10), 0.0)]))
        self.assertIsNone(objects.triangulate([((0, 0), 315.0), ((10, 0), 45.0)]))  # лучи расходятся: пересечение позади

    def test_angular_spread_wraps(self):
        self.assertAlmostEqual(objects.angular_spread([359.0, 2.0, 1.0]), 3.0)

    def test_track_located_end_to_end(self):
        """Машина едет на север, светофор в 6 м правее оси на 60 м: кадры
        с правильными пикселями по модели объектива → точка в пределах метра."""
        lens = objects.Lens()
        plane = objects.Plane(LAT0, LON0)
        obs = []
        for k, y in enumerate((0.0, 8.0, 16.0, 24.0, 32.0)):
            ang = math.degrees(math.atan2(6.0, 60.0 - y))
            px = lens.pixel(ang)
            lat, lon = plane.ll(0.0, y)
            obs.append({'id': k, 't': k, 'cls': 'traffic_light', 'value': None, 'x': px - 5, 'y': 300,
                        'w': 10, 'h': 10, 'lat': lat, 'lon': lon, 'course': 0.0})
        loc = objects.locate_track(obs, lens, plane)
        x, y = plane.xy(loc['lat'], loc['lon'])
        self.assertEqual(loc['method'], 'tri')
        self.assertAlmostEqual(x, 6.0, delta=0.5)
        self.assertAlmostEqual(y, 60.0, delta=1.0)

    def test_size_fallback(self):
        lens = objects.Lens()
        plane = objects.Plane(LAT0, LON0)
        o = {'id': 1, 't': 0, 'cls': 'crossing', 'value': None, 'x': 955, 'y': 300, 'w': 10, 'h': 10,
             'lat': LAT0, 'lon': LON0, 'course': 0.0}
        loc = objects.locate_track([o], lens, plane)
        self.assertEqual(loc['method'], 'size')
        x, y = plane.xy(loc['lat'], loc['lon'])
        self.assertAlmostEqual(y, lens.f * 0.6 / 10, delta=1)


class LinkTracksTest(unittest.TestCase):
    def det(self, t, cx, cy, s, cls='traffic_light', value=None, dist=None):
        return {'id': int(t * 10), 't': t, 'cls': cls, 'value': value, 'x': cx - s / 2, 'y': cy - s / 2,
                'w': s, 'h': s, 'dist': dist if dist is not None else t * 10}

    def test_radial_motion_links_and_sideways_jump_does_not(self):
        fx, fy = objects.FOE
        # объект уходит от фокуса расширения вправо-вверх и растёт
        a = [self.det(0, fx + 100, fy - 60, 8), self.det(1, fx + 160, fy - 96, 12),
             self.det(2, fx + 280, fy - 168, 20)]
        b = [self.det(1, fx - 300, fy - 50, 12)]  # другой объект слева
        tracks = objects.link_tracks(a + b)
        sizes = sorted(len(t) for t in tracks)
        self.assertEqual(sizes, [1, 3])

    def test_different_value_signs_not_linked(self):
        fx, fy = objects.FOE
        tracks = objects.link_tracks([self.det(0, fx + 100, fy - 60, 10, 'speed_limit', 40),
                                      self.det(1, fx + 140, fy - 84, 14, 'speed_limit', 60)])
        self.assertEqual(len(tracks), 2)

    def test_standstill_long_gap_links(self):
        fx, fy = objects.FOE
        tracks = objects.link_tracks([self.det(0, fx + 200, fy - 100, 10, dist=0),
                                      self.det(10, fx + 201, fy - 100, 10, dist=1)])
        self.assertEqual(len(tracks), 1)


class ClusterTest(unittest.TestCase):
    def obj(self, i, trip, e, n, cls='traffic_light', value=None, conf=0.8, w=0.9, frames_n=3):
        lat, lon = at(e, n)
        return {'id': i, 'cls': cls, 'value': value, 'lat': lat, 'lon': lon, 'err_m': 5.0,
                'conf': conf, 'weight': w, 'n_frames': frames_n, 'trip_key': trip}

    def test_merge_within_12m_and_classes_apart(self):
        objs = [self.obj(1, 'A', 0, 0), self.obj(2, 'B', 8, 0), self.obj(3, 'C', 30, 0),
                self.obj(4, 'B', 0, 0, cls='crossing')]
        cl = cluster.cluster_objects(objs)
        self.assertEqual(len(cl), 3)
        big = max(cl, key=lambda c: len(c['members']))
        self.assertEqual(big['n_trips'], 2)
        self.assertGreater(big['confidence'], max(cluster.object_quality(o) for o in objs[:2]))

    def test_confidence_grows_with_trips(self):
        one = cluster.cluster_objects([self.obj(1, 'A', 0, 0, conf=0.5)])[0]['confidence']
        three = cluster.cluster_objects([self.obj(i, t, i, 0, conf=0.5)
                                         for i, t in enumerate('ABC')])[0]['confidence']
        self.assertGreater(three, one + 0.2)

    def test_compare_statuses(self):
        sig = cluster.PointIndex([at(0, 20), at(200, 0)])
        cr = cluster.PointIndex([])
        idx = {'traffic_signals': sig, 'crossing': cr}
        lat, lon = at(0, 0)
        self.assertEqual(cluster.compare({'cls': 'traffic_light', 'lat': lat, 'lon': lon}, idx, None)[0],
                         'confirms')
        lat, lon = at(150, 0)
        self.assertEqual(cluster.compare({'cls': 'traffic_light', 'lat': lat, 'lon': lon}, idx, None)[0],
                         'differs')
        lat, lon = at(500, 500)
        self.assertEqual(cluster.compare({'cls': 'crossing', 'lat': lat, 'lon': lon}, idx, None)[0], 'new')
        a, b = at(-100, 5), at(100, 5)
        seg = cluster.SegIndex([(a[0], a[1], b[0], b[1], 60)])
        lat, lon = at(0, 0)
        self.assertEqual(cluster.compare({'cls': 'speed_limit', 'value': 60, 'lat': lat, 'lon': lon},
                                         idx, seg)[0], 'confirms')
        self.assertEqual(cluster.compare({'cls': 'speed_limit', 'value': 40, 'lat': lat, 'lon': lon},
                                         idx, seg)[0], 'differs')
        lat, lon = at(0, 300)
        self.assertEqual(cluster.compare({'cls': 'speed_limit', 'value': 40, 'lat': lat, 'lon': lon},
                                         idx, seg)[0], 'new')

    def test_decision_follows_place_not_id(self):
        conn = catalog.connect(':memory:')
        lat, lon = at(0, 0)
        conn.execute("INSERT INTO clusters(id, cls, lat, lon) VALUES(7, 'crossing', ?, ?)", (lat, lon))
        self.assertTrue(cluster.decide(conn, 7, 'reject'))
        conn.execute('DELETE FROM clusters')
        lat2, lon2 = at(5, 3)
        self.assertEqual(cluster.decision_for(conn, 'crossing', lat2, lon2), 'reject')
        self.assertIsNone(cluster.decision_for(conn, 'traffic_light', lat2, lon2))
        lat3, lon3 = at(40, 0)
        self.assertIsNone(cluster.decision_for(conn, 'crossing', lat3, lon3))


class PrivacyTest(unittest.TestCase):
    def test_only_allowed_values_and_fields(self):
        ok = detect.sanitize({'cls': 'speed_limit', 'value': 60, 'x': 10, 'y': 10, 'w': 20, 'h': 20,
                              'conf': 0.9})
        self.assertEqual(ok['value'], 60)
        self.assertNotIn('text', ok)
        self.assertIsNone(detect.sanitize({'cls': 'speed_limit', 'value': 65, 'x': 1, 'y': 1, 'w': 1,
                                           'h': 1, 'conf': 1}))
        self.assertIsNone(detect.sanitize({'cls': 'plate', 'x': 1, 'y': 1, 'w': 1, 'h': 1, 'conf': 1}))
        self.assertIsNone(detect.sanitize({'cls': 'traffic_light', 'color': 'green', 'text': '01 A 123 BC',
                                           'x': 1, 'y': 1, 'w': 1, 'h': 1, 'conf': 1}))
        lt = detect.sanitize({'cls': 'traffic_light', 'color': 'red', 'value': 77, 'x': 1, 'y': 1,
                              'w': 1, 'h': 1, 'conf': 1})
        self.assertIsNone(lt['value'])

    def test_parse_output_skips_garbage(self):
        out = detect.parse_output('мусор\n{"f":"a.jpg","d":[{"cls":"crossing","x":1,"y":2,"w":3,"h":4,'
                                  '"conf":0.5}]}\n{"f":"b.jpg","err":"read"}\n')
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0][1][0]['cls'], 'crossing')
        self.assertEqual(out[1][2], 'read')


class EventsAndIdentifyTest(unittest.TestCase):
    def test_events_from_series(self):
        s = [(0, 0.1), (1, 0.7), (2, 0.8), (3, 0.2), (10, 0.9), (20, 0.65), (21, 0.7), (22, 0.66)]
        ev = selfcam.events_from_series(s)
        self.assertEqual([round(e[0], 1) for e in ev], [2.8, 22.8])
        self.assertEqual(ev[1][2], 3)

    def test_straight_cost_bounds(self):
        self.assertIsNone(anchorhmm.straight_cost(1000, 500))     # прямая длиннее пути — невозможно
        self.assertLess(anchorhmm.straight_cost(800, 1000), anchorhmm.straight_cost(300, 1000))

    def test_identify_on_unique_line(self):
        """Камеры по нерегулярной линии: расстояния между соседями разные, и цепочка
        событий с теми же расстояниями опознаётся однозначно."""
        xs = [0, 420, 1130, 1500, 2600, 3050]
        cams = [{'id': 100 + i, 'lat': at(x, 0)[0], 'lon': at(x, 0)[1], 'dir': 90} for i, x in enumerate(xs)]
        # приманки: те же расстояния далеко в стороне не повторяются
        cams += [{'id': 900 + i, 'lat': at(x, 5000)[0], 'lon': at(x, 5000)[1]} for i, x in
                 enumerate((0, 700, 1900))]
        conn = catalog.connect(':memory:')
        osrm = geo.OSRM(conn, fetch=FakeFetch(0), min_interval=0)
        speed = 10.0
        events = [(1000 + x / speed, 0.9) for x in xs[1:5]]   # камеры 1–4
        res = anchorhmm.identify(events, lambda t: t * speed, cams, osrm)
        self.assertEqual(res['status'], 'ok', res)
        self.assertEqual([cams[j]['id'] for _, j, _ in res['anchors']], [101, 102, 103, 104])

    def test_identify_refuses_too_few(self):
        res = anchorhmm.identify([(0, 1), (10, 1)], lambda t: t, [], None)
        self.assertEqual(res['status'], 'too_few_events')


if __name__ == '__main__':
    unittest.main()
