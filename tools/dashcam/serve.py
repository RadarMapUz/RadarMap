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
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import catalog
import overlay
import sync

HERE = os.path.dirname(os.path.abspath(__file__))
UI_DIR = os.path.join(HERE, 'ui')
UI_FILES = {'index.html': 'text/html; charset=utf-8',
            'finds.js': 'text/javascript; charset=utf-8',
            'signs.js': 'text/javascript; charset=utf-8',
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


# ---------- находки и разметка ----------

def _num(q, k, default=None):
    try:
        return float(q[k][0])
    except (KeyError, ValueError, IndexError):
        return default


def findings_list(conn, q):
    import cluster
    sql = 'SELECT * FROM clusters WHERE confidence >= ?'
    args = [_num(q, 'min_conf', 0.0)]
    if q.get('cls', [''])[0]:
        sql += ' AND cls=?'
        args.append(q['cls'][0])
    if q.get('status', [''])[0]:
        sql += ' AND status=?'
        args.append(q['status'][0])
    rows = conn.execute(sql + ' ORDER BY confidence DESC', args).fetchall()
    want = q.get('decision', [''])[0]
    out = []
    for r in rows:
        dec = cluster.decision_for(conn, r['cls'], r['lat'], r['lon'])
        if want == 'none' and dec is not None or want in ('accept', 'reject') and dec != want:
            continue
        out.append({'id': r['id'], 'cls': r['cls'], 'value': r['value'], 'lat': round(r['lat'], 7),
                    'lon': round(r['lon'], 7), 'err_m': _r(r['err_m'], 1), 'n_trips': r['n_trips'],
                    'n_frames': r['n_frames'], 'confidence': _r(r['confidence'], 3),
                    'status': r['status'], 'decision': dec})
    return out


def finding_detail(conn, cid):
    import cluster
    r = conn.execute('SELECT * FROM clusters WHERE id=?', (cid,)).fetchone()
    if r is None:
        return None
    objs = conn.execute('SELECT * FROM objects WHERE cluster=? ORDER BY weight DESC', (cid,)).fetchall()
    rays = []
    for o in objs:
        for d in conn.execute('SELECT f.lat, f.lon FROM detections d JOIN frames f ON f.id=d.frame_id '
                              'WHERE d.obj=? AND f.lat IS NOT NULL', (o['id'],)):
            rays.append([round(d['lat'], 7), round(d['lon'], 7)])
    crops = [{'det_id': d['id'], 'trip': d['trip_key'], 't': d['t'], 'conf': _r(d['conf'], 2),
              'url': f"/crop/{d['id']}.jpg"} for d in cluster.best_detections(conn, cid)]
    return {'id': r['id'], 'cls': r['cls'], 'value': r['value'], 'lat': r['lat'], 'lon': r['lon'],
            'err_m': _r(r['err_m'], 1), 'n_trips': r['n_trips'], 'n_frames': r['n_frames'],
            'confidence': _r(r['confidence'], 3), 'status': r['status'],
            'map_ref': json.loads(r['map_ref'] or '{}'),
            'decision': cluster.decision_for(conn, r['cls'], r['lat'], r['lon']),
            'objects': [{'trip': o['trip_key'], 'method': o['method'], 'err_m': _r(o['err_m'], 1),
                         'n_frames': o['n_frames'], 'weight': _r(o['weight'], 2)} for o in objs],
            'rays': rays, 'crops': crops}


def label_next(conn, cls=None):
    """Следующая сработка без ответа: по очереди классов, внутри — случайно
    (подряд идущие кадры одного светофора разметчику не нужны)."""
    sql = ('SELECT d.id, d.cls, d.value, d.color, d.conf FROM detections d '
           'LEFT JOIN labels l ON l.det_id=d.id WHERE l.det_id IS NULL')
    args = []
    if cls:
        sql += ' AND d.cls=?'
        args.append(cls)
    r = conn.execute(sql + ' ORDER BY random() LIMIT 1', args).fetchone()
    if r is None:
        return {'done': True}
    return {'det_id': r['id'], 'cls': r['cls'], 'value': r['value'], 'color': r['color'],
            'conf': _r(r['conf'], 2), 'url': f"/crop/{r['id']}.jpg"}


def label_stats(conn):
    out = {}
    for r in conn.execute('SELECT d.cls, l.answer, COUNT(*) n FROM labels l JOIN detections d '
                          'ON d.id=l.det_id GROUP BY d.cls, l.answer'):
        out.setdefault(r['cls'], {})[r['answer']] = r['n']
    for r in conn.execute('SELECT cls, COUNT(*) n FROM detections GROUP BY cls'):
        out.setdefault(r['cls'], {})['total'] = r['n']
    return out


def sign_clusters(conn, shape=None, show_all=False):
    sql = 'SELECT * FROM sign_clusters'
    cond, args = [], []
    if shape:
        cond.append('shape=?')
        args.append(shape)
    if not show_all:
        cond.append('label IS NULL')
    if cond:
        sql += ' WHERE ' + ' AND '.join(cond)
    out = []
    for r in conn.execute(sql + ' ORDER BY size DESC', args):
        reps = json.loads(r['reps'] or '[]')
        out.append({'id': r['id'], 'shape': r['shape'], 'size': r['size'], 'label': r['label'],
                    'reps': [{'id': i, 'url': f'/sign/{i}.jpg'} for i in reps]})
    return out


def coverage_cells(conn):
    import coverage
    coverage.connect(conn)
    return [{'lat': round(r['lat'], 6), 'lon': round(r['lon'], 6), 'course': r['course'],
             'passes': r['passes'], 'days': r['days'], 'pinned': bool(r['pinned'])}
            for r in conn.execute('SELECT * FROM coverage')]


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
            if p == '/api/findings':
                return self._with_conn(lambda c: findings_list(c, parse_qs(url.query)))
            m = re.fullmatch(r'/api/findings/(\d+)', p)
            if m:
                return self._with_conn(lambda c: finding_detail(c, int(m.group(1))), notfound=True)
            if p == '/api/signs/clusters':
                q = parse_qs(url.query)
                return self._with_conn(lambda c: sign_clusters(c, q.get('shape', [''])[0] or None,
                                                               q.get('all', ['0'])[0] == '1'))
            if p == '/api/signs/labels':
                import signs
                return self._json([{'key': k, 'name': n} for k, n in signs.LABELS])
            if p == '/api/coverage':
                return self._with_conn(coverage_cells)
            m = re.fullmatch(r'/sign/(\d+)\.jpg', p)
            if m:
                return self._sign_crop(int(m.group(1)))
            if p == '/api/label/next':
                q = parse_qs(url.query)
                return self._with_conn(lambda c: label_next(c, q.get('cls', [''])[0] or None))
            if p == '/api/label/stats':
                return self._with_conn(label_stats)
            m = re.fullmatch(r'/crop/(\d+)\.jpg', p)
            if m:
                return self._crop(int(m.group(1)))
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
        m = re.fullmatch(r'/api/findings/(\d+)/decision', p)
        if m:
            dec = body.get('decision')
            if dec not in ('accept', 'reject', 'clear'):
                return self._error(400, 'decision: accept | reject | clear')
            import cluster
            conn = self._conn()
            try:
                ok = cluster.decide(conn, int(m.group(1)), dec)
            finally:
                conn.close()
            return self._json({'ok': ok}) if ok else self._error(404, 'нет такой находки')
        m = re.fullmatch(r'/api/signs/clusters/(\d+)/(label|split)', p)
        if m:
            import signs
            conn = self._conn()
            try:
                if m.group(2) == 'split':
                    n = signs.split(conn, int(m.group(1)))
                else:
                    lab = body.get('label')
                    if lab not in signs.LABEL_KEYS:
                        return self._error(400, 'неизвестный класс знака')
                    val = body.get('value')
                    if lab == 'speed_limit' and val not in (20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120):
                        return self._error(400, 'для ограничения нужно число 20…120')
                    n = signs.label_cluster(conn, int(m.group(1)), lab, val)
            finally:
                conn.close()
            return self._json({'ok': True, 'n': n})
        if p == '/api/label':
            ans = body.get('answer')
            det = body.get('det_id')
            if ans not in ('yes', 'no', 'skip') or not isinstance(det, int):
                return self._error(400, 'нужны det_id и answer: yes | no | skip')
            conn = self._conn()
            try:
                with conn:
                    conn.execute('INSERT OR REPLACE INTO labels(det_id, answer, at) VALUES(?,?,?)',
                                 (det, ans, time.time()))
            finally:
                conn.close()
            return self._json({'ok': True})
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

    def _with_conn(self, fn, notfound=False):
        conn = self._conn()
        try:
            res = fn(conn)
        finally:
            conn.close()
        if notfound and res is None:
            return self._error(404, 'не найдено')
        return self._json(res)

    def _crop(self, det_id):
        """Вырезка сработки (лица и номера размыты) — по id, путь из URL не берётся."""
        import cluster
        conn = self._conn()
        try:
            path = cluster.crop_for(conn, det_id)
        finally:
            conn.close()
        if not path or not os.path.isfile(path):
            return self._error(404, 'нет вырезки')
        with open(path, 'rb') as f:
            self._send(200, f.read(), 'image/jpeg')

    def _sign_crop(self, crop_id):
        conn = self._conn()
        try:
            r = conn.execute('SELECT path FROM sign_crops WHERE id=?', (crop_id,)).fetchone()
        finally:
            conn.close()
        if r is None or not r['path'] or not os.path.isfile(r['path']):
            return self._error(404, 'нет вырезки')
        with open(r['path'], 'rb') as f:
            self._send(200, f.read(), 'image/jpeg')

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
        if row is not None and row['path'].startswith(CARD_PREFIX):
            return self._card_video(row['path'][len(CARD_PREFIX):])
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


CARD_PREFIX = 'card:'
CARD_DEVICE = os.environ.get('DASHCAM_CARD', '/dev/disk12s1')
_card = {'fs': None, 'index': None, 'chains': {}}
_card_lock = threading.Lock()


def card_file(path):
    """Ролик на карте регистратора (читаем FAT32 напрямую, только чтение) →
    (fs, кластер, размер, цепочка) или None — карты нет / файла нет."""
    import fat32
    with _card_lock:
        if _card['fs'] is None:
            try:
                fs = fat32.FAT32(CARD_DEVICE)
            except OSError:
                return None
            _card['fs'] = fs
            _card['index'] = {p: (cl, size) for p, isdir, cl, size, _ in fs.walk() if not isdir}
        hit = _card['index'].get(path)
        if hit is None:
            return None
        cl, size = hit
        if path not in _card['chains']:
            _card['chains'][path] = _card['fs'].chain(cl)
        return _card['fs'], cl, size, _card['chains'][path]


def _card_video_impl(handler, path):
    hit = card_file(path)
    if hit is None:
        return handler._error(404, 'ролика нет: карта регистратора не вставлена')
    fs, cl, size, chain = hit
    rng = parse_range(handler.headers.get('Range'), size)
    if rng == 'invalid':
        return handler._send(416, extra={'Content-Range': f'bytes */{size}'})
    start, end = rng if rng else (0, size - 1)
    length = end - start + 1
    handler.send_response(206 if rng else 200)
    handler.send_header('Content-Type', 'video/mp4')
    handler.send_header('Accept-Ranges', 'bytes')
    handler.send_header('Content-Length', str(length))
    if rng:
        handler.send_header('Content-Range', f'bytes {start}-{end}/{size}')
    handler.end_headers()
    if handler.command == 'HEAD':
        return
    pos = start
    while pos <= end:
        n = min(CHUNK, end - pos + 1)
        with _card_lock:
            chunk = fs.read_file(cl, size, pos, n, chain)
        if not chunk:
            break
        handler.wfile.write(chunk)
        pos += len(chunk)


Handler._card_video = lambda self, path: _card_video_impl(self, path)


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
