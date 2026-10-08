"""Опознание камер для поездок без опор — HMM/Витерби поверх anchorhmm.py.

Состояния — камеры базы (плюс «ложное событие»), наблюдения — события
«проезд камеры» по видео с путём по OCR-скорости между ними. Переход a→b
правдоподобен, если путь по скорости согласуется с расстоянием по дорогам
(OSRM, с курсами камер), а курс прибытия — с направлением камеры (dir).
Цепочка принимается при ≥ 3 событиях подряд, расхождении ≤ 20 % и без
равноценного соперника.

Отличия от anchorhmm.identify:
- цепочки «туда-обратно» (камера повторяется в пределах NO_REPEAT соседних
  опознанных событий) отбрасываются до проверки: на прямой улице без курса
  они объясняют путь не хуже настоящей и делали ответ «неоднозначным»;
- больше кандидатов уходит на проверку OSRM (VERIFY_TOP);
- путь по дорогам — меньший из маршрутов «с курсами камер» и «без»: на
  поездках с GPX у настоящих соседних камер маршрут с курсами в трети
  случаев уходил в разворотную петлю (775 м по OSRM при 385 м по скорости и
  370 м по прямой) — поле dir у части камер не совпадает с движением.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import anchorhmm  # noqa: E402

MAX_MISMATCH = anchorhmm.MAX_MISMATCH
MIN_CHAIN = anchorhmm.MIN_CHAIN
VERIFY_TOP = 40
NO_REPEAT = 3


def index(cams):
    return anchorhmm.CamIndex(cams)


def has_loop(states, window=NO_REPEAT):
    real = [s for s in states if s is not None]
    for i, s in enumerate(real):
        if s in real[i + 1:i + 1 + window]:
            return True
    return False


class EitherWayOSRM:
    """route() = более короткий из маршрутов с курсами и без; курс прибытия
    проверяет anchorhmm по геометрии возвращённого маршрута."""

    def __init__(self, osrm):
        self.osrm = osrm

    def route(self, a, b, bearings=None):
        r1 = self.osrm.route(a, b, bearings=bearings)
        r2 = self.osrm.route(a, b) if bearings and any(x is not None for x in bearings) else None
        cands = [r for r in (r1, r2) if r]
        return min(cands, key=lambda r: r[1]) if cands else None


# Путь по OCR-скорости к прямой между соседними настоящими камерами (поездки с
# GPX, 08.10.2026): 1,07–1,10 почти везде — улицы города прямые. Цена anchorhmm
# (середина 1,25·прямой, допуск 35 %) этого не знала, и при 3500 камерах любая
# последовательность путей находила «идеальную» ложную цепочку (цена 0,03 против
# 2,27 у настоящей).
TORT_MID = 1.08
TORT_SIGMA = (0.08, 30.0)


def tight_cost(s_ab, d):
    if s_ab > d * 1.05 + 40:
        return None
    return ((d - TORT_MID * s_ab) / (TORT_SIGMA[0] * d + TORT_SIGMA[1])) ** 2


class DetourTolerantOSRM(EitherWayOSRM):
    """Если OSRM уводит в объезд (маршрут > пути по скорости в 1,2 раза), а прямая
    согласуется с путём (путь в 1,0–1,35 прямой), — верим прямой: камеры на оси
    разделённой дороги OSRM садит на встречную половину, и у настоящих соседних
    камер маршрут расходился с путём в 2–4 раза."""

    def __init__(self, osrm, odo_for):
        super().__init__(osrm)
        self.odo_for = odo_for   # (a, b) → путь по скорости для этого перехода

    def route(self, a, b, bearings=None):
        r = super().route(a, b, bearings)
        d = self.odo_for.get((a, b))
        if d is None:
            return r
        import passes
        line = passes.haversine(a[0], a[1], b[0], b[1])
        if (r is None or r[1] > d * 1.2) and line <= d <= 1.35 * line + 60:
            return [a, b], d
        return r


def subindex(cams, region=None, allowed=None):
    """Индекс по части базы: регион владельца (поездки — в одном городе) или список."""
    keep = [i for i, c in enumerate(cams) if (region is None or c.get('region') == region)
            and (allowed is None or i in allowed)]
    idx = anchorhmm.CamIndex([cams[i] for i in keep])
    return idx, keep


def identify(events, odo_at, idx, osrm, start_candidates=None, verify_top=VERIFY_TOP, tight=False,
             detour_ok=False):
    """events: [(t, p)] по времени. → dict(status, anchors=[(t, индекс камеры в idx, conf)]).
    tight — цена перехода по прямой с извилистостью 1,08 (см. tight_cost);
    detour_ok — объезд OSRM при согласной прямой не считать расхождением."""
    if len(events) < MIN_CHAIN:
        return {'status': 'too_few_events', 'anchors': [], 'events': len(events)}
    times = [e[0] for e in events]
    dists = [odo_at(b) - odo_at(a) for a, b in zip(times, times[1:])]
    saved = anchorhmm.straight_cost
    if tight:
        anchorhmm.straight_cost = tight_cost
    try:
        paths = anchorhmm.viterbi(dists, idx, start_candidates, top=verify_top * 4)
    finally:
        anchorhmm.straight_cost = saved
    scored, seen = [], set()
    for cost, states in paths:
        sig = tuple(states)
        if sig in seen or sum(s is not None for s in states) < MIN_CHAIN or has_loop(states):
            continue
        seen.add(sig)
        if detour_ok:
            odo_for, real = {}, [(k, st) for k, st in enumerate(states) if st is not None]
            for (k1, a), (k2, b) in zip(real, real[1:]):
                ca, cb = idx.cams[a], idx.cams[b]
                odo_for[((ca['lat'], ca['lon']), (cb['lat'], cb['lon']))] = sum(dists[k1:k2])
            ro = DetourTolerantOSRM(osrm, odo_for)
        else:
            ro = EitherWayOSRM(osrm)
        chain, checks = anchorhmm.verify_chain(states, dists, idx, ro)
        scored.append((chain, -cost, states, checks))
        if len(scored) >= verify_top:
            break
    if not scored:
        return {'status': 'no_chain', 'anchors': [], 'events': len(events)}
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    best = scored[0]
    if best[0] < MIN_CHAIN:
        return {'status': 'not_converged', 'anchors': [], 'events': len(events), 'best_chain': best[0]}
    rivals = [s for s in scored[1:] if s[0] >= best[0] and
              sum(1 for a, b in zip(s[2], best[2]) if a is not None and a == b) < best[0]]
    if rivals:
        return {'status': 'ambiguous', 'anchors': [], 'events': len(events), 'best_chain': best[0]}
    ok_k = {c['k'] for c in best[3] if c['ok']}
    real = [k for k, s in enumerate(best[2]) if s is not None]
    for k1, k2 in zip(real, real[1:]):
        if k2 in ok_k:
            ok_k.add(k1)
    conf = min(1.0, best[0] / (MIN_CHAIN + 3))
    anchors = [(times[k], best[2][k], conf) for k in sorted(ok_k)]
    return {'status': 'ok', 'anchors': anchors, 'events': len(events), 'best_chain': best[0],
            'checks': best[3]}
