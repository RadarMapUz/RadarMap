#!/usr/bin/env python3
"""append_registry.py — новые камеры свежего реестра МВД в КОНЕЦ базы (28.I, v13).

Путь v11/v12 одним инструментом: реестр (вывод update_cameras.build) против
боевой базы → новые места дописываются с id после максимального, профиль
дороги каждой новой выводится кодом снапа (snap_cameras.apply_road_profile) по
вырезке OSM вокруг неё, twin — по всей базе, но пишется только туда, где пару
образовала новая камера. Прежние записи остаются байт-в-байт (verify).

Чем отличается от merge_cameras.py. Тот сопоставляет по одному расстоянию
(200 м), и на реестре 23.10 это неверно в обе стороны:
  * камеры у школ и базаров, которые МВД ставит в 100–200 м от уже известного
    перекрёстка, — другие камеры (другой адрес, а камеру перекрёстка реестр
    держит отдельной строкой рядом с нашей точкой). Порог 200 м их глотал —
    это молчание о настоящей камере;
  * наша камера, снапнутая на ось дороги, бывает в 60–150 м от своей строки
    реестра (снап двигает до 80 м по имени и до 150 м по номеру трассы), а
    реестр к тому же переписывает адрес одной буквой («Shaharchasi» /
    «Shaxarchasi»). По одному расстоянию 30 м это дубль.
Поэтому сопоставление идёт по адресу, а не только по метрам (classify):
  same        — точка базы ближе SAME_M: та же камера;
  same_addr   — тот же адрес (с точностью до транслита и опечатки) у камеры
                базы в ADDR_M: та же камера, координата сдвинута (дальше
                ADDR_REVIEW_M — в отчёт для «Положения»: одна из двух точек
                неверна, какая — решает человек);
  collapse    — ближе COLLAPSE_M к камере базы: для водителя это одно место
                (реестр держит по строке на каждое направление развязки);
  likely_same — ближайшая камера базы в LIKELY_M осталась без своей строки
                реестра и стоит на той же дороге: скорее всего это она же с
                новой координатой — не дописываем, в отчёт;
  new         — всё остальное; между собой новые схлопываются в COLLAPSE_M.

Профиль новой камеры — только по доказательству (choose_profile). Правило
асимметричное, как у всего конвейера: доверенный неверный профиль ГЛУШИТ
камеру (гейт оси, «не наша дорога»), а needsReview только шумит — коридор
трассы и профиль, который глушить не вправе (Camera.profileMayMute). Отсюда:
  1. номер трассы из адреса (D105, A373, 40V114, Txay=D001 — разбор 14.11)
     совпал с проезжей частью в MAX_SHIFT_REF — она; перекрёсток двух трасс
     под разными осями — needsReview;
  2. иначе адрес — перекрёсток улиц без номера — needsReview: какую из улиц
     снимает камера, адрес не говорит;
  3. иначе имя улицы совпало в MAX_SHIFT (магистраль предпочтительнее);
  4. иначе геометрия: камера уже на дороге (порог по классу, как у снапа), и
     рядом нет проезжей части иного направления.
Тротуары, тропы и платформы в индекс не попадают (урок 11.3: 39 камер v10
сели на тротуар). Не доказано — координата реестра как есть, needsReview,
без профиля: выдуманный профиль хуже никакого.

Камеры базы, которых реестр больше не знает, НЕ удаляются — исчезновение
строки не доказывает, что камеры нет на дороге, а молчание там, где она стоит,
хуже лишнего предупреждения. Их список — CSV для модерации (--report-gone).

Запуск (ничего не публикует; без --apply только показывает):
  python3 server/append_registry.py --base RadarMap/Resources/cameras.json \\
      --registry candidate.json --roads ~/RadarMapBuild/roads.geojsonl \\
      --report-new server/review/cameras_v13_new_2026-10-23.csv \\
      --report-gone server/review/cameras_gone_2026-10-23.csv [--apply]
Дальше: AppConfig.bundledDBVersion, тесты, deploy_db.sh <версия> — владелец.
Тесты: python3 -W ignore -m unittest test_append_registry
"""
import argparse
import collections
import copy
import csv
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge_cameras as mc       # noqa: E402  чтение реестра, инварианты id, типы
import resnap_profiles as rp     # noqa: E402  разбор адреса (14.11), проезжие части
import snap_cameras as snap      # noqa: E402  индекс дорог и профиль
import update_cameras as uc      # noqa: E402  нормализация адресов реестра

# --- Сопоставление реестра с базой --------------------------------------------

#: Ближе — та же точка: 2960 из 3233 строк реестра 23.10 лежат в 30 м от
#: камеры базы (снап двигает точку на несколько метров к оси).
SAME_M = 30.0
#: Ближе — одно место для водителя (строки по направлениям одной развязки).
#: Тот же порог схлопывает новые между собой — как DEDUP_METERS v12.
COLLAPSE_M = 50.0
#: В этом радиусе ищем камеру базы с тем же адресом.
ADDR_M = 1500.0
#: Тот же адрес дальше этого — одна из двух координат неверна: в отчёт.
ADDR_REVIEW_M = 150.0
#: «Осиротевшая» камера базы ближе этого и на той же дороге — скорее она же.
LIKELY_M = 200.0
#: Камера базы без строки реестра в этом радиусе — «пропала из реестра».
GONE_M = 150.0
#: Строже любой проверки выше: после снапа новая не ближе этого к любой другой.
DUP_M = 30.0

#: Слова адреса, которые не называют дорогу (для share_road).
_GENERIC = frozenset((
    "kochasi", "kochalari", "kocha", "kesishmasi", "kesishgan", "chorrahasi",
    "chorraha", "chorrahha", "tutashmasi", "yolining", "yoli", "yol",
    "avtomobil", "oldi", "oldida", "oldidagi", "qarshisi", "qarshisida",
    "roparasi", "ruparasi", "uy", "va", "km", "mfy", "oraligi", "aholi",
    "punkti", "maktab", "maktabi", "bekati", "bozori", "bozor", "dehqon",
    "shahar", "shahri", "shaharchasi", "tuman", "tumani", "markazi", "kirish",
    "qismi", "sonli", "son", "piyodalar", "otish", "joyi", "street", "ulisa",
))
_APOSTROPHES = re.compile(r"[ʻ‘’'`ʼ“”\"«»]")


def _fold(text):
    """Адрес → латиница нижним регистром без апострофов; x ≡ h (реестр пишет
    «Chorraxa»/«Chorraha», «Boburshox»/«Boburshoh» вперемешку)."""
    text = uc.smart(text or "").translate(uc.HOMOGLYPHS).lower()
    text = _APOSTROPHES.sub("", snap.translit(text))
    return text.replace("x", "h")


def _tokens(text):
    return {t for t in re.split(r"[^0-9a-z]+", _fold(text)) if t}


def _token_eq(a, b):
    return a == b or (len(a) >= 5 and len(b) >= 5 and snap._damerau1(a, b))


def addr_same(a, b):
    """Один ли это адрес: те же номера (дом, км, школа) и почти те же слова."""
    if re.sub(r"[^0-9a-z]", "", _fold(a)) == re.sub(r"[^0-9a-z]", "", _fold(b)):
        return True
    ta, tb = _tokens(a), _tokens(b)
    if {t for t in ta if any(ch.isdigit() for ch in t)} != \
            {t for t in tb if any(ch.isdigit() for ch in t)}:
        return False
    common = sum(1 for x in ta if any(_token_eq(x, y) for y in tb))
    union = len(ta | tb) - common
    return union > 0 and common / union >= 0.75


def share_road(a, b):
    """Называют ли два адреса одну дорогу: общий номер трассы, а без номеров —
    общее значимое слово (имя улицы)."""
    ra = {m.ref for m in snap.highway_refs_in_text(a or "")}
    rb = {m.ref for m in snap.highway_refs_in_text(b or "")}
    if ra and rb:
        return bool(ra & rb)

    def names(text):
        return {t for t in _tokens(text)
                if len(t) >= 4 and t not in _GENERIC and not any(ch.isdigit() for ch in t)}
    na, nb = names(a), names(b)
    return any(_token_eq(x, y) for x in na for y in nb)


PRIORITY = {"Интеллектуал + радар": 3, "Стационар камера": 2, "Стационар радар": 1}

Match = collections.namedtuple("Match", "row cls base dist note")


class _Grid:
    """Сетка 0.01° (≈ 1 км) для «что рядом»."""

    def __init__(self, points):
        self.cells = collections.defaultdict(list)
        for p in points:
            self.cells[(int(p["lat"] / 0.01), int(p["lon"] / 0.01))].append(p)

    def around(self, lat, lon, reach=2):
        ci, cj = int(lat / 0.01), int(lon / 0.01)
        for di in range(-reach, reach + 1):
            for dj in range(-reach, reach + 1):
                yield from self.cells.get((ci + di, cj + dj), ())


def _dist(a, b):
    return mc.meters(a["lat"], a["lon"], b["lat"], b["lon"])


def classify(base, source):
    """Чистая функция. → ([Match по строке реестра], [(камера базы, м до
    ближайшей строки реестра)] — пропавшие). Классы — в шапке файла."""
    grid = _Grid(base)
    out = []
    for row in source:
        near = sorted(((_dist(row, c), c) for c in grid.around(row["lat"], row["lon"])),
                      key=lambda x: x[0])
        dist, cam = near[0] if near else (float("inf"), None)
        if dist <= SAME_M:
            out.append(Match(row, "same", cam, dist, ""))
            continue
        twin = next(((d, c) for d, c in near
                     if d <= ADDR_M and addr_same(row["location"], c["location"])), None)
        if twin:
            out.append(Match(row, "same_addr", twin[1], twin[0],
                             "тот же адрес, координата реестра в %.0f м" % twin[0]))
        elif dist <= COLLAPSE_M:
            out.append(Match(row, "collapse", cam, dist,
                             "в %.0f м от камеры базы — одно место" % dist))
        else:
            out.append(Match(row, "new", cam, dist, ""))

    claimed = {m.base["id"] for m in out if m.cls != "new"}
    final = []
    for m in out:
        if (m.cls == "new" and m.dist <= LIKELY_M and m.base["id"] not in claimed
                and share_road(m.row["location"], m.base["location"])):
            claimed.add(m.base["id"])
            m = m._replace(cls="likely_same", note=(
                "камера базы в %.0f м без своей строки реестра, та же дорога — "
                "скорее она же с новой координатой" % m.dist))
        final.append(m)

    # Дубли реестра между новыми: одна точка на COLLAPSE_M, тип — старший.
    order = sorted((i for i, m in enumerate(final) if m.cls == "new"),
                   key=lambda i: (-PRIORITY.get(final[i].row["type"], 0), i))
    kept = []
    for i in order:
        hit = next((k for k in kept if _dist(final[i].row, final[k].row) <= COLLAPSE_M), None)
        if hit is None:
            kept.append(i)
        else:
            final[i] = final[i]._replace(cls="dup_new", note=(
                "дубль новой строки реестра в %.0f м" % _dist(final[i].row, final[hit].row)))

    rgrid = _Grid(source)
    gone = []
    for cam in base:
        dmin = min((_dist(cam, r) for r in rgrid.around(cam["lat"], cam["lon"])),
                   default=None)
        if dmin is None:
            dmin = min(_dist(cam, r) for r in source)
        if dmin > GONE_M and cam["id"] not in claimed:
            gone.append((cam, dmin))
    return final, gone


# --- Профиль новой камеры -----------------------------------------------------

#: Как у полного снапа (snap_cameras.main): радиус поиска и потолки переноса.
RADIUS_M = 160.0
MAX_SHIFT_M = 80.0
MAX_SHIFT_REF_M = 150.0
TRUST_GEOM_M = 10.0

Choice = collections.namedtuple("Choice", "cand how note")


def _where(index, c):
    return "%s ось %s в %.0f м" % (index.attrs[c.way].cls, c.axis, c.dist)


def choose_profile(cam, index):
    """→ Choice. cand None — профиль не писать, how/note объясняют почему."""
    location = cam.get("location", "")
    roads = rp.address_roads(location)
    cands = [c for c in rp.per_way(index.nearby(cam["lat"], cam["lon"], RADIUS_M))
             if c.axis is not None]
    if not cands:
        return Choice(None, "no_road", "нет проезжей части в %.0f м" % RADIUS_M)
    main = [c for c in cands if not rp.is_link(index.attrs[c.way].cls)]

    if roads.highways:
        hws = roads.highways if (len(roads.highways) >= 2 and roads.junction) \
            else roads.highways[:1]
        picks = []
        for hw in hws:
            found = [c for c in main if rp._carries(hw, c) and c.dist <= MAX_SHIFT_REF_M]
            if found:
                picks.append((hw, found[0], found))
        if not picks:
            hw = hws[0]
            far = [c for c in rp.per_way(index.nearby(cam["lat"], cam["lon"], 400.0))
                   if rp._carries(hw, c)]
            return Choice(None, "ref_not_found", "%s в %.0f м нет%s" % (
                hw.label, MAX_SHIFT_REF_M,
                "; ближайшая — " + _where(index, far[0]) if far else "; нет и в 400 м"))
        if len(hws) >= 2:
            if len(picks) < len(hws):
                return Choice(None, "junction", "перекрёсток трасс %s, найдена одна: %s" % (
                    " × ".join(h.label for h in hws), _where(index, picks[0][1])))
            for hw, c, _ in picks[1:]:
                if rp._axis_delta(c.axis, picks[0][1].axis) > rp.AMBIGUITY_ANGLE:
                    return Choice(None, "junction", "перекрёсток трасс: %s — %s, %s — %s" % (
                        picks[0][0].label, _where(index, picks[0][1]),
                        hw.label, _where(index, c)))
        hw, pick, found = min(picks, key=lambda p: p[1].dist)
        conflict = rp._same_road_conflict(pick, found)
        if conflict is not None:
            return Choice(None, "ambiguous", "%s под двумя осями: %s и %s" % (
                hw.label, _where(index, pick), _where(index, conflict)))
        return Choice(pick, "ref", "%s: %s" % (hw.label, _where(index, pick)))

    if roads.junction:
        return Choice(None, "junction",
                      "перекрёсток улиц без номера трассы — какую снимает камера, "
                      "адрес не говорит")

    tokens = snap.street_tokens(location)
    named = [c for c in cands if snap.tokens_match(tokens, c.tokens)]
    if named:
        pick = ([c for c in named if c.rank >= 3] or named)[0]
        if pick.dist > MAX_SHIFT_M:
            return Choice(None, "name_far", "улица из адреса в %.0f м — дальше %.0f" % (
                pick.dist, MAX_SHIFT_M))
        conflict = rp._same_road_conflict(pick, named)
        if conflict is not None:
            return Choice(None, "ambiguous", "по имени две оси: %s и %s" % (
                _where(index, pick), _where(index, conflict)))
        return Choice(pick, "name", "%s: %s" % (" ".join(sorted(pick.tokens)),
                                                _where(index, pick)))

    pick = cands[0]
    major = [c for c in cands if c.rank >= 3]
    if major and major[0].dist <= pick.dist + rp.MAJOR_MARGIN_M:
        pick = major[0]
    limit = snap._trust_for_rank(pick.rank, TRUST_GEOM_M)
    if pick.dist > limit:
        return Choice(None, "far", "ближайшая %s, порог %.0f м, имя и номер не совпали" % (
            _where(index, pick), limit))
    if pick.rank < 3 and major:
        return Choice(None, "ambiguous", "%s, но рядом %s" % (
            _where(index, pick), _where(index, major[0])))
    for other in cands:
        if other.way == pick.way or other.dist > pick.dist + rp.AMBIGUITY_MARGIN_M:
            continue
        if other.rank < min(pick.rank, rp.AMBIGUITY_MIN_RANK):
            continue
        if rp._axis_delta(other.axis, pick.axis) > rp.AMBIGUITY_ANGLE:
            return Choice(None, "ambiguous", "перекрёсток без имени: %s и %s" % (
                _where(index, pick), _where(index, other)))
    return Choice(pick, "geometry", _where(index, pick))


# --- Сборка -------------------------------------------------------------------

def new_record(ident, row, index, choice):
    """Запись новой камеры: поля в порядке базы, профиль — кодом снапа."""
    out = {"id": ident, "region": row["region"], "city": row["city"],
           "location": row["location"], "lat": row["lat"], "lon": row["lon"],
           "type": row["type"]}
    if choice.cand is None:
        out["needsReview"] = True
        return out
    out["lat"] = round(choice.cand.plat, 6)
    out["lon"] = round(choice.cand.plon, 6)
    out["axis"] = choice.cand.axis
    snap.apply_road_profile(out, index, choice.cand)
    return out


def twin_ids(cameras):
    """id камер, которым mark_direction_twins дал бы twin (на копии)."""
    scratch = copy.deepcopy(cameras)
    snap.mark_direction_twins(scratch)
    return {c["id"] for c in scratch if c.get("twin")}


def build(base, fresh, index, *, first_id=None):
    """Чистая часть. fresh — строки реестра (Match.row) к дописыванию.

    → (результат, строки отчёта, id старых камер, получивших twin).
    Порядок fresh задаёт порядок id; дубль после снапа (ближе DUP_M к любой
    камере) не дописывается и уходит в отчёт.
    """
    ident = first_id if first_id is not None else mc.next_id(base)
    result = list(base)
    rows = []
    grid = _Grid(base)
    added = []
    for row in fresh:
        choice = choose_profile(row, index)
        rec = new_record(ident, row, index, choice)
        clash = [c for c in list(grid.around(rec["lat"], rec["lon"], 1)) + added
                 if _dist(rec, c) <= DUP_M]
        if clash:
            rows.append({"row": row, "id": "", "status": "дубль после снапа",
                         "how": choice.how, "note": "в %.0f м от id %s" % (
                             _dist(rec, clash[0]), clash[0]["id"]), "rec": rec})
            continue
        added.append(rec)
        result.append(rec)
        rows.append({"row": row, "id": ident,
                     "status": "профиль" if choice.cand else "needsReview",
                     "how": choice.how, "note": choice.note, "rec": rec})
        ident += 1

    before, after = twin_ids(base), twin_ids(result)
    new_ids = {c["id"] for c in added}
    for rec in added:
        if rec["id"] in after:
            rec["twin"] = True
    old_partners = set()
    for i, cam in enumerate(base):
        if cam["id"] in after and cam["id"] not in before and not cam.get("twin"):
            fixed = dict(cam)
            fixed["twin"] = True
            result[i] = fixed
            old_partners.add(cam["id"])
    for r in rows:
        if r["id"] in new_ids and r["rec"].get("twin"):
            r["note"] += "; пара обратного направления в 100 м (twin)"
    return result, rows, old_partners


def verify(base, result, first_id, twin_partners):
    """Инварианты перед записью. → (ok, почему)."""
    ok, why = mc.verify(base, result)
    if not ok:
        return ok, why
    for old, new in zip(base, result):
        if old == new:
            continue
        if old["id"] not in twin_partners:
            return False, "камера %d базы изменилась" % old["id"]
        if {k: v for k, v in new.items() if k != "twin"} != old or new.get("twin") is not True \
                or list(new)[:-1] != list(old):
            return False, "у камеры %d изменилось не только twin" % old["id"]
    fresh = result[len(base):]
    if [c["id"] for c in fresh] != list(range(first_id, first_id + len(fresh))):
        return False, "новые id не подряд с %d" % first_id
    allowed = {"id", "region", "city", "location", "lat", "lon", "type", "needsReview",
               *rp.PROFILE_KEYS}
    for cam in fresh:
        extra = set(cam) - allowed
        if extra:
            return False, "у новой камеры %d лишние поля %s" % (cam["id"], sorted(extra))
        if "violations" in cam:
            return False, "violations восстанавливаются по типу, в базе им не место"
        if not (37 <= cam["lat"] <= 46 and 55 <= cam["lon"] <= 74):
            return False, "камера %d вне Узбекистана" % cam["id"]
        if cam.get("needsReview") and any(k in cam for k in rp.PROFILE_KEYS):
            return False, "камера %d: needsReview с профилем" % cam["id"]
    grid = _Grid(result)
    for cam in fresh:
        for other in grid.around(cam["lat"], cam["lon"], 1):
            if other["id"] != cam["id"] and _dist(cam, other) <= DUP_M:
                return False, "камера %d в %.0f м от %d" % (
                    cam["id"], _dist(cam, other), other["id"])
    return True, "прежние %d записей на месте, twin добавлен %d; новых %d (id %d–%d)" % (
        len(base), len(twin_partners), len(fresh), first_id, first_id + len(fresh) - 1)


# --- Ввод/вывод ---------------------------------------------------------------

def clip_roads(path, points, out_path, *, cell=0.03):
    """Вырезка OSM вокруг точек: линии с вершиной в клетке точки или соседней
    (клетка 0.03° ≈ 3 км — с запасом на радиус поиска и разделённую дорогу)."""
    cells = set()
    for p in points:
        ci, cj = int(p["lat"] / cell), int(p["lon"] / cell)
        cells.update((ci + di, cj + dj) for di in (-1, 0, 1) for dj in (-1, 0, 1))
    kept = 0
    with open(path, encoding="utf-8") as src, open(out_path, "w", encoding="utf-8") as dst:
        for line in src:
            text = line.strip().lstrip("\x1e").strip()
            if not text:
                continue
            try:
                feat = json.loads(text)
            except json.JSONDecodeError:
                continue
            geom = feat.get("geometry") or {}
            if geom.get("type") != "LineString":
                continue
            if any((int(lat / cell), int(lon / cell)) in cells
                   for lon, lat in geom.get("coordinates") or []):
                dst.write(text + "\n")
                kept += 1
    return kept


def load_index(roads_path):
    """Только проезжие части; номера дорог — разбором 14.11 (D105, 40V114…)."""
    index, _, _ = snap.load_roads(roads_path, keep_highway=rp.is_carriageway,
                                  refs_of=snap.highway_refs_from_props)
    return index


NEW_FIELDS = ("статус", "id", "как", "почему", "тип", "регион", "город", "адрес",
              "lat_реестра", "lon_реестра", "lat", "lon", "cls", "axis", "dir", "twin",
              "камера_базы", "до_неё_м")
GONE_FIELDS = ("id", "тип", "регион", "город", "адрес", "lat", "lon",
               "до_реестра_м", "в_списке_20_10", "needsReview", "cls", "dir",
               "близнец_в_базе_60м")


def write_new_report(path, rows, matches):
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(NEW_FIELDS)
        for r in rows:
            row, rec = r["row"], r["rec"]
            w.writerow([r["status"], r["id"], r["how"], r["note"], row["type"], row["region"],
                        row["city"], row["location"], row["lat"], row["lon"],
                        rec["lat"], rec["lon"], rec.get("cls", ""), rec.get("axis", ""),
                        rec.get("dir", ""), "да" if rec.get("twin") else "", "", ""])
        labels = {"same_addr": "та же камера, координата другая",
                  "likely_same": "скорее та же камера",
                  "dup_new": "дубль строки реестра", "collapse": "одно место с камерой базы"}
        for m in matches:
            if m.cls in ("likely_same", "dup_new") or (
                    m.cls == "same_addr" and m.dist > ADDR_REVIEW_M):
                w.writerow([labels[m.cls], "", "", m.note, m.row["type"], m.row["region"],
                            m.row["city"], m.row["location"], m.row["lat"], m.row["lon"],
                            "", "", "", "", "", "", m.base["id"] if m.base else "",
                            "%.0f" % m.dist])


def write_gone_report(path, gone, base, previous=frozenset()):
    grid = _Grid(base)
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(GONE_FIELDS)
        for cam, dist in sorted(gone, key=lambda g: g[0]["id"]):
            twins = [o["id"] for o in grid.around(cam["lat"], cam["lon"], 1)
                     if o["id"] != cam["id"] and _dist(o, cam) < 60]
            w.writerow([cam["id"], cam["type"], cam["region"], cam["city"], cam["location"],
                        cam["lat"], cam["lon"], "%.0f" % dist,
                        "да" if cam["id"] in previous else "",
                        "да" if cam.get("needsReview") else "", cam.get("cls", ""),
                        cam.get("dir", ""), ";".join(map(str, sorted(twins)))])


def _previous_gone(path):
    if not path or not os.path.exists(path):
        return frozenset()
    with open(path, encoding="utf-8") as f:
        return frozenset(int(r["id_базы"]) for r in csv.DictReader(f)
                         if r.get("что") == "нет в реестре" and r.get("id_базы"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", required=True)
    ap.add_argument("--registry", required=True, help="вывод update_cameras.build(fetch())")
    ap.add_argument("--roads", required=True, help="roads.geojsonl (osmium export)")
    ap.add_argument("--report-new", required=True)
    ap.add_argument("--report-gone", required=True)
    ap.add_argument("--previous-diff", help="registry_diff_*.csv прошлой сверки")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    with open(args.base, encoding="utf-8") as f:
        base = json.load(f)
    with open(args.registry, encoding="utf-8") as f:
        source = mc.read_source(json.load(f))
    if len(source) < mc.MIN_SOURCE_ROWS:
        print("ОТКАЗ: в реестре всего %d строк — источник сломан" % len(source))
        return 1

    matches, gone = classify(base, source)
    counts = collections.Counter(m.cls for m in matches)
    print("база: %d, реестр: %d → %s" % (len(base), len(source), dict(counts)))
    fresh = [m.row for m in matches if m.cls == "new"]
    if len(fresh) > mc.MAX_NEW_AT_ONCE:
        print("ОТКАЗ: %d новых за раз — промах сопоставления" % len(fresh))
        return 1
    # Порядок id: регион, город, адрес — как читает человек.
    fresh.sort(key=lambda r: (r["region"], r["city"], r["location"], r["lat"], r["lon"]))

    with tempfile.TemporaryDirectory() as tmp:
        clip = os.path.join(tmp, "roads_clip.geojsonl")
        kept = clip_roads(args.roads, fresh, clip)
        print("вырезка OSM вокруг новых: %d линий" % kept)
        index = load_index(clip)

    first_id = mc.next_id(base)
    result, rows, partners = build(base, fresh, index, first_id=first_id)
    ok, why = verify(base, result, first_id, partners)
    print("проверка: %s" % why)
    write_new_report(args.report_new, rows, matches)
    write_gone_report(args.report_gone, gone, base, _previous_gone(args.previous_diff))
    status = collections.Counter(r["status"] for r in rows)
    print("новые: %s; twin старым: %s" % (dict(status), sorted(partners)))
    print("пропали из реестра: %d → %s" % (len(gone), args.report_gone))
    if not ok:
        print("ОТКАЗ: база не тронута")
        return 1
    if not args.apply:
        print("(показ без записи; повторите с --apply)")
        return 0
    tmp = args.base + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, args.base)
    print("записано: %d камер (было %d)" % (len(result), len(base)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
