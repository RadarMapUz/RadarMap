#!/usr/bin/env python3
"""Пробки из кусков следа водителей: OSRM match → скорость на ребре OSM →
traffic/now.json для телефонов.

Запуск — cron раз в 2 минуты на VPS (stdlib, без pip):
    */2 * * * * python3 /opt/radarmap/api/traffic_build.py >> /var/log/radarmap-traffic.log 2>&1

Шаги одного прогона:
  1. Новые куски (POST /api/traffic) сопоставляются с дорогами нашим OSRM
     (`match`, тот же граф, что строит маршруты). Ответ даёт по каждому
     отрезку пару узлов OSM и длину, а время между точками следа — из куска:
     скорость = длина участка / время. Кусок удаляется сразу после
     сопоставления: сырой след живёт минуты, дальше остаются только скорости
     на рёбрах.
  2. Текущая скорость ребра — взвешенная медиана за SAMPLE_WINDOW, и только
     если её подтвердили MIN_PIECES разных кусков: один водитель, вставший у
     обочины, пробку не рисует.
  3. Уровень — от отношения текущей скорости к скорости графа (car.lua) на
     этом ребре: свободно / медленно / пробка. Скорость графа есть с первого
     дня, поэтому холодного старта у «свободной скорости» нет; обычная
     скорость по часу недели копится в traffic_profile — для прогноза
     «если выехать в 8:30».
  4. now.json атомарно в webroot: рёбра с координатами узлов, уровнем,
     текущей скоростью и скоростью графа — по последней телефон считает,
     на сколько пробка удлиняет его маршрут:
       {"v": 1, "generated": t, "edges": [[ulat, ulon, vlat, vlon, level, kmh, model_kmh]]}
     Пробки — данные для показа (как отметки водителей), на оповещения о
     камерах не влияют, поэтому файл не подписывается.

Единица — направленное ребро OSM (u, v): ключ постоянен между обновлениями
графа, и это тот же формат, что `--segment-speed-file` у OSRM (следующий
шаг — MLD + customize, маршрут прямо с учётом пробок).
"""
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

DB_PATH = "/opt/radarmap/api/traffic.db"
OSRM = "http://127.0.0.1:8092"
OUT_PATH = "/opt/radarmap/www/traffic/now.json"

PIECE_TTL = 20 * 60          # кусок, который не удалось сопоставить, не живёт дольше
SAMPLE_WINDOW = 15 * 60      # «текущая» скорость — за последние 15 минут
SAMPLE_KEEP = 60 * 60        # сырые скорости рёбер хранятся час
MIN_PIECES = 2               # независимых кусков на ребро, чтобы показать его
MIN_CONFIDENCE = 0.1         # совпадение OSRM ниже — кусок не про дорогу
MATCH_RADIUS = 25            # метров: GPS в городе + ширина проспекта
MAX_KMH = 150.0
JAM_RATIO = 0.35             # ниже — пробка (красный)
SLOW_RATIO = 0.6             # ниже — медленно (жёлтый)
TASHKENT_UTC_OFFSET = 5 * 3600
OUTPUT_VERSION = 1


def schema(conn):
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_pieces(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        received REAL NOT NULL,
        points TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_samples(
        u INTEGER NOT NULL, v INTEGER NOT NULL,
        kmh REAL NOT NULL, weight REAL NOT NULL,
        ts REAL NOT NULL, piece INTEGER NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS traffic_samples_ts ON traffic_samples(ts)")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_nodes(
        id INTEGER PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_edges(
        u INTEGER NOT NULL, v INTEGER NOT NULL, model_kmh REAL NOT NULL,
        PRIMARY KEY(u, v))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_profile(
        u INTEGER NOT NULL, v INTEGER NOT NULL, how INTEGER NOT NULL,
        n INTEGER NOT NULL, sum_kmh REAL NOT NULL,
        PRIMARY KEY(u, v, how))""")
    conn.commit()


# --- Сопоставление ----------------------------------------------------------

def match_url(points, base=OSRM):
    coords = ";".join(f"{lon:.5f},{lat:.5f}" for lat, lon, _, _ in points)
    times = ";".join(str(int(t)) for _, _, t, _ in points)
    radii = ";".join(str(MATCH_RADIUS) for _ in points)
    return (f"{base}/match/v1/driving/{coords}?timestamps={times}&radiuses={radii}"
            "&annotations=nodes,distance,duration&overview=full&geometries=geojson"
            "&tidy=true&gaps=split")


def osrm_match(points, base=OSRM, timeout=10):
    with urllib.request.urlopen(match_url(points, base), timeout=timeout) as resp:
        return json.loads(resp.read())


def edges_from_match(response, points):
    """Скорости по рёбрам из ответа OSRM.

    Возвращает (samples, nodes, models):
      samples — [(u, v, kmh, weight_m)], скорость участка между соседними
                точками следа на каждом ребре этого участка, вес — длина
                отрезка ребра внутри участка;
      nodes   — {id: (lat, lon)} узлов, чьё положение видно в геометрии;
      models  — {(u, v): kmh} скорость графа на ребре (длина / время OSRM).

    Геометрия совпадения — склейка участков: отрезок j участка идёт от
    G[o+j] к G[o+j+1], а внутренние точки G[o+1..o+m-1] — это узлы
    nodes[1..m-1] участка (nodes[0] и nodes[m] лежат за точками следа).
    Проверено на ответе прод-OSRM (fixtures/osrm_match_amir_temur.json).
    """
    samples, nodes, models = [], {}, {}
    if response.get("code") != "Ok":
        return samples, nodes, models
    tracepoints = response.get("tracepoints") or []
    for index, matching in enumerate(response.get("matchings") or []):
        if (matching.get("confidence") or 0) < MIN_CONFIDENCE:
            continue
        # Точки следа этого совпадения по порядку — концы его участков.
        ends = sorted((tp["waypoint_index"], i) for i, tp in enumerate(tracepoints)
                      if tp and tp.get("matchings_index") == index)
        legs = matching.get("legs") or []
        if len(ends) != len(legs) + 1:
            continue
        geometry = (matching.get("geometry") or {}).get("coordinates") or []
        offset = 0
        for k, leg in enumerate(legs):
            annotation = leg.get("annotation") or {}
            ids = annotation.get("nodes") or []
            dist = annotation.get("distance") or []
            dur = annotation.get("duration") or []
            m = len(dist)
            if m == 0 or len(ids) != m + 1:
                offset += m
                continue
            for j in range(1, m):
                if offset + j < len(geometry):
                    lon, lat = geometry[offset + j]
                    nodes[ids[j]] = (lat, lon)
            offset += m
            a, b = ends[k][1], ends[k + 1][1]
            dt = points[b][2] - points[a][2]
            length = leg.get("distance") or 0
            if dt <= 0:
                continue
            kmh = min(MAX_KMH, length / dt * 3.6)
            for j in range(m):
                if dist[j] <= 0:
                    continue
                edge = (ids[j], ids[j + 1])
                samples.append((edge[0], edge[1], kmh, dist[j]))
                if j < len(dur) and dur[j] > 0:
                    models[edge] = dist[j] / dur[j] * 3.6
    return samples, nodes, models


def hour_of_week(ts):
    """Час недели по Ташкенту: 0 — понедельник 00:00."""
    t = time.gmtime(ts + TASHKENT_UTC_OFFSET)
    return t.tm_wday * 24 + t.tm_hour


def store(conn, piece_id, samples, nodes, models, now):
    how = hour_of_week(now)
    conn.executemany("INSERT INTO traffic_samples(u, v, kmh, weight, ts, piece) VALUES(?, ?, ?, ?, ?, ?)",
                     [(u, v, kmh, w, now, piece_id) for u, v, kmh, w in samples])
    conn.executemany("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, ?, ?)",
                     [(i, lat, lon) for i, (lat, lon) in nodes.items()])
    conn.executemany("INSERT OR REPLACE INTO traffic_edges(u, v, model_kmh) VALUES(?, ?, ?)",
                     [(u, v, kmh) for (u, v), kmh in models.items()])
    conn.executemany("""INSERT INTO traffic_profile(u, v, how, n, sum_kmh) VALUES(?, ?, ?, 1, ?)
                        ON CONFLICT(u, v, how) DO UPDATE SET n = n + 1, sum_kmh = sum_kmh + excluded.sum_kmh""",
                     [(u, v, how, kmh) for u, v, kmh, _ in samples])


def process(conn, now, matcher=osrm_match):
    """Сопоставить все ждущие куски. Сопоставленный кусок удаляется сразу;
    не сопоставленный (OSRM лежит) ждёт следующего прогона, но не дольше
    PIECE_TTL. Возвращает (кусков, отрезков)."""
    rows = conn.execute("SELECT id, points FROM traffic_pieces ORDER BY id").fetchall()
    done = matched = 0
    for piece_id, raw in rows:
        points = json.loads(raw)
        try:
            response = matcher(points)
        except (urllib.error.URLError, OSError, ValueError) as error:
            print(f"OSRM недоступен: {error}", file=sys.stderr)
            break
        samples, nodes, models = edges_from_match(response, points)
        store(conn, piece_id, samples, nodes, models, now)
        conn.execute("DELETE FROM traffic_pieces WHERE id = ?", (piece_id,))
        done += 1
        matched += len(samples)
    conn.commit()
    return done, matched


def prune(conn, now):
    conn.execute("DELETE FROM traffic_pieces WHERE received < ?", (now - PIECE_TTL,))
    conn.execute("DELETE FROM traffic_samples WHERE ts < ?", (now - SAMPLE_KEEP,))
    conn.commit()


# --- Агрегация и выход --------------------------------------------------------

def weighted_median(pairs):
    """Медиана значений с весами: [(value, weight)]."""
    pairs = sorted(pairs)
    total = sum(w for _, w in pairs)
    if total <= 0:
        return None
    acc = 0.0
    for value, weight in pairs:
        acc += weight
        if acc >= total / 2:
            return value
    return pairs[-1][0]


def level(kmh, model_kmh):
    """1 — свободно, 2 — медленно, 3 — пробка."""
    if not model_kmh or model_kmh <= 0:
        return None
    ratio = kmh / model_kmh
    if ratio < JAM_RATIO:
        return 3
    if ratio < SLOW_RATIO:
        return 2
    return 1


def aggregate(conn, now):
    """Рёбра для выхода: [(ulat, ulon, vlat, vlon, level, kmh, model_kmh)]."""
    rows = conn.execute("""SELECT s.u, s.v, s.kmh, s.weight, s.piece, e.model_kmh,
                                  a.lat, a.lon, b.lat, b.lon
                           FROM traffic_samples s
                           JOIN traffic_edges e ON e.u = s.u AND e.v = s.v
                           JOIN traffic_nodes a ON a.id = s.u
                           JOIN traffic_nodes b ON b.id = s.v
                           WHERE s.ts >= ?""", (now - SAMPLE_WINDOW,)).fetchall()
    grouped = {}
    for u, v, kmh, weight, piece, model, alat, alon, blat, blon in rows:
        entry = grouped.setdefault((u, v), {"pairs": [], "pieces": set(), "model": model,
                                            "coords": (alat, alon, blat, blon)})
        entry["pairs"].append((kmh, weight))
        entry["pieces"].add(piece)
    out = []
    for entry in grouped.values():
        if len(entry["pieces"]) < MIN_PIECES:
            continue
        kmh = weighted_median(entry["pairs"])
        lvl = level(kmh, entry["model"]) if kmh is not None else None
        if lvl is None:
            continue
        alat, alon, blat, blon = entry["coords"]
        out.append((alat, alon, blat, blon, lvl, kmh, entry["model"]))
    return out


def payload(edges, now):
    return {
        "v": OUTPUT_VERSION,
        "generated": int(now),
        "edges": [[round(a, 5), round(b, 5), round(c, 5), round(d, 5), lvl,
                   int(round(kmh)), int(round(model))]
                  for a, b, c, d, lvl, kmh, model in edges],
    }


def write_atomic(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(tmp, path)


def main():
    now = time.time()
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.execute("PRAGMA busy_timeout = 5000")
    schema(conn)
    pieces, segments = process(conn, now)
    prune(conn, now)
    edges = aggregate(conn, now)
    write_atomic(OUT_PATH, json.dumps(payload(edges, now), separators=(",", ":")))
    conn.close()
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} кусков {pieces}, отрезков {segments}, рёбер в выходе {len(edges)}")


if __name__ == "__main__":
    main()
