#!/usr/bin/env python3
"""Подмножество шрифтов подписей для вшивания в приложение.

На сервере три начертания Noto Sans по 256 диапазонов — 101 МБ. Улицы
Узбекистана пишутся латиницей и кириллицей, и им хватает шести диапазонов:

    0-255       базовая латиница и знаки;
    256-511     расширенная латиница;
    512-767     ʻ (U+02BB) в oʻ и gʻ;
    1024-1279   кириллица, в том числе ў қ ғ ҳ;
    8192-8447   ‘ ’ – “ ” (типографские кавычки и тире);
    8448-8703   № («Maktab № 5» — 121 подпись по стране).

Арабица остаётся за бортом: она встречается в основном `name` у 11 объектов
на страну (мечети), и ради них везти в бандл ещё десятки диапазонов не стоит.

Итого ~1,4 МБ на три начертания. Вшитые шрифты — это правило проекта «без
сетевых шрифтов» (CLAUDE.md) и минус десятки запросов на первом экране
(docs/plan_map_offline.md §2.2). Символ вне диапазонов движок просто не
нарисует — поэтому список диапазонов проверяется по подписям в тайлах
(--check), а не на глаз.

    python3 server/omt/glyph_subset.py <glyphs> <выход>
    python3 server/omt/glyph_subset.py <glyphs> <выход> --check <places.geojsonl> ...
"""

import json
import os
import shutil
import sys

RANGES = ((0, 255), (256, 511), (512, 767), (1024, 1279), (8192, 8447), (8448, 8703))
FONTS = ("Noto Sans Regular", "Noto Sans Bold", "Noto Sans Italic")


def range_name(start, end):
    return f"{start}-{end}.pbf"


def covered(codepoint):
    return any(start <= codepoint <= end for start, end in RANGES)


def export(glyphs, out):
    """Копирует нужные диапазоны; возвращает суммарный размер в байтах."""
    total = 0
    for font in FONTS:
        target = os.path.join(out, font)
        os.makedirs(target, exist_ok=True)
        for start, end in RANGES:
            source = os.path.join(glyphs, font, range_name(start, end))
            if not os.path.isfile(source):
                raise FileNotFoundError(f"нет диапазона: {source}")
            shutil.copyfile(source, os.path.join(target, range_name(start, end)))
            total += os.path.getsize(source)
    return total


def uncovered(names):
    """Символы из названий, которых нет в диапазонах: {символ: сколько раз}."""
    missing = {}
    for name in names:
        for char in name:
            if not covered(ord(char)):
                missing[char] = missing.get(char, 0) + 1
    return missing


def names_from_geojsonl(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            props = json.loads(line).get("properties") or {}
            # Только основной `name`: из него OpenMapTiles выводит name:latin и
            # name:nonlatin, которые и рисует стиль. Переводы (name:fa, name:ug…)
            # на карту не попадают, и арабица в них — не повод тащить в бандл
            # ещё десятки диапазонов.
            value = props.get("name")
            if isinstance(value, str):
                yield value


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    total = export(argv[1], argv[2])
    print(f"шрифты: {len(FONTS)} × {len(RANGES)} диапазонов, {total / 1024:.0f} КБ → {argv[2]}")
    if "--check" in argv:
        sources = argv[argv.index("--check") + 1:]
        missing = {}
        for path in sources:
            for char, count in uncovered(names_from_geojsonl(path)).items():
                missing[char] = missing.get(char, 0) + count
        top = sorted(missing.items(), key=lambda kv: -kv[1])[:15]
        print("вне диапазонов:", ", ".join(f"{c!r} U+{ord(c):04X} ×{n}" for c, n in top) or "ничего")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
