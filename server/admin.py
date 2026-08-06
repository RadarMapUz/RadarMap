#!/usr/bin/env python3
"""RadarMap: панель модератора.

Замыкает контур, который до неё был разомкнут: репорты водителей о камерах
приходили в sqlite и умирали там — колонку camera_reports.resolved никто
никогда не писал, а единственным способом модерации был SELECT в ssh-сессии.

Stdlib-only (sqlite3 + http.server), слушает 127.0.0.1:8092, наружу отдаётся
nginx'ом на /admin/ с basic auth. Отдельный процесс от api.py намеренно:
падение или перезапуск панели не должны ронять приём репортов от водителей,
а публичный api и приватная панель не должны делить адресное пространство.

Интерфейс — серверный HTML и обычные формы, без JS-фреймворков: модерируют
чаще всего с телефона между делом, и страница, которая грузится за 200 мс и
работает без сборки, здесь единственно верный выбор.

ВАЖНО: панель ничего не публикует сама. Ключ подписи живёт только на машине
владельца, поэтому решения копятся в таблице overrides, а публикует их одна
локальная команда — server/publish_overrides.sh. Взломанный VPS не может
ни скрыть камеру у пользователей, ни подсунуть свою.

Запуск:
    python3 admin.py                      # сервер на 127.0.0.1:8092
    python3 admin.py --export             # JSON действующих правок (для публикации)
    python3 admin.py --mark-published 12  # пометить правки опубликованными в версии 12
"""
import html
import json
import os
import sqlite3
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("RADARMAP_DB", "/opt/radarmap/api/reports.db")
CAMERAS_PATH = os.environ.get("RADARMAP_CAMERAS", "/opt/radarmap/www/cameras.json")
PORT = int(os.environ.get("RADARMAP_ADMIN_PORT", "8092"))
DAY = 86400

# --- Порог, при котором панель ПРЕДЛАГАЕТ скрыть камеру ---------------------
# Только предлагает: снимает камеру человек, вторым подтверждающим кликом.
# Автоматизировать это нельзя. Скрытая камера производит молчание там, где
# камера стоит, — худший отказ всей системы, и цена ошибки здесь несимметрична:
# лишняя камера на карте стоит одного лишнего предупреждения, снятая живая —
# штрафа и потерянного доверия ко всему приложению.
SUGGEST_MIN_IPS = 3        # репорты «нет» минимум с трёх РАЗНЫХ адресов
SUGGEST_QUIET_DAYS = 14    # и ни одного «на месте» за две недели
SUGGEST_MIN_AGE_DAYS = 7   # и самому старому репорту хотя бы неделя:
                           # ремонт дороги и чехол на камере проходят быстрее
SNOOZE_DAYS = 30           # «отложить» — вернуть в очередь через месяц

RESOLVED_NEW, RESOLVED_DONE, RESOLVED_REJECTED = 0, 1, 2


# --------------------------------------------------------------------------
# База
# --------------------------------------------------------------------------

def db():
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    """Таблицы, которыми владеет панель. Всё остальное создаёт api.py —
    он же и пишет туда; панель только читает и проставляет статусы."""
    conn = db()
    conn.execute("""CREATE TABLE IF NOT EXISTS overrides(
        camera_id INTEGER PRIMARY KEY,
        op TEXT NOT NULL,                 -- hide | move | retype
        lat REAL, lon REAL, type TEXT,
        note TEXT DEFAULT '',
        decided_at REAL NOT NULL,
        -- NULL = решение принято, но ещё не опубликовано (ключ подписи не здесь)
        published_at REAL)""")
    # Журнал решений. Модератор один, но «когда и почему мы сняли эту камеру»
    # через полгода не вспомнит никто, а вопрос обязательно возникнет.
    conn.execute("""CREATE TABLE IF NOT EXISTS moderation_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at REAL NOT NULL, camera_id INTEGER,
        action TEXT NOT NULL, detail TEXT DEFAULT '')""")
    try:
        conn.execute("ALTER TABLE camera_reports ADD COLUMN snooze_until REAL DEFAULT 0")
    except sqlite3.OperationalError:
        pass  # колонка уже есть
    conn.execute("CREATE INDEX IF NOT EXISTS idx_overrides_pub ON overrides(published_at)")
    conn.commit()
    conn.close()


def log_action(conn, camera_id, action, detail=""):
    conn.execute("INSERT INTO moderation_log(at, camera_id, action, detail) VALUES(?,?,?,?)",
                 (time.time(), camera_id, action, detail))


# --------------------------------------------------------------------------
# База камер: нужна, чтобы показывать адрес, а не голый id
# --------------------------------------------------------------------------

_cameras = {}
_cameras_mtime = 0.0


def cameras():
    """id → запись камеры. Перечитывается при смене файла (после deploy_db.sh)."""
    global _cameras, _cameras_mtime
    try:
        mtime = os.path.getmtime(CAMERAS_PATH)
    except OSError:
        return _cameras
    if mtime != _cameras_mtime:
        try:
            with open(CAMERAS_PATH, encoding="utf-8") as f:
                _cameras = {int(c["id"]): c for c in json.load(f)}
            _cameras_mtime = mtime
        except (OSError, ValueError, KeyError):
            pass  # битый файл — живём на прошлом снимке, панель не должна падать
    return _cameras


def camera_title(camera_id):
    camera = cameras().get(camera_id)
    if not camera:
        return f"id {camera_id} (нет в текущей базе)"
    parts = [camera.get("location") or "", camera.get("city") or ""]
    name = ", ".join(p for p in parts if p) or camera.get("region") or ""
    return f"{name} · {camera.get('type', '')}"


def camera_point(camera_id):
    camera = cameras().get(camera_id)
    return (camera["lat"], camera["lon"]) if camera else (None, None)


# --------------------------------------------------------------------------
# HTML
# --------------------------------------------------------------------------

CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin:0; background:#05070c; color:#e8ecf3; font:15px/1.45 -apple-system,
       BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; padding-bottom:40px; }
header { position:sticky; top:0; background:#0b0f18; border-bottom:1px solid #1b2231;
         padding:10px 14px; display:flex; gap:6px; flex-wrap:wrap; z-index:5; }
header a { color:#8ea0bb; text-decoration:none; padding:6px 10px; border-radius:8px;
           font-size:14px; white-space:nowrap; }
header a.on { background:#101f2e; color:#3cdcff; }
main { padding:14px; max-width:900px; margin:0 auto; }
h1 { font-size:19px; margin:18px 0 10px; }
.card { background:#0c1017; border:1px solid #1b2231; border-radius:14px;
        padding:12px 14px; margin-bottom:10px; }
.row { display:flex; gap:10px; align-items:baseline; flex-wrap:wrap; }
.muted { color:#7c8aa0; font-size:13px; }
.big { font-size:26px; font-weight:600; }
.tag { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px;
       background:#16202f; color:#8ea0bb; }
.warn { background:#3a2410; color:#ffb527; }
.bad  { background:#3a1220; color:#ff4560; }
.ok   { background:#0f2f1e; color:#38e58c; }
/* Тон для крупной цифры: только цвет текста — заливка тега на числе
   превращается в непрочитываемый прямоугольник. */
.t-warn { color:#ffb527; }
.t-bad  { color:#ff4560; }
form.inline { display:inline; }
button { font:inherit; padding:7px 12px; border-radius:9px; border:1px solid #263349;
         background:#16202f; color:#cfe0f5; cursor:pointer; margin:3px 3px 0 0; }
button.danger { border-color:#5a2030; color:#ff8092; }
button.primary { border-color:#1d4a5e; color:#3cdcff; }
input, select, textarea { font:inherit; background:#0b111a; color:#e8ecf3;
       border:1px solid #263349; border-radius:8px; padding:6px 8px; }
a.map { color:#3cdcff; font-size:13px; }
.empty { color:#5f6c80; padding:24px 0; text-align:center; }
"""

TABS = (("/", "Сводка"), ("/cameras", "Камеры"), ("/mobile", "Передвижные"),
        ("/feedback", "Обращения"), ("/health", "Здоровье"))


def esc(value):
    """Любой пользовательский текст — только через это. Сообщения и контакты
    пишут посторонние люди, и панель не должна становиться их трибуной."""
    return html.escape(str(value if value is not None else ""), quote=True)


def page(active, title, body):
    tabs = "".join(
        f'<a href="{esc(path)}" class="{"on" if path == active else ""}">{esc(name)}</a>'
        for path, name in TABS)
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{esc(title)} · RadarMap</title><style>{CSS}</style></head>
<body><header>{tabs}</header><main>{body}</main></body></html>"""


def ago(timestamp):
    if not timestamp:
        return "—"
    seconds = max(0, time.time() - timestamp)
    if seconds < 3600:
        return f"{int(seconds // 60)} мин назад"
    if seconds < DAY:
        return f"{int(seconds // 3600)} ч назад"
    return f"{int(seconds // DAY)} дн назад"


def osm_link(lat, lon, text="на карте"):
    if lat is None or lon is None:
        return ""
    return (f'<a class="map" target="_blank" rel="noopener" '
            f'href="https://www.openstreetmap.org/?mlat={lat}&mlon={lon}#map=18/{lat}/{lon}">'
            f'{esc(text)}</a>')


# --------------------------------------------------------------------------
# Очередь камер
# --------------------------------------------------------------------------

def camera_queue(conn):
    """Нерешённые репорты, сгруппированные по камере, с уже посчитанным сигналом."""
    now = time.time()
    rows = conn.execute("""
        SELECT camera_id, reason, ip, device, received, lat, lon, db_version
        FROM camera_reports
        WHERE resolved = ? AND COALESCE(snooze_until, 0) < ?
        ORDER BY received""", (RESOLVED_NEW, now)).fetchall()

    grouped = {}
    for row in rows:
        item = grouped.setdefault(row["camera_id"], {
            "camera_id": row["camera_id"], "gone_ips": set(), "wrong_ips": set(),
            "here_ips": set(), "counts": {"gone": 0, "wrong_location": 0, "still_here": 0},
            "oldest": row["received"], "newest": row["received"],
            "last_here": 0, "points": [], "db_versions": set(),
        })
        item["counts"][row["reason"]] = item["counts"].get(row["reason"], 0) + 1
        item["oldest"] = min(item["oldest"], row["received"])
        item["newest"] = max(item["newest"], row["received"])
        # Кворум по РАЗНЫМ адресам: device — свежий UUID на каждый запрос, им
        # «пять разных устройств» рисуются с одного телефона за минуту.
        # Старые строки без ip (до миграции) в кворум не идут: лучше не снять
        # исчезнувшую камеру, чем снять стоящую.
        bucket = {"gone": "gone_ips", "wrong_location": "wrong_ips",
                  "still_here": "here_ips"}.get(row["reason"])
        if bucket and row["ip"]:
            item[bucket].add(row["ip"])
        if row["reason"] == "still_here":
            item["last_here"] = max(item["last_here"], row["received"])
        elif row["lat"] and row["lon"]:
            item["points"].append((row["lat"], row["lon"]))
        if row["db_version"]:
            item["db_versions"].add(row["db_version"])

    for item in grouped.values():
        item["suggest_hide"] = suggests_hide(item, now)
        item["disputed"] = item["counts"]["gone"] > 0 and item["counts"]["still_here"] > 0
    # Сначала то, что готово к решению, потом спорное, потом по силе сигнала.
    return sorted(grouped.values(),
                  key=lambda i: (not i["suggest_hide"], not i["disputed"],
                                 -len(i["gone_ips"]), i["oldest"]))


def suggests_hide(item, now):
    """Дозрел ли сигнал до ПРЕДЛОЖЕНИЯ скрыть (не до скрытия — решает человек)."""
    if len(item["gone_ips"]) < SUGGEST_MIN_IPS:
        return False
    if now - item["oldest"] < SUGGEST_MIN_AGE_DAYS * DAY:
        return False
    # Хотя бы одно свежее «камера на месте» отменяет предложение: краудсорс
    # спорит сам с собой, и в этом случае молчать нельзя.
    return not (item["last_here"] and now - item["last_here"] < SUGGEST_QUIET_DAYS * DAY)


def render_camera_item(item, override):
    counts = item["counts"]
    tags = []
    if item["suggest_hide"]:
        tags.append('<span class="tag warn">дозрело до решения</span>')
    if item["disputed"]:
        tags.append('<span class="tag bad">спорное</span>')
    if override:
        tags.append(f'<span class="tag ok">уже решено: {esc(override["op"])}</span>')

    camera_id = item["camera_id"]
    lat, lon = camera_point(camera_id)
    reported = ""
    if item["points"]:
        mid_lat = sum(p[0] for p in item["points"]) / len(item["points"])
        mid_lon = sum(p[1] for p in item["points"]) / len(item["points"])
        distance = ""
        if lat is not None:
            metres = haversine(lat, lon, mid_lat, mid_lon)
            distance = f" · {metres:.0f} м от камеры"
        reported = (f'<div class="muted">Где стояли телефоны: '
                    f'{osm_link(mid_lat, mid_lon, "центр отметок")}{esc(distance)}</div>')

    return f"""<div class="card">
  <div class="row"><b>{esc(camera_title(camera_id))}</b> {' '.join(tags)}</div>
  <div class="muted">id {camera_id} · {osm_link(lat, lon)} ·
    база v{esc(', v'.join(str(v) for v in sorted(item['db_versions'])) or '?')}</div>
  <div class="row" style="margin-top:6px">
    <span class="tag bad">нет: {counts['gone']} ({len(item['gone_ips'])} адр.)</span>
    <span class="tag">не там: {counts['wrong_location']} ({len(item['wrong_ips'])} адр.)</span>
    <span class="tag ok">на месте: {counts['still_here']} ({len(item['here_ips'])} адр.)</span>
    <span class="muted">первый {esc(ago(item['oldest']))}, последний {esc(ago(item['newest']))}</span>
  </div>
  {reported}
  <form method="post" action="/cameras/act">
    <input type="hidden" name="camera_id" value="{camera_id}">
    <button class="danger" name="action" value="hide"
      onclick="return confirm('Скрыть камеру у всех пользователей? Она перестанет предупреждать.')"
      >Скрыть</button>
    <button name="action" value="reject">Не подтверждаю</button>
    <button name="action" value="snooze">Отложить на 30 дн</button>
    <button name="action" value="resolve">Разобрано</button>
  </form>
  <form method="post" action="/cameras/act" style="margin-top:6px">
    <input type="hidden" name="camera_id" value="{camera_id}">
    <input name="lat" placeholder="широта" size="10" inputmode="decimal">
    <input name="lon" placeholder="долгота" size="10" inputmode="decimal">
    <button name="action" value="move">Подвинуть</button>
  </form>
</div>"""


def haversine(lat1, lon1, lat2, lon2):
    import math
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


# --------------------------------------------------------------------------
# Правки: экспорт для публикации
# --------------------------------------------------------------------------

def export_overrides(version):
    """Снимок ДЕЙСТВУЮЩИХ правок — именно снимок, а не приращение: приложение
    читает состояние целиком, и «отменить» значит опубликовать файл без строки."""
    conn = db()
    rows = conn.execute(
        "SELECT camera_id, op, lat, lon, type FROM overrides ORDER BY camera_id").fetchall()
    conn.close()
    items = []
    for row in rows:
        item = {"id": row["camera_id"], "op": row["op"]}
        if row["op"] == "move":
            item["lat"], item["lon"] = row["lat"], row["lon"]
        elif row["op"] == "retype":
            item["type"] = row["type"]
        items.append(item)
    return {"version": version, "updatedAt": time.strftime("%Y-%m-%d"), "items": items}


def mark_published(version):
    conn = db()
    now = time.time()
    count = conn.execute("UPDATE overrides SET published_at = ? WHERE published_at IS NULL",
                         (now,)).rowcount
    log_action(conn, None, "publish", f"версия {version}, новых правок {count}")
    conn.commit()
    conn.close()
    return count


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "RadarMapAdmin/1.0"
    timeout = 15

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, content_type="text/html; charset=utf-8"):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        # Панель целиком серверная — скрипты ей не нужны ни свои, ни чужие.
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.end_headers()
        self.wfile.write(payload)

    def _redirect(self, path):
        self.send_response(303)
        self.send_header("Location", path)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # --- GET ---

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        conn = db()
        try:
            if path == "/":
                return self._send(200, self.dashboard(conn))
            if path == "/cameras":
                return self._send(200, self.cameras_page(conn))
            if path == "/mobile":
                return self._send(200, self.mobile_page(conn))
            if path == "/feedback":
                return self._send(200, self.feedback_page(conn))
            if path == "/health":
                return self._send(200, self.health_page(conn))
        finally:
            conn.close()
        self._send(404, page("/", "Не найдено", '<div class="empty">Такой страницы нет</div>'))

    # --- POST ---

    def do_POST(self):
        # Basic auth браузер подставляет автоматически, в том числе в запрос,
        # инициированный чужой страницей. Сессий у панели нет, поэтому от CSRF
        # защищаемся проверкой источника: форма своя — Origin совпадает.
        origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
        host = self.headers.get("Host") or ""
        if origin and host and urlparse(origin).netloc != host:
            return self._send(403, page("/", "Отказано",
                                        '<div class="empty">Запрос с чужой страницы</div>'))

        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0 or length > 65536:
            return self._send(400, page("/", "Плохой запрос",
                                        '<div class="empty">Пустая или слишком большая форма</div>'))
        form = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        field = lambda name: (form.get(name) or [""])[0].strip()

        path = urlparse(self.path).path.rstrip("/")
        conn = db()
        try:
            if path == "/cameras/act":
                self.camera_action(conn, field)
                return self._redirect("/cameras")
            if path == "/mobile/act":
                self.mobile_action(conn, field)
                return self._redirect("/mobile")
            if path == "/feedback/act":
                self.feedback_action(conn, field)
                return self._redirect("/feedback")
        finally:
            conn.close()
        self._send(404, page("/", "Не найдено", '<div class="empty">Нет такого действия</div>'))

    # --- действия ---

    def camera_action(self, conn, field):
        try:
            camera_id = int(field("camera_id"))
        except ValueError:
            return
        action = field("action")
        now = time.time()

        if action == "hide":
            conn.execute("INSERT OR REPLACE INTO overrides"
                         "(camera_id, op, lat, lon, type, note, decided_at, published_at) "
                         "VALUES(?,'hide',NULL,NULL,NULL,'',?,NULL)", (camera_id, now))
            log_action(conn, camera_id, "hide")
            self.resolve_reports(conn, camera_id, RESOLVED_DONE)

        elif action == "move":
            try:
                lat, lon = float(field("lat")), float(field("lon"))
            except ValueError:
                return
            # Границы Узбекистана — то же условие, что в приложении: правку вне
            # них оно всё равно отвергнет, и лучше узнать об этом здесь.
            if not (37.0 <= lat <= 46.0 and 55.0 <= lon <= 74.0):
                return
            conn.execute("INSERT OR REPLACE INTO overrides"
                         "(camera_id, op, lat, lon, type, note, decided_at, published_at) "
                         "VALUES(?,'move',?,?,NULL,'',?,NULL)", (camera_id, lat, lon, now))
            log_action(conn, camera_id, "move", f"{lat:.6f}, {lon:.6f}")
            self.resolve_reports(conn, camera_id, RESOLVED_DONE)

        elif action == "restore":
            # Откат: правка исчезает из снимка, и после публикации камера
            # возвращается всем. Это и есть страховка от ошибки модератора.
            conn.execute("DELETE FROM overrides WHERE camera_id = ?", (camera_id,))
            log_action(conn, camera_id, "restore")

        elif action == "reject":
            self.resolve_reports(conn, camera_id, RESOLVED_REJECTED)
            log_action(conn, camera_id, "reject")

        elif action == "resolve":
            self.resolve_reports(conn, camera_id, RESOLVED_DONE)
            log_action(conn, camera_id, "resolve")

        elif action == "snooze":
            conn.execute("UPDATE camera_reports SET snooze_until = ? WHERE camera_id = ?",
                         (now + SNOOZE_DAYS * DAY, camera_id))
            log_action(conn, camera_id, "snooze")
        conn.commit()

    def resolve_reports(self, conn, camera_id, status):
        conn.execute("UPDATE camera_reports SET resolved = ? WHERE camera_id = ? AND resolved = ?",
                     (status, camera_id, RESOLVED_NEW))

    def mobile_action(self, conn, field):
        """Живые отметки правятся мгновенно: это данные сервера, не базы, и
        подписи им не нужно — фейк убирается с карты в ту же секунду."""
        try:
            report_id = int(field("id"))
        except ValueError:
            return
        action = field("action")
        if action == "kill":
            conn.execute("UPDATE reports SET active = 0 WHERE id = ?", (report_id,))
            log_action(conn, None, "mobile_kill", f"отметка {report_id}")
        elif action == "extend":
            conn.execute("UPDATE reports SET expires = ? WHERE id = ?",
                         (time.time() + 3 * 3600, report_id))
            log_action(conn, None, "mobile_extend", f"отметка {report_id}")
        conn.commit()

    def feedback_action(self, conn, field):
        try:
            feedback_id = int(field("id"))
        except ValueError:
            return
        status = field("status")
        if status not in ("new", "open", "answered"):
            return
        conn.execute("UPDATE feedback SET status = ?, note = ? WHERE id = ?",
                     (status, field("note")[:500], feedback_id))
        conn.commit()

    # --- страницы ---

    def dashboard(self, conn):
        now = time.time()
        queue = camera_queue(conn)
        ready = sum(1 for item in queue if item["suggest_hide"])
        disputed = sum(1 for item in queue if item["disputed"])
        new_feedback = conn.execute(
            "SELECT COUNT(*) FROM feedback WHERE COALESCE(status,'new') = 'new'").fetchone()[0]
        live = conn.execute("SELECT COUNT(*) FROM reports WHERE active = 1 AND expires > ?",
                            (now,)).fetchone()[0]
        unpublished = conn.execute(
            "SELECT COUNT(*) FROM overrides WHERE published_at IS NULL").fetchone()[0]
        oldest = conn.execute(
            "SELECT MIN(received) FROM camera_reports WHERE resolved = ?",
            (RESOLVED_NEW,)).fetchone()[0]

        def tile(value, label, tone=""):
            return (f'<div class="card" style="flex:1 1 130px">'
                    f'<div class="big {tone}">{value}</div>'
                    f'<div class="muted">{esc(label)}</div></div>')

        publish_hint = ""
        if unpublished:
            publish_hint = (f'<div class="card"><b>Решений ждёт публикации: {unpublished}</b>'
                            '<div class="muted">До публикации они не действуют ни у кого. '
                            'На своей машине: <code>bash server/publish_overrides.sh &lt;версия&gt;</code>'
                            ' — ключ подписи есть только там.</div></div>')
        return page("/", "Сводка", f"""
<h1>Что требует внимания</h1>
<div class="row">
  {tile(ready, "камер дозрело до решения", "t-warn" if ready else "")}
  {tile(disputed, "спорных (есть и «нет», и «на месте»)", "t-bad" if disputed else "")}
  {tile(new_feedback, "новых обращений")}
  {tile(live, "живых отметок на карте")}
</div>
{publish_hint}
<div class="card"><div class="muted">Всего в очереди: {len(queue)} камер ·
самый старый неразобранный репорт: {esc(ago(oldest))}</div></div>
{'<div class="empty">Пусто — можно закрыть вкладку</div>'
 if not (ready or disputed or new_feedback or unpublished) else ''}""")

    def cameras_page(self, conn):
        queue = camera_queue(conn)
        overrides = {row["camera_id"]: row for row in
                     conn.execute("SELECT * FROM overrides").fetchall()}
        if not queue:
            body = '<div class="empty">Нерешённых репортов нет</div>'
        else:
            body = "".join(render_camera_item(item, overrides.get(item["camera_id"]))
                           for item in queue)

        applied = ""
        if overrides:
            rows = "".join(f"""<div class="card"><div class="row">
                <b>{esc(camera_title(row['camera_id']))}</b>
                <span class="tag warn">{esc(row['op'])}</span>
                <span class="muted">{esc(ago(row['decided_at']))}
                {'· опубликовано' if row['published_at'] else '· ЖДЁТ ПУБЛИКАЦИИ'}</span></div>
                <form method="post" action="/cameras/act" class="inline">
                  <input type="hidden" name="camera_id" value="{row['camera_id']}">
                  <button name="action" value="restore">Вернуть камеру</button>
                </form></div>""" for row in overrides.values())
            applied = f"<h1>Действующие правки ({len(overrides)})</h1>{rows}"
        return page("/cameras", "Камеры", f"<h1>Очередь ({len(queue)})</h1>{body}{applied}")

    def mobile_page(self, conn):
        now = time.time()
        rows = conn.execute("""
            SELECT r.id, r.lat, r.lon, r.type, r.created, r.expires, r.up, r.down, r.ip,
                   (SELECT COUNT(DISTINCT v.ip) FROM votes v
                     WHERE v.report_id = r.id AND v.ip != '') AS vote_ips
            FROM reports r WHERE r.active = 1 AND r.expires > ?
            ORDER BY r.created DESC""", (now,)).fetchall()
        if not rows:
            return page("/mobile", "Передвижные", '<div class="empty">Живых отметок нет</div>')
        cards = []
        for row in rows:
            # Голоса с одного адреса — это один человек, а не кворум. Показываем
            # оба числа рядом: расхождение и есть признак накрутки.
            suspicious = (row["up"] or 0) >= 3 and (row["vote_ips"] or 0) <= 1
            cards.append(f"""<div class="card">
  <div class="row"><b>{esc(row['type'] or 'radar')}</b>
    <span class="tag">+{row['up']} / −{row['down']}</span>
    <span class="tag {'bad' if suspicious else ''}">адресов среди голосов: {row['vote_ips']}</span>
    {'<span class="tag bad">похоже на накрутку</span>' if suspicious else ''}</div>
  <div class="muted">поставлена {esc(ago(row['created']))} ·
    исчезнет через {int(max(0, row['expires'] - now) // 60)} мин · {osm_link(row['lat'], row['lon'])}</div>
  <form method="post" action="/mobile/act">
    <input type="hidden" name="id" value="{row['id']}">
    <button class="danger" name="action" value="kill">Убрать с карты</button>
    <button name="action" value="extend">Продлить на 3 ч</button>
  </form></div>""")
        return page("/mobile", "Передвижные",
                    f"<h1>Живые отметки ({len(rows)})</h1>{''.join(cards)}")

    def feedback_page(self, conn):
        rows = conn.execute("""SELECT id, message, contact, app_version, received,
                               COALESCE(status,'new') AS status, COALESCE(note,'') AS note
                               FROM feedback ORDER BY
                               (COALESCE(status,'new') = 'new') DESC, id DESC
                               LIMIT 200""").fetchall()
        if not rows:
            return page("/feedback", "Обращения", '<div class="empty">Обращений нет</div>')
        tone = {"new": "warn", "open": "", "answered": "ok"}
        cards = []
        for row in rows:
            options = "".join(
                f'<option value="{value}" {"selected" if row["status"] == value else ""}>{esc(label)}</option>'
                for value, label in (("new", "новое"), ("open", "в работе"),
                                     ("answered", "отвечено")))
            cards.append(f"""<div class="card">
  <div class="row">
    <span class="tag {tone.get(row['status'], '')}">{esc(row['status'])}</span>
    <span class="muted">{esc(ago(row['received']))} · версия {esc(row['app_version'] or '?')}</span>
  </div>
  <div style="margin:8px 0; white-space:pre-wrap">{esc(row['message'])}</div>
  <div class="muted">Контакт: {esc(row['contact'] or 'не оставлен')}</div>
  <form method="post" action="/feedback/act" style="margin-top:6px">
    <input type="hidden" name="id" value="{row['id']}">
    <select name="status">{options}</select>
    <input name="note" value="{esc(row['note'])}" placeholder="заметка" size="24">
    <button class="primary" name="action" value="save">Сохранить</button>
  </form></div>""")
        new_count = sum(1 for row in rows if row["status"] == "new")
        return page("/feedback", "Обращения",
                    f"<h1>Обращения ({new_count} новых из {len(rows)})</h1>{''.join(cards)}")

    def health_page(self, conn):
        now = time.time()

        def count(sql, args=()):
            return conn.execute(sql, args).fetchone()[0]

        crashes = hangs = 0
        for (payload,) in conn.execute(
                "SELECT payload FROM metrics WHERE kind = 'diagnostic' AND received > ?",
                (now - 7 * DAY,)):
            try:
                data = json.loads(payload)
            except ValueError:
                continue
            crashes += len(data.get("crashDiagnostics") or [])
            hangs += len(data.get("hangDiagnostics") or [])

        try:
            db_size = os.path.getsize(DB_PATH) / 1e6
        except OSError:
            db_size = 0
        base = len(cameras())
        return page("/health", "Здоровье", f"""
<h1>Здоровье за неделю</h1>
<div class="card"><div class="row">
  <span class="tag {'bad' if crashes else 'ok'}">крэшей: {crashes}</span>
  <span class="tag {'warn' if hangs else 'ok'}">зависаний: {hangs}</span>
  <span class="tag">устройств с метриками: {count(
      "SELECT COUNT(DISTINCT device) FROM metrics WHERE received > ?", (now - 7 * DAY,))}</span>
</div><div class="muted">Подробности: <code>python3 report_metrics.py --days 7</code></div></div>
<div class="card"><div class="row">
  <span class="tag">репортов о камерах за неделю: {count(
      "SELECT COUNT(*) FROM camera_reports WHERE received > ?", (now - 7 * DAY,))}</span>
  <span class="tag">отметок за неделю: {count(
      "SELECT COUNT(*) FROM reports WHERE created > ?", (now - 7 * DAY,))}</span>
  <span class="tag">обращений за неделю: {count(
      "SELECT COUNT(*) FROM feedback WHERE received > ?", (now - 7 * DAY,))}</span>
</div></div>
<div class="card"><div class="muted">
  База камер на сервере: {base} точек ·
  reports.db: {db_size:.1f} МБ ·
  правок принято: {count("SELECT COUNT(*) FROM overrides")}
  (ждут публикации: {count("SELECT COUNT(*) FROM overrides WHERE published_at IS NULL")})
</div></div>
<h1>Последние решения</h1>
{''.join(f'<div class="card"><div class="row"><b>{esc(row["action"])}</b>'
         f'<span class="muted">{esc(camera_title(row["camera_id"])) if row["camera_id"] else ""}'
         f' · {esc(ago(row["at"]))} {esc(row["detail"])}</span></div></div>'
         for row in conn.execute(
             "SELECT at, camera_id, action, detail FROM moderation_log "
             "ORDER BY id DESC LIMIT 20"))
 or '<div class="empty">Решений ещё не принимали</div>'}""")


def main():
    init_db()
    if "--export" in sys.argv:
        index = sys.argv.index("--export")
        version = int(sys.argv[index + 1]) if len(sys.argv) > index + 1 else 1
        print(json.dumps(export_overrides(version), ensure_ascii=False, separators=(",", ":")))
        return
    if "--mark-published" in sys.argv:
        index = sys.argv.index("--mark-published")
        version = int(sys.argv[index + 1])
        print(f"помечено опубликованными: {mark_published(version)}")
        return
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
