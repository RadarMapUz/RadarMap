#!/usr/bin/env python3
"""Локальная страница «Разбор видео»: поездки, карта с треком, видео с ползунком.

    python3 serve.py [--port 8780]   →   http://127.0.0.1:8780

Только 127.0.0.1: видео с номерами машин и лицами не должно быть видно даже
в локальной сети. Заголовок Host проверяется (защита от DNS rebinding),
POST принимается только как JSON со своего origin (простая форма с чужой
страницы не пройдёт). Файлы роликов отдаются по id из каталога — путь из
URL не берётся никогда, обходить каталоги нечем. Видео — с HTTP Range:
без него Safari и Chrome не перематывают.
"""
import argparse
import json
import os
import re
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import catalog
import overlay
import sync

HERE = os.path.dirname(os.path.abspath(__file__))
UI_DIR = os.path.join(HERE, 'ui')
UI_FILES = {'index.html': 'text/html; charset=utf-8',
            'app.js': 'text/javascript; charset=utf-8',
            'app.css': 'text/css; charset=utf-8'}
HOST = '127.0.0.1'
DEFAULT_PORT = 8780
CHUNK = 1 << 20
# Поле трека вокруг поездки: сдвиг часов ищется в ±120 с.
TRACK_MARGIN = 180

_jobs = {}
_jobs_lock = threading.Lock()


def parse_range(header, size):
    """Заголовок Range → (start, end) включительно; None — заголовка нет (весь файл);
    'invalid' — несатисфиабельный диапазон (416). Поддерживается один диапазон."""
    if not header:
        return None
    m = re.fullmatch(r'\s*bytes=(\d*)-(\d*)\s*', header)
    if not m or (not m.group(1) and not m.group(2)) or size == 0:
        return 'invalid'
    a, b = m.group(1), m.group(2)
    if not a:  # bytes=-N — последние N байт
        n = int(b)
        if n == 0:
            return 'invalid'
        return max(0, size - n), size - 1
    start = int(a)
    end = int(b) if b else size - 1
    if start >= size or end < start:
        return 'invalid'
    return start, min(end, size - 1)


def _r(x, nd):
    return None if x is None else round(x, nd)


def trip_detail(conn, key, track_id=None):
    trip = catalog.get_trip(conn, key)
    if trip is None:
        return None
    status = catalog.trip_status(conn, trip, track_id)
    clips = [{'id': c['id'], 'name': c['name'], 'start': c['start'], 'duration': c['duration']}
             for c in catalog.trip_clips(conn, key)]
    tr = catalog.track_for_trip(conn, trip, track_id)
    out = {**status, 'clips': clips, 'offset': 0.0, 'points': [], 'shape': [],
           'anchors': [], 'model': None}
    if tr is None:
        return out
    s = status['sync']
    offset = s['offset'] if s and s.get('offset') is not None else 0.0
    out['offset'] = offset
    if tr['kind'] == 'timed':
        pts = catalog.track_points(conn, tr['id'], trip['start'] + offset - TRACK_MARGIN,
                                   trip['end'] + offset + TRACK_MARGIN)
        out['model'] = 'timed'
        anchors = [{'t': w[0], 'lat': w[1], 'lon': w[2], 'name': w[3], 'used': None}
                   for w in catalog.track_waypoints(conn, tr['id'])]
    else:
        model = sync.anchored_model(conn, key, tr, offset)
        ocr = sync.clean_ocr(catalog.ocr_series(conn, key))
        pts = model.timed([t + offset for t, _ in ocr], [v for _, v in ocr])
        out['model'] = 'anchored'
        out['shape'] = [[_r(a, 6), _r(b, 6)] for a, b in model.line.pts]
        out['summary'] = model.summary()
        anchors = [{'t': a['t'], 'lat': a['lat'], 'lon': a['lon'], 'name': a['name'],
                    'used': a['used'], 'offset_m': _r(a['offset_m'], 1)} for a in model.anchors]
        # Невязка перегона — у опоры, которой он заканчивается.
        used = [i for i, a in enumerate(model.anchors) if a['used']]
        for k, r in enumerate(model.residuals()):
            anchors[used[k + 1]]['residual_m'] = _r(r, 1)
    out['points'] = [[_r(t, 2), _r(lat, 6), _r(lon, 6), _r(v, 1)] for t, lat, lon, v in pts]
    out['anchors'] = anchors
    return out


def run_job(key):
    """OCR поездки и синхронизация со всеми её треками — в фоне."""
    conn = catalog.connect()
    try:
        def progress(done, total):
            with _jobs_lock:
                _jobs[key].update(done=done, total=total)
        overlay.ocr_trip(conn, key, progress, log=lambda *_: None)
        with _jobs_lock:
            _jobs[key]['state'] = 'sync'
        trip = catalog.get_trip(conn, key)
        for tr in catalog.tracks_for_trip(conn, trip):
            sync.sync_trip(conn, key, tr['id'])
        with _jobs_lock:
            _jobs[key]['state'] = 'done'
    except Exception as e:  # ошибку показываем в списке, а не глотаем
        traceback.print_exc()
        with _jobs_lock:
            _jobs[key].update(state='error', error=str(e))
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    server_version = 'dashcam/1'

    def log_message(self, fmt, *args):
        if os.environ.get('DASHCAM_LOG'):
            super().log_message(fmt, *args)

    # ---- проверки ----
    def _host_ok(self):
        port = self.server.server_address[1]
        return self.headers.get('Host') in (f'127.0.0.1:{port}', f'localhost:{port}')

    def _origin_ok(self):
        origin = self.headers.get('Origin')
        if origin is None:
            return True
        port = self.server.server_address[1]
        return origin in (f'http://127.0.0.1:{port}', f'http://localhost:{port}')

    # ---- ответы ----
    def _send(self, code, body=b'', ctype='application/json; charset=utf-8', extra=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode('utf-8'))

    def _error(self, code, msg):
        self._json({'error': msg}, code)

    def _conn(self):
        return catalog.connect(self.server.db_path)

    # ---- маршруты ----
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self._host_ok():
            return self._error(403, 'чужой Host')
        url = urlparse(self.path)
        p = url.path
        try:
            if p == '/':
                return self._static('index.html')
            if p.startswith('/ui/'):
                return self._static(p[4:])
            if p == '/api/trips':
                conn = self._conn()
                try:
                    trips = catalog.trips(conn)
                finally:
                    conn.close()
                with _jobs_lock:
                    for t in trips:
                        t['job'] = _jobs.get(t['key'])
                return self._json(trips)
            m = re.fullmatch(r'/api/trips/([0-9-]+)', p)
            if m:
                q = parse_qs(url.query)
                track = int(q['track'][0]) if q.get('track', [''])[0].isdigit() else None
                conn = self._conn()
                try:
                    d = trip_detail(conn, m.group(1), track)
                finally:
                    conn.close()
                return self._json(d) if d else self._error(404, 'нет такой поездки')
            m = re.fullmatch(r'/video/(\d+)', p)
            if m:
                return self._video(int(m.group(1)))
            return self._error(404, 'не найдено')
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        if not self._host_ok() or not self._origin_ok():
            return self._error(403, 'чужой Host или Origin')
        if not (self.headers.get('Content-Type') or '').startswith('application/json'):
            return self._error(415, 'нужен JSON')
        try:
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(min(n, 1 << 16)) or b'{}')
        except (ValueError, json.JSONDecodeError):
            return self._error(400, 'плохой JSON')
        p = urlparse(self.path).path
        if p == '/api/import':
            path = os.path.expanduser(str(body.get('path', '')).strip())
            if not path or not os.path.exists(path):
                return self._error(400, f'нет такой папки или файла: {path}')
            conn = self._conn()
            try:
                clips, tracks = catalog.import_paths(conn, [path], log=lambda *_: None)
            except Exception as e:
                return self._error(400, f'импорт не удался: {e}')
            finally:
                conn.close()
            return self._json({'clips': clips, 'tracks': tracks})
        m = re.fullmatch(r'/api/trips/([0-9-]+)/process', p)
        if m:
            key = m.group(1)
            conn = self._conn()
            try:
                if catalog.get_trip(conn, key) is None:
                    return self._error(404, 'нет такой поездки')
            finally:
                conn.close()
            with _jobs_lock:
                job = _jobs.get(key)
                if job and job['state'] in ('ocr', 'sync'):
                    return self._json(job)
                _jobs[key] = {'state': 'ocr', 'done': 0, 'total': 0, 'error': None}
            threading.Thread(target=run_job, args=(key,), daemon=True).start()
            return self._json(_jobs[key])
        return self._error(404, 'не найдено')

    def _static(self, name):
        if name not in UI_FILES:
            return self._error(404, 'не найдено')
        with open(os.path.join(UI_DIR, name), 'rb') as f:
            self._send(200, f.read(), UI_FILES[name])

    def _video(self, clip_id):
        conn = self._conn()
        try:
            row = conn.execute('SELECT path FROM clips WHERE id=?', (clip_id,)).fetchone()
        finally:
            conn.close()
        if row is None or not os.path.isfile(row['path']):
            return self._error(404, 'нет такого ролика')
        size = os.path.getsize(row['path'])
        rng = parse_range(self.headers.get('Range'), size)
        if rng == 'invalid':
            return self._send(416, extra={'Content-Range': f'bytes */{size}'})
        start, end = rng if rng else (0, size - 1)
        length = end - start + 1
        self.send_response(206 if rng else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(length))
        if rng:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        if self.command == 'HEAD':
            return
        with open(row['path'], 'rb') as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(CHUNK, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)


def make_server(port=DEFAULT_PORT, db_path=None):
    srv = ThreadingHTTPServer((HOST, port), Handler)
    srv.daemon_threads = True
    srv.db_path = db_path or catalog.DB_PATH
    return srv


def main(argv=None):
    ap = argparse.ArgumentParser(description='Локальная страница «Разбор видео»')
    ap.add_argument('--port', type=int, default=DEFAULT_PORT)
    a = ap.parse_args(argv)
    srv = make_server(a.port)
    print(f'Разбор видео: http://{HOST}:{a.port}  (каталог {srv.db_path})')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    sys.exit(main())
