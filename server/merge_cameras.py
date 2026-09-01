#!/usr/bin/env python3
"""Слияние свежего реестра МВД с боевой базой камер — БЕЗ перенумерации.

Зачем отдельный инструмент, если есть update_cameras.py. Тот собирает
КАНДИДАТА с нуля и в конце делает вот это:

    cams = sorted(points.values(), key=lambda r: (region, city, location, ...))
    for i, c in enumerate(cams, 1): c["id"] = i

То есть выдаёт базу, где id розданы заново по алфавиту. Слить такую с боевой
нельзя ни при каких условиях, и это не придирка к стилю:

  * id камеры лежит в ПОЛЬЗОВАТЕЛЬСКИХ данных — в проездах истории, в списке
    «своих» камер, в скрытых и в переопределениях. Перенумерация переклеила бы
    чужие проезды на чужие камеры: человек открыл бы историю и увидел, что
    ехал мимо камеры, которой там нет.
  * кандидат несёт только семь полей. У боевой базы их шестнадцать: axis, dir,
    split, cls, road, lanes, twin, bridge — это результат снапа на ось дороги,
    он считается отдельным тяжёлым проходом. Слить кандидата поверх значило бы
    стереть геометрию у 3463 камер из 3475.

Поэтому здесь всё наоборот: истина по id и по геометрии — БОЕВАЯ база, а
реестр только добавляет то, чего в ней нет. Существующие записи не двигаются
вообще; новые получают id, продолжающие нумерацию, и никогда не занимают
дыры от удалённых камер — за дырой может стоять чужая история.

Запуск:
    python3 merge_cameras.py --base RadarMap/Resources/cameras.json \\
                             --source свежий_реестр.json [--apply]
Без --apply только показывает, что бы сделал.
"""
import argparse
import json
import math
import os
import sys

# Причёсывание КАПСА берём из update_cameras.py, а не копией: реестр пишет
# адреса заглавными («QIZGʻALDOQ MFY HUDUDIDAGI»), а в базе они человеческие.
# Две копии одного словаря исключений разъедутся на первой же правке, и часть
# базы окажется причёсана одним набором правил, часть — другим.
try:
    from update_cameras import smart as _smart
except ImportError:          # автономный запуск без соседнего модуля
    def _smart(value):
        return " ".join(value.split())

# Ближе этого считаем, что реестр говорит о ТОЙ ЖЕ камере, что уже есть.
# Двести метров — с запасом: у одной развязки реестр держит несколько строк
# с разбросом в десятки метров, и все они об одном месте для водителя.
MATCH_METERS = 200.0
# Тот же порог между самими новыми точками: реестр содержит собственные дубли
# (одна и та же камера тремя строками, различающимися символом апострофа).
DEDUP_METERS = 50.0
# Меньше этого в реестре — источник сломан, сливать нечего.
MIN_SOURCE_ROWS = 3000
# Больше этого новых за раз — что-то не так с сопоставлением; требуем явного
# подтверждения человеком, а не молча удваиваем базу.
MAX_NEW_AT_ONCE = 300

TYPE_MAP = {
    "Statsionar kamera": "Стационар камера",
    "Statsionar radar": "Стационар радар",
    "Intellektual + radar": "Интеллектуал + радар",
}
# Ровно эти строки понимает CameraType.init(raw:). Незнакомая падает в
# `.other` — камера остаётся в базе, но ИСЧЕЗАЕТ С КАРТЫ у всех, кто включил
# фильтр «Камеры» или «Радары». Молчание о настоящей камере хуже лишнего
# предупреждения, поэтому строку, которую приложение не знает, не ввозим вовсе.
KNOWN_TYPES = set(TYPE_MAP.values())

# Потолок id стационарной базы. Выше начинаются пространства, где владельца
# точки определяют ПО ЗНАЧЕНИЮ id, а не по флагу: с 1 000 001 — камеры,
# поставленные рукой (CameraRepository.firstCustomID), с 2 000 000 — отметки
# водителей (MobileCameraService.idOffset). Заехать туда значит выдать чужую
# камеру за свою.
MAX_BASE_ID = 1_000_000


def meters(lat1, lon1, lat2, lon2):
    return math.hypot((lat1 - lat2) * 111320.0,
                      (lon1 - lon2) * 111320.0 * math.cos(math.radians(lat1)))


def _num(value):
    try:
        return float(str(value).strip().replace(",", "."))
    except (TypeError, ValueError):
        return None


def read_source(rows):
    """Строки реестра → [{lat, lon, type, region, city, location}].

    Принимает и сырую выгрузку egov (поля Kenglik/Uzunlik/Turi/...), и уже
    нормализованного кандидата update_cameras.py (lat/lon/type/...).
    """
    out = []
    unknown = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        raw_region = r.get("Viloyat") or r.get("region") or ""
        # Первая строка выгрузки — заголовки колонок, а не данные.
        if raw_region.startswith("Viloyat"):
            continue
        lat = _num(r.get("Kenglik", r.get("lat")))
        lon = _num(r.get("Uzunlik", r.get("lon")))
        if lat is None or lon is None:
            continue
        if not (37 <= lat <= 46 and 55 <= lon <= 74):
            continue
        raw_type = (r.get("Turi") or r.get("type") or "").strip()
        kind = TYPE_MAP.get(raw_type, raw_type)
        if kind not in KNOWN_TYPES:
            unknown.append(raw_type)
            continue
        out.append({
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "type": kind,
            # Регион берём как есть: строки реестра совпадают с нашими дословно,
            # включая букву ʻ. Район и адрес приходят заглавными — причёсываем.
            "region": raw_region.split("/")[0].strip(),
            "city": _smart((r.get("Tuman") or r.get("city") or "").strip()),
            "location": _smart((r.get("Joylashganjoyi") or r.get("location") or "").strip()),
        })
    if unknown:
        counts = {}
        for t in unknown:
            counts[t] = counts.get(t, 0) + 1
        print("пропущено строк с незнакомым типом: %d %s" % (len(unknown), counts))
    return out


def _grid(points):
    cells = {}
    for i, p in enumerate(points):
        cells.setdefault((round(p["lat"], 2), round(p["lon"], 2)), []).append(i)
    return cells


def _nearest(cells, points, lat, lon):
    best = None
    for dlat in (-0.01, 0, 0.01):
        for dlon in (-0.01, 0, 0.01):
            for i in cells.get((round(lat + dlat, 2), round(lon + dlon, 2)), []):
                d = meters(lat, lon, points[i]["lat"], points[i]["lon"])
                if best is None or d < best[0]:
                    best = (d, i)
    return best


def plan(base, source, match=MATCH_METERS, dedup=DEDUP_METERS):
    """Что бы мы добавили. Чистая функция — покрыта тестами.

    Возвращает (новые_записи_без_id, отчёт).
    """
    cells = _grid(base)
    fresh = []
    matched = 0
    for row in source:
        hit = _nearest(cells, base, row["lat"], row["lon"])
        if hit and hit[0] <= match:
            matched += 1
            continue
        # Дубли внутри самого реестра схлопываем между собой.
        if any(meters(row["lat"], row["lon"], f["lat"], f["lon"]) <= dedup for f in fresh):
            continue
        fresh.append(row)
    # Камеры базы, которых реестр больше не знает. НЕ удаляем: за каждым id
    # может стоять чужая история, а исчезновение из выгрузки — не то же самое,
    # что исчезновение с дороги.
    scells = _grid(source)
    gone = [c for c in base
            if not (_nearest(scells, source, c["lat"], c["lon"]) or (1e9,))[0] <= match]
    report = {
        "источник": len(source),
        "совпало с базой": matched,
        "новых мест": len(fresh),
        "в базе, но не в реестре": len(gone),
    }
    return fresh, report


def next_id(base):
    """Следующий свободный id — ПРОДОЛЖЕНИЕ нумерации, а не первая дыра.

    В базе 28 дыр от удалённых камер. Занять дыру значит отдать новой камере
    id, который у кого-то уже лежит в истории проездов.
    """
    return max((c.get("id", 0) for c in base), default=0) + 1


def merged(base, fresh):
    """Боевая база + новые записи. Существующие не трогаются вообще."""
    out = list(base)
    ident = next_id(base)
    for row in fresh:
        out.append({
            "id": ident,
            "region": row["region"],
            "city": row["city"],
            "location": row["location"],
            "lat": row["lat"],
            "lon": row["lon"],
            "type": row["type"],
            # Координата — прямо из реестра, на ось дороги не посажена.
            # Приложение показывает такие с честной плашкой «приблизительная»
            # (Camera.isApproximate), а снап дополнит геометрию следующим
            # проходом snap_cameras.py.
            "needsReview": True,
        })
        ident += 1
    return out


def verify(base, result):
    """Инвариант перед записью: ни один существующий id не сдвинулся.

    Проверка стоит здесь, а не в тесте, потому что цена ошибки — чужая
    история проездов, и она обязана сработать в том числе на боевом прогоне.
    """
    # Дубли id проверяем ПЕРВЫМИ: словарь ниже оставляет последнюю запись, и
    # повтор выглядел бы «переездом» камеры — объяснение верное по форме и
    # ложное по сути, а разбирать это будут по одной строке в логе.
    ids = [c["id"] for c in result]
    if len(ids) != len(set(ids)):
        return False, "появились одинаковые id"
    before = {c["id"]: (c["lat"], c["lon"]) for c in base}
    after = {c["id"]: (c["lat"], c["lon"]) for c in result}
    for ident, point in before.items():
        if ident not in after:
            return False, "камера %s исчезла из базы" % ident
        if after[ident] != point:
            return False, "камера %s переехала: %s → %s" % (ident, point, after[ident])
    if len(result) < len(base):
        return False, "записей стало меньше"
    highest = max(ids)
    if highest > MAX_BASE_ID:
        return False, ("id %d вышел за пространство стационарной базы: "
                       "с %d начинаются камеры, поставленные рукой" % (highest, MAX_BASE_ID + 1))
    strange = {c.get("type") for c in result} - KNOWN_TYPES
    if strange:
        return False, "типы, которых приложение не знает: %s" % sorted(strange)
    return True, "все %d прежних id на месте" % len(before)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--apply", action="store_true",
                        help="записать результат (без флага — только показать)")
    parser.add_argument("--allow-many", action="store_true",
                        help="разрешить больше %d новых за раз" % MAX_NEW_AT_ONCE)
    args = parser.parse_args()

    with open(args.base, encoding="utf-8") as f:
        base = json.load(f)
    with open(args.source, encoding="utf-8") as f:
        source = read_source(json.load(f))

    if len(source) < MIN_SOURCE_ROWS:
        print("ОТКАЗ: в реестре всего %d строк — источник сломан" % len(source))
        return 1

    fresh, report = plan(base, source)
    print("база: %d камер" % len(base))
    for key, value in report.items():
        print("  %-24s %d" % (key, value))

    if not fresh:
        print("новых камер нет — база актуальна")
        return 0
    if len(fresh) > MAX_NEW_AT_ONCE and not args.allow_many:
        print("ОТКАЗ: %d новых за раз — это не прирост реестра, а промах "
              "сопоставления. Проверьте и повторите с --allow-many" % len(fresh))
        return 1

    result = merged(base, fresh)
    ok, why = verify(base, result)
    print("проверка инварианта: %s" % why)
    if not ok:
        print("ОТКАЗ: база не тронута")
        return 1

    print("\nновые камеры (id с %d):" % next_id(base))
    for row, cam in zip(fresh, result[len(base):]):
        print("  %5d  %-22s %-20s %s" % (cam["id"], cam["region"][:22],
                                         cam["city"][:20], cam["location"][:52]))
    if not args.apply:
        print("\n(показ без записи; повторите с --apply)")
        return 0

    tmp = args.base + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, args.base)
    print("\nзаписано: %d камер (было %d)" % (len(result), len(base)))
    print("дальше по порядку:")
    print("  1. поднять AppConfig.bundledDBVersion — без этого телефон с уже")
    print("     скачанной базой прежней версии новых камер не увидит вовсе")
    print("  2. snap_cameras.py ПО ВСЕЙ БАЗЕ, а не по срезу из новых: twin и")
    print("     поиск дублей считаются глобально, на срезе они молча соврут")
    print("  3. deploy_db.sh <версия> — подпись ключом владельца")
    return 0


if __name__ == "__main__":
    sys.exit(main())
