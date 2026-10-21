#!/usr/bin/env python3
"""resnap_moved.py — пересъёмка дорожного профиля перенесённых камер.

Модератор двигает камеру в админке («Положение») — и его точка правильная:
человек поставил её на спутнике. Но приложение при переносе честно СБРАСЫВАЕТ
весь дорожный профиль (axis/dir/lanes/cls/bridge/road/split/twin): snap мерил
его в ДРУГОМ месте, а road хранится дельтами от камеры и уехал бы вместе с
ней. Со сброшенным профилем камера предупреждает в обе стороны — безопасно,
но шумно, и так НАВСЕГДА, пока профиль не переснят. Этот скрипт закрывает
цикл.

Что делает: берёт действующие move-переносы из overrides.json, прикладывает
их к базе и заново выводит профиль каждой перенесённой камеры у её НОВОЙ
точки — тем же кодом, что полный снап (импортирует snap_cameras), но БЕЗ
переноса координаты: точка модератора — истина, ищем только дорогу под ней.
Затем пары «камера ↔ встречная» (twin) переразмечаются по всей базе заново:
метка без ссылки на партнёра, и после переезда камеры протухшая twin у
бывшего партнёра разрешала бы глушение по направлению там, где пары больше
нет.

hide и retype остаются жить в overrides.json — они не про геометрию.

Релизный путь владельца (ключ подписи только у него):
  1. на VPS:  python3 resnap_moved.py --roads roads.geojsonl \
                  --cameras /opt/radarmap/www/cameras.json \
                  --overrides /opt/radarmap/www/overrides.json \
                  --out cameras.resnapped.json --report resnap_report.csv
  2. глазами: resnap_report.csv (у каждой камеры статус профиля);
  3. локально: deploy_db.sh <v+1> с новым файлом;
  4. опубликовать overrides.json БЕЗ влитых move-строк (publish_overrides.sh):
     координата теперь в самой базе, два источника одного переноса — путаница.

Тесты логики (без данных и сети): python3 test_resnap_moved.py
"""
import argparse
import base64
import csv
import json
import sys

import snap_cameras as snap

# Все поля дорожного профиля: перед пересъёмкой вычищаются — старые значения
# мерены у другой точки и не имеют права пережить переезд.
PROFILE_KEYS = ("axis", "dir", "lanes", "cls", "bridge", "road", "split", "twin")


def load_overrides(path):
    """items из overrides.json — как из голого снимка CameraOverrides, так и из
    подписанной обёртки {payload, sig} (подпись здесь не проверяем: файл берём
    с того же диска, куда его положил publish_overrides.sh)."""
    data = json.load(open(path, encoding="utf-8"))
    if "items" in data:
        return data["items"]
    payload = data.get("payload")
    if isinstance(payload, str):
        # publish_overrides.sh кладёт payload в base64 (подписаны байты, не
        # JSON-текст); старые ручные снимки могли держать голый JSON.
        try:
            payload = json.loads(base64.b64decode(payload, validate=True))
        except ValueError:
            payload = json.loads(payload)
    if isinstance(payload, dict) and "items" in payload:
        return payload["items"]
    raise SystemExit(f"не разобрать формат {path}: нет items")


def resnap(cameras, items, index, *, radius=60.0):
    """Чистая часть: применить move-переносы и переснять профили.

    Возвращает (новый список камер, строки отчёта). Камеры без переноса
    отдаются как есть (тот же dict) — diff базы показывает ровно переезды.
    """
    by_id = {}
    result = []
    for cam in cameras:
        by_id[cam["id"]] = len(result)
        result.append(cam)

    report = []
    moved_any = False
    for item in items:
        if item.get("op") != "move":
            continue
        cam_index = by_id.get(item.get("id"))
        lat, lon = item.get("lat"), item.get("lon")
        if cam_index is None or lat is None or lon is None:
            report.append((item.get("id"), "-", "-",
                           "пропуск: камеры нет в базе или перенос без координат"))
            continue
        out = dict(result[cam_index])
        out["lat"], out["lon"] = lat, lon
        for key in PROFILE_KEYS:
            out.pop(key, None)
        moved_any = True

        cands = index.nearby(lat, lon, radius)
        if cands and cands[0].axis is not None:
            cand = cands[0]
            out["axis"] = cand.axis
            snap.apply_road_profile(out, index, cand)
            # Дорога под точкой модератора нашлась — прежнее «подозрительно»
            # снято: положение теперь человеческое, профиль свежий.
            out.pop("needsReview", None)
            report.append((out["id"], f"{cand.dist:.0f}", out.get("location", ""),
                           "профиль переснят"
                           + (" (направление известно)" if out.get("dir") is not None
                              else " (без направления — предупреждаем в обе)")))
        else:
            # Дороги рядом нет (двор, новая улица не в выгрузке): профиль пуст,
            # приложение даст камере широкий коридор — шумно, но не молчаливо.
            out["needsReview"] = True
            report.append((out["id"], "-", out.get("location", ""),
                           f"дороги в {radius:.0f} м не нашлось — профиль пуст, needsReview"))
        result[cam_index] = out

    if moved_any:
        # Переразметка пар по всей базе: метки без ссылок, поштучно не починить.
        for cam in result:
            cam.pop("twin", None)
        snap.mark_direction_twins(result)
    return result, report


def main():
    ap = argparse.ArgumentParser(
        description="Пересъёмка дорожного профиля перенесённых модератором камер")
    ap.add_argument("--roads", required=True,
                    help="GeoJSON(seq) дорог (готовит snap_cameras.sh через osmium)")
    ap.add_argument("--cameras", required=True, help="живая база cameras.json")
    ap.add_argument("--overrides", required=True, help="overrides.json с move-строками")
    ap.add_argument("--out", default="cameras.resnapped.json")
    ap.add_argument("--report", default="resnap_report.csv")
    ap.add_argument("--radius", type=float, default=60.0,
                    help="радиус поиска дороги под точкой модератора, м")
    args = ap.parse_args()

    print(f"загрузка дорог: {args.roads} …")
    index, named, withref = snap.load_roads(args.roads)
    print(f"  кусков: {index.count}, линий с именами: {named}, с ref: {withref}")

    cameras = json.load(open(args.cameras, encoding="utf-8"))
    items = load_overrides(args.overrides)
    moves = [i for i in items if i.get("op") == "move"]
    print(f"камер: {len(cameras)} · move-переносов: {len(moves)}")
    if not moves:
        print("переносов нет — пересъёмка не нужна")
        return 0

    result, report = resnap(cameras, items, index, radius=args.radius)

    json.dump(result, open(args.out, "w", encoding="utf-8"),
              ensure_ascii=False, separators=(",", ":"))
    with open(args.report, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "dist_to_road_m", "location", "status"])
        w.writerows(report)

    ok = sum(1 for r in report if r[3].startswith("профиль переснят"))
    empty = sum(1 for r in report if "не нашлось" in r[3])
    skipped = len(report) - ok - empty
    print(f"итог: переснято {ok} · без дороги {empty} · пропущено {skipped}")
    print(f"база-кандидат: {args.out} · отчёт: {args.report}")
    print("\nдалее: отчёт глазами → deploy_db.sh <v+1> с кандидатом → опубликовать")
    print("overrides.json без влитых move-строк (иначе перенос применится дважды).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
