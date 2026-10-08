#!/usr/bin/env python3
"""Прогон модели Create ML (camnet) по всем кадрам → camprob (model=имя).

    python3 cmlpredict.py MODEL.mlmodel NAME [--jobs 4] [--trips k1,k2]
"""
import os
import subprocess
import sys
import tempfile

import common

BIN = os.path.join(common.OUT, 'bin', 'camnet')
TOP = 380 / 529   # полоса над горизонтом, как в выборке dataset.py


def run(model, name, jobs=4, trips=None):
    sh, conn = common.shared(), common.own()
    q = 'SELECT id, trip_key, t, path FROM frames'
    rows = [dict(r) for r in sh.execute(q) if (not trips or r['trip_key'] in trips) and os.path.exists(r['path'])]
    by_path = {r['path']: r for r in rows}
    procs = []
    for j in range(jobs):
        part = rows[j::jobs]
        f = tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False, dir=common.OUT)
        f.write('\n'.join(r['path'] for r in part))
        f.close()
        procs.append((subprocess.Popen([BIN, 'predict', model, f.name, str(TOP)], stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True), f.name))
    out = []
    for p, lst in procs:
        stdout, _ = p.communicate()
        os.remove(lst)
        for line in stdout.splitlines():
            if '\t' in line:
                path, v = line.rsplit('\t', 1)
                r = by_path.get(path)
                if r and float(v) >= 0:
                    out.append((r['id'], r['trip_key'], r['t'], float(v), name))
    with conn:
        conn.executemany('INSERT OR REPLACE INTO camprob(frame_id, trip_key, t, p, model) VALUES(?,?,?,?,?)', out)
    return len(out)


if __name__ == '__main__':
    a = sys.argv
    jobs = int(a[a.index('--jobs') + 1]) if '--jobs' in a else 4
    trips = set(a[a.index('--trips') + 1].split(',')) if '--trips' in a else None
    print('кадров', run(a[1], a[2], jobs, trips))
