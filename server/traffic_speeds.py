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
С --reports-db (33D) в тот же файл ложатся события водителей: ДТП и
перекрытия, подтверждённые независимыми водителями (перекрытие — двумя,
ДТП — одним; другое устройство И другой адрес, правило api.
confirmed_independently), — на время жизни отметки, не дольше
EVENT_MAX_AGE: перекрытие — 5 км/ч на рёбрах в 30 м от точки (по курсу
отметившего, без курса — в обе стороны), ДТП — 0,6 графа в обе стороны. На
общем ребре с пробкой берётся меньшая скорость. Рёбра отметки — путь OSRM
стенда на ±30 м вдоль дороги; ответ кэшируется по id отметки (--events-cache)
и считается один раз, до того как штраф попал в граф: иначе следующий цикл
искал бы путь в объезд собственного штрафа. Неподтверждённые — только показ.
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
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

import traffic_build as tb
import traffic_config as tc
import traffic_model as tm
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


# --- События водителей (33D) ----------------------------------------------------

EVENT_OSRM = "http://127.0.0.1:8094"   # стенд: та же нумерация узлов OSM, что у прода
EVENT_TYPES = ("accident", "closure")


def confirmed_events(reports_db, now):
    """[(id, lat, lon, тип, курс)] живых ДТП и перекрытий с нужным числом
    независимых подтверждений (разные адреса среди лайков с чужого
    устройства и чужого адреса), не старше EVENT_MAX_AGE. Только чтение."""
    if not reports_db or not os.path.exists(reports_db):
        return []
    conn = sqlite3.connect(f"file:{reports_db}?mode=ro", uri=True, timeout=5)
    try:
        rows = conn.execute(
            """SELECT r.id, r.lat, r.lon, r.type, r.course,
                      (SELECT COUNT(DISTINCT v.ip) FROM votes v WHERE v.report_id = r.id AND v.value = 1
                         AND v.device != r.device AND v.ip != '' AND v.ip != r.ip)
               FROM reports r
               WHERE r.active = 1 AND r.expires > ? AND r.created >= ? AND r.type IN (?, ?)
               ORDER BY r.id""", (now, now - tc.EVENT_MAX_AGE, *EVENT_TYPES)).fetchall()
    finally:
        conn.close()
    need = {"closure": tc.CLOSURE_MIN_CONFIRMERS, "accident": tc.ACCIDENT_MIN_CONFIRMERS}
    return [(rid, lat, lon, rtype, course) for rid, lat, lon, rtype, course, confirmers in rows
            if confirmers >= need[rtype]]


def event_bearings(rtype, course):
    """[(курс, допуск)] путей OSRM для отметки: перекрытие с курсом — своя
    сторона; ДТП и всё без курса — обе стороны (без курса — четыре стороны
    света с допуском 50°: ось дороги неизвестна, а 4 × 50° покрывают круг)."""
    known = course is not None and 0 <= course < 360
    if rtype == "closure" and known:
        return [(course, 30)]
    if known:
        return [(course, 30), ((course + 180) % 360, 30)]
    return [(b, 50) for b in (0, 90, 180, 270)]


def offset_point(lat, lon, course, meters):
    """Точка в `meters` м по курсу (плоское приближение — десятки метров)."""
    rad = math.radians(course)
    return (lat + meters * math.cos(rad) / 111320.0,
            lon + meters * math.sin(rad) / (111320.0 * math.cos(math.radians(lat))))


def event_route_url(lat, lon, course, tolerance, base=EVENT_OSRM):
    a = offset_point(lat, lon, (course + 180) % 360, tc.EVENT_REACH)
    b = offset_point(lat, lon, course, tc.EVENT_REACH)
    c = int(round(course)) % 360
    return (f"{base.rstrip('/')}/route/v1/driving/{a[1]:.6f},{a[0]:.6f};{b[1]:.6f},{b[0]:.6f}"
            f"?overview=false&annotations=nodes,distance,duration&bearings={c},{tolerance};{c},{tolerance}"
            "&radiuses=25;25&continue_straight=true")


def event_edges_from_route(body):
    """Рёбра ответа `route`: {(u, v): (км/ч графа, метров)}; путь длиннее
    прямой в EVENT_MAX_DETOUR раз (развязка, разворот) — не та дорога: {}."""
    routes = (body.get("routes") or []) if body.get("code") == "Ok" else []
    if not routes or routes[0].get("distance", 0) > 2 * tc.EVENT_REACH * tc.EVENT_MAX_DETOUR:
        return {}
    out = {}
    for leg in routes[0].get("legs") or []:
        ann = leg.get("annotation") or {}
        nodes, dist, dur = ann.get("nodes") or [], ann.get("distance") or [], ann.get("duration") or []
        for i in range(min(len(dist), len(dur), len(nodes) - 1)):
            if dist[i] > 0 and dur[i] > 0 and nodes[i] != nodes[i + 1]:
                out[(nodes[i], nodes[i + 1])] = (dist[i] / dur[i] * 3.6, dist[i])
    return out


def osrm_event_edges(lat, lon, rtype, course, base=EVENT_OSRM, timeout=10):
    """{(u, v): (км/ч графа, метров)} отметки по всем её сторонам."""
    out = {}
    for bearing, tolerance in event_bearings(rtype, course):
        with urllib.request.urlopen(event_route_url(lat, lon, bearing, tolerance, base), timeout=timeout) as resp:
            out.update(event_edges_from_route(json.loads(resp.read())))
    return out


def event_speed(rtype, model):
    """Скорость ребра под отметкой: перекрытие — CLOSURE_KMH, ДТП —
    ACCIDENT_RATIO графа; в [пол, граф], целые км/ч."""
    kmh = tc.CLOSURE_KMH if rtype == "closure" else model * tc.ACCIDENT_RATIO
    return min(model, max(tc.SPEED_FLOOR_KMH, float(round(kmh))))


def event_speeds(events, cache, resolver=osrm_event_edges):
    """({(u, v): (км/ч, км/ч графа)}, {(u, v): метров}, новый кэш).

    Кэш — {str(id): {"key": [lat, lon, тип, курс], "edges": [[u, v, граф, метров]]}}:
    путь отметки считается один раз (шапка), сдвинутая или переписанная
    отметка — заново, ушедшие из кэша выпадают. Отказ OSRM — отметки в этом
    цикле нет (граф без штрафа — меньшее зло, чем выдуманный)."""
    speeds, lengths, fresh = {}, {}, {}
    for rid, lat, lon, rtype, course in events:
        key = [round(lat, 6), round(lon, 6), rtype, None if course is None else round(course, 1)]
        cached = cache.get(str(rid))
        if cached and cached.get("key") == key:
            edges = {(u, v): (model, length) for u, v, model, length in cached.get("edges") or []}
        else:
            try:
                edges = resolver(lat, lon, rtype, course)
            except (urllib.error.URLError, OSError, ValueError) as error:
                print(f"событие {rid}: OSRM не ответил ({error}) — без штрафа в этом цикле", file=sys.stderr)
                continue
        fresh[str(rid)] = {"key": key, "edges": sorted([u, v, round(m, 1), round(d, 1)]
                                                       for (u, v), (m, d) in edges.items())}
        for edge, (model, length) in edges.items():
            kmh = event_speed(rtype, model)
            if edge not in speeds or kmh < speeds[edge][0]:
                speeds[edge] = (kmh, round(model, 1))
                lengths[edge] = length
    return speeds, lengths, fresh


def merge_slowest(base, extra):
    """Объединение двух слоёв: на общем ребре — меньшая скорость."""
    merged = dict(base)
    for edge, value in extra.items():
        if edge not in merged or value[0] < merged[edge][0]:
            merged[edge] = value
    return merged


def load_cache(path):
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as error:
        print(f"кэш событий {path} не прочитан ({error}) — заново", file=sys.stderr)
        return {}


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


def edge_lengths(conn, edges, model=None):
    """{(u, v): метров} по координатам узлов traffic_nodes, а рёбер модели
    (33G) — по её координатам; неизвестно — 1 м."""
    coords = {}
    for (u, v), (_g, _curve, (ulat, ulon, vlat, vlon)) in (model or {}).items():
        coords.setdefault(u, (ulat, ulon))
        coords.setdefault(v, (vlat, vlon))
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


META_SUFFIX = ".meta"     # рядом с файлом скоростей: час недели и живые (38A)
SKIP_EXIT = 10            # --decide: customize не нужен


def read_rows(path, key_len):
    """{ключ: остаток строки} файла скоростей (ключ — u,v) или манёвров
    (u,via,v). Нет файла — пусто: сравнивать не с чем."""
    rows = {}
    try:
        with open(path, encoding="ascii") as f:
            for line in f:
                parts = line.strip().split(",")
                if len(parts) > key_len:
                    rows[tuple(parts[:key_len])] = ",".join(parts[key_len:])
    except FileNotFoundError:
        pass
    return rows


def read_meta(path):
    try:
        with open(path, encoding="utf-8") as f:
            meta = json.load(f)
        return meta if isinstance(meta, dict) else None
    except (FileNotFoundError, ValueError):
        return None


def changed_rows(new, old):
    """(изменено, всего): строки, которых нет в одном из файлов или у которых
    другое значение, и размер объединения ключей."""
    keys = set(new) | set(old)
    return sum(1 for key in keys if new.get(key) != old.get(key)), len(keys)


def customize_decision(new, old, new_turns, old_turns, meta, loaded_meta,
                       min_share=tc.CUSTOMIZE_MIN_SHARE, min_edges=tc.CUSTOMIZE_MIN_EDGES):
    """(нужен ли customize, причина) — сравнение нового расчёта с ЗАГРУЖЕННЫМ
    слотом (а не с прошлым циклом: мелкие сдвиги копятся и в сумме проходят
    порог). Сомнение — в сторону запуска: так работал цикл до 38A."""
    edges, edges_total = changed_rows(new, old)
    turns, turns_total = changed_rows(new_turns, old_turns)
    changed, total = edges + turns, edges_total + turns_total
    if changed == 0:
        return False, "без изменений"
    if not new and not new_turns:
        return True, "пробки сняты — граф без пробок"
    if meta is None or meta.get("error"):
        return True, "нет сведений о расчёте — как раньше"
    live, events = int(meta.get("live") or 0), int(meta.get("events") or 0)
    if live or events:
        return True, f"живых рёбер {live}, событий {events}"
    slot = meta.get("slot")
    loaded = (loaded_meta or {}).get("slot")
    if slot != loaded:
        return True, f"час недели {loaded if loaded is not None else '?'} → {slot}, изменено {changed}"
    share = changed / total
    if share >= min_share and changed >= min_edges:
        return True, f"изменено {changed} из {total} ({share:.0%})"
    return False, (f"живых нет, час недели тот же ({slot}), изменено {changed} из {total} "
                   f"({share:.1%}) — ниже порога {min_share:.0%} и {min_edges} строк")


def decide(slot_dir, out, turns_out):
    """--decide: код выхода 0 — customize нужен, SKIP_EXIT — нет; причина в stdout."""
    run, reason = customize_decision(
        read_rows(out, 2), read_rows(os.path.join(slot_dir, os.path.basename(out)), 2),
        read_rows(turns_out, 3) if turns_out else {},
        read_rows(os.path.join(slot_dir, os.path.basename(turns_out)), 3) if turns_out else {},
        read_meta(out + META_SUFFIX),
        read_meta(os.path.join(slot_dir, os.path.basename(out) + META_SUFFIX)))
    print(reason)
    return 0 if run else SKIP_EXIT


def write_meta(out, now, stats, error=False):
    """Сведения о расчёте для решения customize: час недели, живые рёбра,
    рёбра событий. Ни координат, ни времени отметок — только числа."""
    meta = {"slot": tb.week_slot(now), "live": int(stats.get("live", 0)),
            "events": int(stats.get("event_edges", 0))}
    if error:
        meta["error"] = True
    write_if_changed(out + META_SUFFIX, json.dumps(meta, sort_keys=True))


def route_files(args, now, steps, resolver=None):
    """Шаги источника route: (рёбра, счётчики). Исключение — наружу (main
    пишет пустой файл)."""
    resolver = resolver or osrm_event_edges
    previous = read_previous(args.out)
    started = time.perf_counter()
    model = tm.load_model(args.model) if args.model else {}
    steps["модель"] = time.perf_counter() - started
    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True, timeout=5)
    try:
        started = time.perf_counter()
        speeds_kmh, graph, stats = tp.route_edges(conn, now, previous, model=model)
        steps["профиль"] = time.perf_counter() - started
        edges = {edge: (kmh, graph[edge]) for edge, kmh in speeds_kmh.items()}
        lengths = edge_lengths(conn, edges, model)
        stats["events"] = 0
        if args.reports_db and tc.LAYER_EVENTS:
            started = time.perf_counter()
            events = confirmed_events(args.reports_db, now)
            event_kmh, event_lengths, cache = event_speeds(events, load_cache(args.events_cache), resolver=resolver)
            if args.events_cache:
                write_if_changed(args.events_cache, json.dumps(cache, sort_keys=True))
            edges = merge_slowest(edges, event_kmh)
            lengths.update(event_lengths)
            stats["events"] = len(cache)
            stats["event_edges"] = len(event_kmh)
            steps["события"] = time.perf_counter() - started
        edges, trimmed = cap(edges, lengths, tc.MAX_SPEED_EDGES, args.mode)
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


def main(argv=None, resolver=None):
    parser = argparse.ArgumentParser(description="Скорости рёбер для osrm-customize")
    parser.add_argument("--db", default=tb.DB_PATH)
    parser.add_argument("--out", default="/opt/radarmap/osrm-mld/speeds.csv")
    parser.add_argument("--source", choices=SOURCES, default="now")
    parser.add_argument("--mode", choices=MODES, default="weight",
                        help="weight — пробка только в выборе пути (по умолчанию), duration — и во времени")
    parser.add_argument("--bucket", help="файл «обычно»: wd-08, off-18 (по умолчанию — текущий час)")
    parser.add_argument("--now", type=float, help="момент расчёта, для проверки (по умолчанию — сейчас)")
    parser.add_argument("--turns-out", help="файл штрафов манёвров (33B; только с --source route)")
    parser.add_argument("--reports-db", help="reports.db: подтверждённые ДТП и перекрытия (33D; только route)")
    parser.add_argument("--events-cache", help="кэш путей отметок (JSON рядом с файлом скоростей)")
    parser.add_argument("--model", default=tc.MODEL_PATH if tc.LAYER_MODEL else "",
                        help="файл модели обычных пробок (33G; пусто — без модели)")
    parser.add_argument("--decide", metavar="SLOT_DIR",
                        help="38A: нужен ли customize — сравнить --out/--turns-out с загруженным слотом "
                             f"(выход 0 — да, {SKIP_EXIT} — нет)")
    args = parser.parse_args(argv)
    if args.decide:
        return decide(args.decide, args.out, args.turns_out)
    if (args.turns_out or args.reports_db) and args.source != "route":
        parser.error("--turns-out и --reports-db — только с --source route")
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
            edges, turns, stats = route_files(args, now, steps, resolver)
        except Exception as error:  # noqa: BLE001 — инвариант 1: любая ошибка — граф
            write_if_changed(args.out, "")
            if args.turns_out:
                write_if_changed(args.turns_out, "")
            write_meta(args.out, now, {}, error=True)
            print(f"{stamp} скорости (route): ОШИБКА {type(error).__name__}: {error} — "
                  f"файл пустой (граф без пробок) → {args.out}")
            return 1
        changed = write_if_changed(args.out, csv_body(edges, args.mode))
        if args.turns_out:
            changed = write_if_changed(args.turns_out, turns_body(turns)) or changed
        write_meta(args.out, now, stats)
        steps["всего"] = time.perf_counter() - started
        timing = ", ".join(f"{name} {seconds * 1000:.0f} мс" for name, seconds in steps.items())
        result = "ок" if edges or turns else "пусто"
        trimmed = f", ПОТОЛОК: обрезано {stats['trimmed']}" if stats.get("trimmed") else ""
        print(f"{stamp} скорости (route, {args.mode}): слоты {stats['slots']}, рёбер типичных "
              f"{stats['typical']}, модели {stats['model']}, живых {stats['live']}, событий {stats['events']}, записано {len(edges)} "
              f"(гистерезис {stats['kept']}), манёвров {len(turns) if args.turns_out else '—'}{trimmed}; {timing}; {result}, "
              f"{'изменён' if changed else 'без изменений'} → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
