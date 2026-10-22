#!/usr/bin/env python3
"""Маркетинговые скриншоты App Store из «чистых» кадров.

python3 tools/appstore/marketing_shots.py docs/appstore/screenshots/6.9

Берёт raw/NN_имя.png (1320×2868) и подписи из CAPTIONS, кладёт в marketing/
кадр того же размера: подпись сверху крупно, снимок экрана ниже со
скруглением и тенью, фон — цвета приложения (accentFill днём, графит ночью).
PNG без альфы — App Store Connect прозрачность не принимает.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
FONT = "/System/Library/Fonts/SFNS.ttf"

# Файл → (строки подписи, тема фона). Тексты — короткие, по-русски.
CAPTIONS = {
    "01_alert":  (["Предупредит", "о камере заранее"], "day"),
    "02_drive":  (["Камеры и полосы", "прямо на маршруте"], "day"),
    "03_myroad": (["Своя дорога домой", "и выбор маршрута"], "day"),
    "04_rating": (["Рейтинг, который", "можно проверить"], "day"),
    "05_family": (["Близкие видят,", "когда вы будете дома"], "day"),
    "06_night":  (["Ночью — спокойная", "тёмная карта"], "night"),
}
THEMES = {
    # Theme.accentFill 0x2563D9 → чуть темнее книзу; ночь — Theme.background/surface тёмные.
    "day":   ((0x2F, 0x6E, 0xE6), (0x1D, 0x4F, 0xB5), (255, 255, 255)),
    "night": ((0x1E, 0x23, 0x2A), (0x0B, 0x0E, 0x12), (255, 255, 255)),
}


def font(size, weight=b"Bold"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def gradient(top, bottom):
    img = Image.new("RGB", (W, H), top)
    px = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        px.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def compose(raw: Path, lines, theme, out: Path):
    top, bottom, ink = THEMES[theme]
    canvas = gradient(top, bottom)
    draw = ImageDraw.Draw(canvas)

    # Подпись: самый крупный кегль, при котором каждая строка влезает в поля.
    margin = 90
    size = 112
    while size > 60:
        f = font(size)
        if all(draw.textlength(l, font=f) <= W - 2 * margin for l in lines):
            break
        size -= 4
    f = font(size)
    line_h = round(size * 1.18)
    y = 190
    for l in lines:
        draw.text((W / 2, y), l, font=f, fill=ink, anchor="mt")
        y += line_h

    # Снимок экрана: по высоте до низа с полем, скругление как у iPhone.
    shot = Image.open(raw).convert("RGB")
    top_y = y + 90
    h = H - top_y - 110
    w = round(h * shot.width / shot.height)
    shot = shot.resize((w, h), Image.LANCZOS)
    radius = round(w * 0.085)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    x = (W - w) // 2

    # Тень — на фоне, а не на снимке.
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, top_y + 24, x + w, top_y + h + 24], radius=radius, fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas.paste(Image.new("RGB", (W, H), (0, 0, 0)), (0, 0), shadow)

    # Тонкая рамка-ободок, как корпус.
    bezel = 14
    ImageDraw.Draw(canvas).rounded_rectangle(
        [x - bezel, top_y - bezel, x + w + bezel, top_y + h + bezel],
        radius=radius + bezel, fill=(0x16, 0x19, 0x1E))
    canvas.paste(shot, (x, top_y), mask)

    assert canvas.size == (W, H) and canvas.mode == "RGB"
    canvas.save(out, "PNG", optimize=True)


def main():
    root = Path(sys.argv[1])
    raw_dir, out_dir = root / "raw", root / "marketing"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, (lines, theme) in CAPTIONS.items():
        raw = raw_dir / f"{name}.png"
        if not raw.exists():
            print(f"нет {raw}")
            continue
        compose(raw, lines, theme, out_dir / f"{name}.png")
        print(f"готово {name}")


if __name__ == "__main__":
    main()
