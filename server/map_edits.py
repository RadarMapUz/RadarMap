#!/usr/bin/env python3
"""Конструктор карты: хранилище правок и магнит.

Отдельный модуль, а не ещё двадцать тысяч строк в admin.py, по той же причине,
по какой отдельно живёт roads_gate.py: здесь считается геометрия, от которой
зависит, что увидит водитель, и такое должно быть чистыми функциями с тестами,
а не обработчиками HTTP, которые нельзя вызвать иначе как запросом.

Три вещи, которые определяют всё остальное.

МАГНИТ ЛИПНЕТ К НАШИМ ЖЕ ТАЙЛАМ, а не к сырому OSM и не к подложке Яндекса.
В панели видно ровно ту геометрию, которая поедет на телефон, — уже разрезанную,
склеенную и упрощённую. Иначе рисуешь по одной карте, а получаешь другую: объект,
идеально посаженный на сырую линию, на схеме окажется в стороне ровно настолько,
насколько её сдвинуло упрощение.

МАГНИТ НЕ РЕШАЕТ ЗА ЧЕЛОВЕКА. Две дороги на равном удалении — обе подсвечиваются,
объект не ставится. Это типичный случай проспекта с дублёром, и угадывание там
даёт разворот не с той проезжей части.

ХРАНИМ ТРИ ГЕОМЕТРИИ, а не одну: куда ткнул человек (raw), куда посадил магнит
(snapped) и описание дороги без её id (anchor). raw нужен, когда OSM обновится:
пересаживать объект надо от исходного намерения человека, а не от прошлой
посадки, иначе он уползает понемногу каждую неделю.
"""
import hashlib
import json
import math
import os
import sqlite3
import time

LAT_METERS = 111_320.0

# --- Пороги магнита. Числа из §8 плана конструктора.

# Дальше этого — это уже не «на дороге».
SNAP_METERS = 25.0
# То же самое для пальца.
#
# Палец накрывает на экране телефона метров сорок городской улицы, и требовать
# от него той же точности, что от курсора, — значит требовать невозможного:
# промах будет не ошибкой модератора, а свойством руки. Радиус увеличен, но
# всё остальное осталось: неоднозначность по-прежнему предъявляется на выбор,
# и именно поэтому больший радиус безопасен — он даёт больше кандидатов, а не
# больше догадок.
TOUCH_SNAP_METERS = 45.0
# Светофоры и стоп-линии стоят на перекрёстках, а не посреди улицы.
NODE_METERS = 15.0
# Две дороги ближе трёх метров друг к другу — не гадаем.
AMBIGUOUS_METERS = 3.0

# Статусы правки. Не удаляем никогда: ручная работа — единственные данные в
# системе, которые нельзя восстановить пересборкой.
DRAFT, ACCEPTED, PUBLISHED, WITHDRAWN = 0, 1, 2, 3

SCHEMA = """
CREATE TABLE IF NOT EXISTS map_edits(
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    kind         TEXT NOT NULL,
    status       INTEGER NOT NULL DEFAULT 0,
    geom         TEXT NOT NULL,
    raw          TEXT NOT NULL,
    anchor       TEXT,
    props        TEXT,
    fingerprint  TEXT,
    note         TEXT DEFAULT '',
    author       TEXT NOT NULL DEFAULT '',
    created      REAL NOT NULL,
    updated      REAL NOT NULL,
    version      INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_edits_kind ON map_edits(kind, status);
"""

# Виды правок. Список закрытый: неизвестный вид не попадает ни в таблицу, ни в
# запекание, и «панель завела новый вид раньше сборки» здесь невозможно —
# в отличие от точек, где такое допускается намеренно.
KINDS = {"lanes", "turn_lanes", "u_turn", "geometry"}

# Названия видов для человека. Код — контракт с сервером и с запеканием, а на
# экране нужно слово: «lanes» в строке очереди читается как недоделка.
KIND_NAMES = {"lanes": "Полосы", "turn_lanes": "Направления полос",
              "u_turn": "Разворот", "geometry": "Своя геометрия"}


def kind_name(kind):
    return KIND_NAMES.get(kind, kind)


def ensure_tables(conn):
    conn.executescript(SCHEMA)
    conn.commit()


# --------------------------------------------------------------------------
# Геометрия
# --------------------------------------------------------------------------

def meters_between(a, b):
    """Расстояние между (lon, lat) в метрах."""
    lon_scale = math.cos(math.radians((a[1] + b[1]) / 2))
    return math.hypot((b[1] - a[1]) * LAT_METERS,
                      (b[0] - a[0]) * LAT_METERS * lon_scale)


def bearing(a, b):
    """Азимут от a к b, градусы (0 — на север)."""
    lon_scale = math.cos(math.radians(a[1]))
    angle = math.degrees(math.atan2((b[0] - a[0]) * lon_scale, b[1] - a[1]))
    return angle + 360 if angle < 0 else angle


def nearest_on(point, line):
    """Ближайшая точка на ломаной, её азимут и расстояние.

    Проекция на ОТРЕЗОК, а не ближайшая вершина: между вершинами упрощённой
    линии бывает сотня метров, и посадка на вершину увела бы объект туда же.
    """
    best, best_bearing, best_distance = line[0], 0.0, float("inf")
    for i in range(1, len(line)):
        a, b = line[i - 1], line[i]
        lon_scale = math.cos(math.radians(a[1]))
        bx = (b[0] - a[0]) * LAT_METERS * lon_scale
        by = (b[1] - a[1]) * LAT_METERS
        px = (point[0] - a[0]) * LAT_METERS * lon_scale
        py = (point[1] - a[1]) * LAT_METERS
        norm = bx * bx + by * by
        t = max(0.0, min(1.0, (px * bx + py * by) / norm)) if norm else 0.0
        candidate = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        distance = meters_between(point, candidate)
        if distance < best_distance:
            best, best_distance, best_bearing = candidate, distance, bearing(a, b)
    return best, best_bearing, best_distance


def nearest_node(point, line, meters=NODE_METERS):
    """Конец линии в радиусе — узел перекрёстка. None, если далеко.

    Именно КОНЕЦ, а не любая вершина: ways режутся на перекрёстках, поэтому
    перекрёсток — это всегда конец куска, а внутренняя вершина — форма дороги.
    """
    best, best_distance = None, meters
    for candidate in (line[0], line[-1]):
        distance = meters_between(point, candidate)
        if distance < best_distance:
            best, best_distance = candidate, distance
    return best


class Snap:
    """Что вышло у магнита. Отдельный класс, а не кортеж: у результата пять
    полей, и позиционный доступ к ним читался бы шифром."""

    def __init__(self, point, road=None, distance=float("inf"),
                 bearing_degrees=0.0, at_node=False, ambiguous=()):
        self.point = point
        self.road = road
        self.distance = distance
        self.bearing_degrees = bearing_degrees
        self.at_node = at_node
        # Дороги, между которыми магнит не стал выбирать. Пусто — выбор
        # однозначен.
        self.ambiguous = list(ambiguous)

    @property
    def on_road(self):
        return self.road is not None and not self.ambiguous

    @property
    def anchor(self):
        """Описание дороги БЕЗ её id.

        Id ведёт в OSM и не переживёт воскресной пересборки: у той же улицы
        назавтра другой way. Класс, азимут и имя переживают, и по ним объект
        пересаживается на новую геометрию.
        """
        if self.road is None:
            return None
        return {"cls": self.road.get("cls"),
                "name": self.road.get("name", ""),
                "bearing": round(self.bearing_degrees, 1),
                "atNode": self.at_node}


def candidates(point, roads, meters=SNAP_METERS):
    """Все дороги в радиусе захвата, ближняя первой.

    Отдельно от snap() и намеренно: магнит не выбирает за человека, но человеку
    надо чем-то ответить. «Приблизьте карту» ответом не является — приближение
    не разводит две проезжие части, они физически в двадцати метрах друг от
    друга. Список кандидатов, у каждого из которых УЖЕ посчитана своя посадка,
    позволяет выбрать без второго запроса на сервер.
    """
    out = []
    for road in roads:
        line = road.get("points") or []
        if len(line) < 2:
            continue
        candidate, azimuth, distance = nearest_on(point, line)
        if distance > meters:
            continue
        out.append({"road": road, "point": candidate,
                    "bearing": azimuth, "distance": distance})
    out.sort(key=lambda item: item["distance"])
    return out


def snap(point, roads, meters=SNAP_METERS, node_meters=NODE_METERS,
         prefer_node=False):
    """Посадить точку на ось ближайшей дороги.

    prefer_node — для объектов, которые стоят на перекрёстке по своей природе
    (светофор, стоп-линия). Для них узел старше проекции: посаженный на ось
    в полутора метрах от узла светофор на схеме висит рядом с перекрёстком,
    а не на нём.
    """
    found = candidates(point, roads, meters)
    if not found:
        return Snap(point)
    first = found[0]
    road, candidate = first["road"], first["point"]
    distance, azimuth = first["distance"], first["bearing"]

    # Неоднозначность: вторая дорога почти на том же расстоянии. Не выбираем
    # за человека — проспект с дублёром выглядит именно так.
    close = [item["road"] for item in found[1:]
             if item["distance"] - distance <= AMBIGUOUS_METERS]
    if close:
        return Snap(candidate, road, distance, azimuth, False, [road] + close)

    at_node = False
    if prefer_node:
        node = nearest_node(point, road["points"], node_meters)
        if node is not None:
            candidate, at_node = node, True
    return Snap(candidate, road, distance, azimuth, at_node)


def fingerprint(point, roads, radius=40.0):
    """Отпечаток окрестной геометрии OSM.

    Считается от того, что РЯДОМ, а не от одной дороги: правка держится за
    место, а не за линию. Дорога может исчезнуть, а место остаться, и наоборот.
    Сошёлся отпечаток — вокруг ничего не изменилось, правка едет молча.
    """
    parts = []
    for road in roads:
        line = road.get("points") or []
        if len(line) < 2:
            continue
        _, _, distance = nearest_on(point, line)
        if distance > radius:
            continue
        # Округляем до метра: дрожание последнего знака в экспорте OSM не
        # должно поднимать очередь на проверку.
        shape = ";".join(f"{round(x, 5)},{round(y, 5)}" for x, y in line)
        parts.append(f"{road.get('cls')}|{road.get('name', '')}|{shape}")
    parts.sort()
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:16]


# --------------------------------------------------------------------------
# Хранилище
# --------------------------------------------------------------------------

def create(conn, kind, raw, snapped, anchor=None, props=None, note="",
           author="", fingerprint_value=None, status=DRAFT):
    if kind not in KINDS:
        raise ValueError(f"неизвестный вид правки: {kind}")
    # Панель не публикует: статус выше «принято» ставит только запекание с
    # машины владельца. Молча понижать до черновика тоже нельзя — модератор
    # нажал «Принять», увидел «Принято» и ушёл, а правка осталась лежать.
    if status not in (DRAFT, ACCEPTED):
        raise ValueError(f"панель не ставит статус {status}")
    now = time.time()
    cursor = conn.execute(
        """INSERT INTO map_edits(kind, status, geom, raw, anchor, props,
                                 fingerprint, note, author, created, updated, version)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,1)""",
        (kind, status, json.dumps(snapped, separators=(",", ":")),
         json.dumps(raw, separators=(",", ":")),
         json.dumps(anchor, separators=(",", ":")) if anchor else None,
         json.dumps(props or {}, separators=(",", ":")),
         fingerprint_value, note, author, now, now))
    conn.commit()
    return cursor.lastrowid


def update(conn, edit_id, version, **fields):
    """Правка по оптимистической блокировке.

    Версия обязательна и проверяется в WHERE. Модератор открывает панель с
    телефона и с ноутбука разом; без версии второе сохранение молча затирало бы
    первое, и узнать об этом было бы неоткуда.
    """
    allowed = {"status", "geom", "raw", "anchor", "props", "note"}
    unknown = set(fields) - allowed
    if unknown:
        raise ValueError(f"нельзя менять: {sorted(unknown)}")
    if not fields:
        return False
    sets, values = [], []
    for key, value in sorted(fields.items()):
        sets.append(f"{key} = ?")
        values.append(value if isinstance(value, str) or value is None
                      else json.dumps(value, separators=(",", ":")))
    sets.append("updated = ?")
    values.append(time.time())
    sets.append("version = version + 1")
    values.extend([edit_id, version])
    changed = conn.execute(
        f"UPDATE map_edits SET {', '.join(sets)} WHERE id = ? AND version = ?",
        values).rowcount
    conn.commit()
    return changed == 1


# Метка автоматики «сдвинулось, посмотри». Живёт в заметке, а не отдельной
# колонкой: через полгода «почему эта правка помечена» вспомнит только текст,
# и держать причину рядом с меткой дешевле, чем сводить их запросом.
CHECK_MARK = "проверить"


def confirm(conn, edit_id, version):
    """«Посмотрел, всё верно» — снять метку автоматики.

    Не трогает ни геометрию, ни статус: правка и так опубликована. Убирается
    ровно то, что мешает ей уйти из очереди, — иначе очередь не пустеет
    никогда и её перестают открывать.
    """
    row = conn.execute("SELECT note FROM map_edits WHERE id = ?",
                       (edit_id,)).fetchone()
    if row is None:
        return False
    cleaned = " · ".join(part for part in (row["note"] or "").split(" · ")
                         if CHECK_MARK not in part)
    return update(conn, edit_id, version, note=cleaned)


def restore(conn, edit_id, version):
    """Вернуть снятую правку. Отмена — это возврат предыдущей версии, а не
    отдельный механизм: у нас есть версия, и её достаточно."""
    return update(conn, edit_id, version, status=ACCEPTED)


def withdraw(conn, edit_id, version):
    """Снять с публикации. НЕ удаление: история ручной работы не
    восстанавливается пересборкой, в отличие от всего остального в системе."""
    return update(conn, edit_id, version, status=WITHDRAWN)


def in_bbox(conn, south, west, north, east, limit=2000):
    """Правки в рамке карты.

    По рамке, а не целиком: в тайле Ташкента 71 595 дорог, и попытка показать
    страну убила бы панель на первом открытии. Потолок — чтобы плотный район
    не сделал того же.
    """
    rows = conn.execute(
        "SELECT * FROM map_edits WHERE status != ? ORDER BY id", (WITHDRAWN,)).fetchall()
    out = []
    for row in rows:
        geom = json.loads(row["geom"])
        point = geom[0] if isinstance(geom[0], (list, tuple)) else geom
        lon, lat = float(point[0]), float(point[1])
        if not (south <= lat <= north and west <= lon <= east):
            continue
        out.append(row_to_dict(row))
        if len(out) >= limit:
            break
    return out


def by_id(conn, edit_id):
    """Одна правка по номеру — для поиска «#12».

    Снятые тоже находятся: номер называют, когда о правке уже говорили, и
    ответ «нет такой» на снятую правку был бы враньём — она есть, просто не
    едет на телефоны.
    """
    row = conn.execute("SELECT * FROM map_edits WHERE id = ?", (edit_id,)).fetchone()
    return row_to_dict(row) if row else None


def row_to_dict(row):
    return {"id": row["id"], "kind": row["kind"], "status": row["status"],
            "geom": json.loads(row["geom"]), "raw": json.loads(row["raw"]),
            "anchor": json.loads(row["anchor"]) if row["anchor"] else None,
            "props": json.loads(row["props"]) if row["props"] else {},
            "fingerprint": row["fingerprint"], "note": row["note"],
            "author": row["author"], "version": row["version"]}


def export_accepted(conn):
    """Снимок правок для запекания в тайлы.

    Снимок, а не приращение: сборка накладывает состояние целиком, и «отменить»
    значит собрать тайлы без этой строки. Тот же приём, что у overrides камер.
    """
    rows = conn.execute(
        "SELECT * FROM map_edits WHERE status IN (?, ?) ORDER BY id",
        (ACCEPTED, PUBLISHED)).fetchall()
    return [row_to_dict(row) for row in rows]


# --------------------------------------------------------------------------
# Очередь работы
# --------------------------------------------------------------------------

# Дороги каких классов вообще стоит размечать руками. Дворовый проезд с одной
# полосой и так нарисован верно, а их половина всей сети: попади они в очередь,
# она стала бы бесконечной и потому бесполезной.
TODO_MAX_CLASS = 4
# Бит «полосы знаем» из build_roads. Дублируется числом, а не импортом:
# build_roads живёт на машине владельца и на VPS его может не быть вовсе, а
# панель обязана работать и там.
FLAG_LANES_TAGGED = 1 << 8
# Биты характера линии — те же, что читает телефон.
FLAG_ONEWAY, FLAG_BRIDGE, FLAG_TUNNEL, FLAG_RING = 1, 2, 4, 8
FLAG_LANES_SHIFT = 4
FLAG_LANES_MASK = 0b1111 << FLAG_LANES_SHIFT

# ТРЕТЬЯ копия таблицы ширин, и это плохо ровно настолько, насколько выглядит.
#
# Первая живёт в build_roads.py, вторая — в RoadShape.swift на телефоне. Их две
# потому, что сервер и клиент физически разные программы; третья появляется
# потому, что панель обязана рисовать то же, что увидит водитель, а импортировать
# build_roads она не может — тот живёт на машине владельца, и на VPS его может
# не быть вовсе.
#
# Расходиться им нельзя, и сторожит это тест: он сверяет числа здесь с числами
# в build_roads, когда тот доступен. Если однажды панель и сборка окажутся на
# одной машине навсегда — таблицу надо свести к одной.
LANE_METERS = {1: 3.75, 2: 3.75, 3: 3.75, 4: 3.5, 5: 3.5, 6: 3.5, 7: 4.5}
DEFAULT_LANES = {1: (3, 6), 2: (3, 6), 3: (3, 6),
                 4: (2, 4), 5: (2, 4), 6: (1, 2), 7: (1, 1)}
MAX_LANES_BY_CLASS = {1: 15, 2: 15, 3: 12, 4: 8, 5: 8, 6: 4, 7: 2}


def road_lanes_of(flags, cls):
    """Полос у дороги: сказанное тайлом, иначе дефолт класса."""
    lanes = (flags & FLAG_LANES_MASK) >> FLAG_LANES_SHIFT
    if not lanes:
        single, both = DEFAULT_LANES.get(cls, (1, 2))
        lanes = single if flags & FLAG_ONEWAY else both
    return min(lanes, MAX_LANES_BY_CLASS.get(cls, 8))


def road_width_meters(flags, cls):
    """Ширина проезжей части в метрах — ровно та, что нарисует телефон."""
    return road_lanes_of(flags, cls) * LANE_METERS.get(cls, 3.5)
# Ближе этого к дороге уже стоит правка — работа сделана.
DONE_METERS = 30.0


def _center(points):
    return points[len(points) // 2]


# Куда идёт дорога, словами. Опубликованные сейчас тайлы имён улиц не содержат
# вовсе — все записи в них длиной три, поле имени появилось позже, — и строка
# «(без имени) · класс 3» ничего не говорит о том, ЧТО перед тобой. Направление
# говорит: по нему дорогу узнают на карте с одного взгляда.
COMPASS = ("с юга на север", "с юго-запада на северо-восток",
           "с запада на восток", "с северо-запада на юго-восток",
           "с севера на юг", "с северо-востока на юго-запад",
           "с востока на запад", "с юго-востока на северо-запад")


def heading_words(points):
    if len(points) < 2:
        return ""
    angle = bearing(points[0], points[-1])
    return COMPASS[int(round(angle / 45.0)) % 8]


def todo(roads, edits, limit=40):
    """Дороги в рамке, о полосах которых никто ничего не сказал.

    Панель обязана говорить, что делать дальше: пустой экран карты — это
    вопрос «а где работать?», на который модератор отвечает своей памятью, а
    она кончается на третьем сеансе.

    Считаем по видимой рамке, а не по городу: очередь в семьдесят тысяч строк
    не помогает, она подавляет. Сколько влезло — столько и работы на сейчас.
    """
    done = [(float(e["geom"][0]), float(e["geom"][1]))
            for e in edits if e.get("geom") and len(e["geom"]) >= 2]
    out = []
    for road in roads:
        if road.get("cls", 99) > TODO_MAX_CLASS:
            continue
        if road.get("flags", 0) & FLAG_LANES_TAGGED:
            continue
        points = road.get("points") or []
        if len(points) < 2:
            continue
        spot = _center(points)
        if any(meters_between(spot, mark) <= DONE_METERS for mark in done):
            continue
        out.append({"what": "lanes", "cls": road["cls"],
                    "name": road.get("name", ""),
                    "heading": heading_words(points),
                    "point": [spot[0], spot[1]],
                    "meters": round(polyline_meters(points))})
        if len(out) >= limit:
            break
    # Длинные дороги первыми: улица в километр важнее проулка в тридцать
    # метров, и разметив её, закрываешь больше карты за то же время.
    out.sort(key=lambda item: -item["meters"])
    return out


def polyline_meters(points):
    total = 0.0
    for i in range(1, len(points)):
        total += meters_between(points[i - 1], points[i])
    return total


# --------------------------------------------------------------------------
# Дороги для магнита: читаем ОПУБЛИКОВАННЫЕ тайлы
# --------------------------------------------------------------------------

SCALE = 100_000.0


def decode_tile(payload):
    """Разобрать тайл в дороги. Тот же формат, что читает телефон."""
    roads = []
    for entry in payload.get("roads") or []:
        if not (3 <= len(entry) <= 4):
            continue
        cls, flags, flat = entry[0], entry[1], entry[2]
        if len(flat) < 4 or len(flat) % 2:
            continue
        points, lat, lon = [], 0, 0
        for i in range(0, len(flat), 2):
            if i == 0:
                lat, lon = flat[0], flat[1]
            else:
                lat += flat[i]
                lon += flat[i + 1]
            points.append((lon / SCALE, lat / SCALE))
        roads.append({"cls": cls, "flags": flags, "points": points,
                      "name": entry[3] if len(entry) > 3 else ""})
    return roads


# Разобранные тайлы: путь → (mtime, дороги).
#
# Тайл Ташкента — 2.7 МБ и 71 595 дорог, и перечитывать его на каждое движение
# карты значит платить четверть секунды за каждый кадр панели. Ключ — время
# правки файла, поэтому свежая публикация подхватывается сама, без перезапуска
# панели: модератор не должен помнить, что после выкладки надо что-то дёрнуть.
_TILE_CACHE = {}


def _tile_roads(path):
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return []
    cached = _TILE_CACHE.get(path)
    if cached and cached[0] == mtime:
        return cached[1]
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        return []
    roads = decode_tile(payload)
    _TILE_CACHE[path] = (mtime, roads)
    return roads


def load_roads(tiles_dir, south, west, north, east, sets=("s", "y")):
    """Дороги из опубликованных тайлов, попадающие в рамку.

    Читаем ТО ЖЕ, что уедет на телефон: магнит обязан липнуть к нарисованной
    геометрии, а не к сырому OSM. Наборы по умолчанию — улицы и дворы: костяк
    (`f`) для посадки не годится, там раздельные проезжие сведены в одну ось,
    и объект сел бы между ними.
    """
    if not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    names = sorted(os.listdir(tiles_dir))

    def wanted(name):
        if not name.endswith(".json"):
            return False
        if name.startswith("road2_"):
            suffix = name[len("road2_"):-len(".json")].rsplit("_", 1)
            return len(suffix) == 2 and suffix[1] in sets
        # Запасной путь: СТАРЫЙ формат, один файл на всё.
        #
        # Он не наследие ради наследия. Формат v2 собирается параллельно с v1 и
        # уберётся, только когда в проде не останется старых сборок, — а до тех
        # пор на сервере может лежать один v1, и именно так там сейчас и есть.
        # Панель, умеющая липнуть только к v2, на таком сервере просто не
        # магнитила бы, и понять почему было бы неоткуда: дороги в тайлах есть.
        return name.startswith("tile_") if not has_v2 else False

    has_v2 = any(name.startswith("road2_") for name in names)
    roads = []
    for name in names:
        if not wanted(name):
            continue
        for road in _tile_roads(os.path.join(tiles_dir, name)):
            if any(south <= lat <= north and west <= lon <= east
                   for lon, lat in road["points"]):
                roads.append(road)
    return roads
