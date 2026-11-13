#!/usr/bin/env python3
"""Сравнение двух прогонов matrix.py: доля изменившихся пикселей по каждому кадру.

    python3 tools/map_matrix/compare.py <было> <стало> [--threshold 12] [--sheet <png>]

Кадр, где правка не должна была ничего менять, обязан дать 0 %: так видно, что
правка стиля задела только то, что задумано. С --sheet — лист пар «было | стало»
для кадров с изменениями.
"""
import argparse
import os

from PIL import Image, ImageChops


def changed_share(before, after, threshold):
    a = Image.open(before).convert("RGB")
    b = Image.open(after).convert("RGB")
    if a.size != b.size:
        return 1.0
    mask = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > threshold else 0)
    return mask.histogram()[255] / (a.width * a.height)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--threshold", type=int, default=12)
    parser.add_argument("--sheet")
    args = parser.parse_args()
    pairs = []
    root = os.path.join(args.after, "frames")
    for place in sorted(os.listdir(root)):
        for name in sorted(os.listdir(os.path.join(root, place))):
            before = os.path.join(args.before, "frames", place, name)
            after = os.path.join(root, place, name)
            if not os.path.exists(before):
                continue
            share = changed_share(before, after, args.threshold)
            print(f"{place:22} {name:28} {share * 100:6.2f} %")
            if share > 0:
                pairs.append((before, after))
    if args.sheet and pairs:
        thumbs = []
        for before, after in pairs:
            a, b = Image.open(before).convert("RGB"), Image.open(after).convert("RGB")
            pair = Image.new("RGB", (a.width * 2 + 8, a.height), "white")
            pair.paste(a, (0, 0))
            pair.paste(b, (a.width + 8, 0))
            pair.thumbnail((640, 640))
            thumbs.append(pair)
        cols = 3
        w, h = thumbs[0].size
        rows = (len(thumbs) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * (w + 8), rows * (h + 8)), "white")
        for k, image in enumerate(thumbs):
            sheet.paste(image, ((k % cols) * (w + 8), (k // cols) * (h + 8)))
        sheet.save(args.sheet)
        print(args.sheet)


if __name__ == "__main__":
    main()
