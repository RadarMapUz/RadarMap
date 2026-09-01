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

Стоимость прогона: 21 секунда, 567 МБ пика (замерено на бою 2026-09-01).
"""
import hashlib
import json
import os
import sys
import time

PBF = os.environ.get("RADARMAP_PBF", "/opt/radarmap/osrm/uzbekistan-latest.osm.pbf")
OUT = os.environ.get("RADARMAP_LIMITS", "/opt/radarmap/www/speed_limits.json")

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


def collect(pbf):
    """Пройти выгрузку и собрать [[limit, [lat,lon,...]], ...]."""
    import osmium

    class Handler(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.segments = []
            self.skipped = 0

        def way(self, w):
            raw = w.tags.get("maxspeed")
            if raw is None:
                return
            limit = parse_limit(raw)
            if limit is None:
                return
            flat = []
            try:
                for n in w.nodes:
                    flat.append(round(n.lat, 5))
                    flat.append(round(n.lon, 5))
            except osmium.InvalidLocationError:
                self.skipped += 1
                return
            if len(flat) >= 4:
                self.segments.append([limit, flat])

    h = Handler()
    h.apply_file(pbf, locations=True)
    return h.segments, h.skipped


def main():
    segments, skipped = collect(PBF)
    allowed, why = decide(previous_count(OUT), len(segments))
    print(why)
    if not allowed:
        print("ПУБЛИКАЦИЯ ОТМЕНЕНА: файл на бою не тронут")
        return 1

    # Хэш — по СОДЕРЖИМОМУ без версии: иначе номер версии менялся бы каждый
    # прогон, и телефоны качали бы 3.4 МБ ради одного и того же списка.
    new_hash = hashlib.sha256(
        json.dumps(segments, separators=(",", ":")).encode()).hexdigest()
    hash_file = OUT + ".hash"
    old_hash = ""
    if os.path.exists(hash_file):
        with open(hash_file) as f:
            old_hash = f.read().strip()
    if new_hash == old_hash:
        print("unchanged: %d segments" % len(segments))
        return 0

    body = json.dumps({"version": int(time.time()), "segments": segments},
                      separators=(",", ":"))
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.replace(tmp, OUT)
    with open(hash_file, "w") as f:
        f.write(new_hash)
    print("written: %d segments, %d KiB, skipped %d" % (
        len(segments), len(body) // 1024, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
