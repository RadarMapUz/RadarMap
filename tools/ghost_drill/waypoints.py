#!/usr/bin/env python3
"""Путевые точки для `simctl location start -`: прямая (линейно в широте и
долготе, как линия профиля учений) через ~100 м — между двумя далёкими
точками simctl сам ведёт не по прямой. Аргументы: lat1 lon1 lat2 lon2
[доля_от доля_до]."""
import sys, math
a = list(map(float, sys.argv[1:5]))
f0 = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
f1 = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
lat1, lon1, lat2, lon2 = a
kx = 111320 * math.cos(math.radians(lat1))
length = math.hypot((lat2 - lat1) * 111320, (lon2 - lon1) * kx)
n = max(2, int(length * (f1 - f0) / 100))
for i in range(n + 1):
    t = f0 + (f1 - f0) * i / n
    print(f"{lat1 + (lat2 - lat1) * t:.6f},{lon1 + (lon2 - lon1) * t:.6f}")
