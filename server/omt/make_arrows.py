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


def _bend(start, corner, end, steps=10):
    """Плавный изгиб (квадратичная кривая Безье) от start через corner к end."""
    out = []
    for i in range(steps + 1):
        t = i / steps
        out.append(((1 - t) ** 2 * start[0] + 2 * (1 - t) * t * corner[0] + t * t * end[0],
                    (1 - t) ** 2 * start[1] + 2 * (1 - t) * t * corner[1] + t * t * end[1]))
    return out


def strokes(code):
    """Стрелки разметки 1.18 ПДД в долях иконки (x 0..1 слева направо, y 0..1
    сверху вниз): [(ломаная, направление наконечника)].

    Поворотная ветка ПЛАВНО отгибается от ствола, а не торчит под прямым углом:
    в прошлом рисунке «прямо и налево» читалось буквой «Н» (снимок владельца
    05.10.2026)."""
    up = (0, -1)
    base = (0.5, 0.98)
    through = ([base, (0.5, 0.16)], up)
    turn_l = ([base, (0.5, 0.62)] + _bend((0.5, 0.62), (0.5, 0.42), (0.16, 0.42))[1:], (-1, 0))
    turn_r = ([base, (0.5, 0.62)] + _bend((0.5, 0.62), (0.5, 0.42), (0.84, 0.42))[1:], (1, 0))
    branch_l = ([(0.5, 0.72)] + _bend((0.5, 0.72), (0.5, 0.5), (0.16, 0.44))[1:], (-0.98, -0.2))
    branch_r = ([(0.5, 0.72)] + _bend((0.5, 0.72), (0.5, 0.5), (0.84, 0.44))[1:], (0.98, -0.2))
    slight_l = ([base, (0.5, 0.62)] + _bend((0.5, 0.62), (0.5, 0.4), (0.24, 0.18))[1:], (-0.6, -0.8))
    slight_r = ([base, (0.5, 0.62)] + _bend((0.5, 0.62), (0.5, 0.4), (0.76, 0.18))[1:], (0.6, -0.8))
    uturn = ([base, (0.62, 0.42)] + _bend((0.62, 0.42), (0.62, 0.14), (0.4, 0.2))[1:]
             + _bend((0.4, 0.2), (0.3, 0.24), (0.3, 0.46))[1:], (0, 1))
    stem = ([base, (0.5, 0.72)], None)
    return {1: [through], 2: [turn_l], 3: [turn_r], 4: [slight_l], 5: [slight_r], 6: [uturn],
            7: [through, branch_l], 8: [through, branch_r], 9: [stem, branch_l, branch_r]}[code]


def draw(code, ratio):
    w, h = W * ratio, H * ratio
    image = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    shaft = max(3, round(3.0 * ratio))
    head = 6.0 * ratio
    for colour, grow in (((40, 45, 55, 80), 2 * ratio), ((255, 255, 255, 255), 0)):
        for line, direction in strokes(code):
            points = [(x * w, y * h) for x, y in line]
            pen.line(points, fill=colour, width=shaft + grow, joint="curve")
            if direction is None:
                continue
            dx, dy = direction
            norm = (dx * dx + dy * dy) ** 0.5
            dx, dy = dx / norm, dy / norm
            tip = points[-1]
            nx, ny = -dy, dx
            spread = head * 0.8 + grow / 2
            tri = [(tip[0] + dx * (head + grow / 2), tip[1] + dy * (head + grow / 2)),
                   (tip[0] + nx * spread - dx * 1.0, tip[1] + ny * spread - dy * 1.0),
                   (tip[0] - nx * spread - dx * 1.0, tip[1] - ny * spread - dy * 1.0)]
            pen.polygon(tri, fill=colour)
    return image


WAFFLE = 12   # шаг сетки «вафли» при pixelRatio 1


def waffle(ratio):
    """Узор «вафли» регулируемого перекрёстка: жёлтая сетка, как у Яндекса.
    Плитка замыкается сама: линия по левому и верхнему краю."""
    size = WAFFLE * ratio
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    line = max(1, ratio)
    colour = (242, 194, 48, 235)
    pen.rectangle((0, 0, size - 1, line - 1), fill=colour)
    pen.rectangle((0, 0, line - 1, size - 1), fill=colour)
    return image


def traffic_light(ratio):
    """Значок светофора для центра регулируемого перекрёстка (как у Яндекса)."""
    w, h = 12 * ratio, 26 * ratio
    image = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    pen.rounded_rectangle((0, 0, w - 1, h - 1), radius=3 * ratio, fill=(52, 56, 64, 255),
                          outline=(255, 255, 255, 230), width=max(1, ratio))
    r = 3 * ratio
    for index, colour in enumerate(((229, 72, 60), (244, 190, 40), (56, 190, 96))):
        cy = (5 + index * 8) * ratio
        pen.ellipse((w / 2 - r, cy - r, w / 2 + r, cy + r), fill=colour + (255,))
    return image


# Деревья в зелени, как у Яндекса (снимок владельца 05.10.2026): кроны
# кружками с тенью и бликом поверх газона, а не однотонная заливка. Плитка
# 64×64 замыкается сама — кроны у края рисуются ещё раз со сдвигом на плитку.
# Положения фиксированы: повторный запуск даёт те же байты.
TREE_TILE = 64
# Реже и бледнее, чем в первой версии: шесть ярких крон на плитку читались
# обоями поверх газона (Чорсу, 06.10.2026) — узор должен быть фактурой.
TREES = ((12, 14, 6.5), (44, 10, 5.0), (52, 40, 6.0), (20, 46, 5.5))
TREE_COLOURS = {
    "trees": {"shadow": (110, 150, 80, 45), "crown": (172, 214, 142, 200), "light": (194, 228, 168, 170)},
    "trees-dark": {"shadow": (0, 0, 0, 110), "crown": (32, 56, 38, 255), "light": (44, 74, 52, 255)},
}


def trees(ratio, palette):
    size = TREE_TILE * ratio
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    colours = TREE_COLOURS[palette]
    for layer in ("shadow", "crown", "light"):
        for x, y, r in TREES:
            for ox in (-TREE_TILE, 0, TREE_TILE):
                for oy in (-TREE_TILE, 0, TREE_TILE):
                    cx, cy, rr = (x + ox) * ratio, (y + oy) * ratio, r * ratio
                    if layer == "shadow":
                        box = (cx - rr + ratio, cy - rr + 2 * ratio, cx + rr + ratio, cy + rr + 2 * ratio)
                    elif layer == "crown":
                        box = (cx - rr, cy - rr, cx + rr, cy + rr)
                    else:
                        small = rr * 0.45
                        box = (cx - rr * 0.35 - small, cy - rr * 0.35 - small,
                               cx - rr * 0.35 + small, cy - rr * 0.35 + small)
                    pen.ellipse(box, fill=colours[layer])
    return image


# Зерно асфальта: мелкие светлые и тёмные крапины на прозрачном фоне —
# накладывается поверх полотна с малой непрозрачностью. Ровный серый цвет
# читался пластиком, а не дорогой (07.10.2026). Зерно задано сидом — повторный
# запуск даёт те же байты.
ASPHALT_TILE = 64
ASPHALT_COLOURS = {
    "asphalt": ((255, 255, 255), (60, 66, 78)),
    "asphalt-dark": ((120, 128, 140), (10, 12, 16)),
}


def asphalt(ratio, palette):
    import random
    rng = random.Random(20261007)
    size = ASPHALT_TILE * ratio
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    light, dark = ASPHALT_COLOURS[palette]
    for _ in range(int(ASPHALT_TILE * ASPHALT_TILE * 0.05)):
        x, y = rng.uniform(0, ASPHALT_TILE), rng.uniform(0, ASPHALT_TILE)
        r = rng.uniform(0.3, 0.6)
        colour = light if rng.random() < 0.5 else dark
        alpha = int(rng.uniform(25, 60))
        pen.ellipse(((x - r) * ratio, (y - r) * ratio, (x + r) * ratio, (y + r) * ratio),
                    fill=colour + (alpha,))
    return image


# Штриховка направляющего островка (разметка 1.16): белые диагонали на
# прозрачном, плитка замыкается сама — как у Яндекса у съездов.
HATCH_TILE = 16


def hatch(ratio):
    size = HATCH_TILE * ratio
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    width = max(1, int(2.2 * ratio))
    for offset in (-size, 0, size):
        pen.line([(offset, size), (offset + size, 0)], fill=(255, 255, 255, 235), width=width)
    return image


def build(ratio):
    suffix = "" if ratio == 1 else f"@{ratio}x"
    base_png = os.path.join(HERE, "sprite", f"base{suffix}.png")
    base_json = os.path.join(HERE, "sprite", f"base{suffix}.json")
    sheet = Image.open(base_png).convert("RGBA")
    index = json.load(open(base_json))
    icons = [(f"lane-{NAMES[code]}", draw(code, ratio)) for code in sorted(NAMES)]
    icons.append(("waffle", waffle(ratio)))
    icons.append(("traffic-light", traffic_light(ratio)))
    icons += [(name, trees(ratio, name)) for name in sorted(TREE_COLOURS)]
    icons += [(name, asphalt(ratio, name)) for name in sorted(ASPHALT_COLOURS)]
    icons.append(("hatch", hatch(ratio)))
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
    print("стрелок:", len(NAMES), "+ узоры: «вафля», деревья")
