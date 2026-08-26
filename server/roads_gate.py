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


# --- Ворота для нарисованного руками.
#
# Числа ловят опечатку, а не мешают работе. Своя геометрия — единственные
# данные в системе, которые нельзя восстановить пересборкой, и единственные,
# которые не с чем сверить, кроме рук, их нарисовавших: проверять их надо
# строже, чем всё остальное, но проверять СМЫСЛ, а не аккуратность.
MIN_DRAWN_METERS = 20.0
MAX_DRAWN_VERTICES = 200
MAX_DRAWN_SEGMENT_METERS = 2000.0
MAX_DRAWN_AT_ONCE = 50
# Причина обязательна и закрытым списком: свободный текст через полгода
# превращается в «тест», «пока так» и «см. выше».
DRAWN_REASONS = {"нет в OSM", "OSM неверен", "временная схема"}
REMOVE_REASONS = {"нет в жизни", "перекрыта", "ошибка OSM"}

LAT_METERS = 111_320.0


def _meters(a, b):
    import math
    lon_scale = math.cos(math.radians((a[1] + b[1]) / 2))
    return math.hypot((b[1] - a[1]) * LAT_METERS,
                      (b[0] - a[0]) * LAT_METERS * lon_scale)


def check_drawn(edits):
    """Пускать ли нарисованное в публикацию → (можно, [причины]).

    Причины возвращаются ВСЕ, а не первая: модератор, нарисовавший десять
    дорог, должен увидеть все замечания разом, а не открывать ворота десять
    раз подряд.
    """
    lines = [e for e in edits if e.get("kind") == "geometry"]
    reasons = []

    # Убранные дороги проверяются отдельно и мягче: геометрию у них не рисовал
    # человек, это копия чужой линии. Спрашиваем только одно — почему.
    for edit in [e for e in edits if e.get("kind") == "remove"]:
        why = (edit.get("props") or {}).get("why")
        if why not in REMOVE_REASONS:
            reasons.append(f"правка #{edit.get('id', '?')}: не сказано, почему "
                           f"дорога убрана")
    if not lines:
        return not reasons, reasons
    if len(lines) > MAX_DRAWN_AT_ONCE:
        reasons.append(f"нарисовано за раз {len(lines)} — больше "
                       f"{MAX_DRAWN_AT_ONCE}, это похоже на ошибку")

    for edit in lines:
        who = f"правка #{edit.get('id', '?')}"
        points = edit.get("geom") or []
        if len(points) < 2:
            reasons.append(f"{who}: меньше двух точек — рисовать нечего")
            continue
        if len(points) > MAX_DRAWN_VERTICES:
            reasons.append(f"{who}: вершин {len(points)} — похоже на дрожь мыши")
        total, longest = 0.0, 0.0
        for i in range(1, len(points)):
            step = _meters(points[i - 1], points[i])
            total += step
            longest = max(longest, step)
        if total < MIN_DRAWN_METERS:
            reasons.append(f"{who}: длина {total:.0f} м — короче {MIN_DRAWN_METERS:.0f}")
        if longest > MAX_DRAWN_SEGMENT_METERS:
            reasons.append(f"{who}: отрезок {longest:.0f} м — похоже на промах "
                           f"через полгорода")
        why = (edit.get("props") or {}).get("why")
        if why not in DRAWN_REASONS:
            reasons.append(f"{who}: не сказано, почему дорога своя")
    return not reasons, reasons


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
