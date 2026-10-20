#!/usr/bin/env python3
"""resnap_profiles.py — пересъёмка дорожного профиля камер на ТОЙ ЖЕ точке (11.3).

Две группы камер базы живут без доверенного профиля:
  - снап посадил их на тротуар, ступени, платформу, остановку (cls footway/
    steps/platform/pedestrian/bus_stop — в v12 таких 39). Приложение такому
    профилю не верит (`Camera.hasTrustedRoadProfile`) и предупреждает о камере
    в обе стороны, по широкому коридору: безопасно, но шумно — и ось
    пешеходного перехода идёт ПОПЕРЁК дороги, так что починить надо, а не
    оставить как есть;
  - профиля нет вовсе (12 камер): рядом в выгрузке не нашлось дороги.

Что делает: для каждой такой камеры ищет под её точкой ПРОЕЗЖУЮ часть
(тротуары, тропы, ступени, платформы, грунтовки и стройки в индекс не
попадают вовсе) и выводит профиль тем же кодом, что полный снап
(snap_cameras.apply_road_profile). Координата НЕ двигается: перенос — это
отдельное решение (модератор, реестр), а профиль мерится там, где камера
стоит сейчас. Затем пары «камера ↔ встречная» (twin) переразмечаются по всей
базе — как в resnap_moved.py.

Правило выбора — асимметричное, как и весь конвейер оповещений: доверенный
профиль ГЛУШИТ камеру (гейт оси, «я не на её дороге»), а недоверенный только
шумит. Поэтому неверная дорога хуже, чем никакой, и профиль пишется только
по доказательству:
  1. ref трассы или имя улицы из адреса совпали с проезжей частью в радиусе;
  2. иначе — геометрия: ближайшая магистраль (tertiary и выше; если она не
     дальше ближайшей мелкой дороги на `MAJOR_MARGIN_M`), в пределах порога
     своего класса (`trust_limit`), и рядом нет ДРУГОЙ заметной проезжей
     части иного направления — на перекрёстке без имени не угадать, какую
     улицу снимает камера, и тогда профиль остаётся прежним (ambiguous).
     Мелкая дорога (service/двор) по одной геометрии берётся, только если
     магистрали в радиусе нет вовсе.
needsReview не трогается: точку человек не проверял.

Запуск (локально, ничего не публикует):
  python3 resnap_profiles.py --roads ~/RadarMapBuild/roads.geojsonl \
      --cameras ../RadarMap/Resources/cameras.json \
      --out review/cameras_v13_resnap_candidate.json \
      --report review/resnap_profiles_2026-10-20.csv

Дальше владелец: CSV глазами → deploy_db.sh 13 с кандидатом (подпись — только
его ключом). Тесты: python3 -W ignore -m unittest test_resnap_profiles
"""
import argparse
import csv
import json
import os
import sys

import snap_cameras as snap

#: Поля дорожного профиля (как в resnap_moved): переснимаются целиком — старые
#: мерены по тротуару и пережить пересъёмку не имеют права.
PROFILE_KEYS = ("axis", "dir", "lanes", "cls", "bridge", "road", "split", "twin")

#: Классы, которые приложение считает НЕ проезжей частью (RoadClass.pedestrian
#: в RoadShape.swift) — профиль с ними недоверенный.
PEDESTRIAN_CLASSES = frozenset(
    ("footway", "path", "cycleway", "steps", "pedestrian", "platform", "bus_stop"))

#: Проезжие части, на которых может стоять камера. Белый список, а не «всё,
#: кроме тротуаров»: грунтовка (track), стройка, гоночная трасса, автобусная
#: полоса (busway) и коридоры зданий тоже не дорога камеры реестра.
CARRIAGEWAY_CLASSES = frozenset((
    "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
    "residential", "living_street", "service", "road",
))

#: Радиус поиска проезжей части под точкой, м.
RADIUS_M = 40.0
#: Порог геометрии для мелкой дороги; класс выше — шире (trust_limit).
#: Точка лежит на тротуаре, а не на оси: от тротуара до оси магистрали
#: 15–35 м, отсюда базовые 16 вместо 10 у полного снапа.
TRUST_BASE_M = 16.0
#: Магистраль предпочитаем ближней мелкой дороге (боковой проезд, парковка),
#: если она дальше не больше чем на столько метров.
MAJOR_MARGIN_M = 15.0
#: Соседняя проезжая часть иного направления ближе pick + столько — перекрёсток.
AMBIGUITY_MARGIN_M = 15.0
#: «Иное направление» — оси расходятся больше чем на столько градусов.
AMBIGUITY_ANGLE = 30.0
#: Минимальный ранг соперника: service/living_street рядом с магистралью
#: (въезд во двор, карман) перекрёстком камеры не делают. У мелкой дороги
#: соперник — любая проезжая часть не ниже её самой (двор автовокзала).
AMBIGUITY_MIN_RANK = 2
#: Для отчёта: насколько далеко искать ближайшую проезжую часть у нерешённых.
REPORT_PROBE_M = 300.0


def is_carriageway(highway):
    return highway in CARRIAGEWAY_CLASSES


def needs_resnap(cam):
    """Почему камере нужен новый профиль: 'pedestrian' / 'no-profile' / None."""
    if cam.get("cls") in PEDESTRIAN_CLASSES:
        return "pedestrian"
    if cam.get("axis") is None and not cam.get("road"):
        return "no-profile"
    return None


def trust_limit(rank, base=TRUST_BASE_M):
    """Порог «камера на этой дороге» по классу — та же лестница, что у снапа."""
    return snap._trust_for_rank(rank, base)


def _axis_delta(a, b):
    d = abs(a - b) % 180
    return min(d, 180 - d)


def per_way(cands):
    """Ближайший кандидат каждой линии (nearby отдаёт куски, а нужен путь)."""
    seen, out = set(), []
    for cand in cands:
        if cand.way in seen:
            continue
        seen.add(cand.way)
        out.append(cand)
    return out


def choose_carriageway(cam, index, *, radius=RADIUS_M):
    """→ (cand, how, note). cand None — профиль не писать (how объясняет)."""
    cands = [c for c in per_way(index.nearby(cam["lat"], cam["lon"], radius))
             if c.axis is not None]
    if not cands:
        return None, "no_carriageway", f"нет проезжей части в {radius:.0f} м"

    location = cam.get("location", "")
    addr_refs = snap.ref_tokens_from_text(location)
    if addr_refs:
        matched = [c for c in cands if addr_refs & c.refs]
        if matched:
            ref = "/".join(sorted(addr_refs & matched[0].refs))
            return matched[0], "ref", f"ref «{ref}»"
    addr = snap.street_tokens(location)
    named = [c for c in cands if snap.tokens_match(addr, c.tokens)]
    if named:
        return named[0], "name", "имя «" + " ".join(sorted(named[0].tokens)) + "»"

    nearest = cands[0]
    pick = nearest
    major = [c for c in cands if c.rank >= 3]
    if major and major[0].dist <= nearest.dist + MAJOR_MARGIN_M:
        pick = major[0]
    limit = trust_limit(pick.rank)
    if pick.dist > limit:
        return None, "no_carriageway", (
            f"ближайшая {index.attrs[pick.way].cls} в {pick.dist:.0f} м — "
            f"дальше порога {limit:.0f} м, имя/ref не совпали")
    if pick.rank < 3 and major:
        # Мелкая дорога (карман остановки, двор), а магистраль в радиусе: камера
        # у остановки снимает скорее магистраль, а доверенный профиль кармана
        # заглушил бы её для всей проезжей части рядом.
        return None, "ambiguous", (
            f"{index.attrs[pick.way].cls} в {pick.dist:.0f} м, но рядом "
            f"{index.attrs[major[0].way].cls} в {major[0].dist:.0f} м")
    for other in cands:
        if other.way == pick.way or other.dist > pick.dist + AMBIGUITY_MARGIN_M:
            continue
        if other.rank < min(pick.rank, AMBIGUITY_MIN_RANK):
            continue
        if _axis_delta(other.axis, pick.axis) > AMBIGUITY_ANGLE:
            return None, "ambiguous", (
                f"перекрёсток без имени: {index.attrs[pick.way].cls} ось {pick.axis} "
                f"в {pick.dist:.0f} м и {index.attrs[other.way].cls} ось {other.axis} "
                f"в {other.dist:.0f} м")
    return pick, "geometry", f"геометрия, {index.attrs[pick.way].cls}"


def _profile(cam):
    return {k: cam[k] for k in PROFILE_KEYS if k in cam and k != "twin"}


def resnap_profiles(cameras, index, *, radius=RADIUS_M, notes=None):
    """Чистая часть. → (новый список камер, строки отчёта).

    Каждая камера копируется (dict), исходный список не меняется. Координата,
    id, тип, адрес и needsReview не трогаются ни у кого; профиль меняется
    только у камер из needs_resnap и только по доказательству; twin
    переразмечается по всей базе.
    """
    notes = notes or {}
    result = [dict(cam) for cam in cameras]
    rows = []
    for out in result:
        why = needs_resnap(out)
        if why is None:
            continue
        old = dict(out)
        cand, how, note = choose_carriageway(out, index, radius=radius)
        status = how if cand is None else "fixed"
        dist = ""
        if cand is not None:
            for key in PROFILE_KEYS:
                out.pop(key, None)
            out["axis"] = cand.axis
            snap.apply_road_profile(out, index, cand)
            dist = f"{cand.dist:.0f}"
            note = f"{how}: {note}"
            if _profile(out) == _profile(old):
                status = "unchanged"
        else:
            probe = per_way(index.nearby(out["lat"], out["lon"], REPORT_PROBE_M))
            if probe and how == "no_carriageway" and probe[0].dist > radius:
                note += (f"; ближайшая {index.attrs[probe[0].way].cls} "
                         f"в {probe[0].dist:.0f} м")
            elif not probe:
                note += f"; в {REPORT_PROBE_M:.0f} м проезжей части нет"
        if out["id"] in notes:
            note += f"; camera_fixes: {notes[out['id']]}"
        rows.append({
            "id": out["id"], "location": out.get("location", ""), "reason": why,
            "old_cls": old.get("cls", ""), "old_axis": old.get("axis", ""),
            "new_cls": out.get("cls", "") if cand else "",
            "new_axis": out.get("axis", "") if cand else "",
            "new_dir": out.get("dir", "") if cand else "",
            "new_lanes": out.get("lanes", "") if cand else "",
            "new_split": out.get("split", "") if cand else "",
            "dist_m": dist, "status": status, "note": note,
        })
    snap.mark_direction_twins(result)
    return result, rows


def verify_diff(old, new, allowed_ids):
    """Проверка кандидата против исходной базы. → dict счётчиков; бросает
    ValueError при любом расхождении вне дорожного профиля разрешённых камер.

    Разрешено: поля профиля у allowed_ids; twin у кого угодно (пары
    переразмечаются по всей базе). Всё остальное — id, порядок, координаты,
    тип, адрес, needsReview, профиль прочих камер — должно совпасть байт в байт.
    """
    if len(old) != len(new):
        raise ValueError(f"число камер: было {len(old)}, стало {len(new)}")
    profile_changed, twin_added, twin_removed = [], [], []
    for a, b in zip(old, new):
        if a.get("id") != b.get("id"):
            raise ValueError(f"порядок/id: {a.get('id')} ↔ {b.get('id')}")
        base_a = {k: v for k, v in a.items() if k not in PROFILE_KEYS}
        base_b = {k: v for k, v in b.items() if k not in PROFILE_KEYS}
        if base_a != base_b:
            raise ValueError(f"камера {a['id']}: изменились поля вне профиля")
        if _profile(a) != _profile(b):
            if a["id"] not in allowed_ids:
                raise ValueError(f"камера {a['id']}: профиль изменён без причины")
            profile_changed.append(a["id"])
        if bool(a.get("twin")) != bool(b.get("twin")):
            (twin_added if b.get("twin") else twin_removed).append(a["id"])
    return {"profile_changed": profile_changed, "twin_added": twin_added,
            "twin_removed": twin_removed}


def load_fix_notes(path):
    """id → проблема из review/camera_fixes_*.csv (там координаты, которые
    профилем не починить: обрезанная долгота, чужая область)."""
    if not path or not os.path.exists(path):
        return {}
    out = {}
    with open(path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                out[int(row["id"])] = row.get("проблема", "").strip()
            except (KeyError, ValueError):
                continue
    return out


REPORT_FIELDS = ("id", "location", "reason", "old_cls", "old_axis", "new_cls",
                 "new_axis", "new_dir", "new_lanes", "new_split", "dist_m",
                 "status", "note")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(
        description="Пересъёмка дорожного профиля камер на той же точке (11.3)")
    ap.add_argument("--roads", required=True, help="GeoJSON(seq) дорог OSM")
    ap.add_argument("--cameras", required=True, help="исходная база cameras.json")
    ap.add_argument("--out", required=True, help="база-кандидат")
    ap.add_argument("--report", required=True, help="CSV для просмотра")
    ap.add_argument("--fixes", default=os.path.join(here, "review",
                                                    "camera_fixes_2026-10-19.csv"))
    ap.add_argument("--radius", type=float, default=RADIUS_M)
    args = ap.parse_args()

    print(f"загрузка проезжих частей: {args.roads} …")
    index, _, _ = snap.load_roads(args.roads, keep_highway=is_carriageway)
    print(f"  кусков: {index.count}")
    cameras = json.load(open(args.cameras, encoding="utf-8"))
    targets = {c["id"] for c in cameras if needs_resnap(c)}
    print(f"камер: {len(cameras)} · к пересъёмке: {len(targets)}")

    result, rows = resnap_profiles(cameras, index, radius=args.radius,
                                   notes=load_fix_notes(args.fixes))
    stats = verify_diff(cameras, result, targets)

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    with open(args.report, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=REPORT_FIELDS)
        w.writeheader()
        w.writerows(rows)

    by_status = {}
    for row in rows:
        by_status[row["status"]] = by_status.get(row["status"], 0) + 1
    print("итог:", " · ".join(f"{k} {v}" for k, v in sorted(by_status.items())))
    print(f"diff: профиль у {len(stats['profile_changed'])} · twin +"
          f"{len(stats['twin_added'])} {stats['twin_added']} · twin −"
          f"{len(stats['twin_removed'])} {stats['twin_removed']}")
    print(f"кандидат: {args.out} · отчёт: {args.report}")
    print("далее (владелец): CSV глазами → deploy_db.sh 13 с кандидатом")
    return 0


if __name__ == "__main__":
    sys.exit(main())
