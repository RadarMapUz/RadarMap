#!/usr/bin/env python3
"""Кластеры вырезок знаков для подписи владельцем и выгрузка обучающей выборки.

    python3 signs.py cluster            — пересобрать кластеры по каждой форме
    python3 signs.py split CLUSTER_ID   — разбить кластер на 4
    python3 signs.py export DIR         — подписанные вырезки → DIR/<класс>/ (для Create ML)

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
    ('other_sign', 'другой знак'),
    ('junk', 'прочее / мусор'),
]
LABEL_KEYS = {k for k, _ in LABELS}


def ensure_binary():
    if os.path.exists(BIN) and os.path.getmtime(BIN) >= os.path.getmtime(SWIFT_SRC):
        return BIN
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    subprocess.run([SWIFTC, '-O', '-sdk', MACOS_SDK, SWIFT_SRC, '-o', BIN], check=True)
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


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    conn = catalog.connect()
    if argv[0] == 'cluster':
        cluster_all(conn)
    elif argv[0] == 'split':
        print(split(conn, int(argv[1])))
    elif argv[0] == 'export':
        print(export(conn, argv[1]))


if __name__ == '__main__':
    sys.exit(main())
