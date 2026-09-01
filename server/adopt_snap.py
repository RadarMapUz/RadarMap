#!/usr/bin/env python3
"""Принять результат снапа ВЫБОРОЧНО — только для новых камер.

Почему не целиком. snap_cameras.py пересчитывает профиль дороги ВСЕЙ базе, и
это не безобидно: на прогоне 01.09.2026 из 3475 старых камер 116 сменили ось,
45 из них — больше чем на 30°, шесть ровно на 90°. Девяносто градусов означает,
что камеру пересадили на поперечную улицу, а `cameraAxisMaxAngle` равен 55° —
такая камера перестаёт считаться «нашей дорогой» и ЗАМОЛКАЕТ. Молчание о
настоящей камере — худший исход из возможных.

Разбор показал, что изменения разнородны: id=2747 уехал с footway на trunk
(явное исправление), id=3440 — с trunk на living_street (явная поломка). Их
надо смотреть глазами по snap_moves.geojson, для чего этот файл снапом и
делается. Пока их не посмотрели, база не должна меняться.

А новым камерам профиль нужен и рисковать нечем: у них его нет вовсе, хуже не
станет. Отсюда этот инструмент — принять геометрию только для id от порога и
выше, оставив всё остальное байт-в-байт прежним.

Запуск:
    python3 adopt_snap.py --base cameras.json --snapped cameras.snapped.json \\
                          --from-id 3504 [--apply]
"""
import argparse
import json
import os
import sys

# Поля, которые считает снап. Всё остальное (id, координата, адрес, тип)
# принадлежит базе и снапом не управляется.
PROFILE_FIELDS = ("axis", "dir", "split", "cls", "road", "lanes", "twin", "bridge")


def adopt(base, snapped, from_id):
    """Профиль из снапа — только камерам с id >= from_id. Чистая функция."""
    by_id = {c["id"]: c for c in snapped}
    out = []
    touched = 0
    for camera in base:
        if camera["id"] < from_id or camera["id"] not in by_id:
            out.append(camera)
            continue
        fresh = by_id[camera["id"]]
        merged = dict(camera)
        # Координату снап тоже уточняет — сажает точку на ось проезжей части.
        merged["lat"] = fresh["lat"]
        merged["lon"] = fresh["lon"]
        for field in PROFILE_FIELDS:
            if field in fresh:
                merged[field] = fresh[field]
        # Снятая пометка «приблизительная» — это утверждение снапа о том, что
        # точка теперь на оси дороги. Верим ему ровно в ту сторону, в какую он
        # её снял; сами флаг не выдумываем.
        if fresh.get("needsReview") is None:
            merged.pop("needsReview", None)
        else:
            merged["needsReview"] = fresh["needsReview"]
        out.append(merged)
        touched += 1
    return out, touched


def verify(base, result, from_id):
    """Ниже порога не изменилось НИЧЕГО. Это и есть весь смысл инструмента."""
    if len(base) != len(result):
        return False, "число камер изменилось"
    for old, new in zip(base, result):
        if old["id"] != new["id"]:
            return False, "порядок или состав id изменился"
        if old["id"] < from_id and old != new:
            return False, "камера %d ниже порога изменилась" % old["id"]
    return True, "камеры до id %d не тронуты" % from_id


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--snapped", required=True)
    ap.add_argument("--from-id", type=int, required=True)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    with open(args.base, encoding="utf-8") as f:
        base = json.load(f)
    with open(args.snapped, encoding="utf-8") as f:
        snapped = json.load(f)

    result, touched = adopt(base, snapped, args.from_id)
    ok, why = verify(base, result, args.from_id)
    print("камер в базе: %d, принят профиль у %d (id >= %d)" % (len(base), touched, args.from_id))
    print("проверка: %s" % why)
    if not ok:
        print("ОТКАЗ: база не тронута")
        return 1

    got_axis = sum(1 for c in result if c["id"] >= args.from_id and c.get("axis") is not None)
    print("из них получили ось дороги: %d" % got_axis)
    if not args.apply:
        print("(показ без записи; повторите с --apply)")
        return 0

    tmp = args.base + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, args.base)
    print("записано")
    return 0


if __name__ == "__main__":
    sys.exit(main())
