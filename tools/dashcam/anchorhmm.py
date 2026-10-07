"""Опознание проездов камер по видео: какие камеры базы стоят за событиями.

Вход — события «проезд неизвестной камеры» (selfcam.events: время по часам
регистратора) и путь по интегралу скорости из кадра между ними. Скрытые
состояния — камеры из RadarMap/Resources/cameras.json (плюс «ложное
событие»: классификатор ошибается). Переход a→b правдоподобен, если путь по
скорости между событиями согласуется с расстоянием по дорогам между камерами.

Два прохода, потому что дорог между всеми парами 3475 камер не посчитать:
1. дёшево — лучевой поиск (beam) по прямым расстояниям: путь по дорогам не
   короче прямой и обычно в 1,0–1,5 раза длиннее;
2. дорого — лучшие цепочки проверяются маршрутом нашего OSRM (кэш, ≤2 запр/с):
   расхождение пути ≤ MAX_MISMATCH и курс прибытия согласен с направлением
   камеры (поле dir), если оно есть.

Цепочка принимается только при сходимости: ≥ MIN_CHAIN подтверждённых
событий подряд, и вторая по счёту цепочка — заметно хуже (иначе неоднозначно,
поездка «не привязана»). Лучше честное «не знаю», чем опоры не там.
"""
import math

import gpx

MAX_MISMATCH = 0.20        # |путь по скорости − по дорогам| / путь
MIN_CHAIN = 3
VERIFY_TOP = 25
FALSE_EVENT_COST = 4.0     # цена объявить событие ложным
TORTUOSITY = (1.0, 1.6)    # дорога / прямая
DIR_TOL_DEG = 70
MIN_GAP_M = 30             # события ближе по пути — одна камера/одна опора (дубль)


def straight_cost(s_ab, d):
    """Цена перехода по прямой s_ab при пути по скорости d (оба в м). None — невозможно."""
    lo = s_ab * TORTUOSITY[0] - 40
    hi = s_ab * TORTUOSITY[1] + 80
    if d < lo - 0.2 * d or s_ab > d * 1.05 + 60:
        return None
    if d <= hi:
        mid = s_ab * 1.25
        return ((d - mid) / (0.35 * d + 60)) ** 2
    return ((d - hi) / (0.2 * d + 60)) ** 2 + 0.5


class CamIndex:
    """Камеры + заранее посчитанные соседи (до MAX_NEIGHBOR_M, по возрастанию
    расстояния): переход ищется срезом по bisect, а не перебором базы."""
    MAX_NEIGHBOR_M = 6000

    def __init__(self, cams, cell=0.05):
        import bisect
        self._bisect = bisect
        self.cams = cams
        g = {}
        for i, c in enumerate(cams):
            g.setdefault((int(c['lat'] / cell), int(c['lon'] / cell)), []).append(i)
        self.nb, self.nd = [], []
        for i, c in enumerate(cams):
            k = (int(c['lat'] / cell), int(c['lon'] / cell))
            lst = []
            for a in range(k[0] - 1, k[0] + 2):
                for b in range(k[1] - 2, k[1] + 3):
                    for j in g.get((a, b), ()):
                        if j != i:
                            d = gpx.haversine(c['lat'], c['lon'], cams[j]['lat'], cams[j]['lon'])
                            if d <= self.MAX_NEIGHBOR_M:
                                lst.append((d, j))
            lst.sort()
            self.nd.append([d for d, _ in lst])
            self.nb.append([j for _, j in lst])

    def within(self, i, r_m, lo_m=0.0):
        """Соседи камеры i на расстоянии [lo_m, r_m] → [(j, d)]."""
        nd = self.nd[i]
        a = self._bisect.bisect_left(nd, lo_m)
        b = self._bisect.bisect_right(nd, r_m)
        return list(zip(self.nb[i][a:b], nd[a:b]))


MAX_SKIP = 3               # до двух ложных событий подряд внутри цепочки


def viterbi(dists, idx, start_candidates=None, top=VERIFY_TOP * 3):
    """Витерби по слоям-событиям. Состояние слоя k — камера события k.
    V[k][j] = min по m ∈ 1..MAX_SKIP и камере i слоя k−m:
              V[k−m][i] + переход(i→j, путь от k−m до k) + (m−1)·FALSE_EVENT_COST.
    Начать цепочку можно на любом слое (все прежние события — ложные), закончить —
    тоже (все последующие — ложные). dists[i] — путь от события i до i+1.
    → [(цена, [камера|None по событиям])] — лучшие пути, по одному на конечную камеру."""
    n = len(dists) + 1
    cum = [0.0]
    for d in dists:
        cum.append(cum[-1] + d)
    starts = list(start_candidates) if start_candidates is not None else list(range(len(idx.cams)))
    V = []      # V[k]: {камера: цена}
    back = []   # back[k]: {камера: (k_prev, камера_prev) | None}
    for k in range(n):
        vk = {j: k * FALSE_EVENT_COST for j in starts}
        bk = {j: None for j in starts}
        for m in range(1, MAX_SKIP + 1):
            kp = k - m
            if kp < 0:
                break
            d = cum[k] - cum[kp]
            if d < MIN_GAP_M:
                continue
            for i, ci in V[kp].items():
                for j, sdist in idx.within(i, d * 1.05 + 60, d / 2.5 - 50):
                    c = straight_cost(sdist, d)
                    if c is None:
                        continue
                    tot = ci + c + (m - 1) * FALSE_EVENT_COST
                    if tot < vk.get(j, math.inf):
                        vk[j] = tot
                        bk[j] = (kp, i)
        V.append(vk)
        back.append(bk)
    ends = []
    for k in range(n):
        for j, c in V[k].items():
            if back[k][j] is None:
                continue  # цепочка из одной камеры — не цепочка
            ends.append((c + (n - 1 - k) * FALSE_EVENT_COST, k, j))
    ends.sort()
    out, seen = [], set()
    for cost, k, j in ends:
        states = [None] * n
        kk, jj = k, j
        while True:
            states[kk] = jj
            b = back[kk][jj]
            if b is None:
                break
            kk, jj = b
        sig = tuple(states)
        if sig in seen:
            continue
        seen.add(sig)
        out.append((cost, states))
        if len(out) >= top:
            break
    return out


def bearing_diff(a, b):
    return abs((a - b + 180) % 360 - 180)


def verify_chain(states, dists, idx, osrm):
    """Проверка цепочки маршрутами OSRM → (подтверждено подряд max, детали)."""
    real = [(k, s) for k, s in enumerate(states) if s is not None]
    checks = []
    for (k1, a), (k2, b) in zip(real, real[1:]):
        d = sum(dists[k1:k2])
        ca, cb = idx.cams[a], idx.cams[b]
        r = osrm.route((ca['lat'], ca['lon']), (cb['lat'], cb['lon']),
                       bearings=(ca.get('dir'), cb.get('dir')))
        if r is None:
            checks.append({'k': k2, 'ok': False, 'why': 'no_route'})
            continue
        coords, route_m = r
        mism = abs(route_m - d) / max(d, 1)
        ok = mism <= MAX_MISMATCH
        dir_ok = None
        if cb.get('dir') is not None and len(coords) >= 2:
            # курс прибытия — по последним ~30 м маршрута
            end = coords[-1]
            prev = coords[0]
            for p in reversed(coords[:-1]):
                prev = p
                if gpx.haversine(p[0], p[1], end[0], end[1]) >= 30:
                    break
            import geo
            brg = geo.bearing(prev[0], prev[1], end[0], end[1])
            dir_ok = bearing_diff(brg, cb['dir']) <= DIR_TOL_DEG
            ok = ok and dir_ok
        checks.append({'k': k2, 'ok': ok, 'mismatch': round(mism, 3), 'route_m': round(route_m),
                       'odo_m': round(d), 'dir_ok': dir_ok})
    best = run = 0
    for c in checks:
        run = run + 1 if c['ok'] else 0
        best = max(best, run)
    # «событий подряд» = подтверждённых переходов + 1
    return (best + 1 if best else 0), checks


def identify(events, odo_at, cams, osrm, start_candidates=None):
    """events: [(t, p, …)]; odo_at(t) → путь, м. → dict(status, anchors=[(t, cam_index, conf)])."""
    if len(events) < MIN_CHAIN:
        return {'status': 'too_few_events', 'anchors': [], 'events': len(events)}
    idx = cams if isinstance(cams, CamIndex) else CamIndex(cams)
    times = [e[0] for e in events]
    dists = [odo_at(b) - odo_at(a) for a, b in zip(times, times[1:])]
    paths = viterbi(dists, idx, start_candidates)
    scored = []
    seen = set()
    for cost, states in paths[:VERIFY_TOP * 3]:
        sig = tuple(states)
        if sig in seen or sum(s is not None for s in states) < MIN_CHAIN:
            continue
        seen.add(sig)
        chain, checks = verify_chain(states, dists, idx, osrm)
        scored.append((chain, -cost, states, checks))
        if len(scored) >= VERIFY_TOP:
            break
    if not scored:
        return {'status': 'no_chain', 'anchors': [], 'events': len(events)}
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    best = scored[0]
    if best[0] < MIN_CHAIN:
        return {'status': 'not_converged', 'anchors': [], 'events': len(events), 'best_chain': best[0]}
    # Однозначность: другая цепочка с тем же числом подтверждений и другими камерами
    rivals = [s for s in scored[1:] if s[0] >= best[0] and
              sum(1 for a, b in zip(s[2], best[2]) if a is not None and a == b) < best[0]]
    if rivals:
        return {'status': 'ambiguous', 'anchors': [], 'events': len(events), 'best_chain': best[0]}
    ok_k = {c['k'] for c in best[3] if c['ok']}
    # первая камера подтверждённого перехода тоже опора
    real = [k for k, s in enumerate(best[2]) if s is not None]
    for (k1, k2) in zip(real, real[1:]):
        if k2 in ok_k:
            ok_k.add(k1)
    conf = min(1.0, best[0] / (MIN_CHAIN + 3))
    anchors = [(times[k], best[2][k], conf) for k in sorted(ok_k)]
    return {'status': 'ok', 'anchors': anchors, 'events': len(events), 'best_chain': best[0],
            'checks': best[3]}
