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

-- История геометрии. Отдельной таблицей, а не колонкой: у одной правки версий
-- много, и «кто и когда сдвинул эту улицу» через полгода спросят обязательно.
-- Восстановить это неоткуда — ручная работа единственная в системе, которую
-- нельзя пересобрать из OSM.
CREATE TABLE IF NOT EXISTS map_edit_history(
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    edit_id  INTEGER NOT NULL,
    version  INTEGER NOT NULL,
    geom     TEXT NOT NULL,
    props    TEXT,
    note     TEXT DEFAULT '',
    author   TEXT DEFAULT '',
    at       REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_history_edit ON map_edit_history(edit_id, version);
"""

# Виды правок. Список закрытый: неизвестный вид не попадает ни в таблицу, ни в
# запекание, и «панель завела новый вид раньше сборки» здесь невозможно —
# в отличие от точек, где такое допускается намеренно.
KINDS = {"lanes", "turn_lanes", "u_turn", "geometry", "point", "remove",
         "lock", "name", "area"}

# Названия видов для человека. Код — контракт с сервером и с запеканием, а на
# экране нужно слово: «lanes» в строке очереди читается как недоделка.
KIND_NAMES = {"lanes": "Полосы", "turn_lanes": "Направления полос",
              "u_turn": "Разворот", "geometry": "Своя геометрия",
              "point": "Обстановка", "remove": "Убрана дорога",
              "lock": "Размеченная область", "name": "Название",
              "area": "Местность"}

# Виды местности — те же коды, что у слоёв из OSM: вода, зелень, рельсы,
# квартал. Панель заводит объект ТОГО ЖЕ вида, а не параллельный, поэтому он
# рисуется на телефоне тем же кодом и добавлять там нечего.
AREA_NAMES = {1: "Вода", 2: "Зелень", 3: "Рельсы", 4: "Квартал"}

# Почему дорогу убрали. Закрытым списком по той же причине, что и у своей
# геометрии: свободный текст через полгода превращается в «тест» и «см. выше».
REMOVE_REASONS = {"нет в жизни", "перекрыта", "ошибка OSM"}

# Радиус размеченной области по умолчанию, метры. Перекрёсток с подъездами —
# это примерно столько; меньше не накрывает подходы, больше захватывает соседние
# улицы, за которые никто не отвечал.
LOCK_METERS = 120.0
MAX_LOCK_METERS = 600.0

# Обстановка, которую ставят руками. Коды — те же, что у точек из OSM: панель
# заводит объект того же вида, а не параллельный, поэтому на телефоне он
# рисуется тем же кодом и ничего добавлять не надо.
POINT_NAMES = {1: "Светофор", 2: "Лежачий полицейский", 3: "Стоп-линия",
               4: "Разворот", 5: "Пешеходный переход", 6: "Стрелки полос"}


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


def remember(conn, edit_id):
    """Отложить нынешнюю версию правки в историю.

    Зовётся ПЕРЕД изменением: сохраняем то, что было, а не то, что стало.
    Иначе история — это копия текущего состояния, то есть ничего.
    """
    row = conn.execute("SELECT * FROM map_edits WHERE id = ?",
                       (edit_id,)).fetchone()
    if row is None:
        return False
    conn.execute(
        """INSERT INTO map_edit_history(edit_id, version, geom, props, note,
                                        author, at)
           VALUES(?,?,?,?,?,?,?)""",
        (edit_id, row["version"], row["geom"], row["props"], row["note"],
         row["author"], time.time()))
    return True


def history(conn, edit_id):
    """Как правка выглядела раньше, свежее первым."""
    rows = conn.execute(
        "SELECT version, geom, props, note, author, at FROM map_edit_history "
        "WHERE edit_id = ? ORDER BY version DESC", (edit_id,)).fetchall()
    out = []
    for row in rows:
        out.append({"version": row["version"],
                    "geom": json.loads(row["geom"]),
                    "props": json.loads(row["props"]) if row["props"] else {},
                    "note": row["note"], "author": row["author"],
                    "at": row["at"]})
    return out


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
    # Историю пишем ДО изменения и только когда меняется геометрия или
    # свойства: заметка и статус меняются часто, и версия «поменяли статус»
    # засоряла бы историю тем, о чём никто не спросит.
    if "geom" in fields or "props" in fields:
        remember(conn, edit_id)
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


def locks(conn):
    """Размеченные области → [(точка, радиус в метрах)].

    Область — это заявление «здесь разбирались руками». Внутри неё автоматика
    смотрит и докладывает, но НИЧЕГО НЕ ДВИГАЕТ: перекрёсток, размеченный
    человеком по спутнику, не должен уезжать за тем, как его в очередной раз
    перерисовал случайный картограф.

    Без этого правила своя карта невозможна: каждая воскресная пересборка
    отчасти обесценивает предыдущую неделю работы, причём молча.
    """
    out = []
    for row in conn.execute("SELECT geom, props FROM map_edits "
                            "WHERE kind = 'lock' AND status IN (?, ?)",
                            (ACCEPTED, PUBLISHED)).fetchall():
        try:
            point = json.loads(row["geom"])
            props = json.loads(row["props"]) if row["props"] else {}
        except (ValueError, TypeError):
            continue
        if not isinstance(point, list) or len(point) < 2:
            continue
        radius = props.get("radius")
        if not isinstance(radius, (int, float)) or radius <= 0:
            radius = LOCK_METERS
        out.append(((float(point[0]), float(point[1])),
                    min(float(radius), MAX_LOCK_METERS)))
    return out


def inside_lock(point, areas):
    """Лежит ли точка в размеченной области."""
    for centre, radius in areas:
        if meters_between(point, centre) <= radius:
            return True
    return False


def by_id(conn, edit_id):
    """Одна правка по номеру — для поиска «#12».

    Снятые тоже находятся: номер называют, когда о правке уже говорили, и
    ответ «нет такой» на снятую правку был бы враньём — она есть, просто не
    едет на телефоны.
    """
    row = conn.execute("SELECT * FROM map_edits WHERE id = ?", (edit_id,)).fetchone()
    return row_to_dict(row) if row else None


def row_to_dict(row):
    edit = {"id": row["id"], "kind": row["kind"], "status": row["status"],
            "geom": json.loads(row["geom"]), "raw": json.loads(row["raw"]),
            "anchor": json.loads(row["anchor"]) if row["anchor"] else None,
            "props": json.loads(row["props"]) if row["props"] else {},
            "fingerprint": row["fingerprint"], "note": row["note"],
            "author": row["author"], "version": row["version"],
            # Когда завели и когда трогали в последний раз. Без этого строка
            # очереди не отвечает на «свежее это или лежит с весны», и решать
            # по ней нельзя: правку месячной давности снимают иначе, чем
            # вчерашнюю.
            "created": row["created"], "updated": row["updated"]}
    edit["draw"] = draw_of(edit)
    return edit


# Какие правки — линии, а какие точки.
#
# Разница не косметическая. Нарисованная дорога — ЛИНИЯ, и показывать её точкой
# значит не показывать сделанную работу вовсе; а взять у линии `geom[1]` как
# широту — это вторая ВЕРШИНА вместо координаты, то есть метка уезжает в
# случайное место. Ровно так и было, и выглядело как «панель ставит что-то
# сама».
LINE_KINDS = {"geometry", "remove"}
RING_KINDS = {"area"}


def draw_of(edit):
    """Чем правка рисуется на карте: точкой, линией или замкнутым контуром.

    Считает СЕРВЕР, и по той же причине, что ширину дороги: панель обязана
    рисовать то же, что увидит водитель, а вторая реализация в JavaScript
    разошлась бы с первой молча.
    """
    kind = edit.get("kind")
    geom = edit.get("geom") or []
    shape = "line" if kind in LINE_KINDS else (
        "ring" if kind in RING_KINDS else "point")
    if shape == "point":
        point = list(geom) if len(geom) == 2 and not isinstance(
            geom[0], (list, tuple)) else None
    else:
        point = list(geom[0]) if geom and isinstance(
            geom[0], (list, tuple)) else None
    out = {"shape": shape, "point": point}
    if kind != "geometry":
        return out
    # Ширина нарисованной дороги — та же формула, что у пришедшей из OSM:
    # полосы на метры полосы по классу. Иначе своя дорога на схеме была бы
    # шире или уже соседней при одинаковом классе.
    props = edit.get("props") or {}
    try:
        cls = int(props.get("cls") or 6)
    except (TypeError, ValueError):
        cls = 6
    flags = FLAG_ONEWAY if props.get("oneway") else 0
    lanes = props.get("lanes")
    if isinstance(lanes, int) and 1 <= lanes <= 15:
        flags |= min(lanes, MAX_LANES_BY_CLASS.get(cls, 8)) << FLAG_LANES_SHIFT
    out["cls"] = cls
    out["lanes"] = road_lanes_of(flags, cls)
    out["width"] = round(road_width_meters(flags, cls), 1)
    return out


# Что писать в тегах, отдавая дорогу в OSM. Класс → highway.
OSM_HIGHWAY = {1: "motorway", 2: "trunk", 3: "primary", 4: "secondary",
               5: "tertiary", 6: "residential", 7: "service"}


def as_osm(edit):
    """Нарисованная дорога в формате OSM XML — чтобы отдать её всем.

    Дорога, отданная в OSM, поддерживается всем миром; наша — только нами.
    Поэтому «отправить в OSM» не украшение, а способ перестать платить за
    поддержку в одиночку: отданная дорога вернётся к нам сама обычной
    воскресной пересборкой, и своя копия снимется по правилу «OSM догнал».

    XML, а не GeoJSON: JOSM открывает .osm файлом, и вставлять руками ничего
    не надо. Отрицательные id — соглашение OSM для того, чего ещё нет на
    сервере.
    """
    points = edit.get("geom") or []
    if not points or not isinstance(points[0], (list, tuple)):
        return ""
    props = edit.get("props") or {}
    tags = {"highway": OSM_HIGHWAY.get(props.get("cls"), "residential")}
    if props.get("oneway"):
        tags["oneway"] = "yes"
    if props.get("bridge"):
        tags["bridge"] = "yes"
    if props.get("tunnel"):
        tags["tunnel"] = "yes"
    if isinstance(props.get("lanes"), int):
        tags["lanes"] = str(props["lanes"])
    if props.get("name"):
        tags["name"] = str(props["name"])

    def escaped(value):
        return (str(value).replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))

    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<osm version="0.6" generator="RadarMap">']
    for index, pair in enumerate(points, start=1):
        lines.append('  <node id="-%d" lat="%.7f" lon="%.7f" />'
                     % (index, float(pair[1]), float(pair[0])))
    lines.append('  <way id="-1000">')
    for index in range(1, len(points) + 1):
        lines.append('    <nd ref="-%d" />' % index)
    for key, value in sorted(tags.items()):
        lines.append('    <tag k="%s" v="%s" />' % (key, escaped(value)))
    lines.append("  </way>")
    lines.append("</osm>")
    return "\n".join(lines) + "\n"


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
# Нарисовано руками. Тот же бит, что ставит сборка: телефон его не читает, а
# панели он нужен, чтобы отличать своё от чужого.
FLAG_HAND_DRAWN = 1 << 9
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


# --- Опора на id из OSM -----------------------------------------------------
#
# Правка привязывается к дороге геометрией: класс, имя, азимут, отпечаток. Так
# сделано потому, что id «не переживает» пересборку, — и это верно лишь
# отчасти. Id способа в OSM меняется, когда способ разрезали или удалили, а не
# когда подвинули точку: в большинстве случаев он находит ту же дорогу
# мгновенно и точно, там где геометрический поиск каждую неделю кладёт в
# очередь «посмотрите» то, что не двигалось вовсе.
#
# Поэтому id — ПОДСКАЗКА, а не замена: сначала он, потом прежний геометрический
# поиск, и только потом «правка потеряла опору».

# Ближе этого опора считается той же дорогой. Двадцать метров — половина
# захвата магнита: середина улицы за неделю так далеко не уезжает, а соседняя
# проезжая часть на проспекте дальше.
IDENTITY_METERS = 20.0
# И азимут должен сойтись: на развязке две дороги проходят в метрах друг от
# друга, но под разными углами.
IDENTITY_BEARING = 25.0


def identity_path(tiles_dir, lat, lon):
    row = int(math.floor((lat + 90) / TILE_DEGREES_V1))
    column = int(math.floor((lon + 180) / TILE_DEGREES_V1))
    return os.path.join(tiles_dir, f"ids_{row}_{column}.json")


def load_identities(tiles_dir, lat, lon):
    """Опоры клетки: {id из OSM: (lon, lat, азимут, класс)}.

    Файл лежит рядом с тайлами, но вне индекса: телефон его не просит никогда,
    читает только панель. Нет файла — пустой словарь, и всё работает как
    раньше, геометрией.
    """
    path = identity_path(tiles_dir, lat, lon)
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        return {}
    out = {}
    for row in payload.get("roads") or []:
        try:
            osm_id, ilat, ilon, bearing, cls = row
            out[str(osm_id)] = (float(ilon) / SCALE, float(ilat) / SCALE,
                                float(bearing), int(cls))
        except (TypeError, ValueError):
            continue
    return out


def identity_at(tiles_dir, point, bearing_degrees):
    """Какая дорога OSM стоит в этом месте под этим углом. None — не нашлось.

    Зовётся в момент правки: человек ткнул в дорогу, и мы записываем, ЧТО это
    было по мнению OSM на сегодняшней сборке.
    """
    lon, lat = point
    best, best_distance = None, IDENTITY_METERS
    for osm_id, (ilon, ilat, bearing, _) in load_identities(tiles_dir, lat, lon).items():
        distance = meters_between((lon, lat), (ilon, ilat))
        if distance > best_distance:
            continue
        if _bearing_apart(bearing, bearing_degrees) > IDENTITY_BEARING:
            continue
        best, best_distance = osm_id, distance
    return best


def identity_place(tiles_dir, osm_id, near):
    """Где эта дорога OSM оказалась на СВЕЖЕЙ сборке. None — id исчез.

    Исчез он ровно в двух случаях: способ разрезали или удалили. Оба означают,
    что дальше работает геометрический поиск, а не что правка потеряна.
    """
    if not osm_id:
        return None
    lon, lat = near
    found = load_identities(tiles_dir, lat, lon).get(str(osm_id))
    if found is None:
        return None
    return (found[0], found[1])


def _bearing_apart(one, other):
    gap = abs((one - other) % 360)
    return min(gap, 360 - gap)


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
    # Через draw_of, а не по geom напрямую. У линии geom — СПИСОК ВЕРШИН, и
    # float(geom[0]) на ней падал: очередь работы отдавала 500, конструктор
    # молча оставался без списка «здесь работать», а в консоли висело
    # «Failed to fetch», по которому причину не найти.
    done = []
    for edit in edits:
        point = (edit.get("draw") or draw_of(edit)).get("point")
        if point:
            done.append((float(point[0]), float(point[1])))
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
        # ДВА числа — тоже запись: у точечного объекта одна координата.
        #
        # Порог в четыре числа отбрасывал всю обстановку целиком, и заметить
        # это было неоткуда: на боевом лежит формат v1, где точек нет вовсе,
        # поэтому пустой ответ читался как «сервер их ещё не публиковал». На
        # первом же тайле с точками панель осталась без светофоров и переходов.
        if len(flat) < 2 or len(flat) % 2:
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


# Шаг сетки тайлов. Формат v1 — один файл на 0.5°, v2 — мелкая сетка по
# наборам. Нужен здесь ровно затем, чтобы по ИМЕНИ файла понять, какой кусок
# земли в нём лежит, и не открывать его, если он не в рамке.
TILE_DEGREES_V1 = 0.5
TILE_DEGREES_V2 = 0.05

# Разобранные тайлы: путь → (mtime, дороги).
#
# Тайл Ташкента — 2.7 МБ и 71 595 дорог; разобранный он занимает десятки
# мегабайт. Кэш ОБЯЗАН быть ограничен: панель живёт под MemoryMax=256M, и
# бесконечный кэш выбирал его за десяток движений карты — сервис упирался в
# потолок и переставал отвечать вовсе. Так и случилось на боевом.
#
# Двух хватает: модератор работает в одном месте, а два — это его тайл и
# соседний, когда он стоит на границе.
_TILE_CACHE = {}
_TILE_ORDER = []
TILE_CACHE_SIZE = 2

# Сколько тайлов вообще можно прочитать за один запрос.
#
# Не «сколько влезет», а именно потолок: запрос с рамкой во всю страну
# («сверь все правки») читал бы все 210 файлов и убивал панель. Рамка шире
# этого — ошибка вызова, а не повод грузить землю целиком.
MAX_TILES_PER_CALL = 6


# Список файлов каталога: считается один раз на публикацию.
#
# Каждый запрос делал sorted(os.listdir()) по каталогу тайлов, а там 82 496
# файлов. Замерено на боевом: 230 мс на КАЖДЫЙ /api/roads и /api/areas ещё до
# того, как открыт хоть один тайл — набор воды из тысячи объектов «стоил»
# столько же, сколько набор кварталов из пятнадцати тысяч. Это была не
# отрисовка и не разбор, это перечисление имён.
#
# Ключ — время правки каталога: публикация подменяет его целиком, и метка
# меняется вместе с содержимым.
_NAMES_CACHE = {}


def _tile_names(tiles_dir):
    """Имена файлов каталога, отсортированные. Кэш живёт до публикации."""
    try:
        stamp = os.stat(tiles_dir).st_mtime_ns
    except OSError:
        return []
    known = _NAMES_CACHE.get(tiles_dir)
    if known and known[0] == stamp:
        return known[1]
    names = sorted(os.listdir(tiles_dir))
    _NAMES_CACHE[tiles_dir] = (stamp, names)
    return names


def touches_box(points, south, west, north, east):
    """Задевает ли ломаная рамку. Не «есть ли вершина внутри».

    Проверка по вершинам теряет то, что кадр ПЕРЕСЕКАЕТ: у куска дороги
    вершины стоят через десятки метров, и на ближнем плане проспект,
    проходящий через весь экран, не имеет внутри кадра ни одной.

    Замерено на боевых тайлах: 121 кадр вида вблизи (55 метров) по центру
    Ташкента. По вершине находилось 174 дороги, ещё 71 терялась — 28 %
    содержимого кадра. Это ровно тот масштаб, на котором работает вид за
    рулём.
    """
    if not points:
        return False
    lons = [point[0] for point in points]
    lats = [point[1] for point in points]
    # Быстрый отбой: рамки не пересекаются вовсе.
    if (min(lats) > north or max(lats) < south
            or min(lons) > east or max(lons) < west):
        return False
    for lon, lat in points:
        if south <= lat <= north and west <= lon <= east:
            return True
    if len(points) < 2:
        return False
    for i in range(1, len(points)):
        if _segment_hits(points[i - 1], points[i], south, west, north, east):
            return True
    return False


def _segment_hits(one, two, south, west, north, east):
    """Пересекает ли отрезок прямоугольник. Отсечение Лианга — Барски."""
    dx = two[0] - one[0]
    dy = two[1] - one[1]
    low, high = 0.0, 1.0
    for edge, delta in ((west - one[0], dx), (one[0] - east, -dx),
                        (south - one[1], dy), (one[1] - north, -dy)):
        if delta == 0:
            if edge > 0:
                return False
            continue
        step = edge / delta
        if delta > 0:
            if step > high:
                return False
            low = max(low, step)
        else:
            if step < low:
                return False
            high = min(high, step)
    return low <= high


def _tile_gap(name, middle):
    """Насколько тайл далёк от середины кадра. Порядок обхода, а не расстояние."""
    box = _tile_box(name)
    if box is None:
        return float("inf")
    lat = (box[0] + box[2]) / 2 - middle[0]
    lon = (box[1] + box[3]) / 2 - middle[1]
    return lat * lat + lon * lon


def _tile_size(path):
    """Вес файла в байтах. Ноль — файла нет: пусть его откроют и промолчат."""
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _tile_box(name):
    """Кусок земли, лежащий в файле, по его ИМЕНИ → (юг, запад, север, восток).

    None — имя не наше. Читать файл, чтобы узнать, нужен ли он, значит читать
    все файлы: ровно эта ошибка и положила панель.
    """
    if name.endswith(".json") and name.startswith("tile_"):
        parts, step = name[len("tile_"):-len(".json")].split("_"), TILE_DEGREES_V1
    elif name.endswith(".json") and name.startswith("road2_"):
        body = name[len("road2_"):-len(".json")].rsplit("_", 1)
        if len(body) != 2:
            return None
        parts, step = body[0].split("_"), TILE_DEGREES_V2
    else:
        return None
    if len(parts) != 2:
        return None
    try:
        row, column = int(parts[0]), int(parts[1])
    except ValueError:
        return None
    south = row * step - 90
    west = column * step - 180
    return (south, west, south + step, west + step)


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
    if path in _TILE_ORDER:
        _TILE_ORDER.remove(path)
    _TILE_ORDER.append(path)
    while len(_TILE_ORDER) > TILE_CACHE_SIZE:
        _TILE_CACHE.pop(_TILE_ORDER.pop(0), None)
    return roads


# Потолок ПО ОХВАТУ, а не один на все случаи.
#
# Шесть файлов на набор — это цифра ближнего плана, и там она верна: в рамку
# квартала больше и не попадает. На охвате города она означала «покажи шестую
# часть города и молчи»: на схеме оставался лоскут посреди чёрного экрана, и
# понять, что это потолок, а не отсутствие данных, было неоткуда.
#
# Ручек нужно две, и они про разное. Первая — сколько ФАЙЛОВ открыть: она про
# работу сервера. Вторая — какие дороги на этом охвате вообще нужны: на городе
# дворовые проезды и служебные съезды не читаются, их там нет и у чужих карт.
# Одной первой мало: сняв её, мы получили бы миллион объектов в браузере.
FRAME_LIMITS = (
    # (охват в градусах, файлов, класс не хуже, объектов)
    (0.02, 6, 7, 12_000),     # квартал и улица: всё, как есть
    (0.08, 24, 6, 20_000),    # район: без служебных проездов
    (0.50, 96, 4, 20_000),    # город целиком: костяк и главные улицы
    (float("inf"), 96, 3, 20_000),   # область: только магистрали
)


# То же самое, но по МЕТРАМ НА ПИКСЕЛЬ: подробность решает масштаб, а не то,
# сколько земли влезло в окно. На большом мониторе тот же зум даёт вдвое
# больший охват, и панель прятала дворовые проезды на семнадцатом зуме — там,
# где по ним и работают.
# Полосы подробности по МЕТРАМ НА ПИКСЕЛЬ, замеренные на боевых тайлах.
#
# Потолок по числу файлов отсюда убран, и это не послабление, а исправление
# вранья. Файл — плохая мера работы: кадр города это 134 файла набора «s» и
# 3,7 МБ, а тот же кадр костяком — 130 файлов и 0,6 МБ. Потолок в 96 файлов
# резал кадр ГЕОГРАФИЧЕСКИ: файлы отбирались по имени, то есть с юга на
# север, и северная половина города просто не приезжала. Модератор видел
# лоскут посреди черноты и ровным горизонтальным срезом сверху.
#
# Мерим тем, что стоит денег: БАЙТАМИ на разбор. И набор выбираем по
# масштабу, потому что костяк для дальнего плана и посчитан.
#
# Замерено на боевом сервере, окно 3000 пикселей:
#
#   кадр   м/пкс   набор s              набор f (костяк)
#    6 км    2,0    6 ф / 0,7 МБ / 30 мс   6 ф / 0,1 МБ /  4 мс
#   18 км    6,0   15 ф / 1,5 МБ / 59 мс  15 ф / 0,3 МБ /  9 мс
#   33 км   11,0   36 ф / 2,3 МБ / 80 мс  36 ф / 0,4 МБ / 13 мс
#   58 км   19,5  134 ф / 3,7 МБ / 249 мс 130 ф / 0,6 МБ / 51 мс
#
# Дальний план на костяке дешевле улиц в пять раз — и при этом ПОЛНЫЙ.
SCALE_PLAN = (
    # м/пиксель, наборы, класс не хуже, объектов, байт на разбор
    (1.2, ("s", "y"), 7, 12_000, 8 << 20),   # дом и подъезд: всё, как есть
    (4.0, ("s", "y"), 6, 20_000, 8 << 20),   # квартал: без служебных проездов
    (8.0, ("s",), 5, 20_000, 8 << 20),       # район: улицы без дворов
    (float("inf"), ("f",), 4, 40_000, 16 << 20),   # город и область: костяк
)


def frame_limits(south, west, north, east, span=None, mpp=None):
    """Сколько читать и что показывать на этом охвате.

    `span` — охват ЭКРАНА, если он известен; рамка запроса шире экрана на
    запас, и считать по ней значит перебрасывать вид в более грубую полосу.
    Замечено на себе: на зуме 17 запас в шестьдесят процентов делал охват
    «районным», и дворовые проезды пропадали ровно там, где по ним и работают.
    """
    if mpp is not None and mpp > 0:
        for edge, sets, worst_class, objects, budget in SCALE_PLAN:
            if mpp <= edge:
                return {"class": worst_class, "objects": objects,
                        "sets": sets, "bytes": budget,
                        "skeleton": sets == ("f",)}
    if span is None:
        span = max(north - south, east - west)
    for edge, files, worst_class, objects in FRAME_LIMITS:
        if span <= edge:
            return {"class": worst_class, "objects": objects,
                    "sets": ("s", "y"), "bytes": files * (1 << 20),
                    "skeleton": False}
    return {"class": 3, "objects": 20_000, "sets": ("f",),
            "bytes": 16 << 20, "skeleton": True}


def load_roads(tiles_dir, south, west, north, east, sets=("s", "y"),
               limits=None, report=None):
    """Дороги из опубликованных тайлов, попадающие в рамку.

    Читаем ТО ЖЕ, что уедет на телефон: магнит обязан липнуть к нарисованной
    геометрии, а не к сырому OSM. Наборы по умолчанию — улицы и дворы: костяк
    (`f`) для посадки не годится, там раздельные проезжие сведены в одну ось, и
    объект сел бы между ними.

    Открываем только те файлы, чей кусок земли ПЕРЕСЕКАЕТ рамку, и не больше
    MAX_TILES_PER_CALL. Прежняя версия читала весь каталог и разбирала каждый
    файл, чтобы понять, нужен ли он: на боевом это 210 файлов и десятки
    миллионов объектов — панель упиралась в MemoryMax и переставала отвечать.
    """
    if not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    names = _tile_names(tiles_dir)
    has_v2 = any(name.startswith("road2_") for name in names)

    wanted = []
    for name in names:
        if name.startswith("road2_"):
            body = name[len("road2_"):-len(".json")].rsplit("_", 1)
            if len(body) != 2 or body[1] not in sets:
                continue
        elif name.startswith("tile_"):
            # Запасной путь: СТАРЫЙ формат, один файл на всё.
            #
            # Он не наследие ради наследия. Формат v2 собирается параллельно с
            # v1 и уберётся, только когда в проде не останется старых сборок, —
            # а до тех пор на сервере может лежать один v1, и именно так там
            # сейчас и есть. Панель, умеющая липнуть только к v2, на таком
            # сервере просто не магнитила бы, и понять почему было бы неоткуда.
            if has_v2:
                continue
        else:
            continue
        box = _tile_box(name)
        if box is None:
            continue
        if box[0] > north or box[2] < south or box[1] > east or box[3] < west:
            continue
        wanted.append(name)

    limits = limits or {"class": 7, "objects": None,
                        "bytes": MAX_TILES_PER_CALL << 20}
    # Отбираем по БАЙТАМ и от центра кадра наружу.
    #
    # Прежний потолок брал первые N имён, а имена идут с юга на север: кадр
    # резался географически, и северная половина города просто не приезжала —
    # ровным горизонтальным срезом. Если урезать всё же придётся, терять надо
    # ОКРАИНЫ кадра, а не его половину.
    opened, taken = [], 0
    budget = limits.get("bytes") or (MAX_TILES_PER_CALL << 20)
    middle = ((south + north) / 2, (west + east) / 2)
    for name in sorted(wanted, key=lambda name: _tile_gap(name, middle)):
        size = _tile_size(os.path.join(tiles_dir, name))
        if opened and taken + size > budget:
            continue
        opened.append(name)
        taken += size
    roads = []
    thinned = 0
    for name in opened:
        for road in _tile_roads(os.path.join(tiles_dir, name)):
            # Сначала РАМКА, потом класс.
            #
            # В обратном порядке счётчик скрытого считал и дороги за пределами
            # кадра: файл покрывает шесть километров, а в рамке квартал. На
            # окраине это давало «скрыто 876» там, где в кадре не было ни
            # одной дороги вовсе, и я полдня искал беду по этой цифре.
            if not touches_box(road["points"], south, west, north, east):
                continue
            if road.get("cls", 7) > limits["class"]:
                thinned += 1
                continue
            roads.append(road)
    # Прореживание не имеет права оставить ПУСТОЙ экран.
    #
    # Замерено на живом кадре окраины: 876 дорог в тайлах, все класса 7, и
    # потолок охвата скрыл их целиком. На экране чернота и совет
    # «приблизьтесь» — то есть мы знали, что показать, и не показали.
    #
    # Правило простое: мелкие дороги лучше пустоты. Если после прореживания не
    # осталось ничего, показываем что есть — потолок по числу объектов при
    # этом остаётся, он и защищает браузер.
    if not roads and thinned:
        for name in opened:
            for road in _tile_roads(os.path.join(tiles_dir, name)):
                if any(south <= lat <= north and west <= lon <= east
                       for lon, lat in road["points"]):
                    roads.append(road)
        thinned = 0

    cut = False
    if limits["objects"] and len(roads) > limits["objects"]:
        # Режем ХУДШИЕ по классу, а не первые попавшиеся: обрезать список с
        # конца значило бы выкинуть половину города целиком, а так исчезают
        # самые мелкие проезды и рисунок города остаётся.
        roads.sort(key=lambda road: road.get("cls", 7))
        roads = roads[:limits["objects"]]
        cut = True
    if report is not None:
        # Потолок обязан о себе сообщать. Молчащий потолок читается как «здесь
        # нет дорог», и это худшая из возможных подписей под пустым экраном.
        report.update({"files": len(opened), "skipped": len(wanted) - len(opened),
                       "thinned": thinned, "cut": cut,
                       "worstClass": limits["class"],
                       "bytes": taken,
                       "skeleton": bool(limits.get("skeleton"))})
    return roads


# Наборы местности: вода, зелень, рельсы, кварталы, тротуары, дома.
# Биты точечной записи: азимут шагом 3° и ширина проезжей части в метрах.
# Те же числа, что в build_roads.py — контракт формата.
PFLAG_AZIMUTH_STEP = 3
PFLAG_AZIMUTH_MASK = 0x7F
PFLAG_WIDTH_SHIFT = 7
PFLAG_WIDTH_MASK = 0x3F

# Населённые пункты: город, посёлок, кишлак, район города. Ранг — в коде
# записи, как класс у дороги; по нему решается, с какого масштаба подписывать.
PLACE_SET = "n"
PLACE_NAMES = {1: "город", 2: "посёлок", 3: "кишлак", 4: "хутор",
               5: "район", 6: "квартал"}
# С какого масштаба виден какой ранг. Замер простой: подпись должна отвечать
# на вопрос «где я», когда дорог уже не разобрать. Показать все ранги сразу
# значит закрыть карту словами.
PLACE_SCALE = ((80.0, 1), (30.0, 2), (12.0, 3), (6.0, 4), (3.0, 6))


def place_rank(mpp=None):
    """Какие ранги мест имеет смысл показывать на этом масштабе."""
    if mpp is None or mpp <= 0:
        return 6
    for edge, rank in PLACE_SCALE:
        if mpp >= edge:
            return rank
    return 6


def load_places(tiles_dir, south, west, north, east, mpp=None, limit=400):
    """Места из тайлов набора «n» → [{ранг, имя, точка}].

    Отдельным набором и отдельным чтением: мест мало (по стране это тысячи), а
    нужны они ровно там, где всё остальное уже не читается.
    """
    if not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    worst = place_rank(mpp)
    out = []
    for name in _tile_names(tiles_dir):
        if not name.startswith("road2_") or not name.endswith(".json"):
            continue
        body = name[len("road2_"):-len(".json")].rsplit("_", 1)
        if len(body) != 2 or body[1] != PLACE_SET:
            continue
        box = _tile_box(name)
        if box is None:
            continue
        if box[0] > north or box[2] < south or box[1] > east or box[3] < west:
            continue
        for place in _tile_roads(os.path.join(tiles_dir, name)):
            points = place["points"]
            if not points:
                continue
            lon, lat = points[0]
            if not (south <= lat <= north and west <= lon <= east):
                continue
            rank = place.get("cls", 6)
            if rank > worst:
                continue
            out.append({"rank": rank, "name": place.get("name", ""),
                        "point": [lon, lat],
                        "kind": PLACE_NAMES.get(rank, "место")})
    # Крупные вперёд: если упрёмся в потолок, потеряем кварталы, а не города.
    out.sort(key=lambda place: place["rank"])
    return out[:limit]


AREA_SETS = ("w", "g", "r", "b", "t", "h", "d")
AREA_KINDS = {"w": 1, "g": 2, "r": 3, "b": 4, "t": 5, "h": 6}
AREA_CLOSED = 1
# Поверхность дорог: полотно, перекрёстки и фаски, посчитанные СБОРКОЙ. В
# наборе «d» лежат два вида сразу, поэтому здесь — единственное место, где вид
# берётся из самой записи, а не из имени файла.
AREA_ROAD, AREA_JUNCTION, AREA_MEDIAN = 7, 8, 9
SURFACE_SET = "d"
SURFACE_CLASS_SHIFT = 1
SURFACE_CLASS_MASK = 0b1111


# Какая местность имеет смысл на этом масштабе — и сколько она весит.
#
# Замерено на боевом, окно 3000 пикселей. Тяжелее всего полотно дорог: кадр
# города это 4,8 МБ набора «d» — ради ленты шириной в полтора пикселя, поверх
# которой и так рисуется сама дорога. Тротуар шириной два метра на шести
# метрах в пикселе — это треть пикселя.
#
#   кадр   м/пкс   b      d      g     r    t     w
#    6 км    2,0   356 КБ 919 КБ  80    20  212    12
#   18 км    6,0   824 КБ 2,0 МБ 121    36  295    28
#   58 км   19,3   1,4 МБ 4,8 МБ 192    71  345   202
# Потолок у местности СВОЙ, а не общий с дорогами.
#
# Замерено на боевых тайлах: дорога в ответе весит около 190 байт, площадной
# объект — около 320. Общий потолок в 40 000 давал 12,5 МБ местности на кадр
# страны, и это при том, что дорог там на два мегабайта.
AREA_PLAN = (
    # м/пиксель, наборы, объектов
    (1.2, ("w", "g", "r", "b", "t", "h", "d"), 20_000),   # всё, как есть
    (4.0, ("w", "g", "r", "b", "h", "d"), 20_000),        # без тротуаров
    (8.0, ("w", "g", "r", "b", "h"), 16_000),   # без полотна: оно уже линия
    (float("inf"), ("w", "g", "r", "b"), 12_000),   # вода, зелень, кварталы
)


def area_sets(mpp=None):
    """Наборы местности для этого масштаба."""
    if mpp is None or mpp <= 0:
        return AREA_SETS
    for edge, sets, _ in AREA_PLAN:
        if mpp <= edge:
            return sets
    return AREA_PLAN[-1][1]


def area_objects(mpp=None):
    """Сколько площадных объектов имеет смысл слать на этом масштабе."""
    if mpp is None or mpp <= 0:
        return AREA_PLAN[0][2]
    for edge, _, objects in AREA_PLAN:
        if mpp <= edge:
            return objects
    return AREA_PLAN[-1][2]


def load_areas(tiles_dir, south, west, north, east, sets=AREA_SETS,
               budget=None, objects=None, keep=0):
    """Местность из тайлов: вода, зелень, рельсы, кварталы, тротуары, дома.

    Без неё панель показывает не схему, а чертёж: серые линии на чёрном. На
    боевом сейчас лежит формат v1, где этих наборов нет вовсе, и панель
    выглядит пустой — но пусто здесь означает «сервер ещё не публиковал
    местность», а не «местности нет».

    Вид берётся ИЗ ИМЕНИ НАБОРА, а не из записи: у площадных объектов первый
    элемент — код слоя, и он совпадает с набором, но именно имя файла отвечает
    на вопрос «что это», когда запись пришла из будущей сборки.
    """
    if not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    out = []
    # Бюджет — НА КАЖДЫЙ НАБОР, а не на все вместе: общий означал бы, что дома
    # съедают его целиком и на воду с зеленью не остаётся ничего.
    #
    # Считаем в байтах, а не в файлах. Потолок в шесть файлов на набор резал
    # кадр географически — и ровно так же, как у дорог: имена идут с юга на
    # север, и северная часть местности не приезжала вовсе.
    budget = budget or (MAX_TILES_PER_CALL << 20)
    middle = ((south + north) / 2, (west + east) / 2)
    wanted = []
    for name in _tile_names(tiles_dir):
        if not name.startswith("road2_") or not name.endswith(".json"):
            continue
        body = name[len("road2_"):-len(".json")].rsplit("_", 1)
        if len(body) != 2 or body[1] not in sets:
            continue
        box = _tile_box(name)
        if box is None:
            continue
        if box[0] > north or box[2] < south or box[1] > east or box[3] < west:
            continue
        wanted.append((name, body[1]))
    taken = {}
    opened = []
    for name, kind_set in sorted(wanted, key=lambda pair: _tile_gap(pair[0], middle)):
        size = _tile_size(os.path.join(tiles_dir, name))
        if taken.get(kind_set) and taken[kind_set] + size > budget:
            continue
        taken[kind_set] = taken.get(kind_set, 0) + size
        opened.append((name, kind_set))
    for name, set_name in opened:
        body = [None, set_name]
        kind = AREA_KINDS.get(body[1], 0)
        for area in _tile_roads(os.path.join(tiles_dir, name)):
            points = area["points"]
            if not touches_box(points, south, west, north, east):
                continue
            flags = area.get("flags", 0)
            item = {"kind": kind,
                    "closed": bool(flags & AREA_CLOSED),
                    "points": points}
            if body[1] == SURFACE_SET:
                item["kind"] = area.get("cls", AREA_ROAD)
                if item["kind"] == AREA_ROAD:
                    item["road"] = (flags >> SURFACE_CLASS_SHIFT) & SURFACE_CLASS_MASK
            out.append(item)
    # Потолок по числу объектов — по РАЗМЕРУ, самые крупные вперёд.
    #
    # У дорог эту роль играет класс: проспект переживает прореживание, двор —
    # нет. У местности класса нет, и её мера — размах на местности: на охвате
    # страны водохранилище обязано остаться, а двор в тридцать метров всё
    # равно занял бы полпикселя.
    #
    # Замерено: кадр страны это 13 МБ местности и 17 415 объектов. Резать с
    # конца списка значило бы стереть целые области — файлы идут по порядку
    # имён, то есть по земле.
    if objects and len(out) > objects:
        out.sort(key=_area_extent, reverse=True)
        del out[objects:]
    if keep:
        for item in out:
            item["points"] = thin_points(item["points"], keep)
    return out


def thin_points(points, step):
    """Выкинуть вершины ближе `step` метров друг к другу.

    На дальнем плане две соседние вершины ложатся в один пиксель, и разница
    между ними — это байты, которых не видно. Порог держим в ОДИН пиксель:
    больше — уже видно, как скругляются углы кварталов.

    Замерено на кадре страны: 318 тысяч точек и 7,2 МБ превращаются в 235
    тысяч и 5,5 МБ. Три вершины остаются всегда — иначе кольцо перестанет быть
    кольцом и заливка исчезнет.
    """
    if step <= 0 or len(points) <= 3:
        return points
    out = [points[0]]
    for point in points[1:-1]:
        gap_x = (point[0] - out[-1][0]) * 111320 * 0.75
        gap_y = (point[1] - out[-1][1]) * 111320
        if gap_x * gap_x + gap_y * gap_y >= step * step:
            out.append(point)
    out.append(points[-1])
    if len(out) < 3:
        # Осталось два конца — добираем середину, а НЕ первые три точки.
        # points[:3] выбрасывал последнюю вершину, то есть замыкание кольца:
        # заливка после такого прореживания разъезжалась. Поймано тестом.
        return [points[0], points[len(points) // 2], points[-1]]
    return out


def _area_extent(area):
    """Наибольшая сторона объекта в градусах. Мера «видно ли его вообще»."""
    points = area["points"]
    if not points:
        return 0.0
    lons = [point[0] for point in points]
    lats = [point[1] for point in points]
    return max(max(lons) - min(lons), max(lats) - min(lats))


def load_candidates(tiles_dir, south, west, north, east, limit=1200):
    """Кандидаты от нейросети: обводки зданий, которых в OSM ещё нет.

    Лежат своими файлами cand_*.json РЯДОМ с тайлами и в подписанный индекс не
    входят — индекс описывает то, что едет на телефоны, а кандидат ещё никто
    не смотрел. Принятый становится обычной правкой и проходит ту же проверку,
    что нарисованное мышью.

    Потолок нужен: в одной клетке центра их больше тысячи, а разбирают их
    поштучно. Показать двадцать тысяч контуров значит не показать ничего.
    """
    if not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    out = []
    for name in _tile_names(tiles_dir):
        if not name.startswith("cand_") or not name.endswith(".json"):
            continue
        parts = name[len("cand_"):-len(".json")].split("_")
        if len(parts) != 2:
            continue
        try:
            row, column = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        step = TILE_DEGREES_V2
        box = (row * step - 90, column * step - 180,
               (row + 1) * step - 90, (column + 1) * step - 180)
        if box[0] > north or box[2] < south or box[1] > east or box[3] < west:
            continue
        try:
            with open(os.path.join(tiles_dir, name), encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            continue
        for flat in payload.get("houses") or []:
            if len(flat) < 6 or len(flat) % 2:
                continue
            points, lat, lon = [], 0, 0
            for i in range(0, len(flat), 2):
                if i == 0:
                    lat, lon = flat[0], flat[1]
                else:
                    lat += flat[i]
                    lon += flat[i + 1]
                points.append((lon / SCALE, lat / SCALE))
            if not any(south <= p[1] <= north and west <= p[0] <= east
                       for p in points):
                continue
            out.append({"points": points})
            if len(out) >= limit:
                return out
    return out


# --- Поиск по СВОЕМУ адресному индексу -------------------------------------
#
# Геокодер Яндекса требует отдельного ключа и отвечает 403 без него, а на
# странице модератора он и не нужен: адреса уже собраны нами и лежат рядом с
# тайлами. Свой поиск работает всегда — и когда чужой сервис лежит, и когда за
# него не заплачено.

# Сведение двух алфавитов. Замерено: 72 % улиц центра записаны латиницей, 28 %
# кириллицей, и человек ищет как ему привычно. Приведение слабое и намеренно:
# «Мустакиллик», «Mustaqillik» и «Mustakillik» обязаны находиться одинаково.
_FOLD = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "j", "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "a", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "s", "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "",
    "ы": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    "ў": "u", "қ": "k", "ғ": "g", "ҳ": "h",
}


# Апострофы узбекской латиницы. «oʻ» — отдельная буква, по-русски «у»
# («Oʻzbekiston» — «Узбекистан», «Koʻkcha» — «Кукча»); то же правило в
# приложении (AddressBook.fold). Остальные апострофы просто исчезают.
_APOSTROPHES = "'\u2018\u2019\u02bb\u02bc`\u00b4\u02b9"


def fold(text, uzbek_u=True):
    """Слово к сравнимому виду: кириллица → латиница, q→k, x→h, o→a, zh→j.

    uzbek_u=False — «oʻ» как «о» без апострофа: так пишет тот, кто набирает
    латиницей без апострофа («Kokcha»), и так выглядит слово, пока апостроф ещё
    не набран. Название из данных сравнивается в обоих видах (folds)."""
    out = []
    lowered = (text or "").lower()
    for apostrophe in _APOSTROPHES:
        lowered = lowered.replace("o" + apostrophe, "u" if uzbek_u else "o")
    for char in lowered:
        out.append(_FOLD.get(char, char))
    word = "".join(out)
    for was, now in (("zh", "j"), ("kh", "h"), ("ts", "s"), ("yo", "e"),
                     ("q", "k"), ("x", "h"), ("w", "v"), ("o", "a"),
                     ("y", "i")) + tuple((a, "") for a in _APOSTROPHES):
        word = word.replace(was, now)
    return "".join(ch for ch in word if ch.isalnum())


def folds(text):
    """Оба вида названия: с «oʻ» как «у» и как «о» (см. fold)."""
    return {fold(text), fold(text, uzbek_u=False)}


ADDRESS_DEGREES = 0.5


def search_addresses(tiles_dir, text, near=None, limit=8):
    """Найти адрес в своих файлах. near — (lat, lon), чтобы ближнее было выше.

    «Навои» есть не в одном городе, и модератор ищет ту улицу, над которой
    сейчас сидит: рамка карты решает порядок, а не отсекает результат.
    """
    wanted = fold(text)
    if not wanted or not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    number = ""
    parts = (text or "").split()
    if len(parts) > 1 and any(ch.isdigit() for ch in parts[-1]):
        number = parts[-1].strip().lower()
        wanted = fold(" ".join(parts[:-1]))
    found = []
    for name in _tile_names(tiles_dir):
        if not name.startswith("road2_") or not name.endswith("_a.json"):
            continue
        try:
            with open(os.path.join(tiles_dir, name), encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            continue
        for street in payload.get("streets") or []:
            if not any(wanted in variant for variant in folds(street.get("n", ""))):
                continue
            numbers = street.get("h") or []
            flat = street.get("p") or []
            lat = lon = 0
            for index, house in enumerate(numbers):
                at = index * 2
                if at + 1 >= len(flat):
                    break
                if index == 0:
                    lat, lon = flat[0], flat[1]
                else:
                    lat += flat[at]
                    lon += flat[at + 1]
                if number and str(house).lower() != number:
                    continue
                found.append({"street": street.get("n", ""), "house": house,
                              "lat": lat / SCALE, "lon": lon / SCALE})
                if not number and len(found) > limit * 40:
                    break
    if near:
        found.sort(key=lambda item: (item["lat"] - near[0]) ** 2
                   + (item["lon"] - near[1]) ** 2)
    # Один адрес приходит ДВАЖДЫ: в OSM он висит и точкой, и на контуре дома.
    # В списке из восьми строк два одинаковых «Шахрисабз, 5» — это две строки,
    # потраченные впустую.
    out, seen = [], set()
    for item in found:
        # Ключ — только улица и номер, без координат.
        #
        # Один адрес приходит и точкой, и контуром дома, а в плотной
        # застройке под одним номером бывает несколько строений. В списке из
        # восьми строк три «Мустакиллик, 10» — это три строки впустую.
        # Список отсортирован по близости, поэтому остаётся ближайший.
        mark = (item["street"], str(item["house"]).lower())
        if mark in seen:
            continue
        seen.add(mark)
        out.append(item)
        if len(out) >= limit:
            break
    return out


# Ближе этого два конца — один узел. Тот же шаг, что у координат в тайле.
PIECE_EPSILON = 1.5e-5


def _same_spot(one, other):
    return (abs(one[0] - other[0]) < PIECE_EPSILON
            and abs(one[1] - other[1]) < PIECE_EPSILON)


def street_pieces(roads, seed, limit=60):
    """Все куски ОДНОЙ улицы, начиная с выбранного.

    Полосы задаются на кусок, а улица приезжает кусками: сборка режет дороги
    по перекрёсткам, чтобы получился граф. Разметить проспект поштучно —
    пятнадцать правок вместо одной. Замерено на центре Ташкента: сто самых
    длинных улиц это 808 правок поштучно и 100 целиком.

    Правило то же, что у склейки в сборке, и не случайно: совпало имя — мало,
    «Мустакиллик» есть в каждом районе, поэтому конец одного куска обязан
    совпадать с началом другого.
    """
    name = (seed.get("name") or "").strip()
    if not name:
        return [seed]
    kin = [road for road in roads
           if (road.get("name") or "").strip() == name
           and road.get("cls") == seed.get("cls")
           and len(road.get("points") or ()) >= 2]
    found = [seed]
    taken = {id(seed)}
    growing = True
    while growing and len(found) < limit:
        growing = False
        for road in kin:
            # Потолок проверяем ЗДЕСЬ, а не только снаружи: один проход по
            # соседям добавляет сразу всех, и внешняя проверка узнаёт об этом
            # уже после. Улица длиной в тридцать кусков проходила потолок в
            # пять целиком.
            if len(found) >= limit:
                break
            if id(road) in taken:
                continue
            for mine in found:
                ends = (mine["points"][0], mine["points"][-1])
                theirs = (road["points"][0], road["points"][-1])
                if any(_same_spot(a, b) for a in ends for b in theirs):
                    found.append(road)
                    taken.add(id(road))
                    growing = True
                    break
    return found


def middle_of(points):
    """Точка посередине ломаной ПО ДЛИНЕ, а не по числу вершин.

    У куска из двух точек «средняя вершина» — это его конец, а концы общие у
    соседей: правка села бы на перекрёсток вместо дороги.
    """
    if not points:
        return None
    total = sum(meters_between(points[i - 1], points[i])
                for i in range(1, len(points)))
    if total <= 0:
        return list(points[0])
    walked = 0.0
    for index in range(1, len(points)):
        before, after = points[index - 1], points[index]
        piece = meters_between(before, after)
        if walked + piece >= total / 2:
            share = (total / 2 - walked) / piece if piece else 0
            return [before[0] + (after[0] - before[0]) * share,
                    before[1] + (after[1] - before[1]) * share]
        walked += piece
    return list(points[-1])


def load_points(tiles_dir, south, west, north, east):
    """Точечные объекты из тайлов: светофоры, переходы, стоп-линии, стрелки.

    Панель обязана показывать ТО ЖЕ, что увидит водитель, а без обстановки
    схема — половина картинки: дорога есть, а перекрёсток на ней ничем не
    отличается от прямого участка.

    Читаем набор `p` — ближний, посаженный на детальную геометрию. Дальний
    (`q`) пересчитан по костяку района и в панели, где всегда крупный масштаб,
    смысла не имеет.

    В опубликованном сейчас формате v1 точек нет вовсе: набор появился только в
    v2. Пусто — не ошибка, а «сервер ещё не публиковал точки»; своя обстановка
    из правок панели показывается независимо от этого.
    """
    if not tiles_dir or not os.path.isdir(tiles_dir):
        return []
    out = []
    for name in _tile_names(tiles_dir):
        if not name.startswith("road2_") or not name.endswith(".json"):
            continue
        body = name[len("road2_"):-len(".json")].rsplit("_", 1)
        if len(body) != 2 or body[1] != "p":
            continue
        box = _tile_box(name)
        if box is None or box[0] > north or box[2] < south \
                or box[1] > east or box[3] < west:
            continue
        for road in _tile_roads(os.path.join(tiles_dir, name)):
            spot = (road.get("points") or [None])[0]
            if spot is None:
                continue
            lon, lat = spot
            if south <= lat <= north and west <= lon <= east:
                flags = road["flags"]
                # Азимут и ширина проезжей части лежат в битах записи с самой
                # первой сборки точек. Без них зебра — кружок «здесь переход»;
                # с ними её можно нарисовать ровно поперёк дороги и ровно во
                # всю её ширину, то есть так, как она лежит на асфальте.
                out.append({"kind": road["cls"], "flags": flags,
                            "azimuth": (flags & PFLAG_AZIMUTH_MASK)
                                       * PFLAG_AZIMUTH_STEP,
                            "width": (flags >> PFLAG_WIDTH_SHIFT)
                                     & PFLAG_WIDTH_MASK,
                            "point": [lon, lat]})
    return out


def roads_near(tiles_dir, point, meters=200.0):
    """Дороги вокруг точки. Рамка считается от радиуса, а не берётся от мира.

    Нужна там, где раньше просили «все дороги»: сверка правок, отпечаток
    окрестности. Правка держится за МЕСТО, и всё, что дальше двухсот метров,
    к ней отношения не имеет — а стоит его чтение всей памяти панели.
    """
    lon, lat = float(point[0]), float(point[1])
    d_lat = meters / LAT_METERS
    d_lon = d_lat / max(0.2, math.cos(math.radians(lat)))
    return load_roads(tiles_dir, lat - d_lat, lon - d_lon, lat + d_lat, lon + d_lon)
