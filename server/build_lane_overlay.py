#!/usr/bin/env python3
"""Слой полос на перекрёстках (план 20.8): данные → lanes.<sha16>.json + индекс.

ЗАЧЕМ. OSRM отдаёт полосы только там, где в OSM есть `turn:lanes`, — у левых
поворотов Ташкента это 1 из 26 (замер 21.10). Слой полос — наш второй
источник: где OSRM молчит, телефон берёт ряд из подписанного файла. Контракт
файла — docs/lanes_overlay_contract.md (формат 1); здесь он соблюдается
дословно, и всё, что телефон отверг бы, отвергается ещё до подписи.

ВХОД — любой из трёх видов, сколько угодно файлов сразу:
  * CSV по шаблону server/lanes/lanes_template.csv
    (id, lat, lon, bearing, tolerance, lanes, src, checked; лишние столбцы —
    confidence, note — разрешены). Разделитель «,», «;» или табуляция —
    по заголовку (русский Excel пишет «;» и десятичную запятую);
  * GeoJSON-точки (FeatureCollection, Feature или по Feature на строку) с
    теми же свойствами; координаты — из геометрии;
  * файл данных в формате контракта ({"v": 1, "junctions": […]}) — так же
    читается выход --from-osm и опубликованный lanes.<sha16>.json (откат).

СТРЕЛКИ приводятся к словарю OSRM: through → straight, slight_left →
slight left, merge_to_left → merge to left, reverse → uturn, пустая
полоса → none; внутри полосы — без повторов и слева направо (uturn, sharp
left, left, slight left, merge to left, straight, merge to right, slight
right, right, sharp right). Одинаковый смысл — одинаковые байты.

ЛЮБОЙ ДЕФЕКТ — ОТКАЗ. Неизвестная стрелка, 0 или 9 полос, точка вне
Узбекистана, курс 360, допуск больше 45, повтор id, два подхода в 15 м с
курсами ближе 20°, дата проверки из будущего — файл не собирается вовсе, а в
выводе — список всех таких строк с файлом и номером строки. Подписанный
мусор доехал бы до всех телефонов, и отозвать его тихо было бы нельзя.

Два исключения, и оба — не ошибки ввода, а правила слияния:
  * --min-confidence: строка с confidence ниже порога отбрасывается (это
    выход распознавания, его неуверенность — норма); строка dashcam без
    confidence при заданном пороге — дефект;
  * дубли подходов OSM (src=osm) не останавливают сборку: OSM рядом с
    ручной записью уступает ей (survey/dashcam/vendor — проверка на месте
    там, где OSM не хватало), два подхода OSM в одном месте выбрасываются
    оба — недельный экстракт не должен останавливать публикацию из-за
    причуды разметки, а «нет данных» безопаснее неверного ряда (без слоя
    телефон советует край по ПДД).

ВЫХОД — как у графа трасс (build_route_graph.py):
  lanes.<sha16>.json  — данные; детерминированно: тот же вход в любом
                         порядке — те же байты и то же имя;
                         generated — полночь UTC самой свежей даты checked;
  index_payload.json  — {"format": 1, "version": …, "files": [{"format": 1,
                         "name", "sha256", "bytes"}]}; версия — unix-время
                         сборки (растёт и при откате на старые данные).
Подписывает индекс владелец у себя (publish_lanes.sh); этот скрипт ничего не
подписывает и никуда не ходит.

    python3 build_lane_overlay.py lanes/lanes.csv --report               # только проверка
    python3 build_lane_overlay.py lanes/lanes.csv --out-dir stage/ --report
    python3 build_lane_overlay.py --verify stage/                         # ворота перед подписью
    python3 build_lane_overlay.py --from-osm roads.geojsonl --osm-out lanes_osm.json
    python3 build_lane_overlay.py lanes/lanes.csv --review review.geojson  # глазами на geojson.io

Только stdlib: этот же файл едет на VPS для --from-osm (там экстракт).
"""
import argparse
import csv
import datetime
import hashlib
import io
import json
import math
import os
import re
import sys
import time
from collections import Counter, defaultdict

# --- Контракт (docs/lanes_overlay_contract.md) ---------------------------------

DATA_VERSION = 1          # "v" файла данных
INDEX_FORMAT = 1          # "format" индекса
DATA_FORMAT = 1           # "format" записи файла в индексе
NAME_PREFIX = "lanes"
# Каталог в вебруте (для publish_lanes.sh): имя в индексе — без каталога,
# телефон сам приставляет «lanes/», как «routes/» у графа трасс.
PUBLISHED_DIR = "lanes"
INDEX_NAME = "lanes_index.json"
NAME_SHA_CHARS = 16

MIN_LANES, MAX_LANES = 1, 8
DEFAULT_TOLERANCE = 30
# Верх — контракт. Низ — наш: допуск в 2° не совпадёт ни с одним курсом
# маршрута, такая строка — опечатка, а не данные.
MIN_TOLERANCE, MAX_TOLERANCE = 5, 45
MAX_JUNCTIONS = 50_000
# «8 МБ» контракта читается строже из двух толкований — 8·10⁶, а не 8·2²⁰:
# файл между ними телефон с другим толкованием отверг бы целиком.
MAX_BYTES = 8_000_000

# Дубль подхода: ближе 15 м и курсы ближе 20° — телефон взял бы любой из двух.
DUPLICATE_METERS = 15.0
DUPLICATE_DEGREES = 20.0

SOURCES = ("osm", "survey", "dashcam", "vendor")

# Словарь OSRM в порядке слева направо — он же порядок стрелок внутри полосы.
VOCABULARY = ("uturn", "sharp left", "left", "slight left", "merge to left",
              "straight", "merge to right", "slight right", "right",
              "sharp right", "none")
_ORDER = {token: index for index, token in enumerate(VOCABULARY)}
# Запись OSM → словарь OSRM (после нижнего регистра и «_» → пробел).
ALIASES = {"through": "straight", "reverse": "uturn", "": "none"}

# Рамка страны — по крайним точкам (как import_poi_egov.py). Телефон берёт
# рамку шире (AppConfig.uzLatRange 37–46, uzLonRange 55–74): всё, что прошло
# здесь, пройдёт и там.
LAT_RANGE = (37.15, 45.6)
LON_RANGE = (55.95, 73.2)

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
# Строки шаблона. Скопированный шаблон с образцами не должен уехать на
# телефоны: образец — выдуманный ряд на настоящем перекрёстке.
EXAMPLE_PREFIX = "example-"

CSV_FIELDS = ("id", "lat", "lon", "bearing", "tolerance", "lanes", "src", "checked")
EARLIEST_CHECKED = datetime.date(2000, 1, 1)

LAT_METERS = 111_320.0


# --- Мелочи -------------------------------------------------------------------

class Rejected(ValueError):
    """Строка не годится: причина — по-русски, для человека."""


def meters_between(a_lat, a_lon, b_lat, b_lon):
    kx = LAT_METERS * math.cos(math.radians((a_lat + b_lat) / 2))
    return math.hypot((a_lat - b_lat) * LAT_METERS, (a_lon - b_lon) * kx)


def bearing_between(a_lat, a_lon, b_lat, b_lon):
    """Азимут от A к B, градусы 0–360 (плоское приближение: отрезки — метры)."""
    kx = math.cos(math.radians((a_lat + b_lat) / 2))
    dx = (b_lon - a_lon) * kx
    dy = b_lat - a_lat
    return math.degrees(math.atan2(dx, dy)) % 360.0


def angle_apart(a, b):
    diff = abs(a - b) % 360.0
    return min(diff, 360.0 - diff)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def published_name(sha):
    """lanes.<sha16>.json — адрес, содержимое которого не меняется никогда."""
    return "%s.%s.json" % (NAME_PREFIX, sha[:NAME_SHA_CHARS])


def _number(value, what):
    if isinstance(value, bool):
        raise Rejected("%s: %r — не число" % (what, value))
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        text = str(value if value is not None else "").strip()
        if not text:
            raise Rejected("%s пусто" % what)
        # Десятичная запятая из русского Excel: «41,31102».
        if "," in text and "." not in text:
            text = text.replace(",", ".")
        try:
            number = float(text)
        except ValueError:
            raise Rejected("%s: %r — не число" % (what, value))
    if not math.isfinite(number):
        raise Rejected("%s: %r — не число" % (what, value))
    return number


# --- Стрелки -------------------------------------------------------------------

def normalize_token(token):
    """Одна стрелка → словарь OSRM. Неизвестная — Rejected."""
    text = " ".join(str(token).strip().lower().replace("_", " ").split())
    text = ALIASES.get(text, text)
    if text not in _ORDER:
        raise Rejected("стрелка %r не из словаря (%s)" % (str(token).strip(), ", ".join(VOCABULARY)))
    return text


def normalize_lane(value):
    """«through;left» → «left;straight». none вместе со стрелкой — Rejected."""
    tokens = []
    for part in str(value).split(";"):
        token = normalize_token(part)
        if token not in tokens:
            tokens.append(token)
    if "none" in tokens and len(tokens) > 1:
        raise Rejected("полоса %r: none вместе со стрелкой" % str(value).strip())
    tokens.sort(key=_ORDER.__getitem__)
    return ";".join(tokens)


def parse_lanes(value):
    """«left|left;straight|straight» или список → полосы слева направо."""
    if value is None:
        raise Rejected("lanes пусто")
    if isinstance(value, (list, tuple)):
        parts = list(value)
        if not parts:
            raise Rejected("lanes пусто")
    else:
        text = str(value).strip()
        if not text:
            raise Rejected("lanes пусто")
        parts = text.split("|")
    lanes = [normalize_lane(part) for part in parts]
    if not MIN_LANES <= len(lanes) <= MAX_LANES:
        raise Rejected("%d полос — допустимо %d–%d" % (len(lanes), MIN_LANES, MAX_LANES))
    if all(lane == "none" for lane in lanes):
        raise Rejected("ни одной стрелки: все полосы none — телефону нечего показать")
    return lanes


# --- Строка ---------------------------------------------------------------------

def parse_date(value, what="checked"):
    text = str(value if value is not None else "").strip()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        raise Rejected("%s: %r — нужна дата ГГГГ-ММ-ДД" % (what, text))
    try:
        return datetime.date.fromisoformat(text)
    except ValueError:
        raise Rejected("%s: %r — такой даты нет" % (what, text))


def validate_row(raw, today, allow_examples=False):
    """Сырая строка → запись контракта. На любом дефекте — Rejected.

    today — дата сборки: проверка «checked не из будущего» (запас в сутки на
    часовые пояса). Чистая функция: время только параметром.
    """
    if not isinstance(raw, dict):
        raise Rejected("запись — не объект")
    ident = str(raw.get("id") if raw.get("id") is not None else "").strip()
    if not ident:
        raise Rejected("id пусто")
    if not ID_RE.match(ident):
        raise Rejected("id %r: только латиница, цифры и . _ : -, до 64 знаков" % ident)
    if ident.startswith(EXAMPLE_PREFIX) and not allow_examples:
        raise Rejected("строка-образец из шаблона — удалите её")

    lat = _number(raw.get("lat"), "lat")
    lon = _number(raw.get("lon"), "lon")
    if not (LAT_RANGE[0] <= lat <= LAT_RANGE[1] and LON_RANGE[0] <= lon <= LON_RANGE[1]):
        raise Rejected("точка %.5f, %.5f вне Узбекистана" % (lat, lon))

    bearing = _number(raw.get("bearing"), "bearing")
    if not 0 <= bearing < 360:
        raise Rejected("bearing %s — нужно 0–359" % raw.get("bearing"))
    bearing = int(round(bearing)) % 360

    tolerance_raw = raw.get("tolerance")
    if tolerance_raw is None or str(tolerance_raw).strip() == "":
        tolerance = DEFAULT_TOLERANCE
    else:
        tolerance = int(round(_number(tolerance_raw, "tolerance")))
        if not MIN_TOLERANCE <= tolerance <= MAX_TOLERANCE:
            raise Rejected("tolerance %s — нужно %d–%d" % (tolerance_raw, MIN_TOLERANCE, MAX_TOLERANCE))

    lanes = parse_lanes(raw.get("lanes"))

    src = str(raw.get("src") if raw.get("src") is not None else "").strip().lower()
    if src not in SOURCES:
        raise Rejected("src %r — нужно одно из: %s" % (raw.get("src"), ", ".join(SOURCES)))

    checked = parse_date(raw.get("checked"))
    if checked < EARLIEST_CHECKED:
        raise Rejected("checked %s — раньше 2000 года" % checked)
    if checked > today + datetime.timedelta(days=1):
        raise Rejected("checked %s — из будущего (сегодня %s)" % (checked, today))

    return {"id": ident, "lat": round(lat, 5), "lon": round(lon, 5),
            "bearing": bearing, "tolerance": tolerance, "lanes": lanes,
            "src": src, "checked": checked.isoformat()}


def confidence_of(raw):
    """confidence строки: None — столбца нет или он пуст; иначе 0..1."""
    value = raw.get("confidence") if isinstance(raw, dict) else None
    if value is None or str(value).strip() == "":
        return None
    number = _number(value, "confidence")
    if not 0.0 <= number <= 1.0:
        raise Rejected("confidence %s — нужно 0..1" % value)
    return number


# --- Чтение входа --------------------------------------------------------------

def _sniff_delimiter(header):
    counts = {sep: header.count(sep) for sep in (",", ";", "\t")}
    best = max(counts, key=counts.get)
    return best if counts[best] else ","


def read_csv_text(text, label):
    """CSV → [(где, сырая строка)]. Строки, где id начинается с «#», —
    комментарии; пустые — пропуск. Нет обязательного столбца — Rejected на
    весь файл (ValueError)."""
    lines = text.splitlines()
    header_index = next((i for i, line in enumerate(lines) if line.strip()), None)
    if header_index is None:
        return []
    delimiter = _sniff_delimiter(lines[header_index])
    reader = csv.reader(io.StringIO(text), delimiter=delimiter)
    rows = []
    header = None
    for line_no, cells in enumerate(reader, start=1):
        if header is None:
            if not any(cell.strip() for cell in cells):
                continue
            header = [cell.strip().lower() for cell in cells]
            missing = [field for field in CSV_FIELDS if field not in header]
            if missing:
                raise ValueError("%s: в заголовке нет столбцов %s (нужны: %s)"
                                 % (label, ", ".join(missing), ", ".join(CSV_FIELDS)))
            continue
        if not any(cell.strip() for cell in cells):
            continue
        if cells and cells[0].strip().startswith("#"):
            continue
        raw = {name: (cells[i] if i < len(cells) else "") for i, name in enumerate(header) if name}
        rows.append(("%s:%d" % (label, line_no), raw))
    return rows


def _feature_row(feature):
    if not isinstance(feature, dict) or feature.get("type") != "Feature":
        return {"__defect__": "не GeoJSON Feature"}
    geometry = feature.get("geometry") or {}
    raw = dict(feature.get("properties") or {})
    if geometry.get("type") != "Point" or not isinstance(geometry.get("coordinates"), list) \
            or len(geometry["coordinates"]) < 2:
        return {"__defect__": "геометрия не Point"}
    raw["lon"], raw["lat"] = geometry["coordinates"][0], geometry["coordinates"][1]
    return raw


def read_document(doc, label):
    """Разобранный JSON (GeoJSON или файл данных) → [(где, сырая строка)]."""
    if isinstance(doc, dict) and doc.get("type") == "FeatureCollection":
        features = doc.get("features")
        if not isinstance(features, list):
            raise ValueError("%s: FeatureCollection без features" % label)
        return [("%s#%d" % (label, i + 1), _feature_row(f)) for i, f in enumerate(features)]
    if isinstance(doc, dict) and doc.get("type") == "Feature":
        return [("%s#1" % label, _feature_row(doc))]
    if isinstance(doc, dict) and "junctions" in doc:
        if doc.get("v") != DATA_VERSION:
            raise ValueError("%s: файл данных версии %r, умеем %d" % (label, doc.get("v"), DATA_VERSION))
        junctions = doc.get("junctions")
        if not isinstance(junctions, list):
            raise ValueError("%s: junctions не список" % label)
        return [("%s#%d" % (label, i + 1), j) for i, j in enumerate(junctions)]
    raise ValueError("%s: не GeoJSON и не файл данных слоя полос" % label)


def read_input(path):
    """Файл любого из трёх видов → [(где, сырая строка)]."""
    label = os.path.basename(path)
    with open(path, encoding="utf-8-sig") as handle:
        text = handle.read()
    lower = path.lower()
    if lower.endswith((".csv", ".tsv", ".txt")):
        return read_csv_text(text, label)
    if lower.endswith((".geojsonl", ".geojsons", ".jsonl", ".ndjson")):
        rows = []
        for line_no, line in enumerate(text.splitlines(), start=1):
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError as error:
                rows.append(("%s:%d" % (label, line_no), {"__defect__": "не JSON (%s)" % error}))
                continue
            rows.append(("%s:%d" % (label, line_no), _feature_row(feature)))
        return rows
    try:
        doc = json.loads(text)
    except ValueError as error:
        raise ValueError("%s: не JSON (%s)" % (label, error))
    return read_document(doc, label)


# --- Сборка ---------------------------------------------------------------------

def _cell(lat, lon):
    return (int(math.floor(lat / 0.0003)), int(math.floor(lon / 0.0004)))


def find_duplicates(junctions, meters=DUPLICATE_METERS, degrees=DUPLICATE_DEGREES):
    """Пары индексов подходов, которые телефон не различит: ближе `meters` и
    курсы ближе `degrees`. Сетка ~33×33 м — сравнение только с соседями."""
    grid = defaultdict(list)
    for index, junction in enumerate(junctions):
        grid[_cell(junction["lat"], junction["lon"])].append(index)
    pairs = []
    for index, junction in enumerate(junctions):
        cx, cy = _cell(junction["lat"], junction["lon"])
        for gx in (cx - 1, cx, cx + 1):
            for gy in (cy - 1, cy, cy + 1):
                for other in grid.get((gx, gy), ()):
                    if other <= index:
                        continue
                    peer = junctions[other]
                    if angle_apart(junction["bearing"], peer["bearing"]) > degrees:
                        continue
                    distance = meters_between(junction["lat"], junction["lon"], peer["lat"], peer["lon"])
                    if distance <= meters:
                        pairs.append((index, other, distance))
    return pairs


def assemble(rows, today, min_confidence=None, allow_examples=False):
    """[(где, сырая строка)] → (подходы, ошибки, отброшенные).

    ошибки      — [(где, id, причина)]: хоть одна — файл не собирается;
    отброшенные — [(где, id, причина)]: по правилам слияния (порог
                  уверенности, дубли OSM), сборку не останавливают.
    Подходы отсортированы по id: порядок входа на байты не влияет.
    """
    errors, dropped = [], []
    valid = []        # (где, запись)
    for where, raw in rows:
        ident = str(raw.get("id", "") if isinstance(raw, dict) else "").strip() or "—"
        if isinstance(raw, dict) and "__defect__" in raw:
            errors.append((where, ident, raw["__defect__"]))
            continue
        try:
            junction = validate_row(raw, today, allow_examples=allow_examples)
            confidence = confidence_of(raw)
        except Rejected as error:
            errors.append((where, ident, str(error)))
            continue
        if min_confidence is not None:
            if confidence is None and junction["src"] == "dashcam":
                errors.append((where, ident, "dashcam без confidence при пороге %.2f" % min_confidence))
                continue
            if confidence is not None and confidence < min_confidence:
                dropped.append((where, ident, "уверенность %.2f ниже порога %.2f"
                                % (confidence, min_confidence)))
                continue
        valid.append((where, junction))

    by_id = defaultdict(list)
    for position, (where, junction) in enumerate(valid):
        by_id[junction["id"]].append(position)
    clashing = set()
    for ident, positions in by_id.items():
        if len(positions) > 1:
            places = ", ".join(valid[p][0] for p in positions)
            for p in positions:
                errors.append((valid[p][0], ident, "id повторяется (%s)" % places))
                clashing.add(p)
    valid = [item for p, item in enumerate(valid) if p not in clashing]

    junctions = [junction for _where, junction in valid]
    drop = {}          # индекс → причина
    defective = set()
    for a, b, distance in find_duplicates(junctions):
        one, two = junctions[a], junctions[b]
        osm_one, osm_two = one["src"] == "osm", two["src"] == "osm"
        what = "%s и %s в %.0f м, курсы %d° и %d°" % (one["id"], two["id"], distance,
                                                      one["bearing"], two["bearing"])
        if osm_one and osm_two:
            drop.setdefault(a, "два подхода OSM в одном месте: " + what)
            drop.setdefault(b, "два подхода OSM в одном месте: " + what)
        elif osm_one or osm_two:
            loser = a if osm_one else b
            drop.setdefault(loser, "OSM уступает ручной записи: " + what)
        else:
            for index in (a, b):
                if index not in defective:
                    defective.add(index)
                    errors.append((valid[index][0], junctions[index]["id"],
                                   "дубль подхода: " + what))
    kept = []
    for index, (where, junction) in enumerate(valid):
        if index in defective:
            continue
        if index in drop:
            dropped.append((where, junction["id"], drop[index]))
            continue
        kept.append(junction)

    if len(kept) > MAX_JUNCTIONS:
        errors.append(("—", "—", "подходов %d — больше %d" % (len(kept), MAX_JUNCTIONS)))
    kept.sort(key=lambda j: j["id"])
    return kept, errors, dropped


def generated_of(junctions):
    """Полночь UTC самой свежей проверки: «данные на дату», и детерминированно."""
    latest = max(datetime.date.fromisoformat(j["checked"]) for j in junctions)
    return int(datetime.datetime(latest.year, latest.month, latest.day,
                                 tzinfo=datetime.timezone.utc).timestamp())


def _junction_json(junction):
    return json.dumps(junction, separators=(",", ":"), sort_keys=True, ensure_ascii=False)


def encode_data(junctions, generated):
    """Байты файла данных: по подходу на строку — diff двух версий читается
    глазами. Ключи отсортированы, подходы — по id (assemble)."""
    body = ",\n".join(_junction_json(j) for j in junctions)
    return ('{"generated":%d,"junctions":[\n%s\n],"v":%d}\n'
            % (generated, body, DATA_VERSION)).encode("utf-8")


def build_data(junctions, generated=None):
    if not junctions:
        raise ValueError("нет ни одного подхода — пустой слой не публикуем "
                         "(выключить слой — пульт features.laneOverlay)")
    data = encode_data(junctions, generated_of(junctions) if generated is None else generated)
    if len(data) > MAX_BYTES:
        raise ValueError("файл %d байт — больше %d" % (len(data), MAX_BYTES))
    return data


def build_payload(data, version):
    """Индекс: {format, version, files: [{format, name, sha256, bytes}]}."""
    if not isinstance(version, int) or isinstance(version, bool) or version <= 0:
        raise ValueError("версия слоя должна быть целым > 0, а не %r" % (version,))
    sha = sha256_hex(data)
    return {"format": INDEX_FORMAT, "version": version,
            "files": [{"format": DATA_FORMAT, "name": published_name(sha),
                       "sha256": sha, "bytes": len(data)}]}


def encode_payload(payload):
    """Байты, которые подписываются (как у лимитов и графа трасс)."""
    return json.dumps(payload, separators=(",", ":"), sort_keys=True,
                      ensure_ascii=False).encode("utf-8")


def write_stage(out_dir, data, payload):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, payload["files"][0]["name"]), "wb") as handle:
        handle.write(data)
    with open(os.path.join(out_dir, "index_payload.json"), "wb") as handle:
        handle.write(encode_payload(payload))


def check_data(data, today):
    """Ворота на готовом файле — так, как его прочтёт телефон, и строже:
    каждая запись по контракту, порядок и байты канонические, дублей нет.
    Возвращает подходы; на дефекте — ValueError."""
    if len(data) > MAX_BYTES:
        raise ValueError("файл %d байт — больше %d" % (len(data), MAX_BYTES))
    try:
        doc = json.loads(data)
    except ValueError as error:
        raise ValueError("не JSON (%s)" % error)
    if not isinstance(doc, dict) or doc.get("v") != DATA_VERSION:
        raise ValueError("нет \"v\": %d" % DATA_VERSION)
    generated = doc.get("generated")
    if not isinstance(generated, int) or isinstance(generated, bool) or generated <= 0:
        raise ValueError("generated %r" % (generated,))
    junctions = doc.get("junctions")
    if not isinstance(junctions, list) or not junctions:
        raise ValueError("нет подходов")
    if len(junctions) > MAX_JUNCTIONS:
        raise ValueError("подходов %d — больше %d" % (len(junctions), MAX_JUNCTIONS))
    for position, junction in enumerate(junctions):
        if not isinstance(junction, dict) or sorted(junction) != sorted(CSV_FIELDS):
            raise ValueError("подход %d: поля не по контракту" % position)
        try:
            normal = validate_row(junction, today)
        except Rejected as error:
            raise ValueError("подход %d (%s): %s" % (position, junction.get("id"), error))
        if normal != junction:
            raise ValueError("подход %d (%s) не в каноническом виде" % (position, junction.get("id")))
    ids = [j["id"] for j in junctions]
    if ids != sorted(ids) or len(set(ids)) != len(ids):
        raise ValueError("id не отсортированы или повторяются")
    pairs = find_duplicates(junctions)
    if pairs:
        a, b, distance = pairs[0]
        raise ValueError("дубль подхода: %s и %s в %.0f м" % (ids[a], ids[b], distance))
    if data != encode_data(junctions, generated):
        raise ValueError("файл не в каноническом виде")
    return junctions


def verify_stage(stage_dir, today=None):
    """Ворота на каталоге сборки: индекс ↔ файл (sha, размер, имя) + check_data.
    Именно это publish_lanes.sh запускает перед подписью."""
    today = today or datetime.date.today()
    with open(os.path.join(stage_dir, "index_payload.json"), "rb") as handle:
        raw = handle.read()
    payload = json.loads(raw)
    if raw != encode_payload(payload):
        raise ValueError("index_payload.json не в каноническом виде")
    if sorted(payload) != ["files", "format", "version"] or payload["format"] != INDEX_FORMAT:
        raise ValueError("индекс не по контракту: %r" % sorted(payload))
    version = payload["version"]
    if not isinstance(version, int) or isinstance(version, bool) or version <= 0:
        raise ValueError("версия %r" % (version,))
    files = payload["files"]
    if not isinstance(files, list) or len(files) != 1:
        raise ValueError("в индексе не один файл")
    entry = files[0]
    if not isinstance(entry, dict) or sorted(entry) != ["bytes", "format", "name", "sha256"] \
            or entry["format"] != DATA_FORMAT:
        raise ValueError("запись файла не по контракту: %r" % (entry,))
    if entry["name"] != os.path.basename(entry["name"]):
        raise ValueError("имя %r с каталогом" % entry["name"])
    with open(os.path.join(stage_dir, entry["name"]), "rb") as handle:
        data = handle.read()
    if entry["bytes"] != len(data) or entry["sha256"] != sha256_hex(data):
        raise ValueError("файл не сошёлся с индексом по sha или размеру")
    if entry["name"] != published_name(entry["sha256"]):
        raise ValueError("имя %s не от его sha" % entry["name"])
    return payload, check_data(data, today)


# --- turn:lanes из экстракта OSM ---------------------------------------------------
#
# Путь А интеграции: разметить turn:lanes в OSM. OSRM видит правку только после
# пересборки графа, а она на VPS выключена с 19.07.2026 (граф не влезает в
# память) — зато недельный экстракт roads.geojsonl (update_roads.sh) несёт
# теги как есть. Отсюда подходы src=osm для слоя: правка в OSM доезжает до
# телефона с ближайшей публикацией, без пересборки OSRM.
#
# Правила консервативные — неверный ряд хуже никакого:
#   * turn:lanes на односторонней (oneway=yes/1/true, кольцо, motorway) — по
#     ходу точек; oneway=-1 — против; :forward/:backward — на двусторонней;
#     голый turn:lanes на двусторонней неоднозначен и пропускается;
#   * подход — КОНЕЦ линии по ходу движения, и только если там перекрёсток
#     (сходятся ≥ 3 ветви автодорог); линия, кончающаяся посреди улицы, —
#     пропуск (OSRM дотянул бы ряд до следующего узла, мы — нет);
#   * курс — по последним ~20 м перед узлом;
#   * id — osm-<way>-f / -b: тот же между недельными выгрузками, пока линию
#     не разрезали.

CAR_HIGHWAYS = frozenset((
    "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
    "residential", "living_street", "service", "road"))
ONEWAY_FORWARD = ("yes", "1", "true")
ONEWAY_BACKWARD = ("-1",)
ONEWAY_NO = ("no", "0", "false")
ONEWAY_SKIP = ("reversible", "alternating")
RING_JUNCTIONS = ("roundabout", "circular")
BEARING_BACK_METERS = 20.0
JUNCTION_ARMS = 3


def _features(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.lstrip("\x1e").strip()
            if line:
                try:
                    yield json.loads(line)
                except ValueError:
                    yield None


def _line_of(feature):
    if not isinstance(feature, dict):
        return None, None
    props = feature.get("properties") or {}
    geometry = feature.get("geometry") or {}
    if geometry.get("type") != "LineString" or props.get("highway") not in CAR_HIGHWAYS:
        return None, None
    coords = geometry.get("coordinates") or []
    points = []
    for pair in coords:
        try:
            points.append((float(pair[1]), float(pair[0])))     # (lat, lon)
        except (TypeError, ValueError, IndexError):
            return None, None
    return (props, points) if len(points) >= 2 else (None, None)


def _key(point):
    return (round(point[0], 7), round(point[1], 7))


def _approach_bearing(points):
    """Курс въезда: от точки ~BEARING_BACK_METERS до конца к концу."""
    end = points[-1]
    travelled = 0.0
    start = points[-1]
    for previous, current in zip(reversed(points[:-1]), reversed(points[1:])):
        travelled += meters_between(previous[0], previous[1], current[0], current[1])
        start = previous
        if travelled >= BEARING_BACK_METERS:
            break
    if travelled < 1.0:
        return None
    return int(round(bearing_between(start[0], start[1], end[0], end[1]))) % 360


def osm_directions(props, points):
    """[(суффикс, точки по ходу движения, значение turn:lanes)] и причина пропуска."""
    oneway = str(props.get("oneway", "")).strip().lower()
    plain = props.get("turn:lanes")
    forward = props.get("turn:lanes:forward")
    backward = props.get("turn:lanes:backward")
    if not (plain or forward or backward):
        return [], None
    if oneway in ONEWAY_SKIP:
        return [], "реверсивная дорога"
    implied = (str(props.get("junction", "")).lower() in RING_JUNCTIONS
               or props.get("highway") == "motorway")
    if oneway in ONEWAY_BACKWARD:
        value = plain or backward
        return ([("b", list(reversed(points)), value)] if value else []), None
    if oneway in ONEWAY_FORWARD or (implied and oneway not in ONEWAY_NO):
        value = plain or forward
        return ([("f", points, value)] if value else []), None
    out = []
    if forward:
        out.append(("f", points, forward))
    if backward:
        out.append(("b", list(reversed(points)), backward))
    if not out:
        return [], "turn:lanes на двусторонней без :forward/:backward"
    return out, None


def osm_rows(path, checked):
    """Подходы src=osm из roads.geojsonl (osmium export -u type_id).

    Два прохода, чтобы не держать страну в памяти (на VPS 2 ГБ и рядом OSRM):
    первый собирает линии с turn:lanes, второй считает ветви только в их
    концах. Возвращает (строки контракта, Counter причин пропуска).
    """
    stats = Counter()
    candidates = []
    for feature in _features(path):
        props, points = _line_of(feature)
        if props is None:
            continue
        directions, skip = osm_directions(props, points)
        if skip:
            stats[skip] += 1
        for suffix, ordered, value in directions:
            way = str(feature.get("id") or "").strip()
            if not re.fullmatch(r"w\d+", way):
                stats["нет id линии (нужен osmium export -u type_id)"] += 1
                continue
            candidates.append((way, suffix, ordered, value))
    ends = {_key(ordered[-1]) for _w, _s, ordered, _v in candidates}
    arms = Counter()
    if ends:
        for feature in _features(path):
            props, points = _line_of(feature)
            if props is None:
                continue
            last = len(points) - 1
            for position, point in enumerate(points):
                key = _key(point)
                if key in ends:
                    arms[key] += 1 if position in (0, last) else 2
    rows = []
    for way, suffix, ordered, value in candidates:
        end = ordered[-1]
        if arms[_key(end)] < JUNCTION_ARMS:
            stats["конец линии не на перекрёстке"] += 1
            continue
        if not (LAT_RANGE[0] <= end[0] <= LAT_RANGE[1] and LON_RANGE[0] <= end[1] <= LON_RANGE[1]):
            stats["вне рамки страны"] += 1
            continue
        bearing = _approach_bearing(ordered)
        if bearing is None:
            stats["линия короче метра"] += 1
            continue
        try:
            lanes = parse_lanes(value)
        except Rejected:
            # Неизвестная стрелка, больше 8 полос, все none: в слой не идёт,
            # и это не повод останавливать всю выгрузку.
            stats["turn:lanes не разобран"] += 1
            continue
        rows.append({"id": "osm-%s-%s" % (way, suffix),
                     "lat": round(end[0], 5), "lon": round(end[1], 5),
                     "bearing": bearing, "tolerance": DEFAULT_TOLERANCE,
                     "lanes": lanes, "src": "osm", "checked": checked})
        stats["подходов"] += 1
    rows.sort(key=lambda r: r["id"])
    return rows, stats


def extract_date(path):
    """Дата выгрузки по времени файла (UTC): для checked подходов OSM."""
    return datetime.datetime.fromtimestamp(os.path.getmtime(path),
                                           datetime.timezone.utc).date().isoformat()


# --- Просмотр ---------------------------------------------------------------------

def review_geojson(junctions, arrow_meters=40.0):
    """Подходы для просмотра глазами (geojson.io): точка + линия курса длиной
    `arrow_meters`, ВХОДЯЩАЯ в точку. Линия, торчащая из перекрёстка не туда, —
    ошибка курса, видная без всяких чисел."""
    features = []
    for j in junctions:
        rad = math.radians(j["bearing"])
        back_lat = j["lat"] - arrow_meters * math.cos(rad) / LAT_METERS
        back_lon = j["lon"] - arrow_meters * math.sin(rad) / (LAT_METERS * math.cos(math.radians(j["lat"])))
        props = {"id": j["id"], "lanes": " | ".join(j["lanes"]), "bearing": j["bearing"],
                 "tolerance": j["tolerance"], "src": j["src"], "checked": j["checked"]}
        features.append({"type": "Feature", "properties": props,
                         "geometry": {"type": "Point", "coordinates": [j["lon"], j["lat"]]}})
        features.append({"type": "Feature", "properties": dict(props, kind="курс"),
                         "geometry": {"type": "LineString",
                                      "coordinates": [[round(back_lon, 6), round(back_lat, 6)],
                                                      [j["lon"], j["lat"]]]}})
    return {"type": "FeatureCollection", "features": features}


# --- Отчёт и CLI -------------------------------------------------------------------

def print_report(junctions, errors, dropped, out=sys.stdout):
    counts = Counter(j["src"] for j in junctions)
    print("подходов принято: %d" % len(junctions), file=out)
    if counts:
        print("  по источникам: " + ", ".join("%s %d" % (src, counts[src])
                                               for src in SOURCES if counts[src]), file=out)
        lanes = Counter(len(j["lanes"]) for j in junctions)
        print("  полос в ряду: " + ", ".join("%d — %d" % (n, lanes[n]) for n in sorted(lanes)), file=out)
    if dropped:
        print("отброшено по правилам слияния: %d" % len(dropped), file=out)
        for where, ident, reason in dropped:
            print("  %s %s: %s" % (where, ident, reason), file=out)
    if errors:
        print("ОШИБКИ: %d" % len(errors), file=out)
        for where, ident, reason in errors:
            print("  %s %s: %s" % (where, ident, reason), file=out)


def main(argv=None, out=sys.stdout):
    parser = argparse.ArgumentParser(description="слой полос на перекрёстках (контракт v1)")
    parser.add_argument("inputs", nargs="*", help="CSV, GeoJSON или файл данных слоя")
    parser.add_argument("--out-dir", help="каталог для lanes.<sha16>.json и index_payload.json")
    parser.add_argument("--version", type=int, default=None,
                        help="версия в индексе (по умолчанию unix-время сборки)")
    parser.add_argument("--generated", type=int, default=None,
                        help="generated файла (по умолчанию полночь UTC свежайшей checked)")
    parser.add_argument("--report", action="store_true", help="счёт по источникам и все отказы")
    parser.add_argument("--min-confidence", type=float, default=None,
                        help="строки с confidence ниже — отбросить (выход регистратора)")
    parser.add_argument("--allow-examples", action="store_true",
                        help="пропустить строки example-* (только для проверки шаблона)")
    parser.add_argument("--osm", metavar="GEOJSONL",
                        help="добавить подходы из turn:lanes экстракта OSM")
    parser.add_argument("--osm-date", help="checked подходов OSM (по умолчанию — дата файла)")
    parser.add_argument("--from-osm", metavar="GEOJSONL",
                        help="только вытащить подходы OSM в --osm-out (без сборки)")
    parser.add_argument("--osm-out", help="куда писать подходы OSM для --from-osm")
    parser.add_argument("--review", metavar="GEOJSON", help="подходы для просмотра на geojson.io")
    parser.add_argument("--verify", metavar="STAGE", help="только ворота каталога сборки")
    parser.add_argument("--today", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()

    if args.verify:
        try:
            payload, junctions = verify_stage(args.verify, today)
        except (OSError, ValueError) as error:
            print("НЕ ПОДПИСЫВАТЬ: %s" % error, file=out)
            return 1
        entry = payload["files"][0]
        print("слой полос годен: %s — %d подходов, %d КиБ, версия %d" % (
            entry["name"], len(junctions), entry["bytes"] // 1024, payload["version"]), file=out)
        return 0

    if args.from_osm:
        if not args.osm_out:
            parser.error("--from-osm требует --osm-out")
        rows, stats = osm_rows(args.from_osm, args.osm_date or extract_date(args.from_osm))
        doc = {"v": DATA_VERSION, "generated": generated_of(rows) if rows else 0, "junctions": rows}
        with open(args.osm_out, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        print("подходы из turn:lanes OSM: %d → %s" % (len(rows), args.osm_out), file=out)
        for reason, count in sorted(stats.items()):
            if reason != "подходов":
                print("  пропущено: %s — %d" % (reason, count), file=out)
        return 0

    if not args.inputs and not args.osm:
        parser.error("нужен хоть один вход (CSV, GeoJSON, файл данных) или --osm")

    rows = []
    try:
        for path in args.inputs:
            rows.extend(read_input(path))
    except (OSError, ValueError) as error:
        print("НЕ ПОДПИСЫВАТЬ: %s" % error, file=out)
        return 1
    if args.osm:
        derived, stats = osm_rows(args.osm, args.osm_date or extract_date(args.osm))
        label = os.path.basename(args.osm)
        rows.extend(("%s/%s" % (label, row["id"]), row) for row in derived)
        print("подходы из turn:lanes OSM: %d" % len(derived), file=out)

    junctions, errors, dropped = assemble(rows, today, min_confidence=args.min_confidence,
                                          allow_examples=args.allow_examples)
    data = None
    if not errors:
        try:
            data = build_data(junctions, args.generated)
        except ValueError as error:
            errors.append(("—", "—", str(error)))
    if args.report or errors:
        print_report(junctions, errors, dropped, out)
    if errors:
        print("НЕ ПОДПИСЫВАТЬ: %d ошибок во входе — исправьте и запустите снова" % len(errors), file=out)
        return 1

    if args.review:
        with open(args.review, "w", encoding="utf-8") as handle:
            json.dump(review_geojson(junctions), handle, ensure_ascii=False)
        print("для просмотра: %s" % args.review, file=out)

    if not args.out_dir:
        print("проверено: %d подходов, sha %s (без --out-dir ничего не записано)"
              % (len(junctions), sha256_hex(data)[:NAME_SHA_CHARS]), file=out)
        return 0
    version = args.version if args.version is not None else int(time.time())
    try:
        payload = build_payload(data, version)
    except ValueError as error:
        print("НЕ ПОДПИСЫВАТЬ: %s" % error, file=out)
        return 1
    write_stage(args.out_dir, data, payload)
    entry = payload["files"][0]
    print("слой полос: %s — %d подходов, %d байт, версия %d" % (
        entry["name"], len(junctions), entry["bytes"], version), file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
