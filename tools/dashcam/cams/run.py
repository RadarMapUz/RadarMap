#!/usr/bin/env python3
"""Прогон этапа «камеры по видео»: события → опознание → честная проверка →
кандидаты «новая» / «возможно, снята» → cams.db + JSON для страницы.

    python3 run.py events MODEL [--p 0.8]   — события по camprob(model) всех поездок,
                                              опознание по ближайшей там, где есть место
    python3 run.py honest MODEL [--p 0.8]   — п.5: опоры спрятаны, HMM, сверка с GPX
    python3 run.py candidates MODEL         — «новая» / «снята» + вырезки + cams_ui.json
"""
import bisect
import json
import os
import sys
import time

import common
import evaluate
import events
import geo
import hmm
import passes

CROPS = os.path.join(common.OUT, 'crops')
UI_JSON = os.path.join(common.OUT, 'cams_ui.json')
DAY_HOURS = (7, 19)       # местное: «днём» — кадры без ночи


def locate_event(ctx, key, t, frame_geo_ts):
    """Место события: кадр с местом, ближайший по времени к моменту проезда (≤ 3 с)."""
    ts, rows = frame_geo_ts
    i = bisect.bisect_left(ts, t)
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(ts) and abs(ts[j] - t) <= 3 and (best is None or abs(ts[j] - t) < abs(ts[best] - t)):
            best = j
    return rows[best] if best is not None else None


def geo_index(ctx, key):
    rows = sorted(((f['t'], ctx.geo[f['id']]) for f in ctx.by_trip.get(key, []) if f['id'] in ctx.geo))
    return [r[0] for r in rows], [r[1] for r in rows]


def run_events(model, p_min, log=print):
    ctx = evaluate.Ctx()
    prob = evaluate.model_prob(ctx.conn, model)
    out = []
    for key in sorted({ctx.fr[f]['trip_key'] for f in prob if f in ctx.fr}):
        evs = events.events_from_series(ctx.series(key, prob), ctx.odo(key), p_min=p_min)
        gi = geo_index(ctx, key)
        for e in evs:
            loc = locate_event(ctx, key, e['t'], gi)
            cid = dist = None
            lat = lon = course = None
            if loc:
                lat, lon, course = loc
                i, dist = events.nearest_camera(lat, lon, course, ctx.grid)
                cid = ctx.grid.cams[i]['id'] if i is not None else None
            out.append((key, e['t'], e['p'], e['n'], e['frame_id'], lat, lon, course, cid, dist,
                        'nearest' if loc else None, model))
        log(key, 'событий', len(evs))
    with ctx.conn:
        ctx.conn.execute('DELETE FROM events WHERE run=?', (model,))
        ctx.conn.executemany('INSERT INTO events(trip_key, t, p, n, frame_id, lat, lon, course, camera_id, '
                             'cam_dist, method, run) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', out)
    return len(out)


def nearest_accuracy(ctx, model):
    """С опорами (место кадра есть): событие ↔ проезд GPX, верно ли ближайшая камера."""
    ok = wrong = none = 0
    for key, tps in ctx.gp.items():
        evs = ctx.conn.execute('SELECT t, camera_id FROM events WHERE run=? AND trip_key=? ORDER BY t',
                               (model, key)).fetchall()
        truth = ctx.truth(key)
        pairs, _, _ = events.match([e['t'] for e in evs], [t for t, _ in truth])
        for i, j in pairs:
            cid = evs[i]['camera_id']
            if cid is None:
                none += 1
            elif cid in truth[j][1]:
                ok += 1
            else:
                wrong += 1
    return {'matched_events': ok + wrong + none, 'correct': ok, 'wrong': wrong, 'no_camera_60m': none}


def honest(model, p_min, oracle=False, log=print):
    """П.5: на поездках с GPX опоры спрятаны; события → HMM → сверка с wpt.
    oracle=True — вместо событий модели идеальные (моменты проездов из GPX)."""
    ctx = evaluate.Ctx()
    prob = evaluate.model_prob(ctx.conn, model)
    idx = hmm.index(ctx.grid.cams)
    osrm = geo.OSRM(ctx.conn)
    tot = {'trips': 0, 'truth_passes': 0, 'events': 0, 'claimed': 0, 'correct': 0, 'false': 0}
    per = []
    for key in sorted(ctx.gp):
        truth = ctx.truth(key)
        if not truth:
            continue
        odo = ctx.odo(key)
        if oracle:
            ev = [(t, 1.0) for t, _ in truth]
        else:
            ev = [(e['t'], e['p']) for e in events.events_from_series(ctx.series(key, prob), odo, p_min=p_min)]
        res = hmm.identify(ev, odo.at, idx, osrm) if len(ev) >= hmm.MIN_CHAIN else {
            'status': 'too_few_events', 'anchors': []}
        claimed = [(t, ctx.grid.cams[j]['id']) for t, j, _ in res['anchors']]
        good = 0
        tt = [t for t, _ in truth]
        for t, cid in claimed:
            j = min(range(len(tt)), key=lambda k: abs(tt[k] - t))
            if abs(tt[j] - t) <= 5 and cid in truth[j][1]:
                good += 1
        per.append({'trip': key, 'status': res['status'], 'truth': len(truth), 'events': len(ev),
                    'claimed': len(claimed), 'correct': good})
        tot['trips'] += 1
        tot['truth_passes'] += len(truth)
        tot['events'] += len(ev)
        tot['claimed'] += len(claimed)
        tot['correct'] += good
        tot['false'] += len(claimed) - good
        log(key, res['status'], f'проездов {len(truth)}, событий {len(ev)}, заявлено {len(claimed)}, верно {good}',
            'OSRM', osrm.requests)
    tot['missed'] = tot['truth_passes'] - tot['correct']
    tot['share_correct_of_truth'] = round(tot['correct'] / max(1, tot['truth_passes']), 3)
    tot['share_correct_of_claimed'] = round(tot['correct'] / max(1, tot['claimed']), 3)
    return {'model': 'oracle' if oracle else model, 'p_min': p_min, 'total': tot, 'trips': per,
            'nearest_with_anchors': None if oracle else nearest_accuracy(ctx, model)}


def is_day(t):
    h = time.localtime(t).tm_hour   # мак — в Ташкенте (UTC+5), как и часы регистратора
    return DAY_HOURS[0] <= h < DAY_HOURS[1]


def crop_event(sh, frame_id, region, name):
    """Вырезка кадра события (номера и лица размыты) — через detect.make_crops."""
    import detect
    os.makedirs(CROPS, exist_ok=True)
    dst = os.path.join(CROPS, name)
    if os.path.exists(dst):
        return name
    r = sh.execute('SELECT path FROM frames WHERE id=?', (frame_id,)).fetchone()
    if not r:
        return None
    box = region or [0, 0, 1280, 380]
    detect.make_crops([{'src': r['path'], 'dst': dst, 'box': box, 'keep': None}])
    return name if os.path.exists(dst) else None


def candidates(model, p_min, log=print):
    ctx = evaluate.Ctx()
    prob = evaluate.model_prob(ctx.conn, model)
    evs = [dict(r) for r in ctx.conn.execute('SELECT * FROM events WHERE run=?', (model,))]
    # «новая»: событие с местом, без проезда GPX рядом по времени и без камеры базы в 60 м по курсу
    unmatched = []
    by_trip = {}
    for e in evs:
        by_trip.setdefault(e['trip_key'], []).append(e)
    for key, lst in by_trip.items():
        truth = [t for t, _ in ctx.truth(key)]
        for e in lst:
            if e['lat'] is None or e['camera_id'] is not None:
                continue
            if any(abs(e['t'] - t) <= 5 for t in truth):
                continue
            if not is_day(e['t']):
                continue
            unmatched.append({'trip': key, 'lat': e['lat'], 'lon': e['lon'], 'course': e['course'], 'p': e['p'],
                              't': e['t'], 'frame_id': e['frame_id'], 'id': e['id']})
    new = events.new_camera_candidates(unmatched)
    # «снята»: камеры базы с проездами GPX днём на ходу, с кадрами, — был ли всплеск
    visits = {}
    for key, tps in ctx.gp.items():
        lst = by_trip.get(key, [])
        frs = ctx.by_trip.get(key, [])
        ts = [f['t'] for f in frs]
        odo = ctx.odo(key)
        for tp, cid in tps:
            i = bisect.bisect_left(ts, tp - 4)
            covered = i < len(ts) and ts[i] <= tp
            seen = any(abs(e['t'] - tp) <= 5 for e in lst)
            v = odo.speed(tp) or 0
            visits.setdefault(cid, []).append({'trip': key, 't': tp, 'day': is_day(tp), 'kmh': v,
                                               'covered': covered, 'seen': seen})
    removed = []
    for cid, vs in visits.items():
        if events.removed_verdict(vs) == 'removed':
            removed.append((cid, vs))
    cams = {c['id']: c for c in common.cameras()}
    rows, ui = [], {'model': model, 'p_min': p_min, 'new': [], 'removed': [], 'at': time.time()}
    for k, c in enumerate(sorted(new, key=lambda c: -len(c))):
        best = max(c, key=lambda e: e['p'])
        crops = [x for x in (crop_event(ctx.sh, e['frame_id'], None, f"new_{e['frame_id']}.jpg")
                             for e in sorted(c, key=lambda e: -e['p'])[:3]) if x]
        lat = sum(e['lat'] for e in c) / len(c)
        lon = sum(e['lon'] for e in c) / len(c)
        near = ctx.grid.near(lat, lon, 300)
        item = {'kind': 'new', 'lat': lat, 'lon': lon, 'course': best['course'], 'trips': sorted({e['trip'] for e in c}),
                'n_events': len(c), 'p': best['p'], 'crops': crops,
                'nearest_db': {'id': ctx.grid.cams[near[0][1]]['id'], 'm': round(near[0][0])} if near else None}
        ui['new'].append(item)
        rows.append(('new', None, lat, lon, best['course'], len(item['trips']), len(c), None, best['p'],
                     json.dumps(crops), json.dumps(item, ensure_ascii=False), time.time()))
    for cid, vs in removed:
        good = [v for v in vs if v['day'] and v['covered'] and v['kmh'] >= events.REMOVED_MIN_KMH]
        crops = []
        for v in good[:3]:
            frs = [f for f in ctx.by_trip[v['trip']] if 0.5 <= v['t'] - f['t'] <= 3]
            if frs:
                f = max(frs, key=lambda f: prob.get(f['id'], 0))
                x = crop_event(ctx.sh, f['id'], None, f"gone_{f['id']}.jpg")
                if x:
                    crops.append(x)
        c = cams.get(cid, {})
        item = {'kind': 'removed', 'camera_id': cid, 'lat': c.get('lat'), 'lon': c.get('lon'), 'type': c.get('type'),
                'location': c.get('location'), 'passes': len(good), 'crops': crops,
                'trips': sorted({v['trip'] for v in good})}
        ui['removed'].append(item)
        rows.append(('removed', cid, c.get('lat'), c.get('lon'), c.get('dir'), len(item['trips']), 0, len(good), None,
                     json.dumps(crops), json.dumps(item, ensure_ascii=False), time.time()))
    present = sum(1 for vs in visits.values() if events.removed_verdict(vs) == 'present')
    unknown = sum(1 for vs in visits.values() if events.removed_verdict(vs) == 'unknown')
    ui['summary'] = {'new': len(ui['new']), 'removed': len(ui['removed']), 'cameras_seen': present,
                     'cameras_unknown': unknown, 'unmatched_events': len(unmatched)}
    with ctx.conn:
        ctx.conn.execute('DELETE FROM candidates')
        ctx.conn.executemany('INSERT INTO candidates(kind, camera_id, lat, lon, course, n_trips, n_events, n_passes, p, '
                             'crops, detail, at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', rows)
    reports = {}
    for r in ctx.conn.execute('SELECT name, body FROM reports'):
        reports[r['name']] = json.loads(r['body'])
    ui['reports'] = {k: reports[k] for k in ('honest', 'honest_oracle', 'lag_check') if k in reports}
    ui['reports']['classifier'] = reports.get(f'eval_{model}') or reports.get(f'eval_{model.replace("_all", "")}')
    with open(UI_JSON, 'w') as f:
        json.dump(ui, f, ensure_ascii=False, indent=1)
    log(json.dumps(ui['summary'], ensure_ascii=False))
    return ui


def arg(name, default):
    return type(default)(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


if __name__ == '__main__':
    cmd, model = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'mil_fine'
    p = arg('--p', 0.8)
    if cmd == 'events':
        print('событий', run_events(model, p))
    elif cmd == 'honest':
        oracle = '--oracle' in sys.argv
        rep = honest(model, p, oracle=oracle)
        common.save_report(common.own(), 'honest_oracle' if oracle else 'honest', rep)
        print(json.dumps({k: v for k, v in rep.items() if k != 'trips'}, ensure_ascii=False, indent=1))
    elif cmd == 'candidates':
        candidates(model, p)
