#!/usr/bin/env python3
"""Все имена места для поиска на телефоне: нынешние, другие языки, старые.

Жалоба, с которой это началось: «метро хамза» не находило ничего, а станция
давно называется «Новза». Город говорит старыми именами годами — таксист,
вывеска, бабушка, — а поиск знал только одно имя из OSM. При этом в OSM уже
лежит почти всё нужное: у станции `old_name=Хамза`, у улиц Ташкента
`name:ru`/`old_name` (замер 02.11: из 14 588 именованных дорог кадра у 13 948
есть `name:ru`, у 6 274 — `old_name`).

Формат клеток — обратно совместимый, новые поля необязательны:

* улица адресного файла: `{"n", "h", "p"}` + `"a"` (другие нынешние имена) и
  `"o"` (старые) — только когда они есть; старый клиент читает `n/h/p` и
  лишних ключей не видит;
* запись заведения: `[код, имя, lat, lon]` + `[другие имена]` и `[старые]`
  пятым и шестым элементом; старый клиент берёт `row[0...3]`.

Имя, совпадающее с основным после приведения (`fold` — то же, что
`AddressBook.fold` в приложении), не пишется: «Novza» при «Новза» телефону
ничего не добавляет, а байты везёт.

Старые имена из других источников (`server/poi/aliases_*.tsv`, колонки
`kind, name_now, name_old, lang, osm_id, lat, lon, source, source_date`)
приклеиваются к записям по нынешнему имени и месту — `apply_aliases`.
"""
import csv
import json
import math
import os
import unicodedata
from collections import Counter, defaultdict

# Вид «метро» и «местность» — контракт с клиентом (Venue.Kind 14 и 15).
VENUE_METRO = 14
VENUE_PLACE = 15

# Нынешние имена: основное, языки поиска и прочие официальные варианты.
# Языки — только те, на которых водитель в Узбекистане набирает запрос.
CURRENT_KEYS = ("name", "name:ru", "name:uz", "name:uz-Cyrl", "name:uz-Latn",
                "name:en", "int_name", "official_name", "short_name", "loc_name")
# Семейства с языковым хвостом (`alt_name:ru`): язык решает письменность.
CURRENT_FAMILIES = ("alt_name", "official_name", "short_name", "loc_name")
OLD_FAMILIES = ("old_name",)

MAX_ALIASES = 6
MAX_OLD = 6
MAX_NAME_CHARS = 60

# Слова типа улицы: при сверке имени из реестра с записью не решают —
# «проспект Амира Темура» и «Amir Temur shoh ko'chasi» одна улица.
STREET_TYPE_WORDS = {
    "ulitsa", "ul", "kuchasi", "kachasi", "kucha", "kacha", "street", "st",
    "praspekt", "pr", "shah", "avenue", "prezd", "praezd", "pereulak", "per",
    "tupik", "shasse", "yuli", "yali", "berk", "atish", "tar",
}

_APOSTROPHES = "'‘’ʻʼ`´ʹ"
_CYRILLIC = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "j", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh",
    "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    "ў": "u", "қ": "k", "ғ": "g", "ҳ": "h", "ә": "a",
}


def fold(text):
    """Имя к сравнимому виду — порт `AddressBook.fold` (uzbekU) с правилами
    `SearchIndex.fold`: «Новза» = «Novza», «Ўзбекистон» = «Oʻzbekiston»."""
    out = []
    previous = None
    # «оʻ» кириллицей с апострофом — так пишут на клавиатуре без «ў».
    for char in (text or "").lower():
        if char in _APOSTROPHES:
            if previous in ("o", "о"):
                out[-1] = "u"
            previous = None
            continue
        out.append(_CYRILLIC.get(char, char))
        previous = char
    word = "".join(out)
    for was, now in (("zh", "j"), ("dj", "j"), ("kh", "h")):
        word = word.replace(was, now)
    loose = []
    for char in word:
        if char == "q":
            loose.append("k")
        elif char == "x":
            loose.append("h")
        elif char == "w":
            loose.append("v")
        elif char == "o":
            loose.append("a")
        elif char.isalnum():
            loose.append(char)
        else:
            loose.append(" ")
    words = "".join(loose).split()
    return " ".join(w[:-1] if len(w) > 3 and w.endswith("iy") else w for w in words)


def core_key(text):
    """Ключ сверки имени без слов типа улицы и без порядка слов."""
    return " ".join(sorted(set(fold(text).split()) - STREET_TYPE_WORDS))


def plain_script(text):
    """Только латиница и кириллица: персидское или китайское имя водитель с
    узбекской клавиатуры не наберёт, а файл оно утяжелит."""
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return False
    for char in letters:
        try:
            name = unicodedata.name(char)
        except ValueError:
            return False
        if "LATIN" not in name and "CYRILLIC" not in name and "MODIFIER" not in name:
            return False
    return True


def split_values(value):
    """`old_name=Хамза;Новза` → два имени."""
    if not isinstance(value, str):
        return []
    return [part.strip() for part in value.split(";") if part.strip()]


def split_parenthetical(text):
    """«Новза (Хамза)» → («Новза», «Хамза»). Так в OSM подписаны станции
    метро: в скобках — прежнее имя. Без скобок — (текст, None)."""
    text = text.strip()
    if text.endswith(")") and "(" in text:
        base, _, inside = text[:-1].rpartition("(")
        base, inside = base.strip(), inside.strip()
        if base and inside:
            return base, inside
    return text, None


def _keys_of(properties, families, exact=()):
    keys = [k for k in exact if k in properties]
    keys += sorted(k for k in properties
                   if k not in keys and any(k == f or k.startswith(f + ":") for f in families))
    return keys


def names_from(properties, display, parenthetical=False):
    """Теги объекта → (другие нынешние имена, старые имена), без повторов
    основного имени `display` и друг друга (по `fold`)."""
    current, old = [], []
    for key in _keys_of(properties, CURRENT_FAMILIES, CURRENT_KEYS):
        for value in split_values(properties.get(key)):
            if parenthetical:
                value, inside = split_parenthetical(value)
                if inside:
                    old.append(inside)
            current.append(value)
    for key in _keys_of(properties, OLD_FAMILIES, ("old_name",)):
        old.extend(split_values(properties.get(key)))
    return dedup(current, old, display)


def dedup(current, old, display):
    """Отсеять повторы: нынешнее имя, совпавшее со старым, остаётся нынешним
    («Хамза;Новза» в old_name у самой Новзы — ошибка разметки, а не история)."""
    seen = {fold(display)}
    alts, olds = [], []
    for text in current:
        key = fold(text)
        if key and key not in seen and plain_script(text) and len(text) <= MAX_NAME_CHARS:
            seen.add(key)
            alts.append(text)
    for text in old:
        key = fold(text)
        if key and key not in seen and plain_script(text) and len(text) <= MAX_NAME_CHARS:
            seen.add(key)
            olds.append(text)
    return alts[:MAX_ALIASES], olds[:MAX_OLD]


def metro_display(properties):
    """Имя станции для показа: по-русски без скобок «(Хамза)»."""
    raw = (properties.get("name:ru") or properties.get("name") or "").strip()
    return split_parenthetical(raw)[0]


def is_metro(properties):
    if properties.get("railway") == "subway_entrance":
        return False
    return properties.get("station") == "subway" or (
        properties.get("railway") == "station" and properties.get("subway") == "yes")


# district — районы города (туманы): в OSM у Ташкента это узлы со всеми
# именами («Алмазарский район», «Olmazor tumani», old_name). На карту они не
# идут (build_roads.PLACE_RANKS их не знает) — только в поиск.
PLACE_KINDS = {"city", "town", "village", "hamlet", "suburb", "neighbourhood", "district"}


def is_place(properties):
    return properties.get("place") in PLACE_KINDS


# --- Имена улиц из дорог ----------------------------------------------------

def _cell(lat, lon, degrees):
    return f"{int(math.floor((lat + 90) / degrees))}_{int(math.floor((lon + 180) / degrees))}"


def street_names(roads_path, degrees=0.5):
    """roads.geojsonl → {клетка: {fold(имя): (Counter нынешних, Counter старых)}}.

    Адрес знает улицу строкой `addr:street`, а все её имена висят на самой
    дороге. Ключ — каждое нынешнее имя дороги: дом с `addr:street` на любом
    из её языков найдёт остальные. Цепочек не строим (имя A → дорога → имя B
    → другая дорога): так «Navoiy ko'chasi» одного района склеилась бы с
    одноимённой улицей другого.
    """
    out = defaultdict(dict)
    if not roads_path or not os.path.exists(roads_path):
        return out
    with open(roads_path, encoding="utf-8") as handle:
        for line in handle:
            if '"name' not in line:
                continue
            line = line.lstrip("\x1e").strip()
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            properties = feature.get("properties") or {}
            name = (properties.get("name") or "").strip()
            if not name or not properties.get("highway"):
                continue
            coords = (feature.get("geometry") or {}).get("coordinates") or []
            ends = [p for p in (coords[:1] + coords[-1:])
                    if isinstance(p, (list, tuple)) and len(p) >= 2]
            if not ends:
                continue
            current = [v for k in _keys_of(properties, CURRENT_FAMILIES, CURRENT_KEYS)
                       for v in split_values(properties.get(k))]
            old = [v for k in _keys_of(properties, OLD_FAMILIES, ("old_name",))
                   for v in split_values(properties.get(k))]
            if len(current) < 2 and not old:
                continue   # одно имя — добавить нечего
            for cell in {_cell(p[1], p[0], degrees) for p in ends}:
                bucket = out[cell]
                for text in current:
                    key = fold(text)
                    if not key:
                        continue
                    entry = bucket.get(key)
                    if entry is None:
                        entry = bucket[key] = (Counter(), Counter())
                    entry[0].update(current)
                    entry[1].update(old)
    return out


def _ranked(counter):
    """Имена по числу дорог, где они стоят, затем по алфавиту — детерминированно."""
    return [text for text, _ in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))]


def attach_street_names(addresses, names):
    """Дописать `a`/`o` улицам адресных клеток (`addresses_by_cell`)."""
    touched = 0
    for key, payload in addresses.items():
        bucket = names.get(key)
        if not bucket:
            continue
        for street in payload.get("streets") or []:
            entry = bucket.get(fold(street.get("n", "")))
            if not entry:
                continue
            alts, olds = dedup(_ranked(entry[0]), _ranked(entry[1]), street["n"])
            if alts or olds:
                touched += 1
                _set_names(street, alts, olds)
    return touched


def _set_names(street, alts, olds):
    if alts:
        street["a"] = alts
    else:
        street.pop("a", None)
    if olds:
        street["o"] = olds
    else:
        street.pop("o", None)


# --- Реестры переименований (aliases_*.tsv) --------------------------------

ALIAS_COLUMNS = ("kind", "name_now", "name_old", "lang", "osm_id", "lat", "lon",
                 "source", "source_date")
METRO_ALIAS_KINDS = {"metro", "subway", "station", "metro_station"}
PLACE_ALIAS_KINDS = {"place", "district", "neighbourhood", "mahalla", "suburb", "city", "quarter"}
# Насколько далеко от точки реестра может стоять запись, к которой клеим имя.
ALIAS_STREET_METERS = 2000.0
ALIAS_VENUE_METERS = 800.0


def read_aliases(path):
    """TSV → [dict]. Строки-комментарии (#) и заголовок пропускаются; строка
    без нынешнего или старого имени — тоже."""
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8", newline="") as handle:
        reader = csv.reader((line for line in handle if not line.startswith("#")),
                            delimiter="\t")
        header = None
        for record in reader:
            if not record or not any(cell.strip() for cell in record):
                continue
            if header is None and record[0].strip().lower() == "kind":
                header = [cell.strip().lower() for cell in record]
                continue
            columns = header or list(ALIAS_COLUMNS)
            row = {columns[i]: record[i].strip() for i in range(min(len(columns), len(record)))}
            if not row.get("name_now") or not row.get("name_old"):
                continue
            for axis in ("lat", "lon"):
                try:
                    row[axis] = float(row.get(axis) or "")
                except ValueError:
                    row[axis] = None
            rows.append(row)
    return rows


def _meters(lat1, lon1, lat2, lon2):
    scale = math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lat2 - lat1) * 111_320.0, (lon2 - lon1) * 111_320.0 * scale)


def _street_points(street, scale):
    lat = lon = 0
    flat = street.get("p") or []
    for index in range(0, len(flat) - 1, 2):
        if index == 0:
            lat, lon = flat[0], flat[1]
        else:
            lat += flat[index]
            lon += flat[index + 1]
        yield lat / scale, lon / scale


def apply_aliases(addresses, venues, rows, degrees=0.5, scale=1e5):
    """Старые имена из реестра → записи клеток. Возвращает (приклеено,
    [строки, которым не нашлось записи]) — второе печатается сборкой, чтобы
    разведчик данных видел, что не легло."""
    applied, missed = 0, []
    for row in rows:
        kind = (row.get("kind") or "").lower()
        want = core_key(row["name_now"])
        lat, lon = row.get("lat"), row.get("lon")
        cells = [_cell(lat, lon, degrees)] if lat is not None and lon is not None else None
        hit = False
        if kind in METRO_ALIAS_KINDS or kind in PLACE_ALIAS_KINDS or kind not in ("street", "avenue", ""):
            codes = ({VENUE_METRO} if kind in METRO_ALIAS_KINDS
                     else {VENUE_PLACE} if kind in PLACE_ALIAS_KINDS else None)
            for key in (cells or sorted(venues)):
                for record in (venues.get(key) or {}).get("venues") or []:
                    if codes is not None and record[0] not in codes:
                        continue
                    names = [record[1]] + (record[4] if len(record) > 4 else [])
                    if want not in {core_key(n) for n in names}:
                        continue
                    if lat is not None and _meters(lat, lon, record[2] / scale, record[3] / scale) > ALIAS_VENUE_METERS:
                        continue
                    hit |= _add_old_venue(record, row["name_old"])
        else:
            for key in (cells or sorted(addresses)):
                for street in (addresses.get(key) or {}).get("streets") or []:
                    names = [street.get("n", "")] + street.get("a", [])
                    if want not in {core_key(n) for n in names}:
                        continue
                    if lat is not None and min(
                            (_meters(lat, lon, a, b) for a, b in _street_points(street, scale)),
                            default=math.inf) > ALIAS_STREET_METERS:
                        continue
                    hit |= _add_old_street(street, row["name_old"])
        if not hit and kind in PLACE_ALIAS_KINDS and lat is not None and lon is not None:
            # Района города (туман) среди мест нет: в OSM это граница, а не
            # place=*. Реестр знает его точку — заводим место сами, иначе
            # «Хамзинский район» так и не найдёт «Яшнабадский».
            payload = venues.setdefault(_cell(lat, lon, degrees), {"version": 1, "venues": []})
            record = [VENUE_PLACE, row["name_now"], round(lat * scale), round(lon * scale)]
            payload["venues"].append(record)
            hit = _add_old_venue(record, row["name_old"])
        if hit:
            applied += 1
        else:
            missed.append(row)
    return applied, missed


def _as_old(alts, olds, old):
    """Реестр говорит «это старое имя» — оно старое, даже если в OSM оно
    лежит в alt_name («Ленинский район» у Мирабадского): иначе поиск находил
    бы район без подписи «бывш.»."""
    key = fold(old)
    return [a for a in alts if fold(a) != key], olds + [old]


def _add_old_street(street, old):
    alts, olds = _as_old(street.get("a", []), street.get("o", []), old)
    alts, olds = dedup(alts, olds, street["n"])
    # Совпало с основным именем — не ошибка реестра, а уже известное имя:
    # считаем приклеенным, чтобы не шуметь в отчёте.
    _set_names(street, alts, olds)
    return True


def _add_old_venue(record, old):
    alts = record[4] if len(record) > 4 else []
    olds = record[5] if len(record) > 5 else []
    alts, olds = dedup(*_as_old(alts, olds, old), record[1])
    del record[4:]
    if alts or olds:
        record.append(alts)
    if olds:
        record.append(olds)
    return True


def venue_row(code, name, lon, lat, alts=(), olds=()):
    """Строка заведения для сборки: 4 поля, а с именами — 6."""
    if alts or olds:
        return (code, name, lon, lat, list(alts), list(olds))
    return (code, name, lon, lat)


def payload_row(row, scale=1e5):
    """Строка сборки → запись файла клетки `[код, имя, lat, lon(, a(, o))]`."""
    code, name, lon, lat = row[:4]
    out = [code, name, round(lat * scale), round(lon * scale)]
    alts = list(row[4]) if len(row) > 4 else []
    olds = list(row[5]) if len(row) > 5 else []
    if alts or olds:
        out.append(alts)
    if olds:
        out.append(olds)
    return out
