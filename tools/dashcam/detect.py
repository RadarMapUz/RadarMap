"""Черновые детекторы на кадрах поездки: обёртка над Swift CLI detect.swift.

Сработки хранятся в таблице detections с рамкой в пикселях ИСХОДНОГО кадра
1920×1080 (кадр детекторов обрезан и уменьшен — см. frames.to_src).

Приватность: из всего текста на кадре сохраняется только число на знаке
ограничения и только из ряда 20…120. Любая другая строка (номер машины,
вывеска) в БД не попадает: Swift CLI её не выводит, а здесь стоит второй
замок — сработка с недопустимым значением или с текстом отбрасывается.
"""
import json
import os
import re
import subprocess
import tempfile

import catalog
import frames as fr

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT_SRC = os.path.join(HERE, 'detect.swift')
BIN = os.path.join(os.path.dirname(catalog.DB_PATH), 'bin', 'detect')
SWIFTC = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
MACOS_SDK = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
CHUNK = 400

CLASSES = ('speed_limit', 'traffic_light', 'crossing')
ALLOWED_LIMITS = frozenset((20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120))
COLORS = frozenset(('red', 'yellow', 'green'))
# Похоже на номер машины Узбекистана («01 A 123 BC», «01 123 ABC») — второй
# замок на случай, если в сработку когда-нибудь попадёт строка.
PLATE_RE = re.compile(r'\d{2}\s*[A-Z]?\s*\d{3}\s*[A-Z]{2,3}', re.I)


def ensure_binary():
    if os.path.exists(BIN) and os.path.getmtime(BIN) >= os.path.getmtime(SWIFT_SRC):
        return BIN
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    # Собираем рядом и подменяем файл целиком: перезапись подписанного бинарника
    # на месте macOS наказывает SIGKILL у всех, кто его сейчас запускает.
    subprocess.run([SWIFTC, '-O', '-sdk', MACOS_SDK, SWIFT_SRC, '-o', BIN + '.new'], check=True)
    os.replace(BIN + '.new', BIN)
    return BIN


def sanitize(d):
    """Сработка из CLI → безопасная запись или None. Только известные поля."""
    cls = d.get('cls')
    if cls not in CLASSES:
        return None
    for v in d.values():
        if isinstance(v, str) and PLATE_RE.search(v):
            return None
    value = d.get('value')
    if cls == 'speed_limit':
        if not isinstance(value, int) or value not in ALLOWED_LIMITS:
            return None
    else:
        value = None
    color = d.get('color') if cls == 'traffic_light' else None
    if cls == 'traffic_light' and color not in COLORS:
        return None
    try:
        x, y, w, h, conf = (float(d[k]) for k in ('x', 'y', 'w', 'h', 'conf'))
    except (KeyError, TypeError, ValueError):
        return None
    sx, sy = fr.to_src(x, y)
    return {'cls': cls, 'value': value, 'color': color, 'x': sx, 'y': sy,
            'w': w / fr.SCALE, 'h': h / fr.SCALE, 'conf': conf}


def parse_output(text):
    """Вывод CLI → [(путь кадра, [сработки])]."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            j = json.loads(line)
        except json.JSONDecodeError:
            continue
        if 'f' not in j:
            continue
        dets = [s for s in (sanitize(d) for d in j.get('d', [])) if s]
        signs = [s for s in (sanitize_sign(x) for x in j.get('s', [])) if s]
        out.append((j['f'], dets, j.get('err'), signs))
    return out


SIGN_DIR = os.path.join(os.path.dirname(catalog.DB_PATH), 'signs')
SIGN_SHAPES = frozenset(('red_circle', 'blue_circle', 'blue_square', 'red_triangle', 'red_inverted',
                         'red_octagon', 'yellow_diamond', 'name_plate', 'orange_cone'))


def sign_side(x_src, w_src):
    """Сторона дороги по положению в кадре: левая/правая треть или над дорогой."""
    cx = x_src + w_src / 2
    if cx < 0.4 * fr.SRC_W:
        return 'left'
    if cx > 0.6 * fr.SRC_W:
        return 'right'
    return 'over'


def sanitize_sign(s):
    if s.get('shape') not in SIGN_SHAPES:
        return None
    try:
        x, y, w, h, score = (float(s[k]) for k in ('x', 'y', 'w', 'h', 'score'))
    except (KeyError, TypeError, ValueError):
        return None
    sx, sy = fr.to_src(x, y)
    f = s.get('file')
    # Текст — только с табличек улиц/домов и никогда похожий на номер машины.
    text = s.get('text') if s['shape'] == 'name_plate' else None
    if not isinstance(text, str) or PLATE_RE.search(text) or len(text) > 80:
        text = None
    value = s.get('value') if s['shape'] == 'red_circle' else None
    if value not in ALLOWED_LIMITS:
        value = None
    return {'shape': s['shape'], 'x': sx, 'y': sy, 'w': w / fr.SCALE, 'h': h / fr.SCALE,
            'score': score, 'text': text, 'value': value,
            'file': f if isinstance(f, str) and f.startswith(SIGN_DIR) else None}


def run_frames(paths, binary=None):
    binary = binary or ensure_binary()
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        f.write('\n'.join(paths))
        lst = f.name
    try:
        env = dict(os.environ, SIGN_DIR=SIGN_DIR)
        text = subprocess.run([binary, 'detect', lst], capture_output=True, text=True,
                              check=True, env=env).stdout
    finally:
        os.remove(lst)
    return parse_output(text)


def detect_trip(conn, key, log=print):
    rows = conn.execute('SELECT id, path, t, lat, lon, course FROM frames WHERE trip_key=? AND detected=0 '
                        'ORDER BY t', (key,)).fetchall()
    if not rows:
        return 0
    binary = ensure_binary()
    by_path = {r['path']: r['id'] for r in rows}
    frame = {r['id']: r for r in rows}
    total = 0
    for i in range(0, len(rows), CHUNK):
        chunk = [r['path'] for r in rows[i:i + CHUNK] if os.path.exists(r['path'])]
        res = run_frames(chunk, binary)
        with conn:
            for path, dets, err, signs in res:
                fid = by_path.get(path)
                if fid is None:
                    continue
                conn.execute('DELETE FROM detections WHERE frame_id=?', (fid,))
                conn.executemany('INSERT INTO detections(frame_id, cls, value, color, x, y, w, h, conf) '
                                 'VALUES(?,?,?,?,?,?,?,?,?)',
                                 [(fid, d['cls'], d['value'], d['color'], d['x'], d['y'], d['w'], d['h'],
                                   d['conf']) for d in dets])
                # после сработок: число в красном круге добавит speed_limit, если его нет
                store_signs(conn, frame[fid], signs)
                conn.execute('UPDATE frames SET detected=? WHERE id=?', (2 if err else 1, fid))
                total += len(dets)
        # кадры, которых нет на диске, — тоже «разобраны», чтобы не крутиться
        missing = [r['id'] for r in rows[i:i + CHUNK] if not os.path.exists(r['path'])]
        if missing:
            with conn:
                conn.executemany('UPDATE frames SET detected=2 WHERE id=?', [(m,) for m in missing])
    return total


# Текст сначала (плитки с апскейлом): медленно (~0,45 с/кадр), поэтому каждый
# TEXT_EVERY-й кадр на ходу. Знак виден в 5–8 кадрах подхода — пропуск не страшен.
TEXT_EVERY = 5
# Кант вокруг цифр — только в уверенность: рамка числа от Vision смещена, и у
# половины настоящих знаков проверка канта промахивается. На 4 тыс. кадров все
# числа из ряда 20…120, найденные так, оказались знаками (в т. ч. «МАКТАБ 50»).
TEXT_MIN_RING = 0.0


def textscan_trip(conn, key, binary=None):
    """Знаки ограничения «текст сначала» → сработки speed_limit (если кольцевое
    сито их пропустило). Кадры отмечаются в text_done, повтор не читается."""
    conn.execute('CREATE TABLE IF NOT EXISTS text_done(frame_id INTEGER PRIMARY KEY)')
    rows = conn.execute('SELECT f.id, f.path FROM frames f LEFT JOIN text_done t ON t.frame_id=f.id '
                        'WHERE f.trip_key=? AND f.kmh>8 AND t.frame_id IS NULL ORDER BY f.t', (key,)).fetchall()
    rows = [r for i, r in enumerate(rows) if i % TEXT_EVERY == 0 and os.path.exists(r['path'])]
    if not rows:
        return 0
    binary = binary or ensure_binary()
    by_path = {r['path']: r['id'] for r in rows}
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        f.write('\n'.join(by_path))
        lst = f.name
    try:
        out = subprocess.run([binary, 'textscan', lst], capture_output=True, text=True, check=True).stdout
    finally:
        os.remove(lst)
    n = 0
    with conn:
        for line in out.splitlines():
            parts = line.split('\t')
            if len(parts) < 7 or parts[0] not in by_path:
                continue
            try:
                v, x, y, w, h, ring = int(parts[1]), *map(float, parts[2:7])
            except ValueError:
                continue
            if v not in ALLOWED_LIMITS or ring < TEXT_MIN_RING:
                continue
            fid = by_path[parts[0]]
            side = max(w, h) * 2.1
            cx, cy = x + w / 2, y + h / 2
            sx, sy = fr.to_src(cx - side / 2, cy - side / 2)
            s_src = side / fr.SCALE
            dup = conn.execute("SELECT 1 FROM detections WHERE frame_id=? AND cls='speed_limit' AND "
                               'abs(x + w / 2 - ?) < w AND abs(y + h / 2 - ?) < h',
                               (fid, sx + s_src / 2, sy + s_src / 2)).fetchone()
            if not dup:
                conn.execute("INSERT INTO detections(frame_id, cls, value, x, y, w, h, conf) "
                             "VALUES(?, 'speed_limit', ?, ?, ?, ?, ?, ?)",
                             (fid, v, sx, sy, s_src, s_src, 0.5 + 0.4 * ring))
                n += 1
        conn.executemany('INSERT OR IGNORE INTO text_done(frame_id) VALUES(?)', [(i,) for i in by_path.values()])
    return n


def store_signs(conn, f, signs):
    """Кандидаты знаков кадра → sign_crops; файл вырезки переименовывается в <id>.jpg."""
    for (p,) in conn.execute('SELECT path FROM sign_crops WHERE frame_id=?', (f['id'],)).fetchall():
        if p and os.path.exists(p):
            os.remove(p)
    conn.execute('DELETE FROM sign_crops WHERE frame_id=?', (f['id'],))
    for s in signs:
        cur = conn.execute('INSERT INTO sign_crops(frame_id, shape, x, y, w, h, score, t, lat, lon, course, '
                           'side, text, value) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                           (f['id'], s['shape'], s['x'], s['y'], s['w'], s['h'], s['score'], f['t'],
                            f['lat'], f['lon'], f['course'], sign_side(s['x'], s['w']), s.get('text'),
                            s.get('value')))
        # Число в красном круге — знак ограничения, даже если основной детектор
        # (кольцо → OCR) его пропустил: добавляем сработку speed_limit.
        if s.get('value'):
            cx, cy = s['x'] + s['w'] / 2, s['y'] + s['h'] / 2
            dup = conn.execute("SELECT 1 FROM detections WHERE frame_id=? AND cls='speed_limit' AND "
                               'abs(x + w / 2 - ?) < w AND abs(y + h / 2 - ?) < h', (f['id'], cx, cy)).fetchone()
            if not dup:
                conn.execute("INSERT INTO detections(frame_id, cls, value, x, y, w, h, conf) "
                             "VALUES(?, 'speed_limit', ?, ?, ?, ?, ?, ?)",
                             (f['id'], s['value'], s['x'], s['y'], s['w'], s['h'], 0.7))
        if s['file'] and os.path.exists(s['file']):
            dst = os.path.join(SIGN_DIR, s['shape'], f'{cur.lastrowid}.jpg')
            os.replace(s['file'], dst)
            conn.execute('UPDATE sign_crops SET path=? WHERE id=?', (dst, cur.lastrowid))


def make_crops(specs, binary=None):
    """specs: [{'src','dst','box':[x,y,w,h],'keep':[x,y,w,h]}] в пикселях кадра
    детекторов → вырезки с размытыми лицами и текстом вне keep."""
    if not specs:
        return 0
    binary = binary or ensure_binary()
    with tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False) as f:
        f.write('\n'.join(json.dumps(s) for s in specs))
        spec = f.name
    try:
        out = subprocess.run([binary, 'crop', spec], capture_output=True, text=True, check=True).stdout
    finally:
        os.remove(spec)
    return sum(1 for line in out.splitlines() if line.startswith('ok '))
