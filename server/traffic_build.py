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
  5. Раз в час — «обычно по водителям» (план 19.10, 8.8.16): traffic/typical/
     <класс дня>-<час>.json из traffic_profile, холодный старт «дороги на
     работу», пока у водителя нет трёх своих поездок:
       {"v": 1, "bucket": "wd-08", "generated": t, "edges": [[ulat, ulon, vlat, vlon, kmh]]}
     Класс дня — будни (wd, пн–пт) или выходные (off, сб–вс и праздники
     Узбекистана по ташкентской дате — тот же список, что UzHolidays на
     телефоне: кусок из Навруза во вторник ложится в off, как и запрос
     телефона в этот день), а не 168 часов
     недели: холодный старт — ровно тогда, когда данных мало, и пять будних
     восьми утра, сложенные в один файл, набирают порог впятеро быстрее, а
     дорога во вторник в 8:00 от среды в 8:00 не отличается. Ребро попадает
     в файл, только если его прошли не меньше TYPICAL_MIN_PIECES кусков в этот
     час И хоть раз два куска прошли его вместе (в одном окне now.json): один
     человек, каждый будний день едущий в 8:00 по своей улице, набирает пять
     кусков за неделю — но не два одновременно, и его улица публичной не
     становится. Скорость — гармоническое среднее (через время на километр):
     время в пути — это сумма времён, и среднее км/ч по пробке 5 и свободе 50
     дало бы 27 вместо честных 9. Файл переписывается, только если рёбра
     сменились: телефон проверяет его с ETag, и неизменный файл стоит 304.

Единица — направленное ребро OSM (u, v): ключ постоянен между обновлениями
графа, и это тот же формат, что `--segment-speed-file` у OSRM (следующий
шаг — MLD + customize, маршрут прямо с учётом пробок).
"""
import datetime
import functools
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
SEEN_TTL = 30 * 60           # отпечатки повторов: как TRAFFIC_SEEN_TTL в api.py
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

TYPICAL_DIR = "/opt/radarmap/www/traffic/typical"
TYPICAL_MIN_PIECES = 5       # кусков на ребро в этот класс дня и час
TYPICAL_EVERY = 60 * 60      # «обычно» пересобирается не чаще раза в час
TYPICAL_VERSION = 1
PACE_MIN_KMH = 3.0           # ниже — «стоим»: темп не уходит в бесконечность
DAY_CLASSES = ("wd", "off")  # будни (пн–пт), выходные (сб–вс)


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
    # «Обычно по водителям» (8.8.16): кусков, а не отрезков (кусок, чьи две
    # точки следа легли на одно ребро, давал два «наблюдения»), и сумма темпа
    # (с/км) — для гармонического среднего. Старые строки — с нулями: в
    # typical они не идут, «обычно» копится с выкладки.
    columns = {row[1] for row in conn.execute("PRAGMA table_info(traffic_profile)")}
    if "pieces" not in columns:
        conn.execute("ALTER TABLE traffic_profile ADD COLUMN pieces INTEGER NOT NULL DEFAULT 0")
    if "sum_pace" not in columns:
        conn.execute("ALTER TABLE traffic_profile ADD COLUMN sum_pace REAL NOT NULL DEFAULT 0")
    # Рёбра, которые хоть раз прошли два куска в одном окне now.json — то
    # есть не один человек.
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_shared(
        u INTEGER NOT NULL, v INTEGER NOT NULL, PRIMARY KEY(u, v))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_meta(
        key TEXT PRIMARY KEY, value REAL NOT NULL)""")
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


# --- Праздники Узбекистана ----------------------------------------------------
# Зеркало RadarMap/Models/UzHolidays.swift (8.8.13): телефон ищет файл
# «обычно» праздничного дня в выходном классе, значит и сервер должен класть
# туда кусок, снятый в праздник — иначе Навруз во вторник портит будничный
# файл, а праздничный выходной его не видит. Списки сверяет тест
# (test_traffic_build.HolidayTest) — правка одного без другого его роняет.

# Постоянные праздники (Трудовой кодекс, ст. 132): (месяц, день).
HOLIDAYS_FIXED = ((1, 1), (3, 8), (3, 21), (5, 9), (9, 1), (10, 1), (12, 8))
# Хайиты и дополнительные нерабочие дни по годам; 2027–2028 — оценка, как
# в UzHolidays.moving (сверять с постановлением года — в обоих местах).
HOLIDAYS_MOVING = {
    2026: ((3, 20), (5, 27), (5, 28), (5, 29)),
    2027: ((3, 9), (5, 16)),
    2028: ((2, 26), (5, 5)),
}
HOLIDAY_SLOT = 168           # how праздника = час недели + 168 (см. profile_slot)


@functools.lru_cache(maxsize=None)
def holidays(year):
    """Нерабочие праздничные дни года как месяц × 100 + день, с переносом:
    праздник в субботу или воскресенье даёт ближайший рабочий день, который
    ещё не праздник и не занят прежним переносом (UzHolidays.days)."""
    listed = HOLIDAYS_FIXED + HOLIDAYS_MOVING.get(year, ())
    result = {month * 100 + day for month, day in listed}
    for month, day in sorted(listed):
        date = datetime.date(year, month, day)
        if date.weekday() < 5:
            continue
        for _ in range(10):
            date += datetime.timedelta(days=1)
            key = date.month * 100 + date.day
            if date.weekday() < 5 and key not in result and date.year == year:
                result.add(key)
                break
    return frozenset(result)


def is_holiday(ts):
    """Праздник по ташкентской дате момента `ts` (часовой пояс сервера не
    участвует: gmtime + UTC+5)."""
    t = time.gmtime(ts + TASHKENT_UTC_OFFSET)
    return t.tm_mon * 100 + t.tm_mday in holidays(t.tm_year)


def profile_slot(ts):
    """Ключ `how` строки профиля: час недели (0–167), а в праздник — тот же
    час + HOLIDAY_SLOT (168–335). Праздник не сливается с субботой: час
    недели остаётся в ключе для будущего прогноза по 168 часам, а в файл
    «обычно» такая строка идёт выходным классом (bucket_name)."""
    how = hour_of_week(ts)
    return how + HOLIDAY_SLOT if is_holiday(ts) else how


def store(conn, piece_id, samples, nodes, models, now):
    how = profile_slot(now)
    conn.executemany("INSERT INTO traffic_samples(u, v, kmh, weight, ts, piece) VALUES(?, ?, ?, ?, ?, ?)",
                     [(u, v, kmh, w, now, piece_id) for u, v, kmh, w in samples])
    conn.executemany("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, ?, ?)",
                     [(i, lat, lon) for i, (lat, lon) in nodes.items()])
    conn.executemany("INSERT OR REPLACE INTO traffic_edges(u, v, model_kmh) VALUES(?, ?, ?)",
                     [(u, v, kmh) for (u, v), kmh in models.items()])
    conn.executemany("""INSERT INTO traffic_profile(u, v, how, n, sum_kmh, pieces, sum_pace)
                        VALUES(?, ?, ?, ?, ?, 1, ?)
                        ON CONFLICT(u, v, how) DO UPDATE SET n = n + excluded.n,
                            sum_kmh = sum_kmh + excluded.sum_kmh,
                            pieces = pieces + 1, sum_pace = sum_pace + excluded.sum_pace""",
                     [(u, v, how, count, total, pace)
                      for (u, v), (count, total, pace) in piece_profile(samples).items()])


def piece_profile(samples):
    """Один кусок — одно наблюдение ребра: {(u, v): (отрезков, сумма км/ч,
    темп с/км)}. Темп — взвешенный по длине отрезков внутри куска."""
    acc = {}
    for u, v, kmh, weight in samples:
        entry = acc.setdefault((u, v), [0, 0.0, 0.0, 0.0])
        entry[0] += 1
        entry[1] += kmh
        entry[2] += weight
        entry[3] += weight * 3600.0 / max(PACE_MIN_KMH, kmh)
    return {edge: (count, total, paced / length if length > 0 else 3600.0 / PACE_MIN_KMH)
            for edge, (count, total, length, paced) in acc.items()}


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
    # Отпечатки повторов (api.py) живут полчаса и без новых POST: ночью
    # запросов нет, а cron идёт. Таблицы может ещё не быть (старый api.py).
    try:
        conn.execute("DELETE FROM traffic_seen WHERE received < ?", (now - SEEN_TTL,))
    except sqlite3.OperationalError:
        pass
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


def mark_shared(conn, now):
    """Запомнить рёбра, которые сейчас прошли два независимых куска (то же
    правило, что у now.json). Признак вечный: «здесь ездит не один
    человек» со временем не перестаёт быть правдой."""
    conn.execute("""INSERT OR IGNORE INTO traffic_shared(u, v)
                    SELECT u, v FROM traffic_samples WHERE ts >= ?
                    GROUP BY u, v HAVING COUNT(DISTINCT piece) >= ?""",
                 (now - SAMPLE_WINDOW, MIN_PIECES))
    conn.commit()


# --- «Обычно по водителям» (8.8.16) -------------------------------------------

def bucket_name(how):
    """Файл строки профиля: «wd-08» — будни в 8:00, «off-08» — выходные или
    праздник (how ≥ HOLIDAY_SLOT, см. profile_slot) в 8:00."""
    how = int(how)
    day, hour = divmod(how % 168, 24)
    off = day >= 5 or how >= HOLIDAY_SLOT
    return f"{DAY_CLASSES[1] if off else DAY_CLASSES[0]}-{hour:02d}"


ALL_BUCKETS = tuple(f"{cls}-{hour:02d}" for cls in DAY_CLASSES for hour in range(24))


def typical_due(conn, now):
    row = conn.execute("SELECT value FROM traffic_meta WHERE key = 'typical_built'").fetchone()
    return row is None or now - row[0] >= TYPICAL_EVERY


def typical_buckets(conn):
    """{имя файла: [(ulat, ulon, vlat, vlon, kmh)]} — только рёбра с
    TYPICAL_MIN_PIECES кусками в классе дня и часе и прошедшие проверку «не
    один человек». Отсортировано: одинаковые данные — одинаковый файл."""
    rows = conn.execute("""SELECT p.how, p.pieces, p.sum_pace, a.lat, a.lon, b.lat, b.lon, p.u, p.v
                           FROM traffic_profile p
                           JOIN traffic_shared s ON s.u = p.u AND s.v = p.v
                           JOIN traffic_nodes a ON a.id = p.u
                           JOIN traffic_nodes b ON b.id = p.v
                           WHERE p.pieces > 0""").fetchall()
    acc = {}
    for how, pieces, pace, alat, alon, blat, blon, u, v in rows:
        entry = acc.setdefault((bucket_name(how), u, v), [0, 0.0, (alat, alon, blat, blon)])
        entry[0] += pieces
        entry[1] += pace
    out = {}
    for (name, _, _), (pieces, pace, coords) in acc.items():
        if pieces < TYPICAL_MIN_PIECES or pace <= 0:
            continue
        kmh = min(MAX_KMH, 3600.0 / (pace / pieces))
        out.setdefault(name, []).append((*coords, kmh))
    return {name: sorted(edges) for name, edges in out.items()}


def typical_payload(name, edges, now):
    return {
        "v": TYPICAL_VERSION,
        "bucket": name,
        "generated": int(now),
        "edges": [[round(a, 5), round(b, 5), round(c, 5), round(d, 5), int(round(kmh))]
                  for a, b, c, d, kmh in edges],
    }


def write_typical(conn, now, directory=TYPICAL_DIR):
    """Все 48 файлов (пустой — честное «данных нет», а не 404). Файл
    переписывается, только если сменились рёбра: иначе ETag и 304 у телефона
    теряли бы смысл. Возвращает, сколько файлов записано."""
    buckets = typical_buckets(conn)
    written = 0
    for name in ALL_BUCKETS:
        body = typical_payload(name, buckets.get(name, []), now)
        path = os.path.join(directory, f"{name}.json")
        try:
            with open(path, encoding="utf-8") as f:
                current = json.load(f)
            if current.get("v") == body["v"] and current.get("edges") == body["edges"]:
                continue
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as error:
            # Битый файл (обрыв диска) — перезаписываем, не падаем.
            print(f"typical {name}: старый файл не прочитан ({error}) — перезапись", file=sys.stderr)
        write_atomic(path, json.dumps(body, separators=(",", ":")))
        written += 1
    conn.execute("INSERT OR REPLACE INTO traffic_meta(key, value) VALUES('typical_built', ?)", (now,))
    conn.commit()
    return written


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
    mark_shared(conn, now)
    typical = write_typical(conn, now) if typical_due(conn, now) else None
    conn.close()
    note = "" if typical is None else f", «обычно» файлов переписано {typical}"
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} кусков {pieces}, отрезков {segments}, рёбер в выходе {len(edges)}{note}")


if __name__ == "__main__":
    main()
