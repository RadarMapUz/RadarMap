#!/usr/bin/env python3
"""Тесты локальной страницы: Range для видео (206/416), ролик только по id
из каталога (никаких путей из URL), чужой Host и POST не-JSON отвергаются,
API поездки отдаёт трек, опоры и сдвиг. Сервер поднимается на свободном
порту с временным каталогом — настоящий каталог не трогается."""
import http.client
import json
import os
import shutil
import tempfile
import threading
import unittest

import catalog
import gpx
import serve


class RangeTest(unittest.TestCase):
    def test_parse_range(self):
        self.assertIsNone(serve.parse_range(None, 100))
        self.assertEqual(serve.parse_range('bytes=0-', 100), (0, 99))
        self.assertEqual(serve.parse_range('bytes=10-19', 100), (10, 19))
        self.assertEqual(serve.parse_range('bytes=90-500', 100), (90, 99))
        self.assertEqual(serve.parse_range('bytes=-10', 100), (90, 99))
        self.assertEqual(serve.parse_range('bytes=-500', 100), (0, 99))
        for bad in ('bytes=100-', 'bytes=20-10', 'bytes=-0', 'bytes=-', 'items=0-1', 'bytes=0-1,5-6'):
            self.assertEqual(serve.parse_range(bad, 100), 'invalid', bad)


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.db = os.path.join(cls.dir, 'db.sqlite')
        conn = catalog.connect(cls.db)
        cls.video = os.path.join(cls.dir, '2026-10-07-08-05-10.mp4')
        cls.blob = bytes(range(256)) * 40
        with open(cls.video, 'wb') as f:
            f.write(cls.blob)
        t0 = catalog.parse_clip_name(cls.video)
        g = os.path.join(cls.dir, 't.gpx')
        gpx.write(g, 'трек', [(t0 + i, 41.30 + i * 1e-4, 69.25, 36.0) for i in range(120)],
                  waypoints=[(t0 + 60, 41.306, 69.25, 'камера 7, 36 км/ч')])
        catalog.import_paths(conn, [cls.video, g],
                             lambda p: {'duration': 120.0, 'end': None, 'width': 1920, 'height': 1080},
                             log=lambda *_: None)
        conn.close()
        cls.srv = serve.make_server(0, cls.db)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()
        shutil.rmtree(cls.dir)

    def req(self, method, path, headers=None, body=None):
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        h = {'Host': f'127.0.0.1:{self.port}', **(headers or {})}
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r, data

    def test_bound_to_localhost_only(self):
        self.assertEqual(self.srv.server_address[0], '127.0.0.1')

    def test_trips_and_detail(self):
        r, data = self.req('GET', '/api/trips')
        self.assertEqual(r.status, 200)
        trips = json.loads(data)
        self.assertEqual(len(trips), 1)
        key = trips[0]['key']
        r, data = self.req('GET', f'/api/trips/{key}')
        d = json.loads(data)
        self.assertEqual(d['model'], 'timed')
        self.assertEqual(len(d['points']), 120)
        self.assertEqual(d['anchors'][0]['name'], 'камера 7, 36 км/ч')
        self.assertEqual(d['clips'][0]['duration'], 120.0)
        self.assertEqual(self.req('GET', '/api/trips/1999-01-01')[0].status, 404)

    def test_video_range_206(self):
        r, data = self.req('GET', '/video/1', {'Range': 'bytes=100-199'})
        self.assertEqual(r.status, 206)
        self.assertEqual(r.getheader('Content-Range'), f'bytes 100-199/{len(self.blob)}')
        self.assertEqual(r.getheader('Accept-Ranges'), 'bytes')
        self.assertEqual(data, self.blob[100:200])
        r, data = self.req('GET', '/video/1')
        self.assertEqual((r.status, data), (200, self.blob))
        r, _ = self.req('GET', '/video/1', {'Range': f'bytes={len(self.blob)}-'})
        self.assertEqual(r.status, 416)

    def test_no_paths_from_url(self):
        for p in ('/video/../../etc/passwd', '/video/%2e%2e%2fetc', '/video/999',
                  '/ui/../serve.py', '/ui/serve.py', '/ui/%2e%2e/catalog.py'):
            self.assertEqual(self.req('GET', p)[0].status, 404, p)

    def test_foreign_host_rejected(self):
        r, _ = self.req('GET', '/api/trips', {'Host': 'evil.example:8780'})
        self.assertEqual(r.status, 403)

    def test_post_requires_json_and_own_origin(self):
        r, _ = self.req('POST', '/api/import', {'Content-Type': 'application/x-www-form-urlencoded'},
                        'path=/tmp')
        self.assertEqual(r.status, 415)
        r, _ = self.req('POST', '/api/import', {'Content-Type': 'application/json',
                                                'Origin': 'http://evil.example'}, '{"path": "/tmp"}')
        self.assertEqual(r.status, 403)
        r, data = self.req('POST', '/api/import', {'Content-Type': 'application/json'},
                           json.dumps({'path': os.path.join(self.dir, 'нет')}))
        self.assertEqual(r.status, 400)

    def test_index_served(self):
        r, data = self.req('GET', '/')
        self.assertEqual(r.status, 200)
        self.assertIn('Разбор видео', data.decode('utf-8'))


if __name__ == '__main__':
    unittest.main()
