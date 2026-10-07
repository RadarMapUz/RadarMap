"""Чистая логика: вероятность по кадрам → события «проезд камеры»,
опознание по ближайшей камере базы, сверка с правдой, правила «новая»/«снята».
"""
import passes

# ---------- всплески ----------

EVENT_P = 0.5          # кадр «камера близко»
EVENT_MIN_FRAMES = 2   # всплеск — хотя бы столько кадров
EVENT_SOLO_P = 0.9     # …или один очень уверенный
EVENT_GAP_S = 2.0      # кадры всплеска не дальше друг от друга по времени
EVENT_LEAD_M = 12.0    # камера уходит за верх кадра за ~10 м до проезда
EVENT_MERGE_M = 40.0   # два всплеска ближе по пути — одна опора


def spikes(series, p_min=EVENT_P, min_frames=EVENT_MIN_FRAMES, solo_p=EVENT_SOLO_P, gap=EVENT_GAP_S):
    """series: [(t, p, frame_id)] по времени (кадры на ходу) → [[(t, p, frame_id)…]] —
    подряд идущие кадры с p ≥ p_min."""
    out, run = [], []
    for item in series:
        t, p = item[0], item[1]
        if p >= p_min and (not run or t - run[-1][0] <= gap):
            run.append(item)
            continue
        if run and (len(run) >= min_frames or max(q[1] for q in run) >= solo_p):
            out.append(run)
        run = [item] if p >= p_min else []
    if run and (len(run) >= min_frames or max(q[1] for q in run) >= solo_p):
        out.append(run)
    return out


def events_from_series(series, odo, merge_m=EVENT_MERGE_M, lead_m=EVENT_LEAD_M, **kw):
    """→ [dict(t — момент проезда, p — max, n — кадров, frame_id — лучший кадр)].
    Момент проезда: путь последнего «близкого» кадра + lead_m. Соседние
    всплески ближе merge_m по пути сливаются (камеры на одной опоре, мигание)."""
    evs = []
    for run in spikes(series, **kw):
        best = max(run, key=lambda q: q[1])
        s_end = odo.at(run[-1][0]) + lead_m
        t = odo.time_at(s_end) if odo.time_at(s_end) is not None else run[-1][0]
        e = {'t': t, 's': s_end, 'p': best[1], 'n': len(run), 'frame_id': best[2], 't0': run[0][0]}
        if evs and s_end - evs[-1]['s'] < merge_m:
            prev = evs[-1]
            prev.update(t=t, s=s_end, n=prev['n'] + len(run))
            if best[1] > prev['p']:
                prev.update(p=best[1], frame_id=best[2])
            continue
        evs.append(e)
    return evs


# ---------- сверка с правдой ----------

def match(events, truth_times, tol_s=5.0):
    """Жадное сопоставление по времени. truth_times: [t]. → (пары [(i_ev, i_truth)],
    лишние события [i], пропущенные проезды [i])."""
    pairs = sorted(((abs(e - t), i, j) for i, e in enumerate(events) for j, t in enumerate(truth_times)
                    if abs(e - t) <= tol_s))
    used_e, used_t, out = set(), set(), []
    for _, i, j in pairs:
        if i in used_e or j in used_t:
            continue
        used_e.add(i)
        used_t.add(j)
        out.append((i, j))
    return (sorted(out), [i for i in range(len(events)) if i not in used_e],
            [j for j in range(len(truth_times)) if j not in used_t])


def dedup_truth(passes_list, gap_s=2.0):
    """[(t, camera_id)] → [(t, {camera_id…})]: камеры одной опоры — одно событие."""
    out = []
    for t, cid in sorted(passes_list):
        if out and t - out[-1][0] < gap_s:
            out[-1][1].add(cid)
            continue
        out.append((t, {cid}))
    return out


# ---------- опознание по ближайшей (поездки с опорами) ----------

NEAR_M = 60.0
DIR_TOL = 70.0


def course_ok(cam, course, tol=DIR_TOL):
    """Камера с известным направлением (dir) снимает только свою сторону;
    без dir — годится любая (нет доказательства, что не наша)."""
    d = cam.get('dir')
    if d is None or course is None or course < 0:
        return True
    return passes.angle_diff(d, course) <= tol


def nearest_camera(lat, lon, course, grid, r_m=NEAR_M):
    """→ (индекс камеры, расстояние) или (None, расстояние до ближайшей любой)."""
    near = grid.near(lat, lon, r_m)
    for d, i in near:
        if course_ok(grid.cams[i], course):
            return i, d
    return None, (near[0][0] if near else None)


# ---------- правила для продукта ----------

NEW_MIN_TRIPS = 2       # «новая» — всплеск в ≥ 2 поездках
NEW_CLUSTER_M = 40.0    # события ближе — одно место
REMOVED_MIN_PASSES = 3  # «снята» — ≥ 3 дневных проезда на ходу без всплеска
REMOVED_MIN_KMH = 15.0


def cluster_unmatched(evs, r_m=NEW_CLUSTER_M, course_tol=45.0):
    """evs: [dict(lat, lon, course, trip, …)] — события без камеры базы рядом.
    → [[ev…]] кластеры по месту и курсу (разные стороны дороги — разные камеры)."""
    clusters = []
    for e in sorted(evs, key=lambda x: -x.get('p', 0)):
        for c in clusters:
            h = c[0]
            if passes.haversine(e['lat'], e['lon'], h['lat'], h['lon']) <= r_m and (
                    e.get('course') is None or h.get('course') is None or
                    passes.angle_diff(e['course'], h['course']) <= course_tol):
                c.append(e)
                break
        else:
            clusters.append([e])
    return clusters


def new_camera_candidates(unmatched, min_trips=NEW_MIN_TRIPS, **kw):
    """Устойчивый всплеск без камеры базы: кластер, подтверждённый ≥ min_trips поездками."""
    out = []
    for c in cluster_unmatched(unmatched, **kw):
        trips = {e['trip'] for e in c}
        if len(trips) >= min_trips:
            out.append(c)
    return out


def removed_verdict(visits, min_passes=REMOVED_MIN_PASSES, min_kmh=REMOVED_MIN_KMH):
    """visits: [dict(day: bool, kmh, seen: bool, covered: bool)] — проезды мимо камеры
    базы. «Возможно, снята» — ≥ min_passes дневных проездов на ходу с кадрами (covered)
    и ни одного со всплеском. → 'removed' | 'present' | 'unknown'."""
    good = [v for v in visits if v.get('day') and v.get('covered') and (v.get('kmh') or 0) >= min_kmh]
    if any(v.get('seen') for v in good):
        return 'present'
    if len(good) >= min_passes:
        return 'removed'
    return 'unknown'
