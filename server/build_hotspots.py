#!/usr/bin/env python3
"""build_hotspots.py — «здесь часто ставят треногу» из накопленных отметок.

Дислокация передвижных радаров суточная и закрытая: её утверждает начальник
областной службы безопасности движения, публиковать её никто не обязан, а с
2022 года водителю не показывают её даже на месте. Но точки в ней
ПОВТОРЯЮТСЯ — инспектор возвращается на те же участки. Накопленные отметки
водителей и есть восстановленная снизу дислокация, и она существует только у
нас: скачать её неоткуда, ни у реестра, ни у конкурентов её нет.

Что делает: сводит отметки радаров и треног за окно (90 дней) в кластеры
~200 м и оставляет только те, за которые ручались РАЗНЫЕ люди — минимум три
отметки от двух устройств и двух адресов. Один водитель, отмечающий одно и то
же место каждый день, горячей точки не делает: иначе достаточно одного
упорного человека, чтобы приложение начало врать всему городу.

ПРИВАТНОСТЬ. Наружу уходит только координата кластера, счётчик, число разных
дней и «когда обычно» с точностью до четверти суток. Ни device, ни ip, ни
времена отдельных отметок: по ним восстанавливается маршрут конкретного
человека, а ради подсказки о треноге это непозволительная цена.

Выход — payload для publish_hotspots.sh; подпись ставит владелец локально,
сервер подписывать не умеет и не должен (взломанный VPS не может ни завести
фантомную точку, ни стереть настоящую).

Запуск:
    python3 build_hotspots.py --db /opt/radarmap/api/reports.db > hotspots.payload
Тесты (без базы и сети):
    python3 test_build_hotspots.py
"""
import argparse
import json
import math
import sqlite3
import sys
import time

#: Окно наблюдения. Три месяца — компромисс: короче окно не накопит
#: повторов, длиннее начнёт помнить точки, которые ГАИ давно оставила.
WINDOW_DAYS = 90
#: Радиус кластера. Тренога стоит не в точке, а на участке — 200 м примерно
#: соответствует «то же место» в понимании водителя.
CLUSTER_METERS = 200.0
#: Пороги доверия. Все три обязательны одновременно.
MIN_REPORTS = 3
MIN_DEVICES = 2
MIN_IPS = 2
#: Какие типы вообще участвуют. Пост ДПС стоит иначе (он полупостоянный), ДТП
#: не повторяется — их память сюда не относится.
KINDS = ("radar", "tripod")
#: Часовой пояс Узбекистана: сервер считает «утро/день/вечер» по местному
#: времени водителя, а не по UTC, где утро приходится на ночь.
TZ_OFFSET = 5 * 3600
#: Метров в градусе широты (плоская аппроксимация: кластеры маленькие).
M_PER_DEG_LAT = 111_320.0


def distance(lat1, lon1, lat2, lon2):
    kx = M_PER_DEG_LAT * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lat2 - lat1) * M_PER_DEG_LAT, (lon2 - lon1) * kx)


def quarter(created):
    """Четверть суток по местному времени: 0 ночь, 1 утро, 2 день, 3 вечер."""
    hour = time.gmtime(created + TZ_OFFSET).tm_hour
    return min(3, hour // 6)


def day_key(created):
    return int((created + TZ_OFFSET) // 86400)


def cluster(rows, *, radius=CLUSTER_METERS):
    """Сгруппировать отметки по месту. Центр — бегущее среднее: кластер
    подтягивается к настоящему месту стоянки, а не к первой отметке, которую
    кто-то поставил с обочины в ста метрах."""
    clusters = []
    for lat, lon, created, device, ip in rows:
        best, best_distance = None, radius
        for item in clusters:
            d = distance(item["lat"], item["lon"], lat, lon)
            if d < best_distance:
                best, best_distance = item, d
        if best is None:
            best = {"lat": lat, "lon": lon, "n": 0, "devices": set(),
                    "ips": set(), "days": set(), "quarters": [0, 0, 0, 0]}
            clusters.append(best)
        n = best["n"]
        best["lat"] = (best["lat"] * n + lat) / (n + 1)
        best["lon"] = (best["lon"] * n + lon) / (n + 1)
        best["n"] = n + 1
        best["devices"].add(device or "")
        # Пустой ip — это строки старого сервера, который его не писал.
        # Считать их разными адресами нельзя: так одно устройство набрало бы
        # кворум само себе.
        if ip:
            best["ips"].add(ip)
        best["days"].add(day_key(created))
        best["quarters"][quarter(created)] += 1
    return clusters


def spots(clusters, *, min_reports=MIN_REPORTS, min_devices=MIN_DEVICES,
          min_ips=MIN_IPS):
    """Кластеры, дожившие до порога доверия, — в контракт для приложения."""
    result = []
    for item in clusters:
        if item["n"] < min_reports:
            continue
        if len(item["devices"]) < min_devices or len(item["ips"]) < min_ips:
            continue
        counts = item["quarters"]
        top = max(range(4), key=lambda q: counts[q])
        # «Обычно утром» имеет смысл, только если это действительно перевес.
        # Ровное распределение честнее показать как «когда угодно» (peak = -1).
        peak = top if counts[top] * 2 > item["n"] else -1
        result.append({"lat": round(item["lat"], 5), "lon": round(item["lon"], 5),
                       "n": item["n"], "days": len(item["days"]), "peak": peak})
    result.sort(key=lambda s: (-s["n"], s["lat"], s["lon"]))
    return result


def load(db_path, *, now, window_days=WINDOW_DAYS):
    since = now - window_days * 86400
    conn = sqlite3.connect(db_path)
    try:
        placeholders = ",".join("?" for _ in KINDS)
        return conn.execute(
            f"SELECT lat, lon, created, device, ip FROM reports "
            f"WHERE created >= ? AND type IN ({placeholders}) ORDER BY created",
            (since, *KINDS)).fetchall()
    finally:
        conn.close()


def build(rows, *, now):
    return {"version": 1,
            "generated": time.strftime("%Y-%m-%d", time.gmtime(now)),
            "window_days": WINDOW_DAYS,
            "spots": spots(cluster(rows))}


def main():
    ap = argparse.ArgumentParser(description="Горячие точки треног из отметок водителей")
    ap.add_argument("--db", default="/opt/radarmap/api/reports.db")
    ap.add_argument("--now", type=float, default=None,
                    help="метка времени для воспроизводимости (по умолчанию — сейчас)")
    args = ap.parse_args()
    now = args.now if args.now is not None else time.time()
    try:
        rows = load(args.db, now=now)
    except sqlite3.Error as error:
        print(f"не читается база отметок: {error}", file=sys.stderr)
        return 1
    payload = build(rows, now=now)
    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    print(f"\nточек: {len(payload['spots'])} из {len(rows)} отметок", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
