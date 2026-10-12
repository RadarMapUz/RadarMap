#!/usr/bin/env python3
"""import_poi_egov.py — банкоматы и гостиницы с портала открытых данных.

«Банкомат рядом» в OSM по Узбекистану отвечает полутора тысячами точек, а
реестр Центробанка на data.egov.uz знает девять с лишним тысяч — в семь раз
больше, с банком и адресом. Сертифицированные гостиницы (две тысячи) — для
междугородних поездок: в OSM за пределами Ташкента и Самарканда их почти нет.

Что делает: скачивает оба набора постранично (таймауты, повторы), выбрасывает
строки без координат или с координатами вне Узбекистана, схлопывает дубли
(одно название ближе 20 м) и пишет два файла GeoJSON Text Sequence —
`poi/egov_atm.geojsonl` и `poi/egov_hotel.geojsonl` — в том же виде, что
`osmium export` даёт для заведений OSM: `build_roads.py --venues-extra`
сливает их с OSM по расстоянию (30 м) и кладёт в клетки «v» для поиска.

Теги в свойствах — осмовские намеренно (amenity=atm, tourism=hotel, name,
operator, addr:full): сборка заведений ничего не знает про портал и не должна.

ЛИЦЕНЗИЯ. Данные портала — CC BY-SA 4.0 (https://data.egov.uz, Агентство
«Электронное правительство»), ссылка обязательна: первая строка каждого файла
и server/ATTRIBUTION.md её несут. Никаких персональных данных в наборах нет
(банк, адрес, координата; у гостиниц — ИНН юрлица, который мы не берём).

Запуск (на маке, раз в месяц-два; сеть нужна только здесь):
    python3 import_poi_egov.py                 # → server/poi/*.geojsonl
    python3 import_poi_egov.py --out-dir /tmp/poi --page 500
Тесты (без сети, на фикстурах из server/fixtures/):
    python3 test_import_poi_egov.py
"""
import argparse
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request

PORTAL = "https://data.egov.uz"
API = PORTAL + "/apiClient/Main/GetMainData?GuidId={guid}"
LICENSE = "CC BY-SA 4.0"
LICENSE_URL = "https://creativecommons.org/licenses/by-sa/4.0/"

#: Наборы портала. code — номер в каталоге, guid — structId для API.
DATASETS = {
    "atm": {"guid": "664af8be2f776a551cd0b845", "code": "4-009-0061",
            "title": "Реестр банкоматов (Центральный банк)",
            "url": PORTAL + "/ru/data/664af8be2f776a551cd0b845"},
    "hotel": {"guid": "662758862f776a551cc8b7c6", "code": "2-017-0007",
              "title": "Сертифицированные гостиницы",
              "url": PORTAL + "/ru/data/662758862f776a551cc8b7c6"},
}

#: Границы Узбекистана с запасом. Строки с lat=39809352 (запятая потеряна при
#: вводе) и с нулями режутся здесь.
LAT_RANGE = (37.0, 46.0)
LON_RANGE = (55.0, 74.0)
#: Один объект, занесённый дважды (две карты в одном банкомате, две записи
#: одного отеля) — одно название ближе этого расстояния.
DUPLICATE_METERS = 20.0
#: Размер страницы API и сетевые пределы.
PAGE = 1000
TIMEOUT = 60
RETRIES = 3
M_PER_DEG_LAT = 111_320.0

#: Правовые формы в названиях юрлиц: «"SM HOTEL" MChJ» → «SM HOTEL».
LEGAL_FORMS = {"mchj", "mchj.", "ok", "aj", "xk", "yatt", "ooo", "ооо", "ао", "чп",
               "mchj,", "xususiy", "korxonasi", "korxona", "ltd", "llc"}


def distance(lat1, lon1, lat2, lon2):
    """Метры по плоской аппроксимации: расстояния здесь — десятки метров."""
    kx = M_PER_DEG_LAT * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lat2 - lat1) * M_PER_DEG_LAT, (lon2 - lon1) * kx)


# --- разбор строк портала -------------------------------------------------

def text_of(cell):
    """Значение ячейки. Текстовые поля приходят на четырёх языках — берём
    русский, иначе латиницу, иначе кириллицу; прочие — `data`/`default`."""
    if not isinstance(cell, dict):
        return ""
    text = cell.get("text")
    if isinstance(text, dict):
        for key in ("rusText", "uzbText", "uzbKrText", "engText"):
            value = text.get(key)
            if value and str(value).strip():
                return str(value).strip()
        return ""
    for key in ("data", "default"):
        value = cell.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return ""


def number_of(cell):
    """Число из ячейки: `number`, иначе текст с запятой вместо точки."""
    if not isinstance(cell, dict):
        return None
    value = cell.get("number")
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value != 0:
        return float(value)
    raw = text_of(cell).replace(",", ".")
    try:
        return float(raw)
    except ValueError:
        return None


def coordinates(columns):
    """(lat, lon) или None. Перестановка широты и долготы распознаётся — у
    реестра камер такое уже случалось, — а всё остальное отбрасывается."""
    a = number_of(columns.get("latitude"))
    b = number_of(columns.get("longitude"))
    if a is None or b is None:
        return None
    if LAT_RANGE[0] <= a <= LAT_RANGE[1] and LON_RANGE[0] <= b <= LON_RANGE[1]:
        return round(a, 6), round(b, 6)
    if LAT_RANGE[0] <= b <= LAT_RANGE[1] and LON_RANGE[0] <= a <= LON_RANGE[1]:
        return round(b, 6), round(a, 6)
    return None


def clean_spaces(value):
    return re.sub(r"\s+", " ", value or "").strip(" ,;")


def legal_name(value):
    """Имя заведения из названия юрлица: кавычки, иначе без правовой формы."""
    value = clean_spaces(value)
    quoted = re.search(r"[\"“«]([^\"”»]+)[\"”»]", value)
    if quoted and quoted.group(1).strip():
        return clean_spaces(quoted.group(1))
    words = [w for w in value.split(" ") if w.lower().strip(".,") not in LEGAL_FORMS]
    return clean_spaces(" ".join(words)) or value


def row_id(row):
    """Устойчивый ключ строки портала (mongo-id записи)."""
    return str(row.get("id") or "").strip()


def parse_atm(row):
    """Строка реестра банкоматов → запись или None (без координат)."""
    columns = row.get("tableColumn") or {}
    spot = coordinates(columns)
    if spot is None:
        return None
    bank = clean_spaces(text_of(columns.get("Bank")))
    title = clean_spaces(text_of(columns.get("Nomlanishi")))
    return {
        "lat": spot[0], "lon": spot[1],
        # Название — банк: «Kapitalbank» водитель ищет, «ОПЕРУ GRG» — нет.
        "name": bank or legal_name(title),
        "operator": bank,
        "description": title if title and title != bank else "",
        "address": clean_spaces(text_of(columns.get("Joylashuvi"))),
        "region": clean_spaces(text_of(columns.get("Viloyat"))),
        "district": clean_spaces(text_of(columns.get("Tumanshahar"))),
        "payment": clean_spaces(text_of(columns.get("Tolovtizimi"))),
        "phone": clean_spaces(text_of(columns.get("Bankomatningtexniktaminlanishtelefonraqami"))),
        "egov_id": row_id(row),
    }


def parse_hotel(row):
    """Строка реестра гостиниц → запись или None (без координат)."""
    columns = row.get("tableColumn") or {}
    spot = coordinates(columns)
    if spot is None:
        return None
    return {
        "lat": spot[0], "lon": spot[1],
        "name": legal_name(text_of(columns.get("Yuridikshaxsnomi"))),
        "address": clean_spaces(text_of(columns.get("Manzil"))),
        "region": clean_spaces(text_of(columns.get("Viloyat"))),
        "certificate_until": clean_spaces(text_of(columns.get("Sertifikatamalqilishmuddati"))),
        "egov_id": row_id(row),
    }


PARSERS = {"atm": parse_atm, "hotel": parse_hotel}


def name_key(name):
    """Ключ сравнения названий: регистр, кавычки и пробелы не считаются."""
    return re.sub(r"[^\w]+", "", (name or "").lower())


def dedup(records, meters=DUPLICATE_METERS):
    """Одно название ближе `meters` — одна запись; остаётся первая.

    Порядок — как в реестре, чтобы прогон был воспроизводим. Разные названия
    рядом НЕ схлопываются: в одном торговом центре стоят банкоматы пяти банков.
    """
    kept, by_name = [], {}
    for record in records:
        key = name_key(record.get("name"))
        near = by_name.setdefault(key, [])
        if any(distance(record["lat"], record["lon"], lat, lon) < meters for lat, lon in near):
            continue
        near.append((record["lat"], record["lon"]))
        kept.append(record)
    return kept


# --- GeoJSON ---------------------------------------------------------------

def feature(kind, record):
    """Запись → Feature с осмовскими тегами, которые понимает collect_venues."""
    if kind == "atm":
        properties = {"amenity": "atm", "name": record["name"]}
        if record.get("operator"):
            properties["operator"] = record["operator"]
        if record.get("description"):
            properties["description"] = record["description"]
        if record.get("payment"):
            properties["payment"] = record["payment"]
        if record.get("phone"):
            properties["phone"] = record["phone"]
    else:
        properties = {"tourism": "hotel", "name": record["name"]}
        if record.get("certificate_until"):
            properties["certificate:until"] = record["certificate_until"]
    for key, tag in (("address", "addr:full"), ("region", "addr:region"),
                     ("district", "addr:district")):
        if record.get(key):
            properties[tag] = record[key]
    properties["source"] = "data.egov.uz " + DATASETS[kind]["code"]
    properties["egov:id"] = record.get("egov_id", "")
    return {"type": "Feature",
            "geometry": {"type": "Point", "coordinates": [record["lon"], record["lat"]]},
            "properties": properties}


def attribution(kind, count, fetched_at):
    """Первая строка файла. Не Feature: у неё нет properties, и сборка её
    молча пропускает, а человек, открывший файл, видит, откуда данные."""
    dataset = DATASETS[kind]
    return {"type": "Attribution", "license": LICENSE, "license_url": LICENSE_URL,
            "source": dataset["url"], "dataset": f'{dataset["code"]} {dataset["title"]}',
            "attribution": "Данные портала открытых данных Республики Узбекистан "
                           "(data.egov.uz), " + LICENSE,
            "count": count, "fetched": fetched_at}


def write_geojsonl(path, kind, records, fetched_at):
    """Атомарно: файл читает сборка дорог, и половина файла хуже старого."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write("\x1e" + json.dumps(attribution(kind, len(records), fetched_at),
                                         ensure_ascii=False) + "\n")
        for record in records:
            handle.write("\x1e" + json.dumps(feature(kind, record), ensure_ascii=False,
                                             separators=(",", ":")) + "\n")
    os.replace(tmp, path)


def build(kind, rows):
    """Строки портала → проверенные, без дублей записи. Чистая часть прогона."""
    parse = PARSERS[kind]
    parsed = [record for record in (parse(row) for row in rows) if record]
    return dedup(parsed)


# --- сеть ------------------------------------------------------------------

def fetch_page(guid, offset, limit, timeout=TIMEOUT):
    body = json.dumps({"guidId": guid, "fields": {}, "limit": limit,
                       "offset": offset}).encode()
    request = urllib.request.Request(API.format(guid=guid), data=body,
                                     headers={"Content-Type": "application/json",
                                              "User-Agent": "RadarMap import_poi_egov"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    result = payload.get("result") or {}
    return result.get("data") or [], int(result.get("count") or 0)


def fetch_all(guid, page=PAGE, retries=RETRIES, fetch=fetch_page, sleep=time.sleep):
    """Все строки набора постранично. Страница повторяется `retries` раз с
    растущей паузой; после этого — ошибка, а не половина набора молча."""
    rows, offset, total = [], 0, None
    while total is None or offset < total:
        for attempt in range(retries):
            try:
                chunk, total = fetch(guid, offset, page)
                break
            except (urllib.error.URLError, OSError, ValueError) as error:
                if attempt + 1 == retries:
                    raise RuntimeError(f"страница {offset} набора {guid}: {error}") from error
                sleep(2 ** attempt)
        if not chunk:
            break
        rows.extend(chunk)
        offset += len(chunk)
        if len(chunk) < page:
            break
    if total and len(rows) < total * 0.9:
        raise RuntimeError(f"набор {guid}: получено {len(rows)} строк из {total}")
    return rows


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Банкоматы и гостиницы с data.egov.uz")
    ap.add_argument("--out-dir", default=os.path.join(here, "poi"),
                    help="куда писать egov_atm.geojsonl и egov_hotel.geojsonl")
    ap.add_argument("--page", type=int, default=PAGE, help="строк на страницу API")
    ap.add_argument("--only", choices=sorted(DATASETS), default=None,
                    help="только один набор")
    args = ap.parse_args()

    fetched_at = time.strftime("%Y-%m-%d", time.gmtime())
    failed = 0
    for kind in sorted(DATASETS):
        if args.only and kind != args.only:
            continue
        dataset = DATASETS[kind]
        try:
            rows = fetch_all(dataset["guid"], page=args.page)
        except RuntimeError as error:
            print(f"{kind}: {error}", file=sys.stderr)
            failed += 1
            continue
        records = build(kind, rows)
        if len(records) < len(rows) * 0.5:
            # Половина строк без координат — это не данные, а поломка выгрузки.
            print(f"{kind}: из {len(rows)} строк годных {len(records)} — не пишу",
                  file=sys.stderr)
            failed += 1
            continue
        path = os.path.join(args.out_dir, f"egov_{kind}.geojsonl")
        write_geojsonl(path, kind, records, fetched_at)
        print(f"{kind}: строк {len(rows)}, записей {len(records)} → {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
