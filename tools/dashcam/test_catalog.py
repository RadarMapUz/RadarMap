#!/usr/bin/env python3
"""Тесты каталога: время из имени ролика, поездки по разрыву ≤ 5 мин, импорт
роликов и GPX (оба вида трека), выбор трека по умолчанию — настоящий, не
синтетика; разбор полосы кадра (overlay) и синтетический GPX."""
import os
import shutil
import tempfile
import unittest
from datetime import datetime, timezone

import catalog
import gpx
import overlay
import synth_gpx


def ts(s):
    return datetime.strptime(s, '%Y-%m-%d %H:%M:%S').replace(tzinfo=catalog.DASHCAM_TZ).timestamp()


class CatalogPureTest(unittest.TestCase):
    def test_clip_name_is_tashkent_local_start(self):
        t = catalog.parse_clip_name('/x/2026-10-07-08-05-24.mp4')
        self.assertEqual(datetime.fromtimestamp(t, timezone.utc).strftime('%H:%M:%S'), '03:05:24')
        self.assertIsNone(catalog.parse_clip_name('IMG_0001.mp4'))
        self.assertIsNone(catalog.parse_clip_name('2026-13-40-08-05-24.mp4'))

    def test_initial_start_trusts_creation_only_if_consistent(self):
        name = ts('2026-10-07 08:05:10')
        end = ts('2026-10-07 08:07:11')  # creation_time — конец ролика
        self.assertAlmostEqual(catalog.initial_start(name, 120.0, end), name + 1.0)
        self.assertEqual(catalog.initial_start(name, 120.0, end + 3600), name)
        self.assertEqual(catalog.initial_start(name, 120.0, None), name)

    def test_group_trips_by_five_minute_gap(self):
        clips = [(1, 0, 120), (2, 120, 120), (3, 240 + 299, 120),   # разрыв 299 с — та же
                 (4, 659 + 301, 120), (5, 5000, 60)]                  # 301 с — новая
        self.assertEqual(catalog.group_trips(clips), [[1, 2, 3], [4], [5]])
        self.assertEqual(catalog.group_trips([]), [])


class CatalogImportTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.conn = catalog.connect(os.path.join(self.dir, 'db.sqlite'))
        self.videos = os.path.join(self.dir, 'v')
        os.makedirs(self.videos)
        for name in ['2026-10-07-08-05-10.mp4', '2026-10-07-08-07-11.mp4',
                     '2026-10-07-19-21-07.mp4', 'notes.txt']:
            with open(os.path.join(self.videos, name), 'wb') as f:
                f.write(b'x' * 10)

    def tearDown(self):
        self.conn.close()
        shutil.rmtree(self.dir)

    @staticmethod
    def fake_probe(path):
        return {'duration': 120.0, 'end': None, 'width': 1920, 'height': 1080}

    def test_import_is_idempotent_and_groups(self):
        self.assertEqual(catalog.import_paths(self.conn, [self.videos], self.fake_probe), (3, 0))
        self.assertEqual(catalog.import_paths(self.conn, [self.videos], self.fake_probe), (0, 0))
        trips = catalog.trips(self.conn)
        self.assertEqual([t['clips'] for t in trips], [1, 2])  # новые сверху
        self.assertEqual(trips[1]['key'], '2026-10-07-08-05-10')
        self.assertEqual(trips[1]['stage'], 'no_gpx')

    def write_anchored(self, path):
        with open(path, 'w') as f:
            f.write('<?xml version="1.0"?><gpx creator="RadarMap" xmlns="http://www.topografix.com/GPX/1/1">'
                    '<wpt lat="41.335" lon="69.221"><time>2026-10-07T03:06:00Z</time>'
                    '<name>камера 1, 24 км/ч</name></wpt>'
                    '<trk><name>старая</name><trkseg>'
                    '<trkpt lat="41.333" lon="69.217"><extensions><speed>3.8</speed></extensions></trkpt>'
                    '<trkpt lat="41.336" lon="69.222"><extensions><speed>4.9</speed></extensions></trkpt>'
                    '</trkseg></trk></gpx>')

    def test_tracks_real_preferred_over_synthetic(self):
        catalog.import_paths(self.conn, [self.videos], self.fake_probe)
        synth = os.path.join(self.dir, 'synth.gpx')
        t0 = ts('2026-10-07 08:05:10')
        gpx.write(synth, 'синт', [(t0 + i, 41.3 + i * 1e-5, 69.2, 30.0) for i in range(240)],
                  synthetic=True)
        real = os.path.join(self.dir, 'real.gpx')
        self.write_anchored(real)
        self.assertEqual(catalog.import_paths(self.conn, [synth, real], self.fake_probe,
                                              log=lambda *_: None), (0, 2))
        trip = catalog.trips(self.conn)[1]
        self.assertEqual(trip['track']['kind'], 'anchored')
        self.assertFalse(trip['track']['synthetic'])
        self.assertEqual(len(trip['tracks']), 2)
        self.assertEqual(trip['stage'], 'ocr')
        tid = trip['track']['id']
        self.assertEqual(len(catalog.track_shape(self.conn, tid)), 2)
        self.assertEqual(catalog.track_waypoints(self.conn, tid)[0][3], 'камера 1, 24 км/ч')
        # синтетику можно выбрать явно
        other = [t for t in trip['tracks'] if t['synthetic']][0]
        st = catalog.trip_status(self.conn, catalog.get_trip(self.conn, trip['key']), other['id'])
        self.assertTrue(st['track']['synthetic'])

    def test_gpx_roundtrip_timed(self):
        p = os.path.join(self.dir, 't.gpx')
        pts = [(1000.5, 41.3, 69.2, 36.0), (1001.5, 41.3001, 69.2, 40.0)]
        gpx.write(p, 'имя', pts, waypoints=[(1000.0, 41.3, 69.2, 'камера <1>')])
        g = gpx.parse(p)
        self.assertEqual(g['kind'], 'timed')
        self.assertEqual(g['name'], 'имя')
        self.assertAlmostEqual(g['points'][0][0], 1000.5)
        self.assertAlmostEqual(g['points'][1][3], 40.0, places=1)
        self.assertEqual(g['waypoints'][0][3], 'камера <1>')

    def test_gpx_without_anything_is_rejected(self):
        p = os.path.join(self.dir, 'empty.gpx')
        with open(p, 'w') as f:
            f.write('<gpx><trk><trkseg><trkpt lat="1" lon="2"/></trkseg></trk></gpx>')
        with self.assertRaises(ValueError):
            catalog.import_gpx(self.conn, p)


class OverlayTest(unittest.TestCase):
    def test_parse_bar_csv(self):
        rows = overlay.parse_bar_csv('file,time,speed\n00001.png,2026-10-07 08:05:11,0\n'
                                     '00002.png,,\n00003.png,2026-10-07 08:05:13,12\nx.png,,\n')
        self.assertEqual([r[0] for r in rows], [0, 1, 2])
        self.assertEqual(rows[0][1], ts('2026-10-07 08:05:11'))
        self.assertEqual((rows[1][1], rows[1][2]), (None, None))
        self.assertEqual(rows[2][2], 12.0)

    def test_refine_start_median_and_misreads(self):
        start = ts('2026-10-07 08:05:11')
        rows = [(t, start + t, 10.0) for t in range(60)]
        rows[5] = (5, start + 3600, 10.0)  # misread часов — отбрасывается
        self.assertAlmostEqual(overlay.refine_start(rows, start - 1.0), start + 0.5)
        self.assertEqual(overlay.refine_start(rows[:3], start - 1.0), start - 1.0)


class SynthTest(unittest.TestCase):
    def test_synthesize_shift_and_shape(self):
        speed = [(1000.0 + i, 0.0 if i < 10 else 36.0) for i in range(100)]
        shape = [(41.30, 69.20), (41.30, 69.21)]
        pts = synth_gpx.synthesize(speed, shape, shift=7, noise_kmh=0)
        self.assertEqual(pts[0][0], 1000.0 + 0.5 + 7)
        self.assertAlmostEqual(pts[0][2], 69.20, places=6)
        self.assertAlmostEqual(pts[-1][2], 69.21, places=6)  # путь растянут на всю форму
        lons = [p[2] for p in pts]
        self.assertEqual(lons, sorted(lons))


if __name__ == '__main__':
    unittest.main()
