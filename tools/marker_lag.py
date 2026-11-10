#!/usr/bin/env python3
"""Лаг значка «я» на симуляторной поездке (25.B).

    python3 tools/marker_lag.py log.txt [log2.txt ...]

Журнал — `log stream` приложения, запущенного с `-logMarker` (DEBUG):
строки «МЕТКА фикс <t фикса> <t приёма> <lat> <lon> <м/с>» и
«МЕТКА знак <t> <lat> <lon> …». Истинная точка в момент t — линейная
интерполяция фиксов по их собственному времени (симулятор ведёт машину
равномерно между фиксами). Лаг — проекция «истина − значок» на направление
движения, метры: плюс — значок позади, минус — впереди. Поперечный сдвиг
(прижим к линии маршрута) в лаг не входит.

Линия маршрута (27.A): строки «МЕТКА линия <t> <lat значка> <lon значка>
<lat среза> <lon среза>» — где на экране начинается непройденная (синяя)
линия. «Хвост» — проекция «значок − срез» на направление движения, метры:
плюс — синяя линия начинается ПОЗАДИ центра значка (торчит из-под машины
назад), минус — впереди. Нос значка впереди центра на полкорпуса, так что
хвост от 0 до −полкорпуса не виден вовсе: линия выходит из-под машины.

Лента «Вождения 3D» (85): строки «МЕТКА лента <t> <lat значка> <lon значка>
<lat границы> <lon границы>» — где начинается показанная лента; хвост ленты
считается так же, как хвост линии.

Плавность (27.A): строки «МЕТКА кадр <t> <значок> <срез> <центр камеры>»
пишутся на каждом кадре хода значка. По каждой из трёх точек: сколько кадров
она сдвинулась НАЗАД вдоль движения больше чем на сантиметр (в движении цель
— 0), наибольший сдвиг за кадр и наибольший «рывок» — изменение скорости
между соседними окнами по 0,1 с, м/с². Поездка с шумом GPS (`-noisyDrive`)
пишет «МЕТКА истина <t> <lat> <lon> <м/с>» — тогда истина берётся из них, а
не из шумных фиксов. Последние два поля кадра — точка значка на экране (pt):
при плавном ходе камеры и значка она почти стоит; её дрожь между кадрами —
то, что глаз видит как «дёргается».
"""
import math
import statistics
import sys

M_PER_DEG = 111320.0


def parse(path):
    fixes, marks, cuts, frames, truth, ribbon = [], [], [], [], [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if "МЕТКА" not in line:
                continue
            parts = line.split("МЕТКА", 1)[1].split()
            if parts[0] == "фикс":
                fixes.append((float(parts[1]), float(parts[3]), float(parts[4]), float(parts[5])))
            elif parts[0] == "знак":
                marks.append((float(parts[1]), float(parts[2]), float(parts[3])))
            elif parts[0] == "линия":
                cuts.append(tuple(float(x) for x in parts[1:6]))
            elif parts[0] == "лента":
                ribbon.append(tuple(float(x) for x in parts[1:6]))
            elif parts[0] == "кадр":
                frames.append(tuple(float(x) for x in parts[1:10]))
            elif parts[0] == "истина":
                truth.append((float(parts[1]), float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4])))
    if truth:
        fixes = [(t, lat, lon, v) for t, _, lat, lon, v in truth]
    return fixes, marks, cuts, frames, bool(truth), ribbon


def local(lat0, a, b):
    k = math.cos(math.radians(lat0))
    return ((b[1] - a[1]) * M_PER_DEG * k, (b[0] - a[0]) * M_PER_DEG)


def honest(a, b):
    dx, dy = local(a[1], (a[1], a[2]), (b[1], b[2]))
    expected = a[3] * (b[0] - a[0])
    return expected > 0 and abs(math.hypot(dx, dy) - expected) <= 0.1 * expected


def lags(fixes, marks, trusted=False):
    out = []
    j = 0
    for t, lat, lon in marks:
        while j + 1 < len(fixes) and fixes[j + 1][0] <= t:
            j += 1
        if j + 1 >= len(fixes) or fixes[j][0] > t:
            continue
        a, b = fixes[j], fixes[j + 1]
        if b[0] - a[0] > 2.5 or a[3] < 1:   # провал фиксов или стоянка — не меряем
            continue
        # `simctl location start` замирает на каждой путевой точке, а скорость
        # фикса пишет прежнюю: такой интервал — не равномерное движение, и
        # истина между фиксами там неизвестна. Меряем, где фикс честен
        # (сдвиг = скорость × время на этом и на прошлом интервале).
        if not trusted and not (honest(a, b) and j > 0 and honest(fixes[j - 1], a)):
            continue
        s = (t - a[0]) / (b[0] - a[0])
        true = (a[1] + (b[1] - a[1]) * s, a[2] + (b[2] - a[2]) * s)
        dx, dy = local(true[0], (a[1], a[2]), (b[1], b[2]))
        n = math.hypot(dx, dy)
        if n < 0.5:
            continue
        ex, ey = local(true[0], (lat, lon), true)
        out.append(((ex * dx + ey * dy) / n, a[3] * 3.6))
    return out


def tails(fixes, cuts):
    """Хвост синей линии позади центра значка, метры (см. шапку)."""
    out = []
    j = 0
    for t, mlat, mlon, clat, clon in cuts:
        while j + 1 < len(fixes) and fixes[j + 1][0] <= t:
            j += 1
        if j + 1 >= len(fixes) or fixes[j][0] > t:
            continue
        a, b = fixes[j], fixes[j + 1]
        if b[0] - a[0] > 2.5 or a[3] < 1:   # провал фиксов или стоянка
            continue
        dx, dy = local(a[1], (a[1], a[2]), (b[1], b[2]))
        n = math.hypot(dx, dy)
        if n < 0.5:
            continue
        ex, ey = local(mlat, (clat, clon), (mlat, mlon))
        out.append(((ex * dx + ey * dy) / n, a[3] * 3.6))
    return out


def direction(fixes, t, j):
    """Единичный вектор движения (восток, север) и скорость истины в момент t."""
    while j + 1 < len(fixes) and fixes[j + 1][0] <= t:
        j += 1
    if j + 1 >= len(fixes) or fixes[j][0] > t:
        return None, j
    a, b = fixes[j], fixes[j + 1]
    if b[0] - a[0] > 2.5 or a[3] < 1:
        return None, j
    dx, dy = local(a[1], (a[1], a[2]), (b[1], b[2]))
    n = math.hypot(dx, dy)
    if n < 0.5:
        return None, j
    return (dx / n, dy / n), j


def smoothness(fixes, frames, index):
    """Точка кадра (index: 1 — значок, 3 — срез, 5 — центр камеры): кадров
    назад, наибольший сдвиг за кадр, наибольший рывок по окнам 0,1 с."""
    backward, max_step, steps = 0, 0.0, []
    j = 0
    for f0, f1 in zip(frames, frames[1:]):
        dt = f1[0] - f0[0]
        if dt <= 0 or dt > 0.2:
            continue
        unit, j = direction(fixes, f1[0], j)
        if unit is None:
            continue
        p0 = (f0[index], f0[index + 1])
        p1 = (f1[index], f1[index + 1])
        dx, dy = local(p0[0], p0, p1)
        along = dx * unit[0] + dy * unit[1]
        if along < -0.01:
            backward += 1
        max_step = max(max_step, math.hypot(dx, dy))
        steps.append((f1[0], along))
    # Скорость по окнам 0,1 с, рывок — разница соседних окон.
    speeds, window, acc, start = [], [], 0.0, None
    for t, d in steps:
        if start is None:
            start = t - 1e-3
        acc += d
        if t - start >= 0.1:
            speeds.append((t, acc / (t - start)))
            acc, start = 0.0, t
    jerk = 0.0
    for (t0, v0), (t1, v1) in zip(speeds, speeds[1:]):
        if 0 < t1 - t0 < 0.25:
            jerk = max(jerk, abs(v1 - v0) / (t1 - t0))
    return backward, len(steps), max_step, jerk


def screen(frames):
    """Дрожь значка на экране: сдвиг за кадр (p95 и макс, pt) и рывок —
    изменение скорости на экране между окнами 0,1 с, pt/с²."""
    steps, speeds = [], []
    rows = [f for f in frames if len(f) >= 9]
    for f0, f1 in zip(rows, rows[1:]):
        dt = f1[0] - f0[0]
        if dt <= 0 or dt > 0.2:
            continue
        steps.append(math.hypot(f1[7] - f0[7], f1[8] - f0[8]))
    if not steps:
        return None
    win, start, acc = [], None, (0.0, 0.0)
    for f0, f1 in zip(rows, rows[1:]):
        dt = f1[0] - f0[0]
        if dt <= 0 or dt > 0.2:
            start = None
            continue
        if start is None:
            start, acc = f0[0], (0.0, 0.0)
        acc = (acc[0] + f1[7] - f0[7], acc[1] + f1[8] - f0[8])
        if f1[0] - start >= 0.1:
            speeds.append((f1[0], acc[0] / (f1[0] - start), acc[1] / (f1[0] - start)))
            start, acc = f1[0], (0.0, 0.0)
    jerk = 0.0
    for a, b in zip(speeds, speeds[1:]):
        if 0 < b[0] - a[0] < 0.25:
            jerk = max(jerk, math.hypot(b[1] - a[1], b[2] - a[2]) / (b[0] - a[0]))
    steps.sort()
    return steps[int(len(steps) * 0.95)], steps[-1], jerk


def report(path, name, values):
    along = sorted(v for v, _ in values)
    speeds = [s for _, s in values]
    p95 = along[min(len(along) - 1, int(len(along) * 0.95))]
    p5 = along[int(len(along) * 0.05)]
    print(f"{path}: {name} — {len(values)} замеров, {statistics.median(speeds):.0f} км/ч: "
          f"медиана {statistics.median(along):.1f} м, среднее {statistics.mean(along):.1f} м, "
          f"p5 {p5:.1f} м, p95 {p95:.1f} м, макс {along[-1]:.1f} м")


def main():
    for path in sys.argv[1:]:
        fixes, marks, cuts, frames, trusted, ribbon = parse(path)
        values = lags(fixes, marks, trusted)
        if values:
            report(path, "лаг значка", values)
        else:
            print(f"{path}: лаг значка — нет данных")
        if cuts:
            line = tails(fixes, cuts)
            if line:
                report(path, "хвост линии", line)
        if ribbon:
            band = tails(fixes, ribbon)
            if band:
                report(path, "хвост ленты 3D", band)
        if frames:
            for name, index in (("значок", 1), ("граница линии", 3), ("камера", 5)):
                back, total, step, jerk = smoothness(fixes, frames, index)
                print(f"{path}: плавность, {name} — {total} кадров: назад {back}, "
                      f"скачок ≤ {step:.2f} м/кадр, рывок ≤ {jerk:.1f} м/с²")
            on_screen = screen(frames)
            if on_screen:
                p95, top, jerk = on_screen
                print(f"{path}: значок на экране — сдвиг за кадр p95 {p95:.2f} pt, макс {top:.1f} pt, "
                      f"рывок ≤ {jerk:.0f} pt/с²")


if __name__ == "__main__":
    main()
