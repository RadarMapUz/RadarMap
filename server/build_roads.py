#!/usr/bin/env python3
"""Сборка дорожных тайлов для схемы на приборке.

Зачем. Приложение чертит окрестные дороги само, без карты и без сети: приборка
это режим «телефон в держателе», и она обязана быть самым дешёвым экраном, а
не самым дорогим. Первым источником служил индекс лимитов скорости — он уже на
телефоне и несёт настоящую геометрию, но НЕ ЗНАЕТ ни класса дороги, ни моста,
ни односторонности, ни дворов. Всё это есть в OSM, и этот скрипт достаёт
именно их.

Вход:  roads.geojsonl — выгрузка OSM в формате GeoJSON Text Sequence
       (RFC 8142: каждая запись начинается с байта 0x1E — обычный json.loads
       по строке на нём падает, и это первое, обо что тут спотыкаешься).
Выход: каталог тайлов по 0.5° (~55 км) + index_payload.json.

Тайлы, а не один файл: вся страна — десятки мегабайт, а телефону нужна
окрестность. Дорога, задевшая несколько тайлов, кладётся в КАЖДЫЙ из них
целиком — дубль на границе стоит килобайты, а склейка по границам стоила бы
клиенту кода и ошибок.

Целостность: index_payload.json несёт sha256 каждого тайла. Владелец
подписывает ЕГО (publish_roads.sh, Ed25519-ключ живёт только у владельца) —
и подпись индекса накрывает все тайлы разом: подменённый на сервере или по
дороге тайл не сойдётся по хэшу и будет отброшен телефоном.

Формат тайла (экономия важнее читаемости — файл едет на телефоны):

    {"version": 1, "roads": [[cls, flags, [lat, lon, dlat, dlon, …]], …]}

    cls    — код класса дороги (см. CLASS_CODES)
    flags  — биты: 1 = одностороннее, 2 = мост, 4 = тоннель
    коорды — первая точка абсолютная в 1e-5°, дальше ДЕЛЬТЫ в тех же единицах.
             1e-5° ≈ 1,1 м: мельче для схемы бессмысленно, а дельты в целых
             жмутся gzip в разы лучше, чем полные числа с плавающей точкой.

Индекс по сетке строит уже приложение при загрузке — так же, как для лимитов.
Дублировать его в файле значило бы возить одно и то же дважды.

Запуск на VPS (обычно через publish_roads.sh с локальной машины владельца):
    python3 build_roads.py --in /opt/radarmap/work/roads.geojsonl \\
                          --tiles /opt/radarmap/work/roads_tiles
"""
import argparse
import hashlib
import json
import math
import os
import sys
from collections import Counter, defaultdict

# Что рисуем. Пешеходное, тропы и велодорожки не берём: схема про то, где
# едет машина, а лишние линии превращают её в паутину.
CLASS_CODES = {
    "motorway": 1, "motorway_link": 1,
    "trunk": 2, "trunk_link": 2,
    "primary": 3, "primary_link": 3,
    "secondary": 4, "secondary_link": 4,
    "tertiary": 5, "tertiary_link": 5,
    "residential": 6, "unclassified": 6, "living_street": 6,
    "service": 7,
}

FLAG_ONEWAY, FLAG_BRIDGE, FLAG_TUNNEL = 1, 2, 4

# Упрощение: 4 м — на схеме шириной в пару сотен метров разницы не видно,
# а точек становится в разы меньше.
SIMPLIFY_METERS = 4.0
SCALE = 1e5   # 1e-5° ≈ 1,1 м

# Тайл 0.5° ≈ 55 км: город с окрестностями в одном-двух файлах, а вся страна —
# в паре сотен, из которых телефон возит только соседние.
TILE_DEGREES = 0.5


def tile_key(lat, lon, degrees=TILE_DEGREES):
    """Ключ тайла: смещаем в положительные, чтобы не спорить об округлении
    отрицательных (и клиент делает ровно то же самое)."""
    return f"{int(math.floor((lat + 90) / degrees))}_{int(math.floor((lon + 180) / degrees))}"


def tile_keys_of(points, degrees=TILE_DEGREES):
    """Все тайлы, которых касается дорога (GeoJSON: [lon, lat])."""
    return {tile_key(lat, lon, degrees) for lon, lat in points}


def perpendicular_distance(point, start, end):
    """Расстояние от точки до отрезка в градусах, с поправкой на широту."""
    lat_scale = math.cos(math.radians(point[1]))
    px, py = (point[0] - start[0]) * lat_scale, point[1] - start[1]
    ex, ey = (end[0] - start[0]) * lat_scale, end[1] - start[1]
    norm = ex * ex + ey * ey
    if norm == 0:
        return math.hypot(px, py)
    t = max(0.0, min(1.0, (px * ex + py * ey) / norm))
    return math.hypot(px - ex * t, py - ey * t)


def simplify(points, tolerance_deg):
    """Дуглас-Пекер, итеративно (рекурсия на длинных трассах упирается в лимит)."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        worst, worst_index = 0.0, -1
        for i in range(lo + 1, hi):
            d = perpendicular_distance(points[i], points[lo], points[hi])
            if d > worst:
                worst, worst_index = d, i
        if worst > tolerance_deg and worst_index > 0:
            keep[worst_index] = True
            stack.append((lo, worst_index))
            stack.append((worst_index, hi))
    return [p for p, k in zip(points, keep) if k]


def encode(points):
    """Первая точка абсолютная, дальше дельты — всё в целых 1e-5°."""
    out = []
    previous_lat = previous_lon = None
    for lon, lat in points:   # GeoJSON: [lon, lat]
        ilat, ilon = round(lat * SCALE), round(lon * SCALE)
        if previous_lat is None:
            out.extend((ilat, ilon))
        else:
            # Нулевые дельты выбрасываем: после квантования соседние точки
            # часто совпадают, и это чистый мусор в файле.
            if ilat == previous_lat and ilon == previous_lon:
                continue
            out.extend((ilat - previous_lat, ilon - previous_lon))
        previous_lat, previous_lon = ilat, ilon
    return out


def flags_of(properties):
    flags = 0
    oneway = properties.get("oneway")
    if oneway in ("yes", "1", "true", "-1"):
        flags |= FLAG_ONEWAY
    if properties.get("bridge") not in (None, "no"):
        flags |= FLAG_BRIDGE
    if properties.get("tunnel") not in (None, "no"):
        flags |= FLAG_TUNNEL
    return flags


def collect(source_path, tolerance_deg):
    """Прочитать geojsonl → список (code, flags, encoded, tile_keys)."""
    roads = []
    classes, flag_counts = Counter(), Counter()
    read = skipped = 0

    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            # RFC 8142: запись начинается с разделителя 0x1E.
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                skipped += 1
                continue
            read += 1
            properties = feature.get("properties") or {}
            code = CLASS_CODES.get(properties.get("highway"))
            if code is None:
                continue
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "LineString":
                continue
            points = geometry.get("coordinates") or []
            if len(points) < 2:
                continue

            points = simplify(points, tolerance_deg)
            encoded = encode(points)
            if len(encoded) < 4:
                continue
            roads.append((code, flags_of(properties), encoded, tile_keys_of(points)))
            classes[properties["highway"]] += 1
            flag_counts[roads[-1][1]] += 1

    return roads, classes, flag_counts, read, skipped


def write_tiles(roads, target_dir):
    """Разложить дороги по тайлам и собрать индекс с sha256 каждого файла.

    Дорога, задевшая несколько тайлов, попадает в каждый целиком: дубль на
    границе дешевле, чем склейка на клиенте.
    """
    os.makedirs(target_dir, exist_ok=True)
    by_tile = defaultdict(list)
    for code, flags, encoded, keys in roads:
        for key in keys:
            by_tile[key].append([code, flags, encoded])

    index = {}
    for key, tile_roads in sorted(by_tile.items()):
        blob = json.dumps({"version": 1, "roads": tile_roads},
                          separators=(",", ":")).encode()
        with open(os.path.join(target_dir, f"tile_{key}.json"), "wb") as handle:
            handle.write(blob)
        index[key] = {"sha256": hashlib.sha256(blob).hexdigest(),
                      "bytes": len(blob)}

    # Байты индекса подписывает владелец (publish_roads.sh): подпись индекса
    # накрывает все тайлы разом через их sha256.
    payload = json.dumps({"version": 1, "tileDegrees": TILE_DEGREES,
                          "tiles": index},
                         separators=(",", ":")).encode()
    with open(os.path.join(target_dir, "index_payload.json"), "wb") as handle:
        handle.write(payload)
    return index


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="source", required=True)
    parser.add_argument("--tiles", dest="tiles_dir", required=True,
                        help="каталог, куда положить tile_*.json и index_payload.json")
    parser.add_argument("--tolerance", type=float, default=SIMPLIFY_METERS)
    args = parser.parse_args()

    roads, classes, flag_counts, read, skipped = collect(
        args.source, args.tolerance / 111_320.0)
    index = write_tiles(roads, args.tiles_dir)

    points_total = sum(len(r[2]) // 2 for r in roads)
    total_bytes = sum(meta["bytes"] for meta in index.values())
    biggest = max(index.items(), key=lambda kv: kv[1]["bytes"], default=None)
    print(f"прочитано объектов: {read} (не разобрано: {skipped})")
    print(f"дорог: {len(roads)}, точек: {points_total}, тайлов: {len(index)}")
    print(f"суммарно: {total_bytes / 1e6:.1f} МБ (в gzip будет в разы меньше)")
    if biggest:
        print(f"самый тяжёлый тайл: {biggest[0]} — {biggest[1]['bytes'] / 1e6:.1f} МБ")
    print("классы:", classes.most_common(10))
    bridges = sum(n for f, n in flag_counts.items() if f & FLAG_BRIDGE)
    tunnels = sum(n for f, n in flag_counts.items() if f & FLAG_TUNNEL)
    oneways = sum(n for f, n in flag_counts.items() if f & FLAG_ONEWAY)
    print(f"односторонних: {oneways}, мостов: {bridges}, тоннелей: {tunnels}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
