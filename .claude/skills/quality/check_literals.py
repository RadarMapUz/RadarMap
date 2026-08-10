#!/usr/bin/env python3
"""Русские литералы в локализуемых позициях без узбекского перевода.

Каталог проверяет только то, что в него попало. А литерал, переданный как
LocalizedStringKey (Text("…"), label:, title:), в каталоге может просто
отсутствовать — и тогда узбекский интерфейс молча показывает русское слово.
Ровно так «пройдено» жило в плитках Итогов, а «макс. км/ч» пропало из каталога
вместе с чужой уборкой и утащило за собой два экрана.

    python3 .claude/skills/quality/check_literals.py
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
CATALOG = ROOT / "Shared/Localizable.xcstrings"
SOURCES = [ROOT / "RadarMap", ROOT / "RadarMapWidgets", ROOT / "RadarWatch"]
#: Text("…"), label: "…", title: "…" — позиции, где SwiftUI сам локализует ключ.
PATTERN = re.compile(r'(?:Text|label:|title:)\s*\(?\s*"([^"%\\]{2,80})"')
CYRILLIC = re.compile(r"[А-Яа-яЁё]")


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    missing: dict[str, set[str]] = {}
    for root in SOURCES:
        for path in root.rglob("*.swift"):
            for match in PATTERN.finditer(path.read_text(encoding="utf-8")):
                key = match.group(1)
                if not CYRILLIC.search(key):
                    continue
                unit = (catalog.get(key) or {}).get("localizations", {}) \
                    .get("uz", {}).get("stringUnit", {})
                if unit.get("state") != "translated" or not unit.get("value"):
                    missing.setdefault(key, set()).add(path.name)
    if not missing:
        print("русских литералов без узбекского: 0")
        return 0
    print(f"БЕЗ УЗБЕКСКОГО: {len(missing)}")
    for key, files in sorted(missing.items()):
        print(f"  «{key}» — {', '.join(sorted(files))}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
