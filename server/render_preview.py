#!/usr/bin/env python3
"""Снимок места из готовых MVT-тайлов — без браузера и без телефона.

Рисует слои в той же очерёдности и теми же цветами, что стиль телефона
(EngineMapStyle.swift, ночь), ширина дороги — из свойства width. Нужен, чтобы
сравнить «до/после» правки сборщика на одном и том же месте:

    python3 server/render_preview.py <каталог тайлов> <lon> <lat> <zoom> <out.png> [--kind7]

--kind7 дорисовывает полотно (вид 7) так, как его заливает панель-конструктор.
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

    for tx, ty, p, shapes in each("land"):
        for s in shapes:
            if len(s) > 2:
                draw.polygon(s, fill=LAND.get(p.get("kind"), C["block"]))
    for tx, ty, p, shapes in each("houses"):
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
    for tx, ty, p, shapes in each("surface"):
        kind = p.get("kind")
        for s in shapes:
            if len(s) < 3:
                continue
            if kind == 8:
                draw.polygon(s, fill=ASPHALT[3])
            elif kind == 9:
                draw.polygon(s, fill=C["median"], outline=C["kerb"])
            elif kind == 7 and kind7:
                draw.polygon(s, fill=ASPHALT.get(p.get("cls"), ASPHALT[3]), outline=C["kerb"])
    image.save(out)
    print(out)


if __name__ == "__main__":
    main()
