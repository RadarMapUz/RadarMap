#!/usr/bin/env python3
"""Граф трасс для маршрута без сети (план 19.10, 12б.10) — один файл на страну.

ЗАЧЕМ. На трассе Ташкент — Бухара связь пропадает на часы, а маршрут строит
наш OSRM на сервере: без сети приложение оставалось без маршрута вовсе.
Этап 1 — междугородние дороги (motorway/trunk/primary/secondary и их съезды)
одним файлом, по которому телефон сам ищет путь A* (OfflineRouteGraph.swift).
Улиц города здесь нет намеренно: подъезд к трассе телефон рисует прямой и
честно подписывает маршрут как приблизительный.

ФОРМАТ — РОВНО формат дорожного тайла (build_roads.py), который приложение
уже разбирает (RoadTiles.decodeTile), — второй разборщик стоил бы кода и
расхождений:

    {"version": 1, "roads": [[code, flags, [lat0, lon0, dlat, dlon, …]], …]}

    code   — класс дороги по build_roads.CLASS_CODES, здесь только 1–4
    flags  — 1 = одностороннее ПО ПОРЯДКУ ТОЧЕК (oneway=-1 уже развёрнут),
             8 = кольцо (развязка-круг; телефон ведёт по нему по ходу точек)
    коорды — первая точка абсолютная в целых 1e-5°, дальше дельты
             (build_roads.encode). Имён нет: графу они не нужны.

ТОПОЛОГИЯ ДЕРЖИТСЯ НА КООРДИНАТАХ. Телефон считает одним узлом точки с
одинаковыми целыми 1e-5° — других связей между линиями в файле нет. Отсюда
три правила сборки:
  1. узел перекрёстка — точка (после квантования), которую делят две линии
     или больше, плюс концы каждой линии;
  2. упрощение (Дуглас—Пекер, ~10 м) идёт КУСКАМИ между такими узлами и не
     выбрасывает ни одного из них: стёртый узел — это разорванный граф,
     то есть «маршрута нет» посреди трассы (ровно этим упрощение и ломало
     топологию в build_roads, см. collect());
  3. квантование — ДО поиска узлов: две линии, чьи общие вершины совпали в
     1e-5°, обязаны дать на телефоне один и тот же узел, а не два в метре
     друг от друга.

ОДНОСТОРОННОСТЬ — по правилам OSRM, а не только по тегу: кольцевая развязка и
motorway односторонние и без oneway=yes. Ошибка тут дороже, чем на схеме:
стрелка не в ту сторону на картинке — некрасиво, маршрут по встречной —
опасно. Реверсивные (oneway=reversible/alternating) не берём вовсе: куда по
ним едут сейчас, файл не знает.

ЦЕЛОСТНОСТЬ — как у лимитов (build_limits_index.py): подписывается маленький
индекс с sha256 и размером файла, файл лежит под именем с хэшем
(route_graph.<sha16>.json) — содержимое по такому адресу не меняется никогда.
Подпись ставит владелец у себя (publish_route_graph.sh); этот скрипт ничего
не подписывает и никуда не ходит.

    python3 build_route_graph.py --input roads.geojsonl --out-dir stage/
    python3 build_route_graph.py --verify stage/     # ворота перед подписью
"""
import argparse
import gzip
import hashlib
import json
import os
import sys
import time
from collections import Counter

import build_roads

# Классы графа: motorway, trunk, primary, secondary и их _link (коды 1–4).
# Третьестепенные и ниже — уже город и сёла, и вся страна с ними — десятки
# мегабайт: этапу 1 они не по карману.
MAX_CLASS = 4
ROUTE_CLASSES = {highway: code for highway, code in build_roads.CLASS_CODES.items()
                 if code <= MAX_CLASS}

FLAG_ONEWAY = build_roads.FLAG_ONEWAY
FLAG_RING = build_roads.FLAG_RING

# Допуск упрощения. Графу нужна длина ребра и линия на экране, а не кромка
# полотна: 10 м на трассе — меньше ширины дороги, а точек в разы меньше.
SIMPLIFY_METERS = 10.0

# Версия формата САМОГО файла — та же, что у тайла v1 (RoadTiles.formatVersion):
# телефон разбирает граф тем же decodeTile.
GRAPH_VERSION = 1

# Формат индекса и формат файла в нём — контракт с RouteGraphManifest
# (RadarMap/Services/OfflineRouteService.swift: indexFormat, dataFormat).
INDEX_FORMAT = 1
DATA_FORMAT = 1

# Имя файла. Без каталога: телефон сам кладёт его в routes/ при загрузке
# («routes/» + name) и по префиксу route_graph. чистит старые копии у себя.
NAME_PREFIX = "route_graph"
# Каталог в вебруте — для publish_route_graph.sh, здесь только для справки.
PUBLISHED_DIR = "routes"
# 64 бита sha в имени — как у лимитов: случайно не совпадут, а в логах читаемо.
NAME_SHA_CHARS = 16

# Ворота перед подписью. Верх — с запасом ниже AppConfig.offlineGraphMaxBytes
# (16 МБ): файл больше телефон отвергнет, и узнали бы мы это от пользователей.
# Низ и число линий — от обрезанного экстракта: подписанный огрызок страны
# хуже старого графа.
MIN_BYTES = 500_000
MAX_BYTES = 12_000_000
MIN_WAYS = 5_000

# oneway в OSM: что значит «по ходу точек», «против», «в обе стороны».
ONEWAY_FORWARD = ("yes", "1", "true")
ONEWAY_BACKWARD = ("-1",)
ONEWAY_NO = ("no", "0", "false")
ONEWAY_UNKNOWN_DIRECTION = ("reversible", "alternating")
RING_JUNCTIONS = ("roundabout", "circular")


def tolerance_degrees(meters=SIMPLIFY_METERS):
    """Допуск в градусах для build_roads.simplify (он меряет в градусах широты)."""
    return meters / build_roads.LAT_METERS


def oneway_of(properties):
    """True/False — одностороннее или нет; None — дорогу в граф не брать.

    Неявная односторонность — как в профиле car.lua нашего OSRM: кольцо и
    motorway. Явный oneway=no её снимает.
    """
    value = str(properties.get("oneway", "")).strip().lower()
    if value in ONEWAY_UNKNOWN_DIRECTION:
        return None
    if value in ONEWAY_FORWARD or value in ONEWAY_BACKWARD:
        return True
    if value in ONEWAY_NO:
        return False
    if properties.get("junction") in RING_JUNCTIONS:
        return True
    return properties.get("highway") == "motorway"


def quantized(points):
    """[lon, lat] из GeoJSON → [(ilat, ilon)] в целых 1e-5° без нулевых шагов.

    Квантуем ДО поиска узлов (правило 3 в шапке) и тем же округлением, что
    build_roads._node и encode — иначе узел здесь и узел в файле разошлись бы.
    """
    out = []
    for point in points:
        node = build_roads._node((float(point[0]), float(point[1])))
        if not out or out[-1] != node:
            out.append(node)
    return out


def read_ways(source_path):
    """geojsonl → [(code, flags, [(ilat, ilon), …])] по ходу движения.

    Читается так же, как build_roads.collect: RFC 8142, байт 0x1E в начале
    записи, битые строки пропускаются (и считаются).
    """
    ways = []
    skipped = reversible = 0
    with open(source_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                skipped += 1
                continue
            properties = feature.get("properties") or {}
            code = ROUTE_CLASSES.get(properties.get("highway"))
            if code is None:
                continue
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "LineString":
                continue
            raw = geometry.get("coordinates") or []
            if len(raw) < 2:
                continue
            oneway = oneway_of(properties)
            if oneway is None:
                reversible += 1
                continue
            # oneway=-1 — разворачиваем здесь, тем же build_roads.oriented:
            # телефон знает только «по ходу точек».
            points = quantized(build_roads.oriented(raw, properties))
            if len(points) < 2:
                continue
            flags = FLAG_ONEWAY if oneway else 0
            # Кольцо — только развязка-круг, и только одностороннее. Замкнутая
            # по геометрии дорога (петля объезда) бывает двусторонней, а телефон
            # ведёт по кольцу строго по ходу точек — флаг отрезал бы ей
            # встречное направление.
            if oneway and properties.get("junction") in RING_JUNCTIONS:
                flags |= FLAG_RING
            ways.append((code, flags, points))
    return ways, {"skipped": skipped, "reversible": reversible}


def junction_nodes(ways):
    """Узлы, которые нельзя выбрасывать: общие для 2+ вхождений и концы линий.

    Считаются ВХОЖДЕНИЯ, а не линии: точка, дважды стоящая в одной линии
    (петля, замкнутое кольцо), — тоже узел, через него идёт ветвление.
    """
    seen = Counter()
    for _code, _flags, points in ways:
        seen.update(points)
    nodes = {node for node, count in seen.items() if count >= 2}
    for _code, _flags, points in ways:
        nodes.add(points[0])
        nodes.add(points[-1])
    return nodes


def simplify_way(points, anchors, tolerance_deg):
    """Дуглас—Пекер кусками между узлами: узлы и концы остаются ВСЕ.

    build_roads.simplify держит концы куска — значит, разрезав линию по
    узлам, мы держим каждый узел. Точки идут в него как (lon, lat, номер):
    расстояние он считает по первым двум, а номер возвращает нас к ТОЧНЫМ
    целым координатам — без обратного пересчёта из float.
    """
    if len(points) < 3:
        return list(points)
    cuts = [0] + [i for i in range(1, len(points) - 1) if points[i] in anchors] \
        + [len(points) - 1]
    kept = [0]
    for lo, hi in zip(cuts, cuts[1:]):
        piece = [(points[i][1] / build_roads.SCALE, points[i][0] / build_roads.SCALE, i)
                 for i in range(lo, hi + 1)]
        kept.extend(point[2] for point in build_roads.simplify(piece, tolerance_deg)[1:])
    out = []
    for i in kept:
        # Выброшенная середина «туда-обратно» оставляет два одинаковых узла
        # подряд — нулевое ребро графу не нужно.
        if not out or out[-1] != points[i]:
            out.append(points[i])
    return out


def encoded(points):
    """Целые (ilat, ilon) → дельты формата тайла через build_roads.encode.

    Обратный пересчёт i / 1e5 * 1e5 возвращает ровно i после round(), так что
    файл несёт те же целые, по которым здесь искались узлы.
    """
    return build_roads.encode([(lon / build_roads.SCALE, lat / build_roads.SCALE)
                               for lat, lon in points])


def build_graph(ways, tolerance_deg=None):
    """Линии → (документ графа, статистика). Чистая функция, без диска."""
    tolerance_deg = tolerance_degrees() if tolerance_deg is None else tolerance_deg
    anchors = junction_nodes(ways)
    roads = []
    points_in = points_out = 0
    classes, oneway = Counter(), 0
    for code, flags, points in ways:
        simple = simplify_way(points, anchors, tolerance_deg)
        points_in += len(points)
        if len(simple) < 2:
            continue
        roads.append([code, flags, encoded(simple)])
        points_out += len(simple)
        classes[code] += 1
        oneway += 1 if flags & FLAG_ONEWAY else 0
    # Узлы, реально соединяющие линии (не просто концы): для печати.
    shared = Counter()
    for _code, _flags, points in ways:
        shared.update(set(points))
    stats = {
        "ways": len(roads),
        "points_in": points_in,
        "points": points_out,
        "junctions": sum(1 for count in shared.values() if count >= 2),
        "anchors": len(anchors),
        "oneway": oneway,
        "classes": dict(sorted(classes.items())),
    }
    return {"version": GRAPH_VERSION, "roads": roads}, stats


def encode_graph(doc):
    """Байты файла. Детерминированно: тот же экстракт — тот же sha и то же имя."""
    return json.dumps(doc, separators=(",", ":")).encode("utf-8")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def published_name(sha):
    """route_graph.<sha16>.json — адрес, содержимое которого не меняется."""
    return "%s.%s.json" % (NAME_PREFIX, sha[:NAME_SHA_CHARS])


def build_payload(data, version):
    """Индекс: {format, version, files: [{format, name, sha256, bytes}]}."""
    if not isinstance(version, int) or isinstance(version, bool) or version <= 0:
        raise ValueError("версия графа должна быть целым > 0, а не %r" % (version,))
    sha = sha256_hex(data)
    return {
        "format": INDEX_FORMAT,
        "version": version,
        "files": [{
            "format": DATA_FORMAT,
            "name": published_name(sha),
            "sha256": sha,
            "bytes": len(data),
        }],
    }


def encode_payload(payload):
    """Байты, которые подписываются (как build_limits_index.encode_payload)."""
    return json.dumps(payload, separators=(",", ":"), sort_keys=True,
                      ensure_ascii=False).encode("utf-8")


def write_stage(out_dir, data, payload):
    """Файл под именем с хэшем + index_payload.json — то, что поедет на сервер."""
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, payload["files"][0]["name"]), "wb") as handle:
        handle.write(data)
    with open(os.path.join(out_dir, "index_payload.json"), "wb") as handle:
        handle.write(encode_payload(payload))


def check_graph(data, min_bytes=None, max_bytes=None, min_ways=None):
    """Ворота: файл похож на сборку этого скрипта и телефон его примет.

    Проверка строгая и по ВСЕМ записям: телефон отбрасывает битый файл
    целиком, и подписать такой — значит оставить всех без графа до
    следующей публикации. Возвращает число линий; на дефекте — ValueError.
    Пороги по умолчанию — константы модуля на момент вызова.
    """
    min_bytes = MIN_BYTES if min_bytes is None else min_bytes
    max_bytes = MAX_BYTES if max_bytes is None else max_bytes
    min_ways = MIN_WAYS if min_ways is None else min_ways
    if not min_bytes <= len(data) <= max_bytes:
        raise ValueError("размер %d вне [%d, %d]" % (len(data), min_bytes, max_bytes))
    try:
        doc = json.loads(data)
    except ValueError as error:
        raise ValueError("не JSON (%s)" % error)
    if not isinstance(doc, dict) or doc.get("version") != GRAPH_VERSION:
        raise ValueError("нет \"version\": %d" % GRAPH_VERSION)
    roads = doc.get("roads")
    if not isinstance(roads, list):
        raise ValueError("нет списка roads")
    for position, entry in enumerate(roads):
        if not isinstance(entry, list) or len(entry) != 3:
            raise ValueError("запись %d не из трёх полей" % position)
        code, flags, flat = entry
        if not isinstance(code, int) or isinstance(code, bool) or not 1 <= code <= MAX_CLASS:
            raise ValueError("запись %d — класс %r" % (position, code))
        if not isinstance(flags, int) or isinstance(flags, bool) \
                or flags & ~(FLAG_ONEWAY | FLAG_RING):
            raise ValueError("запись %d — флаги %r" % (position, flags))
        if (not isinstance(flat, list) or len(flat) < 4 or len(flat) % 2
                or not all(isinstance(v, int) and not isinstance(v, bool) for v in flat)):
            raise ValueError("запись %d — геометрия битая" % position)
    if len(roads) < min_ways:
        raise ValueError("линий всего %d — экстракт обрезан?" % len(roads))
    return len(roads)


def verify_stage(stage_dir, **gates):
    """Ворота на каталоге сборки: индекс ↔ файл (sha, размер, имя) + check_graph.

    Именно это publish_route_graph.sh запускает на маке перед подписью: под
    подпись идёт payload, sha которого пересчитан ЗДЕСЬ от этих байтов.
    """
    with open(os.path.join(stage_dir, "index_payload.json"), "rb") as handle:
        raw = handle.read()
    payload = json.loads(raw)
    if raw != encode_payload(payload):
        raise ValueError("index_payload.json не в каноническом виде")
    if payload.get("format") != INDEX_FORMAT:
        raise ValueError("формат индекса %r" % payload.get("format"))
    version = payload.get("version")
    if not isinstance(version, int) or isinstance(version, bool) or version <= 0:
        raise ValueError("версия %r" % (version,))
    files = payload.get("files")
    if not isinstance(files, list) or len(files) != 1:
        raise ValueError("в индексе не один файл")
    entry = files[0]
    if sorted(entry) != ["bytes", "format", "name", "sha256"] or entry["format"] != DATA_FORMAT:
        raise ValueError("запись файла не по контракту: %r" % entry)
    with open(os.path.join(stage_dir, entry["name"]), "rb") as handle:
        data = handle.read()
    if entry["bytes"] != len(data) or entry["sha256"] != sha256_hex(data):
        raise ValueError("файл не сошёлся с индексом по sha или размеру")
    if entry["name"] != published_name(entry["sha256"]):
        raise ValueError("имя %s не от его sha" % entry["name"])
    ways = check_graph(data, **gates)
    return payload, ways


def main(argv=None):
    parser = argparse.ArgumentParser(description="граф трасс для маршрута без сети")
    parser.add_argument("--input", help="roads.geojsonl (тот же экстракт, что у build_roads.py)")
    parser.add_argument("--out-dir", help="каталог для route_graph.<sha16>.json и index_payload.json")
    parser.add_argument("--version", type=int, default=None,
                        help="версия данных в индексе (по умолчанию unix-время сборки)")
    parser.add_argument("--simplify-meters", type=float, default=SIMPLIFY_METERS)
    parser.add_argument("--verify", metavar="STAGE",
                        help="только ворота: проверить каталог сборки перед подписью")
    args = parser.parse_args(argv)

    if args.verify:
        try:
            payload, ways = verify_stage(args.verify)
        except (OSError, ValueError) as error:
            print("НЕ ПОДПИСЫВАТЬ: %s" % error)
            return 1
        entry = payload["files"][0]
        print("граф годен: %s — %d линий, %d КиБ, версия %d" % (
            entry["name"], ways, entry["bytes"] // 1024, payload["version"]))
        return 0

    if not args.input or not args.out_dir:
        parser.error("нужны --input и --out-dir (или --verify)")

    started = time.time()
    ways, read_stats = read_ways(args.input)
    doc, stats = build_graph(ways, tolerance_degrees(args.simplify_meters))
    data = encode_graph(doc)
    version = args.version if args.version is not None else int(time.time())
    try:
        check_graph(data)
        payload = build_payload(data, version)
    except ValueError as error:
        print("НЕ ПОДПИСЫВАТЬ: %s" % error)
        return 1
    write_stage(args.out_dir, data, payload)

    entry = payload["files"][0]
    print("граф трасс: %s" % entry["name"])
    print("  линий %d (одностор. %d), по классам %s" % (
        stats["ways"], stats["oneway"], stats["classes"]))
    print("  точек %d из %d (упрощение %.0f м), перекрёстков %d, узлов-якорей %d" % (
        stats["points"], stats["points_in"], args.simplify_meters,
        stats["junctions"], stats["anchors"]))
    print("  пропущено: битых строк %d, реверсивных %d" % (
        read_stats["skipped"], read_stats["reversible"]))
    print("  %d байт (%.2f МБ), gzip %.2f МБ, версия %d, %.0f с" % (
        entry["bytes"], entry["bytes"] / 1e6, len(gzip.compress(data, 9)) / 1e6,
        version, time.time() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
