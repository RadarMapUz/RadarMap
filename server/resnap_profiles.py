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

Третья группа (14.11, --mode links) — профиль ЕСТЬ и приложение ему верит,
но снят с безымянного проезда, жилой улицы или съезда, хотя адрес называет
трассу («D006 … 23 km» — 2977 на unclassified поперёк D006). Правило — «решает
адрес»: профиль берётся с названной трассы (номер, кольцо, проспект) в
LINK_RADIUS_M, при перекрёстке двух трасс или улиц без номера — без изменений;
подробно — у resnap_links ниже.

Запуск (локально, ничего не публикует), два шага в один кандидат:
  python3 resnap_profiles.py --roads ~/RadarMapBuild/roads.geojsonl \
      --cameras ../RadarMap/Resources/cameras.json \
      --out review/cameras_v13_resnap_candidate.json \
      --report review/resnap_profiles_2026-10-20.csv
  python3 resnap_profiles.py --mode links --roads ~/RadarMapBuild/roads.geojsonl \
      --cameras review/cameras_v13_resnap_candidate.json \
      --out review/cameras_v13_resnap_candidate.json \
      --report review/resnap_links_2026-10-20.csv
Второй шаг идемпотентен: исправленные камеры уходят из его классов.

Дальше владелец: CSV глазами → deploy_db.sh 13 с кандидатом (подпись — только
его ключом). Тесты: python3 -W ignore -m unittest test_resnap_profiles
"""
import argparse
import collections
import csv
import json
import os
import re
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


# --- 14.11: снап на unclassified/residential/съезд при трассе в адресе ---------
#
# Третья группа: полный снап посадил камеру на дорогу, которая о проезжей части
# камеры почти ничего не говорит — безымянный проезд (unclassified), жилую
# улицу или съезд развязки (*_link), — хотя адрес называет трассу. Причина
# одна: «D006», «10V006», «4P85» узкий разбор номеров не видел (см.
# snap_cameras.highway_refs_in_text), и камера «D006 23 км» снапалась по
# геометрии на ближайший проезд — ПОПЕРЁК трассы. Приложение такому профилю
# верит (в minorSnapRoadClasses этих классов нет), и гейт оси глушит камеру
# для машин на самой трассе — тот же класс тишины, что 3135/3136 (прогон 13.3).
#
# Правило: решает адрес, а не близость.
#   - Трасса — номер дороги вне кавычек (в кавычках — описание маршрута:
#     «D002 "Toshkent — A373 (44 km)"» говорит о D002, не об A373) или
#     кольцо: «Txay» = D001, «Kxay» = Kichik halqa yo‘li. Ищем её проезжую
#     часть (не съезд) в LINK_RADIUS_M и берём профиль ближайшей.
#   - Трасса и улица на одном перекрёстке («D006 … 23 km bilan Furqat
#     ko‘chasi tutashgan chorraha»): трасса. Адрес привязан к её километру, а
#     радар на трассе — ровно та камера, которую глушил профиль проезда.
#   - Две трассы на перекрёстке («D006 … bilan 10V006 … kesishgan
#     chorraxa»): берём, только если обе найдены и идут одной осью; иначе
#     какую снимает камера, адрес не говорит — без изменений, в отчёт.
#   - Проспект/шоссе без номера («Amir Temur shoh ko‘chasi», «Farg‘ona yo‘li
#     ko‘chasi»): по имени, предпочтительно магистраль; на перекрёстке двух
#     улиц — без изменений (неоднозначно).
#   - Номер есть только у съезда, на котором стоит камера, — камера на
#     съезде, OSM с адресом согласен: без изменений.
#   - Трасса не найдена в радиусе — без изменений, в отчёт.
# Координата не двигается; needsReview не трогается.

#: Классы снапа, профиль которых 14.11 перепроверяет по адресу.
LINK_SNAP_CLASSES = frozenset((
    "unclassified", "residential", "motorway_link", "trunk_link",
    "primary_link", "secondary_link", "tertiary_link"))
#: Радиус поиска названной трассы, м. Точка камеры уже на оси съезда/проезда:
#: от неё до проезжей части трассы 0–22 м у всех найденных (замер по базе
#: v13, отчёт 14.11); следующая — 53 м (484: камера у перекрёстка ДРУГОЙ
#: дороги, D089 за ним). Дальше 40 м — уже не проезжая часть камеры.
LINK_RADIUS_M = 40.0
#: Ось новой дороги с той же, что у старой, и класс тот же — это та же
#: дорога, запись не трогаем (без лишних байтов в диффе).
SAME_ROAD_AXIS = 5
#: Кольцевые без номера в адресе: «Txay» (Toshkent halqa avtomobil yo‘li) —
#: D001; «Kxay» (Kichik halqa avtomobil yo‘li) номера в OSM не имеет, только имя.
RING_REFS = {"txay": "d1", "tkad": "d1"}
RING_NAMES = {"kxay": frozenset(("kichik", "halqa"))}
#: Слова перекрёстка (после транслита, вне кавычек).
_JUNCTION = re.compile(
    r"\b(kesish\w*|chorrah\w*|chorrax\w*|tutash\w*|bilan|va|perekrest\w*|peresech\w*)\b")
#: Проспект/шоссе/кольцо/объездная без номера — «дорога с именем».
_AVENUE = re.compile(
    r"\b(sho[hx]\s*ko\W?chasi|shohkochasi|prospekt\w*|shosse\w*|trakt\w*|"
    r"halqa|xalqa|aylanma|yo\W?li\s+ko\W?chasi)\b")
#: «Автомобильная дорога» без распознанного номера («4D072 avtomobil
#: yo‘lining 24 km») — трасса в адресе есть, но какая, не сказать.
_HIGHWAY_WORDS = re.compile(
    r"(?i)avtomobil\W+yo\W?l|avtoyo\W?l|(?<!\w)a/y(?!\w)|автомобил\w*\s+дорог|\btrassa")
_QUOTE_PAIRS = {'"': '"', "“": "”", "«": "»", "„": "“"}

AddressRoads = collections.namedtuple("AddressRoads",
                                      "highways avenue junction highway_word")
#: Трасса из адреса: kind 'ref' (key — канонический номер) или 'name' (key —
#: обязательные токены имени); label — для отчёта.
Highway = collections.namedtuple("Highway", "kind key label")


def _quoted_spans(text):
    """Отрезки текста в кавычках: [(начало, конец), …]. Незакрытая кавычка
    тянется до конца строки."""
    spans, i, n = [], 0, len(text)
    while i < n:
        close = _QUOTE_PAIRS.get(text[i])
        if close is None:
            i += 1
            continue
        j = text.find(close, i + 1)
        if j < 0:
            j = n
        spans.append((i, j))
        i = j + 1
    return spans


def _outside(text, spans):
    out, last = [], 0
    for a, b in spans:
        out.append(text[last:a])
        last = b + 1
    out.append(text[last:])
    return " ".join(out)


def address_roads(location):
    """Что адрес говорит о дороге камеры → AddressRoads.

    highways — трассы по порядку упоминания: номера вне кавычек (если вне
    кавычек номера нет — номер, с которого начинается кавычка: «"D025G"
    Samarqand…») и кольца-синонимы; avenue — в адресе проспект/шоссе/кольцо
    без номера; junction — адрес описывает перекрёсток; highway_word —
    «avtomobil yo‘li»/«A/y» (трасса названа, даже если номер не разобран).
    """
    text = location or ""
    spans = _quoted_spans(text)

    def inside(pos):
        return any(a <= pos <= b for a, b in spans)

    mentions = snap.highway_refs_in_text(text)
    outer = [m for m in mentions if not inside(m.pos)]
    if not outer:
        outer = [m for m in mentions if any(m.pos == a + 1 for a, _ in spans)]
    found = [(m.pos, Highway("ref", m.ref, m.text)) for m in outer]
    # Кольца ищем в исходном тексте: транслит сдвигает позиции (ч → ch).
    for word, ref in RING_REFS.items():
        for m in re.finditer(rf"(?i)\b{word}\b", text):
            if not inside(m.start()):
                found.append((m.start(), Highway("ref", ref, f"{m.group(0)} ({ref.upper()})")))
    for word, tokens in RING_NAMES.items():
        for m in re.finditer(rf"(?i)\b{word}\b", text):
            if not inside(m.start()):
                found.append((m.start(), Highway("name", tokens, m.group(0))))
    found.sort(key=lambda item: item[0])
    highways, seen = [], set()
    for _, hw in found:
        if (hw.kind, hw.key) not in seen:
            seen.add((hw.kind, hw.key))
            highways.append(hw)
    plain = snap.translit(_outside(text, spans)).translate(snap._PUNCT)
    return AddressRoads(highways=highways,
                        avenue=bool(_AVENUE.search(plain)),
                        junction=bool(_JUNCTION.search(plain)),
                        highway_word=bool(_HIGHWAY_WORDS.search(text)))


def is_link(cls):
    return bool(cls) and cls.endswith("_link")


def _carries(hw, cand):
    if hw.kind == "ref":
        return hw.key in cand.refs
    return hw.key <= cand.tokens


def _same_road_conflict(pick, others, margin=AMBIGUITY_MARGIN_M):
    """Та же дорога рядом под другой осью (развязка, кольцо, петля) — какая
    из её проезжих частей у камеры, не сказать."""
    for other in others:
        if other.way == pick.way or other.dist > pick.dist + margin:
            continue
        if _axis_delta(other.axis, pick.axis) > AMBIGUITY_ANGLE:
            return other
    return None


#: Решение 14.11 по одной камере. cand None — профиль не менять, и how
#: говорит почему: 'skip' (в адресе нет трассы/проспекта), 'not_found',
#: 'on_link', 'ambiguous'; иначе how — чем доказано: 'ref', 'ring', 'name'.
#: label — какую дорогу назвал адрес; dist — до неё, м (None — не нашлась и
#: в REPORT_PROBE_M).
Choice = collections.namedtuple("Choice", "cand how label note dist")


def choose_named_road(cam, index, *, radius=LINK_RADIUS_M):
    """Дорога, которую называет адрес камеры, рядом с её точкой → Choice."""
    roads = address_roads(cam.get("location", ""))
    if not roads.highways and not roads.avenue:
        if roads.highway_word:
            return Choice(None, "not_found", "трасса без номера",
                          "в адресе трасса, но номер не распознан", None)
        return Choice(None, "skip", "", "в адресе нет трассы или проспекта", None)
    lat, lon = cam["lat"], cam["lon"]

    def ways(r):
        cands = [c for c in per_way(index.nearby(lat, lon, r)) if c.axis is not None]
        return cands, [c for c in cands if not is_link(index.attrs[c.way].cls)]

    cands, main = ways(radius)

    def where(c):
        return f"{index.attrs[c.way].cls} ось {c.axis} в {c.dist:.0f} м"

    def farther(hw):
        """Названная дорога дальше радиуса — для отчёта, не для решения."""
        far = [c for c in ways(REPORT_PROBE_M)[1] if _carries(hw, c)]
        if not far:
            return f"; в {REPORT_PROBE_M:.0f} м её нет", None
        return f"; ближайшая её проезжая часть — {where(far[0])}", far[0].dist

    def hint():
        """Что за магистраль рядом, раз названной нет: часто дорога с ДРУГИМ
        номером — реестр и OSM нумеруют по-разному."""
        major = [c for c in main if c.rank >= 3]
        if not major:
            return ""
        c = major[0]
        what = "/".join(sorted(r.upper() for r in c.refs)) or "без номера"
        return f"; рядом {where(c)} ({what})"

    if roads.highways:
        hws = roads.highways
        if len(hws) >= 2 and roads.junction:
            label = " × ".join(h.label for h in hws)
            picks = []
            for hw in hws:
                found = [c for c in main if _carries(hw, c)]
                if not found:
                    more, dist = farther(hw)
                    return Choice(None, "ambiguous", label, (
                        f"перекрёсток трасс, {hw.label} в {radius:.0f} м не найдена "
                        f"— какую снимает камера, адрес не говорит{more}"),
                        min([p.dist for _, p in picks] + ([] if dist is None else [dist]),
                            default=None))
                picks.append((hw, found[0]))
            for hw, c in picks[1:]:
                if _axis_delta(c.axis, picks[0][1].axis) > AMBIGUITY_ANGLE:
                    return Choice(None, "ambiguous", label, (
                        f"перекрёсток трасс: {picks[0][0].label} — {where(picks[0][1])}, "
                        f"{hw.label} — {where(c)}"), min(p.dist for _, p in picks))
            hw, pick = min(picks, key=lambda item: item[1].dist)
            found = [c for c in main if _carries(hw, c)]
        else:
            hw = hws[0]
            label = hw.label
            found = [c for c in main if _carries(hw, c)]
            if not found:
                on_link = [c for c in cands if _carries(hw, c)]
                if on_link:
                    return Choice(None, "on_link", label, (
                        f"номер {hw.label} в OSM только у съезда ({where(on_link[0])}) "
                        "— камера на съезде, адрес с OSM согласен"), on_link[0].dist)
                more, dist = farther(hw)
                return Choice(None, "not_found", label, (
                    f"{hw.label} в {radius:.0f} м не найдена{more}{hint()}"), dist)
            pick = found[0]
        conflict = _same_road_conflict(pick, found)
        if conflict is not None:
            return Choice(None, "ambiguous", label, (
                f"{hw.label} рядом под двумя осями: {where(pick)} и {where(conflict)}"),
                pick.dist)
        note = f"{hw.label}: {where(pick)}"
        if roads.junction and len(hws) == 1:
            note += "; адрес — перекрёсток, трасса в нём одна: берём её"
        return Choice(pick, "ref" if hw.kind == "ref" else "ring", label, note, pick.dist)

    # Проспект/шоссе без номера — по имени.
    tokens = snap.street_tokens(cam.get("location", ""))
    label = "по имени: " + " ".join(sorted(tokens))
    if roads.junction:
        return Choice(None, "ambiguous", label, (
            "перекрёсток улиц без номера трассы — какую снимает камера, "
            "адрес не говорит"), None)
    named = [c for c in main if snap.tokens_match(tokens, c.tokens)]
    if not named:
        return Choice(None, "not_found", label,
                      f"улица из адреса в {radius:.0f} м не найдена{hint()}", None)
    # «Farg‘ona yo‘li ko‘chasi»: имя совпадает и у тупика «Farg‘ona berk» —
    # адрес говорит о проспекте, значит магистраль.
    named = [c for c in named if c.rank >= 3] or named
    pick = named[0]
    conflict = _same_road_conflict(pick, named)
    if conflict is not None:
        return Choice(None, "ambiguous", label, (
            f"по имени две дороги под разными осями: {where(pick)} и "
            f"{where(conflict)}"), pick.dist)
    return Choice(pick, "name", "по имени: " + " ".join(sorted(pick.tokens)),
                  where(pick), pick.dist)


def _dir_delta(a, b):
    d = abs(a - b) % 360
    return min(d, 360 - d)


def resnap_links(cameras, index, *, radius=LINK_RADIUS_M, notes=None):
    """Чистая часть 14.11. → (новый список камер, строки отчёта).

    Как resnap_profiles: камеры копируются, исходный список не меняется;
    координата, id, тип, адрес и needsReview не трогаются ни у кого; профиль
    меняется только у камер со снапом из LINK_SNAP_CLASSES и только по
    названной в адресе дороге; twin переразмечается по всей базе.
    """
    notes = notes or {}
    result = [dict(cam) for cam in cameras]
    rows = []
    for i, cam in enumerate(result):
        if cam.get("cls") not in LINK_SNAP_CLASSES:
            continue
        choice = choose_named_road(cam, index, radius=radius)
        status, note, new = choice.how, choice.note, None
        if choice.cand is not None:
            cand = choice.cand
            new = dict(cam)
            for key in PROFILE_KEYS:
                new.pop(key, None)
            new["axis"] = cand.axis
            snap.apply_road_profile(new, index, cand)
            note = f"{choice.how}: {note}"
            status = "fixed"
            old_axis = cam.get("axis")
            if (new.get("cls") == cam.get("cls") and old_axis is not None
                    and _axis_delta(old_axis, cand.axis) <= SAME_ROAD_AXIS):
                status, new = "unchanged", None
                note += "; камера уже на этой дороге"
            elif (cam.get("dir") is not None and new.get("dir") is not None
                  and old_axis is not None
                  and _axis_delta(old_axis, cand.axis) <= AMBIGUITY_ANGLE
                  and _dir_delta(cam["dir"], new["dir"]) > 90):
                # Съезд идёт вдоль трассы, а ближайшая её проезжая часть —
                # встречная: на чьей стороне камера, не сказать.
                status, new = "ambiguous", None
                note += (f"; направление: у съезда {cam['dir']}°, а ближайшая "
                         "проезжая часть трассы — встречная")
        if cam["id"] in notes:
            note += f"; camera_fixes: {notes[cam['id']]}"
        if new is not None:
            result[i] = new
        rows.append({
            "id": cam["id"], "location": cam.get("location", ""),
            "old_cls": cam.get("cls", ""), "old_axis": cam.get("axis", ""),
            "old_dir": cam.get("dir", ""), "named_road": choice.label,
            "new_cls": new.get("cls", "") if new else "",
            "new_axis": new.get("axis", "") if new else "",
            "new_dir": new.get("dir", "") if new else "",
            "new_split": new.get("split", "") if new else "",
            "dist_m": "" if choice.dist is None else f"{choice.dist:.0f}",
            "status": status, "note": note,
        })
    snap.mark_direction_twins(result)
    return result, rows


LINK_REPORT_FIELDS = ("id", "location", "old_cls", "old_axis", "old_dir",
                      "named_road", "new_cls", "new_axis", "new_dir",
                      "new_split", "dist_m", "status", "note")


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
        description="Пересъёмка дорожного профиля камер на той же точке (11.3, 14.11)")
    ap.add_argument("--mode", choices=("pedestrian", "links"), default="pedestrian",
                    help="pedestrian — тротуары и камеры без профиля (11.3); "
                         "links — unclassified/residential/съезды при трассе в адресе (14.11)")
    ap.add_argument("--roads", required=True, help="GeoJSON(seq) дорог OSM")
    ap.add_argument("--cameras", required=True, help="исходная база cameras.json")
    ap.add_argument("--out", required=True, help="база-кандидат")
    ap.add_argument("--report", required=True, help="CSV для просмотра")
    ap.add_argument("--fixes", default=os.path.join(here, "review",
                                                    "camera_fixes_2026-10-19.csv"))
    ap.add_argument("--radius", type=float, default=None,
                    help=f"радиус, м (по умолчанию {RADIUS_M:.0f} / {LINK_RADIUS_M:.0f})")
    args = ap.parse_args()
    links = args.mode == "links"
    radius = args.radius or (LINK_RADIUS_M if links else RADIUS_M)

    print(f"загрузка проезжих частей: {args.roads} …")
    # 14.11 сверяет номера трасс нового реестра (D006, 10V006) и old_ref.
    index, _, _ = snap.load_roads(
        args.roads, keep_highway=is_carriageway,
        refs_of=snap.highway_refs_from_props if links else None)
    print(f"  кусков: {index.count}")
    cameras = json.load(open(args.cameras, encoding="utf-8"))
    notes = load_fix_notes(args.fixes)
    if links:
        targets = {c["id"] for c in cameras if c.get("cls") in LINK_SNAP_CLASSES}
        print(f"камер: {len(cameras)} · снап на проезд/жилую/съезд: {len(targets)}")
        result, rows = resnap_links(cameras, index, radius=radius, notes=notes)
        fields = LINK_REPORT_FIELDS
    else:
        targets = {c["id"] for c in cameras if needs_resnap(c)}
        print(f"камер: {len(cameras)} · к пересъёмке: {len(targets)}")
        result, rows = resnap_profiles(cameras, index, radius=radius, notes=notes)
        fields = REPORT_FIELDS
    stats = verify_diff(cameras, result, targets)

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    with open(args.report, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
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
