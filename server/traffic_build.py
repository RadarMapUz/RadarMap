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
     если её подтвердили MIN_PIECES разных кусков, прошедших ребро насквозь:
     один водитель, вставший у обочины, пробку не рисует. «Насквозь» — не
     ближе PIECE_END_GUARD к концам совпадения: соседние куски одной машины
     стыкуются на одном ребре (следующий начинается со следующего фикса,
     метрах в 10–15), и по одному лишь касанию эта машина сама с собой
     набирала бы «два куска» на стыке, а машина, стоящая на месте, — на
     своём ребре каждые 8–10 минут. Скорость участков у концов в медиану
     идёт как обычно; не в счёт они только как свидетели.
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
       {"v": 1, "bucket": "wd-08", "generated": t, "edges": [[ulat, ulon, vlat, vlon, kmh, model_kmh]]}
     model_kmh (27.E) — скорость графа на ребре, 0 — неизвестна: шестой
     столбец добавлен к версии 1 (старые телефоны читают первые пять), по
     нему ETA любого маршрута получает обычную пробку часа выезда.
     Класс дня — будни (wd, пн–пт) или выходные (off, сб–вс и праздники
     Узбекистана по ташкентской дате — тот же список, что UzHolidays на
     телефоне: кусок из Навруза во вторник ложится в off, как и запрос
     телефона в этот день), а не 168 часов
     недели: холодный старт — ровно тогда, когда данных мало, и пять будних
     восьми утра, сложенные в один файл, набирают порог впятеро быстрее, а
     дорога во вторник в 8:00 от среды в 8:00 не отличается. Ребро попадает
     в файл, только если его прошли не меньше TYPICAL_MIN_PIECES кусков в этот
     час (эффективных, п. 6) И два куска прошли его вместе (в одном окне
     now.json) за последние SHARED_TTL: один
     человек, каждый будний день едущий в 8:00 по своей улице, набирает пять
     кусков за неделю — но не два одновременно, и его улица публичной не
     становится. Скорость — гармоническое среднее (через время на километр):
     время в пути — это сумма времён, и среднее км/ч по пробке 5 и свободе 50
     дало бы 27 вместо честных 9. Файл переписывается, только если рёбра
     сменились: телефон проверяет его с ETag, и неизменный файл стоит 304.
  6. «Обычно» стареет (план 14.4). Без старения профиль копился бы вечно, и
     перестроенная дорога, новый светофор или открытый мост проступали бы в
     «обычно» месяцами: неделя новых данных сдвигает среднее за год на 2 %.
     Кусок весит 2^(−возраст / PROFILE_HALF_LIFE), полураспад — 5 недель:
     перемена на дороге видна наполовину через 5 недель и на три четверти
     через 10, а холодный старт почти не замечает старения (кусок
     двухнедельной давности весит 0,76).

     Хранение — «прямое затухание» (forward decay), а не умножение всего
     профиля на множитель раз в час или сутки. Такой UPDATE переписывает
     каждую страницу таблицы, раздувает WAL до её размера и держит замок
     записи, пока api.py кладёт новые куски в ту же traffic.db (его
     busy_timeout — 5 с; дольше — POST /api/traffic падает). Вместо этого
     новый кусок пишется сразу с весом 2^((сейчас − метка) / H), метка —
     traffic_meta.profile_epoch, общая для всех строк. Сумма в строке — это
     эффективные куски, умноженные на масштаб decay_scale(метка, сейчас), и
     читается делением на него; в гармоническом среднем масштаб сокращается.
     Цена для cron — одна степень на кусок. Раз в сутки (maintain_profile) —
     DELETE умерших строк (эффективно < PROFILE_DROP: одиночный кусок живёт
     ~5 месяцев) — таблица ограничена тем, что ездили последние месяцы, а не
     всей историей, и не растёт в памяти VPS без конца; раз в
     PROFILE_RENORM_AFTER (~9 месяцев) — один UPDATE, возвращающий числа к
     метке «сейчас», чтобы масштаб не рос без предела. Скользящее окно из
     недельных корзин считало бы куски точно, но умножило бы строки профиля
     на число недель и обрывало бы данные ступенькой.

     Порог TYPICAL_MIN_PIECES — в эффективных кусках. Свежий кусок весит 1,
     старый меньше, поэтому старение делает порог только строже: пять
     эффективных — это не меньше пяти настоящих (обычно 5–6 за последние
     недели), а в установившемся режиме ребро держится в файле, если в этот
     класс дня и час по нему проходит ≳ 0,7 куска в неделю (5 · ln 2 / 5 нед.).

     Отметка «не один человек» (traffic_shared) тоже стареет: ребро идёт в
     файл, только если два куска прошли его вместе за последние SHARED_TTL
     (= полураспад — тот срок, за который набирается половина веса
     публикуемого числа). Вечная отметка вместе со старением профиля
     ослабила бы защиту: улица, по которой когда-то раз проехали двое, а
     теперь ездит один человек, через пару полураспадов публиковала бы
     данные только его — под давним «не один». Теперь, если за SHARED_TTL
     второго водителя на улице не было, она уходит из файлов, хотя
     эффективных кусков у неё может хватать.

Единица — направленное ребро OSM (u, v): ключ постоянен между обновлениями
графа, и это тот же формат, что `--segment-speed-file` у OSRM: по нему
traffic_speeds.py пишет файл скоростей для стенда MLD + customize, где
маршрут сам объезжает пробку (32D, server/osrm/TRAFFIC.md).
"""
import datetime
import fcntl
import functools
import gzip
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import traffic_config as tc

DB_PATH = "/opt/radarmap/api/traffic.db"
OSRM = "http://127.0.0.1:8092"
OUT_PATH = "/opt/radarmap/www/traffic/now.json"

PIECE_TTL = 20 * 60          # кусок, который не удалось сопоставить, не живёт дольше
RUN_BUDGET = 90              # секунд на сопоставление: now.json выходит каждый прогон и при очереди
MATCH_WORKERS = 2            # запросов к OSRM разом: по числу ядер VPS
SATURATE_FROM = 300          # кусков в очереди: ниже CPU хватает и каждый кусок дороже
CELL_LAT, CELL_LON = 0.003, 0.004   # ячейка насыщения: ~330 м на широте Ташкента
CELL_BUCKET = 180            # секунд: лимит по коротким окнам, чтобы данные шли весь период
CELL_LIMIT = 2               # кусков на ячейку, направление и окно — остальные не идут в OSRM
SEEN_TTL = 30 * 60           # отпечатки повторов: как TRAFFIC_SEEN_TTL в api.py
SAMPLE_WINDOW = 15 * 60      # «текущая» скорость — за последние 15 минут
SAMPLE_KEEP = 60 * 60        # сырые скорости рёбер хранятся час
MIN_PIECES = 2               # независимых кусков на ребро, чтобы показать его
MIN_CONFIDENCE = 0.1         # совпадение OSRM ниже — кусок не про дорогу
MATCH_RADIUS = 25            # метров: GPS в городе + ширина проспекта
PIECE_END_GUARD = MATCH_RADIUS   # метров у концов совпадения: ребро задето, а не пройдено
MAX_KMH = 150.0
JAM_RATIO = 0.35             # ниже — пробка (красный)
SLOW_RATIO = 0.6             # ниже — медленно (жёлтый)
TASHKENT_UTC_OFFSET = 5 * 3600
OUTPUT_VERSION = 1

TYPICAL_DIR = "/opt/radarmap/www/traffic/typical"
PROFILE_PATH = "/opt/radarmap/www/traffic/profile.json"   # 33C: профиль часа недели для телефона
TYPICAL_MIN_PIECES = 5       # кусков на ребро в этот класс дня и час
TYPICAL_EVERY = 60 * 60      # «обычно» пересобирается не чаще раза в час
TYPICAL_VERSION = 1
PACE_MIN_KMH = 3.0           # ниже — «стоим»: темп не уходит в бесконечность
DAY_CLASSES = ("wd", "off")  # будни (пн–пт), выходные (сб–вс и праздники)

# Старение «обычно» (14.4, п. 6 шапки).
PROFILE_HALF_LIFE = 35 * 86400           # вес куска падает вдвое за 5 недель
PROFILE_DROP = 0.05                      # эффективно легче — строка удаляется
PROFILE_MAINTAIN_EVERY = 24 * 3600       # уборка профиля — раз в сутки
PROFILE_RENORM_AFTER = 8 * PROFILE_HALF_LIFE   # масштаб 256 — числа обратно к метке «сейчас»
SHARED_TTL = PROFILE_HALF_LIFE           # «не один человек» без подтверждения дольше — не в счёт
LOCK_PATH = DB_PATH + ".lock"            # два прогона cron разом не идут


def schema(conn):
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_pieces(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        received REAL NOT NULL,
        points TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_cell_load(
        la INTEGER NOT NULL, lo INTEGER NOT NULL, sector INTEGER NOT NULL,
        bucket INTEGER NOT NULL, n INTEGER NOT NULL,
        PRIMARY KEY(la, lo, sector, bucket)) WITHOUT ROWID""")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_samples(
        u INTEGER NOT NULL, v INTEGER NOT NULL,
        kmh REAL NOT NULL, weight REAL NOT NULL,
        ts REAL NOT NULL, piece INTEGER NOT NULL,
        passed INTEGER NOT NULL DEFAULT 0)""")
    # passed — кусок прошёл ребро насквозь (п. 2 шапки). Строки до выкладки
    # получают 0: свидетелями не считаются, а живут они час (SAMPLE_KEEP), и
    # now.json первые 15 минут после выкладки строится только из новых.
    add_column(conn, "traffic_samples", "passed", "INTEGER NOT NULL DEFAULT 0")
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
    # Со старением (14.4) n, sum_kmh, pieces и sum_pace — суммы весов в
    # масштабе метки profile_epoch (п. 6 шапки), а не целые счётчики.
    add_column(conn, "traffic_profile", "pieces", "INTEGER NOT NULL DEFAULT 0")
    add_column(conn, "traffic_profile", "sum_pace", "REAL NOT NULL DEFAULT 0")
    # Рёбра, которые два куска прошли в одном окне now.json — то есть не
    # один человек; seen — когда это было в последний раз (живёт SHARED_TTL).
    # Отметки 8.8.16 без времени получают 0 — просрочены: их возраст
    # неизвестен, а улица с настоящим движением подтвердится в первом же
    # окне, где по ней проедут двое.
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_shared(
        u INTEGER NOT NULL, v INTEGER NOT NULL, seen REAL NOT NULL DEFAULT 0,
        PRIMARY KEY(u, v))""")
    add_column(conn, "traffic_shared", "seen", "REAL NOT NULL DEFAULT 0")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_meta(
        key TEXT PRIMARY KEY, value REAL NOT NULL)""")
    # Профиль часа недели для маршрутизатора (33A, docs/spec_traffic_33.md):
    # одно наблюдение — кусок, прошедший ребро насквозь, — со слотом часа
    # недели и НОМЕРОМ ДНЯ (не временем): медиане нужен список скоростей, а
    # доверию — число разных дней. Ни куска, ни устройства, ни минуты; строка
    # живёт PROFILE_KEEP_DAYS и наружу не уходит.
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_slot_obs(
        u INTEGER NOT NULL, v INTEGER NOT NULL, slot INTEGER NOT NULL,
        day INTEGER NOT NULL, kmh REAL NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS traffic_slot_obs_slot ON traffic_slot_obs(slot, u, v)")
    # Задержки манёвров (33B): одно наблюдение — кусок, прошедший перекрёсток;
    # тройка узлов, слот часа недели, номер дня (для «разных дней»), секунды
    # и угол. Живёт PROFILE_KEEP_DAYS, наружу не уходит.
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_turn_obs(
        u INTEGER NOT NULL, v INTEGER NOT NULL, w INTEGER NOT NULL, slot INTEGER NOT NULL,
        day INTEGER NOT NULL, delay REAL NOT NULL, angle REAL NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS traffic_turn_obs_slot ON traffic_turn_obs(slot, u, v, w)")
    conn.commit()


def add_column(conn, table, column, decl):
    """ALTER TABLE … ADD COLUMN, только если столбца ещё нет: schema() идёт
    каждые 2 минуты, и ALTER, падающий на каждом прогоне, — не миграция."""
    columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    if column not in columns:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")


# --- Сопоставление ----------------------------------------------------------

def match_url(points, base=OSRM):
    coords = ";".join(f"{lon:.5f},{lat:.5f}" for lat, lon, _, _ in points)
    times = ";".join(str(int(t)) for _, _, t, _ in points)
    radii = ";".join(str(MATCH_RADIUS) for _ in points)
    return (f"{base}/match/v1/driving/{coords}?timestamps={times}&radiuses={radii}"
            "&annotations=nodes,distance,duration&overview=full&geometries=geojson"
            "&tidy=true&gaps=split&steps=true")


def osrm_match(points, base=OSRM, timeout=10):
    with urllib.request.urlopen(match_url(points, base), timeout=timeout) as resp:
        return json.loads(resp.read())


def leg_length(leg):
    """Длина участка по отрезкам его рёбер (то, что идёт в samples)."""
    return sum(d for d in ((leg.get("annotation") or {}).get("distance") or []) if d > 0)


def edges_from_match(response, points):
    """Скорости по рёбрам из ответа OSRM.

    Возвращает (samples, nodes, models):
      samples — [(u, v, kmh, weight_m, passed)], скорость участка между
                соседними точками следа на каждом ребре этого участка, вес —
                длина отрезка ребра внутри участка, passed — отрезок не
                ближе PIECE_END_GUARD к концам совпадения (кусок прошёл это
                ребро, а не начался или кончился на нём);
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
        # Метры вдоль совпадения: где начинается и кончается каждый отрезок.
        total = sum(leg_length(leg) for leg in legs)
        along = 0.0
        offset = 0
        for k, leg in enumerate(legs):
            annotation = leg.get("annotation") or {}
            ids = annotation.get("nodes") or []
            dist = annotation.get("distance") or []
            dur = annotation.get("duration") or []
            m = len(dist)
            if m == 0 or len(ids) != m + 1:
                offset += m
                along += leg_length(leg)
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
                along += leg_length(leg)
                continue
            kmh = min(MAX_KMH, length / dt * 3.6)
            for j in range(m):
                if dist[j] <= 0:
                    continue
                start, along = along, along + dist[j]
                passed = start >= PIECE_END_GUARD and along <= total - PIECE_END_GUARD
                edge = (ids[j], ids[j + 1])
                samples.append((edge[0], edge[1], kmh, dist[j], passed))
                if j < len(dur) and dur[j] > 0:
                    models[edge] = dist[j] / dur[j] * 3.6
    return samples, nodes, models


# --- Задержки манёвров (33B, docs/spec_traffic_33.md) -------------------------------
#
# Налево у светофора и прямо через тот же узел — разное время, а граф знает
# только «узел со светофором — 8 с» и угол поворота (car_radarmap.lua). Кусок
# следа это время видит: когда машина вошла в последние TURN_APPROACH м ребра
# въезда и когда вышла из первых TURN_EXIT м ребра выезда. Задержка манёвра —
# это время минус время тех же 60 м по скорости графа, в пределах
# 0…TURN_MAX_DELAY.
#
# Узел — перекрёсток из шагов `match` (steps=true): 3+ направления
# (bearings); узел с одной парой рёбер — не манёвр. Окно должно целиком
# лежать внутри совпадения с запасом PIECE_END_GUARD: кусок, оборвавшийся у
# узла, не считается (стоянка у дома — не светофор).
#
# Сверх спецификации — перекрёсток проспекта с разделительной: два узла в
# 15–25 м, и их окна по 30 м перекрываются — одно ожидание у светофора
# писалось бы обоим манёврам. Узлы ближе TURN_CLUSTER — один перекрёсток:
# окно от первого − 30 до последнего + 30, задержка — манёвру с самым крутым
# углом (там решается, налево мы или прямо).
#
# Ключ — тройка узлов OSM (откуда, через, куда), ровно формат
# --turn-penalty-file. Опыт на v26.7.3 (TRAFFIC.md, 33B): значение из файла
# ЗАМЕНЯЕТ штраф профиля и во времени, и в весе — поэтому в файл идёт полная
# медиана задержки, а не прибавка, и только там, где она больше оценки
# штрафа профиля (profile_turn_ceiling) больше чем на TURN_MARGIN.

def bearing(lat1, lon1, lat2, lon2):
    """Азимут, градусы 0–360 (плоское приближение — отрезки короткие)."""
    k = math.cos(math.radians((lat1 + lat2) / 2))
    return math.degrees(math.atan2((lon2 - lon1) * k, lat2 - lat1)) % 360


def turn_angle(prev, via, nxt):
    """Угол манёвра −180…180: плюс — направо, минус — налево (как turn.angle
    в профиле OSRM); prev/via/nxt — (lat, lon)."""
    a = bearing(prev[0], prev[1], via[0], via[1])
    b = bearing(via[0], via[1], nxt[0], nxt[1])
    return (b - a + 180) % 360 - 180


def match_chains(response, points):
    """Совпадения `match` как цепочки для мер у узла: [{chain, marks, segments,
    crossings}] по совпадению с достаточной уверенностью.

      chain     — [(id узла, метры вдоль, (lat, lon))] внутренних узлов
                  участков по порядку (те же узлы, что ключи рёбер);
      marks     — [(метры вдоль, секунды следа)] точек следа;
      segments  — [(от, до, секунд графа)] отрезков рёбер вдоль совпадения;
      crossings — {(lon, lat) с точностью 1e-6} перекрёстков из шагов (3+
                  направления; пусто, если ответ без steps).
    """
    out = []
    if response.get("code") != "Ok":
        return out
    tracepoints = response.get("tracepoints") or []
    for index, matching in enumerate(response.get("matchings") or []):
        if (matching.get("confidence") or 0) < MIN_CONFIDENCE:
            continue
        ends = sorted((tp["waypoint_index"], i) for i, tp in enumerate(tracepoints)
                      if tp and tp.get("matchings_index") == index)
        legs = matching.get("legs") or []
        if len(ends) != len(legs) + 1:
            continue
        geometry = (matching.get("geometry") or {}).get("coordinates") or []
        chain, marks, segments, crossings = [], [], [], set()
        along, offset = 0.0, 0
        for k, leg in enumerate(legs):
            marks.append((along, points[ends[k][1]][2]))
            for step in leg.get("steps") or []:
                for crossing in step.get("intersections") or []:
                    if len(crossing.get("bearings") or []) >= 3 and crossing.get("location"):
                        lon, lat = crossing["location"]
                        crossings.add((round(lon, 6), round(lat, 6)))
            annotation = leg.get("annotation") or {}
            ids = annotation.get("nodes") or []
            dist = annotation.get("distance") or []
            dur = annotation.get("duration") or []
            m = len(dist)
            if m == 0 or len(ids) != m + 1:
                offset += m
                along += leg_length(leg)
                continue
            position = along
            for j in range(m):
                if j >= 1 and offset + j < len(geometry):
                    lon, lat = geometry[offset + j]
                    if not chain or chain[-1][0] != ids[j]:
                        chain.append((ids[j], position, (lat, lon)))
                length = max(0.0, dist[j])
                if length > 0:
                    segments.append((position, position + length, dur[j] if j < len(dur) else 0.0))
                position += length
            offset += m
            along += leg_length(leg)
        marks.append((along, points[ends[-1][1]][2]))
        out.append({"chain": chain, "marks": marks, "segments": segments, "crossings": crossings})
    return out


def time_at(marks, x):
    """Секунда следа, когда машина впервые дошла до метра `x` (по точкам
    следа, линейно между ними). Стоянка — несколько точек на одном месте:
    время до неё и после неё разведено, и окно вокруг узла его включает."""
    for (a0, t0), (a1, t1) in zip(marks, marks[1:]):
        if a1 >= x and a1 > a0:
            if x <= a0:
                return t0
            return t0 + (t1 - t0) * (x - a0) / (a1 - a0)
    return marks[-1][1]


def time_after(marks, x):
    """Секунда, когда машина ушла дальше метра `x` (последняя точка на нём или
    до него — конец стоянки)."""
    for (a0, t0), (a1, t1) in zip(marks, marks[1:]):
        if a1 > x and a1 > a0:
            if x <= a0:
                return t0
            return t0 + (t1 - t0) * (x - a0) / (a1 - a0)
    return marks[-1][1]


def graph_time(segments, start, end):
    """Секунд графа на отрезке [start, end] совпадения (доля каждого ребра)."""
    total = 0.0
    for a, b, dur in segments:
        overlap = min(b, end) - max(a, start)
        if overlap > 0 and b > a:
            total += dur * overlap / (b - a)
    return total


def maneuver(angle):
    """Класс манёвра по углу: прямо (|угол| < TURN_STRAIGHT_DEG), направо,
    налево, разворот (|угол| > TURN_UTURN_DEG). Плюс — направо, как turn.angle."""
    if abs(angle) > tc.TURN_UTURN_DEG:
        return "uturn"
    if abs(angle) < tc.TURN_STRAIGHT_DEG:
        return "straight"
    return "right" if angle > 0 else "left"


def turns_from_match(response, points):
    """Задержки у перекрёстков: [(u, v, w, секунд, угол)], один манёвр на
    перекрёсток (шапка раздела)."""
    out = []
    for item in match_chains(response, points):
        chain, marks, segments, crossings = (item["chain"], item["marks"], item["segments"],
                                             item["crossings"])
        if len(chain) < 3 or len(marks) < 2 or not crossings:
            continue
        first, last = marks[0][0], marks[-1][0]
        at_crossing = [i for i in range(1, len(chain) - 1)
                       if (round(chain[i][2][1], 6), round(chain[i][2][0], 6)) in crossings]
        clusters = []
        for i in at_crossing:
            if clusters and chain[i][1] - chain[clusters[-1][-1]][1] < tc.TURN_CLUSTER:
                clusters[-1].append(i)
            else:
                clusters.append([i])
        for cluster in clusters:
            start = chain[cluster[0]][1] - tc.TURN_APPROACH
            end = chain[cluster[-1]][1] + tc.TURN_EXIT
            if start < first + PIECE_END_GUARD or end > last - PIECE_END_GUARD:
                continue
            spent = time_after(marks, end) - time_at(marks, start)
            graph = graph_time(segments, start, end)
            if spent <= 0 or graph <= 0:
                continue
            delay = min(tc.TURN_MAX_DELAY, max(0.0, spent - graph))
            angles = [(abs(turn_angle(chain[i - 1][2], chain[i][2], chain[i + 1][2])), i) for i in cluster]
            _, via = max(angles)
            angle = turn_angle(chain[via - 1][2], chain[via][2], chain[via + 1][2])
            out.append((chain[via - 1][0], chain[via][0], chain[via + 1][0], delay, angle))
    return out


def profile_turn_ceiling(angle):
    """Верхняя оценка штрафа манёвра в car_radarmap.lua (process_turn): угол
    по сигмоиде (до turn_penalty 7,5 с) + светофор 8 с ИЛИ налево с главной без
    светофора 15 с + разворот 20 с. Файл штрафов ЗАМЕНЯЕТ штраф профиля, а
    признака «есть светофор» в ответе match нет — поэтому пишем манёвр, только
    если измерено больше этой оценки: манёвр никогда не становится дешевле, чем
    его считает граф (то же правило, что «не быстрее графа» у рёбер)."""
    turn_penalty, bias = 7.5, 1.075
    if angle >= 0:
        base = turn_penalty / (1 + math.exp(-((13 / bias) * angle / 180 - 6.5 * bias)))
    else:
        base = turn_penalty / (1 + math.exp(-((13 * bias) * -angle / 180 - 6.5 / bias)))
    left = angle < -40            # left_turn_min_degrees профиля
    uturn = maneuver(angle) == "uturn"
    return base + (15.0 if left else 8.0) + (20.0 if uturn else 0.0)


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


def week_slot(ts):
    """Слот профиля маршрутизатора (33A): час недели 0–167 по Ташкенту
    (понедельник 00:00 = 0). Праздник — как воскресенье в тот же час: в
    Навруз дороги как в выходной (то же правило, что у файлов «обычно» и
    UzHolidays на телефоне), а 168 слотов праздников по одному дню в году не
    набрали бы трёх разных дней никогда."""
    hour = hour_of_week(ts) % 24
    return 6 * 24 + hour if is_holiday(ts) else hour_of_week(ts)


def day_number(ts):
    """Номер ташкентского дня (дни от 1970-01-01) — для «разных дней» слота."""
    return int((ts + TASHKENT_UTC_OFFSET) // 86400)


def profile_epoch(conn, now):
    """Метка весов профиля (п. 6 шапки). Нет метки — ставится `now`: строки,
    накопленные до старения (8.8.16), считаются снятыми в первом прогоне
    после выкладки — их возраст неизвестен, а копились они считанные недели."""
    row = conn.execute("SELECT value FROM traffic_meta WHERE key = 'profile_epoch'").fetchone()
    if row is not None:
        return row[0]
    conn.execute("INSERT INTO traffic_meta(key, value) VALUES('profile_epoch', ?)", (now,))
    return now


def decay_scale(epoch, now):
    """Масштаб весов: кусок из `now` весит, как 2^((now − epoch) / H) кусков
    из метки. Эффективное значение строки — хранимое, делённое на масштаб."""
    return 2.0 ** ((now - epoch) / PROFILE_HALF_LIFE)


def store(conn, piece_id, samples, nodes, models, now, turns=()):
    how = profile_slot(now)
    weight = decay_scale(profile_epoch(conn, now), now)
    # 33A: кусок — одно наблюдение слота на каждом ребре, которое прошёл
    # насквозь (темп по длине своих отрезков, как piece_profile).
    passed = [sample for sample in samples if sample[4]]
    slot, day = week_slot(now), day_number(now)
    conn.executemany("INSERT INTO traffic_slot_obs(u, v, slot, day, kmh) VALUES(?, ?, ?, ?, ?)",
                     [(u, v, slot, day, min(MAX_KMH, 3600.0 / pace))
                      for (u, v), (_c, _t, pace) in sorted(piece_profile(passed).items())])
    conn.executemany("INSERT INTO traffic_turn_obs(u, v, w, slot, day, delay, angle) VALUES(?, ?, ?, ?, ?, ?, ?)",
                     [(u, v, w, slot, day, delay, angle) for u, v, w, delay, angle in turns])
    conn.executemany("""INSERT INTO traffic_samples(u, v, kmh, weight, ts, piece, passed)
                        VALUES(?, ?, ?, ?, ?, ?, ?)""",
                     [(u, v, kmh, w, now, piece_id, int(passed)) for u, v, kmh, w, passed in samples])
    conn.executemany("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, ?, ?)",
                     [(i, lat, lon) for i, (lat, lon) in nodes.items()])
    conn.executemany("INSERT OR REPLACE INTO traffic_edges(u, v, model_kmh) VALUES(?, ?, ?)",
                     [(u, v, kmh) for (u, v), kmh in models.items()])
    # Кусок — вес `weight` в масштабе метки: и счётчики, и суммы стареют
    # вместе, поэтому средние (sum_kmh / n, sum_pace / pieces) от масштаба не
    # зависят.
    conn.executemany("""INSERT INTO traffic_profile(u, v, how, n, sum_kmh, pieces, sum_pace)
                        VALUES(?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(u, v, how) DO UPDATE SET n = n + excluded.n,
                            sum_kmh = sum_kmh + excluded.sum_kmh,
                            pieces = pieces + excluded.pieces,
                            sum_pace = sum_pace + excluded.sum_pace""",
                     [(u, v, how, count * weight, total * weight, weight, pace * weight)
                      for (u, v), (count, total, pace) in piece_profile(samples).items()])


def piece_profile(samples):
    """Один кусок — одно наблюдение ребра: {(u, v): (отрезков, сумма км/ч,
    темп с/км)}. Темп — взвешенный по длине отрезков внутри куска."""
    acc = {}
    for u, v, kmh, weight, _ in samples:
        entry = acc.setdefault((u, v), [0, 0.0, 0.0, 0.0])
        entry[0] += 1
        entry[1] += kmh
        entry[2] += weight
        entry[3] += weight * 3600.0 / max(PACE_MIN_KMH, kmh)
    return {edge: (count, total, paced / length if length > 0 else 3600.0 / PACE_MIN_KMH)
            for edge, (count, total, length, paced) in acc.items()}


def match_or_none(matcher, points):
    try:
        return matcher(points)
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"OSRM недоступен: {error}", file=sys.stderr)
        return None


def piece_cell(points, received):
    """Ключ насыщения: ячейка середины куска, сектор направления 45°, окно времени."""
    lat, lon = points[len(points) // 2][:2]
    heading = bearing(points[0][0], points[0][1], points[-1][0], points[-1][1])
    return (math.floor(lat / CELL_LAT), math.floor(lon / CELL_LON),
            int((heading + 22.5) % 360 // 45), int(received // CELL_BUCKET))


def cell_full(conn, key):
    row = conn.execute("SELECT n FROM traffic_cell_load WHERE la = ? AND lo = ? AND sector = ? AND bucket = ?",
                       key).fetchone()
    return row is not None and row[0] >= CELL_LIMIT


def count_cell(conn, key):
    conn.execute("""INSERT INTO traffic_cell_load(la, lo, sector, bucket, n) VALUES(?, ?, ?, ?, 1)
                    ON CONFLICT(la, lo, sector, bucket) DO UPDATE SET n = n + 1""", key)


def process(conn, now, matcher=osrm_match, budget=RUN_BUDGET, clock=time.monotonic, saturate_from=SATURATE_FROM):
    """Сопоставить ждущие куски, новые первыми, не дольше budget секунд.
    Сопоставленный кусок удаляется сразу; не сопоставленный (OSRM лежит или
    кончилось время) ждёт следующего прогона, но не дольше PIECE_TTL. Запись
    открыта только между запросами к OSRM: иначе POST /api/traffic ждёт весь
    прогон и падает с database is locked. При очереди от saturate_from куски
    из уже закрытых ячеек удаляются без OSRM. Возвращает (кусков, отрезков)."""
    deadline = clock() + budget
    saturating = conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0] >= saturate_from
    done = matched = skipped = 0
    with ThreadPoolExecutor(MATCH_WORKERS) as pool:
        while clock() < deadline:
            rows = conn.execute("SELECT id, received, points FROM traffic_pieces ORDER BY id DESC LIMIT ?",
                                (MATCH_WORKERS,)).fetchall()
            if not rows:
                break
            batch = []
            for piece_id, received, raw in rows:
                points = json.loads(raw)
                key = piece_cell(points, received)
                if saturating and cell_full(conn, key):
                    conn.execute("DELETE FROM traffic_pieces WHERE id = ?", (piece_id,))
                    skipped += 1
                else:
                    batch.append((piece_id, points, key))
            conn.commit()
            responses = list(pool.map(lambda item: match_or_none(matcher, item[1]), batch))
            for (piece_id, points, key), response in zip(batch, responses):
                if response is None:
                    continue
                samples, nodes, models = edges_from_match(response, points)
                store(conn, piece_id, samples, nodes, models, now, turns_from_match(response, points))
                conn.execute("DELETE FROM traffic_pieces WHERE id = ?", (piece_id,))
                if saturating:
                    count_cell(conn, key)
                done += 1
                matched += len(samples)
            conn.commit()
            if None in responses:
                break
    if skipped:
        print(f"насыщение: без OSRM пропущено кусков {skipped}")
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
    conn.execute("DELETE FROM traffic_cell_load WHERE bucket < ?", (int((now - PIECE_TTL) // CELL_BUCKET),))
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


def live_edges(conn, now):
    """Подтверждённые рёбра окна now.json с id узлов OSM:
    [(u, v, ulat, ulon, vlat, vlon, level, kmh, model_kmh)]. Одно правило для
    now.json, файла скоростей OSRM (traffic_speeds.py) и плотности в панели."""
    rows = conn.execute("""SELECT s.u, s.v, s.kmh, s.weight, s.piece, s.passed, e.model_kmh,
                                  a.lat, a.lon, b.lat, b.lon
                           FROM traffic_samples s
                           JOIN traffic_edges e ON e.u = s.u AND e.v = s.v
                           JOIN traffic_nodes a ON a.id = s.u
                           JOIN traffic_nodes b ON b.id = s.v
                           WHERE s.ts >= ?""", (now - SAMPLE_WINDOW,))
    grouped = {}
    for u, v, kmh, weight, piece, passed, model, alat, alon, blat, blon in rows:
        entry = grouped.setdefault((u, v), {"pairs": [], "pieces": set(), "model": model,
                                            "coords": (alat, alon, blat, blon)})
        entry["pairs"].append((kmh, weight))
        # Свидетель — только кусок, прошедший ребро насквозь (п. 2 шапки).
        if passed:
            entry["pieces"].add(piece)
    out = []
    for (u, v), entry in grouped.items():
        # Порог карты (33F) — свой, отдельно от порога пути (traffic_profile).
        if len(entry["pieces"]) < tc.MAP_MIN_PIECES:
            continue
        kmh = weighted_median(entry["pairs"])
        lvl = level(kmh, entry["model"]) if kmh is not None else None
        if lvl is None:
            continue
        out.append((u, v) + entry["coords"] + (lvl, kmh, entry["model"]))
    return sorted(out)


def aggregate(conn, now):
    """Рёбра для выхода: [(ulat, ulon, vlat, vlon, level, kmh, model_kmh)]."""
    return [row[2:] for row in live_edges(conn, now)]


def mark_shared(conn, now):
    """Отметить временем `now` рёбра, которые сейчас прошли два независимых
    куска (то же правило, что у now.json). Отметка живёт SHARED_TTL: «здесь
    ездит не один человек» — правда о недавнем, а не навсегда (п. 6 шапки)."""
    conn.execute("""INSERT INTO traffic_shared(u, v, seen)
                    SELECT u, v, ? FROM traffic_samples WHERE ts >= ? AND passed = 1
                    GROUP BY u, v HAVING COUNT(DISTINCT piece) >= ?
                    ON CONFLICT(u, v) DO UPDATE SET seen = MAX(seen, excluded.seen)""",
                 (now, now - SAMPLE_WINDOW, MIN_PIECES))
    conn.commit()


# --- Плотность данных (27.E) ----------------------------------------------------
#
# Слой пробок честен ребро за ребром (MIN_PIECES свидетелей за SAMPLE_WINDOW),
# но «на карте нет красного» значит «свободно» только там, где ездят многие:
# набор несёт одни медленные рёбра, и пустой город неотличим от свободного.
# Панель (admin.py, «Пробки») показывает по городам, сколько данных пришло за
# последний час, — по нему владелец решает, где пробкам уже можно верить
# (подпись, реклама, MLD-маршруты), а где слой пока лишь отдельные отметки.
#
# CITY_READY_PIECES_PER_HOUR — порог «город готов»: 60 кусков по ~1 км в час —
# это ~15 кусков в каждом 15-минутном окне, примерно три машины, всё время
# едущие по городу. Меньше — подтверждённое ребро редкость (два куска на одном
# ребре за 15 минут), и отсутствие пробки ничего не говорит. Порог — для
# людей и решений, телефоны его не видят: слой и ETA по-прежнему решают
# ребро за ребром, и ни одно ребро без двух свидетелей не публикуется.
CITY_READY_PIECES_PER_HOUR = 60


def density(conn, now, area_of):
    """Плотность за последний час по районам: [{area, pieces, seen, published,
    slow, typical}] по убыванию кусков. Только счётчики — ни кусков, ни
    координат, ни времени отдельных проездов наружу не идёт.

      pieces    — разных кусков, задевших район за SAMPLE_KEEP (сырые
                  скорости живут ровно час, дольше не посчитать);
      seen      — разных рёбер, на которые кусок лёг за этот час;
      published — рёбер, которые сейчас в now.json (то же правило — live_edges);
      slow      — из них медленно или пробка;
      typical   — рёбер в файле «обычно» текущего класса дня и часа.

    `area_of(lat, lon)` — имя района (город или «трасса»); ребро относится к
    району своего начального узла, кусок — к каждому району, который задел.
    """
    areas = {}

    def entry(lat, lon):
        name = area_of(lat, lon)
        return areas.setdefault(name, {"area": name, "pieces": set(), "seen": set(),
                                       "published": 0, "slow": 0, "typical": 0})

    for u, v, piece, lat, lon in conn.execute(
            """SELECT s.u, s.v, s.piece, a.lat, a.lon FROM traffic_samples s
               JOIN traffic_nodes a ON a.id = s.u WHERE s.ts >= ?""", (now - SAMPLE_KEEP,)):
        item = entry(lat, lon)
        item["pieces"].add(piece)
        item["seen"].add((u, v))
    for row in live_edges(conn, now):
        item = entry(row[2], row[3])
        item["published"] += 1
        item["slow"] += row[6] >= 2
    current = bucket_name(profile_slot(now))
    for row in typical_rows(conn, now):
        if row[0] == current:
            entry(row[3], row[4])["typical"] += 1
    out = [dict(item, pieces=len(item["pieces"]), seen=len(item["seen"])) for item in areas.values()]
    return sorted(out, key=lambda item: (-item["pieces"], -item["published"], str(item["area"])))


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


def typical_rows(conn, now):
    """Публикуемые строки «обычно» с id узлов: [(файл, u, v, ulat, ulon, vlat,
    vlon, kmh, model_kmh)] — только рёбра с TYPICAL_MIN_PIECES эффективными
    кусками в классе дня и часе и прошедшие проверку «не один человек» за
    последние SHARED_TTL. Сложение и порог — в SQLite: в Python приходят только
    публикуемые рёбра, а не весь профиль. model_kmh — скорость графа (car.lua)
    на ребре, 0 — неизвестна: по ней телефон считает, на сколько обычная
    пробка этого часа удлиняет ЛЮБОЙ маршрут (27.E), а не только свою дорогу."""
    scale = decay_scale(profile_epoch(conn, now), now)
    # Класс дня — тем же bucket_name, что и везде: правило в одном месте.
    conn.create_function("bucket_name", 1, bucket_name)
    # Допуск 1e-9: пять кусков одного момента — пять, а не 4,999… от
    # сложения степеней.
    rows = conn.execute("""SELECT bucket_name(p.how) AS bucket, p.u, p.v, SUM(p.pieces), SUM(p.sum_pace),
                                  a.lat, a.lon, b.lat, b.lon, COALESCE(MAX(e.model_kmh), 0)
                           FROM traffic_profile p
                           JOIN traffic_shared s ON s.u = p.u AND s.v = p.v
                           JOIN traffic_nodes a ON a.id = p.u
                           JOIN traffic_nodes b ON b.id = p.v
                           LEFT JOIN traffic_edges e ON e.u = p.u AND e.v = p.v
                           WHERE p.pieces > 0 AND s.seen >= ?
                           GROUP BY p.u, p.v, bucket
                           HAVING SUM(p.pieces) >= ? AND SUM(p.sum_pace) > 0""",
                        (now - SHARED_TTL, TYPICAL_MIN_PIECES * scale * (1 - 1e-9)))
    out = []
    for name, u, v, pieces, pace, alat, alon, blat, blon, model in rows:
        kmh = min(MAX_KMH, 3600.0 / (pace / pieces))
        out.append((name, u, v, alat, alon, blat, blon, kmh, model or 0.0))
    return sorted(out)


def typical_buckets(conn, now):
    """{имя файла: [(ulat, ulon, vlat, vlon, kmh, model_kmh)]} — строки
    typical_rows по файлам. Отсортировано: одинаковые данные — одинаковый файл."""
    out = {}
    for name, _u, _v, alat, alon, blat, blon, kmh, model in typical_rows(conn, now):
        out.setdefault(name, []).append((alat, alon, blat, blon, kmh, model))
    return {name: sorted(edges) for name, edges in out.items()}


def maintain_profile(conn, now):
    """Уборка профиля не чаще раза в PROFILE_MAINTAIN_EVERY (п. 6 шапки):
    умершие строки, просроченные отметки «не один человек» и, раз в
    PROFILE_RENORM_AFTER, перевод сумм к метке «сейчас». True — уборка была."""
    row = conn.execute("SELECT value FROM traffic_meta WHERE key = 'profile_maintained'").fetchone()
    if row is not None and now - row[0] < PROFILE_MAINTAIN_EVERY:
        return False
    epoch = profile_epoch(conn, now)
    scale = decay_scale(epoch, now)
    # n ≥ pieces у каждой строки (кусок даёт ребру хотя бы один отрезок), а
    # строки до 8.8.16 — с pieces = 0: умирают, когда отстареет и n.
    conn.execute("DELETE FROM traffic_profile WHERE pieces < ? AND n < ?",
                 (PROFILE_DROP * scale, PROFILE_DROP * scale))
    conn.execute("DELETE FROM traffic_shared WHERE seen < ?", (now - SHARED_TTL,))
    conn.execute("DELETE FROM traffic_slot_obs WHERE day < ?", (day_number(now) - tc.PROFILE_KEEP_DAYS,))
    conn.execute("DELETE FROM traffic_turn_obs WHERE day < ?", (day_number(now) - tc.PROFILE_KEEP_DAYS,))
    if now - epoch >= PROFILE_RENORM_AFTER:
        # Одна транзакция с новой меткой: числа и метка меняются разом.
        factor = 1.0 / scale
        conn.execute("""UPDATE traffic_profile SET n = n * ?, sum_kmh = sum_kmh * ?,
                            pieces = pieces * ?, sum_pace = sum_pace * ?""", (factor,) * 4)
        conn.execute("INSERT OR REPLACE INTO traffic_meta(key, value) VALUES('profile_epoch', ?)", (now,))
    conn.execute("INSERT OR REPLACE INTO traffic_meta(key, value) VALUES('profile_maintained', ?)", (now,))
    conn.commit()
    return True


def typical_payload(name, edges, now):
    return {
        "v": TYPICAL_VERSION,
        "bucket": name,
        "generated": int(now),
        "edges": [[round(a, 5), round(b, 5), round(c, 5), round(d, 5), int(round(kmh)),
                   int(round(model))]
                  for a, b, c, d, kmh, model in edges],
    }


def write_typical(conn, now, directory=TYPICAL_DIR):
    """Все 48 файлов (пустой — честное «данных нет», а не 404). Файл
    переписывается, только если сменились рёбра: иначе ETag и 304 у телефона
    теряли бы смысл. Возвращает, сколько файлов записано."""
    buckets = typical_buckets(conn, now)
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


def profile_due(conn, now):
    row = conn.execute("SELECT value FROM traffic_meta WHERE key = 'profile_json_built'").fetchone()
    return row is None or now - row[0] >= tc.PROFILE_JSON_EVERY


def write_profile_json(conn, now, path=PROFILE_PATH):
    """profile.json (33C) — раз в PROFILE_JSON_EVERY, переписывается всегда:
    телефон считает файл старше 36 ч «нет данных», и неизменный профиль
    должен получить свежую метку. Возвращает (рёбер, обрезано)."""
    import traffic_profile   # там формулы 33A; он сам импортирует этот модуль
    body, count, trimmed = traffic_profile.profile_body(conn, now)
    write_atomic(path, body)
    conn.execute("INSERT OR REPLACE INTO traffic_meta(key, value) VALUES('profile_json_built', ?)", (now,))
    conn.commit()
    return count, trimmed


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


def write_gzip_copy(path, body):
    """Готовый path.gz: nginx с gzip_static не сжимает файл на каждый запрос."""
    tmp = path + ".gz.tmp"
    with open(tmp, "wb") as f:
        f.write(gzip.compress(body.encode("utf-8"), 6, mtime=0))
    os.replace(tmp, path + ".gz")


# Показ пробки для проверки владельцем (27.10): пока файл есть и не истёк,
# его рёбра добавляются в now.json поверх настоящих. Срок вшит в сам файл —
# забытый показ гаснет сам; откат раньше срока — удалить файл. Файл скоростей
# маршрутизатора он не трогает: только показ, ETA и «Впереди пробка».
DEMO_PATH = "/opt/radarmap/api/traffic_demo.json"


def demo_edges(now, path=DEMO_PATH):
    """Рёбра показа [(ulat, ulon, vlat, vlon, level, kmh, model_kmh)] или []."""
    try:
        with open(path, encoding="utf-8") as f:
            demo = json.load(f)
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as error:
        print(f"показ пробки: файл не читается — {error}", file=sys.stderr)
        return []
    if not isinstance(demo, dict) or float(demo.get("expires", 0)) <= now:
        return []
    out = []
    for e in demo.get("edges", []):
        if (isinstance(e, list) and len(e) == 7 and e[4] in (1, 2, 3)
                and all(isinstance(x, (int, float)) for x in e)):
            out.append(tuple(e))
    return out


def merge_demo(edges, demo):
    """Показ поверх настоящих рёбер: то же ребро (u→v по координатам) — из показа."""
    if not demo:
        return edges
    key = lambda e: (round(e[0], 5), round(e[1], 5), round(e[2], 5), round(e[3], 5))
    taken = {key(e) for e in demo}
    return [e for e in edges if key(e) not in taken] + list(demo)


def run(conn, now, matcher=osrm_match, out_path=OUT_PATH, typical_dir=TYPICAL_DIR, profile_path=PROFILE_PATH,
        demo_path=DEMO_PATH):
    """Один прогон без замка и печати (main и тесты). Возвращает (кусков,
    отрезков, рёбер в now.json, переписано файлов «обычно» или None)."""
    schema(conn)
    pieces, segments = process(conn, now, matcher=matcher)
    prune(conn, now)
    edges = aggregate(conn, now)
    body = json.dumps(payload(merge_demo(edges, demo_edges(now, demo_path)), now), separators=(",", ":"))
    write_atomic(out_path, body)
    write_gzip_copy(out_path, body)
    mark_shared(conn, now)
    typical = None
    if typical_due(conn, now):
        maintain_profile(conn, now)
        typical = write_typical(conn, now, directory=typical_dir)
    if profile_due(conn, now):
        count, trimmed = write_profile_json(conn, now, profile_path)
        if trimmed:
            print(f"profile.json: ПОТОЛОК {tc.PROFILE_JSON_MAX_GZIP // 1024} КБ gzip — обрезано рёбер {trimmed}",
                  file=sys.stderr)
    return pieces, segments, len(edges), typical


def main():
    # Прогон, затянувшийся дольше 2 минут (OSRM тормозит), не должен
    # встретиться со следующим: второй взял бы те же ждущие куски до их
    # удаления первым и сложил бы их в профиль дважды — порог «пяти кусков»
    # набирался бы вдвое быстрее.
    with open(LOCK_PATH, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} прошлый прогон ещё идёт — пропуск")
            return
        now = time.time()
        conn = sqlite3.connect(DB_PATH, timeout=5)
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("PRAGMA synchronous = NORMAL")
        try:
            pieces, segments, edges, typical = run(conn, now)
        finally:
            conn.close()
    note = "" if typical is None else f", «обычно» файлов переписано {typical}"
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} кусков {pieces}, отрезков {segments}, рёбер в выходе {edges}{note}")


if __name__ == "__main__":
    main()
