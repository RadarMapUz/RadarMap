#!/usr/bin/env python3
"""snap_cameras.py — притягивает координаты камер к оси дороги по геометрии OSM.

Проблема: адреса data.egov.uz геокодированы неточно — точка падает вбок от
полосы, иногда на ПАРАЛЛЕЛЬНУЮ улицу или во двор (камера «Navoiy prospekti»
оказывается на боковой «Saqchimon ko'chasi»). Это ломает карту, направление в
HUD и учёт проездов (одна камера двоится/считается с чужой улицы).

КЛЮЧЕВАЯ ИДЕЯ (умно, без ложных переносов на ЧУЖУЮ дорогу):
  снапим не на ближайшую дорогу, а на ближайшую дорогу с ПОДХОДЯЩИМ ИМЕНЕМ.
  Имя улицы берём из адреса камеры и матчим с name/name:ru/name:uz дороги,
  учитывая кириллицу↔латиницу (Навои ↔ Navoiy, Сақчимон ↔ Saqchimon).
  Даже если чужая (параллельная) дорога физически ближе — выбираем ту, чьё
  название совпало с адресом.

Почему НЕ OSRM /nearest: в нашей сборке OSRM возвращает пустые имена дорог
(name=''), поэтому имя не проверить — снап выродился бы в «на ближайшую», то
есть на параллельную. Здесь берём геометрию именованных дорог прямо из OSM.

БЕЗОПАСНОСТЬ ДАННЫХ (переставить на чужую дорогу хуже, чем оставить как есть):
  - двигаем только при совпадении имени и не дальше --max-shift;
  - камера и так <--trust-geom м от дороги → доверяем геометрии (смещение мало);
  - иначе оставляем исходную координату и ставим needsReview=true
    (в приложении подсветится как «проверить» + отработает краудсорс-репортинг);
  - каждый перенос пишем в отчёт (CSV) и в GeoJSON «старое→новое» для
    визуальной проверки (geojson.io / QGIS) ПЕРЕД заливкой в прод.

Данные дорог готовит snap_cameras.sh через osmium (см. там), формат — GeoJSON
LineString'ы с тегами name/name:ru/name:uz/highway (geojsonseq или
FeatureCollection).

Запуск:
    python3 snap_cameras.py --roads roads.geojsonl --in cameras.json \
        --out cameras.snapped.json --report snap_report.csv --moves snap_moves.geojson

Самотест логики (без данных/сети) — ловушка параллельной улицы + транслит:
    python3 snap_cameras.py --selftest
"""
import argparse
import csv
import json
import math
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


def tokens_match(addr_tokens, road_tokens):
    """Совпадают ли улицы: общий значимый токен (учёт navoi↔navoiy)."""
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
    return False


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


class RoadIndex:
    """Сеточный индекс отрезков именованных дорог для запросов «что рядом»."""

    CELL = 0.003  # ≈ 250–330 м

    def __init__(self):
        self.grid = {}   # (ci, cj) -> [ (lat1, lon1, lat2, lon2, tokens, rank) ]
        self.count = 0

    @staticmethod
    def _cell(lat, lon):
        return (int(math.floor(lat / RoadIndex.CELL)),
                int(math.floor(lon / RoadIndex.CELL)))

    def add_linestring(self, coords, tokens, rank):
        """coords: [[lon, lat], ...] (порядок GeoJSON). Режем на короткие отрезки."""
        for (lon1, lat1), (lon2, lat2) in zip(coords, coords[1:]):
            seg = (lat1, lon1, lat2, lon2, tokens, rank)
            # Индексируем по клеткам обоих концов (городские отрезки короткие).
            for lat, lon in ((lat1, lon1), (lat2, lon2)):
                self.grid.setdefault(self._cell(lat, lon), []).append(seg)
            self.count += 1

    def nearby(self, lat, lon, radius):
        """Отрезки в пределах radius метров: (dist, plat, plon, tokens, rank)."""
        coslat = math.cos(math.radians(lat))
        kx = _M_PER_DEG_LON * coslat
        ci, cj = self._cell(lat, lon)
        seen = set()
        out = []
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for seg in self.grid.get((ci + di, cj + dj), ()):  # noqa
                    key = id(seg)
                    if key in seen:
                        continue
                    seen.add(key)
                    lat1, lon1, lat2, lon2, tokens, rank = seg
                    ax = (lon1 - lon) * kx
                    ay = (lat1 - lat) * _M_PER_DEG_LAT
                    bx = (lon2 - lon) * kx
                    by = (lat2 - lat) * _M_PER_DEG_LAT
                    qx, qy = _project_point_to_segment(0.0, 0.0, ax, ay, bx, by)
                    dist = math.hypot(qx, qy)
                    if dist <= radius:
                        plat = lat + qy / _M_PER_DEG_LAT
                        plon = lon + qx / kx
                        out.append((dist, plat, plon, tokens, rank))
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


def load_roads(path):
    index = RoadIndex()
    named = 0
    for feat in _iter_features(path):
        geom = (feat or {}).get("geometry") or {}
        if geom.get("type") != "LineString":
            continue
        coords = geom.get("coordinates") or []
        if len(coords) < 2:
            continue
        props = feat.get("properties") or {}
        tokens = set()
        for key in ("name", "name:uz", "name:ru", "name:en", "int_name",
                    "name:uz-Latn", "name:uz-Cyrl", "alt_name", "official_name"):
            tokens |= street_tokens(props.get(key))
        rank = _HIGHWAY_RANK.get(props.get("highway", ""), 2)
        if tokens:
            named += 1
        index.add_linestring(coords, tokens, rank)
    return index, named


# --- Выбор точки переноса ----------------------------------------------------

def choose_snap(cam, index, *, radius, max_shift, trust_geom):
    """→ (lat, lon, reason, road_tokens, shift) либо None (оставить + needsReview)."""
    cands = index.nearby(cam["lat"], cam["lon"], radius)
    if not cands:
        return None
    addr = street_tokens(cam.get("location", ""))

    named = [c for c in cands if tokens_match(addr, c[3])]
    if named:
        dist, plat, plon, tokens, _rank = named[0]  # ближайшая среди совпавших
        if dist <= max_shift:
            road = " ".join(sorted(tokens))
            return (plat, plon, f"name-match «{road}» ({dist:.0f} м)", tokens, dist)
        return None  # имя нашли, но слишком далеко — подозрительно, не двигаем

    # Имя не совпало (адрес без улицы / улицы нет рядом в OSM). Доверяем геометрии
    # только если камера и так почти на дороге — смещение мало и безопасно.
    dist, plat, plon, tokens, _rank = cands[0]
    if dist <= trust_geom:
        return (plat, plon, f"already-on-road ({dist:.0f} м)", tokens, dist)
    return None


# --- Основной проход ---------------------------------------------------------

def snap_all(cameras, index, *, radius, max_shift, trust_geom):
    snapped = kept = 0
    total_shift = 0.0
    result, moves, report = [], [], []
    for cam in cameras:
        out = dict(cam)
        choice = choose_snap(cam, index, radius=radius, max_shift=max_shift,
                             trust_geom=trust_geom)
        if choice:
            lat, lon, reason, _tokens, shift = choice
            out["lat"], out["lon"] = round(lat, 6), round(lon, 6)
            out.pop("needsReview", None)
            snapped += 1
            total_shift += shift
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
    return result, snapped, kept, total_shift, moves, report


def _round_lat(m):  # метры → доли градуса широты (для самотеста)
    return m / _M_PER_DEG_LAT


def selftest():
    ok = True

    def check(cond, label):
        nonlocal ok
        print(f"  [{'ok ' if cond else 'FAIL'}] {label}")
        ok = ok and cond

    # 1) Матчинг имён с транслитом.
    check(tokens_match(street_tokens("A.navoiy ko'chasi 30"),
                       street_tokens("Alisher Navoiy ko'chasi")), "navoiy ~ Navoiy")
    check(tokens_match(street_tokens("Навои проспекти"),
                       street_tokens("Navoiy ko'chasi")), "кир. Навои ~ лат. Navoiy")
    check(tokens_match(street_tokens("Сақчимон кўчаси"),
                       street_tokens("Saqchimon ko'chasi")), "кир. Сақчимон ~ Saqchimon")
    check(not tokens_match(street_tokens("Istiqlol ko'chasi"),
                           street_tokens("Sharof Rashidov ko'chasi")), "разные улицы не матчатся")

    # 2) Ловушка параллельной улицы: камера ближе к боковой, но адрес — Navoiy.
    index = RoadIndex()
    A = 41.3110      # «Navoiy ko'chasi» (главная)
    B = A - _round_lat(40)   # «Saqchimon ko'chasi» параллельно в 40 м
    index.add_linestring([[69.2800, A], [69.2820, A]], street_tokens("Navoiy ko'chasi"), 5)
    index.add_linestring([[69.2800, B], [69.2820, B]], street_tokens("Saqchimon ko'chasi"), 2)
    cam = {"id": 1, "lat": A - _round_lat(26), "lon": 69.2810,  # 26 м от A, 14 м от B
           "location": "Navoiy ko'chasi 30"}
    res = choose_snap(cam, index, radius=100, max_shift=80, trust_geom=10)
    check(res is not None, "камера с адресом Navoiy снапится")
    if res:
        d_to_A = abs(res[0] - A) * _M_PER_DEG_LAT
        d_to_B = abs(res[0] - B) * _M_PER_DEG_LAT
        check(d_to_A < 3 and d_to_B > 30,
              f"снап на Navoiy, не на параллельную ({d_to_A:.0f} м до A, {d_to_B:.0f} м до B)")

    # 3) Нет совпадения по имени и далеко от дорог → needsReview (None).
    cam_far = {"id": 2, "lat": A - _round_lat(70), "lon": 69.2810,
               "location": "Nomalum ko'chasi"}
    check(choose_snap(cam_far, index, radius=100, max_shift=80, trust_geom=10) is None,
          "далёкая камера без совпадения имени → needsReview")

    # 4) Почти на дороге (8 м), имя не совпало → доверяем геометрии.
    cam_close = {"id": 3, "lat": A - _round_lat(8), "lon": 69.2810, "location": ""}
    check(choose_snap(cam_close, index, radius=100, max_shift=80, trust_geom=10) is not None,
          "камера в 8 м от дороги снапится по геометрии")

    print("selftest:", "PASSED" if ok else "FAILED")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Snap camera coordinates to named OSM roads")
    ap.add_argument("--roads", help="GeoJSON(seq) именованных дорог (из osmium export)")
    ap.add_argument("--in", dest="inp", default="cameras.json")
    ap.add_argument("--out", dest="out", default="cameras.snapped.json")
    ap.add_argument("--report", default="snap_report.csv")
    ap.add_argument("--moves", default="snap_moves.geojson")
    ap.add_argument("--radius", type=float, default=100.0, help="радиус поиска дорог, м")
    ap.add_argument("--max-shift", type=float, default=80.0,
                    help="макс. перенос при совпадении имени, м")
    ap.add_argument("--trust-geom", type=float, default=10.0,
                    help="если камера ближе этого к дороге — снап без имени, м")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.roads:
        print("нужен --roads roads.geojsonl (подготовит snap_cameras.sh через osmium)",
              file=sys.stderr)
        return 2

    print(f"загрузка дорог: {args.roads} …")
    index, named = load_roads(args.roads)
    print(f"  отрезков: {index.count}, из них с именами: {named}")

    cameras = json.load(open(args.inp, encoding="utf-8"))
    print(f"камер: {len(cameras)} · radius {args.radius:.0f} м · "
          f"max-shift {args.max_shift:.0f} м · trust-geom {args.trust_geom:.0f} м\n")

    result, snapped, kept, total_shift, moves, report = snap_all(
        cameras, index, radius=args.radius, max_shift=args.max_shift,
        trust_geom=args.trust_geom)

    json.dump(result, open(args.out, "w", encoding="utf-8"), ensure_ascii=False)
    with open(args.report, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "shift_m", "reason", "location"])
        w.writerows(sorted(report, key=lambda r: -r[1]))
    json.dump({"type": "FeatureCollection", "features": moves},
              open(args.moves, "w", encoding="utf-8"), ensure_ascii=False)

    avg = (total_shift / snapped) if snapped else 0
    print(f"итог: перенесено {snapped}, оставлено+needsReview {kept}")
    print(f"средний перенос: {avg:.1f} м")
    print(f"отчёт: {args.report} · переносы (GeoJSON): {args.moves} · база: {args.out}")
    print("\nдалее: открыть snap_moves.geojson в geojson.io и глазами проверить,")
    print("что камеры не прыгнули на чужие дороги; затем заменить живую базу и")
    print("поднять version.json (OTA раздаст обновление приложению).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
