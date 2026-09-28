#!/usr/bin/env python3
"""Иконки стрелок полос (коды build_roads.TURN_*) → дописываются в спрайт стиля.

Стрелка нарисована «вверх» (на север); стиль поворачивает её по bearing.
Белая, как краска на асфальте, с тонкой тенью — читается и на светлой, и на
тёмной теме. Спрайт пересобирается из osm-bright + стрелок, поэтому повторный
запуск даёт те же байты.

    python3 server/omt/make_arrows.py   # пишет sprite/sprite{,@2x}.{png,json}
"""
import json
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 18, 30          # размер иконки при pixelRatio 1
NAMES = {1: "through", 2: "left", 3: "right", 4: "slight_left", 5: "slight_right",
         6: "uturn", 7: "through_left", 8: "through_right", 9: "left_right"}


def strokes(code):
    """Ломаные стрелки в долях иконки (x 0..1 слева направо, y 0..1 сверху вниз) и
    куда смотрят наконечники: [(ломаная, (конец, направление))]."""
    up, left, right = (0, -1), (-1, 0), (1, 0)
    base = (0.5, 0.97)
    through = ([base, (0.5, 0.12)], up)
    turn_l = ([base, (0.5, 0.55), (0.14, 0.55)], left)
    turn_r = ([base, (0.5, 0.55), (0.86, 0.55)], right)
    slight_l = ([base, (0.5, 0.6), (0.22, 0.2)], (-0.57, -0.82))
    slight_r = ([base, (0.5, 0.6), (0.78, 0.2)], (0.57, -0.82))
    uturn = ([base, (0.62, 0.3), (0.62, 0.22), (0.3, 0.22), (0.3, 0.55)], (0, 1))
    return {1: [through], 2: [turn_l], 3: [turn_r], 4: [slight_l], 5: [slight_r], 6: [uturn],
            7: [through, turn_l], 8: [through, turn_r], 9: [turn_l, turn_r]}[code]


def draw(code, ratio):
    w, h = W * ratio, H * ratio
    image = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    shaft = max(2, round(2.2 * ratio))
    head = 5.0 * ratio
    for colour, grow in (((40, 45, 55, 90), 2 * ratio), ((255, 255, 255, 255), 0)):
        for line, (dx, dy) in strokes(code):
            points = [(x * w, y * h) for x, y in line]
            pen.line(points, fill=colour, width=shaft + grow, joint="curve")
            tip = points[-1]
            nx, ny = -dy, dx
            tri = [(tip[0] + dx * head, tip[1] + dy * head),
                   (tip[0] + nx * (head + grow / 2), tip[1] + ny * (head + grow / 2)),
                   (tip[0] - nx * (head + grow / 2), tip[1] - ny * (head + grow / 2))]
            pen.polygon(tri, fill=colour)
    return image


def build(ratio):
    suffix = "" if ratio == 1 else f"@{ratio}x"
    base_png = os.path.join(HERE, "sprite", f"base{suffix}.png")
    base_json = os.path.join(HERE, "sprite", f"base{suffix}.json")
    sheet = Image.open(base_png).convert("RGBA")
    index = json.load(open(base_json))
    icons = [(f"lane-{NAMES[code]}", draw(code, ratio)) for code in sorted(NAMES)]
    row = max(icon.height for _n, icon in icons)
    out = Image.new("RGBA", (max(sheet.width, sum(i.width + 2 for _n, i in icons)),
                             sheet.height + row + 2), (0, 0, 0, 0))
    out.paste(sheet, (0, 0))
    x = 0
    for name, icon in icons:
        out.paste(icon, (x, sheet.height + 2))
        index[name] = {"x": x, "y": sheet.height + 2, "width": icon.width,
                       "height": icon.height, "pixelRatio": ratio}
        x += icon.width + 2
    out.save(os.path.join(HERE, "sprite", f"sprite{suffix}.png"), optimize=True)
    with open(os.path.join(HERE, "sprite", f"sprite{suffix}.json"), "w") as handle:
        json.dump(index, handle, sort_keys=True, separators=(",", ":"))


if __name__ == "__main__":
    for ratio in (1, 2):
        build(ratio)
    print("стрелок:", len(NAMES))
