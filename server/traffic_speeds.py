#!/usr/bin/env python3
"""Скорости рёбер для osrm-customize (`--segment-speed-file`) — из той же
traffic.db, что now.json и «обычно» (27.E, подготовка; в cron НЕ подключено).

Сейчас OSRM на VPS — CH, и пробки живут только поверх маршрута: телефон
добавляет задержку к времени варианта (TrafficSnapshot.delay), а путь
выбирает граф пустых дорог. Следующий шаг — MLD + `osrm-customize`: граф
пересчитывает веса по этому файлу раз в несколько минут, и маршрут сам
обходит пробку. Схема сборки и выкладки — в шапке build_osrm_mld.sh.

    python3 traffic_speeds.py --source now      [--db …] [--out speeds.csv]
    python3 traffic_speeds.py --source typical  [--bucket wd-08]
    python3 traffic_speeds.py --source auto     # now, где он есть, иначе «обычно» часа

Формат OSRM — CSV без заголовка, одна строка на НАПРАВЛЕННОЕ ребро:
    from_osm_id,to_osm_id,speed_kmh
Ключ — пара узлов OSM, как в traffic_samples/traffic_profile: OSRM `match`
отдаёт именно их (annotations=nodes), и они постоянны между пересборками
графа — файл подходит к графу любой свежести.

Правила — те же, что у телефона, и по той же причине (честность важнее
частоты):
  * now — ровно рёбра now.json (traffic_build.live_edges: MIN_PIECES
    свидетелей за SAMPLE_WINDOW), и ТОЛЬКО медленные (уровень ≥ 2). Свободный
    поток в граф не пишется: «быстрее car.lua» по двум машинам — догадка, а
    маршрут через двор на скорости 60 км/ч — реальный вред;
  * typical — рёбра файла «обычно» класса дня и часа (traffic_build.
    typical_rows: TYPICAL_MIN_PIECES эффективных кусков и «не один человек»),
    и только те, что медленнее графа (обычная < SLOW_RATIO × скорость графа);
    ребро без скорости графа (0) не пишется — сравнивать не с чем;
  * auto — объединение: живое ребро главнее обычного;
  * скорость не ниже SPEED_FLOOR_KMH: 0 в этом файле для OSRM значит «ребро
    закрыто», а стоящая пробка — не перекрытие;
  * целые км/ч, строки отсортированы: одинаковые данные — одинаковый файл,
    и cron может не трогать граф, когда ничего не сменилось (exit 0, «без
    изменений»). Пустой файл — честно «пробок нет»: customize вернёт граф к
    скоростям car.lua.

Наружу (телефонам) файл не уходит и координат не несёт — только id узлов и
скорость; лежит рядом с графом.
"""
import argparse
import os
import sqlite3
import sys
import time

import traffic_build as tb

SPEED_FLOOR_KMH = int(tb.PACE_MIN_KMH)    # 3 км/ч: «стоим», но не «закрыто»
SOURCES = ("now", "typical", "auto")


def live_speeds(conn, now):
    """{(u, v): км/ч} медленных рёбер now.json."""
    return {(u, v): kmh for u, v, _a, _b, _c, _d, lvl, kmh, _m in tb.live_edges(conn, now) if lvl >= 2}


def typical_speeds(conn, now, bucket=None):
    """{(u, v): км/ч} рёбер «обычно» этого файла (по умолчанию — текущий час),
    медленнее графа."""
    bucket = bucket or tb.bucket_name(tb.profile_slot(now))
    out = {}
    for name, u, v, _a, _b, _c, _d, kmh, model in tb.typical_rows(conn, now):
        if name == bucket and model > 0 and kmh < model * tb.SLOW_RATIO:
            out[(u, v)] = kmh
    return out


def speeds(conn, now, source="now", bucket=None):
    if source not in SOURCES:
        raise ValueError(f"источник {source!r}: только {', '.join(SOURCES)}")
    if source == "now":
        return live_speeds(conn, now)
    if source == "typical":
        return typical_speeds(conn, now, bucket)
    merged = typical_speeds(conn, now, bucket)
    merged.update(live_speeds(conn, now))
    return merged


def csv_body(edges):
    """Строки файла скоростей: `u,v,kmh`, по возрастанию ключа."""
    lines = [f"{u},{v},{max(SPEED_FLOOR_KMH, int(round(kmh)))}" for (u, v), kmh in sorted(edges.items())]
    return "".join(line + "\n" for line in lines)


def write_if_changed(path, body):
    """True — файл переписан. Неизменный не трогаем: по mtime cron решает,
    гонять ли customize."""
    try:
        with open(path, encoding="ascii") as f:
            if f.read() == body:
                return False
    except FileNotFoundError:
        pass
    tb.write_atomic(path, body)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description="Скорости рёбер для osrm-customize")
    parser.add_argument("--db", default=tb.DB_PATH)
    parser.add_argument("--out", default="/opt/radarmap/osrm/traffic/speeds.csv")
    parser.add_argument("--source", choices=SOURCES, default="now")
    parser.add_argument("--bucket", help="файл «обычно»: wd-08, off-18 (по умолчанию — текущий час)")
    parser.add_argument("--now", type=float, help="момент расчёта, для проверки (по умолчанию — сейчас)")
    args = parser.parse_args(argv)
    if args.bucket and args.bucket not in tb.ALL_BUCKETS:
        parser.error(f"нет такого файла «обычно»: {args.bucket}")
    now = args.now or time.time()
    # Только чтение: сборщик пробок пишет в эту базу каждые 2 минуты.
    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True, timeout=5)
    try:
        edges = speeds(conn, now, args.source, args.bucket)
    finally:
        conn.close()
    changed = write_if_changed(args.out, csv_body(edges))
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} скорости ({args.source}): рёбер {len(edges)}, "
          f"{'записано' if changed else 'без изменений'} → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
