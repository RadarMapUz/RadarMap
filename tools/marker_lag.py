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
"""
import math
import statistics
import sys

M_PER_DEG = 111320.0


def parse(path):
    fixes, marks, cuts = [], [], []
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
    return fixes, marks, cuts


def local(lat0, a, b):
    k = math.cos(math.radians(lat0))
    return ((b[1] - a[1]) * M_PER_DEG * k, (b[0] - a[0]) * M_PER_DEG)


def honest(a, b):
    dx, dy = local(a[1], (a[1], a[2]), (b[1], b[2]))
    expected = a[3] * (b[0] - a[0])
    return expected > 0 and abs(math.hypot(dx, dy) - expected) <= 0.1 * expected


def lags(fixes, marks):
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
        if not (honest(a, b) and j > 0 and honest(fixes[j - 1], a)):
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
        fixes, marks, cuts = parse(path)
        values = lags(fixes, marks)
        if values:
            report(path, "лаг значка", values)
        else:
            print(f"{path}: лаг значка — нет данных")
        if cuts:
            line = tails(fixes, cuts)
            if line:
                report(path, "хвост линии", line)


if __name__ == "__main__":
    main()
