#!/usr/bin/env python3
"""Скорость ребра для маршрутизатора — типичная по профилю часа недели плюс
живые куски поверх (33A, docs/spec_traffic_33.md; константы —
traffic_config.py). Читает traffic.db сборщика (traffic_build.py) только на
чтение; пишет файл traffic_speeds.py.

Формулы — ровно спецификация:
  * слот — час недели 0–167 по Ташкенту (traffic_build.week_slot);
    наблюдение — кусок, прошедший ребро насквозь, со своей скоростью и днём;
  * скорость слота — МЕДИАНА наблюдений: один медленный кусок (встал у
    обочины) её не двигает;
  * слот годен при n ≥ SLOT_MIN_DAYS разных дней и ≥ SLOT_MIN_PIECES кусков;
    v_typ = (n·v_med + k·v_graph) / (n + k), k = SHRINK_K: при малом n
    типичная близка к графу;
  * плавность: минута m часа — смесь текущего и следующего слота, α = m/60
    (слот без годных данных — скорость графа); воскресенье 23:xx →
    понедельник 0 — тем же механизмом (следующий слот — час спустя);
  * живое: n_live независимых кусков за LIVE_MAX_AGE (как now.json), вес
    w = min(1, n_live/LIVE_FULL_PIECES) · exp(−age/LIVE_TAU), age — возраст
    самого свежего куска, старше LIVE_MAX_AGE — 0; для пути живое
    участвует только с ROUTE_MIN_PIECES кусков (33F);
  * итог v = w·v_live + (1−w)·v_base, v_base — смесь слотов;
  * в файл — только v < WRITE_RATIO·граф, в пределах [SPEED_FLOOR_KMH, граф];
  * гистерезис: ребро меняет значение прошлого файла, только если сдвиг ≥
    max(HYST_KMH, HYST_SHARE·прошлое); иначе остаётся прошлое.

Сверх спецификации — одна защита, та же, что у файлов «обычно» для
телефонов: ребро идёт в типичный слой, только если по нему ездит не один
человек (traffic_shared за SHARED_TTL). «Три разных дня» её не заменяют:
один водитель, каждый будний день едущий в 8:00 по своей улице, набирает
три дня за полнедели.
"""
import math

import traffic_build as tb
import traffic_config as tc


# --- Чистые формулы ---------------------------------------------------------------

def median(values):
    """Медиана списка; пусто — None."""
    ordered = sorted(values)
    if not ordered:
        return None
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2


def shrink(v_med, n, v_graph, k=tc.SHRINK_K):
    """Сжатие к графу: (n·v_med + k·v_graph) / (n + k)."""
    return (n * v_med + k * v_graph) / (n + k)


def slot_typical(observations, v_graph):
    """Типичная скорость слота по наблюдениям [(день, км/ч)] или None — слот
    не годен (меньше SLOT_MIN_DAYS дней или SLOT_MIN_PIECES кусков)."""
    days = {day for day, _ in observations}
    if len(days) < tc.SLOT_MIN_DAYS or len(observations) < tc.SLOT_MIN_PIECES or v_graph <= 0:
        return None
    return shrink(median([kmh for _, kmh in observations]), len(days), v_graph)


def slot_mix(now):
    """[(слот, вес)] для момента: текущий час недели с весом 1 − m/60 и
    следующий — с m/60. Следующий — слот момента на час позже: так переход
    167 → 0 и праздники решает week_slot, а не отдельный случай."""
    minute = (now + tb.TASHKENT_UTC_OFFSET) % 3600 / 60.0
    alpha = minute / 60.0
    return [(tb.week_slot(now), 1.0 - alpha), (tb.week_slot(now + 3600), alpha)]


def base_speed(slots, v_graph):
    """v_base: смесь слотов [(типичная или None, вес)]; негодный слот — граф."""
    return sum(weight * (v_graph if v is None else v) for v, weight in slots)


def live_weight(n_live, age):
    """w = min(1, n/LIVE_FULL_PIECES)·exp(−age/τ); старше LIVE_MAX_AGE или
    меньше ROUTE_MIN_PIECES кусков — 0."""
    if n_live < tc.ROUTE_MIN_PIECES or age > tc.LIVE_MAX_AGE or age < 0:
        return 0.0
    return min(1.0, n_live / tc.LIVE_FULL_PIECES) * math.exp(-age / tc.LIVE_TAU)


def blend(v_live, w, v_base):
    return w * v_live + (1.0 - w) * v_base


def keep_previous(v, previous):
    """True — сдвиг меньше гистерезиса, остаётся прошлое значение."""
    return previous is not None and abs(v - previous) < max(tc.HYST_KMH, tc.HYST_SHARE * previous)


def file_speed(v, v_graph):
    """Скорость для файла (целые км/ч в [пол, граф]) или None — ребро не
    пишется: итог не медленнее WRITE_RATIO графа (инвариант 6)."""
    if v_graph <= 0:
        return None
    speed = min(v_graph, max(tc.SPEED_FLOOR_KMH, float(round(v))))
    return speed if speed < tc.WRITE_RATIO * v_graph else None


# --- Данные traffic.db --------------------------------------------------------------

def slot_observations(conn, now, slots):
    """{(u, v): {слот: [(день, км/ч)]}} для слотов `slots` за
    PROFILE_KEEP_DAYS, только рёбра «не одного человека» (шапка)."""
    marks = ",".join("?" for _ in slots)
    rows = conn.execute(f"""SELECT o.u, o.v, o.slot, o.day, o.kmh FROM traffic_slot_obs o
                            JOIN traffic_shared s ON s.u = o.u AND s.v = o.v
                            WHERE o.slot IN ({marks}) AND o.day >= ? AND s.seen >= ?""",
                        (*slots, tb.day_number(now) - tc.PROFILE_KEEP_DAYS,
                         now - tb.SHARED_TTL)).fetchall()
    out = {}
    for u, v, slot, day, kmh in rows:
        out.setdefault((u, v), {}).setdefault(slot, []).append((day, kmh))
    return out


def live_observations(conn, now):
    """{(u, v): (v_live, n_live, возраст свежего куска)} за LIVE_MAX_AGE:
    скорость — взвешенная медиана отрезков (как now.json), свидетели и
    возраст — только куски, прошедшие ребро насквозь."""
    rows = conn.execute("""SELECT u, v, kmh, weight, piece, passed, ts FROM traffic_samples
                           WHERE ts >= ?""", (now - tc.LIVE_MAX_AGE,)).fetchall()
    grouped = {}
    for u, v, kmh, weight, piece, passed, ts in rows:
        entry = grouped.setdefault((u, v), {"pairs": [], "pieces": set(), "fresh": None})
        entry["pairs"].append((kmh, weight))
        if passed:
            entry["pieces"].add(piece)
            entry["fresh"] = ts if entry["fresh"] is None else max(entry["fresh"], ts)
    out = {}
    for edge, entry in grouped.items():
        speed = tb.weighted_median(entry["pairs"])
        if entry["pieces"] and speed is not None:
            out[edge] = (speed, len(entry["pieces"]), now - entry["fresh"])
    return out


def graph_speeds(conn):
    return {(u, v): kmh for u, v, kmh in conn.execute("SELECT u, v, model_kmh FROM traffic_edges")
            if kmh and kmh > 0}


def route_edges(conn, now, previous=None, typical=tc.LAYER_TYPICAL, live=tc.LAYER_LIVE):
    """({(u, v): км/ч для файла}, {(u, v): км/ч графа}, счётчики) — слой
    33A для маршрутизатора. `previous` — {(u, v): км/ч} прошлого файла для
    гистерезиса. Ребро без графа, без годного слота и без живых — нет строки
    (отказ = граф)."""
    previous = previous or {}
    graph = graph_speeds(conn)
    mix = slot_mix(now)
    slots = sorted({slot for slot, _ in mix})
    observed = slot_observations(conn, now, slots) if typical else {}
    fresh = live_observations(conn, now) if live else {}
    stats = {"slots": "/".join(str(slot) for slot, _ in mix), "typical": 0, "live": 0,
             "written": 0, "kept": 0}
    out = {}
    for edge in sorted(set(observed) | set(fresh)):
        v_graph = graph.get(edge)
        if not v_graph:
            continue
        per_slot = [(slot_typical(observed.get(edge, {}).get(slot, []), v_graph), weight)
                    for slot, weight in mix]
        has_typical = any(v is not None and weight > 0 for v, weight in per_slot)
        v = base_speed(per_slot, v_graph)
        w = 0.0
        if edge in fresh:
            v_live, n_live, age = fresh[edge]
            w = live_weight(n_live, age)
            v = blend(v_live, w, v)
        if not has_typical and w <= 0:
            continue
        stats["typical"] += has_typical
        stats["live"] += w > 0
        prev = previous.get(edge)
        if keep_previous(v, prev):
            speed = file_speed(prev, v_graph)
            stats["kept"] += speed is not None
        else:
            speed = file_speed(v, v_graph)
        if speed is not None:
            out[edge] = speed
    stats["written"] = len(out)
    return out, graph, stats


# --- Манёвры (33B) ----------------------------------------------------------------

def turn_penalty(observations):
    """Штраф манёвра по наблюдениям слота [(день, секунд, угол)]: (секунд,
    оценка профиля) или None — манёвр не годен (меньше TURN_MIN_PIECES кусков
    или TURN_MIN_DAYS дней) либо медиана не больше штрафа профиля на
    TURN_MARGIN. Файл заменяет штраф профиля (опыт 33B), поэтому значение —
    полная медиана, целые секунды."""
    days = {day for day, _, _ in observations}
    if len(observations) < tc.TURN_MIN_PIECES or len(days) < tc.TURN_MIN_DAYS:
        return None
    delay = min(tc.TURN_MAX_DELAY, max(0.0, median([d for _, d, _ in observations])))
    base = tb.profile_turn_ceiling(median([a for _, _, a in observations]))
    if delay <= base + tc.TURN_MARGIN:
        return None
    return int(round(delay)), base


def turn_penalties(conn, now, enabled=tc.LAYER_TURNS):
    """[(u, v, w, секунд, значимость)] для --turn-penalty-file в слоте часа
    недели момента `now`, по возрастанию тройки; значимость — превышение над
    профилем (для потолка MAX_TURNS). Только манёвры «не одного человека»:
    въезд или выезд прошли два куска вместе за SHARED_TTL (как у профиля)."""
    if not enabled:
        return []
    rows = conn.execute("""SELECT o.u, o.v, o.w, o.day, o.delay, o.angle FROM traffic_turn_obs o
                           WHERE o.slot = ? AND o.day >= ? AND (
                               EXISTS(SELECT 1 FROM traffic_shared s WHERE s.u = o.u AND s.v = o.v AND s.seen >= ?)
                            OR EXISTS(SELECT 1 FROM traffic_shared s WHERE s.u = o.v AND s.v = o.w AND s.seen >= ?))""",
                        (tb.week_slot(now), tb.day_number(now) - tc.PROFILE_KEEP_DAYS,
                         now - tb.SHARED_TTL, now - tb.SHARED_TTL)).fetchall()
    grouped = {}
    for u, v, w, day, delay, angle in rows:
        grouped.setdefault((u, v, w), []).append((day, delay, angle))
    out = []
    for key in sorted(grouped):
        got = turn_penalty(grouped[key])
        if got:
            out.append(key + (got[0], got[0] - got[1]))
    return out


# --- profile.json для телефона (33C) -------------------------------------------------

def profile_edges(conn, now):
    """Рёбра профиля для телефона: [[ulat, ulon, vlat, vlon, км/ч графа,
    [[слот, км/ч], …]]] — только годные слоты медленнее WRITE_RATIO графа (та
    же типичная, что идёт в маршрутизатор), только рёбра «не одного
    человека». Ни дней, ни кусков, ни времени наблюдений — слот часа недели и
    скорость."""
    rows = conn.execute("""SELECT o.u, o.v, o.slot, o.day, o.kmh, e.model_kmh, a.lat, a.lon, b.lat, b.lon
                           FROM traffic_slot_obs o
                           JOIN traffic_shared s ON s.u = o.u AND s.v = o.v
                           JOIN traffic_edges e ON e.u = o.u AND e.v = o.v
                           JOIN traffic_nodes a ON a.id = o.u
                           JOIN traffic_nodes b ON b.id = o.v
                           WHERE o.day >= ? AND s.seen >= ? AND e.model_kmh > 0""",
                        (tb.day_number(now) - tc.PROFILE_KEEP_DAYS, now - tb.SHARED_TTL)).fetchall()
    grouped = {}
    for u, v, slot, day, kmh, model, alat, alon, blat, blon in rows:
        entry = grouped.setdefault((u, v), {"model": model, "coords": (alat, alon, blat, blon), "slots": {}})
        entry["slots"].setdefault(slot, []).append((day, kmh))
    out = []
    for edge in sorted(grouped):
        entry = grouped[edge]
        slots = []
        for slot in sorted(entry["slots"]):
            v = slot_typical(entry["slots"][slot], entry["model"])
            if v is not None and round(v) < tc.WRITE_RATIO * entry["model"]:
                slots.append([slot, int(max(tc.SPEED_FLOOR_KMH, round(v)))])
        if slots:
            a, b, c, d = entry["coords"]
            out.append([round(a, 5), round(b, 5), round(c, 5), round(d, 5), int(round(entry["model"])), slots])
    return out


def profile_payload(edges, now):
    return {"v": tc.PROFILE_JSON_VERSION, "generated": int(now), "edges": edges}


def profile_body(conn, now, max_gzip=tc.PROFILE_JSON_MAX_GZIP):
    """(тело profile.json, рёбер, обрезано). Больше max_gzip в gzip — рёбра
    по убыванию значимости (длина × среднее замедление по слотам), пока не
    влезет."""
    import gzip
    import json
    edges = profile_edges(conn, now)

    def body(items):
        return json.dumps(profile_payload(items, now), separators=(",", ":"))

    text = body(edges)
    if len(gzip.compress(text.encode(), 6)) <= max_gzip:
        return text, len(edges), 0

    def weight(edge):
        k = math.cos(math.radians(edge[0])) * 111320.0
        length = math.hypot((edge[1] - edge[3]) * k, (edge[0] - edge[2]) * 111320.0)
        slow = sum(1 - kmh / edge[4] for _, kmh in edge[5]) / len(edge[5])
        return -length * slow
    ranked = sorted(edges, key=weight)
    keep = len(ranked)
    while keep > 0:
        keep = int(keep * 0.9)
        text = body(sorted(ranked[:keep]))
        if len(gzip.compress(text.encode(), 6)) <= max_gzip:
            break
    return text, keep, len(edges) - keep
