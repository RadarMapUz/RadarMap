#!/usr/bin/env python3
"""Извлечение лимитов скорости (maxspeed) из выгрузки OSM.

ЭТОТ ФАЙЛ ДОЛГО ЖИЛ ТОЛЬКО НА СЕРВЕРЕ. Его не было ни в гите, ни в тестах, ни
в воротах публикации — в отличие от дорог, у которых есть и build_roads.py, и
roads_gate.py, и еженедельный прогон. Заметить это можно было только по дате
файла: speed_limits.json на бою был от 15 июля, потому что ежемесячный крон
выключили 19 июля вместе с пересборкой графа OSRM. Граф в 1.9 ГБ памяти этого
сервера не влезает — а лимитам граф не нужен вовсе, и они уехали на свалку
заодно с ним. Здесь эта связка разорвана: обновление лимитов не зависит от
OSRM (см. update_speed_limits.sh).

Что оно даёт и чего не даёт. Тег maxspeed стоит у 4.3% дорожных way страны
(23 715 из 549 454, замерено по июльской выгрузке). Остальное приложение
предполагает по классу дороги и по признаку «населённый пункт» — см.
RoadClass.assumedLimitKmh(inSettlement:). То есть этот файл покрывает малую
часть дорог, но именно ту, где лимит нестандартный: 60 на проспекте, 80 на
въезде в город. Ровно там догадка по классу и ошибается.

Выход: {"version": <unix_ts>, "segments": [[limit, [lat,lon,lat,lon,...]], ...]}
Координаты округлены до 5 знаков (~1.1 м). Пишет только при изменении
содержимого — иначе телефоны скачивали бы 3.4 МБ ради нового номера версии.
Поверх OSM накладываются официальные снижения (limit_overrides.py): тега там
нет, а знак уже стоит, и крон не должен их терять.

Стоимость прогона: 21 секунда, 567 МБ пика (замерено на бою 2026-09-01).
"""
import gzip
import hashlib
import json
import os
import sys
import time

import limit_overrides

PBF = os.environ.get("RADARMAP_PBF", "/opt/radarmap/osrm/uzbekistan-latest.osm.pbf")
OUT = os.environ.get("RADARMAP_LIMITS", "/opt/radarmap/www/speed_limits.json")
OVERRIDES = os.environ.get("RADARMAP_LIMIT_OVERRIDES", limit_overrides.DEFAULT_PATH)

# --- Ворота публикации.
#
# Тот же принцип, что в roads_gate.py: не доверять входу, который выглядит
# неправдоподобно. Выгрузка OSM может приехать обрезанной, osmium — упасть на
# середине; во всех этих случаях файл СОБИРАЕТСЯ УСПЕШНО и выглядит как обычный
# набор сегментов, просто меньше. Лимиты попадают прямо в «превышение» и в
# сумму штрафа на экране, поэтому тихая потеря половины — худший исход.
MAX_TOTAL_DELTA = 0.25
# Дорог с лимитом мало (4.3% от сети), и любая правка заметна в процентах.
# Ниже этого числа выгрузка заведомо битая.
MIN_SEGMENTS = 5000

# Код класса дороги. Контракт с клиентом: RoadClass в RadarMap/Models/RoadShape.swift
# читает ровно эти числа. Класс нужен, потому что лимит без него — половина
# ответа: вдоль ташкентского проспекта идёт дублёр, он параллелен и проходит
# проверку направления, а у проспекта тега maxspeed может не быть вовсе. Отличить
# их по одной геометрии нечем, и приложение объявляло лимит дублёра
# (docs/plan_drive_complaints.md, Ж2).
ROAD_CLASS_CODES = {
    "motorway": 1, "motorway_link": 1,
    "trunk": 2, "trunk_link": 2,
    "primary": 3, "primary_link": 3,
    "secondary": 4, "secondary_link": 4,
    "tertiary": 5, "tertiary_link": 5,
    "residential": 6, "living_street": 6, "unclassified": 6,
    "service": 7, "track": 7,
    "footway": 8, "path": 8, "cycleway": 8, "steps": 8, "pedestrian": 8,
    "platform": 8, "bus_stop": 8,
}


def road_class_code(raw):
    """OSM highway -> код класса; неизвестный тип — 0, как unknown у клиента."""
    return ROAD_CLASS_CODES.get(raw, 0)


def parse_limit(v):
    """"70", "70 km/h" -> 70; mph/none/signals/walk пропускаем."""
    v = v.strip().lower()
    if "mph" in v:
        return None
    parts = v.split()
    # Пустой тег maxspeed="" в OSM встречается, и прежний код падал на нём
    # IndexError — то есть один такой way ронял сборку лимитов ЦЕЛИКОМ, а
    # заметить это было негде: скрипт жил вне репозитория и вне тестов.
    if not parts:
        return None
    tok = parts[0].split(";")[0]
    try:
        n = int(tok)
    except ValueError:
        return None
    return n if 5 <= n <= 130 else None


def decide(previous_count, candidate_count):
    """(можно_публиковать, объяснение). Чистая функция — покрыта тестами."""
    if candidate_count < MIN_SEGMENTS:
        return False, "сегментов всего %d — выгрузка обрезана" % candidate_count
    if not previous_count:
        return True, "первая сборка: %d сегментов" % candidate_count
    delta = (candidate_count - previous_count) / previous_count
    if abs(delta) > MAX_TOTAL_DELTA:
        return False, "сегментов %d вместо %d (%+.0f%%) — так за месяц не бывает" % (
            candidate_count, previous_count, delta * 100)
    return True, "сегментов %d (было %d, %+.1f%%)" % (candidate_count, previous_count, delta * 100)


def previous_count(path):
    try:
        with open(path, encoding="utf-8") as f:
            return len(json.load(f).get("segments") or [])
    except (OSError, ValueError):
        return 0


# Пол лимита на магистралях — тот же, что EnforcedLimit.floorKmh в приложении.
#
# Замер 29.09.2026 по боевому файлу: в Ташкенте у 786 участков trunk, primary,
# secondary и tertiary записано 50 (ещё ~70 — 40 и 30). Это те самые улицы,
# где висят камеры, а камер на 50 в городе нет ни одной: фиксация начинается
# с 60 (владелец, 30.09.2026: «в городе радары все 60»). Для денег и рейтинга
# пол 60 в приложении уже стоял, а голос, HUD и знак продолжали говорить 50 —
# водитель слышал ограничение, которого камера не применяет, и переставал
# верить остальному. Пол ставится здесь, в данных, — все сборки приложения
# получают его со следующей выгрузкой, без релиза.
#
# Дворы и проезды (residential, service) не трогаем: 5–40 там — настоящие
# знаки у школ, парковок и въездов во двор, и камер там нет.
MAIN_ROAD_FLOOR_KMH = 60
MAIN_ROAD_CLASSES = {1, 2, 3, 4, 5}


def floor_main_roads(segments):
    """Поднять лимит ниже пола на магистралях. Возвращает, сколько поднято."""
    raised = 0
    for segment in segments:
        if segment[1] in MAIN_ROAD_CLASSES and segment[0] < MAIN_ROAD_FLOOR_KMH:
            segment[0] = MAIN_ROAD_FLOOR_KMH
            raised += 1
    return raised


def collect(pbf, wanted_refs=frozenset()):
    """Пройти выгрузку: [[limit, cls, [lat,lon,...]], ...], пропуски и way поправок.

    wanted_refs — ref дорог из limit_overrides.json: такие way запоминаются с
    узлами, даже если тега maxspeed у них нет. Именно они и нужны поправке.
    """
    import osmium

    class Handler(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.segments = []
            self.skipped = 0
            self.road_ways = []

        def way(self, w):
            highway = w.tags.get("highway")
            raw = w.tags.get("maxspeed")
            limit = parse_limit(raw) if raw is not None else None
            ref = w.tags.get("ref")
            wanted = (highway in limit_overrides.MAIN_HIGHWAYS
                      and bool(limit_overrides.normalize_ref(ref) & wanted_refs))
            if limit is None and not wanted:
                return
            nodes = []
            try:
                for n in w.nodes:
                    nodes.append((n.ref, round(n.lat, 5), round(n.lon, 5)))
            except osmium.InvalidLocationError:
                self.skipped += 1
                return
            if len(nodes) < 2:
                return
            cls = road_class_code(highway)
            segment = None
            if limit is not None:
                segment = [limit, cls, [value for _id, lat, lon in nodes for value in (lat, lon)]]
                self.segments.append(segment)
            if wanted:
                self.road_ways.append(limit_overrides.way_record(
                    w.id, highway, cls, w.tags.get("oneway"), ref, nodes, segment,
                    w.tags.get("junction")))

    h = Handler()
    h.apply_file(pbf, locations=True)
    return h.segments, h.skipped, h.road_ways


def overlay_overrides(segments, ways, doc):
    """Наложить поправки и вернуть (сегменты, отметка в файл). Сбой — в журнал.

    Крон не падает: старые сборки читают эти же файлы, и месячное обновление
    лимитов не должно зависеть от одной поправки. Подписанный набор такой файл
    не получит — его остановит гейт на маке (limit_overrides.check_built).
    """
    result, report = limit_overrides.apply_overrides(segments, ways, doc)
    for line in limit_overrides.describe(report):
        print(line)
    mark = {"sha": report["sha"], "applied": report["applied"], "failed": report["failed"]}
    return result, mark


def load_overrides(path):
    """Файл поправок или пустой набор с записью в журнал: крон должен дойти до конца."""
    try:
        return limit_overrides.load(path)
    except (OSError, ValueError) as error:
        print("ПОПРАВКИ НЕ ЗАГРУЖЕНЫ: %s" % error)
        return None


def write_published(path, body):
    """Файл и его .gz — одной операцией, и .gz ВСЕГДА вместе с файлом.

    nginx раздаёт каталог с `gzip_static on`: на запрос с Accept-Encoding: gzip
    (а URLSession шлёт его всегда) он отдаёт готовый path.gz, не глядя на сам
    файл. Этот скрипт годами обновлял только .json, и с 01.09 по 27.09.2026
    телефоны получали лимиты от 15 июля — из .gz, оставшегося от прежнего
    конвейера. Поэтому оба файла пишутся здесь, а не «где-то при выкладке».
    """
    data = body.encode()
    for target, payload in ((path + ".gz", gzip.compress(data, 9, mtime=0)),
                            (path, data)):
        tmp = target + ".tmp"
        with open(tmp, "wb") as f:
            f.write(payload)
        os.replace(tmp, target)


def companions_fresh(out):
    """Всё ли, что раздаётся рядом с out, на месте и не старше него.

    Хэш содержимого не видит отставших спутников: v2 мог не выкладываться
    никогда, .gz — остаться от прошлого конвейера. Тогда «unchanged» —
    неправда, и файлы надо переписать, даже если сегменты те же.
    """
    out_v2 = out.replace(".json", "_v2.json")
    for main_file in (out, out_v2):
        gz = main_file + ".gz"
        if not (os.path.exists(main_file) and os.path.exists(gz)):
            return False
        if gzip.decompress(open(gz, "rb").read()) != open(main_file, "rb").read():
            return False
    return True


def main():
    overrides = load_overrides(OVERRIDES)
    wanted = limit_overrides.wanted_refs(overrides) if overrides else frozenset()
    segments, skipped, road_ways = collect(PBF, wanted)
    print("пол %d на магистралях: поднято %d сегментов" % (
        MAIN_ROAD_FLOOR_KMH, floor_main_roads(segments)))
    mark = None
    if overrides:
        segments, mark = overlay_overrides(segments, road_ways, overrides)
    allowed, why = decide(previous_count(OUT), len(segments))
    print(why)
    if not allowed:
        print("ПУБЛИКАЦИЯ ОТМЕНЕНА: файл на бою не тронут")
        return 1

    # Хэш — по СОДЕРЖИМОМУ без версии: иначе номер версии менялся бы каждый
    # прогон, и телефоны качали бы 3.4 МБ ради одного и того же списка.
    # Отметка поправок — в хэш: снятая поправка без единого изменившегося
    # сегмента всё равно должна дойти до файла, иначе гейт на маке не сойдётся.
    new_hash = hashlib.sha256(
        json.dumps([segments, mark], separators=(",", ":"), sort_keys=True).encode()).hexdigest()
    hash_file = OUT + ".hash"
    old_hash = ""
    if os.path.exists(hash_file):
        with open(hash_file) as f:
            old_hash = f.read().strip()
    if new_hash == old_hash and companions_fresh(OUT):
        print("unchanged: %d segments" % len(segments))
        return 0

    # ДВА файла, и это не запас на будущее.
    #
    # Приложения с прошлых сборок читают segments как [limit, geometry] и на
    # записи из трёх элементов просто отбросят СЕГМЕНТ — то есть у них молча
    # исчезнут все лимиты. Поэтому старый файл остаётся байт в байт прежним, а
    # класс дороги едет во втором. Ровно так же в проекте разведены
    # roads_index.json и roads_index_v2.json.
    version = int(time.time())
    legacy = [[limit, flat] for limit, _cls, flat in segments]
    # Ключ limit_overrides клиент не читает (LimitIndex.Builder берёт только
    # segments); он нужен гейту публикации, и его не бывает без поправок.
    extra = {"limit_overrides": mark} if mark else {}
    body = json.dumps(dict({"version": version, "segments": legacy}, **extra),
                      separators=(",", ":"))
    write_published(OUT, body)

    body_v2 = json.dumps(dict({"version": version, "format": 2, "segments": segments}, **extra),
                         separators=(",", ":"))
    out_v2 = OUT.replace(".json", "_v2.json")
    write_published(out_v2, body_v2)

    with open(hash_file, "w") as f:
        f.write(new_hash)
    print("written: %d segments, %d KiB (+v2 %d KiB), skipped %d" % (
        len(segments), len(body) // 1024, len(body_v2) // 1024, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
