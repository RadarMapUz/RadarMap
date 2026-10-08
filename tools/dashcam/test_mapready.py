#!/usr/bin/env python3
"""Тесты отбора «готово к карте» и выгрузки (без файлов карты и сети)."""
import math
import unittest
import xml.etree.ElementTree as ET

import mapready

LAT0, LON0 = 41.31, 69.25
M_LAT = 1 / 111195.0
M_LON = 1 / (111195.0 * math.cos(math.radians(LAT0)))


def at(east_m, north_m=0.0):
    return LAT0 + north_m * M_LAT, LON0 + east_m * M_LON


def clus(**kw):
    lat, lon = at(kw.pop('east', 0.0))
    c = {'id': 1, 'cls': 'traffic_light', 'status': 'new', 'n_trips': 2, 'err_m': 8.0,
         'confidence': 0.9, 'lat': lat, 'lon': lon, 'n_frames': 10}
    c.update(kw)
    return c


class ReadyRulesTest(unittest.TestCase):
    def test_strong_new_light_is_ready(self):
        self.assertEqual(mapready.ready_reasons(clus(), gap_m=None), [])
        self.assertEqual(mapready.ready_reasons(clus(), gap_m=80.0), [])

    def test_each_threshold_blocks(self):
        cases = [clus(n_trips=1), clus(err_m=12.5), clus(err_m=None), clus(confidence=0.69),
                 clus(status='confirms'), clus(status='differs'), clus(cls='speed_limit'),
                 clus(cls='speed_bump')]
        for c in cases:
            self.assertTrue(mapready.ready_reasons(c, None), c)

    def test_boundaries_inclusive(self):
        c = clus(n_trips=mapready.MIN_TRIPS, err_m=mapready.MAX_ERR_M, confidence=mapready.MIN_CONFIDENCE)
        self.assertEqual(mapready.ready_reasons(c, mapready.MIN_GAP_EXISTING_M), [])

    def test_existing_object_close_blocks(self):
        self.assertTrue(mapready.ready_reasons(clus(), gap_m=mapready.MIN_GAP_EXISTING_M - 1))

    def test_rejected_by_human_blocks(self):
        self.assertTrue(mapready.ready_reasons(clus(), None, decision='reject'))
        self.assertEqual(mapready.ready_reasons(clus(), None, decision='accept'), [])


class MergeTest(unittest.TestCase):
    def test_duplicates_merge_into_most_confident(self):
        cs = [clus(id=1, confidence=0.8, east=0), clus(id=2, confidence=0.99, east=39),
              clus(id=3, confidence=0.9, east=200), clus(id=4, cls='crossing', east=5)]
        out = mapready.merge_ready(cs)
        self.assertEqual(sorted(c['id'] for c in out), [2, 3, 4])
        two = next(c for c in out if c['id'] == 2)
        self.assertEqual([m['id'] for m in two['merged']], [1])

    def test_far_apart_stay_separate(self):
        out = mapready.merge_ready([clus(id=1, east=0), clus(id=2, east=mapready.MERGE_READY_M + 5)])
        self.assertEqual(len(out), 2)


class OsmChangeTest(unittest.TestCase):
    def draft(self, snap='node', **props):
        p = {'highway': 'traffic_signals', 'source': 'dashcam', 'confidence': 0.9, 'trips': 2}
        p.update(props)
        return {'geom': [LON0, LAT0], 'props': p, 'dashcam': {'snap': snap}}

    def test_nodes_only_osm_tags_and_negative_ids(self):
        xml, n = mapready.osm_change([self.draft(crossing='traffic_signals'), self.draft(snap='road')])
        self.assertEqual(n, 2)
        root = ET.fromstring(xml)
        self.assertEqual(root.tag, 'osmChange')
        nodes = root.findall('./create/node')
        self.assertEqual([x.get('id') for x in nodes], ['-1', '-2'])
        tags = {t.get('k'): t.get('v') for t in nodes[0].findall('tag')}
        self.assertEqual(tags, {'highway': 'traffic_signals', 'crossing': 'traffic_signals'})
        self.assertAlmostEqual(float(nodes[0].get('lat')), LAT0)

    def test_ambiguous_and_off_road_not_exported(self):
        _, n = mapready.osm_change([self.draft(snap='ambiguous'), self.draft(snap='off_road')])
        self.assertEqual(n, 0)


class LimitsAlongTest(unittest.TestCase):
    def test_course_picks_own_carriageway(self):
        # улица на восток (60) и поперечная на север (40), обе в 10 м
        a, b = at(-50, 10), at(50, 10)
        c, d = at(10, -50), at(10, 50)
        segs = [(a[0], a[1], b[0], b[1], 60), (c[0], c[1], d[0], d[1], 40)]
        lat, lon = at(0, 0)
        self.assertEqual(mapready.limits_along(segs, lat, lon, 90)[0], 60)
        self.assertEqual(mapready.limits_along(segs, lat, lon, 270)[0], 60)   # обратный курс — та же ось
        self.assertEqual(mapready.limits_along(segs, lat, lon, 0)[0], 40)
        self.assertIsNone(mapready.limits_along(segs, lat, lon, 45))

    def test_circular_mean(self):
        self.assertAlmostEqual(mapready.circular_mean([350, 10]) % 360, 0, delta=1e-6)
        self.assertIsNone(mapready.circular_mean([]))


if __name__ == '__main__':
    unittest.main()
