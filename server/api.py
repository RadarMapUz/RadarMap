#!/usr/bin/env python3
"""RadarMap API: краудсорсинг передвижных радаров, метрики, обратная связь.

Stdlib-only (sqlite3 + http.server): без pip-зависимостей на общем VPS.
Слушает 127.0.0.1:8091, наружу отдаётся nginx'ом на :8090/api/.

Endpoints:
  GET  /api/health         -> {"ok": true}
  GET  /api/mobile         -> {"reports": [{id, lat, lon, created, expires, up, down,
                                            type, confirmed}]}   (без перекрытий и ремонта)
  GET  /api/road           -> {"reports": [... то же + course]}  (только closure/roadwork)
  POST /api/report         {lat, lon, device, type [, course]}  -> {"id": N, "merged": bool
                                                                    [, "amended": true]}
  POST /api/vote           {id, device, value: 1|-1 [, kind: "pass"]} -> {"ok": true}
  POST /api/metrics        {device, kind, payload}   -> {"ok": true}   (MetricKit)
  POST /api/camera_report  {camera_id, reason, lat, lon, db_version, device} -> {"ok": true}
  POST /api/feedback       {message, contact, app_version, device}     -> {"ok": true}
  POST /api/stat           {device, day, app, ios, model, location_auth, onboarded,
                            trips, km, alerts, passes, reports, screens} -> {"ok": true}
                           (обезличенный суточный агрегат: ни координат, ни времени событий)
  POST /api/traffic        {v: 1, pieces: [{p: [[lat, lon, t, kmh], ...]}]} -> {"ok": true, "accepted": N}
                           (куски следа для пробок: без устройства, без поездки, время —
                            только относительное внутри куска; см. «Пробки» ниже)
  POST /api/eta            {token, eta, left_m, status: "driving"|"arrived"|"ended"} -> {"ok": true}
  GET  /api/eta/<token>    -> HTML «будет примерно в 18:40» (см. «Поделиться прибытием» ниже)

Правила передвижных радаров (жизненный цикл доверия):
  * новая отметка — на испытательном сроке (радар/тренога 75 мин, пост 2 ч):
    фейк, которого никто не подтвердил, умирает сам
  * полный срок (3 ч / 6 ч) даёт только НЕЗАВИСИМОЕ подтверждение — другое
    устройство И другой адрес: ротация UUID не превращает слух в факт
  * подтверждение (+1) продлевает на 30 мин (максимум 6 ч от создания)
  * новая отметка в 300 м от активной того же типа — подтверждение (merge)
  * та же точка от того же устройства с ДРУГИМ типом в 400 м / 10 мин —
    уточнение типа своей отметки (amend), а не вторая точка
  * дизлайк с нового адреса срезает 30 мин жизни; полное скрытие — по кворуму:
    3+ дизлайков, больше лайков, с >=3 разных адресов
  * на устройство: максимум 3 активных отметки, минимум 120 с между отметками;
    на адрес: максимум 12 активных отметок

Модерация — в панели (server/admin.py, отдельный процесс на :8092, наружу
через nginx /admin/ с basic auth). Она же проставляет camera_reports.resolved
и копит решения в таблице overrides; публикует их владелец локальной командой
server/publish_overrides.sh — ключ подписи на VPS не хранится.
"""
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import notify

DB_PATH = "/opt/radarmap/api/reports.db"
# Пробки — отдельный файл: куски следа пишутся потоком всю поездку каждого
# водителя, и делить с ними блокировки базы отметок незачем. Читает и чистит
# его server/traffic_build.py.
TRAFFIC_DB_PATH = "/opt/radarmap/api/traffic.db"
# Потолок одновременных обработчиков. У ThreadingHTTPServer предела нет: поток
# на соединение плюс медленный клиент — и память кончается раньше, чем сработают
# капы. Сверх потолка отвечаем 503: честный отказ лучше молчаливой очереди.
MAX_WORKERS = 64
BUSY_TIMEOUT_MS = 5000
TTL = 3 * 3600
EXTEND = 30 * 60
MAX_LIFE = 6 * 3600
# ПОЛНЫЙ срок жизни по типам — его отметка получает только после независимого
# подтверждения. Пост стоит долго, ДТП рассасывается за час.
REPORT_TTLS = {"radar": TTL, "tripod": TTL, "post": 6 * 3600, "accident": 3600,
               "closure": 12 * 3600, "roadwork": 7 * 86400}
# Перекрытие и ремонт (12б.5) — события дороги, а не камеры. Живут в своём
# списке GET /api/road: старые сборки читают незнакомый тип в /api/mobile как
# «радар» и предупреждали бы о ремонте как о передвижном радаре. Отдельный
# список им не виден вовсе. Свой и кап активных отметок устройства: ремонт
# живёт неделю, и три отмеченных ремонта не должны запирать «Радар!».
ROAD_TYPES = ("closure", "roadwork")
# Свои капы активных точек у событий дороги: ремонт живёт до недели, и при
# общих капах дюжина ремонтов за одним адресом оператора (CGNAT) запирала
# бы «Радар!» всем за ним, а сорок адресов — всей стране.
MAX_ACTIVE_ROAD = 300
MAX_ACTIVE_ROAD_PER_IP = 6


def is_road(rtype):
    return rtype in ROAD_TYPES
# Испытательный срок новой отметки. Ставить фейки должно быть бессмысленно:
# точка, которую не подтвердил ни один независимый водитель, умирает сама —
# ни модерации, ни кворума не нужно. Цена: одинокая честная тренога на пустой
# дороге живёт 75 мин вместо трёх часов — но там её и видят единицы.
PROBATION_TTLS = {"radar": 75 * 60, "tripod": 75 * 60, "post": 2 * 3600,
                  "accident": 3600, "closure": 3 * 3600, "roadwork": 24 * 3600}

# --- Испытательный срок и холодный старт --------------------------------------
#
# Испытательный срок держится на допущении, которого в первые недели нет:
# что рядом есть ДРУГОЙ водитель, способный подтвердить отметку. Пока
# приложение только запустили, честная тренога умирает через 75 минут просто
# потому, что подтверждать её некому, — и первый же человек, нажавший кнопку,
# видит, что ничего не произошло, и больше не нажимает. Так фильтр от фейков
# убивает ровно ту функцию, которую защищает.
#
# Поэтому испытательный срок включается САМ, когда плотность появилась, а не
# по флагу, который однажды поставят и забудут: если за последнюю неделю
# отметки ставили меньше PROBATION_MIN_DEVICES разных устройств, подтверждать
# всё равно некому — новая точка сразу получает полный срок.
#
# Ручное переопределение оставлено на случай волны фейков: переменная
# окружения RADARMAP_PROBATION = auto (по умолчанию) | on | off.
PROBATION_MIN_DEVICES = 25
PROBATION_WINDOW = 7 * 86400
PROBATION_CACHE_TTL = 300
PROBATION_MODE = os.environ.get("RADARMAP_PROBATION", "auto").strip().lower()

_probation_cache = (0.0, None)
_probation_lock = threading.Lock()


def probation_active(conn, now):
    """Работает ли испытательный срок прямо сейчас.

    Решает плотность, а не календарь: считаем РАЗНЫЕ устройства, ставившие
    отметки за неделю. Результат кэшируется на пять минут — запрос дешёвый и
    по индексу, но он на горячем пути создания отметки.
    """
    if PROBATION_MODE == "on":
        return True
    if PROBATION_MODE == "off":
        return False
    global _probation_cache
    with _probation_lock:
        stamp, cached = _probation_cache
        if cached is not None and now - stamp < PROBATION_CACHE_TTL:
            return cached
    try:
        devices = conn.execute(
            "SELECT COUNT(DISTINCT device) FROM reports WHERE created > ?",
            (now - PROBATION_WINDOW,)).fetchone()[0]
    except sqlite3.Error:
        # Сомнение трактуем в пользу защиты: лучше короткий срок жизни
        # у честной отметки, чем открытая дверь фейкам.
        return True
    active = devices >= PROBATION_MIN_DEVICES
    with _probation_lock:
        _probation_cache = (now, active)
    return active
# Дизлайк с нового адреса срезает жизнь: два честных «Нет» после проезда
# убирают пустышку задолго до кворума на полное скрытие. Пол — 5 минут:
# мгновенное снятие остаётся привилегией кворума разных адресов.
DOWN_PENALTY = 30 * 60
DOWN_FLOOR = 300
# Уточнение типа своей отметки: радиус тот же, что у окна дублей в приложении
# (ReportGuard, 400 м); окно шире клиентских секунд — уточнить можно и из меню.
AMEND_WINDOW = 10 * 60
AMEND_METERS = 400
MERGE_METERS = 300
# Радиус слияния зависит от дороги, а не один на страну. На трассе две
# настоящие треноги в 300 м — это две разные засады, и схлопывать их нельзя;
# в квартале 300 м — соседняя улица, и туда отметка попадать не должна.
# Класс приходит от клиента: он снапает точку на ось по своим дорожным тайлам
# и знает, по чему едет. Нет класса (старый клиент) — прежние 300 м.
MERGE_METERS_BY_CLASS = {
    "motorway": 400, "trunk": 400, "primary": 300, "secondary": 250,
    "tertiary": 200, "residential": 120, "service": 120,
    "living_street": 120, "unclassified": 200,
}
# Окно отзыва своей отметки. Совпадает с окном уточнения типа: и то и другое —
# «я только что нажал, дайте исправить», а не право распоряжаться точкой,
# которую уже подтвердили другие.
CANCEL_WINDOW = 10 * 60
# Адрес панели — чтобы уведомление в Telegram вело на запись, а не заставляло
# искать её глазами. Пусто — ссылки в сообщении просто не будет.
ADMIN_URL = os.environ.get("RADARMAP_ADMIN_URL", "")
UZ_LAT = (37.0, 46.0)
UZ_LON = (55.0, 74.0)
# Глобальные капы — потолок ущерба от ротации device (лимиты per-device
# обходятся новым UUID на каждый запрос). Честные объёмы в разы ниже.
MAX_ACTIVE_REPORTS = 500     # активных отметок всего (и потолок O(N)-скана дедупликации)
MAX_METRICS_ROWS = 5000      # строк метрик в БД (по ~200 КБ — потолок диска)
# Суточная метрика — десятки КБ. Диагностика (падение, зависание, CPU) несёт
# дерево стеков и бывает за 200 КБ: при прежнем общем пороге её отбивало 400,
# и за 30 дней на сервере не оказалось НИ ОДНОЙ — то есть вылеты и зависания
# у людей были невидимы. Диагностик единицы в сутки, суточный кап 20 на
# устройство и потолок строк остаются — диск это переживёт.
METRIC_MAX_BYTES = 200_000
DIAGNOSTIC_MAX_BYTES = 2_000_000
MAX_DAILY_ROWS = 2000        # camera_reports/feedback суммарно в сутки
MAX_VOTES_PER_DAY = 30       # голосов с устройства в сутки
MAX_ID = 2**31               # верхняя граница id: больше — не наш id, а OverflowError в SQLite
# Суточные капы по IP: device ротируется бесплатно, IP — нет. Пороги в разы
# выше честного пользования, но на порядки ниже «один атакующий забивает
# глобальный кап»: раньше 500 UUID с одного адреса гасили /api/report для всех,
# а 250 — сбор метрик на месяц. CGNAT мобильных сетей помним, поэтому капы
# щедрые: за одним адресом оператора живут десятки честных водителей.
IP_DAILY_CAPS = {"report": 30, "vote": 100, "camera_report": 60,
                 "feedback": 30, "metrics": 60, "stat": 60}
MAX_USAGE_ROWS = 2_000_000   # ~90 дней × 20 000 устройств: потолок диска
# Скрытие отметки требует дизлайков с РАЗНЫХ адресов: три свежих UUID с одного
# телефона больше не снимают чужую отметку с карты.
HIDE_DISTINCT_IPS = 3
# Активных отметок с одного адреса. Суточный кап (30) не мешал одному адресу
# держать на карте десяток живых фейков разом. CGNAT помним: за одним адресом
# оператора — десятки честных водителей, поэтому не 3, а 12.
MAX_ACTIVE_PER_IP = 12

def db():
    """Соединение для обработки одного запроса.

    Схему здесь НЕ трогаем: раньше каждый HTTP-запрос выполнял шесть
    CREATE TABLE IF NOT EXISTS и четыре ALTER TABLE, из которых все четыре
    всегда падали в исключение — десяток служебных запросов до начала работы.
    Схема и миграции живут в init_db() и выполняются один раз при старте.

    busy_timeout обязателен: без него параллельный POST во время чтения
    /api/mobile отдаёт «database is locked» мгновенным 500 вместо ожидания.
    """
    conn = sqlite3.connect(DB_PATH, timeout=BUSY_TIMEOUT_MS / 1000)
    conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
    # NORMAL в паре с WAL: fsync на каждый коммит нам не нужен — потеря
    # последних отметок при отключении питания дешевле, чем запись в темпе диска.
    conn.execute("PRAGMA synchronous = NORMAL")
    return conn


def init_db():
    """Схема, миграции и индексы. Вызывается один раз при старте процесса."""
    conn = sqlite3.connect(DB_PATH, timeout=BUSY_TIMEOUT_MS / 1000)
    # WAL — свойство файла БД, ставится один раз и переживает перезапуск.
    # Без него писатель блокирует читателей: один POST /api/report во время
    # опроса десятком телефонов давал им 500.
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS reports(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lat REAL NOT NULL, lon REAL NOT NULL,
        created REAL NOT NULL, expires REAL NOT NULL,
        device TEXT NOT NULL, up INTEGER DEFAULT 0, down INTEGER DEFAULT 0,
        active INTEGER DEFAULT 1)""")
    # Теневой бан. Единственный рычаг против системного фейкомёта был капом,
    # а кап обходится ожиданием: UUID ротируется сам раз в 30 дней, адрес —
    # переподключением. Блокировка «тихая» намеренно: отметка принимается и
    # ложится в базу с active = 0. Автор видит «принято» и не начинает искать
    # обход, модератор видит строку целиком, а на карту она не попадает.
    conn.execute("""CREATE TABLE IF NOT EXISTS blocked(
        kind TEXT NOT NULL, value TEXT NOT NULL,
        until REAL NOT NULL, note TEXT DEFAULT '',
        created REAL NOT NULL,
        PRIMARY KEY(kind, value))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS votes(
        report_id INTEGER, device TEXT, value INTEGER,
        PRIMARY KEY(report_id, device))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS metrics(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device TEXT NOT NULL, kind TEXT NOT NULL,
        received REAL NOT NULL, payload TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS camera_reports(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        camera_id INTEGER NOT NULL,
        reason TEXT NOT NULL,
        lat REAL, lon REAL,
        db_version INTEGER,
        device TEXT NOT NULL,
        received REAL NOT NULL,
        resolved INTEGER DEFAULT 0)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS feedback(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message TEXT NOT NULL,
        contact TEXT,
        app_version TEXT,
        device TEXT NOT NULL,
        received REAL NOT NULL)""")
    # Обезличенный суточный агрегат: ни координат, ни маршрутов, ни времени
    # событий — только счётчики. Один отчёт на устройство в сутки (PRIMARY KEY),
    # повтор просто перезаписывает: сеть могла оборвать подтверждение, и
    # дубликат не должен раздувать «сколько у нас пользователей».
    conn.execute("""CREATE TABLE IF NOT EXISTS usage_stats(
        device TEXT NOT NULL, day TEXT NOT NULL,
        app TEXT, ios TEXT, model TEXT,
        location_auth TEXT, onboarded INTEGER,
        trips INTEGER, km REAL, alerts INTEGER, passes INTEGER, reports INTEGER,
        screens TEXT, received REAL NOT NULL,
        PRIMARY KEY(device, day))""")

    # --- миграции живой БД (порядок: только после CREATE всех таблиц) ---
    migrate(conn, "votes", "ts REAL DEFAULT 0")               # суточный лимит голосов
    migrate(conn, "reports", "type TEXT DEFAULT 'radar'")     # radar/tripod/post/accident/closure/roadwork
    migrate(conn, "reports", "course REAL DEFAULT -1")       # курс отметившего (перекрытие одной стороны)
    migrate(conn, "feedback", "status TEXT DEFAULT 'new'")    # new/open/answered (админка)
    migrate(conn, "feedback", "note TEXT DEFAULT ''")         # заметка модератора
    # IP голосов, отметок и репортов о камерах. Все device-лимиты обходятся
    # новым UUID на каждый запрос; IP от nginx (X-Forwarded-For = $remote_addr,
    # клиентский заголовок перезаписывается) — единственный признак, который
    # ротацией не меняется. Старые строки остаются с '' и в проверках не
    # участвуют: лучше передержать отметку, чем дать снять её анонимной ротацией.
    #
    # camera_reports получили ip позже остальных, и это была дыра: модератор
    # видел «5 разных устройств сообщили, что камеры нет» — а это пять запросов
    # с одного телефона со свежим UUID. Снять по такому сигналу живую камеру
    # значит получить молчание там, где камера стоит, то есть худший отказ всей
    # системы. Кворум на скрытие считается по РАЗНЫМ адресам (см. admin.py).
    for table in ("votes", "reports", "camera_reports"):
        migrate(conn, table, "ip TEXT DEFAULT ''")
    # Происхождение голоса: "pass" — после реального проезда (MobilePassWatch),
    # "merge" — повторная отметка тем же местом. Вес не меняет — проезд сервер
    # проверить не может, — но модератор в админке видит, какому сигналу верить.
    migrate(conn, "votes", "kind TEXT DEFAULT ''")
    # Счётчики КАЧЕСТВА решений приложения (limitSource, maneuvers,
    # tripsDropped, alertRecall) — одной JSON-колонкой, а не четырьмя.
    # Набор счётчиков меняется чаще, чем схема должна мигрировать, а запросов
    # «сгруппируй по источнику лимита» здесь не будет: читают их сводкой.
    #
    # Заведена 25 сентября: клиент считал эти счётчики с 6 сентября, но не
    # клал их в payload, а сервер — не имел куда положить. Три недели данных,
    # на которые был заложен план А4, не собирались вовсе.
    migrate(conn, "usage_stats", "quality TEXT DEFAULT ''")
    # Почему отметка перестала быть живой. Без этого «доля дошедших до
    # подтверждения» и «доля снесённых» неотличимы друг от друга: в таблице
    # видно только active = 0, а причин у него пять.
    #   ''        — ещё жива либо истекла сама (по expires)
    #   author    — автор отозвал свой случайный тап
    #   quorum    — кворум дизлайков с разных адресов
    #   moderator — решение из админки
    #   blocked   — теневой бан, точка не публиковалась вовсе
    migrate(conn, "reports", "closed TEXT DEFAULT ''")
    # Класс дороги от клиента (он уже снапнул точку на ось по своим тайлам).
    # Нужен радиусу слияния: 300 м на трассе — соседние треноги, 300 м в
    # квартале — та же самая.
    migrate(conn, "reports", "cls TEXT DEFAULT ''")

    # --- индексы ---
    # Раньше не было ни одного: каждая проверка суточного капа была полным
    # сканом таблицы, а горячий GET /api/mobile сканировал все отметки.
    for statement in (
        "CREATE INDEX IF NOT EXISTS idx_reports_live ON reports(active, expires)",
        "CREATE INDEX IF NOT EXISTS idx_reports_device ON reports(device, active, expires)",
        "CREATE INDEX IF NOT EXISTS idx_reports_ip ON reports(ip, active, expires)",
        "CREATE INDEX IF NOT EXISTS idx_reports_created ON reports(created)",
        "CREATE INDEX IF NOT EXISTS idx_blocked_until ON blocked(until)",
        # votes(report_id, …) уже покрыт индексом первичного ключа
        "CREATE INDEX IF NOT EXISTS idx_votes_device ON votes(device, ts)",
        "CREATE INDEX IF NOT EXISTS idx_camrep_camera ON camera_reports(camera_id, resolved)",
        "CREATE INDEX IF NOT EXISTS idx_camrep_device ON camera_reports(device, received)",
        "CREATE INDEX IF NOT EXISTS idx_camrep_received ON camera_reports(received)",
        "CREATE INDEX IF NOT EXISTS idx_feedback_received ON feedback(received)",
        "CREATE INDEX IF NOT EXISTS idx_feedback_device ON feedback(device, received)",
        "CREATE INDEX IF NOT EXISTS idx_metrics_device ON metrics(device, received)",
        "CREATE INDEX IF NOT EXISTS idx_metrics_received ON metrics(received)",
        "CREATE INDEX IF NOT EXISTS idx_usage_day ON usage_stats(day)",
        "CREATE INDEX IF NOT EXISTS idx_usage_received ON usage_stats(received)",
    ):
        conn.execute(statement)

    conn.commit()
    conn.close()


# --- Пробки ---------------------------------------------------------------------
#
# Телефон присылает куски следа поездки (~1 км), из которых traffic_build.py
# через OSRM match получает скорость на рёбрах дорог OSM. Приватность — по
# построению, и проверки ниже её охраняют, а не только форму:
#   * в куске нет ни устройства, ни поездки, ни абсолютного времени — только
#     секунды от начала куска; лишние поля не читаются и не сохраняются;
#   * IP не пишется никуда: он нужен только суточному лимиту в памяти;
#   * сырой кусок живёт до сопоставления (traffic_build.py удаляет его сразу
#     после, и в любом случае через TRAFFIC_PIECE_TTL);
#   * концы поездок и места у дома/работы режет сам телефон (TrafficProbes).
TRAFFIC_BODY_LIMIT = 64 * 1024
TRAFFIC_MAX_PIECES = 12          # за один запрос (пачка раз в 2 минуты)
TRAFFIC_MIN_POINTS = 3
TRAFFIC_MAX_POINTS = 120         # в куске
TRAFFIC_MAX_SPAN = 900           # секунд в куске (стоим в пробке — кусок длинный)
TRAFFIC_MAX_STEP_MPS = 70.0      # между соседними точками (~250 км/ч)
TRAFFIC_PIECES_PER_IP_DAY = 5000 # CGNAT: за адресом оператора — десятки машин
# Дубли: ответ на POST потерялся (таймаут, смена соты) — телефон шлёт ту же
# пачку снова, и одна машина набирала бы MIN_PIECES=2 сама с собой (ревью S21,
# 20.10). Отпечаток куска живёт полчаса: сырые куски удаляются через пару минут
# после сопоставления, и по ним повтор уже не поймать. Отпечаток — sha256
# тех же чисел, что и так лежат в traffic_pieces; ни устройства, ни адреса.
TRAFFIC_SEEN_TTL = 30 * 60
# Узбекистан с запасом: точка за границей — не наша дорога или подделка.
UZ_LAT = (37.0, 45.8)
UZ_LON = (55.8, 73.3)


def traffic_db():
    conn = sqlite3.connect(TRAFFIC_DB_PATH, timeout=BUSY_TIMEOUT_MS / 1000)
    conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
    conn.execute("PRAGMA synchronous = NORMAL")
    return conn


def init_traffic_db():
    conn = sqlite3.connect(TRAFFIC_DB_PATH, timeout=BUSY_TIMEOUT_MS / 1000)
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_pieces(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        received REAL NOT NULL,
        points TEXT NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS traffic_pieces_received ON traffic_pieces(received)")
    conn.execute("""CREATE TABLE IF NOT EXISTS traffic_seen(
        hash TEXT PRIMARY KEY,
        received REAL NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS traffic_seen_received ON traffic_seen(received)")
    conn.commit()
    conn.close()


# Сколько секунд назад телефон поставил отметку из очереди — не больше часа:
# дольше очередь телефона отметки не держит.
REPORT_MAX_AGE = 3600


def report_age(data):
    try:
        age = float(data.get("age", 0))
    except (TypeError, ValueError):
        return 0
    if not math.isfinite(age):
        return 0
    return min(max(age, 0), REPORT_MAX_AGE)


def clean_traffic_piece(raw):
    """Кусок в каноническом виде или None. Берутся только четыре числа точки;
    всё, что прислали сверх, отбрасывается — сохранить «случайно» нечего."""
    if not isinstance(raw, dict):
        return None
    points = raw.get("p")
    if not isinstance(points, list) or not (TRAFFIC_MIN_POINTS <= len(points) <= TRAFFIC_MAX_POINTS):
        return None
    out = []
    for point in points:
        if not isinstance(point, list) or len(point) != 4:
            return None
        try:
            lat, lon, t, kmh = (float(v) for v in point)
        except (TypeError, ValueError):
            return None
        if not all(math.isfinite(v) for v in (lat, lon, t, kmh)):
            return None
        if not (UZ_LAT[0] <= lat <= UZ_LAT[1] and UZ_LON[0] <= lon <= UZ_LON[1]):
            return None
        if kmh > 250:
            return None
        out.append([round(lat, 5), round(lon, 5), int(round(t)), int(round(kmh)) if kmh >= 0 else -1])
    if out[0][2] != 0 or out[-1][2] > TRAFFIC_MAX_SPAN:
        return None
    for a, b in zip(out, out[1:]):
        dt = b[2] - a[2]
        if dt <= 0:
            return None
        if haversine(a[0], a[1], b[0], b[1]) / dt > TRAFFIC_MAX_STEP_MPS:
            return None
    return out


def migrate(conn, table, column_def):
    """ALTER TABLE ADD COLUMN, идемпотентно. Отдельной функцией, чтобы
    «колонка уже есть» не путалась с настоящей ошибкой схемы в глазах читателя."""
    try:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column_def}")
    except sqlite3.OperationalError:
        pass  # колонка уже есть

def clean_text(s):
    """Пользовательский текст идёт в терминал модератора (sqlite3 в консоли) —
    вырезаем управляющие символы, чтобы ANSI-escape'ами нельзя было рисовать."""
    return "".join(ch for ch in s if ch.isprintable() or ch == "\n")

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# Версии данных в суточной сводке (dataVersions): что именно телефон держит.
# roads и mvt — первые 7 hex sha256 подписанного индекса, как число; так же
# их считает status.py по опубликованному файлу.
DATA_VERSION_KEYS = ("cameras", "limits", "roads", "mvt", "overrides", "hotspots")


def clamp_int(value, limit=100000):
    """Счётчик из отчёта. Не число, отрицательное или неправдоподобно большое —
    ноль: испорченное поле не должно ни падать, ни искажать сводку."""
    try:
        number = int(value or 0)
    except (TypeError, ValueError):
        return 0
    return number if 0 <= number <= limit else 0


def as_str(value, default=None):
    """Строгое строковое поле. str(dict) молча сохранял Python-repr словаря
    вместо 400 — ветка except TypeError в хендлерах была недостижима."""
    if value is None and default is not None:
        return default
    if not isinstance(value, str):
        raise TypeError(f"expected str, got {type(value).__name__}")
    return value

# Суточные счётчики по IP — в памяти, а не в БД: при рестарте обнуляются, и это
# нормально для rate-limit'а. Ключ (день, ip); прошлые дни чистятся лениво.
_ip_lock = threading.Lock()
_ip_counters = {}

# Чистка протухших отметок из GET /api/mobile — не чаще раза в минуту.
_cleanup_lock = threading.Lock()
_last_cleanup = 0.0

# Ответ GET /api/mobile — общий для всех: это один и тот же список отметок по
# стране. Его собирали заново на каждый запрос каждого телефона, хотя между
# запросами он меняется редко.
#
# Отсюда две вещи, и обе — про батарею телефона, а не про сервер.
#
# ETag: тело считается один раз, его отпечаток уходит заголовком, и телефон
# присылает его обратно. Не изменилось — 304 без тела. Радио на приём пустого
# ответа тратит десятки миллиджоулей вместо сотен на разбор двухсот килобайт
# JSON; именно это позволяет опрашивать ЧАЩЕ, не платя за это временем работы.
#
# Мемо на секунду: одновременный опрос с сотни телефонов сканировал таблицу
# сто раз. Версия в ключе делает мемо честным — любая запись (отметка, голос,
# отзыв) обнуляет его сразу, а не через секунду.
_mobile_lock = threading.Lock()
_mobile_cache = None          # (version, built_at, etag, body)
_road_cache = None            # то же для GET /api/road
_mobile_version = 0
MOBILE_MEMO_SECONDS = 1.0

def bump_mobile_version():
    """Список отметок изменился — мемо ответа больше не действительно."""
    global _mobile_version
    with _mobile_lock:
        _mobile_version += 1

def ip_quota_exceeded(bucket, ip, cap):
    """True — суточный кап этого IP по данному бакету исчерпан (и счёт +1)."""
    if not ip:
        return False
    day = int(time.time() // 86400)
    with _ip_lock:
        stale = [k for k in _ip_counters if k[0] != day]
        for k in stale:
            del _ip_counters[k]
        key = (day, bucket, ip)
        count = _ip_counters.get(key, 0)
        if count >= cap:
            return True
        _ip_counters[key] = count + 1
        return False

def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def confirmed_independently(conn, rid, owner_device, owner_ip):
    """Есть ли у отметки лайк с ДРУГОГО устройства и ДРУГОГО адреса.

    Только такой голос превращает испытательный срок в полный: свой UUID
    ротируется бесплатно, свой адрес — нет. Старые голоса без ip ('') не в
    счёт — консервативно: лучше недодержать отметку, чем продлить фейк его же
    рукой. За CGNAT второй честный водитель может не подтвердить (адрес общий) —
    эта цена ниже, чем самоподтверждение фейков ротацией UUID.
    """
    return conn.execute(
        "SELECT 1 FROM votes WHERE report_id = ? AND value = 1 "
        "AND device != ? AND ip != '' AND ip != ? LIMIT 1",
        (rid, owner_device, owner_ip)).fetchone() is not None


def is_blocked(conn, ip, device, now):
    """Источник под теневым баном. Проверяются оба ключа: адрес переживает
    ротацию UUID, устройство — смену сети."""
    row = conn.execute(
        "SELECT 1 FROM blocked WHERE until > ? AND "
        "((kind = 'ip' AND value = ?) OR (kind = 'device' AND value = ?)) LIMIT 1",
        (now, ip or "\x00", device)).fetchone()
    return row is not None


def merge_radius(cls):
    """Радиус слияния по классу дороги; неизвестный класс — прежние 300 м."""
    return MERGE_METERS_BY_CLASS.get(cls or "", MERGE_METERS)


def road_new_ttl(conn, rtype, now):
    """Срок новой (или переведённой через границу) точки. Событиям дороги —
    всегда испытательный: без независимого подтверждения неделя ремонта от
    одного тапа на холодном старте висела бы неделю, а снять её водителю нечем."""
    if is_road(rtype) or probation_active(conn, now):
        return PROBATION_TTLS[rtype]
    return REPORT_TTLS[rtype]


def lifecycle_expires(created, expires, rtype, confirmed, now):
    """Новый expires после лайка. Неподтверждённой точке лайк жизнь НЕ
    продлевает (испытательный срок идёт), подтверждённой — полный срок её типа
    плюс 30 мин за голос, но не дальше MAX_LIFE от создания."""
    if not confirmed:
        return expires
    full = REPORT_TTLS.get(rtype, TTL)
    new_exp = max(max(expires, now) + EXTEND, created + full)
    # Потолок — не меньше полного срока типа: ремонт живёт неделю, и шесть
    # часов MAX_LIFE обрезали бы его до испытательного дня.
    return min(created + max(MAX_LIFE, full), new_exp)

# --- Поделиться прибытием -------------------------------------------------
#
# Водитель отправляет знакомому ссылку «буду примерно в 18:40». Приватно по
# построению: телефон шлёт только время прибытия, остаток пути и статус — ни
# точки, ни цели, ни устройства; хранится всё в ПАМЯТИ процесса по случайной
# ссылке (128 бит) и гаснет само: без обновлений — через ETA_TTL, после «на
# месте» — через ETA_ARRIVED_TTL. Рестарт сервиса стирает все ссылки — это
# цена того, что на диске нет ничего.

ETA_TTL = 2 * 3600
ETA_ARRIVED_TTL = 30 * 60
ETA_MAX_LINKS = 5000
ETA_UPDATES_PER_IP_DAY = 2000
ETA_HORIZON = 48 * 3600
_ETA_TOKEN = re.compile(r"^[A-Za-z0-9_-]{22,64}$")
_eta_links = {}
_eta_lock = threading.Lock()


def clean_eta(data, now):
    """Чистое обновление или None. Берутся только четыре поля — всё остальное,
    что пришло (координаты, имя, устройство), не сохраняется вовсе."""
    if not isinstance(data, dict):
        return None
    token = data.get("token")
    status = data.get("status")
    if not isinstance(token, str) or not _ETA_TOKEN.match(token):
        return None
    if status not in ("driving", "arrived", "ended"):
        return None
    eta = data.get("eta")
    left = data.get("left_m", 0)
    if not isinstance(eta, (int, float)) or isinstance(eta, bool) or not math.isfinite(eta):
        return None
    if not isinstance(left, (int, float)) or isinstance(left, bool) or not math.isfinite(left):
        return None
    if not (now - 3600 <= eta <= now + ETA_HORIZON) or not (0 <= left <= 2_000_000):
        return None
    return token, {"eta": float(eta), "left_m": int(left), "status": status, "updated": now}


def eta_put(token, item, now):
    with _eta_lock:
        for key in [k for k, v in _eta_links.items() if _eta_expired(v, now)]:
            del _eta_links[key]
        if token not in _eta_links and len(_eta_links) >= ETA_MAX_LINKS:
            return False
        _eta_links[token] = item
        return True


def eta_get(token, now):
    with _eta_lock:
        item = _eta_links.get(token)
        if item and _eta_expired(item, now):
            del _eta_links[token]
            return None
        return dict(item) if item else None


def _eta_expired(item, now):
    ttl = ETA_TTL if item["status"] == "driving" else ETA_ARRIVED_TTL
    return now - item["updated"] > ttl


def eta_page(item, now, uz=False):
    """Страница для знакомого: время прибытия по Ташкенту, сколько осталось,
    когда обновлено. Без скриптов и внешних ресурсов; обновляется сама."""
    def clock(ts):
        return time.strftime("%H:%M", time.gmtime(ts + 5 * 3600))   # Узбекистан — UTC+5 круглый год
    if item is None:
        title = "Havola eskirgan" if uz else "Ссылка устарела"
        line = ("Safar tugagan yoki yangilanmayapti." if uz
                else "Поездка закончилась или больше не обновляется.")
        sub = ""
    elif item["status"] == "ended":
        title = "Kuzatish tugadi" if uz else "Поездка больше не отслеживается"
        line = ("Haydovchi ulashishni to‘xtatdi." if uz
                else "Водитель перестал делиться временем прибытия.")
        sub = ""
    elif item["status"] == "arrived":
        title = "Yetib keldi" if uz else "На месте"
        line = (f"{clock(item['updated'])} da yetib keldi" if uz
                else f"На месте с {clock(item['updated'])}")
        sub = ""
    else:
        minutes = max(0, round((item["eta"] - now) / 60))
        title = (f"Taxminan {clock(item['eta'])} da" if uz
                 else f"Будет примерно в {clock(item['eta'])}")
        line = (f"{minutes} daqiqadan keyin" if uz else f"через {minutes} мин")
        km = item["left_m"] / 1000
        if km >= 0.1:
            line += (f" · {km:.1f} km qoldi" if uz else f" · осталось {km:.1f} км".replace(".", ","))
        ago = max(0, round((now - item["updated"]) / 60))
        sub = (f"Yangilandi: {ago} daqiqa oldin" if uz else f"Обновлено {ago} мин назад")
    refresh = "" if item is None else '<meta http-equiv="refresh" content="30">'
    return f"""<!doctype html><html lang="{'uz' if uz else 'ru'}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">{refresh}<title>RadarMap</title>
<style>body{{margin:0;font:17px -apple-system,system-ui,sans-serif;background:#f4f6f9;color:#14181f;
display:flex;min-height:100vh;align-items:center;justify-content:center}}
main{{background:#fff;border-radius:20px;padding:28px 24px;max-width:360px;width:calc(100% - 32px);
box-shadow:0 6px 24px rgba(0,0,0,.08);text-align:center}}h1{{font-size:26px;margin:0 0 8px}}
p{{margin:4px 0;color:#4a5260}}small{{color:#8a929c}}
@media(prefers-color-scheme:dark){{body{{background:#14181f;color:#eef1f5}}main{{background:#1e232a}}p{{color:#b8c0cc}}}}
</style></head><body><main><h1>{title}</h1><p>{line}</p><p><small>{sub}</small></p>
<p><small>RadarMap</small></p></main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "RadarMapAPI/1.3"
    timeout = 10  # slow-POST не должен держать поток вечно

    def log_message(self, fmt, *args):
        pass  # keep journald quiet; errors surface via exceptions

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json_cached(self, body, etag):
        """Готовое тело с отпечатком: 304, если у телефона уже есть это самое.

        Заголовок Cache-Control обязателен и обязан быть no-cache, а не
        max-age: список отметок обязан перепроверяться каждый раз, просто
        дёшево. max-age отдал бы телефону право не спрашивать вовсе, и свежая
        тренога ждала бы истечения срока.
        """
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", etag)
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _ip(self):
        """IP клиента.

        Порядок важен и стоил бы нам всей защиты по IP. Верить можно только
        заголовку, который nginx ПЕРЕЗАПИСЫВАЕТ значением $remote_addr —
        клиентский он затирает. Живой конфиг ставит X-Real-IP, поэтому он и
        первый; X-Forwarded-For остаётся вторым для тестов и на случай другого
        фронта, а сокет — для запуска без прокси вовсе.

        Раньше первым (и единственным) читался X-Forwarded-For, которого живой
        nginx НЕ ставил, — то есть его значение приходило от клиента. Проверено
        на проде: запрос с «X-Forwarded-For: 8.8.8.8» проходил и списывался с
        чужого лимита. Так обходились все суточные капы и подделывался кворум
        «разных адресов», по которому скрывается отметка.
        """
        for header in ("X-Real-IP", "X-Forwarded-For"):
            value = self.headers.get(header, "").split(",")[0].strip()
            if value:
                return value
        return self.client_address[0]

    def _body(self, limit=4096):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > limit:
                return None
            return json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            return None

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")   # /api/mobile/?x — тот же эндпоинт
        if path.startswith("/api/eta/"):
            return self._eta_page(path[len("/api/eta/"):])
        if path == "/api/health":
            return self._json(200, {"ok": True})
        if path == "/api/mobile":
            return self._reports_list(road=False)
        if path == "/api/road":
            return self._reports_list(road=True)
        self._json(404, {"error": "not found"})

    def _reports_list(self, road):
        """Список живых отметок: /api/mobile — камеры и посты, /api/road —
        перекрытия и ремонт (с курсом отметившего). Мемо и ETag — у каждого
        списка свои, версия записей — общая."""
        global _last_cleanup, _mobile_cache, _road_cache
        now = time.time()
        # Свежее мемо той же версии — отдаём, не трогая базу вовсе.
        with _mobile_lock:
            cached = _road_cache if road else _mobile_cache
            version = _mobile_version
        if (cached and cached[0] == version
                and now - cached[1] < MOBILE_MEMO_SECONDS):
            return self._json_cached(cached[3], cached[2])
        conn = db()
        try:
            # Чистку не гоняем на каждый GET: это два DELETE и commit в
            # файле, куда параллельно пишет /api/report, — при 10 r/s с IP
            # чтение превращалось в постоянную запись. Раз в минуту хватает.
            with _cleanup_lock:
                due = now - _last_cleanup >= 60
                if due:
                    _last_cleanup = now
            if due:
                conn.execute("DELETE FROM reports WHERE expires < ?", (now - 86400,))
                # голоса удалённых отметок — сироты, без чистки таблица растёт вечно
                conn.execute("DELETE FROM votes WHERE report_id NOT IN (SELECT id FROM reports)")
                conn.commit()
                bump_mobile_version()
            # confirmed — по разным устройству И адресу (см.
            # confirmed_independently): клиент рисует неподтверждённые
            # полупрозрачными и говорит «возможно, радар», а не «радар».
            rows = conn.execute(
                "SELECT r.id, r.lat, r.lon, r.created, r.expires, r.up, r.down, r.type, "
                "EXISTS(SELECT 1 FROM votes v WHERE v.report_id = r.id AND v.value = 1 "
                "AND v.device != r.device AND v.ip != '' AND v.ip != r.ip), r.course "
                "FROM reports r WHERE r.active = 1 AND r.expires > ? "
                "AND (r.type IN (?, ?)) = ?",
                (now, ROAD_TYPES[0], ROAD_TYPES[1], 1 if road else 0)).fetchall()
        finally:
            conn.close()
        items = []
        for r in rows:
            item = {"id": r[0], "lat": r[1], "lon": r[2], "created": r[3],
                    "expires": r[4], "up": r[5], "down": r[6], "type": r[7],
                    "confirmed": bool(r[8])}
            if road:
                item["course"] = r[9] if r[9] is not None else -1
            items.append(item)
        body = json.dumps({"reports": items}).encode()
        # Отпечаток — по СОДЕРЖИМОМУ, а не по времени сборки: пока список
        # не меняется, ETag тот же, и телефон получает 304 хоть каждую
        # секунду. По времени он менялся бы на каждой пересборке, и весь
        # смысл 304 пропал бы.
        etag = '"%s"' % hashlib.sha1(body).hexdigest()[:32]
        with _mobile_lock:
            # Версию перечитываем: пока шёл SELECT, кто-то мог записать
            # отметку. Тогда наше тело уже старое — отдаём его этому
            # клиенту, но в мемо не кладём.
            if _mobile_version == version:
                if road:
                    _road_cache = (version, now, etag, body)
                else:
                    _mobile_cache = (version, now, etag, body)
        return self._json_cached(body, etag)

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/api/report":
            return self._report()
        if path == "/api/report/cancel":
            return self._report_cancel()
        if path == "/api/vote":
            return self._vote()
        if path == "/api/metrics":
            return self._metrics()
        if path == "/api/camera_report":
            return self._camera_report()
        if path == "/api/feedback":
            return self._feedback()
        if path == "/api/stat":
            return self._stat()
        if path == "/api/traffic":
            return self._traffic()
        if path == "/api/eta":
            return self._eta()
        self._json(404, {"error": "not found"})

    def _eta(self):
        now = time.time()
        cleaned = clean_eta(self._body(), now)
        if cleaned is None:
            return self._json(400, {"error": "bad json"})
        if ip_quota_exceeded("eta", self._ip(), ETA_UPDATES_PER_IP_DAY):
            return self._json(429, {"error": "too many"})
        token, item = cleaned
        if not eta_put(token, item, now):
            return self._json(503, {"error": "busy"})
        self._json(200, {"ok": True})

    def _eta_page(self, token):
        now = time.time()
        item = eta_get(token, now) if _ETA_TOKEN.match(token or "") else None
        uz = (self.headers.get("Accept-Language", "") or "").lower().startswith("uz")
        body = eta_page(item, now, uz=uz).encode()
        self.send_response(200 if item else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Robots-Tag", "noindex")
        self.end_headers()
        self.wfile.write(body)

    def _traffic(self):
        """Куски следа для пробок. Плохой кусок пропускается, а не роняет
        пачку: один глюк GPS не должен стоить водителю всей отправки."""
        data = self._body(limit=TRAFFIC_BODY_LIMIT)
        if not isinstance(data, dict) or data.get("v") != 1 or not isinstance(data.get("pieces"), list):
            return self._json(400, {"error": "bad json"})
        pieces = [p for p in (clean_traffic_piece(raw) for raw in data["pieces"][:TRAFFIC_MAX_PIECES]) if p]
        ip = self._ip()
        accepted = 0
        now = time.time()
        conn = traffic_db()
        try:
            conn.execute("DELETE FROM traffic_seen WHERE received < ?", (now - TRAFFIC_SEEN_TTL,))
            for piece in pieces:
                text = json.dumps(piece, separators=(",", ":"))
                digest = hashlib.sha256(text.encode()).hexdigest()
                # Повтор квоту адреса не тратит.
                if conn.execute("SELECT 1 FROM traffic_seen WHERE hash = ?", (digest,)).fetchone():
                    continue
                if ip_quota_exceeded("traffic", ip, TRAFFIC_PIECES_PER_IP_DAY):
                    break
                # INSERT OR IGNORE — и проверка, и отметка разом: два запроса
                # с одной пачкой не проскочат оба.
                if conn.execute("INSERT OR IGNORE INTO traffic_seen(hash, received) VALUES(?, ?)",
                                (digest, now)).rowcount == 0:
                    continue
                conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)", (now, text))
                accepted += 1
            conn.commit()
        finally:
            conn.close()
        self._json(200, {"ok": True, "accepted": accepted})

    def _stat(self):
        """Суточный агрегат использования. Координат тут нет и быть не может:
        всё, что принимается, — числа, версии и уровень разрешений."""
        data = self._body(limit=8192)
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            device = as_str(data["device"])[:64]
            day = as_str(data["day"])[:10]
            app = as_str(data.get("app"), default="")[:16]
            ios = as_str(data.get("ios"), default="")[:16]
            model = as_str(data.get("model"), default="")[:32]
            auth = as_str(data.get("location_auth"), default="")[:16]
            onboarded = 1 if data.get("onboarded") else 0
            trips = clamp_int(data.get("trips"))
            alerts = clamp_int(data.get("alerts"))
            passes = clamp_int(data.get("passes"))
            reports = clamp_int(data.get("reports"))
            km = float(data.get("km") or 0)
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not device or not DAY_RE.match(day):
            return self._json(400, {"error": "bad fields"})
        if auth not in ("", "always", "whenInUse", "denied", "restricted",
                        "notDetermined", "unknown"):
            return self._json(400, {"error": "bad fields"})
        # 20 000 км за сутки — это не поездка, а испорченное поле.
        if not 0 <= km <= 20000 or km != km:
            km = 0.0
        screens = data.get("screens")
        if not isinstance(screens, dict):
            screens = {}
        screens = {as_str(k)[:24]: clamp_int(v) for k, v in list(screens.items())[:20]}

        # Счётчики качества решений — та же дисциплина, что у screens: только
        # словари «короткая строка → число», ключи и размер обрезаются здесь, а
        # не на доверии к клиенту. Координате или времени тут не во что попасть:
        # значение проходит через clamp_int, то есть перестаёт быть чем угодно,
        # кроме счётчика.
        quality = {}
        for field in ("limitSource", "maneuvers", "tripsDropped", "alertRecall",
                      "memoryWarnings", "voiced", "carPlay"):
            value = data.get(field)
            if not isinstance(value, dict):
                continue
            cleaned = {as_str(k)[:24]: clamp_int(v) for k, v in list(value.items())[:20]}
            if cleaned:
                quality[field] = cleaned

        # Какие версии данных у телефона сейчас в памяти. Без этого сервер знает,
        # что он ОТДАЁТ, но не знает, что ДОШЛО: июльские лимиты, отданные
        # вместо сентябрьских, отсюда были бы видны в первый же день. Ключи —
        # закрытый список, значения — номера публикаций, одинаковые у всех
        # телефонов (номер базы, версия файла лимитов, отпечаток подписанного
        # индекса). О человеке они не говорят ничего.
        versions = data.get("dataVersions")
        if isinstance(versions, dict):
            cleaned = {key: clamp_int(versions.get(key), limit=2 ** 31)
                       for key in DATA_VERSION_KEYS if key in versions}
            if cleaned:
                quality["dataVersions"] = cleaned

        if ip_quota_exceeded("stat", self._ip(), IP_DAILY_CAPS["stat"]):
            return self._json(429, {"error": "too many"})

        now = time.time()
        conn = db()
        try:
            total = conn.execute("SELECT COUNT(*) FROM usage_stats").fetchone()[0]
            if total >= MAX_USAGE_ROWS:
                # Ротация device не должна заливать диск. Чистим старое и только
                # потом отказываем: иначе таблица однажды закрывается навсегда.
                conn.execute("DELETE FROM usage_stats WHERE received < ?", (now - 90 * 86400,))
                if conn.execute("SELECT COUNT(*) FROM usage_stats").fetchone()[0] >= MAX_USAGE_ROWS:
                    conn.commit()
                    return self._json(429, {"error": "too many"})
            conn.execute(
                "INSERT OR REPLACE INTO usage_stats(device, day, app, ios, model, "
                "location_auth, onboarded, trips, km, alerts, passes, reports, "
                "screens, quality, received) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (device, day, app, ios, model, auth, onboarded, trips, km,
                 alerts, passes, reports, json.dumps(screens),
                 json.dumps(quality), now))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _metrics(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > DIAGNOSTIC_MAX_BYTES + 65536:
                sys.stderr.write(f"metrics: отказ по длине тела {length}\n")
                return self._json(400, {"error": "bad length"})
            data = json.loads(self.rfile.read(length))
            device = as_str(data["device"])[:64]
            kind = as_str(data["kind"])[:16]
            payload = json.dumps(data["payload"])
            limit = DIAGNOSTIC_MAX_BYTES if kind == "diagnostic" else METRIC_MAX_BYTES
            if len(payload) > limit:  # срез сделал бы JSON невалидным — отказываем целиком
                sys.stderr.write(f"metrics: {kind} {len(payload)} байт > {limit} — отказ\n")
                return self._json(400, {"error": "payload too big"})
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad json"})
        if not device or kind not in ("metric", "diagnostic"):
            return self._json(400, {"error": "bad fields"})
        if ip_quota_exceeded("metrics", self._ip(), IP_DAILY_CAPS["metrics"]):
            return self._json(429, {"error": "too many"})
        now = time.time()
        conn = db()
        try:
            count = conn.execute(
                "SELECT COUNT(*) FROM metrics WHERE device = ? AND received > ?",
                (device, now - 86400)).fetchone()[0]
            if count >= 20:
                return self._json(429, {"error": "too many"})
            conn.execute("DELETE FROM metrics WHERE received < ?", (now - 30 * 86400,))
            total = conn.execute("SELECT COUNT(*) FROM metrics").fetchone()[0]
            if total >= MAX_METRICS_ROWS:  # ротация device не должна заливать диск
                return self._json(429, {"error": "too many"})
            conn.execute("INSERT INTO metrics(device, kind, received, payload) VALUES(?,?,?,?)",
                         (device, kind, now, payload))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _camera_report(self):
        """Репорт по базе камер: «больше нет» / «неверное место» / «на месте»
        (still_here — краудсорс-подтверждение, гасит ложные gone-репорты).
        Разбирается вручную (см. запросы модерации в шапке файла)."""
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            camera_id = int(data["camera_id"])
            reason = as_str(data["reason"])[:32]
            device = as_str(data["device"])[:64]
            lat = float(data.get("lat") or 0) or None
            lon = float(data.get("lon") or 0) or None
            db_version = int(data.get("db_version") or 0) or None
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if reason not in ("gone", "wrong_location", "still_here") or not device \
                or not 0 < camera_id < MAX_ID:
            return self._json(400, {"error": "bad fields"})
        # Версия базы — наша, маленькая. Всё прочее (включая 10**100, который
        # раньше ронял хендлер OverflowError'ом на INSERT) — мусор, не повод 500.
        if db_version is not None and not 0 < db_version < MAX_ID:
            return self._json(400, {"error": "bad fields"})
        # Координаты — только правдоподобные: NaN/Infinity проходят float(),
        # но проваливают сравнение с границами и превращаются в NULL.
        if lat is not None and not (UZ_LAT[0] <= lat <= UZ_LAT[1]):
            lat = None
        if lon is not None and not (UZ_LON[0] <= lon <= UZ_LON[1]):
            lon = None
        ip = self._ip()
        if ip_quota_exceeded("camera_report", ip, IP_DAILY_CAPS["camera_report"]):
            return self._json(429, {"error": "too many"})

        now = time.time()
        conn = db()
        try:
            count = conn.execute(
                "SELECT COUNT(*) FROM camera_reports WHERE device = ? AND received > ?",
                (device, now - 86400)).fetchone()[0]
            if count >= 20:
                return self._json(429, {"error": "too many"})
            daily = conn.execute(
                "SELECT COUNT(*) FROM camera_reports WHERE received > ?",
                (now - 86400,)).fetchone()[0]
            if daily >= MAX_DAILY_ROWS:  # глобальный кап против ротации device
                return self._json(429, {"error": "too many"})
            # Повтор того же репорта с того же устройства не плодим — сигнал
            # считаем по числу РАЗНЫХ устройств на камеру.
            dup = conn.execute(
                "SELECT id FROM camera_reports WHERE device = ? AND camera_id = ? "
                "AND reason = ? AND received > ?",
                (device, camera_id, reason, now - 7 * 86400)).fetchone()
            if dup:
                return self._json(200, {"ok": True, "duplicate": True})
            conn.execute(
                "INSERT INTO camera_reports(camera_id, reason, lat, lon, db_version, "
                "device, received, ip) VALUES(?,?,?,?,?,?,?,?)",
                (camera_id, reason, lat, lon, db_version, device, now, ip))
            conn.commit()
        finally:
            conn.close()
        # Жалоба на камеру — вторая вещь, о которой владелец обязан узнать
        # быстро: «камеры нет» и «стоит не там» ведут к молчанию там, где
        # камера стоит, либо к предупреждению там, где её нет.
        notify.camera_report(camera_id, reason)
        return self._json(200, {"ok": True})

    def _feedback(self):
        """Сообщение разработчику из формы в настройках."""
        data = self._body(limit=16384)
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            message = clean_text(as_str(data["message"]).strip()[:2000])
            contact = clean_text(as_str(data.get("contact"), default="")[:200])
            # app_version печатается в терминале модератора рядом с message —
            # ANSI-мусор вырезаем и здесь.
            app_version = clean_text(as_str(data.get("app_version"), default="")[:32])
            device = as_str(data["device"])[:64]
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not message or not device:
            return self._json(400, {"error": "bad fields"})
        if ip_quota_exceeded("feedback", self._ip(), IP_DAILY_CAPS["feedback"]):
            return self._json(429, {"error": "too many"})

        now = time.time()
        conn = db()
        try:
            count = conn.execute(
                "SELECT COUNT(*) FROM feedback WHERE device = ? AND received > ?",
                (device, now - 86400)).fetchone()[0]
            if count >= 10:
                return self._json(429, {"error": "too many"})
            daily = conn.execute(
                "SELECT COUNT(*) FROM feedback WHERE received > ?",
                (now - 86400,)).fetchone()[0]
            if daily >= MAX_DAILY_ROWS:  # глобальный кап против ротации device
                return self._json(429, {"error": "too many"})
            cur = conn.execute(
                "INSERT INTO feedback(message, contact, app_version, device, received) "
                "VALUES(?,?,?,?,?)",
                (message, contact, app_version, device, now))
            conn.commit()
            row_id = cur.lastrowid
        finally:
            conn.close()
        # В бот — ПОСЛЕ коммита и в фоне. Письмо уже сохранено, бот лишь способ
        # узнать о нём быстрее; лежащий telegram не имеет права превратиться в
        # таймаут у человека, который и так чем-то недоволен.
        notify.feedback(message, contact, app_version,
                        admin_url=f"{ADMIN_URL}/feedback#f{row_id}" if ADMIN_URL else None)
        return self._json(200, {"ok": True})

    def _report(self):
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            lat, lon = float(data["lat"]), float(data["lon"])
            device = as_str(data["device"])[:64]
            rtype = as_str(data.get("type"), default="radar")
            cls = as_str(data.get("cls"), default="")[:24]
            course = float(data.get("course", -1))
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not (UZ_LAT[0] <= lat <= UZ_LAT[1] and UZ_LON[0] <= lon <= UZ_LON[1]) or not device:
            return self._json(400, {"error": "out of bounds"})
        if rtype not in REPORT_TTLS:
            return self._json(400, {"error": "bad type"})
        # Курс отметившего — сторона дороги для перекрытия; мусор — «неизвестно».
        if not (0 <= course < 360) or math.isnan(course):
            course = -1.0
        try:
            amend_id = int(data.get("amend_id") or 0)
        except (TypeError, ValueError):
            amend_id = 0
        ip = self._ip()
        if ip_quota_exceeded("report", ip, IP_DAILY_CAPS["report"]):
            return self._json(429, {"error": "too many"})

        now = time.time()
        conn = db()
        try:
            # Уточнение типа СВОЕЙ свежей отметки. «Радар!» уходит сразу, тип
            # человек выбирает следующим тапом — раньше второй тап с другим
            # типом рождал ВТОРУЮ точку рядом. Проверка стоит ДО лимитов:
            # amend не создаёт новых точек, и глушить его капом «минимум 120 с
            # между отметками» значило бы сломать само уточнение.
            #
            # Граница камера/дорога (12б.5): неявное уточнение — только внутри
            # своей категории. Иначе «Ремонт», поставленный рукой в 300 м от
            # своего свежего «Радар!», переписывал ЖИВОЙ радар в ремонт — и
            # радар пропадал у всех, старых сборок тоже. Через границу — только
            # явно: «Что это было? → Перекрыто» присылает amend_id той точки.
            own = conn.execute(
                "SELECT id, lat, lon, type, created FROM reports "
                "WHERE device = ? AND active = 1 AND expires > ? AND created > ?",
                (device, now, now - AMEND_WINDOW)).fetchall()
            for r in own:
                if r[3] == rtype or haversine(lat, lon, r[1], r[2]) > AMEND_METERS:
                    continue
                crossing = is_road(r[3]) != is_road(rtype)
                if crossing and r[0] != amend_id:
                    continue
                if crossing:
                    # Кап своих активных точек — категории, куда переводим:
                    # иначе «три радара → в ремонт → ещё три радара» обходил его.
                    target = conn.execute(
                        "SELECT COUNT(*) FROM reports WHERE device = ? AND active = 1 "
                        "AND expires > ? AND (type IN (?, ?)) = ?",
                        (device, now, ROAD_TYPES[0], ROAD_TYPES[1],
                         1 if is_road(rtype) else 0)).fetchone()[0]
                    if target >= 3:
                        return self._json(429, {"error": "too many active reports"})
                    # Через границу срок — по НОВОМУ типу, от создания: иначе
                    # перекрытие жило бы сроком радара (75 мин вместо 3 ч), а
                    # радар из перекрытия — сроком перекрытия. Как у новой
                    # точки — испытательный, без подтверждения не продлевается.
                    ttl = road_new_ttl(conn, rtype, now)
                    conn.execute("UPDATE reports SET type = ?, expires = ? WHERE id = ?",
                                 (rtype, max(now + 60, r[4] + ttl), r[0]))
                else:
                    # Срок не трогаем: уточнение типа — не подтверждение, иначе
                    # amend был бы бесплатным продлением собственной отметки.
                    conn.execute("UPDATE reports SET type = ? WHERE id = ?",
                                 (rtype, r[0]))
                conn.commit()
                bump_mobile_version()
                # merged=True — для старых клиентов, знающих только это поле.
                return self._json(200, {"id": r[0], "merged": True,
                                        "amended": True})

            # rate limits per device
            road = rtype in ROAD_TYPES
            recent = conn.execute(
                "SELECT COUNT(*), MAX(created) FROM reports WHERE device = ? AND active = 1 "
                "AND expires > ? AND (type IN (?, ?)) = ?",
                (device, now, ROAD_TYPES[0], ROAD_TYPES[1], 1 if road else 0)).fetchone()
            if recent[0] >= 3:
                return self._json(429, {"error": "too many active reports"})
            if recent[1] and now - recent[1] < 120:
                return self._json(429, {"error": "too fast"})

            # dedupe: nearby active report of the SAME type -> treat as confirmation
            # (пост ДПС и радар в 100 м друг от друга — разные сущности)
            active_rows = conn.execute(
                "SELECT id, lat, lon, created, expires, type, device, ip, cls FROM reports "
                "WHERE active = 1 AND expires > ?", (now,)).fetchall()
            # Радиус берём максимальный из двух классов: если хоть одна из
            # точек стоит на трассе, «рядом» здесь измеряется по-трассовому.
            for r in active_rows:
                radius = max(merge_radius(cls), merge_radius(r[8]))
                if r[5] == rtype and haversine(lat, lon, r[1], r[2]) <= radius:
                    # Подтверждение — через votes, как обычный лайк: _vote
                    # пересчитывает up/down только из votes, инкремент в
                    # reports первый же голос стёр бы.
                    conn.execute(
                        "INSERT OR REPLACE INTO votes(report_id, device, value, ts, ip, kind) "
                        "VALUES(?,?,1,?,?,'merge')",
                        (r[0], device, now, ip))
                    up = conn.execute(
                        "SELECT COUNT(*) FROM votes WHERE report_id = ? AND value = 1",
                        (r[0],)).fetchone()[0]
                    # Продление — привилегия НЕЗАВИСИМОГО подтверждения: merge
                    # с того же адреса (свой второй UUID, пассажир на том же
                    # Wi-Fi) засчитывается голосом, но испытательный срок не
                    # снимает — иначе фейк продлевал бы сам себя ротацией.
                    confirmed = confirmed_independently(conn, r[0], r[6], r[7])
                    new_exp = lifecycle_expires(r[3], r[4], rtype, confirmed, now)
                    conn.execute("UPDATE reports SET up = ?, expires = ? WHERE id = ?",
                                 (up, new_exp, r[0]))
                    conn.commit()
                    bump_mobile_version()
                    return self._json(200, {"id": r[0], "merged": True})

            # Глобальный кап: ротация device не должна ни заваливать карту
            # фейками, ни раздувать O(N)-скан дедупликации выше. По категории:
            # недельный ремонт не съедает место радаров.
            same_category = [r for r in active_rows if is_road(r[5]) == road]
            if len(same_category) >= (MAX_ACTIVE_ROAD if road else MAX_ACTIVE_REPORTS):
                return self._json(429, {"error": "too many active"})
            # Пер-IP кап активных точек: суточный кап не мешал одному адресу
            # держать на карте десяток живых фейков одновременно.
            if ip:
                mine = conn.execute(
                    "SELECT COUNT(*) FROM reports WHERE ip = ? AND active = 1 AND expires > ? "
                    "AND (type IN (?, ?)) = ?",
                    (ip, now, ROAD_TYPES[0], ROAD_TYPES[1], 1 if road else 0)).fetchone()[0]
                if mine >= (MAX_ACTIVE_ROAD_PER_IP if road else MAX_ACTIVE_PER_IP):
                    return self._json(429, {"error": "too many active"})
            # Теневой бан: строка ложится в базу мёртвой. Ответ обычный —
            # заблокированный не должен узнать, что он заблокирован, иначе
            # начнёт подбирать обход вместо того, чтобы бросить.
            blocked = is_blocked(conn, ip, device, now)
            # Новая отметка живёт испытательный срок, полный получит после
            # независимого подтверждения (см. lifecycle_expires).
            # Срок жизни новой точки: испытательный, только пока в стране
            # есть кому подтверждать (см. probation_active).
            ttl = road_new_ttl(conn, rtype, now)
            # Отметка из очереди телефона (не было связи): срок — от момента,
            # когда её поставили, а не от приёма — иначе тренога, отмеченная
            # сорок минут назад, жила бы полный срок с этой минуты (S25).
            observed = now - report_age(data)
            cur = conn.execute(
                "INSERT INTO reports(lat, lon, created, expires, device, type, ip, cls, "
                "active, closed, course) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (lat, lon, now, max(now + 60, observed + ttl), device, rtype, ip, cls,
                 0 if blocked else 1, "blocked" if blocked else "", course))
            conn.commit()
            bump_mobile_version()
            return self._json(200, {"id": cur.lastrowid, "merged": False})
        finally:
            conn.close()

    def _report_cancel(self):
        """Отзыв своей случайной отметки.

        Право автора кончается там, где начинается чужое доверие: как только
        отметку подтвердил кто-то ещё, она больше не его — она общая, и снять
        её можно только кворумом или модератором. Плюс окно в десять минут:
        это исправление промаха пальцем, а не пульт управления точкой, мимо
        которой уже едут люди.
        """
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            rid = int(data["id"])
            device = as_str(data["device"])[:64]
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not device or not 0 < rid < MAX_ID:
            return self._json(400, {"error": "bad fields"})
        now = time.time()
        conn = db()
        try:
            row = conn.execute(
                "SELECT device, created, active FROM reports WHERE id = ?", (rid,)).fetchone()
            if not row:
                return self._json(404, {"error": "no such report"})
            if row[0] != device:
                return self._json(403, {"error": "not yours"})
            if not row[2]:
                # Уже не на карте — считаем задачу выполненной, чтобы клиент
                # не показывал ошибку там, где результат ровно тот, что нужен.
                return self._json(200, {"ok": True, "already": True})
            if now - row[1] > CANCEL_WINDOW:
                return self._json(409, {"error": "too late"})
            others = conn.execute(
                "SELECT COUNT(*) FROM votes WHERE report_id = ? AND value = 1 AND device != ?",
                (rid, device)).fetchone()[0]
            if others:
                return self._json(409, {"error": "confirmed by others"})
            conn.execute("UPDATE reports SET active = 0, closed = 'author' WHERE id = ?", (rid,))
            conn.commit()
            bump_mobile_version()
            return self._json(200, {"ok": True})
        finally:
            conn.close()

    def _vote(self):
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            rid = int(data["id"])
            device = as_str(data["device"])[:64]
            value = int(data["value"])
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if value not in (1, -1) or not device or not 0 < rid < MAX_ID:
            return self._json(400, {"error": "bad value"})
        ip = self._ip()
        if ip_quota_exceeded("vote", ip, IP_DAILY_CAPS["vote"]):
            return self._json(429, {"error": "too many"})

        now = time.time()
        conn = db()
        try:
            voted = conn.execute(
                "SELECT COUNT(*) FROM votes WHERE device = ? AND ts > ?",
                (device, now - 86400)).fetchone()[0]
            if voted >= MAX_VOTES_PER_DAY:
                return self._json(429, {"error": "too many"})
            row = conn.execute(
                "SELECT created, expires, device, ip, type FROM reports "
                "WHERE id = ? AND active = 1", (rid,)).fetchone()
            if not row:
                return self._json(404, {"error": "no report"})
            created, expires, owner_device, owner_ip, rtype = row
            # kind="pass" — голос после реального проезда (MobilePassWatch).
            # Вес не меняет (проезд сервер проверить не может), но модератор
            # видит, какому сигналу верить. Мусор в поле не убивает сам голос.
            try:
                # "pass" — голос после реального проезда, "merge" — повторная
                # отметка тем же местом, "misplaced" — «радар есть, но стоит
                # не там». Последний намеренно считается обычным дизлайком по
                # сроку жизни: точка в двухстах метрах от истины всё равно
                # предупреждает о засаде, гасить её мгновенно нельзя. Но
                # модератор видит именно этот сигнал и может подвинуть.
                kind = as_str(data.get("kind"), default="")[:16]
            except TypeError:
                kind = ""
            prior = conn.execute(
                "SELECT value FROM votes WHERE report_id = ? AND device = ?",
                (rid, device)).fetchone()
            conn.execute("INSERT OR REPLACE INTO votes(report_id, device, value, ts, ip, kind) "
                         "VALUES(?,?,?,?,?,?)",
                         (rid, device, value, now, ip, kind))
            up, down = conn.execute(
                "SELECT COALESCE(SUM(value = 1), 0), COALESCE(SUM(value = -1), 0) "
                "FROM votes WHERE report_id = ?", (rid,)).fetchone()
            if value == 1:
                # Продление и полный срок — только за независимое подтверждение
                # (другое устройство И другой адрес): см. lifecycle_expires.
                confirmed = confirmed_independently(conn, rid, owner_device, owner_ip)
                expires = lifecycle_expires(created, expires, rtype, confirmed, now)
            elif ip and (prior is None or prior[0] != -1):
                # Первый дизлайк с НОВОГО адреса срезает жизнь: два честных
                # «Нет» после проезда снимают пустышку задолго до кворума.
                # Повтор с того же устройства или адреса не режет второй раз.
                seen = conn.execute(
                    "SELECT COUNT(*) FROM votes WHERE report_id = ? AND value = -1 "
                    "AND ip = ? AND device != ?", (rid, ip, device)).fetchone()[0]
                if seen == 0:
                    expires = max(now + DOWN_FLOOR, expires - DOWN_PENALTY)
            # Скрытие — по числу РАЗНЫХ адресов среди дизлайков: device
            # ротируется бесплатно, и три свежих UUID с одного телефона гасили
            # любую отметку. Старые голоса (ip = '') в кворум не входят —
            # лучше передержать отметку, чем дать её снять анонимной ротацией.
            down_ips = conn.execute(
                "SELECT COUNT(DISTINCT ip) FROM votes "
                "WHERE report_id = ? AND value = -1 AND ip != ''", (rid,)).fetchone()[0]
            active = 0 if (down >= 3 and down > up and down_ips >= HIDE_DISTINCT_IPS) else 1
            conn.execute("UPDATE reports SET up = ?, down = ?, expires = ?, active = ?, "
                         "closed = CASE WHEN ? = 0 THEN 'quorum' ELSE closed END WHERE id = ?",
                         (up, down, expires, active, active, rid))
            conn.commit()
            bump_mobile_version()
            return self._json(200, {"ok": True, "up": up, "down": down, "active": bool(active)})
        finally:
            conn.close()

class BoundedHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer с потолком одновременных обработчиков.

    Базовый класс плодит поток на каждое соединение без предела: сотня
    медленных POST'ов — сотня потоков, висящих до таймаута в 10 с. Капы в
    хендлерах от этого не спасают, они срабатывают уже внутри обработчика.
    Сверх потолка отвечаем 503 и закрываем: отказ, который клиент увидит и
    повторит позже, лучше очереди, которую никто не разгребёт.
    """
    daemon_threads = True

    def __init__(self, *args, max_workers=MAX_WORKERS, **kwargs):
        self._slots = threading.BoundedSemaphore(max_workers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                                b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass  # клиент уже отвалился — отвечать некому
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            # поток не стартовал (например, кончились потоки ОС) — слот вернуть,
            # иначе сервер медленно «зарастает» и перестаёт принимать вообще
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


if __name__ == "__main__":
    init_db()
    init_traffic_db()
    BoundedHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
