#!/usr/bin/env python3
"""Скорости рёбер для osrm-customize (`--segment-speed-file`) — из той же
traffic.db, что now.json и «обычно» (27.E; 32D — стенд MLD рядом с продом,
server/osrm/traffic_customize.sh; в cron НЕ подключено).

Сейчас OSRM на VPS — CH, и пробки живут только поверх маршрута: телефон
добавляет задержку к времени варианта (TrafficSnapshot.delay), а путь
выбирает граф пустых дорог. Следующий шаг — MLD + `osrm-customize`: граф
пересчитывает веса по этому файлу раз в несколько минут, и маршрут сам
обходит пробку. Схема сборки и выкладки — в шапке build_osrm_mld.sh.

    python3 traffic_speeds.py --source route    # 33A: профиль часа недели + живые (для customize)
    python3 traffic_speeds.py --source now      [--db …] [--out speeds.csv]
    python3 traffic_speeds.py --source typical  [--bucket wd-08]
    python3 traffic_speeds.py --source auto     # now, где он есть, иначе «обычно» часа
    python3 traffic_speeds.py --mode duration   # см. «Два режима» ниже

Формат OSRM — CSV без заголовка, одна строка на НАПРАВЛЕННОЕ ребро:
    from_osm_id,to_osm_id,speed_kmh[,rate]
Ключ — пара узлов OSM, как в traffic_samples/traffic_profile: OSRM `match`
отдаёт именно их (annotations=nodes), и они постоянны между пересборками
графа — файл подходит к графу любой свежести.

Два режима (32D, проверено на osrm-customize v26.7.3, server/osrm/TRAFFIC.md):
  * weight (по умолчанию) — `u,v,скорость графа,rate`: выбор пути идёт по
    пробке (вес = длина / rate, rate = скорость пробки в м/с — та же единица,
    что forward_rate в car.lua), а время в пути (duration) остаётся
    скоростью графа. Телефон по-прежнему сам прибавляет задержку пробки к
    времени варианта (TrafficSnapshot.delay), и пробка не считается дважды —
    сервер можно переключить без новой сборки приложения;
  * duration — `u,v,скорость пробки`: OSRM переписывает и время, и вес
    («Speed values were used to update … segments for 'routability'
    profile»). Время маршрута уже с пробкой — годится, только когда телефон
    перестанет прибавлять свою задержку к такому ответу.

Источник `route` (33A, docs/spec_traffic_33.md) — то, что идёт в
маршрутизатор: типичная скорость слота часа недели по медиане и числу
разных дней, сжатая к графу, живые куски поверх с весом по их числу и
возрасту, гистерезис против дребезга — формулы в traffic_profile.py,
константы в traffic_config.py. Инварианты этого источника:
  * отказ = граф: любая ошибка — файл пишется ПУСТЫМ, не прошлым, и выход 1;
  * один запуск за раз (flock на <out>.lock), второй выходит с журналом;
  * итог в [5 км/ч, граф], пишется только < 0,85 графа;
  * потолки: MAX_SPEED_EDGES строк и MAX_FILE_BYTES; сверх — обрезка по
    убыванию значимости (длина ребра × замедление) и «ПОТОЛОК» в журнале;
  * одна строка журнала на запуск: слоты, рёбер типичных/живых, записано,
    время шагов, итог (ок / пусто / ошибка).
С --turns-out тот же запуск пишет файл --turn-penalty-file (33B):
`from_osm,via_osm,to_osm,секунд` — медиана задержки манёвра в слоте часа
недели, только где она больше штрафа профиля на 5 с (traffic_profile.
turn_penalties); потолок MAX_TURNS по превышению над профилем. Ошибка —
пустыми оба файла.
Источники now/typical/auto ниже — прежние (32D), для проверки руками; цикл
стенда берёт route.

Правила прежних источников — те же, что у телефона, и по той же причине
(честность важнее частоты):
  * now — ровно рёбра now.json (traffic_build.live_edges: MIN_PIECES
    свидетелей за SAMPLE_WINDOW), и ТОЛЬКО медленные (уровень ≥ 2). Свободный
    поток в граф не пишется: «быстрее car.lua» по двум машинам — догадка, а
    маршрут через двор на скорости 60 км/ч — реальный вред;
  * typical — рёбра файла «обычно» класса дня и часа (traffic_build.
    typical_rows: TYPICAL_MIN_PIECES эффективных кусков и «не один человек»),
    и только те, что медленнее графа (обычная < SLOW_RATIO × скорость графа);
    ребро без скорости графа (0) не пишется — сравнивать не с чем;
  * auto — объединение: живое ребро главнее обычного;
  * скорость не выше скорости графа и не ниже SPEED_FLOOR_KMH. Выше графа
    файл ребро не ускоряет: «быстрее car.lua» — не дело пробок (правило
    выше), а ребро без скорости графа не пишется — сравнивать не с чем.
    Пол: 0 для OSRM значит «ребро закрыто», а стоящая пробка — не
    перекрытие; ниже 5 км/ч медиана 15 минут — это уже не темп потока, а
    стояние у светофора и дрожь GPS на месте, и 40-метровый огрызок ребра
    по 1 км/ч весил бы, как километр объезда. 5 км/ч — 12 мин/км: любой
    разумный объезд пробки выигрывает и так;
  * целые км/ч, строки отсортированы: одинаковые данные — одинаковый файл,
    и cron может не трогать граф, когда ничего не сменилось (exit 0, «без
    изменений»). Пустой файл — честно «пробок нет»: customize вернёт граф к
    скоростям car.lua.

Наружу (телефонам) файл не уходит и координат не несёт — только id узлов и
скорость; лежит рядом с графом.
"""
import argparse
import fcntl
import math
import os
import sqlite3
import sys
import time

import traffic_build as tb
import traffic_config as tc
import traffic_profile as tp

SPEED_FLOOR_KMH = 5          # «стоим», но не «закрыто» (см. шапку)
SOURCES = ("now", "typical", "auto", "route")
MODES = ("weight", "duration")


def bounded(kmh, model):
    """Скорость для графа: не выше скорости графа и не ниже пола. None —
    скорости графа нет, ребро не пишется."""
    if not model or model <= 0:
        return None
    return min(model, max(SPEED_FLOOR_KMH, kmh))


def live_speeds(conn, now):
    """{(u, v): (км/ч, км/ч графа)} медленных рёбер now.json."""
    out = {}
    for u, v, _a, _b, _c, _d, lvl, kmh, model in tb.live_edges(conn, now):
        speed = bounded(kmh, model) if lvl >= 2 else None
        if speed is not None:
            out[(u, v)] = (speed, model)
    return out


def typical_speeds(conn, now, bucket=None):
    """{(u, v): (км/ч, км/ч графа)} рёбер «обычно» этого файла (по умолчанию —
    текущий час), медленнее графа."""
    bucket = bucket or tb.bucket_name(tb.profile_slot(now))
    out = {}
    for name, u, v, _a, _b, _c, _d, kmh, model in tb.typical_rows(conn, now):
        if name == bucket and model > 0 and kmh < model * tb.SLOW_RATIO:
            out[(u, v)] = (bounded(kmh, model), model)
    return out


def speeds(conn, now, source="now", bucket=None):
    if source not in SOURCES:
        raise ValueError(f"источник {source!r}: только {', '.join(SOURCES)}")
    if source == "now":
        return live_speeds(conn, now)
    if source == "typical":
        return typical_speeds(conn, now, bucket)
    if source == "route":
        edges, graph, _stats = tp.route_edges(conn, now)
        return {edge: (kmh, graph[edge]) for edge, kmh in edges.items()}
    merged = typical_speeds(conn, now, bucket)
    merged.update(live_speeds(conn, now))
    return merged


def csv_body(edges, mode="weight"):
    """Строки файла скоростей по возрастанию ключа: `u,v,км/ч графа,rate` (weight)
    или `u,v,км/ч пробки` (duration). Числа округлены: одинаковые данные —
    одинаковый файл, и цикл на VPS не гоняет customize впустую."""
    if mode not in MODES:
        raise ValueError(f"режим {mode!r}: только {', '.join(MODES)}")
    lines = []
    for (u, v), (kmh, model) in sorted(edges.items()):
        # Целые км/ч, но округление не поднимает ребро выше графа (60,4 → 60,
        # не 61) и не даёт 0 — «закрыто».
        speed = max(1.0, min(float(round(kmh)), model))
        if mode == "duration":
            lines.append(f"{u},{v},{max(1, int(speed))}")
        else:
            # rate — м/с пробки; скорость графа с десятыми: целые км/ч сдвинули
            # бы время в пути (duration) на ребре на доли процента от графа.
            lines.append(f"{u},{v},{model:.1f},{speed / 3.6:.3f}")
    return "".join(line + "\n" for line in lines)


def turns_body(rows):
    """Строки --turn-penalty-file по возрастанию тройки: `u,v,w,секунд`
    (целые секунды — детерминизм)."""
    return "".join(f"{u},{v},{w},{int(delay)}\n" for u, v, w, delay, *_ in sorted(rows))


def cap_turns(rows, limit=tc.MAX_TURNS):
    """Инвариант 5 для манёвров: самые значимые (превышение над профилем)."""
    ranked = sorted(rows, key=lambda row: (-row[4], row[:3]))
    return sorted(ranked[:limit]), max(0, len(rows) - limit)


def read_previous(path):
    """{(u, v): км/ч} прошлого файла скоростей (для гистерезиса 33A): weight —
    rate × 3,6, duration — третий столбец. Нет файла или строка не та — без
    неё (гистерезис просто не сработает: это безопасная сторона)."""
    out = {}
    try:
        with open(path, encoding="ascii") as f:
            for line in f:
                parts = line.strip().split(",")
                try:
                    if len(parts) == 4:
                        out[(int(parts[0]), int(parts[1]))] = float(round(float(parts[3]) * 3.6))
                    elif len(parts) == 3:
                        out[(int(parts[0]), int(parts[1]))] = float(parts[2])
                except ValueError:
                    continue
    except (FileNotFoundError, UnicodeDecodeError):
        pass
    return out


def edge_lengths(conn, edges):
    """{(u, v): метров} по координатам узлов traffic_nodes; неизвестно — 1 м."""
    coords = {}
    for node, lat, lon in conn.execute("SELECT id, lat, lon FROM traffic_nodes"):
        coords[node] = (lat, lon)
    out = {}
    for u, v in edges:
        a, b = coords.get(u), coords.get(v)
        if a and b:
            k = math.cos(math.radians(a[0])) * 111320.0
            out[(u, v)] = max(1.0, math.hypot((a[1] - b[1]) * k, (a[0] - b[0]) * 111320.0))
        else:
            out[(u, v)] = 1.0
    return out


def cap(edges, lengths, limit, mode="weight", max_bytes=tc.MAX_FILE_BYTES):
    """Инвариант 5: не больше `limit` рёбер и `max_bytes` файла; лишние —
    наименее значимые (длина × замедление). (рёбра, обрезано)."""
    def weight(item):
        (edge, (kmh, model)) = item
        return (-(lengths.get(edge, 1.0) * (1 - kmh / model)), edge)
    ranked = sorted(edges.items(), key=weight)
    kept = dict(ranked[:limit])
    while kept and len(csv_body(kept, mode).encode()) > max_bytes:
        ranked = ranked[:max(1, int(len(kept) * 0.9))]
        kept = dict(ranked)
    return kept, len(edges) - len(kept)


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


def route_files(args, now, steps):
    """Шаги источника route: (рёбра, счётчики). Исключение — наружу (main
    пишет пустой файл)."""
    previous = read_previous(args.out)
    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True, timeout=5)
    try:
        started = time.perf_counter()
        speeds_kmh, graph, stats = tp.route_edges(conn, now, previous)
        steps["профиль"] = time.perf_counter() - started
        edges = {edge: (kmh, graph[edge]) for edge, kmh in speeds_kmh.items()}
        edges, trimmed = cap(edges, edge_lengths(conn, edges), tc.MAX_SPEED_EDGES, args.mode)
        turns = []
        if args.turns_out:
            started = time.perf_counter()
            turns, trimmed_turns = cap_turns(tp.turn_penalties(conn, now))
            trimmed += trimmed_turns
            steps["манёвры"] = time.perf_counter() - started
        stats["trimmed"] = trimmed
    finally:
        conn.close()
    return edges, turns, stats


def main(argv=None):
    parser = argparse.ArgumentParser(description="Скорости рёбер для osrm-customize")
    parser.add_argument("--db", default=tb.DB_PATH)
    parser.add_argument("--out", default="/opt/radarmap/osrm-mld/speeds.csv")
    parser.add_argument("--source", choices=SOURCES, default="now")
    parser.add_argument("--mode", choices=MODES, default="weight",
                        help="weight — пробка только в выборе пути (по умолчанию), duration — и во времени")
    parser.add_argument("--bucket", help="файл «обычно»: wd-08, off-18 (по умолчанию — текущий час)")
    parser.add_argument("--now", type=float, help="момент расчёта, для проверки (по умолчанию — сейчас)")
    parser.add_argument("--turns-out", help="файл штрафов манёвров (33B; только с --source route)")
    args = parser.parse_args(argv)
    if args.turns_out and args.source != "route":
        parser.error("--turns-out — только с --source route")
    if args.bucket and args.bucket not in tb.ALL_BUCKETS:
        parser.error(f"нет такого файла «обычно»: {args.bucket}")
    now = args.now or time.time()
    stamp = time.strftime('%Y-%m-%dT%H:%M:%S')
    if args.source != "route":
        # Только чтение: сборщик пробок пишет в эту базу каждые 2 минуты.
        conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True, timeout=5)
        try:
            edges = speeds(conn, now, args.source, args.bucket)
        finally:
            conn.close()
        changed = write_if_changed(args.out, csv_body(edges, args.mode))
        print(f"{stamp} скорости ({args.source}, {args.mode}): рёбер {len(edges)}, "
              f"{'записано' if changed else 'без изменений'} → {args.out}")
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out + ".lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"{stamp} скорости (route): прошлый запуск ещё идёт — пропуск")
            return 0
        steps = {}
        started = time.perf_counter()
        try:
            edges, turns, stats = route_files(args, now, steps)
        except Exception as error:  # noqa: BLE001 — инвариант 1: любая ошибка — граф
            write_if_changed(args.out, "")
            if args.turns_out:
                write_if_changed(args.turns_out, "")
            print(f"{stamp} скорости (route): ОШИБКА {type(error).__name__}: {error} — "
                  f"файл пустой (граф без пробок) → {args.out}")
            return 1
        changed = write_if_changed(args.out, csv_body(edges, args.mode))
        if args.turns_out:
            changed = write_if_changed(args.turns_out, turns_body(turns)) or changed
        steps["всего"] = time.perf_counter() - started
        timing = ", ".join(f"{name} {seconds * 1000:.0f} мс" for name, seconds in steps.items())
        result = "ок" if edges or turns else "пусто"
        trimmed = f", ПОТОЛОК: обрезано {stats['trimmed']}" if stats.get("trimmed") else ""
        print(f"{stamp} скорости (route, {args.mode}): слоты {stats['slots']}, рёбер типичных "
              f"{stats['typical']}, живых {stats['live']}, записано {len(edges)} (гистерезис "
              f"{stats['kept']}), манёвров {len(turns) if args.turns_out else '—'}{trimmed}; {timing}; {result}, "
              f"{'изменён' if changed else 'без изменений'} → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
