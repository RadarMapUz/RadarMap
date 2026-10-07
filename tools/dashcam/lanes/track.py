"""Отслеживание линий по подряд идущим кадрам — чистая логика, без картинок.

Кадр даёт гистограмму поперечного положения точек разметки на земле
(X0 — поперёк на Z_REF впереди, шаг BIN). Линия разметки держится много
кадров на одном поперечном месте (смещаясь вместе со всеми линиями, когда
машина виляет или перестраивается), бок соседней машины, тень или блик —
один-два кадра. Поэтому:

1. пики каждого кадра (frame_peaks);
2. общий сдвиг соседних кадров — взаимная корреляция гистограмм
   (frame_shift): виляние и перестроение сдвигают все линии сразу;
3. сцепка пиков в треки с учётом сдвига (link_tracks): линия = трек,
   который живёт ≥ MIN_LIFE_S и виден в большей части своих кадров;
4. «бегут ли штрихи» (motion_test): продольный профиль краски линии в
   кадре k, сдвинутый на путь машины между k и m, должен совпасть с
   профилем кадра m. Настоящая прерывистая сдвигается ровно на путь;
   отражение в стекле, блик, грязь на стекле — стоят (сдвиг 0); бордюр,
   забор, сплошная — без структуры, тест молчит (ни за, ни против).
"""
import math

BIN = 0.1
PEAK_SEP = 0.6        # два пика ближе — один
LINK_TOL = 0.30       # пик кадра k+1 — продолжение трека, если поперёк ближе, м
MAX_GAP_S = 0.6       # трек переживает столько секунд без пика
MIN_LIFE_S = 1.0      # линия — то, что живёт хотя бы столько
MIN_PRESENCE = 0.5    # …и видна хотя бы в такой доле кадров своей жизни
SHIFT_MAX = 0.30      # общий сдвиг соседних кадров не больше, м


def smooth(h, k=(1, 2, 3, 2, 1)):
    n = len(k) // 2
    s = sum(k)
    out = []
    for i in range(len(h)):
        acc = 0.0
        for j, w in enumerate(k):
            ii = i + j - n
            if 0 <= ii < len(h):
                acc += w * h[ii]
        out.append(acc / s)
    return out


def frame_peaks(h, x0, min_val, sep=PEAK_SEP, step=BIN):
    """Пики гистограммы h (бины от x0 с шагом step): локальные максимумы не
    ниже min_val, жадно по убыванию, ближе sep не берём. → [(x, val)]."""
    hs = smooth(h)
    cand = [i for i in range(1, len(hs) - 1)
            if hs[i] >= min_val and hs[i] >= hs[i - 1] and hs[i] > hs[i + 1]]
    cand.sort(key=lambda i: -hs[i])
    out = []
    for i in cand:
        x = x0 + (i + 0.5) * step
        if all(abs(x - p) >= sep for p, _ in out):
            out.append((x, hs[i]))
    return sorted(out)


def frame_shift(ha, hb, max_shift=SHIFT_MAX, step=BIN):
    """Сдвиг (м) гистограммы hb относительно ha: argmax корреляции в
    пределах ±max_shift. Плюс — линии в кадре b правее. Пустые → 0."""
    n = int(round(max_shift / step))
    best, arg = None, 0
    for d in range(-n, n + 1):
        acc = 0.0
        for i in range(max(0, -d), min(len(ha), len(hb) - d)):
            acc += ha[i] * hb[i + d]
        # при равенстве — меньший по модулю сдвиг
        if best is None or acc > best + 1e-9 or (abs(acc - best) <= 1e-9 and abs(d) < abs(arg)):
            best, arg = acc, d
    return arg * step if best and best > 0 else 0.0


def cumulative(shifts):
    """Сдвиги соседних кадров → накопленный сдвиг каждого кадра от первого."""
    out = [0.0]
    for s in shifts:
        out.append(out[-1] + s)
    return out


def link_tracks(peaks, times, shifts, tol=LINK_TOL, max_gap=MAX_GAP_S):
    """peaks[k] — [(x, val)] кадра k, times[k] — время, с; shifts[k] — сдвиг
    кадра k+1 относительно k. → треки [{'k': [...], 'x': [...], 'v': [...]}].
    Сравниваем в «приведённых» координатах x − накопленный сдвиг: так
    перестроение не рвёт треки. Каждый пик достаётся одному треку
    (ближайшему)."""
    cum = cumulative(shifts)
    tracks = []
    for k, pk in enumerate(peaks):
        active = [t for t in tracks if times[k] - times[t["k"][-1]] <= max_gap + 1e-9]
        pairs = []
        for pi, (x, v) in enumerate(pk):
            xr = x - cum[k]
            for ti, t in enumerate(active):
                d = abs(xr - t["xr"][-1])
                if d <= tol:
                    pairs.append((d, pi, ti))
        pairs.sort()
        used_p, used_t = set(), set()
        for d, pi, ti in pairs:
            if pi in used_p or ti in used_t:
                continue
            used_p.add(pi)
            used_t.add(ti)
            t = active[ti]
            x, v = pk[pi]
            t["k"].append(k)
            t["x"].append(x)
            t["xr"].append(x - cum[k])
            t["v"].append(v)
        for pi, (x, v) in enumerate(pk):
            if pi not in used_p:
                tracks.append({"k": [k], "x": [x], "xr": [x - cum[k]], "v": [v]})
    return tracks


def track_life(t, times):
    """→ (длительность, с; доля кадров жизни, где трек виден)."""
    k0, k1 = t["k"][0], t["k"][-1]
    life = times[k1] - times[k0]
    return life, len(t["k"]) / (k1 - k0 + 1)


def is_line_track(t, times, min_life=MIN_LIFE_S, min_presence=MIN_PRESENCE):
    life, pres = track_life(t, times)
    return life >= min_life and pres >= min_presence


def track_x_at(t, k, cum):
    """Поперечное положение трека в кадре k: своё, если виден; иначе
    ближайшее известное, перенесённое общим сдвигом кадров."""
    if k in t["k"]:
        return t["x"][t["k"].index(k)]
    j = min(range(len(t["k"])), key=lambda i: abs(t["k"][i] - k))
    return t["xr"][j] + cum[k]


# ── бегут ли штрихи ───────────────────────────────────────────────────

PROF_STEP = 0.25      # ячейка продольного профиля, м
MOVE_TOL = 0.25       # доля пути: сдвиг совпал с путём машины в пределах
MOVE_ABS = 1.0        # …или в пределах стольких метров
STATIC_MAX = 0.5      # сдвиг не больше — «стоит»
MIN_PATH = 2.5        # пара кадров информативна, если проехали хотя бы столько


def profile(zs, z0, z1, step=PROF_STEP, unknown=()):
    """Продольные координаты точек краски → занятость ячеек [z0, z1):
    1 — краска, 0 — нет, −1 — не знаем (ячейку закрывает нить отражения,
    вырезанная из маски: её дыра стоит в кадре и иначе голосовала бы
    «стоит»)."""
    n = int(round((z1 - z0) / step))
    occ = [0] * n
    for z in zs:
        i = int((z - z0) / step)
        if 0 <= i < n:
            occ[i] = 1
    for z in unknown:
        i = int((z - z0) / step)
        if 0 <= i < n:
            occ[i] = -1
    return occ


def structured(occ, lo=0.15, hi=0.8):
    """Есть ли в профиле что сравнивать: и краска, и разрывы."""
    known = [o for o in occ if o >= 0]
    if len(known) < 0.5 * len(occ) or not known:
        return False
    f = sum(known) / len(known)
    return lo <= f <= hi


def best_shift(pa, pb, max_shift, step=PROF_STEP):
    """Сдвиг δ ≥ 0 (м): профиль b ≈ профиль a, сдвинутый к машине на δ
    (точка на Z в кадре a видна на Z − δ в кадре b). → (δ, совпадение 0…1)
    по лучшему δ; совпадение — доля общих занятых ячеек от занятых в
    перекрытии (Жаккар)."""
    n = int(round(max_shift / step))
    best = (0.0, -1.0)
    for d in range(0, n + 1):
        inter = union = 0
        for i in range(len(pb)):
            j = i + d
            if j >= len(pa):
                break
            a, b = pa[j], pb[i]
            if a < 0 or b < 0:
                continue
            inter += a & b
            union += a | b
        if union == 0:
            continue
        score = inter / union
        if score > best[1] + 1e-9:
            best = (d * step, score)
    return best


def motion_test(profiles, path, min_path=MIN_PATH, max_shift=12.0, min_score=0.35):
    """profiles[k] — продольный профиль линии в кадре k (или None — не
    видна), path[k] — путь машины от первого кадра, м. Для пар кадров,
    между которыми проехали min_path…max_shift−2 м, сравниваем найденный
    сдвиг с путём. → (пар, «бегут», «стоят»)."""
    n = moving = static = 0
    ks = [k for k, p in enumerate(profiles) if p is not None and structured(p)]
    for a_i, a in enumerate(ks):
        for b in ks[a_i + 1:]:
            d = path[b] - path[a]
            if d < min_path:
                continue
            if d > max_shift - 2:
                break
            delta, score = best_shift(profiles[a], profiles[b], max_shift)
            if score < min_score:
                continue
            n += 1
            if abs(delta - d) <= max(MOVE_ABS, MOVE_TOL * d):
                moving += 1
            elif delta <= STATIC_MAX:
                static += 1
            break           # одна пара на кадр a — пары не зависят друг от друга
    return n, moving, static


def strokes(occ, step=PROF_STEP, join=0.5):
    """Профиль занятости → (штрихи, разрывы) в метрах: подряд занятые
    ячейки (дыры до join склеиваются — шов, блик) дают штрих; штрих,
    упёршийся в край профиля, обрезан — его длину не берём, как и
    разрывы рядом с ним."""
    runs = []
    i, n = 0, len(occ)
    while i < n:
        if occ[i] == 1:
            j = i
            while j + 1 < n and occ[j + 1] == 1:
                j += 1
            runs.append([i, j])
            i = j + 1
        else:
            i += 1
    jc = int(round(join / step))
    merged = []
    for r in runs:
        if merged and r[0] - merged[-1][1] - 1 <= jc:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    full = [r for r in merged if r[0] > 0 and r[1] < n - 1
            and occ[r[0] - 1] == 0 and occ[r[1] + 1] == 0]
    st = [(r[1] - r[0] + 1) * step for r in full]
    gp = [(b[0] - a[1] - 1) * step for a, b in zip(merged, merged[1:])
          if a in full and b in full]
    return st, gp


DASH_STROKE = (1.0, 7.0)   # штрих прерывистой по ПДД 1.5–1.6: 1–6 м (+ размытие)
DASH_GAP_MIN = 1.0         # и разрыв не короче (в окне 12 м полный разрыв 9 м виден редко)


def dash_like(profiles):
    """Похожа ли картина линии на штрихи разметки: медиана полных штрихов
    по кадрам в DASH_STROKE и медиана разрывов ≥ DASH_GAP_MIN. Трава,
    тени листвы и фактура обочины тоже «бегут» с машиной (они на земле),
    но дают обрывки по 0,25–0,5 м. → (да/нет/None — нечего мерить, штрих, разрыв)."""
    st, gp = [], []
    for p in profiles:
        if p is None:
            continue
        a, b = strokes(p)
        st += a
        gp += b
    if len(st) < 3:
        return None, None, None
    ms = median(st)
    mg = median(gp) if gp else None
    ok = DASH_STROKE[0] <= ms <= DASH_STROKE[1] and (mg is None or mg >= DASH_GAP_MIN)
    return ok, ms, mg


def path_from_speed(times, kmh):
    """Путь, м, от первого кадра по скорости (км/ч, на каждый кадр)."""
    out = [0.0]
    for i in range(1, len(times)):
        v = (kmh[i] + kmh[i - 1]) / 2 / 3.6
        out.append(out[-1] + v * (times[i] - times[i - 1]))
    return out


def median(vals):
    v = sorted(vals)
    if not v:
        return math.nan
    m = len(v) // 2
    return v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2
