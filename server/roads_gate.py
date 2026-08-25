#!/usr/bin/env python3
"""Ворота публикации дорожных тайлов.

Зачем отдельный модуль, а не пара сравнений в шелле. Публикация дорог —
единственный путь, которым геометрия попадает на телефоны, и ошибка здесь
видна не в логе, а на экране у водителя за рулём. Такое решение должно быть
чистой функцией с тестами, а не арифметикой в bash, где `$(( ))` молча
округляет и пустая переменная равна нулю.

Принцип тот же, что уже стоит в update_cameras.py: не доверять входу, который
выглядит неправдоподобно. Выгрузка OSM может приехать обрезанной, osmium —
упасть на середине, фильтр — смениться. Во всех этих случаях кандидат
СОБИРАЕТСЯ УСПЕШНО и выглядит как обычный набор тайлов, просто меньше.

Запуск: python3 roads_gate.py прошлый.json кандидат.json  → код 0 или 1.
"""
import json
import sys

# Общий объём дорог не меняется рывками: сеть страны за неделю прирастает
# долями процента. Двенадцать — это с запасом на разовые правки в OSM
# (кто-то перерисовал развязку), но заведомо меньше обрезанной выгрузки.
MAX_TOTAL_DELTA = 0.12
# Отдельный тайл имеет право заметно измениться (в районе снесли квартал),
# но потеря четверти — это уже не правка, а пропажа данных.
MAX_TILE_LOSS = 0.25
# Сколько тайлов вправе исчезнуть насовсем. Ноль: тайл пропадает только если
# из региона исчезли ВСЕ дороги, а такого не бывает.
MAX_TILES_GONE = 0


def _totals(index):
    tiles = index.get("tiles") or {}
    return len(tiles), sum(meta.get("bytes", 0) for meta in tiles.values())


def decide(previous, candidate, allow_grid_change=False):
    """Пускать ли кандидата в публикацию. Возвращает (можно, [причины])."""
    reasons = []
    if not (candidate.get("tiles") or {}):
        return False, ["кандидат пуст: ни одного тайла"]

    # Первая публикация: сравнивать не с чем, и это не повод отказывать.
    if not (previous.get("tiles") or {}):
        return True, []

    # Смена сетки меняет ВСЕ ключи разом: потайловое сравнение теряет смысл,
    # а не срабатывает. Требуем сказать это вслух, иначе первая же публикация
    # нового формата упёрлась бы в ворота, написанные ради обрезанных выгрузок.
    grid_changed = previous.get("tileDegrees") != candidate.get("tileDegrees")
    if grid_changed and not allow_grid_change:
        return False, [f"сетка меняется с {previous.get('tileDegrees')} "
                       f"на {candidate.get('tileDegrees')} — нужен явный allow_grid_change"]

    previous_count, previous_bytes = _totals(previous)
    candidate_count, candidate_bytes = _totals(candidate)

    if previous_bytes > 0:
        delta = (candidate_bytes - previous_bytes) / previous_bytes
        if abs(delta) > MAX_TOTAL_DELTA:
            reasons.append(f"объём дорог изменился на {delta * 100:+.0f}% "
                           f"(порог ±{MAX_TOTAL_DELTA * 100:.0f}%)")

    if grid_changed:
        # Потайловые ворота на смене сетки неприменимы: ключей прошлого набора
        # в новом нет ни одного, и «пропало N тайлов» означало бы только то,
        # что сетка другая.
        return not reasons, reasons

    gone = [key for key in previous["tiles"] if key not in candidate["tiles"]]
    if len(gone) > MAX_TILES_GONE:
        reasons.append(f"тайлов исчезло: {len(gone)} ({', '.join(sorted(gone)[:5])})")

    shrunk = []
    for key, meta in previous["tiles"].items():
        fresh = candidate["tiles"].get(key)
        if not fresh or not meta.get("bytes"):
            continue
        loss = (meta["bytes"] - fresh.get("bytes", 0)) / meta["bytes"]
        if loss > MAX_TILE_LOSS:
            shrunk.append((key, loss))
    if shrunk:
        shrunk.sort(key=lambda item: -item[1])
        worst = ", ".join(f"{key} −{loss * 100:.0f}%" for key, loss in shrunk[:5])
        reasons.append(f"тайлов похудело больше чем на "
                       f"{MAX_TILE_LOSS * 100:.0f}%: {len(shrunk)} ({worst})")

    return not reasons, reasons


def summary(previous, candidate):
    """Строка для телеграма: что изменилось, человеческим языком."""
    previous_count, previous_bytes = _totals(previous)
    candidate_count, candidate_bytes = _totals(candidate)
    changed = sum(1 for key, meta in (candidate.get("tiles") or {}).items()
                  if (previous.get("tiles") or {}).get(key, {}).get("sha256")
                  != meta.get("sha256"))
    delta = ((candidate_bytes - previous_bytes) / previous_bytes * 100
             if previous_bytes else 0)
    return (f"тайлов {candidate_count} (было {previous_count}), "
            f"изменилось {changed}, объём {candidate_bytes / 1e6:.1f} МБ ({delta:+.1f}%)")


def main():
    if len(sys.argv) < 3:
        print("нужно: roads_gate.py прошлый.json кандидат.json [--allow-grid-change]")
        return 2
    allow = "--allow-grid-change" in sys.argv
    with open(sys.argv[1], encoding="utf-8") as handle:
        previous = json.load(handle)
    with open(sys.argv[2], encoding="utf-8") as handle:
        candidate = json.load(handle)
    ok, reasons = decide(previous, candidate, allow_grid_change=allow)
    print(summary(previous, candidate))
    for reason in reasons:
        print("СТОП:", reason)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
