#!/usr/bin/env python3
"""build_camera_candidates.py — «камеры, которых нет в базе»: очередь проверки.

База приложения — реестр МВД (3475 точек). Рядом есть ещё два источника,
которые с ним не сверялись: узлы OSM `highway=speed_camera` (их ставят
водители по факту) и областные наборы Статкомитета на data.egov.uz (Бухара,
Навои, Хорезм, Каракалпакстан — те же «онлайн фото-радары», но собранные
областью отдельно и в реестр МВД попавшие не все). Кандидат — точка из любого
из них дальше 300 м от любой камеры базы.

Что делает: читает OSM-выгрузку (pyosmium, локальный .osm.pbf), качает четыре
областных набора (structId вшиты; `--discover` ищет их заново по каталогу),
выбрасывает битые координаты (в Бухаре есть строки с lat=39809352 — потерянная
запятая, такое не чинится), схлопывает повторы одного места из разных
источников (50 м) и пишет `review/camera_candidates.json`. Админка показывает
файл разделом «Кандидаты (не в базе)» на экране «Положение» с кнопкой
«Отклонить»; ничего не публикует — как и всё в админке, в базу камера попадает
только руками владельца через deploy_db.sh.

`RadarMap/Resources/cameras.json` читается и НЕ меняется.

Запуск (на маке):
    python3 build_camera_candidates.py --pbf ~/RadarMapBuild/omt_langs/uzbekistan.osm.pbf
    python3 build_camera_candidates.py --pbf … --no-egov      # только OSM, без сети
Тесты (без сети и без большой выгрузки):
    python3 test_build_camera_candidates.py
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

PORTAL = "https://data.egov.uz"
API = PORTAL + "/apiClient/Main/GetMainData?GuidId={guid}"
CATALOG = PORTAL + "/apiClient/main/gettable?offset={offset}&limit=500&orderType=2"
#: Набор МВД по всей стране — это и есть база приложения, в кандидаты не идёт.
NATIONAL_GUID = "62735473d44f5eea297cef3d"
#: Областные наборы (каталог портала, найдены 12.10.2026). Ключ — суффикс
#: источника: "egov-buxoro". Пересобрать список: --discover.
REGIONAL = {
    "buxoro": "637f15614878653e5fe430a7",
    "navoiy": "637f15914878653e5fe430a9",
    "xorazm": "637f15214878653e5fe430a3",
    "qoraqalpogiston": "637f14df4878653e5fe42f3d",
}
#: Как узнать областной набор в каталоге: по русскому названию.
CATALOG_MARK = "онлайн фото-радарах"
REGION_KEYS = (("бухар", "buxoro"), ("навои", "navoiy"), ("хорезм", "xorazm"),
               ("каракалпак", "qoraqalpogiston"), ("самарканд", "samarqand"),
               ("ташкент", "toshkent"), ("ферган", "fargona"), ("андижан", "andijon"),
               ("наманган", "namangan"), ("кашкадар", "qashqadaryo"),
               ("сурхандар", "surxondaryo"), ("джизак", "jizzax"), ("сырдар", "sirdaryo"))

#: Дальше этого от любой камеры базы — кандидат. Ближе — та же камера:
#: реестр и OSM расходятся на десятки метров, снап базы — ещё на столько же.
MIN_DISTANCE_METERS = 300.0
#: Один кандидат из двух источников (OSM-узел и строка области) — одна запись.
SAME_SPOT_METERS = 50.0
LAT_RANGE = (37.0, 46.0)
LON_RANGE = (55.0, 74.0)
TIMEOUT = 60
RETRIES = 3
M_PER_DEG_LAT = 111_320.0
GRID = 0.01   # ~1 км; соседние 3×3 клетки накрывают любой радиус до 1 км


def distance(lat1, lon1, lat2, lon2):
    kx = M_PER_DEG_LAT * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lat2 - lat1) * M_PER_DEG_LAT, (lon2 - lon1) * kx)


def in_bounds(lat, lon):
    return LAT_RANGE[0] <= lat <= LAT_RANGE[1] and LON_RANGE[0] <= lon <= LON_RANGE[1]


# --- база камер (только чтение) ----------------------------------------------

def load_cameras(path):
    """[(lat, lon)] из cameras.json приложения. Файл не меняется."""
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    items = data.get("cameras", data) if isinstance(data, dict) else data
    return [(float(c["lat"]), float(c["lon"])) for c in items
            if isinstance(c, dict) and "lat" in c and "lon" in c]


class SpotIndex:
    """Сетка для вопроса «ближайшая точка в радиусе»: 3475 камер × 300
    кандидатов перебором — мелочь, но областные наборы растут, а OSM — тем
    более."""

    def __init__(self, points):
        self.cells = {}
        for lat, lon in points:
            self.cells.setdefault(self.key(lat, lon), []).append((lat, lon))

    @staticmethod
    def key(lat, lon):
        return int(math.floor(lat / GRID)), int(math.floor(lon / GRID))

    def nearest_meters(self, lat, lon):
        """До ближайшей точки, м; None — точек нет вовсе. Дальше соседних клеток
        (~1 км) — полным перебором: модератору «в 3,4 км от ближайшей камеры»
        говорит больше пустого поля (63 кандидата без расстояния, план 11.12)."""
        row, column = self.key(lat, lon)
        best = None
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                for other in self.cells.get((row + dr, column + dc), ()):
                    meters = distance(lat, lon, other[0], other[1])
                    if best is None or meters < best:
                        best = meters
        if best is None:
            for points in self.cells.values():
                for other in points:
                    meters = distance(lat, lon, other[0], other[1])
                    if best is None or meters < best:
                        best = meters
        return best


# --- OSM -----------------------------------------------------------------------

def candidate_from_node(node_id, lat, lon, tags):
    """Узел OSM → кандидат или None. Только highway=speed_camera: знаки
    `traffic_sign=…camera` и секции enforcement без точки нам не нужны."""
    if tags.get("highway") != "speed_camera":
        return None
    if not in_bounds(lat, lon):
        return None
    note_bits = [tags[key] for key in ("name:ru", "name", "description", "note")
                 if tags.get(key)]
    item = {"id": f"osm:{node_id}", "lat": round(lat, 6), "lon": round(lon, 6),
            "type": tags.get("enforcement") or "radar", "source": "osm",
            "note": " · ".join(dict.fromkeys(note_bits))}
    maxspeed = (tags.get("maxspeed") or "").strip()
    if maxspeed.isdigit():
        item["maxspeed"] = int(maxspeed)
    direction = (tags.get("direction") or "").strip()
    if direction:
        item["direction"] = direction
    return item


def osm_candidates(pbf_path):
    """Все узлы highway=speed_camera из выгрузки. pyosmium — только здесь."""
    import osmium

    class Handler(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.items = []

        def node(self, n):
            if n.tags.get("highway") != "speed_camera":
                return
            try:
                lat, lon = n.location.lat, n.location.lon
            except osmium.InvalidLocationError:
                return
            item = candidate_from_node(n.id, lat, lon, dict(n.tags))
            if item:
                self.items.append(item)

    handler = Handler()
    handler.apply_file(pbf_path)
    return handler.items


# --- портал ------------------------------------------------------------------

def cell_text(cell):
    if not isinstance(cell, dict):
        return ""
    text = cell.get("text")
    if isinstance(text, dict):
        for key in ("rusText", "uzbText", "uzbKrText"):
            if text.get(key):
                return str(text[key]).strip()
    for key in ("data", "default"):
        if cell.get(key) is not None and str(cell[key]).strip():
            return str(cell[key]).strip()
    return ""


def cell_number(cell):
    if not isinstance(cell, dict):
        return None
    value = cell.get("number")
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value != 0:
        return float(value)
    try:
        return float(cell_text(cell).replace(",", "."))
    except ValueError:
        return None


def tidy(value):
    """«РОМИТАН ТУМАНИ, А-380 …» в строке капсом — читается как крик;
    первой буквой каждого слова достаточно."""
    value = " ".join((value or "").split())
    if not value or value != value.upper() or not any(ch.isalpha() for ch in value):
        return value

    def word(w):
        letters = "".join(ch for ch in w if ch.isalpha())
        # Короткие аббревиатуры (ПДД, АЯЖ) и коды с цифрами (А-380) — как есть.
        if len(letters) <= 3 or any(ch.isdigit() for ch in w):
            return w
        return w[:1] + w[1:].lower()
    return " ".join(word(w) for w in value.split(" "))


def candidate_from_egov(region, row):
    """Строка областного набора → кандидат или None (битые координаты)."""
    columns = {k.lower(): v for k, v in (row.get("tableColumn") or {}).items()}
    lat = cell_number(columns.get("latitude") or columns.get("kenglik"))
    lon = cell_number(columns.get("longitude") or columns.get("uzunlik"))
    if lat is None or lon is None:
        return None
    if not in_bounds(lat, lon):
        if in_bounds(lon, lat):
            lat, lon = lon, lat
        else:
            return None
    place = tidy(cell_text(columns.get("joylashganjoyi")))
    district = tidy(cell_text(columns.get("tuman")))
    note = " · ".join(bit for bit in (district, place) if bit)
    return {"id": f"egov-{region}:{row.get('id') or ''}".rstrip(":"),
            "lat": round(lat, 6), "lon": round(lon, 6),
            "type": tidy(cell_text(columns.get("turi"))) or "radar",
            "source": f"egov-{region}", "note": note}


def fetch_page(guid, offset, limit, timeout=TIMEOUT):
    body = json.dumps({"guidId": guid, "fields": {}, "limit": limit, "offset": offset}).encode()
    request = urllib.request.Request(API.format(guid=guid), data=body,
                                     headers={"Content-Type": "application/json",
                                              "User-Agent": "RadarMap build_camera_candidates"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        result = json.load(response).get("result") or {}
    return result.get("data") or [], int(result.get("count") or 0)


def fetch_rows(guid, page=500, retries=RETRIES, fetch=fetch_page, sleep=time.sleep):
    rows, offset, total = [], 0, None
    while total is None or offset < total:
        for attempt in range(retries):
            try:
                chunk, total = fetch(guid, offset, page)
                break
            except (urllib.error.URLError, OSError, ValueError) as error:
                if attempt + 1 == retries:
                    raise RuntimeError(f"набор {guid}, страница {offset}: {error}") from error
                sleep(2 ** attempt)
        if not chunk:
            break
        rows.extend(chunk)
        offset += len(chunk)
    return rows


def egov_candidates(regional=None, fetch=fetch_rows):
    """Кандидаты всех областных наборов. Набор, который не скачался, пишется в
    stderr и пропускается: остальные области от этого не беднеют."""
    items = []
    for region, guid in sorted((regional or REGIONAL).items()):
        try:
            rows = fetch(guid)
        except RuntimeError as error:
            print(f"egov-{region}: {error}", file=sys.stderr)
            continue
        good = [c for c in (candidate_from_egov(region, row) for row in rows) if c]
        print(f"egov-{region}: строк {len(rows)}, с координатами {len(good)}", file=sys.stderr)
        items.extend(good)
    return items


def regional_sets_from_catalog(items):
    """Записи каталога → {регион: structId} для наборов про фото-радары, кроме
    общереспубликанского. Регион угадывается по названию; неизвестный
    получает ключ из structId, чтобы набор не потерялся молча."""
    found = {}
    for item in items:
        name = item.get("dataName") or {}
        title = (name.get("rusText") or "") if isinstance(name, dict) else str(name)
        guid = item.get("structId") or ""
        if CATALOG_MARK not in title.lower() or not guid or guid == NATIONAL_GUID:
            continue
        lower = title.lower()
        region = next((key for mark, key in REGION_KEYS if mark in lower), guid[-6:])
        found[region] = guid
    return found


def fetch_catalog(timeout=TIMEOUT):
    offset, items = 0, []
    while True:
        request = urllib.request.Request(CATALOG.format(offset=offset),
                                         headers={"User-Agent": "RadarMap build_camera_candidates"})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.load(response).get("result") or {}
        chunk = result.get("data") or []
        items.extend(chunk)
        offset += len(chunk)
        if not chunk or offset >= int(result.get("count") or 0):
            return items


# --- сборка ------------------------------------------------------------------

def build(osm_items, egov_items, cameras, *, min_distance=MIN_DISTANCE_METERS,
          same_spot=SAME_SPOT_METERS):
    """Кандидаты: дальше `min_distance` от базы, без повторов между
    источниками. OSM идёт первым — у него есть лимит и направление, — а
    совпавшая строка области дописывается в заметку, не теряясь."""
    base = SpotIndex(cameras)
    kept, taken = [], SpotIndex([])
    for item in list(osm_items) + list(egov_items):
        nearest = base.nearest_meters(item["lat"], item["lon"])
        if nearest is not None and nearest < min_distance:
            continue
        twin = None
        row, column = taken.key(item["lat"], item["lon"])
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                for other in taken.cells.get((row + dr, column + dc), ()):
                    if distance(item["lat"], item["lon"], other[0], other[1]) < same_spot:
                        twin = other
        if twin is not None:
            first = next(k for k in kept if (k["lat"], k["lon"]) == twin)
            first["also"] = sorted(set(first.get("also", [])) | {item["source"]})
            if item.get("note") and item["note"] not in first.get("note", ""):
                first["note"] = " · ".join(bit for bit in (first.get("note"), item["note"]) if bit)
            continue
        item = dict(item)
        item["nearest_m"] = None if nearest is None else int(round(nearest))
        kept.append(item)
        taken.cells.setdefault(taken.key(item["lat"], item["lon"]), []).append(
            (item["lat"], item["lon"]))
    kept.sort(key=lambda c: (c["source"], c["lat"], c["lon"]))
    return kept


def payload(candidates, camera_count, *, now, sources):
    return {"version": 1,
            "generated": time.strftime("%Y-%m-%d", time.gmtime(now)),
            "min_distance_m": MIN_DISTANCE_METERS,
            "cameras_in_db": camera_count,
            "sources": sources,
            "candidates": candidates}


def write_json(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    os.replace(tmp, path)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Кандидаты в камеры: OSM + областные наборы портала")
    ap.add_argument("--pbf", default=os.path.expanduser("~/RadarMapBuild/omt_langs/uzbekistan.osm.pbf"),
                    help="выгрузка OSM (.osm.pbf); --no-osm — без неё")
    ap.add_argument("--cameras", default=os.path.join(here, "..", "RadarMap", "Resources", "cameras.json"),
                    help="база приложения (только чтение)")
    ap.add_argument("--out", default=os.path.join(here, "review", "camera_candidates.json"))
    ap.add_argument("--no-osm", action="store_true", help="не читать OSM")
    ap.add_argument("--no-egov", action="store_true", help="не ходить на портал")
    ap.add_argument("--discover", action="store_true",
                    help="найти областные наборы по каталогу портала, а не по вшитым structId")
    args = ap.parse_args()

    try:
        cameras = load_cameras(args.cameras)
    except (OSError, ValueError, KeyError) as error:
        print(f"база камер не читается: {error}", file=sys.stderr)
        return 1
    if len(cameras) < 1000:
        print(f"в базе {len(cameras)} камер — похоже, не та база; стоп", file=sys.stderr)
        return 1

    osm_items, sources = [], []
    if not args.no_osm:
        try:
            osm_items = osm_candidates(args.pbf)
        except (OSError, RuntimeError, ImportError) as error:
            print(f"OSM не прочитан ({args.pbf}): {error}", file=sys.stderr)
            return 1
        sources.append("osm")
        print(f"osm: узлов highway=speed_camera {len(osm_items)}", file=sys.stderr)

    egov_items = []
    if not args.no_egov:
        regional = REGIONAL
        if args.discover:
            try:
                regional = regional_sets_from_catalog(fetch_catalog()) or REGIONAL
            except (urllib.error.URLError, OSError, ValueError) as error:
                print(f"каталог портала недоступен ({error}) — беру вшитый список", file=sys.stderr)
            print("областные наборы: " + ", ".join(f"{k}={v}" for k, v in sorted(regional.items())),
                  file=sys.stderr)
        egov_items = egov_candidates(regional)
        sources.extend(f"egov-{region}" for region in sorted(regional))

    candidates = build(osm_items, egov_items, cameras)
    write_json(args.out, payload(candidates, len(cameras), now=time.time(), sources=sources))
    by_source = {}
    for item in candidates:
        by_source[item["source"]] = by_source.get(item["source"], 0) + 1
    print(f"кандидатов: {len(candidates)} {by_source} → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
