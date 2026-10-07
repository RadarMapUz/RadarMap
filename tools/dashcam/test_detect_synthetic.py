#!/usr/bin/env python3
"""Фильтры черновых детекторов на синтетических кадрах: горящая секция в
тёмном корпусе — светофор; то же пятно без корпуса (вывеска) и пара красных
пятен у горизонта (задние фонари) — нет; синий квадрат с белым треугольником —
переход, синий круг — не переход. Нужен собранный Swift CLI (detect.swift);
без него тест пропускается."""
import json
import os
import struct
import subprocess
import tempfile
import unittest
import zlib

import detect

W, H = 1280, 529
SKY = (150, 180, 210)


def png(path, px):
    raw = b''.join(b'\x00' + bytes(c for p in row for c in p) for row in px)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def canvas():
    return [[SKY if y < 290 else (90, 90, 90) for x in range(W)] for y in range(H)]


def rect(px, x0, y0, x1, y1, c):
    for y in range(y0, y1):
        for x in range(x0, x1):
            px[y][x] = c


def disc(px, cx, cy, r, c, core=None):
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            d2 = (x - cx) ** 2 + (y - cy) ** 2
            if d2 <= r * r:
                px[y][x] = core if core and d2 <= (r * 0.4) ** 2 else c


def run(px):
    binary = detect.BIN
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'f.png')
        png(p, px)
        lst = os.path.join(d, 'l.txt')
        with open(lst, 'w') as f:
            f.write(p)
        out = subprocess.run([binary, 'detect', lst], capture_output=True, text=True, check=True).stdout
    return json.loads(out.strip().splitlines()[-1])['d']


@unittest.skipUnless(os.path.exists(detect.BIN), 'Swift CLI detect не собран')
class SyntheticDetectorTest(unittest.TestCase):
    def test_green_lamp_in_dark_housing(self):
        px = canvas()
        rect(px, 600, 80, 630, 170, (25, 25, 28))              # корпус
        disc(px, 615, 152, 8, (40, 230, 170), (230, 255, 245))  # нижняя (зелёная) секция горит
        d = [x for x in run(px) if x['cls'] == 'traffic_light']
        self.assertEqual(len(d), 1, d)
        self.assertEqual(d[0]['color'], 'green')

    def test_lamp_without_housing_is_not_light(self):
        px = canvas()
        disc(px, 615, 152, 8, (40, 230, 170), (230, 255, 245))
        self.assertEqual([x for x in run(px) if x['cls'] == 'traffic_light'], [])

    def test_tail_light_pair_below_horizon(self):
        px = canvas()
        rect(px, 560, 300, 720, 340, (20, 20, 22))
        disc(px, 580, 318, 6, (240, 30, 40), (255, 220, 220))
        disc(px, 700, 318, 6, (240, 30, 40), (255, 220, 220))
        self.assertEqual([x for x in run(px) if x['cls'] == 'traffic_light'], [])

    def test_crossing_square_vs_blue_circle(self):
        px = canvas()
        rect(px, 300, 100, 340, 140, (20, 80, 200))
        for y in range(105, 136):                               # белый треугольник вершиной вверх
            half = int((y - 105) / 31 * 17)
            for x in range(320 - half, 320 + half + 1):
                px[y][x] = (245, 245, 245)
        disc(px, 900, 120, 20, (20, 80, 200))
        rect(px, 896, 108, 904, 132, (245, 245, 245))
        d = [x for x in run(px) if x['cls'] == 'crossing']
        self.assertEqual(len(d), 1, d)
        self.assertLess(abs(d[0]['x'] - 300), 3)


if __name__ == '__main__':
    unittest.main()
