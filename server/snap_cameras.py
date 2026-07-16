#!/usr/bin/env python3
"""
snap_cameras.py — притягивает координаты камер к оси дороги через наш OSRM.

Проблема: адреса data.egov.uz геокодированы неточно, точки камер смещены вбок
от полосы на десятки метров (камера «A.navoiy ko'chasi» падает на параллельную
улицу). Это ломает направление в HUD, карту и учёт проездов.

Решение без новых зависимостей: у нас уже работает OSRM. Его сервис
/nearest/v1/driving возвращает точку, спроецированную на дорожную сеть OSM,
и название дороги. Для каждой камеры берём кандидатов, выбираем ближайшего,
чьё название совпадает с улицей из адреса, и переносим координату на него.

БЕЗОПАСНОСТЬ ДАННЫХ (переносить камеру на ЧУЖУЮ дорогу хуже, чем оставить как есть):
  - переносим только при совпадении имени дороги ИЛИ если и так почти на дороге (<15 м);
  - при переносе дальше max-shift или без совпадения — оставляем исходную
    координату и ставим needsReview=true (в приложение попадёт как «проверить»,
    плюс отработает краудсорсинг-репортинг).

Запуск на сервере (где живёт OSRM):
    python3 snap_cameras.py --in cameras.json --out cameras.snapped.json \
        --osrm http://127.0.0.1:5000
    # проверить отчёт, затем при желании заменить живую базу и поднять version.json

Самотест матчинга имён (без сети):
    python3 snap_cameras.py --selftest
"""
import argparse
import json
import math
import sys
import urllib.request
import urllib.parse

# --- Нормализация и матчинг названий улиц -----------------------------------

# Служебные слова «улица/проспект/перекрёсток» на всех вариантах — выкидываем.
_STREET_STOPWORDS = {
    "ko", "kochasi", "kocha", "kchasi", "koicha", "ko'chasi", "ko'cha",
    "kuchasi", "kucha", "shohko'chasi", "shoh", "prospekti", "prospekt",
    "prospek", "yoli", "yo'li", "yuli", "chorrahasi", "chorraha", "kesishgan",
    "va", "burchagi", "yon", "qismi", "uy", "dom", "ulitsa", "улица",
    "проспект", "переулок", "проезд", "шоссе", "koʻchasi", "koʻcha",
}
# Латиница ↔ приведение к простому виду (апострофы, ʻ, ' → нет; o' → o и т.п.).
_TRANSLIT = str.maketrans({
    "ʻ": "", "'": "", "`": "", "'": "", "ʼ": "", "-": " ", ".": " ", ",": " ",
    "ў": "u", "қ": "q", "ғ": "g", "ҳ": "h", "х": "h", "ц": "c",
})


def normalize_street(text):
    """Адрес → множество значимых слов улицы (нижний регистр, без служебных)."""
    if not text:
        return set()
    t = text.lower().translate(_TRANSLIT)
    words = [w for w in t.replace("/", " ").split() if w]
    out = set()
    for w in words:
        w = "".join(ch for ch in w if ch.isalnum())
        if not w or w in _STREET_STOPWORDS or w.isdigit():
            continue
        out.add(w)
    return out


def names_match(camera_location, road_name):
    """Совпадает ли улица камеры с названием дороги из OSRM (пересечение слов)."""
    a = normalize_street(camera_location)
    b = normalize_street(road_name)
    if not a or not b:
        return False
    # Достаточно одного общего значимого слова длиной ≥3 (Navoiy, Amir, Bunyodkor…).
    return any(len(w) >= 3 and w in b for w in a)


def haversine(lat1, lon1, lat2, lon2):
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(x))


# --- OSRM /nearest ----------------------------------------------------------

def osrm_nearest(osrm_base, lat, lon, number=8, timeout=10):
    """Кандидаты проекции на дорожную сеть: [(lat, lon, name, dist_m), …]."""
    url = f"{osrm_base}/nearest/v1/driving/{lon:.6f},{lat:.6f}?number={number}"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        data = json.load(resp)
    if data.get("code") != "Ok":
        return []
    out = []
    for wp in data.get("waypoints", []):
        loc = wp.get("location")
        if not loc or len(loc) != 2:
            continue
        wlon, wlat = loc[0], loc[1]
        out.append((wlat, wlon, wp.get("name", "") or "", wp.get("distance", 1e9)))
    return out


def choose_snap(camera, candidates, max_shift):
    """Выбрать точку переноса. Возвращает (lat, lon, reason) или None."""
    if not candidates:
        return None
    # Кандидаты уже отсортированы OSRM по расстоянию (ближний первый).
    named = [c for c in candidates if names_match(camera["location"], c[2])]
    for lat, lon, name, dist in named:
        if dist <= max_shift:
            return (lat, lon, f"name-match «{name}» ({dist:.0f} м)")
    # Имя не совпало, но точка и так почти на дороге — доверяем геометрии.
    lat, lon, name, dist = candidates[0]
    if dist <= 15:
        return (lat, lon, f"already-on-road ({dist:.0f} м)")
    return None


# --- Основной проход --------------------------------------------------------

def snap_all(cameras, osrm_base, max_shift):
    snapped = kept = 0
    total_shift = 0.0
    result = []
    for cam in cameras:
        out = dict(cam)
        try:
            cands = osrm_nearest(osrm_base, cam["lat"], cam["lon"])
        except Exception as e:                       # сеть/OSRM — не роняем весь прогон
            cands = []
            print(f"  [{cam['id']}] OSRM error: {e}", file=sys.stderr)
        choice = choose_snap(cam, cands, max_shift)
        if choice:
            lat, lon, reason = choice
            shift = haversine(cam["lat"], cam["lon"], lat, lon)
            out["lat"], out["lon"] = round(lat, 6), round(lon, 6)
            out.pop("needsReview", None)
            snapped += 1
            total_shift += shift
            if shift > 5:
                print(f"  [{cam['id']}] {shift:5.0f} м → {reason} · {cam['location'][:40]}")
        else:
            out["needsReview"] = True                # оставили как есть, пометили
            kept += 1
        result.append(out)
    return result, snapped, kept, total_shift


def selftest():
    cases = [
        ("A.navoiy ko'chasi 30-UY Yon Qismi", "Alisher Navoiy ko'chasi", True),
        ("Istiqlol ko'chasi", "Sharof Rashidov ko'chasi", False),
        ("Bunyodkor shohko'chasi", "Bunyodkor prospekti", True),
        ("Amir Temur ko'chasi", "Amir Temur shoh ko'chasi", True),
        ("4Р-116-YO'L", "Kichik halqa yo'li", False),
    ]
    ok = True
    for loc, road, expect in cases:
        got = names_match(loc, road)
        flag = "ok " if got == expect else "FAIL"
        if got != expect:
            ok = False
        print(f"  [{flag}] «{loc}» ~ «{road}» → {got} (ждали {expect})")
    print("selftest:", "PASSED" if ok else "FAILED")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Snap camera coordinates to OSM roads via OSRM")
    ap.add_argument("--in", dest="inp", default="cameras.json")
    ap.add_argument("--out", dest="out", default="cameras.snapped.json")
    ap.add_argument("--osrm", default="http://127.0.0.1:5000",
                    help="OSRM base URL (internal)")
    ap.add_argument("--max-shift", type=float, default=60.0,
                    help="макс. перенос при совпадении имени, метры")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    cameras = json.load(open(args.inp, encoding="utf-8"))
    print(f"камер: {len(cameras)} · OSRM: {args.osrm} · max-shift {args.max_shift:.0f} м\n")

    result, snapped, kept, total_shift = snap_all(cameras, args.osrm, args.max_shift)

    json.dump(result, open(args.out, "w", encoding="utf-8"), ensure_ascii=False)
    avg = (total_shift / snapped) if snapped else 0
    print(f"\nитог: перенесено {snapped}, оставлено+needsReview {kept}")
    print(f"средний перенос: {avg:.1f} м · файл: {args.out}")
    print("\nдалее: проверить отчёт выше, затем при желании заменить живую базу")
    print("и поднять version.json (OTA раздаст обновление приложению).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
