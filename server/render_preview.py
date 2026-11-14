#!/usr/bin/env python3
"""Снимок места из готовых MVT-тайлов — без браузера и без телефона.

Рисует слои в той же очерёдности и теми же цветами, что стиль телефона
(EngineMapStyle.swift, ночь), ширина дороги — из свойства width. Нужен, чтобы
сравнить «до/после» правки сборщика на одном и том же месте:

    python3 server/render_preview.py <каталог тайлов> <lon> <lat> <zoom> <out.png> [--kind7]

--kind7 дорисовывает полотно (вид 7) так, как его заливает панель-конструктор.
--roads-only оставляет только дороги и их кромки для проверки геометрии.
--markings добавляет записанную в MVT разметку (без значков и стрелок).
Это диагностический рендер геометрии, не снимок стиля приложения.
"""
import math
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_mvt import parse, shapes_of  # noqa: E402

EXTENT = 4096
SIZE = 1400
DETAIL = 15
C = dict(ground=(14, 16, 19), block=(30, 32, 37), green=(27, 50, 32), water=(31, 64, 103),
         rail=(107, 102, 92), sidewalk=(40, 43, 50), house=(41, 43, 48), house_edge=(59, 62, 69),
         casing=(0, 3, 5), median=(18, 21, 27), kerb=(92, 91, 87))
ASPHALT = {1: (107, 105, 97), 2: (107, 105, 97), 3: (94, 92, 87), 4: (82, 82, 82),
           5: (69, 69, 71), 6: (56, 56, 61), 7: (46, 46, 51)}
LAND = {1: C["water"], 2: C["green"], 3: C["rail"], 4: C["block"], 5: C["sidewalk"], 6: C["house"]}


def props(layer, feature):
    tags = feature["tags"]
    return {layer["keys"][tags[i]]: layer["values"][tags[i + 1]] for i in range(0, len(tags), 2)}


def main():
    tiles, lon, lat, zoom, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
    kind7 = "--kind7" in sys.argv
    roads_only = "--roads-only" in sys.argv
    markings = "--markings" in sys.argv
    n = 2 ** DETAIL
    wx = (lon + 180) / 360 * n
    wy = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    px_per_tile = 512 * 2 ** (zoom - DETAIL)          # CSS-пиксели MapLibre: 512 на тайл
    half = SIZE / 2 / px_per_tile
    image = Image.new("RGB", (SIZE, SIZE), C["ground"])
    draw = ImageDraw.Draw(image)
    metres_px = px_per_tile / (40075016.7 * math.cos(math.radians(lat)) / n)

    def to_px(tx, ty, x, y):
        return ((tx + x / EXTENT - wx) * px_per_tile + SIZE / 2,
                (ty + y / EXTENT - wy) * px_per_tile + SIZE / 2)

    layers = []
    for tx in range(int(wx - half) - 1, int(wx + half) + 2):
        for ty in range(int(wy - half) - 1, int(wy + half) + 2):
            path = os.path.join(tiles, "mvt", str(DETAIL), str(tx), f"{ty}.mvt")
            if os.path.exists(path):
                layers.append((tx, ty, parse(open(path, "rb").read())))

    def each(name):
        for tx, ty, parsed in layers:
            layer = parsed.get(name)
            if not layer:
                continue
            for feature in layer["features"]:
                yield tx, ty, props(layer, feature), [[to_px(tx, ty, x, y) for x, y in s] for s in shapes_of(feature)]

    for tx, ty, p, shapes in (() if roads_only else each("land")):
        for s in shapes:
            if len(s) > 2:
                draw.polygon(s, fill=LAND.get(p.get("kind"), C["block"]))
    for tx, ty, p, shapes in (() if roads_only else each("houses")):
        for s in shapes:
            if len(s) > 2:
                draw.polygon(s, fill=C["house"], outline=C["house_edge"])
    roads = list(each("roads"))
    for extra, colour in ((1.4, C["casing"]), (0, None)):
        for tx, ty, p, shapes in sorted(roads, key=lambda r: -r[2].get("cls", 9)):
            w = max(1.2 + extra, p.get("width", 8) * metres_px * 0.85 + extra)
            fill = colour or ASPHALT.get(p.get("cls"), (70, 70, 72))
            for s in shapes:
                if len(s) > 1:
                    draw.line(s, fill=fill, width=int(round(w)), joint="curve")
                    r = w / 2
                    for x, y in (s[0], s[-1]):
                        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)
    # Сначала всё полотно, затем узлы и разделители — независимо от тайла.
    # Иначе соседний тайл мог снова залить уже нарисованный островок.
    order = {7: 0, 13: 1, 8: 2, 10: 3, 9: 4, 15: 5, 16: 6}
    for tx, ty, p, shapes in sorted(each("surface"), key=lambda row: order.get(row[2].get("kind"), 7)):
        kind = p.get("kind")
        for s in shapes:
            if kind in (15, 16) and len(s) >= 2:
                draw.line(s, fill=(188, 168, 106) if p.get("major") else C["kerb"],
                          width=max(1, round(0.25 * metres_px)), joint="curve")
                continue
            if len(s) < 3:
                continue
            if kind in (8, 10):
                draw.polygon(s, fill=ASPHALT[3])
            elif kind == 13:
                draw.polygon(s, fill=ASPHALT[3] if p.get("major") else ASPHALT[6])
            elif kind == 9:
                draw.polygon(s, fill=C["median"], outline=C["kerb"])
            elif kind == 7 and kind7:
                draw.polygon(s, fill=ASPHALT.get(p.get("cls"), ASPHALT[3]), outline=C["kerb"])
    if markings:
        def dashed(line, width, dash, gap, colour):
            distance = 0.0
            period = dash + gap
            for a, b in zip(line, line[1:]):
                length = math.dist(a, b)
                at = 0.0
                while at < length:
                    phase = (distance + at) % period
                    on = phase < dash
                    step = min(length - at, (dash if on else period) - phase)
                    if step < 1e-8:
                        step = min(length - at, 1e-8)
                    if on:
                        p = tuple(a[i] + (b[i] - a[i]) * at / length for i in (0, 1))
                        q = tuple(a[i] + (b[i] - a[i]) * (at + step) / length for i in (0, 1))
                        draw.line([p, q], fill=colour, width=width)
                    at += step
                distance += length

        for _tx, _ty, p, shapes in each("markings"):
            colour = (202, 192, 144) if p.get("centre") else (215, 220, 220)
            width = max(1, round(0.18 * metres_px))
            for s in shapes:
                if len(s) < 2:
                    continue
                if p.get("solid") or p.get("centre") == 2:
                    draw.line(s, fill=colour, width=width)
                else:
                    dashed(s, width, 3 * metres_px, 5 * metres_px, colour)
        for _tx, _ty, p, shapes in each("paint"):
            for s in shapes:
                if len(s) < 2:
                    continue
                if p.get("kind") == 12:
                    dashed(s, max(1, round(3 * metres_px)),
                           0.5 * metres_px, 0.5 * metres_px, (226, 231, 219))
                else:
                    draw.line(s, fill=(226, 231, 219), width=max(1, round(0.4 * metres_px)))
    image.save(out)
    print(out)


if __name__ == "__main__":
    main()
