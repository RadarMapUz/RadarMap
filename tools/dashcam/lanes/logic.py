"""Чистая логика полос — без картинок, только числа (её и тестируем).

Линия — (x, kind, fill): поперечное положение в метрах на 8 м впереди
(минус — слева от машины), тип 'solid'/'dashed'/'edge' (край проезжей
части: асфальт только с одной стороны — бордюр) и заполнение вдоль.
"""
from collections import Counter
import math

LANE_MIN, LANE_MAX = 2.6, 4.2      # одна полоса: ширина в м (норма 3–3,75;
                                   # 4,0 по ТЗ + 0,2 на погрешность замера)
PLAUSIBLE = (3.0, 3.8)              # «правдоподобно» в строгом смысле
# За такую линию цепочка полос не идёт. Слева сплошная — обычно ось
# дороги (дальше встречка); справа встречки нет, а сплошная между попутными
# рядами у перекрёстков и на проспектах Ташкента — обычное дело, поэтому
# справа останавливает только край (бордюр).
BOUNDARY = ("solid", "edge")
BOUNDARY_RIGHT = ("edge",)
SOLID_FILL = 0.62                   # сплошная: заполнено ≥ этой доли
SOLID_MIN_LEN = 4.0                # …и краски вдоль хотя бы столько, м (один
                                   # видимый штрих — ещё не сплошная)
SOLID_MAX_GAP = 1.2                 # …и нет разрыва длиннее, м


def runs(occ):
    """Список длин подряд идущих True и False: [(значение, длина)]."""
    out = []
    for o in occ:
        if out and out[-1][0] == o:
            out[-1][1] += 1
        else:
            out.append([o, 1])
    return [(bool(v), n) for v, n in out]


def classify(occ, step_m):
    """occ — заполненность ячеек вдоль линии (True — есть краска) по
    видимому участку, шаг step_m. → ('solid'|'dashed'|None, fill)."""
    if not occ:
        return None, 0.0
    fill = sum(occ) / len(occ)
    # Внутренние разрывы: краевые пустоты — это просто конец видимости.
    r = runs(occ)
    while r and not r[0][0]:
        r.pop(0)
    while r and not r[-1][0]:
        r.pop()
    gaps = [n * step_m for v, n in r if not v]
    max_gap = max(gaps) if gaps else 0.0
    painted = sum(n for v, n in r if v) * step_m
    # Меньше одного штриха краски — не линия (даже если видимый участок
    # короткий и доля большая). Одного штриха достаточно: на 6–20 м
    # прерывистая с шагом 12 м даёт иногда ровно один.
    if painted < 0.9:
        return None, fill
    # Сплошная решается по заполнению между первым и последним штрихом:
    # пустота у краёв окна — конец видимости, а не разрыв.
    span_cells = sum(n for _, n in r)
    inner = (painted / step_m) / span_cells if span_cells else 0.0
    if inner >= SOLID_FILL and max_gap <= SOLID_MAX_GAP and painted >= SOLID_MIN_LEN:
        return "solid", fill
    if len(gaps) >= 1 and painted >= 0.8:
        return "dashed", fill
    # Один короткий штрих без разрывов — тоже прерывистая (видели один).
    if painted >= 0.8:
        return "dashed", fill
    return None, fill


def dash_runs(zs, z0, z1, join=0.35, margin=0.3, row_step=None, min_stroke=0.3):
    """Продольные координаты точек краски одной линии (м) → (штрихи,
    разрывы) в метрах. Точки ближе join — один штрих. Учитываются только
    штрихи целиком в видимом окне [z0, z1] (с запасом margin) и разрывы
    между двумя такими штрихами: обрезанный краем кадра штрих короче
    настоящего. row_step(z) — продольный шаг одной строки кадра на этой
    дальности: вдали строки редкие, и сплошной штрих иначе рассыпается.
    Штрих короче min_stroke — шум, не штрих (его точки отбрасываются)."""
    zs = sorted(zs)
    if not zs:
        return [], []
    runs = []
    a = b = zs[0]
    for z in zs[1:]:
        j = join if row_step is None else max(join, 2.0 * row_step(z))
        if z - b <= j:
            b = z
        else:
            runs.append((a, b))
            a = b = z
    runs.append((a, b))
    runs = [(a, b) for a, b in runs if b - a >= min_stroke]
    full = [(a, b) for a, b in runs if a >= z0 + margin and b <= z1 - margin]
    strokes = [b - a for a, b in full]
    gaps = []
    for (a1, b1), (a2, b2) in zip(runs, runs[1:]):
        if (a1, b1) in full and (a2, b2) in full:
            gaps.append(a2 - b1)
    return strokes, gaps


def lanes_in_gap(w):
    """Сколько полос помещается между соседними линиями: 1, 2 (потерянная
    линия посередине) или 0 — неправдоподобно."""
    if LANE_MIN <= w <= LANE_MAX:
        return 1
    if 2 * LANE_MIN <= w <= 2 * LANE_MAX:
        return 2
    return 0


EDGE_SNAP = 0.6      # линия ближе к краю — кромка бордюра
UNMARKED_MAX = 5.0   # крайний ряд без разметки у бордюра — не шире, м
UNDER_CAR = 0.7      # линия ближе к оси машины — мы на ней (перестроение)
EDGE_A = 0.2          # столбец «не асфальт», если асфальта в нём меньше
EDGE_RUN = 0.6        # край дороги — столько метров подряд не асфальта


def road_extent(xs, a, step):
    """Поперечный профиль асфальта a(x) (доля по Z, nan — не видно) →
    (левый край, правый край) проезжей части от машины (x=0) наружу:
    первое место, где EDGE_RUN метров подряд не асфальт. Не видно края —
    None с этой стороны (кадр кончился раньше, чем дорога)."""
    need = max(1, int(round(EDGE_RUN / step)))
    i0 = min(range(len(xs)), key=lambda i: abs(xs[i]))
    res = []
    for direction in (-1, 1):
        run = 0
        edge = None
        i = i0
        while 0 <= i < len(xs):
            v = a[i]
            if v != v:          # nan — дальше не видно
                break
            if v < EDGE_A:
                run += 1
                if run >= need:
                    edge = xs[i - direction * (need - 1)] - direction * step / 2
                    break
            else:
                run = 0
            i += direction
        res.append(edge)
    return tuple(res)


def lane_layout(lines, extent=(None, None)):
    """lines: [(x, kind, fill)] → dict с полосами или None.

    Своя полоса — между ближайшими линиями слева и справа от 0. Дальше
    цепочка наружу, пока шаг правдоподобен; край (асфальт с одной
    стороны) — граница, слева ещё и сплошная (ось дороги), за них не идём.
    extent — края асфальта (road_extent): линии за краем — это тротуар,
    их не считаем; между последней прерывистой линией и краем бывает
    крайняя полоса без разметки (у бордюра в Ташкенте это обычное дело) —
    её добавляем, если ширина правдоподобна.
    Итог: всего полос, полос слева/справа от своей.
    """
    le, re_ = (None if e is None else float(e) for e in extent)
    xs = sorted(((float(l[0]),) + tuple(l[1:]) for l in lines), key=lambda l: l[0])
    if le is not None:
        xs = [l for l in xs if l[0] > le - 0.3]
    if re_ is not None:
        xs = [l for l in xs if l[0] < re_ + 0.3]
    # Левый край (бордюр разделительной/тротуара) — сам граница полосы:
    # на проспектах своя левая полоса часто идёт от бордюра без линии.
    # Линия в EDGE_SNAP от края — это кромка самого бордюра, не разметка.
    # Правый край так не вставляем: при проверке глазами он чаще ложился
    # на припаркованные машины и тротуар, чем на бордюр.
    if le is not None and le < -UNDER_CAR:
        xs = [l for l in xs if abs(l[0] - le) > EDGE_SNAP]
        xs = sorted(xs + [(le, "edge", 1.0)], key=lambda l: l[0])
    # Линия под машиной — перестроение (или блик в стекле): кадр не годится.
    if any(abs(l[0]) < UNDER_CAR for l in xs):
        return None
    left = [l for l in xs if l[0] < 0]
    right = [l for l in xs if l[0] >= 0]
    if not left or not right:
        return None
    # Своя полоса: ближайшая пара с правдоподобной шириной; одну ложную
    # линию рядом (блик, шов асфальта) пропускаем, но не больше одной.
    pair = None
    # Своя может быть крайней у бордюра (там ряд шире, до UNMARKED_MAX), и
    # тогда «правая линия» — это сам бордюр.
    for li, ri in ((1, 0), (1, 1), (2, 0)):
        if len(left) >= li and len(right) > ri and \
                LANE_MIN <= right[ri][0] - left[-li][0] <= UNMARKED_MAX:
            pair = (li, ri)
            break
    if pair is None:
        return None
    left = left[:len(left) - pair[0] + 1]
    right = right[pair[1]:]
    own_w = right[0][0] - left[-1][0]
    n_left = 0
    cur = left[-1]
    widths = [own_w]
    cand = list(reversed(left[:-1]))
    i = 0
    while i < len(cand):
        if cur[1] in BOUNDARY:
            break
        k = lanes_in_gap(cur[0] - cand[i][0])
        if k == 0 and i + 1 < len(cand):
            # одна ложная линия в цепочке (бок машины, тень) — пропускаем
            k2 = lanes_in_gap(cur[0] - cand[i + 1][0])
            if k2:
                i, k = i + 1, k2
        if k == 0:
            break
        n_left += k
        widths.append((cur[0] - cand[i][0]) / k)
        cur = cand[i]
        i += 1
    cur_left = cur
    n_right = 0
    cur = right[0]
    cand = right[1:]
    i = 0
    while i < len(cand):
        if cur[1] in BOUNDARY_RIGHT:
            break
        k = lanes_in_gap(cand[i][0] - cur[0])
        if k == 0 and i + 1 < len(cand):
            k2 = lanes_in_gap(cand[i + 1][0] - cur[0])
            if k2:
                i, k = i + 1, k2
        if k == 0:
            break
        n_right += k
        widths.append((cand[i][0] - cur[0]) / k)
        cur = cand[i]
        i += 1
    # Крайняя полоса без разметки — максимум одна с каждой стороны, и край
    # тогда не дальше UNMARKED_MAX от последней линии (у бордюра ряд бывает
    # шире, до 4,5 м). Край дальше — это уже не край, а тротуар/плитка,
    # похожие на асфальт: такой край считаем ненадёжным (None).
    unmarked = 0
    gl = cur_left[0] - le if le is not None else None
    gr = re_ - cur[0] if re_ is not None else None
    if gl is not None and cur_left[1] not in BOUNDARY and LANE_MIN <= gl <= UNMARKED_MAX:
        n_left += 1
        unmarked += 1
    if gr is not None and cur[1] not in BOUNDARY_RIGHT and LANE_MIN <= gr <= UNMARKED_MAX:
        n_right += 1
        unmarked += 1
    return {
        "left_edge_ok": bool(gl is not None and gl <= UNMARKED_MAX),
        "right_edge_ok": bool(gr is not None and gr <= UNMARKED_MAX),
        "left_line": cur_left[0],
        "left_kind": cur_left[1],
        "right_line": cur[0],
        "unmarked": unmarked,
        "lanes": n_left + 1 + n_right,
        "left": n_left,
        "right": n_right,
        "own_width": own_w,
        "mean_width": sum(widths) / len(widths),
        "plausible": bool(PLAUSIBLE[0] <= own_w <= PLAUSIBLE[1]),
    }


# ── согласованность во времени ────────────────────────────────────────

TRACK_WIN = 3          # соседей с каждой стороны (кадры через ~8 м)
TRACK_DIST = 30.0      # сосед не дальше, м
TRACK_TURN = 6.0       # и курс отличается не больше, °
TRACK_TOL = 0.45       # линия «та же», если поперёк ближе, м
TRACK_MIN = 3          # столько соседей должны видеть линию


def _dist_m(a, b):
    dy = (a[0] - b[0]) * 111_320.0
    dx = (a[1] - b[1]) * 111_320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def track_filter(frames):
    """frames: [{'lat','lon','course','lines':[[x, kind, ...], ...]}] по
    времени → новые списки линий: линия остаётся, если её видят хотя бы
    TRACK_MIN соседних кадров (±TRACK_WIN, ближе TRACK_DIST, курс в
    пределах TRACK_TURN) на том же поперечном месте ±TRACK_TOL. Разметка
    держится десятки метров, а бок машины, тень или блик — один кадр.
    Кадр, у которого соседей вообще меньше TRACK_MIN, не судим: его линии
    уходят все (лучше без оценки, чем одиночный шум)."""
    out = []
    for i, f in enumerate(frames):
        nb = []
        for j in range(max(0, i - TRACK_WIN), min(len(frames), i + TRACK_WIN + 1)):
            if j == i:
                continue
            g = frames[j]
            if _dist_m((f["lat"], f["lon"]), (g["lat"], g["lon"])) > TRACK_DIST:
                continue
            d = (f["course"] - g["course"] + 180) % 360 - 180
            if abs(d) > TRACK_TURN:
                continue
            nb.append(g)
        kept = []
        if len(nb) >= TRACK_MIN:
            for ln in f["lines"]:
                sup = sum(1 for g in nb
                          if any(abs(ln[0] - m[0]) <= TRACK_TOL for m in g["lines"]))
                if sup >= TRACK_MIN:
                    kept.append(ln)
        out.append(kept)
    return out


# ── обочина: край, ширина, разделительная, тротуар ────────────────────

def strip_kind(green, bright, asphalt, textured):
    """Что за краем асфальта — по долям пикселей полосы 0,3–2 м за краем:
    green — зелень, bright — светлый серый (бетон бордюра/плитка),
    asphalt — тот же асфальт, textured — фактурное тёмное (ограждение,
    машины, кусты в тени). → 'газон'|'бордюр'|'асфальт'|'ограждение'|None."""
    if green >= 0.25:
        return "газон"
    if bright >= 0.35:
        return "бордюр"
    if asphalt >= 0.6:
        return "асфальт"
    if textured >= 0.5:
        return "ограждение"
    return None


def median_kind(left_line_kind, left_line_yellow, strip):
    """Тип разделительной слева. Физическая (бордюр/газон/ограждение) — по
    полосе за левым краем; иначе по левой линии своей цепочки: сплошная —
    «сплошная» (двойная сливается в одну, MIN_SEP), прерывистая/нет — «нет»."""
    if strip in ("газон", "бордюр", "ограждение"):
        return strip
    if left_line_kind == "solid":
        return "сплошная"
    if left_line_kind == "edge":
        return "край"
    return "нет"


def carriageway_width(left_edge, right_edge, left_axis=None):
    """Ширина проезжей части нашего направления: от правого края до левого
    края (бордюра/разделительной) либо до осевой (сплошной слева), если
    физического края слева не видно. Неправдоподобно (< 2,6 или > 25 м) —
    None."""
    if right_edge is None:
        return None
    left = left_edge if left_edge is not None else left_axis
    if left is None:
        return None
    w = right_edge - left
    return w if 2.6 <= w <= 25 else None


def model_width(osm_lanes, highway, oneway):
    """Ширина нашей модели (server/build_roads.py: road_width_meters) для
    одного направления: у двусторонней — половина."""
    code = CLASS_CODES.get(highway)
    if code is None:
        return None
    lanes = osm_lanes
    if not lanes:
        lanes = DEFAULT_LANES.get(code, (1, 2))[0 if oneway else 1]
    w = lanes * LANE_METERS.get(code, 3.5)
    return w if oneway else w / 2


# Копия констант server/build_roads.py (тот модуль тянет за собой сборку
# тайлов; здесь нужна только формула ширины). Тест сверяет с оригиналом.
CLASS_CODES = {
    "motorway": 1, "motorway_link": 1, "trunk": 2, "trunk_link": 2,
    "primary": 3, "primary_link": 3, "secondary": 4, "secondary_link": 4,
    "tertiary": 5, "tertiary_link": 5,
    "residential": 6, "unclassified": 6, "living_street": 6, "service": 7,
}
DEFAULT_LANES = {1: (3, 6), 2: (3, 6), 3: (3, 6),
                 4: (2, 4), 5: (2, 4), 6: (1, 2), 7: (1, 1)}
LANE_METERS = {1: 3.75, 2: 3.75, 3: 3.75, 4: 3.5, 5: 3.5, 6: 3.5, 7: 4.5}


def robust_value(values, min_n=3, max_spread=1.5):
    """Медиана чисел участка, если их не меньше min_n и межквартильный
    размах не больше max_spread. → (медиана|None, размах, n)."""
    vals = sorted(v for v in values if v is not None)
    n = len(vals)
    if n < min_n:
        return None, None, n
    q1 = vals[n // 4]
    q3 = vals[(3 * n) // 4 if n > 3 else n - 1]
    med = vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2
    spread = q3 - q1
    return (med if spread <= max_spread else None), spread, n


# ── агрегирование по участкам ─────────────────────────────────────────

SEG_M = 50.0


def seg_key(lat, lon, course, seg_m=SEG_M):
    """Участок: ячейка ~seg_m по положению + курс с шагом 45° (встречные
    направления — разные участки, у них своё число полос)."""
    dlat = seg_m / 111_320.0
    dlon = seg_m / (111_320.0 * math.cos(math.radians(lat)))
    c = int(((course % 360) + 22.5) // 45) % 8
    return (int(math.floor(lat / dlat)), int(math.floor(lon / dlon)), c)


def robust_count(values, min_n=3, min_agree=0.6):
    """Число полос участка по оценкам кадров: мода, если за неё не меньше
    min_agree голосов и самих голосов не меньше min_n. → (n|None,
    уверенность=доля голосов за моду, голосов)."""
    vals = [v for v in values if v is not None]
    if len(vals) < min_n:
        return None, 0.0, len(vals)
    c = Counter(vals)
    (top, cnt), = c.most_common(1)
    share = cnt / len(vals)
    if share < min_agree:
        return None, share, len(vals)
    return top, share, len(vals)
