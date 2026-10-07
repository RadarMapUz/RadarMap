"""Кадры для детекторов: какие моменты ролика вынимать и как.

Шаг — по пути, а не по времени: кадр каждые ~8 м по интегралу скорости из
полосы кадра. На 20 км/ч это кадр в 1,4 с, на 80 км/ч — 2–3 кадра в секунду,
и каждый метр дороги виден примерно одинаково часто. На стоянке путь не
растёт — там не больше одного кадра в 10 с (светофор над перекрёстком
меняет цвет, пока стоим, но сто одинаковых кадров детектору не нужны).

Кадр режется сразу при извлечении: верхняя полоса регистратора (скорость,
время, значки — в том числе красные) и капот (нижние ~20 %) в кадр
детекторов не попадают. Сохраняется JPEG шириной 1280 px.
"""
import bisect
import os
import subprocess

FFMPEG = os.environ.get('FFMPEG', '/opt/homebrew/bin/ffmpeg')
FFPROBE = os.environ.get('FFPROBE', '/opt/homebrew/bin/ffprobe')

STEP_M = 8.0                 # кадр каждые столько метров пути
STOP_KMH = 3.0               # медленнее — «стоим»
STOP_INTERVAL_S = 10.0       # на стоянке — не чаще кадра в столько секунд
MIN_GAP_S = 0.12             # два кадра ближе — один (на 100 км/ч 8 м = 0,29 с)

# Геометрия кадра 1920×1080 регистратора BYD: полоса сверху 70 px,
# капот начинается около 870 px. Кадр детекторов — строки [TOP, BOTTOM).
SRC_W, SRC_H = 1920, 1080
CROP_TOP = 70
CROP_BOTTOM = 864            # 80 % высоты: капот и отражения в нём — мимо
OUT_W = 1280
SCALE = OUT_W / SRC_W        # исходный пиксель → пиксель JPEG
OUT_H = int(round((CROP_BOTTOM - CROP_TOP) * SCALE))
JPEG_Q = 5                   # mjpeg qscale: ≈ качество 80


def speed_profile(ocr_rows, duration):
    """ocr_rows: [(секунда ролика, км/ч или None)] → список км/ч на каждую
    целую секунду 0…ceil(duration); дыры OCR заполняются линейно между
    прочитанными соседями, края — ближайшим. Ничего не прочиталось — None."""
    n = int(duration) + 1
    known = sorted((int(t), v) for t, v in ocr_rows if v is not None and 0 <= t < n + 1)
    if not known:
        return None
    out = [None] * n
    for t, v in known:
        if t < n:
            out[t] = float(v)
    ks = [t for t, _ in known if t < n]
    if not ks:
        return [float(known[-1][1])] * n
    for i in range(n):
        if out[i] is not None:
            continue
        j = bisect.bisect_left(ks, i)
        if j == 0:
            out[i] = out[ks[0]]
        elif j >= len(ks):
            out[i] = out[ks[-1]]
        else:
            a, b = ks[j - 1], ks[j]
            out[i] = out[a] + (out[b] - out[a]) * (i - a) / (b - a)
    return out


def select_positions(profile, duration, step_m=STEP_M, stop_kmh=STOP_KMH,
                     stop_interval=STOP_INTERVAL_S, min_gap=MIN_GAP_S, dt=0.05):
    """profile: км/ч на каждую секунду (speed_profile) → позиции кадров в ролике, с.

    Путь интегрируется мелким шагом dt по линейно интерполированной скорости;
    кадр — каждый раз, когда путь перешагнул очередные step_m. На стоянке
    (скорость ниже stop_kmh) — кадр, если с прошлого прошло ≥ stop_interval.
    Первый кадр — в начале ролика. Без OCR скорости (profile None) — кадр раз
    в 2 с: ехали или стояли, неизвестно, а пропустить участок хуже."""
    if profile is None:
        return [round(i * 2.0, 3) for i in range(int(duration // 2) + 1) if i * 2.0 < duration]
    out = [0.0]
    dist = 0.0
    next_mark = step_m
    last = 0.0
    t = 0.0
    n = len(profile)

    def v_at(x):
        i = int(x)
        if i >= n - 1:
            return profile[-1]
        k = x - i
        return profile[i] + (profile[i + 1] - profile[i]) * k

    while t + dt <= duration:
        v0, v1 = v_at(t), v_at(t + dt)
        dist += (v0 + v1) / 2 / 3.6 * dt
        t += dt
        if dist >= next_mark:
            if t - last >= min_gap:
                out.append(round(t, 3))
                last = t
            # Если ехали так быстро, что перешагнули несколько меток, —
            # следующая метка от текущего пути, а не очередь «долгов».
            next_mark = dist + step_m
        elif v1 < stop_kmh and t - last >= stop_interval:
            out.append(round(t, 3))
            last = t
    return out


def frame_times(path):
    """Время (pts) каждого кадра видео по пакетам — быстро, без декодирования.
    У регистратора BYD частота плавающая (~25 к/с при заявленных 30)."""
    out = subprocess.run([FFPROBE, '-v', 'error', '-select_streams', 'v:0',
                          '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', path],
                         capture_output=True, text=True, check=True).stdout
    ts = []
    for line in out.split():
        line = line.strip().strip(',')
        try:
            ts.append(float(line))
        except ValueError:
            continue
    ts.sort()
    return ts


def nearest_indices(times, positions):
    """Позиции (с) → номера ближайших кадров; повторы схлопываются.
    → [(номер кадра, его время)] по возрастанию."""
    out = {}
    for p in positions:
        j = bisect.bisect_left(times, p)
        cands = [k for k in (j - 1, j) if 0 <= k < len(times)]
        if not cands:
            continue
        k = min(cands, key=lambda k: abs(times[k] - p))
        out[k] = times[k]
    return sorted(out.items())


def frame_name(clock):
    """Имя файла кадра = его время по часам регистратора, с миллисекундами."""
    from datetime import datetime, timedelta, timezone
    dt = datetime.fromtimestamp(clock, timezone(timedelta(hours=5)))
    return dt.strftime('%Y%m%d-%H%M%S-') + f'{dt.microsecond // 1000:03d}.jpg'


def _sum_tree(terms):
    """«a+b+c+…» сбалансированным деревом в скобках: у парсера выражений
    ffmpeg ограничена глубина, и плоская сумма из ~120 слагаемых уже не
    разбирается («Cannot allocate memory»)."""
    if len(terms) == 1:
        return terms[0]
    mid = len(terms) // 2
    return f'({_sum_tree(terms[:mid])}+{_sum_tree(terms[mid:])})'


def extract(path, indices, out_paths, tmpdir):
    """Вынимает кадры с номерами indices (по возрастанию) в out_paths.
    Фильтр — select по номеру кадра, затем обрезка полосы и капота и масштаб."""
    if not indices:
        return 0
    script = os.path.join(tmpdir, 'select.txt')
    expr = _sum_tree([f'eq(n\\,{i})' for i in indices])
    with open(script, 'w') as f:
        f.write(f"select='{expr}',crop={SRC_W}:{CROP_BOTTOM - CROP_TOP}:0:{CROP_TOP},"
                f"scale={OUT_W}:{OUT_H}")
    pattern = os.path.join(tmpdir, 'f_%06d.jpg')
    subprocess.run([FFMPEG, '-v', 'error', '-nostdin', '-y',
                    '-i', path, '-filter_script:v', script, '-fps_mode', 'passthrough',
                    '-q:v', str(JPEG_Q), pattern], check=True)
    made = sorted(n for n in os.listdir(tmpdir) if n.startswith('f_') and n.endswith('.jpg'))
    if len(made) != len(indices):
        # select не попал в какие-то кадры — сопоставлять по порядку нельзя
        for n in made:
            os.remove(os.path.join(tmpdir, n))
        raise RuntimeError(f'ffmpeg вынул {len(made)} кадров вместо {len(indices)}')
    for n, dst in zip(made, out_paths):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(os.path.join(tmpdir, n), dst)
    return len(made)


def to_src(x, y):
    """Пиксель JPEG кадра детекторов → пиксель исходного кадра 1920×1080."""
    return x / SCALE, y / SCALE + CROP_TOP
