#!/usr/bin/env python3
"""build_aliases.py — старые имена Ташкента для поиска: метро, районы, массивы.

«Метро Хамза» должно находить «Новза». Старые имена улиц и большей части мест
поиск берёт из OSM сам (`old_name` на дорогах и местах, search_names.py); этот
файл добавляет то, чего в OSM нет или что там без даты: официальные прежние
названия станций метро с датами переименования (Википедия), их узбекские
формы (OSM `name:uz`, Wikidata), прежние названия районов и жилых массивов.

Источники и лицензии:
* русская Википедия — «Список станций Ташкентского метрополитена», статьи
  районов Ташкента — CC BY-SA 4.0 (факт «как станция называлась раньше и до
  какой даты»; текст статей не переносится);
* Wikidata — координаты и узбекские подписи станций — CC0;
* OpenStreetMap (локальная выгрузка) — osm id, координаты, `name:uz` — ODbL.

Проектные названия станций («Кипчак (проектное)» у нынешнего «Чинора») не
берутся: под ними станция никогда не работала, а «Кипчак» — сегодня другая
станция, и такой псевдоним увёл бы водителя не туда.

Шаги (сеть нужна только первому; разбор — на скачанных файлах):
    python3 build_aliases.py fetch --raw RAW         # Википедия + Wikidata → RAW/
    python3 build_aliases.py osm --pbf X.osm.pbf --raw RAW   # нужен pyosmium
    python3 -I build_aliases.py build --raw RAW      # → poi/aliases_tashkent.tsv,
                                                     #   poi/metro_tashkent.tsv
Тесты: python3 test_build_aliases.py
"""
import argparse
import csv
import datetime
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
USER_AGENT = "RadarMap-data-scout/1.0"
TIMEOUT = 60

RUWIKI_API = "https://ru.wikipedia.org/w/api.php"
WIKIDATA_API = "https://www.wikidata.org/w/api.php"
METRO_PAGE = "Список станций Ташкентского метрополитена"
DISTRICT_PAGES = ("Алмазарский", "Бектемирский", "Мирабадский", "Мирзо-Улугбекский",
                  "Сергелийский", "Учтепинский", "Чиланзарский", "Шайхантахурский",
                  "Юнусабадский", "Яккасарайский", "Яшнабадский", "Янгихаётский")
TASHKENT_BOX = (41.12, 41.47, 69.07, 69.52)

ALIAS_COLUMNS = ("kind", "name_now", "name_old", "lang", "osm_id", "lat", "lon",
                 "source", "source_date", "renamed", "city", "wikidata")
METRO_COLUMNS = ("line", "name_ru", "name_uz", "name_uz_cyrl", "name_uz_osm", "opened", "osm_id",
                 "wikidata", "lat", "lon", "former_ru")

#: Узбекские формы прежних названий районов (советские «… tumani»). Нужны
#: потому, что «Hamza tumani» по ключу поиска не сходится с «Хамзинский район».
DISTRICT_OLD_UZ = {
    "Хамзинский район": "Hamza tumani",
    "Сабир-Рахимовский район": "Sobir Rahimov tumani",
    "Акмал-Икрамовский район": "Akmal Ikromov tumani",
    "Куйбышевский район": "Kuybishev tumani",
    "Ленинский район": "Lenin tumani",
    "Октябрьский район": "Oktyabr tumani",
    "Фрунзенский район": "Frunze tumani",
    "Кировский район": "Kirov tumani",
}

MONTHS = {"января": 1, "февраля": 2, "марта": 3, "апреля": 4, "мая": 5, "июня": 6,
          "июля": 7, "августа": 8, "сентября": 9, "октября": 10, "ноября": 11,
          "декабря": 12}
APOSTROPHES = "'‘’ʻʼ`´"
CYR_TO_LAT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "j",
    "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
    "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts",
    "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "yu",
    "я": "ya", "ў": "u", "қ": "k", "ғ": "g", "ҳ": "h",
}
LAT_TO_CYR = {"a": "а", "b": "б", "d": "д", "e": "е", "f": "ф", "g": "г", "h": "ҳ",
              "i": "и", "j": "ж", "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
              "p": "п", "q": "қ", "r": "р", "s": "с", "t": "т", "u": "у", "v": "в",
              "x": "х", "y": "й", "z": "з", "c": "ц", "w": "в"}
VOWELS = set("aeiou")


# --- Имена ------------------------------------------------------------------

def fold(text):
    """К сравнимому виду: кириллица → латиница, q=k, x=h, без апострофов."""
    out = []
    for char in (text or "").lower():
        if char in APOSTROPHES:
            continue
        out.append(CYR_TO_LAT.get(char, char))
    text = "".join(out).replace("q", "k").replace("x", "h")
    return " ".join(re.sub(r"[^a-z0-9 ]+", " ", text).split())


def skeleton(text):
    """Согласные без повторов: «Чкаловская» и «Chkalov» — один корень,
    «Хамза» и «Hamza» — одно слово, гласные и окончания не решают."""
    letters = re.sub(r"[aeiouy ]", "", fold(text))
    return re.sub(r"(.)\1+", r"\1", letters)


def same_root(a, b, length=3):
    sa, sb = skeleton(a), skeleton(b)
    return bool(sa) and bool(sb) and sa[:length] == sb[:length]


def uz_official(text):
    """Узбекская латиница с официальным знаком «ʻ» (U+02BB) после o и g."""
    text = re.sub(r"([oOgG])[" + APOSTROPHES + "]", lambda m: m.group(1) + "ʻ", text.strip())
    return " ".join(text.split())


def uz_cyrillic(text):
    """Узбекская латиница → кириллица по правилам алфавита 1995 г."""
    text = uz_official(text)
    out = []
    i = 0
    word_start = True
    while i < len(text):
        char = text[i]
        low = char.lower()
        nxt = text[i + 1].lower() if i + 1 < len(text) else ""
        after = text[i + 2] if i + 2 < len(text) else ""
        piece, step = None, 1
        if low in "og" and nxt == "ʻ":
            piece, step = ("ў" if low == "o" else "ғ"), 2
        elif low == "s" and nxt == "h":
            piece, step = "ш", 2
        elif low == "c" and nxt == "h":
            piece, step = "ч", 2
        elif low == "y" and nxt in "oaue" and nxt:
            if nxt == "o" and after == "ʻ":
                piece = "й"
            else:
                piece, step = {"o": "ё", "a": "я", "u": "ю", "e": "е"}[nxt], 2
        elif low == "e":
            piece = "э" if word_start else "е"
        elif char in APOSTROPHES or char == "ʻ":
            piece = "ъ"
        elif low in LAT_TO_CYR:
            piece = LAT_TO_CYR[low]
        else:
            piece = char
        if char.isupper() and piece:
            piece = piece[0].upper() + piece[1:]
        out.append(piece)
        word_start = not char.isalpha() and char not in APOSTROPHES
        i += step
    return "".join(out)


def iso_date(text):
    """«16 июня 2015» → «2015-06-16»; иначе пусто."""
    match = re.search(r"(\d{1,2})\s+([а-я]+)\s+(\d{4})", text or "")
    if not match or match.group(2) not in MONTHS:
        return ""
    return f"{int(match.group(3)):04d}-{MONTHS[match.group(2)]:02d}-{int(match.group(1)):02d}"


# --- Вики-разметка ----------------------------------------------------------

def clean_wiki(text):
    text = re.sub(r"<ref[^>]*/>", "", text)
    text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.S)
    text = re.sub(r"\[\[(?:File|Файл|Изображение):[^\]]*\]\]", "", text)
    text = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"\[\[([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"<br\s*/?>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text.replace("'''", "").replace("''", "").replace(" ", " ")


def wiki_tables(wikitext):
    """[(заголовок раздела, [строки ячеек])] — с учётом rowspan. Пустые строки
    таблицы (двойной `|-`) MediaWiki выбрасывает и rowspan их не считает."""
    tables = []
    section = ""
    lines = wikitext.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        heading = re.match(r"^==\s*(.*?)\s*==\s*$", line)
        if heading:
            section = heading.group(1)
        if line.startswith("{|"):
            rows, current, pending = [], None, {}
            i += 1
            while i < len(lines) and not lines[i].startswith("|}"):
                cell_line = lines[i]
                if cell_line.startswith("|-"):
                    if current:
                        rows.append(current)
                    current = []
                elif cell_line.startswith("|") and not cell_line.startswith("|+") and current is not None:
                    current.append(cell_line[1:])
                elif current:
                    current[-1] += "\n" + cell_line
                i += 1
            if current:
                rows.append(current)
            tables.append((section, _span_rows(rows)))
        i += 1
    return tables


def _span_rows(rows):
    out, pending = [], {}
    for raw in rows:
        if any("width=" in cell or "colspan=" in cell for cell in raw):
            continue
        cells, column, queue = {}, 0, list(raw)
        while queue or column in pending:
            if column in pending:
                value, left = pending[column]
                cells[column] = value
                if left <= 1:
                    del pending[column]
                else:
                    pending[column] = (value, left - 1)
                column += 1
                continue
            cell = queue.pop(0)
            span = re.match(r'^\s*rowspan="?(\d+)"?\s*\|(.*)$', cell, re.S)
            value = span.group(2) if span else cell
            value = value.strip()
            if span and int(span.group(1)) > 1:
                pending[column] = (value, int(span.group(1)) - 1)
            cells[column] = value
            column += 1
        out.append([cells.get(index, "") for index in range(max(cells) + 1 if cells else 0)])
    return out


def former_names(cell):
    """Ячейка «Прежние названия» → [{name, variants, until, since, project}]."""
    text = clean_wiki(cell).strip()
    if not text or text.lower() in ("нет", "—", "-"):
        return []
    segments, depth, buffer = [], 0, ""
    for char in text:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            segments.append(buffer)
            buffer = ""
        else:
            buffer += char
    segments.append(buffer)
    out = []
    for segment in segments:
        parens = re.findall(r"\(([^()]*)\)", segment)
        name = " ".join(re.sub(r"\([^()]*\)", " ", segment).split())
        if not name:
            continue
        item = {"name": name, "variants": [], "until": "", "since": "", "project": False}
        for inside in parens:
            inside = " ".join(inside.split())
            if "проектн" in inside:
                item["project"] = True
            elif re.search(r"\b(до|с|по)\s+\d", inside):
                spans = re.match(r"с\s+(.+?)\s+по\s+(.+)$", inside)
                if spans:
                    item["since"], item["until"] = iso_date(spans.group(1)), iso_date(spans.group(2))
                else:
                    item["until"] = iso_date(inside)
            elif same_root(inside, name):
                # «Чкалов (Чкаловская)» — та же форма имени; «Бунёдкор (Творец)» —
                # перевод, им станцию никто не называл.
                item["variants"].append(inside)
        out.append(item)
    return out


def parse_metro_list(wikitext):
    """Википедия → [{line, ru, ru_title, uz, opened, former}] только для
    действующих станций."""
    stations = []
    for section, rows in wiki_tables(wikitext):
        for cells in rows:
            if len(cells) < 5:
                continue
            title = re.match(r"\s*\[\[([^\]|]+)", cells[0])
            ru = clean_wiki(cells[0]).strip()
            opened = clean_wiki(cells[3]).strip()
            if not ru or not title or "проектир" in opened or not re.search(r"\d{4}", opened):
                continue
            stations.append({
                "line": section, "ru": ru, "ru_title": title.group(1).strip(),
                "translation": clean_wiki(cells[1]).split("\n")[0].strip(),
                "uz": uz_official(clean_wiki(cells[2]).strip()),
                "opened": iso_date(opened.replace("года", "")),
                "former": former_names(cells[4]),
            })
    return stations


def parse_district(wikitext, title):
    """Статья района → (прежние имена [(имя, дата)], массивы [(ныне, прежде)])."""
    olds = []
    infobox = re.search(r"\|\s*прежние имена\s*=\s*([^\n|]*)", wikitext)
    plain = clean_wiki(wikitext)
    dated = {}
    for sentence in re.split(r"(?<=[.;])\s", plain):
        if "переименован" not in sentence:
            continue
        date = iso_date(sentence)
        named = re.search(r"([А-ЯЁ][\w-]+ский) район был переименован", sentence)
        if named:
            dated[named.group(1) + " район"] = date
        elif date:
            dated.setdefault("", date)
    if infobox:
        for name in infobox.group(1).split(","):
            name = clean_wiki(name).strip()
            if name and name.endswith("район") and not name.startswith("город"):
                olds.append((name, dated.get(name) or dated.get("", "")))
    for name, date in dated.items():
        if name and name not in [old for old, _ in olds]:
            olds.append((name, date))
    massifs = []
    for match in re.finditer(r"''([^'\n]{2,60})''\s*\(бывш\w*\s*''([^'\n]{1,60})''\)"
                             r"|''([^'\n]{2,60}?)\s*\(''бывш\w*''\s*([^)\n]{1,60})\)''", wikitext):
        now, old = (match.group(1), match.group(2)) if match.group(1) else (match.group(3), match.group(4))
        massifs.append((now.strip(), old.strip()))
    return olds, massifs


# --- Wikidata и OSM ---------------------------------------------------------

def parse_wikidata(payload):
    """Wikidata → {заголовок ruwiki: {qid, lat, lon, uz_names}}. Понимает ответ
    `wbgetentities` (основной путь) и ответ SPARQL (запасной: сервис запросов
    в часы перегрузки отдаёт 429 чаще раза в минуту)."""
    out = {}
    for qid, entity in (payload.get("entities") or {}).items():
        title = ((entity.get("sitelinks") or {}).get("ruwiki") or {}).get("title")
        if not title:
            continue
        lat = lon = None
        for claim in (entity.get("claims") or {}).get("P625", []):
            value = ((claim.get("mainsnak") or {}).get("datavalue") or {}).get("value") or {}
            if "latitude" in value:
                lat, lon = value["latitude"], value["longitude"]
                break
        uz = [(entity.get("labels") or {}).get("uz", {}).get("value", "")]
        uz += [alias.get("value", "") for alias in (entity.get("aliases") or {}).get("uz", [])]
        out[title] = {"qid": qid, "lat": lat, "lon": lon,
                      "uz_names": [_strip_station(name) for name in uz if name]}
    # Список ссылается на станции и через перенаправления («Дружба Народов
    # (станция метро)» → «… , Ташкент»): fetch запоминает, куда ведёт каждая.
    by_qid = {item["qid"]: item for item in out.values()}
    for title, qid in (payload.get("titles") or {}).items():
        if title not in out and qid in by_qid:
            out[title] = by_qid[qid]
    for row in payload.get("results", {}).get("bindings", []):
        page = row.get("ruwiki", {}).get("value", "")
        if not page:
            continue
        title = urllib.parse.unquote(page.rsplit("/", 1)[-1]).replace("_", " ")
        lat = lon = None
        point = re.match(r"Point\(([-\d.]+) ([-\d.]+)\)", row.get("coord", {}).get("value", ""))
        if point:
            lon, lat = float(point.group(1)), float(point.group(2))
        uz = []
        for field in ("labels", "aliases"):
            for part in row.get(field, {}).get("value", "").split("|"):
                lang, _, value = part.partition(":")
                if lang == "uz" and value:
                    uz.append(_strip_station(value))
        out[title] = {"qid": row["s"]["value"].rsplit("/", 1)[-1], "lat": lat, "lon": lon,
                      "uz_names": uz}
    return out


def _strip_station(name):
    return re.sub(r"\s*\((metro bekati|Tashkent Metro|станция метро[^)]*)\)\s*$", "", name).strip()


def read_jsonl(path):
    rows = []
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def osm_uz_variants(tags):
    """Узбекские латинские имена OSM: `old_name:uz` и скобка в `name:uz`
    («Novza (Hamza)»)."""
    out = [value for value in (tags.get("old_name:uz") or "").split(";") if value.strip()]
    for key in ("name:uz", "name:uz-Latn"):
        inside = re.search(r"\(([^()]+)\)", tags.get(key) or "")
        if inside:
            out.append(inside.group(1))
    return [value.strip() for value in out]


def in_tashkent(lat, lon):
    south, north, west, east = TASHKENT_BOX
    return lat is not None and lon is not None and south < lat < north and west < lon < east


def nearest(rows, lat, lon):
    best, best_d = None, None
    for row in rows:
        d = (row["lat"] - lat) ** 2 + ((row["lon"] - lon) * 0.75) ** 2
        if best_d is None or d < best_d:
            best, best_d = row, d
    return best, (best_d ** 0.5 * 111_320 if best_d is not None else None)


# --- Сборка -----------------------------------------------------------------

def metro_rows(stations, wikidata, osm_stations, source, snapshot):
    """→ (строки псевдонимов, строки таблицы метро, [предупреждения])."""
    aliases, table, warnings = [], [], []
    by_qid = {}
    for row in osm_stations:
        qid = row["tags"].get("wikidata")
        if qid and qid not in by_qid:
            by_qid[qid] = row
    for station in stations:
        wd = wikidata.get(station["ru_title"], {})
        osm = by_qid.get(wd.get("qid"))
        if osm is None and osm_stations:
            candidates = [row for row in osm_stations
                          if same_root(row["tags"].get("name", ""), station["uz"], 4)
                          or same_root(row["tags"].get("name:ru", ""), station["ru"], 4)]
            if wd.get("lat") is not None and candidates:
                osm, distance = nearest(candidates, wd["lat"], wd["lon"])
                if distance > 1500:
                    osm = None
            elif len(candidates) == 1:
                osm = candidates[0]
        if osm is None:
            warnings.append(f"метро без OSM: {station['ru']}")
        lat = osm["lat"] if osm else wd.get("lat")
        lon = osm["lon"] if osm else wd.get("lon")
        osm_id = osm["osm"] if osm else ""
        name_now = (osm["tags"].get("name") if osm else "") or station["uz"]
        official = [item for item in station["former"] if not item["project"]]
        currents = (station["ru"], station["uz"], station["translation"], name_now)
        uz_pool = list(wd.get("uz_names", [])) + (osm_uz_variants(osm["tags"]) if osm else [])
        former_ru = []
        for item in official:
            names = [item["name"]] + item["variants"]
            if any(skeleton(name) == skeleton(current) for name in names[:1] for current in currents):
                continue
            former_ru.append(item["name"] + (f" (до {item['until']})" if item["until"] else ""))
            seen = set()
            entries = [(name, "ru") for name in names]
            for uz in uz_pool:
                if any(same_root(uz, name, 3) and fold(uz).split()[0][:3] == fold(name).split()[0][:3]
                       for name in names):
                    entries.append((uz_official(uz), "uz"))
                    # Кириллица из узбекской латиницы нужна, только если она не
                    # повторяет русское имя: «Ҳамза» ищется так же, как «Хамза».
                    cyrillic = uz_cyrillic(uz)
                    if all(skeleton(cyrillic) != skeleton(name) for name in names):
                        entries.append((cyrillic, "uz-Cyrl"))
            for name, lang in entries:
                key = (fold(name), lang)
                if key in seen:
                    continue
                seen.add(key)
                aliases.append({"kind": "metro", "name_now": name_now, "name_old": name, "lang": lang,
                                "osm_id": osm_id, "lat": lat, "lon": lon, "source": source,
                                "source_date": snapshot, "renamed": item["until"], "city": "Ташкент",
                                "wikidata": wd.get("qid", "")})
        table.append({"line": station["line"], "name_ru": station["ru"], "name_uz": station["uz"],
                      "name_uz_cyrl": uz_cyrillic(station["uz"]), "name_uz_osm": name_now if osm else "",
                      "opened": station["opened"],
                      "osm_id": osm_id, "wikidata": wd.get("qid", ""), "lat": lat, "lon": lon,
                      "former_ru": "; ".join(former_ru)})
    return aliases, table, warnings


def place_rows(districts, osm_places, snapshot):
    """Районы и массивы → строки псевдонимов, привязанные к месту OSM."""
    aliases, warnings = [], []
    district_nodes = [row for row in osm_places if row["tags"].get("place") == "district"]
    small = [row for row in osm_places if row["tags"].get("place") in
             ("suburb", "quarter", "neighbourhood") or row["tags"].get("landuse") == "residential"]
    for title, revid, olds, massifs in districts:
        stem = title.split()[0]
        node = next((row for row in district_nodes
                     if same_root(row["tags"].get("name:ru", ""), stem, 5)), None)
        source = f"ruwiki:{title}@{revid}"
        for old, date in olds:
            if node is None:
                warnings.append(f"район без OSM: {title} ← {old}")
                continue
            names = [(old, "ru")]
            if old in DISTRICT_OLD_UZ:
                names += [(DISTRICT_OLD_UZ[old], "uz"), (uz_cyrillic(DISTRICT_OLD_UZ[old]), "uz-Cyrl")]
            for name, lang in names:
                aliases.append({"kind": "district", "name_now": node["tags"]["name"], "name_old": name,
                                "lang": lang, "osm_id": node["osm"], "lat": node["lat"],
                                "lon": node["lon"], "source": source, "source_date": snapshot,
                                "renamed": date, "city": "Ташкент", "wikidata": ""})
        for now, old in massifs:
            matches = [row for row in small if fold(now) in
                       {fold(re.sub(r"\s*\(.*\)", "", row["tags"].get(key, "")))
                        for key in ("name", "name:ru", "name:uz")}]
            if node is not None and matches:
                place, _ = nearest(matches, node["lat"], node["lon"])
            elif len(matches) == 1:
                place = matches[0]
            else:
                warnings.append(f"массив без OSM: {now} ← {old} ({len(matches)} кандидатов)")
                continue
            aliases.append({"kind": "neighbourhood", "name_now": place["tags"]["name"], "name_old": old,
                            "lang": "ru", "osm_id": place["osm"], "lat": place["lat"], "lon": place["lon"],
                            "source": source, "source_date": snapshot, "renamed": "",
                            "city": "Ташкент", "wikidata": ""})
    return aliases, warnings


def validate(aliases, table, min_stations=45):
    """Форма и разумность: станций не меньше, чем в метро на 2024 год, у
    каждой — координата в Ташкенте; псевдоним не равен нынешнему имени."""
    problems = []
    if len(table) < min_stations:
        problems.append(f"станций {len(table)} < {min_stations}")
    for row in table:
        if not in_tashkent(row["lat"], row["lon"]):
            problems.append(f"станция вне Ташкента: {row['name_ru']}")
    for row in aliases:
        if fold(row["name_old"]) == fold(row["name_now"]):
            problems.append(f"псевдоним равен имени: {row['name_now']}")
        if not in_tashkent(row["lat"], row["lon"]):
            problems.append(f"псевдоним вне Ташкента: {row['name_now']} ← {row['name_old']}")
    return problems


def write_tsv(path, columns, rows, header_lines):
    with open(path + ".tmp", "w", encoding="utf-8", newline="") as handle:
        for line in header_lines:
            handle.write("# " + line + "\n")
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(columns)
        for row in rows:
            writer.writerow(["" if row.get(c) is None else
                             (f"{row[c]:.6f}" if isinstance(row.get(c), float) else row[c])
                             for c in columns])
    os.replace(path + ".tmp", path)


def build(raw, out_dir, snapshot=None, min_stations=45):
    snapshot = snapshot or datetime.date.today().isoformat()
    with open(os.path.join(raw, "ruwiki_metro.json"), encoding="utf-8") as handle:
        page = json.load(handle)["parse"]
    with open(os.path.join(raw, "wikidata_metro.json"), encoding="utf-8") as handle:
        wikidata = parse_wikidata(json.load(handle))
    stations = parse_metro_list(page["wikitext"]["*"])
    osm_stations = read_jsonl(os.path.join(raw, "osm_metro.jsonl"))
    source = f"ruwiki:{page['title']}@{page['revid']}; wikidata; osm"
    aliases, table, warnings = metro_rows(stations, wikidata, osm_stations, source, snapshot)
    districts = []
    for stem in DISTRICT_PAGES:
        path = os.path.join(raw, f"ruwiki_district_{stem}.json")
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            parsed = json.load(handle).get("parse")
        if parsed:
            olds, massifs = parse_district(parsed["wikitext"]["*"], parsed["title"])
            districts.append((parsed["title"], parsed["revid"], olds, massifs))
    more, more_warnings = place_rows(districts, read_jsonl(os.path.join(raw, "osm_places.jsonl")), snapshot)
    aliases += more
    warnings += more_warnings
    problems = validate(aliases, table, min_stations)
    if problems:
        raise SystemExit("набор не прошёл проверку:\n  " + "\n  ".join(problems))
    attribution = ("Старые имена Ташкента: русская Википедия (CC BY-SA 4.0), Wikidata (CC0), "
                   "© участники OpenStreetMap (ODbL 1.0). Собрано build_aliases.py " + snapshot)
    os.makedirs(out_dir, exist_ok=True)
    write_tsv(os.path.join(out_dir, "aliases_tashkent.tsv"), ALIAS_COLUMNS, aliases,
              [attribution, "renamed — дата, до которой действовало старое имя (если известна)"])
    write_tsv(os.path.join(out_dir, "metro_tashkent.tsv"), METRO_COLUMNS, table,
              [attribution, "name_uz_cyrl — транслитерация name_uz по алфавиту 1995 г."])
    return aliases, table, warnings


# --- Сеть и OSM -------------------------------------------------------------

def http_get(url, params, accept="application/json"):
    request = urllib.request.Request(url + "?" + urllib.parse.urlencode(params),
                                     headers={"User-Agent": USER_AGENT, "Accept": accept})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                return response.read()
        except OSError as error:
            if attempt == 2:
                raise
            # Wikidata при перегрузке просит не чаще раза в минуту — ждём, не долбим.
            time.sleep(65 if getattr(error, "code", None) == 429 else 5 * (attempt + 1))


def fetch(raw):
    os.makedirs(raw, exist_ok=True)

    def page(title, name):
        body = http_get(RUWIKI_API, {"action": "parse", "page": title, "prop": "wikitext|revid",
                                     "format": "json", "redirects": "1"})
        with open(os.path.join(raw, name), "wb") as handle:
            handle.write(body)
        time.sleep(1)

    page(METRO_PAGE, "ruwiki_metro.json")
    for stem in DISTRICT_PAGES:
        page(f"{stem} район", f"ruwiki_district_{stem}.json")
    with open(os.path.join(raw, "ruwiki_metro.json"), encoding="utf-8") as handle:
        wikitext = json.load(handle)["parse"]["wikitext"]["*"]
    titles = sorted({station["ru_title"] for station in parse_metro_list(wikitext)})
    qids, title_qids = [], {}
    for start in range(0, len(titles), 50):
        body = http_get(RUWIKI_API, {"action": "query", "prop": "pageprops", "ppprop": "wikibase_item",
                                     "redirects": "1", "format": "json",
                                     "titles": "|".join(titles[start:start + 50])})
        query = json.loads(body).get("query", {})
        final = {p["title"]: p["pageprops"]["wikibase_item"]
                 for p in query.get("pages", {}).values() if "pageprops" in p}
        hops = {step["from"]: step["to"] for step in query.get("normalized", []) + query.get("redirects", [])}
        for title in titles[start:start + 50]:
            target = title
            while target in hops and target not in final:
                target = hops[target]
            if target in final:
                title_qids[title] = final[target]
        qids += list(final.values())
        time.sleep(1)
    entities = {}
    for start in range(0, len(qids), 50):
        body = http_get(WIKIDATA_API, {"action": "wbgetentities", "ids": "|".join(qids[start:start + 50]),
                                       "props": "labels|aliases|claims|sitelinks",
                                       "languages": "ru|uz|en", "sitefilter": "ruwiki",
                                       "format": "json"})
        entities.update(json.loads(body).get("entities", {}))
        time.sleep(1)
    with open(os.path.join(raw, "wikidata_metro.json"), "w", encoding="utf-8") as handle:
        json.dump({"entities": entities, "titles": title_qids}, handle, ensure_ascii=False)


def extract_osm(pbf, raw):
    """Станции метро и места Ташкента из выгрузки OSM (нужен pyosmium)."""
    import osmium

    south, north, west, east = TASHKENT_BOX
    metro = open(os.path.join(raw, "osm_metro.jsonl"), "w", encoding="utf-8")
    places = open(os.path.join(raw, "osm_places.jsonl"), "w", encoding="utf-8")

    def emit(handle, kind, oid, tags, lat, lon):
        if south < lat < north and west < lon < east:
            handle.write(json.dumps({"osm": f"{kind}/{oid}", "lat": round(lat, 6),
                                     "lon": round(lon, 6), "tags": tags}, ensure_ascii=False) + "\n")

    def is_metro(tags):
        return ((tags.get("station") == "subway" or tags.get("subway") == "yes")
                and (tags.get("railway") == "station" or tags.get("public_transport") == "station"))

    def is_place(tags):
        return "name" in tags and ("place" in tags or tags.get("landuse") == "residential")

    class Handler(osmium.SimpleHandler):
        def node(self, node):
            tags = {k: v for k, v in node.tags}
            if is_metro(tags):
                emit(metro, "node", node.id, tags, node.location.lat, node.location.lon)
            elif "place" in tags and "name" in tags:
                emit(places, "node", node.id, tags, node.location.lat, node.location.lon)

        def way(self, way):
            tags = {k: v for k, v in way.tags}
            if not (is_metro(tags) or is_place(tags)):
                return
            locations = [n.location for n in way.nodes if n.location.valid()]
            if not locations:
                return
            lat = sum(p.lat for p in locations) / len(locations)
            lon = sum(p.lon for p in locations) / len(locations)
            emit(metro if is_metro(tags) else places, "way", way.id, tags, lat, lon)

    Handler().apply_file(pbf, locations=True)
    metro.close()
    places.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    fetch_cmd = sub.add_parser("fetch")
    fetch_cmd.add_argument("--raw", required=True)
    osm_cmd = sub.add_parser("osm")
    osm_cmd.add_argument("--pbf", required=True)
    osm_cmd.add_argument("--raw", required=True)
    build_cmd = sub.add_parser("build")
    build_cmd.add_argument("--raw", required=True)
    build_cmd.add_argument("--out-dir", default=os.path.join(HERE, "poi"))
    build_cmd.add_argument("--snapshot", help="дата выгрузки источников (YYYY-MM-DD)")
    args = parser.parse_args(argv)
    if args.command == "fetch":
        fetch(args.raw)
    elif args.command == "osm":
        extract_osm(args.pbf, args.raw)
    else:
        aliases, table, warnings = build(args.raw, args.out_dir, args.snapshot)
        for warning in warnings:
            print("  ! " + warning, file=sys.stderr)
        print(f"станций {len(table)}, старых имён {len(aliases)} "
              f"(метро {sum(r['kind'] == 'metro' for r in aliases)}, "
              f"районы {sum(r['kind'] == 'district' for r in aliases)}, "
              f"массивы {sum(r['kind'] == 'neighbourhood' for r in aliases)})")


if __name__ == "__main__":
    main()
