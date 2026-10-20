#!/usr/bin/env python3
"""snap_cameras.py — притягивает координаты камер к оси дороги по геометрии OSM.

Проблема: адреса data.egov.uz геокодированы неточно — точка падает вбок от
полосы, иногда на ПАРАЛЛЕЛЬНУЮ улицу или во двор (камера «Navoiy prospekti»
оказывается на боковой «Saqchimon ko'chasi»). Это ломает карту, направление в
HUD и учёт проездов (одна камера двоится/считается с чужой улицы).

КАСКАД ДОВЕРИЯ (v2) — от самого надёжного сигнала к самому слабому:
  1. ref-матч: «M-39», «А 373», «4R-87» из адреса ↔ теги ref/int_ref дороги.
     Параллельной дороги с тем же ref не бывает, поэтому допустимый перенос
     шире (--max-shift-ref, 150 м): трассы геокодированы хуже улиц.
  2. name-матч: имя улицы из адреса ↔ name/name:ru/name:uz дороги, с
     кириллица↔латиница транслитом (Навои ↔ Navoiy) и, для длинных токенов,
     редакционным допуском 1 (Chilonzor ↔ Chilanzar — разные нормы транслита).
     Даже если чужая (параллельная) дорога физически ближе — выбираем ту,
     чьё название совпало с адресом.
  3. геометрия: имя не совпало, но камера и так почти на дороге — доверяем.
     Порог зависит от класса дороги: у магистрали ось полосы дальше от точки
     на обочине, чем у переулка (см. _trust_for_rank).

Почему НЕ OSRM /nearest: в нашей сборке OSRM возвращает пустые имена дорог
(name=''), поэтому имя не проверить — снап выродился бы в «на ближайшую», то
есть на параллельную. Здесь берём геометрию именованных дорог прямо из OSM.

БЕЗОПАСНОСТЬ ДАННЫХ (переставить на чужую дорогу хуже, чем оставить как есть):
  - двигаем только при совпадении ref/имени и не дальше своего лимита;
  - иначе оставляем исходную координату и ставим needsReview=true
    (приложение даёт таким камерам более широкий коридор оповещения);
  - каждый перенос пишем в отчёт (CSV) и в GeoJSON «старое→новое» для
    визуальной проверки (geojson.io / QGIS) ПЕРЕД заливкой в прод;
  - отдельный отчёт пар-дублей (та же точка после снапа) — только глазами,
    автослияния нет: в реестре бывают две камеры по направлениям.

Индекс дорог (v2): сегменты режутся на куски ≤200 м и индексируются по всем
клеткам куска. Прежний индекс «по концам сегмента» терял длинные прямые
(2-километровый кусок трассы был невидим для камеры посередине) — из-за этого
магистральные камеры не снапались вовсе.

Данные дорог готовит snap_cameras.sh через osmium (см. там), формат — GeoJSON
LineString'ы с тегами name*/ref*/highway (geojsonseq или FeatureCollection).

Запуск:
    python3 snap_cameras.py --roads roads.geojsonl --in cameras.json \
        --out cameras.snapped.json --report snap_report.csv --moves snap_moves.geojson

Самотест логики (без данных/сети):
    python3 snap_cameras.py --selftest
"""
import argparse
import collections
import csv
import json
import math
import re
import sys

# --- Нормализация и матчинг названий улиц (кириллица ↔ латиница) --------------

# Многобуквенные кириллические последовательности (до посимвольной транслитерации).
_CYR_MULTI = [
    ("ё", "yo"), ("ж", "j"), ("ч", "ch"), ("ш", "sh"), ("щ", "sh"),
    ("ю", "yu"), ("я", "ya"), ("ц", "s"), ("ў", "o"), ("ъ", ""),
]
# Однобуквенная транслитерация узбекской/русской кириллицы в латиницу.
_CYR_ONE = str.maketrans({
    "а": "a", "б": "b", "в": "v", "г": "g", "ғ": "g", "д": "d", "е": "e",
    "з": "z", "и": "i", "й": "y", "к": "k", "қ": "q", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "x", "ҳ": "h", "ы": "i", "ь": "", "э": "e", "һ": "h",
})

# Служебные слова «улица/проспект/перекрёсток» — выкидываем из токенов.
_STREET_STOPWORDS = {
    "ko", "kochasi", "kocha", "kchasi", "koicha", "kuchasi", "kucha",
    "shohkochasi", "shoh", "prospekti", "prospekt", "prospek", "yoli", "yuli",
    "chorrahasi", "chorraha", "kesishgan", "va", "burchagi", "yon", "qismi",
    "uy", "dom", "ulitsa", "ulica", "prospekta", "pereulok", "proezd", "shosse",
    "kochasy", "shahar", "mavze", "massiv", "mkr", "kvartal", "tumani",
}
# Апострофы/дефисы/пунктуация → пробел/ничего.
_PUNCT = str.maketrans({
    "ʻ": "", "'": "", "`": "", "'": "", "ʼ": "", "’": "", "-": " ", ".": " ",
    ",": " ", "/": " ", "«": " ", "»": " ", "(": " ", ")": " ", "№": " ",
})


def translit(text):
    """Кириллицу → латиницу; латиницу оставляем как есть."""
    t = text.lower()
    for a, b in _CYR_MULTI:
        t = t.replace(a, b)
    return t.translate(_CYR_ONE)


def street_tokens(text):
    """Адрес/название дороги → множество значимых латинских токенов улицы."""
    if not text:
        return set()
    t = translit(text).translate(_PUNCT)
    out = set()
    for w in t.split():
        w = "".join(ch for ch in w if ch.isalnum())
        if not w or w in _STREET_STOPWORDS or w.isdigit():
            continue
        out.add(w)
    return out


def _damerau1(a, b):
    """Расстояние Дамерау-Левенштейна ≤ 1? (замена/вставка/удаление/перестановка).
    Токены короткие — полный DP не нужен, хватает разбора случаев."""
    if a == b:
        return True
    la, lb = len(a), len(b)
    if abs(la - lb) > 1:
        return False
    if la == lb:
        # одна замена ИЛИ одна перестановка соседних
        diff = [i for i in range(la) if a[i] != b[i]]
        if len(diff) == 1:
            return True
        return (len(diff) == 2 and diff[1] == diff[0] + 1
                and a[diff[0]] == b[diff[1]] and a[diff[1]] == b[diff[0]])
    # длины отличаются на 1 — одна вставка/удаление
    if la > lb:
        a, b, la, lb = b, a, lb, la
    i = j = used = 0
    while i < la and j < lb:
        if a[i] == b[j]:
            i += 1; j += 1
        elif used:
            return False
        else:
            used = 1; j += 1
    return True


_VOWELS = set("aeiou")


def _skeleton(word):
    """Скелет согласных: разные нормы узбекского транслита расходятся почти
    только в гласных (Chilanzar/Chilonzor, Yunusabad/Yunusobod)."""
    return "".join(ch for ch in word if ch not in _VOWELS)


def tokens_match(addr_tokens, road_tokens):
    """Совпадают ли улицы: общий значимый токен (учёт navoi↔navoiy и опечаток)."""
    if not addr_tokens or not road_tokens:
        return False
    for a in addr_tokens:
        if len(a) < 3:
            continue
        for b in road_tokens:
            if len(b) < 3:
                continue
            if a == b:
                return True
            # «navoi» ↔ «navoiy», «temur» ↔ «temuriy»: короткое внутри длинного.
            if len(a) >= 4 and a in b:
                return True
            if len(b) >= 4 and b in a:
                return True
            # Длинные токены (короткие дают ложняк): опечатка геокодера в одну
            # букву ИЛИ другая норма транслита — совпал скелет согласных при
            # той же первой букве (chilanzar↔chilonzor: гласные разные, chlnzr общий).
            if len(a) >= 6 and len(b) >= 6:
                if _damerau1(a, b):
                    return True
                if a[0] == b[0] and abs(len(a) - len(b)) <= 1 \
                        and len(_skeleton(a)) >= 4 and _skeleton(a) == _skeleton(b):
                    return True
    return False


# --- Ref трасс: «M-39» / «А 373» / «4Р-87» ↔ ref/int_ref дороги ---------------

# Кириллические двойники латинских букв в номерах дорог.
_REF_CYR2LAT = str.maketrans({"м": "m", "а": "a", "р": "r", "е": "e"})
# Шаблон номера дороги в адресе: М-39, M 39, A373, 4Р-87, 4R125...
# Lookbehind исключает и кириллицу: иначе «м» из «дом 39» ловится как М39.
_REF_IN_TEXT = re.compile(
    r"(?<![a-zа-яё0-9])(4?[mareмаре])[-\s]?(\d{1,4})(?![0-9])",
    re.IGNORECASE)


def _norm_ref(letters, digits):
    letters = letters.lower().translate(_REF_CYR2LAT)
    return f"{letters}{digits}"


def ref_tokens_from_text(text):
    """Номера дорог, упомянутые в адресе камеры: {'m39', '4r87', ...}."""
    if not text:
        return set()
    out = set()
    for m in _REF_IN_TEXT.finditer(text):
        out.add(_norm_ref(m.group(1), m.group(2)))
    return out


def ref_tokens_from_tag(value):
    """Тег ref дороги (бывает списком: 'M39;E40') → {'m39', 'e40'}."""
    if not value:
        return set()
    out = set()
    for part in re.split(r"[;,]", str(value)):
        part = translit(part.strip()).replace("-", "").replace(" ", "")
        if re.fullmatch(r"4?[mare]\d{1,4}", part):
            out.add(part)
    return out


# --- Геометрия (локальная равнопромежуточная проекция, город ≤ сотни метров) --

_M_PER_DEG_LAT = 110540.0
_M_PER_DEG_LON = 111320.0


def _project_point_to_segment(px, py, ax, ay, bx, by):
    """Ближайшая точка отрезка AB к точке P (все в метрах). → (qx, qy)."""
    dx, dy = bx - ax, by - ay
    if dx == 0.0 and dy == 0.0:
        return ax, ay
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return ax + t * dx, ay + t * dy


def segment_axis(lat1, lon1, lat2, lon2):
    """Ось сегмента дороги: недирекционный азимут 0–179° (юг = север).
    Камера меряет скорость вдоль своей дороги — ось позволяет приложению
    отбрасывать «проезды» поперёк (мост над камерой, перпендикулярный
    перекрёсток на развязке)."""
    kx = _M_PER_DEG_LON * math.cos(math.radians((lat1 + lat2) / 2))
    dx = (lon2 - lon1) * kx
    dy = (lat2 - lat1) * _M_PER_DEG_LAT
    if dx == 0.0 and dy == 0.0:
        return None
    deg = math.degrees(math.atan2(dx, dy)) % 360.0   # 0 = север, по часовой
    return int(round(deg % 180.0)) % 180


RoadAttrs = collections.namedtuple("RoadAttrs", "oneway reverse lanes cls bridge layer")
_NO_ATTRS = RoadAttrs(False, False, None, None, False, 0)

#: Кандидат снапа. namedtuple, а не растущий кортеж: полей стало девять.
Candidate = collections.namedtuple(
    "Candidate", "dist plat plon tokens refs rank axis way vertex")


def _parse_lanes(value):
    """Тег lanes: «4», «2;3», «1|2», мусор. Берём первое целое в разумных рамках."""
    if value is None:
        return None
    try:
        first = str(value).split(";")[0].split("|")[0].strip()
        n = int(float(first))
    except (TypeError, ValueError):
        return None
    return n if 1 <= n <= 12 else None


def _parse_layer(value):
    try:
        return int(float(str(value).split(";")[0]))
    except (TypeError, ValueError):
        return 0


def road_attrs_from_props(props):
    """Атрибуты дороги, которые раньше просто выбрасывались.

    oneway важнее всего: на разделённой дороге каждая проезжая часть — отдельная
    линия с oneway, значит НАПРАВЛЕНИЕ известно однозначно, и камера обратного
    направления перестаёт быть «нашей». У двусторонней улицы направления нет —
    ни OSM, ни реестр не говорят, куда смотрит камера, и остаётся ось.
    """
    raw = str(props.get("oneway", "")).strip().lower()
    oneway = raw in ("yes", "1", "true", "-1")
    return RoadAttrs(
        oneway=oneway,
        reverse=(raw == "-1"),   # геометрия нарисована против движения
        lanes=_parse_lanes(props.get("lanes")),
        cls=props.get("highway") or None,
        bridge=str(props.get("bridge", "")).strip().lower() in ("yes", "viaduct", "true"),
        layer=_parse_layer(props.get("layer")),
    )


def _bearing(lat1, lon1, lat2, lon2):
    """Азимут 0–359° из первой точки во вторую (плоская аппроксимация: участки
    дороги короткие, сферическая формула тут ничего не добавляет)."""
    kx = _M_PER_DEG_LON * math.cos(math.radians((lat1 + lat2) / 2))
    dx = (lon2 - lon1) * kx
    dy = (lat2 - lat1) * _M_PER_DEG_LAT
    return math.degrees(math.atan2(dx, dy)) % 360


class RoadIndex:
    """Сеточный индекс отрезков дорог для запросов «что рядом».

    v2: длинные отрезки режем на куски ≤ SPLIT_M и кладём кусок во все клетки
    его bbox. Прежний индекс «по клеткам концов» терял длинные прямые: у
    2-километрового сегмента трассы концы лежат далеко, и камера посередине
    его «не видела» — магистральные камеры не снапались вовсе.
    """

    CELL = 0.003    # ≈ 250–330 м
    SPLIT_M = 200.0  # максимальная длина индексируемого куска

    def __init__(self):
        self.grid = {}   # (ci, cj) -> [ сегменты ]
        # Геометрия путей целиком и их атрибуты: по ним строится короткий кусок
        # проезжей части вокруг камеры и определяется направление движения.
        self.ways = []   # [ [ (lat, lon), ... ] ]
        self.attrs = []  # [ RoadAttrs ]
        self.count = 0

    @staticmethod
    def _cell(lat, lon):
        return (int(math.floor(lat / RoadIndex.CELL)),
                int(math.floor(lon / RoadIndex.CELL)))

    def _add_segment(self, lat1, lon1, lat2, lon2, tokens, refs, rank, way, vertex):
        seg = (lat1, lon1, lat2, lon2, tokens, refs, rank,
               segment_axis(lat1, lon1, lat2, lon2), way, vertex)
        c1i, c1j = self._cell(lat1, lon1)
        c2i, c2j = self._cell(lat2, lon2)
        for ci in range(min(c1i, c2i), max(c1i, c2i) + 1):
            for cj in range(min(c1j, c2j), max(c1j, c2j) + 1):
                self.grid.setdefault((ci, cj), []).append(seg)
        self.count += 1

    def add_linestring(self, coords, tokens, refs, rank, attrs=_NO_ATTRS):
        """coords: [[lon, lat], ...] (порядок GeoJSON)."""
        way = len(self.ways)
        self.ways.append([(lat, lon) for lon, lat in coords])
        self.attrs.append(attrs)
        for vertex, ((lon1, lat1), (lon2, lat2)) in enumerate(zip(coords, coords[1:])):
            # Длину меряем грубо (по широте средней точки) — для нарезки хватает.
            kx = _M_PER_DEG_LON * math.cos(math.radians((lat1 + lat2) / 2))
            length = math.hypot((lat2 - lat1) * _M_PER_DEG_LAT, (lon2 - lon1) * kx)
            pieces = max(1, int(math.ceil(length / self.SPLIT_M)))
            for k in range(pieces):
                t0, t1 = k / pieces, (k + 1) / pieces
                self._add_segment(lat1 + (lat2 - lat1) * t0, lon1 + (lon2 - lon1) * t0,
                                  lat1 + (lat2 - lat1) * t1, lon1 + (lon2 - lon1) * t1,
                                  tokens, refs, rank, way, vertex)

    def nearby(self, lat, lon, radius):
        """Отрезки в пределах radius метров: (dist, plat, plon, tokens, refs, rank)."""
        coslat = math.cos(math.radians(lat))
        kx = _M_PER_DEG_LON * coslat
        ci, cj = self._cell(lat, lon)
        reach = max(1, int(math.ceil(radius / (self.CELL * _M_PER_DEG_LAT))))
        seen = set()
        out = []
        for di in range(-reach, reach + 1):
            for dj in range(-reach, reach + 1):
                for seg in self.grid.get((ci + di, cj + dj), ()):  # noqa
                    key = id(seg)
                    if key in seen:
                        continue
                    seen.add(key)
                    lat1, lon1, lat2, lon2, tokens, refs, rank, axis, way, vertex = seg
                    ax = (lon1 - lon) * kx
                    ay = (lat1 - lat) * _M_PER_DEG_LAT
                    bx = (lon2 - lon) * kx
                    by = (lat2 - lat) * _M_PER_DEG_LAT
                    qx, qy = _project_point_to_segment(0.0, 0.0, ax, ay, bx, by)
                    dist = math.hypot(qx, qy)
                    if dist <= radius:
                        plat = lat + qy / _M_PER_DEG_LAT
                        plon = lon + qx / kx
                        out.append(Candidate(dist, plat, plon, tokens, refs,
                                             rank, axis, way, vertex))
        out.sort(key=lambda c: c[0])
        return out


# --- Загрузка дорог из GeoJSON (geojsonseq или FeatureCollection) ------------

_HIGHWAY_RANK = {
    "motorway": 6, "trunk": 6, "primary": 5, "secondary": 4, "tertiary": 3,
    "unclassified": 2, "residential": 2, "living_street": 1, "service": 0,
    "road": 2,
}


def _iter_features(path):
    with open(path, encoding="utf-8") as f:
        head = f.read(256)
    # FeatureCollection — единый JSON; иначе geojsonseq (Feature на строку, потоково).
    if '"FeatureCollection"' in head:
        data = json.load(open(path, encoding="utf-8"))
        for feat in data.get("features", []):
            yield feat
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip().lstrip("\x1e").strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def load_roads(path, *, keep_highway=None):
    """keep_highway — необязательный фильтр по тегу highway (функция значения →
    bool): пересъёмке профиля (resnap_profiles) нужны только проезжие части,
    тротуар в индексе — это ровно та ошибка, которую она исправляет."""
    index = RoadIndex()
    named = withref = 0
    for feat in _iter_features(path):
        geom = (feat or {}).get("geometry") or {}
        if geom.get("type") != "LineString":
            continue
        coords = geom.get("coordinates") or []
        if len(coords) < 2:
            continue
        props = feat.get("properties") or {}
        if keep_highway is not None and not keep_highway(props.get("highway")):
            continue
        tokens = set()
        for key in ("name", "name:uz", "name:ru", "name:en", "int_name",
                    "name:uz-Latn", "name:uz-Cyrl", "alt_name", "official_name"):
            tokens |= street_tokens(props.get(key))
        refs = set()
        for key in ("ref", "int_ref", "nat_ref", "official_ref"):
            refs |= ref_tokens_from_tag(props.get(key))
        rank = _HIGHWAY_RANK.get(props.get("highway", ""), 2)
        if tokens:
            named += 1
        if refs:
            withref += 1
        index.add_linestring(coords, tokens, refs, rank, road_attrs_from_props(props))
    return index, named, withref


# --- Профиль дороги камеры ---------------------------------------------------

#: Кусок проезжей части: по столько метров в каждую сторону от камеры.
STUB_SPAN_M = 100.0
#: Допуск упрощения куска (Дуглас-Пекер): 2 м мельче любой полосы.
STUB_EPS_M = 2.0
#: Потолок точек, чтобы база не пухла: 9 точек хватает на любую городскую кривую.
STUB_MAX_POINTS = 9


def road_direction(index, cand):
    """Азимут проезжей части 0–359° — только для ОДНОСТОРОННЕЙ дороги, где
    направление известно однозначно. У двусторонней возвращаем None: в какую
    сторону смотрит камера, не знает ни OSM, ни реестр, и приложение остаётся
    на оси (0–179°), предупреждая в обе стороны."""
    attrs = index.attrs[cand.way]
    if not attrs.oneway:
        return None
    coords = index.ways[cand.way]
    if len(coords) < 2:
        return None
    i = min(cand.vertex, len(coords) - 2)
    (lat1, lon1), (lat2, lon2) = coords[i], coords[i + 1]
    if attrs.reverse:   # oneway=-1: геометрия нарисована против движения
        lat1, lon1, lat2, lon2 = lat2, lon2, lat1, lon1
    return int(round(_bearing(lat1, lon1, lat2, lon2))) % 360


def _meters(lat1, lon1, lat2, lon2):
    kx = _M_PER_DEG_LON * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lat2 - lat1) * _M_PER_DEG_LAT, (lon2 - lon1) * kx)


def _simplify(points, eps):
    """Дуглас-Пекер по хорде в метрах: убирает вершины, которые ничего не
    добавляют к форме дороги."""
    if len(points) <= 2:
        return points
    (alat, alon), (blat, blon) = points[0], points[-1]
    kx = _M_PER_DEG_LON * math.cos(math.radians(alat))
    ax, ay = 0.0, 0.0
    bx, by = (blon - alon) * kx, (blat - alat) * _M_PER_DEG_LAT
    worst, index = 0.0, 0
    for i in range(1, len(points) - 1):
        plat, plon = points[i]
        px, py = (plon - alon) * kx, (plat - alat) * _M_PER_DEG_LAT
        qx, qy = _project_point_to_segment(px, py, ax, ay, bx, by)
        d = math.hypot(px - qx, py - qy)
        if d > worst:
            worst, index = d, i
    if worst <= eps:
        return [points[0], points[-1]]
    return _simplify(points[:index + 1], eps)[:-1] + _simplify(points[index:], eps)


def road_stub(index, cand, cam_lat, cam_lon, *, span=STUB_SPAN_M):
    """Короткий кусок проезжей части вокруг камеры — дельты 1e-6° от её
    координаты (плоский список lat, lon, lat, lon…).

    Зачем: по нему приложение проверяет «я на этой дороге» настоящим расстоянием
    до ломаной вместо эвристического коридора и берёт истинный курс дороги в
    точке камеры — на кривой одна ось врёт, а ломаная нет.
    """
    coords = index.ways[cand.way]
    if len(coords) < 2:
        return []
    i = min(cand.vertex, len(coords) - 2)
    point = (cand.plat, cand.plon)

    def walk(indices):
        """Идём по вершинам, пока не набрали span. Если следующая вершина дальше
        границы — ставим точку РОВНО на границе: на длинной прямой (в OSM это
        обычная вещь) иначе не набралось бы ни одной точки и куска не было бы.
        """
        out, walked, prev = [], 0.0, point
        for j in indices:
            nxt = coords[j]
            step = _meters(prev[0], prev[1], nxt[0], nxt[1])
            if step <= 0:
                continue
            if walked + step > span:
                ratio = (span - walked) / step
                out.append((prev[0] + (nxt[0] - prev[0]) * ratio,
                            prev[1] + (nxt[1] - prev[1]) * ratio))
                break
            walked += step
            out.append(nxt)
            prev = nxt
        return out

    back = walk(range(i, -1, -1))
    forward = walk(range(i + 1, len(coords)))

    points = list(reversed(back)) + [point] + forward
    if len(points) < 2:
        return []
    points = _simplify(points, STUB_EPS_M)
    if len(points) > STUB_MAX_POINTS:
        step = (len(points) - 1) / (STUB_MAX_POINTS - 1)
        points = [points[min(len(points) - 1, int(round(k * step)))]
                  for k in range(STUB_MAX_POINTS)]
    out = []
    for lat, lon in points:
        out.append(int(round((lat - cam_lat) * 1e6)))
        out.append(int(round((lon - cam_lon) * 1e6)))
    return out


def opposite_carriageway(index, cand, *, radius=60.0, min_angle=120.0):
    """Разделённая ли дорога: идёт ли рядом параллельная проезжая часть ОБРАТНОГО
    направления.

    Это ключ к безопасности гейта направления. Если дорога разделённая, а парной
    камеры на обратной стороне в реестре нет, то эта одиночная камера вполне может
    снимать и обратную сторону — глушить её по направлению нельзя, молчание
    опаснее лишнего предупреждения. А на настоящей односторонней улице обратного
    направления просто не существует, и гейт там безвреден.
    """
    own = road_direction(index, cand)
    if own is None:
        return False
    for other in index.nearby(cand.plat, cand.plon, radius):
        if other.way == cand.way:
            continue
        direction = road_direction(index, other)
        if direction is None:
            continue
        delta = abs(direction - own) % 360
        if min(delta, 360 - delta) > min_angle:
            return True
    return False


def mark_direction_twins(cameras, *, max_meters=100.0, min_angle=120.0):
    """Пометить камеры, у которых рядом стоит камера ОБРАТНОГО направления.

    Такая пара означает, что стороны дороги поделены между двумя камерами: каждая
    смотрит свою, и глушить по направлению безопасно. Возвращает число помеченных.

    Прежние признаки снимаются: база дописывается, а не пересобирается, и
    признак от камеры, которую с тех пор перенесли или убрали, оставался бы
    без пары (2009, 2010 в v11) — доказательство без доказательства (11.2).
    Приложение проверяет пару и само (TwinCheck), но в базе её быть не должно.
    """
    for cam in cameras:
        cam.pop("twin", None)
    cell = 0.001   # ~110 м
    grid = {}
    for i, cam in enumerate(cameras):
        if cam.get("dir") is None:
            continue
        grid.setdefault((int(cam["lat"] / cell), int(cam["lon"] / cell)), []).append(i)
    marked = 0
    for (ci, cj), indices in grid.items():
        neighbours = []
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                neighbours.extend(grid.get((ci + di, cj + dj), ()))
        for i in indices:
            a = cameras[i]
            kx = _M_PER_DEG_LON * math.cos(math.radians(a["lat"]))
            for j in neighbours:
                if i == j:
                    continue
                b = cameras[j]
                delta = abs(a["dir"] - b["dir"]) % 360
                if min(delta, 360 - delta) <= min_angle:
                    continue
                if math.hypot((a["lat"] - b["lat"]) * _M_PER_DEG_LAT,
                              (a["lon"] - b["lon"]) * kx) <= max_meters:
                    a["twin"] = True
                    marked += 1
                    break
    return marked


def apply_road_profile(out, index, cand):
    """Записать профиль дороги в камеру. Пишем только известное: старые базы
    этих полей не содержали, приложение к их отсутствию готово."""
    attrs = index.attrs[cand.way]
    direction = road_direction(index, cand)
    if direction is not None:
        out["dir"] = direction
        # Разделённая дорога или нет — пишем ЯВНО, оба значения. Приложение должно
        # отличать «дорога не разделена» (гейт безопасен) от «мы не знаем» (гейт
        # запрещён): при неизвестности предупреждаем в обе стороны.
        out["split"] = bool(opposite_carriageway(index, cand))
    # Одна полоса на магистрали — чаще ошибка тега (509, 2205, 3091…), а
    # узкая «дорога» камеры выводит машину крайнего ряда за её ширину. Без
    # поля приложение берёт ширину класса — безопасная сторона (11.2).
    if attrs.lanes and not (attrs.lanes == 1 and attrs.cls in ("motorway", "trunk", "primary")):
        out["lanes"] = attrs.lanes
    if attrs.cls:
        out["cls"] = attrs.cls
    # Мост/эстакада больше не пишется (11.5): приложение признак не читало —
    # глушить по нему без высоты нельзя, а проезд поперёк ловит гейт оси.
    stub = road_stub(index, cand, out["lat"], out["lon"])
    if len(stub) >= 4:
        out["road"] = stub


# --- Выбор точки переноса ----------------------------------------------------

def _trust_for_rank(rank, base):
    """Порог «уже на дороге» по классу: у магистрали ось дальше от обочины."""
    if rank >= 5:
        return base * 2.5   # trunk/primary: широкая многополоска
    if rank >= 3:
        return base * 1.5   # secondary/tertiary
    return base


def choose_snap(cam, index, *, radius, max_shift, max_shift_ref, trust_geom):
    """→ (lat, lon, reason, shift, axis, cand) либо None (оставить + needsReview).

    Каскад: ref трассы → имя улицы → геометрия (см. шапку файла).
    axis — ось дороги камеры (0–179°): по ней приложение отбрасывает «проезды»
    поперёк (мост над камерой, перпендикулярный перекрёсток на развязке).
    """
    cands = index.nearby(cam["lat"], cam["lon"], radius)
    if not cands:
        return None
    location = cam.get("location", "")
    addr = street_tokens(location)
    addr_refs = ref_tokens_from_text(location)

    # 1) Ref: однозначнее имени (двух параллельных M39 не бывает) — допускаем
    #    больший перенос: трассы геокодированы хуже городских улиц.
    if addr_refs:
        matched = [c for c in cands if addr_refs & c[4]]
        if matched:
            cand = matched[0]
            if cand.dist <= max_shift_ref:
                matched_refs = '/'.join(sorted(addr_refs & cand.refs))
                return (cand.plat, cand.plon,
                        f"ref-match «{matched_refs}» ({cand.dist:.0f} м)",
                        cand.dist, cand.axis, cand)

    # 2) Имя улицы: даже если чужая дорога физически ближе.
    named = [c for c in cands if tokens_match(addr, c[3])]
    if named:
        cand = named[0]
        if cand.dist <= max_shift:
            road = " ".join(sorted(cand.tokens))
            return (cand.plat, cand.plon, f"name-match «{road}» ({cand.dist:.0f} м)",
                    cand.dist, cand.axis, cand)
        return None  # имя нашли, но слишком далеко — подозрительно, не двигаем

    # 3) Геометрия: имя не совпало (адрес без улицы / улицы нет в OSM), но камера
    #    и так почти на дороге — смещение мало и безопасно.
    cand = cands[0]
    if cand.dist <= _trust_for_rank(cand.rank, trust_geom):
        return (cand.plat, cand.plon,
                f"already-on-road ({cand.dist:.0f} м, rank {cand.rank})",
                cand.dist, cand.axis, cand)
    return None


def annotate_axes(cameras, index, *, radius=60.0):
    """Только проставить axis по ближайшему сегменту, координаты не трогать.
    Для базы, которая уже снапнута: камера лежит на своей дороге, ближайший
    сегмент и есть её дорога. needsReview-камеры без дороги рядом остаются
    без оси — приложение для них ось не проверяет."""
    result = []
    annotated = 0
    for cam in cameras:
        out = dict(cam)
        cands = index.nearby(cam["lat"], cam["lon"], radius)
        if cands and cands[0].axis is not None:
            out["axis"] = cands[0].axis
            apply_road_profile(out, index, cands[0])
            annotated += 1
        result.append(out)
    return result, annotated


# --- Дубли после снапа -------------------------------------------------------

def find_duplicates(cameras, *, max_meters=60.0):
    """Пары камер одного типа ближе max_meters — кандидаты в дубли реестра.
    Только отчёт: в реестре бывают две законные камеры по направлениям."""
    cell = 0.001  # ~110 м
    grid = {}
    for i, cam in enumerate(cameras):
        grid.setdefault((int(cam["lat"] / cell), int(cam["lon"] / cell)), []).append(i)
    # Полный обход 3×3 соседей + дедуп через (min, max): «форвардные» клетки
    # ломаются на паре через границу, когда индексы идут не по сетке.
    seen = set()
    pairs = []
    for (ci, cj), members in grid.items():
        for i in members:
            a = cameras[i]
            kx = _M_PER_DEG_LON * math.cos(math.radians(a["lat"]))
            for di in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    for j in grid.get((ci + di, cj + dj), ()):
                        if j == i:
                            continue
                        key = (min(i, j), max(i, j))
                        if key in seen:
                            continue
                        seen.add(key)
                        b = cameras[j]
                        if a.get("type") != b.get("type"):
                            continue
                        d = math.hypot((a["lat"] - b["lat"]) * _M_PER_DEG_LAT,
                                       (a["lon"] - b["lon"]) * kx)
                        if d <= max_meters:
                            pairs.append((a.get("id"), b.get("id"), round(d, 1),
                                          a.get("type", ""),
                                          a.get("location", "")[:50],
                                          b.get("location", "")[:50]))
    return sorted(pairs, key=lambda p: p[2])


# --- Основной проход ---------------------------------------------------------

def snap_all(cameras, index, *, radius, max_shift, max_shift_ref, trust_geom):
    snapped = kept = 0
    total_shift = 0.0
    result, moves, report = [], [], []
    reasons = {}
    for cam in cameras:
        out = dict(cam)
        choice = choose_snap(cam, index, radius=radius, max_shift=max_shift,
                             max_shift_ref=max_shift_ref, trust_geom=trust_geom)
        if choice:
            lat, lon, reason, shift, axis, cand = choice
            out["lat"], out["lon"] = round(lat, 6), round(lon, 6)
            if axis is not None:
                out["axis"] = axis
            apply_road_profile(out, index, cand)
            out.pop("needsReview", None)
            snapped += 1
            total_shift += shift
            reasons[reason.split(" ")[0]] = reasons.get(reason.split(" ")[0], 0) + 1
            if shift > 3:
                report.append((cam.get("id"), round(shift, 1), reason,
                               cam.get("location", "")[:60]))
                moves.append({
                    "type": "Feature",
                    "properties": {"id": cam.get("id"), "shift_m": round(shift, 1),
                                   "reason": reason},
                    "geometry": {"type": "LineString", "coordinates": [
                        [cam["lon"], cam["lat"]], [round(lon, 6), round(lat, 6)]]},
                })
        else:
            out["needsReview"] = True
            kept += 1
        result.append(out)
    mark_direction_twins(result)
    return result, snapped, kept, total_shift, moves, report, reasons


def _round_lat(m):  # метры → доли градуса широты (для самотеста)
    return m / _M_PER_DEG_LAT


def selftest():
    ok = True

    def check(cond, label):
        nonlocal ok
        print(f"  [{'ok ' if cond else 'FAIL'}] {label}")
        ok = ok and cond

    # radius ≥ max_shift_ref: дорога должна попадать в поиск на пределе переноса.
    kwargs = dict(radius=160, max_shift=80, max_shift_ref=150, trust_geom=10)

    # 1) Матчинг имён с транслитом.
    check(tokens_match(street_tokens("A.navoiy ko'chasi 30"),
                       street_tokens("Alisher Navoiy ko'chasi")), "navoiy ~ Navoiy")
    check(tokens_match(street_tokens("Навои проспекти"),
                       street_tokens("Navoiy ko'chasi")), "кир. Навои ~ лат. Navoiy")
    check(tokens_match(street_tokens("Сақчимон кўчаси"),
                       street_tokens("Saqchimon ko'chasi")), "кир. Сақчимон ~ Saqchimon")
    check(not tokens_match(street_tokens("Istiqlol ko'chasi"),
                           street_tokens("Sharof Rashidov ko'chasi")), "разные улицы не матчатся")

    # 1а) Опечатки/нормы транслита: допуск 1 только на длинных токенах.
    check(tokens_match(street_tokens("Chilanzar ko'chasi"),
                       street_tokens("Chilonzor ko'chasi")), "Chilanzar ~ Chilonzor (скелет согласных)")
    check(tokens_match(street_tokens("Юнусабад тумани"),
                       street_tokens("Yunusobod ko'chasi")), "Юнусабад ~ Yunusobod")
    check(_damerau1("chilonzor", "chilonzar"), "DL: chilonzor ~ chilonzar")
    check(_damerau1("beruniy", "beruiny"), "DL: перестановка соседних букв")
    check(not _damerau1("amir", "emir") or len("amir") < 6, "короткие токены без допуска")
    check(not tokens_match({"ozod"}, {"obod"}), "ozod ≠ obod (4 буквы, замена не в счёт)")

    # 2) Ref из адреса и тега.
    check(ref_tokens_from_text("Автодорога М-39, 25-км") == {"m39"}, "кир. М-39 → m39")
    check(ref_tokens_from_text("A 373 Tashkent-Osh") == {"a373"}, "A 373 → a373")
    check(ref_tokens_from_text("4Р-87 участок") == {"4r87"}, "4Р-87 → 4r87")
    check(ref_tokens_from_text("дом 39, кв 5") == set(), "номер дома — не ref")
    check(ref_tokens_from_tag("M39;E40") == {"m39", "e40"}, "тег 'M39;E40'")

    # 3) Ловушка параллельной улицы: камера ближе к боковой, но адрес — Navoiy.
    index = RoadIndex()
    A = 41.3110      # «Navoiy ko'chasi» (главная)
    B = A - _round_lat(40)   # «Saqchimon ko'chasi» параллельно в 40 м
    index.add_linestring([[69.2800, A], [69.2820, A]],
                         street_tokens("Navoiy ko'chasi"), set(), 5)
    index.add_linestring([[69.2800, B], [69.2820, B]],
                         street_tokens("Saqchimon ko'chasi"), set(), 2)
    cam = {"id": 1, "lat": A - _round_lat(26), "lon": 69.2810,  # 26 м от A, 14 м от B
           "location": "Navoiy ko'chasi 30"}
    res = choose_snap(cam, index, **kwargs)
    check(res is not None, "камера с адресом Navoiy снапится")
    if res:
        d_to_A = abs(res[0] - A) * _M_PER_DEG_LAT
        d_to_B = abs(res[0] - B) * _M_PER_DEG_LAT
        check(d_to_A < 3 and d_to_B > 30,
              f"снап на Navoiy, не на параллельную ({d_to_A:.0f} м до A, {d_to_B:.0f} м до B)")

    # 4) Нет совпадения по имени и далеко от дорог → needsReview (None).
    cam_far = {"id": 2, "lat": A - _round_lat(70), "lon": 69.2810,
               "location": "Nomalum ko'chasi"}
    check(choose_snap(cam_far, index, **kwargs) is None,
          "далёкая камера без совпадения имени → needsReview")

    # 5) Почти на дороге (8 м), имя не совпало → доверяем геометрии.
    cam_close = {"id": 3, "lat": A - _round_lat(8), "lon": 69.2810, "location": ""}
    check(choose_snap(cam_close, index, **kwargs) is not None,
          "камера в 8 м от дороги снапится по геометрии")

    # 5а) Порог геометрии растёт с классом дороги: 20 м от primary — ок,
    #     20 м от residential — нет.
    cam20 = {"id": 4, "lat": A - _round_lat(20), "lon": 69.2810, "location": ""}
    res20 = choose_snap(cam20, index, **kwargs)
    check(res20 is not None and abs(res20[0] - A) * _M_PER_DEG_LAT < 3,
          "20 м от primary → снап (trust растёт с рангом)")

    # 6) ДЛИННЫЙ сегмент: камера у середины 2-км прямой (прежний индекс терял).
    long_index = RoadIndex()
    L = 41.5000
    long_index.add_linestring([[69.0000, L], [69.0240, L]],   # ~2 км по долготе
                              street_tokens("Katta yol"), {"m39"}, 6)
    cam_mid = {"id": 5, "lat": L - _round_lat(30), "lon": 69.0120,
               "location": "Katta yol, 12"}
    res_mid = choose_snap(cam_mid, long_index, **kwargs)
    check(res_mid is not None and abs(res_mid[0] - L) * _M_PER_DEG_LAT < 3,
          "камера у середины 2-км сегмента видит дорогу (supercover-индекс)")

    # 6а) Ось дороги: сегмент запад→восток = 90°, юг→север = 0°; снап несёт ось.
    check(segment_axis(L, 69.0000, L, 69.0240) == 90, "ось широтного сегмента = 90°")
    check(segment_axis(41.30, 69.28, 41.31, 69.28) == 0, "ось меридианного сегмента = 0°")
    check(res_mid is not None and res_mid[4] == 90, "снап отдаёт ось дороги камеры")
    ann, n_ann = annotate_axes([{"id": 9, "lat": L - _round_lat(10), "lon": 69.0120}],
                               long_index)
    check(n_ann == 1 and ann[0].get("axis") == 90 and "lat" in ann[0],
          "annotate проставляет ось, не трогая координаты")

    # 7) Ref-матч: адрес «М-39», дорога без имени в 120 м (для name — слишком
    #    далеко, для ref — норм).
    cam_ref = {"id": 6, "lat": L - _round_lat(120), "lon": 69.0120,
               "location": "Автодорога М-39, 25-км"}
    res_ref = choose_snap(cam_ref, long_index, **kwargs)
    check(res_ref is not None and "ref-match" in res_ref[2],
          "трассовая камера снапится по ref на 120 м")
    cam_far_ref = {"id": 7, "lat": L - _round_lat(200), "lon": 69.0120,
                   "location": "Автодорога М-39"}
    check(choose_snap(cam_far_ref, long_index, **kwargs) is None,
          "200 м — за пределом даже для ref → needsReview")

    # 8) Дубли: две камеры одного типа в 25 м → пара в отчёте.
    dups = find_duplicates([
        {"id": 10, "lat": A, "lon": 69.2800, "type": "Стационар радар"},
        {"id": 11, "lat": A - _round_lat(25), "lon": 69.2800, "type": "Стационар радар"},
        {"id": 12, "lat": A, "lon": 69.2900, "type": "Стационар радар"},
    ])
    check(len(dups) == 1 and {dups[0][0], dups[0][1]} == {10, 11},
          "пара-дубль найдена, дальняя камера не зацеплена")

    # 8) Профиль дороги: направление у односторонней, ось у двусторонней.
    oneway_index = RoadIndex()
    W = 41.4000
    oneway_index.add_linestring([[69.1000, W], [69.1050, W]],   # запад → восток
                                street_tokens("Katta kocha"), set(), 5,
                                road_attrs_from_props({"oneway": "yes", "lanes": "3",
                                                       "highway": "primary"}))
    cam_ow = {"id": 20, "lat": W - _round_lat(6), "lon": 69.1020,
              "location": "Katta kocha"}
    res_ow = choose_snap(cam_ow, oneway_index, **kwargs)
    check(res_ow is not None, "камера на односторонней снапится")
    if res_ow:
        out = {"lat": round(res_ow[0], 6), "lon": round(res_ow[1], 6)}
        apply_road_profile(out, oneway_index, res_ow[5])
        check(out.get("dir") == 90,
              f"направление односторонней = 90° (получили {out.get('dir')})")
        check(out.get("lanes") == 3, "полосы сохранены")
        check(out.get("cls") == "primary", "класс дороги сохранён")
        check("bridge" not in out, "обычная дорога не помечена мостом")
        check(len(out.get("road", [])) >= 4, "кусок дороги записан")
        check(all(abs(d) < 3000 for d in out.get("road", [])),
              "дельты куска дороги в разумных пределах")

    # 8к) Одна полоса на магистрали — без поля lanes (ширина по классу).
    one_lane = RoadIndex()
    one_lane.add_linestring([[69.1000, W], [69.1050, W]],
                            street_tokens("Katta kocha"), set(), 5,
                            road_attrs_from_props({"highway": "trunk", "lanes": "1", "oneway": "yes"}))
    res_ol = choose_snap(cam_ow, one_lane, **kwargs)
    if res_ol:
        out_ol = {"lat": round(res_ol[0], 6), "lon": round(res_ol[1], 6)}
        apply_road_profile(out_ol, one_lane, res_ol[5])
        check("lanes" not in out_ol, "lanes=1 на trunk не пишется")

    # 8а) Двусторонняя: направления нет — приложение остаётся на оси.
    two_way = RoadIndex()
    two_way.add_linestring([[69.1000, W], [69.1050, W]],
                           street_tokens("Katta kocha"), set(), 5,
                           road_attrs_from_props({"highway": "secondary", "lanes": "2"}))
    res_tw = choose_snap(cam_ow, two_way, **kwargs)
    if res_tw:
        out_tw = {"lat": round(res_tw[0], 6), "lon": round(res_tw[1], 6)}
        apply_road_profile(out_tw, two_way, res_tw[5])
        check("dir" not in out_tw, "у двусторонней дороги направления нет")
        check(res_tw[4] == 90, "ось двусторонней = 90°")

    # 8б) oneway=-1: геометрия нарисована против движения — азимут разворачиваем.
    rev = RoadIndex()
    rev.add_linestring([[69.1000, W], [69.1050, W]], set(), set(), 5,
                       road_attrs_from_props({"oneway": "-1", "highway": "primary"}))
    check(road_direction(rev, rev.nearby(W, 69.1020, 30)[0]) == 270,
          "oneway=-1 → азимут 270°")

    # 8в) Мост: флаг в профиль не пишется (11.5).
    bridge_index = RoadIndex()
    bridge_index.add_linestring([[69.1000, W], [69.1050, W]], set(), set(), 5,
                                road_attrs_from_props({"bridge": "yes", "layer": "1",
                                                       "highway": "trunk"}))
    out_br = {"lat": W, "lon": 69.1020}
    apply_road_profile(out_br, bridge_index, bridge_index.nearby(W, 69.1020, 30)[0])
    check("bridge" not in out_br, "мост в профиль не пишется (приложение его не читает)")

    # 8г) Кусок дороги на кривой сохраняет форму (упрощение не срезает поворот).
    curve = RoadIndex()
    pts = [[69.2000 + 0.0004 * k, 41.5000 + 0.0004 * (k * k) / 8] for k in range(12)]
    curve.add_linestring(pts, set(), set(), 4,
                         road_attrs_from_props({"highway": "secondary"}))
    stub = road_stub(curve, curve.nearby(pts[6][1], pts[6][0], 40)[0],
                     pts[6][1], pts[6][0])
    check(4 <= len(stub) <= STUB_MAX_POINTS * 2, f"кусок кривой: {len(stub) // 2} точек")
    check(len(stub) // 2 >= 3, "на кривой больше двух точек — форма сохранена")

    # 8е) Разделённая дорога: рядом параллельная проезжая часть обратного
    #     направления → одиночную камеру глушить по направлению нельзя.
    divided = RoadIndex()
    D = 41.4500
    divided.add_linestring([[69.3000, D], [69.3060, D]], set(), set(), 6,
                           road_attrs_from_props({"oneway": "yes", "highway": "trunk"}))
    divided.add_linestring([[69.3060, D - _round_lat(20)], [69.3000, D - _round_lat(20)]],
                           set(), set(), 6,
                           road_attrs_from_props({"oneway": "yes", "highway": "trunk"}))
    out_div = {"lat": D, "lon": 69.3030}
    apply_road_profile(out_div, divided, divided.nearby(D, 69.3030, 30)[0])
    check(out_div.get("split") is True, "разделённая дорога распознана")

    # 8ж) Настоящая односторонняя улица: параллельной обратной нет — гейт безвреден.
    single = RoadIndex()
    single.add_linestring([[69.3000, D], [69.3060, D]], set(), set(), 3,
                          road_attrs_from_props({"oneway": "yes", "highway": "tertiary"}))
    out_sng = {"lat": D, "lon": 69.3030}
    apply_road_profile(out_sng, single, single.nearby(D, 69.3030, 30)[0])
    check(out_sng.get("split") is False,
          "односторонняя улица помечена как НЕ разделённая (явное false, не пропуск)")

    # 8з) Парная камера обратной стороны: обе помечаются twin.
    pair_cams = [
        {"id": 30, "lat": D, "lon": 69.3030, "dir": 90},
        {"id": 31, "lat": D - _round_lat(20), "lon": 69.3030, "dir": 270},
        {"id": 32, "lat": D, "lon": 69.3300, "dir": 90},   # далеко, без пары
    ]
    marked = mark_direction_twins(pair_cams)
    check(marked == 2 and pair_cams[0].get("twin") and pair_cams[1].get("twin"),
          "парные камеры обратных направлений помечены")
    check("twin" not in pair_cams[2], "одиночная камера парной не считается")
    # 8и) Признак без пары (камеру-пару перенесли или убрали) — снимается.
    stale = [{"id": 40, "lat": D, "lon": 69.3400, "dir": 90, "twin": True}]
    check(mark_direction_twins(stale) == 0 and "twin" not in stale[0],
          "прежний признак без пары снят")

    # 8д) Битые теги дают пустой профиль, а не падение.
    junk = road_attrs_from_props({"lanes": "куда", "layer": "нет", "oneway": "reversible"})
    check(junk.lanes is None and junk.layer == 0 and junk.oneway is False,
          "мусорные теги разбираются без падения")

    print("selftest:", "PASSED" if ok else "FAILED")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Snap camera coordinates to OSM roads")
    ap.add_argument("--roads", help="GeoJSON(seq) дорог (из osmium export)")
    ap.add_argument("--in", dest="inp", default="cameras.json")
    ap.add_argument("--out", dest="out", default="cameras.snapped.json")
    ap.add_argument("--report", default="snap_report.csv")
    ap.add_argument("--moves", default="snap_moves.geojson")
    ap.add_argument("--dups", default="snap_dups.csv")
    ap.add_argument("--radius", type=float, default=160.0, help="радиус поиска дорог, м")
    ap.add_argument("--max-shift", type=float, default=80.0,
                    help="макс. перенос при совпадении имени, м")
    ap.add_argument("--max-shift-ref", type=float, default=150.0,
                    help="макс. перенос при совпадении ref трассы, м")
    ap.add_argument("--trust-geom", type=float, default=10.0,
                    help="базовый порог «уже на дороге» (растёт с классом), м")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--annotate", action="store_true",
                    help="только проставить axis (оси дорог), координаты не трогать")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.roads:
        print("нужен --roads roads.geojsonl (подготовит snap_cameras.sh через osmium)",
              file=sys.stderr)
        return 2

    print(f"загрузка дорог: {args.roads} …")
    index, named, withref = load_roads(args.roads)
    print(f"  кусков: {index.count}, линий с именами: {named}, с ref: {withref}")

    cameras = json.load(open(args.inp, encoding="utf-8"))

    if args.annotate:
        result, annotated = annotate_axes(cameras, index)
        twins = mark_direction_twins(result)
        json.dump(result, open(args.out, "w", encoding="utf-8"),
                  ensure_ascii=False, separators=(",", ":"))
        with_dir = sum(1 for c in result if c.get("dir") is not None)
        split = sum(1 for c in result if c.get("split"))
        gated = sum(1 for c in result if c.get("dir") is not None
                    and (c.get("twin") or not c.get("split")))
        print(f"annotate: осей {annotated} из {len(cameras)} → {args.out}")
        print(f"  направление: {with_dir} · разделённая дорога: {split} · "
              f"парных камер: {twins}")
        print(f"  гейт по направлению применим к {gated} камерам "
              f"(остальные могут снимать обе стороны — предупреждаем в обе)")
        return 0

    print(f"камер: {len(cameras)} · radius {args.radius:.0f} м · "
          f"max-shift {args.max_shift:.0f}/{args.max_shift_ref:.0f} (имя/ref) м · "
          f"trust-geom {args.trust_geom:.0f} м\n")

    result, snapped, kept, total_shift, moves, report, reasons = snap_all(
        cameras, index, radius=args.radius, max_shift=args.max_shift,
        max_shift_ref=args.max_shift_ref, trust_geom=args.trust_geom)

    json.dump(result, open(args.out, "w", encoding="utf-8"), ensure_ascii=False)
    with open(args.report, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "shift_m", "reason", "location"])
        w.writerows(sorted(report, key=lambda r: -r[1]))
    json.dump({"type": "FeatureCollection", "features": moves},
              open(args.moves, "w", encoding="utf-8"), ensure_ascii=False)

    dups = find_duplicates(result)
    with open(args.dups, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id1", "id2", "dist_m", "type", "location1", "location2"])
        w.writerows(dups)

    avg = (total_shift / snapped) if snapped else 0
    print(f"итог: перенесено {snapped}, оставлено+needsReview {kept}")
    print(f"по сигналам: {reasons}")
    print(f"средний перенос: {avg:.1f} м · пар-дублей: {len(dups)}")
    print(f"отчёты: {args.report} · {args.moves} · {args.dups} · база: {args.out}")
    print("\nдалее: открыть snap_moves.geojson в geojson.io и глазами проверить,")
    print("что камеры не прыгнули на чужие дороги; затем заменить живую базу и")
    print("поднять version.json (OTA раздаст обновление приложению).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
