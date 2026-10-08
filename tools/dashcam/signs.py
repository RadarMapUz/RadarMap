#!/usr/bin/env python3
"""Кластеры вырезок знаков для подписи владельцем, обучающая выборка и классификатор.

    python3 signs.py cluster            — пересобрать кластеры по каждой форме
    python3 signs.py split CLUSTER_ID   — разбить кластер на 4
    python3 signs.py export DIR         — подписанные вырезки → DIR/<класс>/ (для Create ML)
    python3 signs.py fix [FILE]         — правки подписей после проверки глазами → sign_label_fix
    python3 signs.py purity             — чистота подписей по классам (по правкам)
    python3 signs.py train              — обучение (деление по поездкам) → models/signs.mlmodel
    python3 signs.py classify [--all]   — классификатор по вырезкам → sign_pred

Подпись ставится на вырезки (sign_crops.label), а не на кластер: кластеры
пересобираются, подпись остаётся. Уже подписанные вырезки в новые кластеры
не попадают — человеку показывается только неподписанное.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

import catalog

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.dirname(catalog.DB_PATH)
SWIFT_SRC = os.path.join(HERE, 'signcluster.swift')
BIN = os.path.join(BASE, 'bin', 'signcluster')
SWIFTC = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
MACOS_SDK = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
PER_CLUSTER = 25          # средний размер кластера — столько вырезок человек «подписывает разом»
MAX_K = 80

# Классы для подписи (ключ → подпись на странице).
LABELS = [
    ('speed_limit', 'ограничение скорости (NN)'),
    ('no_stopping', 'остановка запрещена'),
    ('no_parking', 'стоянка запрещена'),
    ('no_left', 'поворот налево запрещён'),
    ('no_right', 'поворот направо запрещён'),
    ('no_uturn', 'разворот запрещён'),
    ('uturn', 'разворот'),
    ('only_straight', 'только прямо'),
    ('only_right', 'только направо'),
    ('only_left', 'только налево'),
    ('straight_right', 'прямо или направо'),
    ('straight_left', 'прямо или налево'),
    ('keep_right', 'объезд справа/слева'),
    ('no_entry', 'въезд запрещён'),
    ('one_way', 'одностороннее движение'),
    ('lanes', 'движение по полосам'),
    ('crossing', 'пешеходный переход'),
    ('main_road', 'главная дорога'),
    ('give_way', 'уступи дорогу'),
    ('stop', 'STOP'),
    ('speed_bump', 'искусственная неровность'),
    ('bus_stop', 'остановка транспорта'),
    ('street_name', 'табличка улицы / дома'),
    ('roadworks', 'ремонт / конус'),
    ('other_sign', 'другой знак'),
    ('junk', 'прочее / мусор'),
]
LABEL_KEYS = {k for k, _ in LABELS}


def ensure_binary():
    if os.path.exists(BIN) and os.path.getmtime(BIN) >= os.path.getmtime(SWIFT_SRC):
        return BIN
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    # Собираем рядом и подменяем файл целиком: перезапись подписанного бинарника
    # на месте macOS наказывает SIGKILL у всех, кто его сейчас запускает.
    subprocess.run([SWIFTC, '-O', '-sdk', MACOS_SDK, SWIFT_SRC, '-o', BIN + '.new'], check=True)
    os.replace(BIN + '.new', BIN)
    return BIN


def run_kmeans(paths, k):
    binary = ensure_binary()
    with tempfile.TemporaryDirectory() as d:
        lst = os.path.join(d, 'list.txt')
        out = os.path.join(d, 'out.json')
        with open(lst, 'w') as f:
            f.write('\n'.join(paths))
        subprocess.run([binary, lst, str(k), out], check=True, capture_output=True)
        with open(out) as f:
            return json.load(f)['clusters']


def cluster_all(conn, log=print):
    with conn:
        conn.execute('UPDATE sign_crops SET cluster=NULL WHERE label IS NULL')
        conn.execute('DELETE FROM sign_clusters WHERE id NOT IN '
                     '(SELECT DISTINCT cluster FROM sign_crops WHERE cluster IS NOT NULL)')
    stats = {}
    for (shape,) in conn.execute('SELECT DISTINCT shape FROM sign_crops').fetchall():
        rows = conn.execute('SELECT id, path FROM sign_crops WHERE shape=? AND label IS NULL '
                            'AND path IS NOT NULL', (shape,)).fetchall()
        rows = [r for r in rows if os.path.exists(r['path'])]
        if not rows:
            continue
        k = max(1, min(MAX_K, round(len(rows) / PER_CLUSTER)))
        stats[shape] = (len(rows), store(conn, shape, rows, run_kmeans([r['path'] for r in rows], k)))
    log(stats)
    return stats


def store(conn, shape, rows, clusters, parent=None):
    by_path = {r['path']: r['id'] for r in rows}
    n = 0
    with conn:
        for c in clusters:
            ids = [by_path[p] for p in c['members'] if p in by_path]
            if not ids:
                continue
            reps = [by_path[p] for p in c['reps'] if p in by_path]
            cur = conn.execute('INSERT INTO sign_clusters(shape, size, reps, parent) VALUES(?,?,?,?)',
                               (shape, len(ids), json.dumps(reps), parent))
            conn.executemany('UPDATE sign_crops SET cluster=? WHERE id=?', [(cur.lastrowid, i) for i in ids])
            n += 1
    return n


def split(conn, cid, k=4):
    c = conn.execute('SELECT * FROM sign_clusters WHERE id=?', (cid,)).fetchone()
    if c is None:
        return 0
    rows = conn.execute('SELECT id, path FROM sign_crops WHERE cluster=? AND label IS NULL', (cid,)).fetchall()
    rows = [r for r in rows if r['path'] and os.path.exists(r['path'])]
    if len(rows) < 2:
        return 0
    res = run_kmeans([r['path'] for r in rows], min(k, len(rows)))
    n = store(conn, c['shape'], rows, res, parent=cid)
    with conn:
        conn.execute('DELETE FROM sign_clusters WHERE id=?', (cid,))
    return n


def label_cluster(conn, cid, label, value=None):
    """Подпись всем неподписанным вырезкам кластера (ограничение — с числом: speed_limit:60)."""
    if label not in LABEL_KEYS:
        return 0
    tag = f'{label}:{int(value)}' if label == 'speed_limit' and value else label
    with conn:
        cur = conn.execute('UPDATE sign_crops SET label=?, labeled_at=? WHERE cluster=? AND label IS NULL',
                           (tag, time.time(), cid))
        conn.execute('UPDATE sign_clusters SET label=? WHERE id=?', (tag, cid))
    return cur.rowcount


def export(conn, dest):
    n = 0
    for r in conn.execute('SELECT id, path, label FROM sign_crops WHERE label IS NOT NULL'):
        if not r['path'] or not os.path.exists(r['path']):
            continue
        d = os.path.join(dest, r['label'].replace(':', '_'))
        os.makedirs(d, exist_ok=True)
        dst = os.path.join(d, f"{r['id']}.jpg")
        if not os.path.exists(dst):
            os.link(r['path'], dst)
            n += 1
    return n


# ---------- правки подписей ----------

FIX_FILE = os.path.join(HERE, 'sign_label_fix.json')
# Действующая подпись: правка после проверки глазами, иначе подпись кластером.
EFFECTIVE_SQL = ('SELECT s.*, COALESCE(fx.label, s.label) AS eff, fx.label AS fixed '
                 'FROM sign_crops s LEFT JOIN sign_label_fix fx ON fx.crop_id = s.id')


def apply_fixes(conn, fixes, note='проверка глазами'):
    """fixes: [{'crop_id', 'label'}] → sign_label_fix. Исходная sign_crops.label
    не трогается; правка, совпавшая с подписью, не пишется."""
    n = 0
    with conn:
        for f in fixes:
            r = conn.execute('SELECT label FROM sign_crops WHERE id=?', (f['crop_id'],)).fetchone()
            if r is None:
                continue
            if r['label'] == f['label']:
                conn.execute('DELETE FROM sign_label_fix WHERE crop_id=?', (f['crop_id'],))
                continue
            conn.execute('INSERT OR REPLACE INTO sign_label_fix(crop_id, label_orig, label, note, at) '
                         'VALUES(?,?,?,?,?)', (f['crop_id'], r['label'], f['label'], note, time.time()))
            n += 1
    return n


def effective_labels(conn):
    """{crop_id: действующая подпись} для подписанных вырезок."""
    return {r['id']: r['eff'] for r in
            conn.execute(EFFECTIVE_SQL + ' WHERE COALESCE(fx.label, s.label) IS NOT NULL')}


def purity(conn):
    """Чистота подписей кластерами по классам: доля вырезок класса, которые
    проверка глазами оставила в нём. Уточнение other_sign → radar_sign —
    не примесь (знак «другой», просто теперь известно какой)."""
    out = {}
    for r in conn.execute('SELECT s.label, COUNT(*) n, SUM(fx.label IS NOT NULL AND NOT '
                          "(s.label='other_sign' AND fx.label='radar_sign')) bad "
                          'FROM sign_crops s LEFT JOIN sign_label_fix fx ON fx.crop_id=s.id '
                          'WHERE s.label IS NOT NULL GROUP BY s.label ORDER BY n DESC'):
        out[r['label']] = {'n': r['n'], 'bad': r['bad'], 'purity': round(1 - r['bad'] / r['n'], 3)}
    return out


# ---------- классификатор ----------

MODELS_DIR = os.path.join(BASE, 'models')
MODEL_PATH = os.path.join(MODELS_DIR, 'signs.mlmodel')
DATASET_DIR = os.path.join(BASE, 'signs_ds')
TRAIN_SRC = os.path.join(HERE, 'signtrain.swift')
CLASSIFY_SRC = os.path.join(HERE, 'signclassify.swift')
# Класс с меньшим числом примеров учить нечему: в проверку по поездкам ушло бы
# 2–3 вырезки, и «точность» по ним — шум. Такие сливаются в other_sign.
TRAIN_MIN = 15
# Редкие — не учатся вовсе и не сливаются: ограничение скорости читает число
# OCR (detect.swift), разворот запрещён — 2 вырезки; их знают только подписи.
RARE = ('speed_limit', 'no_uturn')
VAL_SHARE = 0.25
SPLIT_SEED = 7
# Ниже этой вероятности ответ классификатора не считается подписью (подбор —
# по проверке, см. models/signs_eval.json: per_class_thr).
PRED_MIN = 0.6


def is_rare(label):
    return label is not None and label.split(':')[0] in RARE


def train_classes(labels):
    """{crop_id: подпись} → {crop_id: класс обучения}: редкие выброшены,
    классы < TRAIN_MIN слиты в other_sign."""
    cnt = {}
    for lab in labels.values():
        if not is_rare(lab):
            cnt[lab] = cnt.get(lab, 0) + 1
    return {i: (lab if cnt[lab] >= TRAIN_MIN else 'other_sign')
            for i, lab in labels.items() if not is_rare(lab)}


def split_by_trips(items, share=VAL_SHARE, seed=SPLIT_SEED):
    """items: [(crop_id, trip_key, класс)] → множество поездок проверки.

    Делим ПО ПОЕЗДКАМ, а не по вырезкам: один знак виден в 3–8 кадрах подряд,
    и соседние кадры в train и val дали бы «точность» запоминания. Поездки
    перебираются в случайном (фиксированном) порядке; поездка уходит в
    проверку, если не переполняет ни один класс сверх share + 10 % и хоть
    одному ещё не хватает до share."""
    import random
    total, by_trip = {}, {}
    for _, trip, c in items:
        total[c] = total.get(c, 0) + 1
        by_trip.setdefault(trip, {})
        by_trip[trip][c] = by_trip[trip].get(c, 0) + 1
    trips = sorted(by_trip)
    random.Random(seed).shuffle(trips)
    val, have = set(), {}
    for t in trips:
        cnt = by_trip[t]
        over = any(have.get(c, 0) + n > (share + 0.1) * total[c] + 1 for c, n in cnt.items())
        need = any(have.get(c, 0) < share * total[c] for c in cnt)
        if need and not over:
            val.add(t)
            for c, n in cnt.items():
                have[c] = have.get(c, 0) + n
    return val


def labeled_items(conn):
    """[(crop_id, trip_key, класс обучения, путь)] подписанных вырезок."""
    labels = effective_labels(conn)
    cls = train_classes(labels)
    trip = dict(conn.execute('SELECT s.id, f.trip_key FROM sign_crops s JOIN frames f ON f.id=s.frame_id'))
    paths = dict(conn.execute('SELECT id, path FROM sign_crops'))
    return [(i, trip[i], c, paths[i]) for i, c in sorted(cls.items())
            if i in trip and paths.get(i) and os.path.exists(paths[i])]


def build_dataset(conn, dest=DATASET_DIR):
    import shutil
    items = labeled_items(conn)
    val = split_by_trips([(i, t, c) for i, t, c, _ in items])
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    split = {}
    for i, t, c, p in items:
        part = 'val' if t in val else 'train'
        d = os.path.join(dest, part, c)
        os.makedirs(d, exist_ok=True)
        os.link(p, os.path.join(d, f'{i}.jpg'))
        split[i] = part
    return items, split, sorted(val)


def ensure_tool(src, name):
    binary = os.path.join(BASE, 'bin', name)
    if os.path.exists(binary) and os.path.getmtime(binary) >= os.path.getmtime(src):
        return binary
    os.makedirs(os.path.dirname(binary), exist_ok=True)
    subprocess.run([SWIFTC, '-O', '-sdk', MACOS_SDK, src, '-o', binary + '.new'], check=True)
    os.replace(binary + '.new', binary)
    return binary


def run_classifier(paths, model=MODEL_PATH):
    """[путь] → {путь: (класс, вероятность, второй, его вероятность)}."""
    if not paths:
        return {}
    binary = ensure_tool(CLASSIFY_SRC, 'signclassify')
    with tempfile.TemporaryDirectory() as d:
        lst = os.path.join(d, 'list.txt')
        with open(lst, 'w') as f:
            f.write('\n'.join(paths))
        text = subprocess.run([binary, model, lst], capture_output=True, text=True, check=True).stdout
    out = {}
    for line in text.splitlines():
        try:
            j = json.loads(line)
        except json.JSONDecodeError:
            continue
        out[j['f']] = (j['l'], j['p'], j.get('l2'), j.get('p2'))
    return out


def confusion(pairs):
    """[(истина, ответ)] → (по классам {класс: precision, recall, n}, матрица {истина: {ответ: n}})."""
    m, classes = {}, set()
    for a, b in pairs:
        m.setdefault(a, {})
        m[a][b] = m[a].get(b, 0) + 1
        classes |= {a, b}
    per = {}
    for c in sorted(classes):
        tp = m.get(c, {}).get(c, 0)
        n_true = sum(m.get(c, {}).values())
        n_pred = sum(row.get(c, 0) for row in m.values())
        per[c] = {'n': n_true, 'precision': round(tp / n_pred, 3) if n_pred else None,
                  'recall': round(tp / n_true, 3) if n_true else None}
    return per, m


def train(conn, iters=40, log=print):
    items, split, val_trips = build_dataset(conn)
    os.makedirs(MODELS_DIR, exist_ok=True)
    binary = ensure_tool(TRAIN_SRC, 'signtrain')
    tmp = os.path.join(MODELS_DIR, 'signs.new.mlmodel')
    res = subprocess.run([binary, os.path.join(DATASET_DIR, 'train'), os.path.join(DATASET_DIR, 'val'), tmp,
                          str(iters)], capture_output=True, text=True, check=True)
    stats = json.loads(res.stdout.strip().splitlines()[-1])
    os.replace(tmp, MODEL_PATH)
    # своя оценка на проверке: по классам, с порогом и без
    val_items = [(i, c, p) for i, t, c, p in items if split[i] == 'val']
    pred = run_classifier([p for _, _, p in val_items])
    pairs, pairs_thr, below = [], [], 0
    for i, c, p in val_items:
        if p not in pred:
            continue
        lab, prob = pred[p][0], pred[p][1]
        pairs.append((c, lab))
        if prob >= PRED_MIN:
            pairs_thr.append((c, lab))
        else:
            below += 1
    per, mat = confusion(pairs)
    per_thr, _ = confusion(pairs_thr)
    count = {}
    for i, t, c, p in items:
        count.setdefault(c, {'train': 0, 'val': 0})
        count[c][split[i]] += 1
    report = {'when': time.strftime('%Y-%m-%d %H:%M'), 'createml': stats, 'iters': iters,
              'val_trips': val_trips, 'counts': count,
              'accuracy': round(sum(a == b for a, b in pairs) / max(1, len(pairs)), 3),
              'per_class': per, 'confusion': mat,
              'threshold': PRED_MIN, 'below_threshold': below,
              'accuracy_thr': round(sum(a == b for a, b in pairs_thr) / max(1, len(pairs_thr)), 3),
              'per_class_thr': per_thr}
    with open(os.path.join(MODELS_DIR, 'signs_eval.json'), 'w') as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    log(json.dumps({k: report[k] for k in ('createml', 'accuracy', 'accuracy_thr', 'below_threshold')},
                   ensure_ascii=False))
    return report


def model_tag(model=MODEL_PATH):
    return f'signs@{int(os.path.getmtime(model))}' if os.path.exists(model) else None


def classify(conn, all_crops=False, model=MODEL_PATH, log=print):
    """Классификатор по вырезкам → sign_pred. По умолчанию — только те, что
    ещё не размечены этой моделью (новые кандидаты следующих прогонов)."""
    tag = model_tag(model)
    if tag is None:
        log('модели знаков нет — python3 signs.py train')
        return 0
    sql = ('SELECT s.id, s.path FROM sign_crops s LEFT JOIN sign_pred p ON p.crop_id=s.id '
           'WHERE s.path IS NOT NULL')
    rows = conn.execute(sql) if all_crops else \
        conn.execute(sql + ' AND (p.crop_id IS NULL OR p.model IS NOT ?)', (tag,))
    rows = [r for r in rows.fetchall() if os.path.exists(r['path'])]
    n = 0
    for k in range(0, len(rows), 500):
        chunk = rows[k:k + 500]
        res = run_classifier([r['path'] for r in chunk], model)
        with conn:
            for r in chunk:
                if r['path'] in res:
                    lab, prob = res[r['path']][:2]
                    conn.execute('INSERT OR REPLACE INTO sign_pred(crop_id, label, conf, model, at) '
                                 'VALUES(?,?,?,?,?)', (r['id'], lab, prob, tag, time.time()))
                    n += 1
    return n


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    conn = catalog.connect()
    if argv[0] == 'cluster':
        cluster_all(conn)
    elif argv[0] == 'split':
        print(split(conn, int(argv[1])))
    elif argv[0] == 'export':
        print(export(conn, argv[1]))
    elif argv[0] == 'fix':
        with open(argv[1] if len(argv) > 1 else FIX_FILE) as f:
            print(apply_fixes(conn, json.load(f)['fixes']))
    elif argv[0] == 'purity':
        print(json.dumps(purity(conn), ensure_ascii=False, indent=1))
    elif argv[0] == 'train':
        train(conn, int(argv[1]) if len(argv) > 1 else 40)
    elif argv[0] == 'classify':
        print(classify(conn, all_crops='--all' in argv))


if __name__ == '__main__':
    sys.exit(main())
