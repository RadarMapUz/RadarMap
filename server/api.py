#!/usr/bin/env python3
"""RadarMap API: краудсорсинг передвижных радаров, метрики, обратная связь.

Stdlib-only (sqlite3 + http.server): без pip-зависимостей на общем VPS.
Слушает 127.0.0.1:8091, наружу отдаётся nginx'ом на :8090/api/.

Endpoints:
  GET  /api/health         -> {"ok": true}
  GET  /api/mobile         -> {"reports": [{id, lat, lon, created, expires, up, down,
                                            type, confirmed}]}
  POST /api/report         {lat, lon, device, type}  -> {"id": N, "merged": bool
                                                         [, "amended": true]}
  POST /api/vote           {id, device, value: 1|-1 [, kind: "pass"]} -> {"ok": true}
  POST /api/metrics        {device, kind, payload}   -> {"ok": true}   (MetricKit)
  POST /api/camera_report  {camera_id, reason, lat, lon, db_version, device} -> {"ok": true}
  POST /api/feedback       {message, contact, app_version, device}     -> {"ok": true}
  POST /api/stat           {device, day, app, ios, model, location_auth, onboarded,
                            trips, km, alerts, passes, reports, screens} -> {"ok": true}
                           (обезличенный суточный агрегат: ни координат, ни времени событий)

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
import json
import math
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_PATH = "/opt/radarmap/api/reports.db"
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
REPORT_TTLS = {"radar": TTL, "tripod": TTL, "post": 6 * 3600, "accident": 3600}
# Испытательный срок новой отметки. Ставить фейки должно быть бессмысленно:
# точка, которую не подтвердил ни один независимый водитель, умирает сама —
# ни модерации, ни кворума не нужно. Цена: одинокая честная тренога на пустой
# дороге живёт 75 мин вместо трёх часов — но там её и видят единицы.
PROBATION_TTLS = {"radar": 75 * 60, "tripod": 75 * 60, "post": 2 * 3600,
                  "accident": 3600}
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
UZ_LAT = (37.0, 46.0)
UZ_LON = (55.0, 74.0)
# Глобальные капы — потолок ущерба от ротации device (лимиты per-device
# обходятся новым UUID на каждый запрос). Честные объёмы в разы ниже.
MAX_ACTIVE_REPORTS = 500     # активных отметок всего (и потолок O(N)-скана дедупликации)
MAX_METRICS_ROWS = 5000      # строк метрик в БД (по ~200 КБ — потолок диска)
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
    migrate(conn, "reports", "type TEXT DEFAULT 'radar'")     # radar/tripod/post/accident
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

    # --- индексы ---
    # Раньше не было ни одного: каждая проверка суточного капа была полным
    # сканом таблицы, а горячий GET /api/mobile сканировал все отметки.
    for statement in (
        "CREATE INDEX IF NOT EXISTS idx_reports_live ON reports(active, expires)",
        "CREATE INDEX IF NOT EXISTS idx_reports_device ON reports(device, active, expires)",
        "CREATE INDEX IF NOT EXISTS idx_reports_ip ON reports(ip, active, expires)",
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


def lifecycle_expires(created, expires, rtype, confirmed, now):
    """Новый expires после лайка. Неподтверждённой точке лайк жизнь НЕ
    продлевает (испытательный срок идёт), подтверждённой — полный срок её типа
    плюс 30 мин за голос, но не дальше MAX_LIFE от создания."""
    if not confirmed:
        return expires
    new_exp = max(max(expires, now) + EXTEND,
                  created + REPORT_TTLS.get(rtype, TTL))
    return min(created + MAX_LIFE, new_exp)

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
        if path == "/api/health":
            return self._json(200, {"ok": True})
        if path == "/api/mobile":
            now = time.time()
            conn = db()
            try:
                # Чистку не гоняем на каждый GET: это два DELETE и commit в
                # файле, куда параллельно пишет /api/report, — при 10 r/s с IP
                # чтение превращалось в постоянную запись. Раз в минуту хватает.
                global _last_cleanup
                with _cleanup_lock:
                    due = now - _last_cleanup >= 60
                    if due:
                        _last_cleanup = now
                if due:
                    conn.execute("DELETE FROM reports WHERE expires < ?", (now - 86400,))
                    # голоса удалённых отметок — сироты, без чистки таблица растёт вечно
                    conn.execute("DELETE FROM votes WHERE report_id NOT IN (SELECT id FROM reports)")
                    conn.commit()
                # confirmed — по разным устройству И адресу (см.
                # confirmed_independently): клиент рисует неподтверждённые
                # полупрозрачными и говорит «возможно, радар», а не «радар».
                rows = conn.execute(
                    "SELECT r.id, r.lat, r.lon, r.created, r.expires, r.up, r.down, r.type, "
                    "EXISTS(SELECT 1 FROM votes v WHERE v.report_id = r.id AND v.value = 1 "
                    "AND v.device != r.device AND v.ip != '' AND v.ip != r.ip) "
                    "FROM reports r WHERE r.active = 1 AND r.expires > ?", (now,)).fetchall()
            finally:
                conn.close()
            return self._json(200, {"reports": [
                {"id": r[0], "lat": r[1], "lon": r[2], "created": r[3],
                 "expires": r[4], "up": r[5], "down": r[6], "type": r[7],
                 "confirmed": bool(r[8])} for r in rows]})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/api/report":
            return self._report()
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
        self._json(404, {"error": "not found"})

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
                "screens, received) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (device, day, app, ios, model, auth, onboarded, trips, km,
                 alerts, passes, reports, json.dumps(screens), now))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _metrics(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > 262144:
                return self._json(400, {"error": "bad length"})
            data = json.loads(self.rfile.read(length))
            device = as_str(data["device"])[:64]
            kind = as_str(data["kind"])[:16]
            payload = json.dumps(data["payload"])
            if len(payload) > 200000:  # срез сделал бы JSON невалидным — отказываем целиком
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
            conn.execute(
                "INSERT INTO feedback(message, contact, app_version, device, received) "
                "VALUES(?,?,?,?,?)",
                (message, contact, app_version, device, now))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _report(self):
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            lat, lon = float(data["lat"]), float(data["lon"])
            device = as_str(data["device"])[:64]
            rtype = as_str(data.get("type"), default="radar")
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not (UZ_LAT[0] <= lat <= UZ_LAT[1] and UZ_LON[0] <= lon <= UZ_LON[1]) or not device:
            return self._json(400, {"error": "out of bounds"})
        if rtype not in REPORT_TTLS:
            return self._json(400, {"error": "bad type"})
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
            own = conn.execute(
                "SELECT id, lat, lon, type FROM reports "
                "WHERE device = ? AND active = 1 AND expires > ? AND created > ?",
                (device, now, now - AMEND_WINDOW)).fetchall()
            for r in own:
                if r[3] != rtype and haversine(lat, lon, r[1], r[2]) <= AMEND_METERS:
                    # Срок не трогаем: уточнение типа — не подтверждение, иначе
                    # amend был бы бесплатным продлением собственной отметки.
                    conn.execute("UPDATE reports SET type = ? WHERE id = ?",
                                 (rtype, r[0]))
                    conn.commit()
                    # merged=True — для старых клиентов, знающих только это поле.
                    return self._json(200, {"id": r[0], "merged": True,
                                            "amended": True})

            # rate limits per device
            recent = conn.execute(
                "SELECT COUNT(*), MAX(created) FROM reports WHERE device = ? AND active = 1 AND expires > ?",
                (device, now)).fetchone()
            if recent[0] >= 3:
                return self._json(429, {"error": "too many active reports"})
            if recent[1] and now - recent[1] < 120:
                return self._json(429, {"error": "too fast"})

            # dedupe: nearby active report of the SAME type -> treat as confirmation
            # (пост ДПС и радар в 100 м друг от друга — разные сущности)
            active_rows = conn.execute(
                "SELECT id, lat, lon, created, expires, type, device, ip FROM reports "
                "WHERE active = 1 AND expires > ?", (now,)).fetchall()
            for r in active_rows:
                if r[5] == rtype and haversine(lat, lon, r[1], r[2]) <= MERGE_METERS:
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
                    return self._json(200, {"id": r[0], "merged": True})

            # Глобальный кап: ротация device не должна ни заваливать карту
            # фейками, ни раздувать O(N)-скан дедупликации выше.
            if len(active_rows) >= MAX_ACTIVE_REPORTS:
                return self._json(429, {"error": "too many active"})
            # Пер-IP кап активных точек: суточный кап не мешал одному адресу
            # держать на карте десяток живых фейков одновременно.
            if ip:
                mine = conn.execute(
                    "SELECT COUNT(*) FROM reports WHERE ip = ? AND active = 1 AND expires > ?",
                    (ip, now)).fetchone()[0]
                if mine >= MAX_ACTIVE_PER_IP:
                    return self._json(429, {"error": "too many active"})
            # Новая отметка живёт испытательный срок, полный получит после
            # независимого подтверждения (см. lifecycle_expires).
            cur = conn.execute(
                "INSERT INTO reports(lat, lon, created, expires, device, type, ip) "
                "VALUES(?,?,?,?,?,?,?)",
                (lat, lon, now, now + PROBATION_TTLS[rtype], device, rtype, ip))
            conn.commit()
            return self._json(200, {"id": cur.lastrowid, "merged": False})
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
            conn.execute("UPDATE reports SET up = ?, down = ?, expires = ?, active = ? WHERE id = ?",
                         (up, down, expires, active, rid))
            conn.commit()
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
    BoundedHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
