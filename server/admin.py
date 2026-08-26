#!/usr/bin/env python3
"""RadarMap: панель модератора.

Замыкает контур, который до неё был разомкнут: репорты водителей о камерах
приходили в sqlite и умирали там — колонку camera_reports.resolved никто
никогда не писал, а единственным способом модерации был SELECT в ssh-сессии.

Stdlib-only (sqlite3 + http.server), слушает 127.0.0.1:8093. Вход по паролю
(admin_auth.py: scrypt-хэш в /opt/radarmap/admin.conf, сессия в куке), но
наружу панель отдаётся ТОЛЬКО поверх HTTPS: по открытому HTTP пароль ушёл бы
открытым текстом, и `require_secure()` этого не допускает. До покупки домена
работаем через ssh-туннель. Отдельный процесс от api.py намеренно:
падение или перезапуск панели не должны ронять приём репортов от водителей,
а публичный api и приватная панель не должны делить адресное пространство.

Интерфейс — серверный HTML и обычные формы, без JS-фреймворков: модерируют
чаще всего с телефона между делом, и страница, которая грузится за 200 мс и
работает без сборки, здесь единственно верный выбор.

Единственное исключение — /map, экран положения камер. Там нужна настоящая
карта со спутником (положение камеры проверяют по снимку, не по схеме) и
работа без перезагрузок: первая версия водила по списку и отдельной странице
на каждую камеру — семь действий и две перезагрузки ради одной точки, причём
район, в котором работаешь, терялся при каждом переходе. Теперь всё на одной
карте: цвет маркера показывает, где чинить, клик выбирает, перетаскивание
двигает, JSON-ручки (/api/*) сохраняют. Скрипт один, свой, лежит файлом
(static/moderate.js), и CSP послаблена ровно на этой странице.

ВАЖНО: панель ничего не публикует сама. Ключ подписи живёт только на машине
владельца, поэтому решения копятся в таблице overrides, а публикует их одна
локальная команда — server/publish_overrides.sh. Взломанный VPS не может
ни скрыть камеру у пользователей, ни подсунуть свою.

Запуск:
    python3 admin.py                      # сервер на 127.0.0.1:8092
    python3 admin.py --export             # JSON действующих правок (для публикации)
    python3 admin.py --mark-published 12  # пометить правки опубликованными в версии 12
    python3 admin.py --set-password       # задать пароль входа (спросит дважды)
"""
import html
import json
import os
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import admin_auth
import map_edits
import osm_queue

DB_PATH = os.environ.get("RADARMAP_DB", "/opt/radarmap/api/reports.db")
CAMERAS_PATH = os.environ.get("RADARMAP_CAMERAS", "/opt/radarmap/www/cameras.json")
# 8092 занят OSRM (docker-proxy), 8091 — публичным api. 8093 свободен.
PORT = int(os.environ.get("RADARMAP_ADMIN_PORT", "8093"))
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

# Живые сессии панели и счётчик неудачных попыток. Один объект на процесс.
SESSIONS = admin_auth.Sessions()


# --------------------------------------------------------------------------
# База
# --------------------------------------------------------------------------

def db():
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.row_factory = sqlite3.Row
    return conn


def ensure_api_tables():
    """Таблицы репортов, отзывов и статистики принадлежат api.py, но ЧИТАЕТ их
    панель. Отдельные процессы стартуют в произвольном порядке, и на свежем
    сервере панель падала на каждой странице с «no such table».

    Разбрасывать try/except по всем запросам — лечение симптома. Честнее один
    раз попросить владельца схемы создать её: файл базы у нас общий.
    """
    try:
        import api
        api.init_db()
    except Exception as error:      # api.py не рядом или не импортируется
        print(f"схема api недоступна: {error}", file=sys.stderr)


def edits_tiles_dir():
    """Где лежат ОПУБЛИКОВАННЫЕ тайлы. Магнит липнет к ним, а не к сырому OSM
    и не к подложке Яндекса: в панели надо видеть ровно ту геометрию, которая
    поедет на телефон, вместе со всей генерализацией."""
    return os.environ.get("RADARMAP_TILES", "/opt/radarmap/api/tiles")


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
    map_edits.ensure_tables(conn)
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
/* Панель модератора. Один язык с приложением: тот же тёмный фон, тот же
   акцентный голубой, те же скруглённые карточки — человек ходит между ними
   в один день и не должен переключаться.

   Мобильная вёрстка не украшение: очередь разбирают с телефона (в дороге, в
   перерыве), а таблицы уезжали за экран, и «Убрать с карты» приходилось
   искать горизонтальной прокруткой. */
:root {
  color-scheme: dark;
  --bg:#05070c; --surface:#0c1017; --surface-2:#101725; --stroke:#1b2231;
  --text:#e8ecf3; --text-2:#8ea0bb; --text-3:#5f6c80;
  --accent:#3cdcff; --ok:#38e58c; --warn:#ffb527; --bad:#ff4560;
  --r:14px;
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
body { margin:0; background:var(--bg); color:var(--text);
       font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       padding-bottom:40px; -webkit-text-size-adjust:100%; }

/* Шапка: горизонтальная прокрутка вместо переноса — семь вкладок в две
   строки на телефоне съедали треть экрана. */
header { position:sticky; top:0; z-index:5; background:rgba(11,15,24,.92);
         backdrop-filter:saturate(160%) blur(12px);
         border-bottom:1px solid var(--stroke); padding:8px 10px;
         display:flex; gap:4px; align-items:center;
         overflow-x:auto; scrollbar-width:none; }
header::-webkit-scrollbar { display:none; }
header a { color:var(--text-2); text-decoration:none; padding:7px 11px;
           border-radius:10px; font-size:14px; white-space:nowrap;
           display:inline-flex; align-items:center; gap:6px; }
header a:hover { background:var(--surface-2); }
header a.on { background:#0e2434; color:var(--accent); font-weight:600; }
header a.out { margin-left:auto; color:var(--text-3); }
/* Счётчик необработанного прямо на вкладке: иначе про очередь узнаёшь,
   только если в неё зайти. */
header .n { background:var(--bad); color:#fff; border-radius:999px;
            padding:1px 6px; font-size:11px; font-weight:700; line-height:1.5; }
header a.on .n { background:var(--accent); color:#04222c; }

main { padding:14px; max-width:920px; margin:0 auto; }
h1 { font-size:19px; margin:18px 0 10px; letter-spacing:-.2px; }
h1:first-child { margin-top:4px; }

.card { background:var(--surface); border:1px solid var(--stroke);
        border-radius:var(--r); padding:13px 15px; margin-bottom:10px; }
.card:hover { border-color:#243044; }
.row { display:flex; gap:10px; align-items:baseline; flex-wrap:wrap; }
.muted { color:var(--text-2); font-size:13px; }
.big { font-size:26px; font-weight:650; letter-spacing:-.5px; }

/* Плитки сводки: то, ради чего панель открывают, — сверху и крупно. */
.tiles { display:grid; gap:10px; margin-bottom:14px;
         grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); }
.tile { background:var(--surface); border:1px solid var(--stroke);
        border-radius:var(--r); padding:12px 14px; text-decoration:none;
        color:inherit; display:block; }
.tile:hover { border-color:#243044; }
.tile .k { color:var(--text-2); font-size:12px; text-transform:uppercase;
           letter-spacing:.4px; }
.tile .v { font-size:27px; font-weight:650; letter-spacing:-.6px; margin-top:3px; }
.tile .s { color:var(--text-3); font-size:12px; margin-top:2px; }

.tag { display:inline-block; padding:2px 9px; border-radius:999px; font-size:12px;
       background:var(--surface-2); color:var(--text-2); white-space:nowrap; }
.warn { background:#3a2410; color:var(--warn); }
.bad  { background:#3a1220; color:var(--bad); }
.ok   { background:#0f2f1e; color:var(--ok); }
/* Тон для крупной цифры: только цвет текста — заливка тега на числе
   превращается в непрочитываемый прямоугольник. */
.t-warn { color:var(--warn); }
.t-bad  { color:var(--bad); }
.t-ok   { color:var(--ok); }

form.inline { display:inline; }
button { font:inherit; padding:9px 13px; border-radius:10px;
         border:1px solid #263349; background:var(--surface-2); color:#cfe0f5;
         cursor:pointer; margin:4px 4px 0 0; min-height:38px; }
button:hover { background:#16202f; border-color:#2f3f58; }
button:active { transform:translateY(1px); }
button.danger { border-color:#5a2030; color:#ff8092; }
button.danger:hover { background:#2a1119; }
button.primary { border-color:#1d4a5e; color:var(--accent); }
input, select, textarea { font:inherit; background:#0b111a; color:var(--text);
       border:1px solid #263349; border-radius:10px; padding:8px 10px;
       max-width:100%; }
input:focus, textarea:focus { outline:none; border-color:#2f6f88; }
a.map { color:var(--accent); font-size:13px; }
a { color:var(--accent); }
.empty { color:var(--text-3); padding:26px 0; text-align:center; }

/* Очередь изменений OSM. Строка — это решение, которое надо принять, поэтому
   действия стоят В НЕЙ, а не за переходом на отдельную страницу: очередь
   разбирают подряд, и каждый переход стоил бы возврата и потери места. */
.chg { border:1px solid var(--stroke); border-radius:12px; padding:10px 12px;
       margin:8px 0; display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
.chg b { font-size:14px; }
.chg .muted { flex-basis:100%; font-size:12px; }
.chg a { margin-left:auto; }
form.inline { display:inline; }
form.inline button { margin:0; padding:6px 12px; font-size:13px; }
button.ghost { background:transparent; color:var(--text-2);
               border:1px solid var(--stroke); }
.warn { background:#2a2013; border:1px solid #6b5320; border-radius:10px;
        padding:9px 12px; margin:10px 0; font-size:13px; color:#e3c07b;
        display:flex; gap:10px; align-items:center; flex-wrap:wrap; }

@media (max-width:520px) {
  main { padding:10px; }
  .card { padding:11px 12px; border-radius:12px; }
  .tile .v { font-size:23px; }
  button { width:100%; margin:5px 0 0 0; }
  button + button { margin-top:6px; }
  form.inline { display:block; }
}
"""

TABS = (("/", "Сводка"), ("/map", "Карта"), ("/editor", "Конструктор"),
        ("/changes", "Что изменилось"), ("/cameras", "Камеры"),
        ("/mobile", "Передвижные"), ("/feedback", "Обращения"),
        ("/usage", "Люди"), ("/health", "Здоровье"))

# Префикс, под которым панель видна снаружи: "/radarmap/admin" на общем домене
# или пусто при доступе через SSH-туннель. Внутрь запросы приходят уже без
# него (слеш на конце proxy_pass снимает префикс), поэтому маршрутизатор не
# меняется — префикс подставляется только в ССЫЛКИ, которые панель отдаёт
# браузеру. Без этого «Камеры» на общем домене ведут в корень чужого сайта.
BASE = os.environ.get("RADARMAP_ADMIN_BASE", "").rstrip("/")


def u(path):
    """Внешний адрес внутреннего пути."""
    return f"{BASE}{path}" if BASE else path


def esc(value):
    """Любой пользовательский текст — только через это. Сообщения и контакты
    пишут посторонние люди, и панель не должна становиться их трибуной."""
    return html.escape(str(value if value is not None else ""), quote=True)


def pending_counts(conn):
    """Сколько необработанного за каждой вкладкой. Пустой словарь при любой
    ошибке: счётчик — удобство, и панель обязана открыться без него."""
    now = time.time()
    try:
        return {
            "/cameras": conn.execute(
                "SELECT COUNT(DISTINCT camera_id) FROM camera_reports "
                "WHERE resolved = 0").fetchone()[0],
            "/feedback": conn.execute(
                "SELECT COUNT(*) FROM feedback "
                "WHERE COALESCE(status,'new') = 'new'").fetchone()[0],
            "/mobile": conn.execute(
                "SELECT COUNT(*) FROM reports WHERE active = 1 AND expires > ?",
                (now,)).fetchone()[0],
            # Черновик — это начатая и не законченная работа: он не едет
            # никуда и через неделю о нём никто не вспомнит. Счётчик на
            # вкладке — единственный способ о нём узнать, не заходя внутрь.
            "/editor": conn.execute(
                "SELECT COUNT(*) FROM map_edits WHERE status = ?",
                (map_edits.DRAFT,)).fetchone()[0],
            # Помеченные автоматикой «проверить» ждут человека на странице
            # «Что изменилось». Считаем их дешёвым запросом, а не пересборкой
            # очереди: счётчик рисуется на КАЖДОЙ странице панели.
            "/changes": conn.execute(
                "SELECT COUNT(*) FROM map_edits "
                "WHERE status = ? AND note LIKE '%проверить%'",
                (map_edits.ACCEPTED,)).fetchone()[0],
        }
    except sqlite3.Error:
        return {}


# Счётчики вкладок считаются один раз на запрос и лежат в переменной потока:
# протаскивать их через девять page(...) значило бы девять раз не забыть.
# ThreadingHTTPServer даёт поток на запрос, так что гонки тут нет.
_request = threading.local()


def page(active, title, body, counts=None):
    counts = counts if counts is not None else getattr(_request, "counts", {})
    # Адреса — заранее в переменные: вложенные кавычки внутри f-строки
    # разрешены только с Python 3.12, а на сервере 3.10.
    logout_url = u("/logout")

    def tab(path, name):
        # Счётчик прямо на вкладке: без него про очередь узнаёшь, только если
        # в неё зайти, а очередь — единственная причина открывать панель.
        number = counts.get(path) or 0
        badge = f'<span class="n">{number}</span>' if number else ""
        on = "on" if path == active else ""
        return f'<a href="{esc(u(path))}" class="{on}">{esc(name)}{badge}</a>'

    tabs = "".join(tab(path, name) for path, name in TABS)
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{esc(title)} · RadarMap</title><style>{CSS}</style></head>
<body><header>{tabs}<a href="{logout_url}" class="out">Выход</a></header>
<main>{body}</main></body></html>"""



def login_page(message="", secure=True, configured=True):
    """Форма входа. Отдельно от page(): вкладок здесь быть не должно —
    по ним ещё нельзя ходить, а ссылки, ведущие на отказ, только злят."""
    if not secure:
        note = ("Панель открыта по незашифрованному соединению. Пароль ушёл бы "
                "открытым текстом, поэтому вход отключён. Откройте её через "
                "ssh-туннель или настройте HTTPS (server/HTTPS.md).")
        form = f'<div class="empty">{esc(note)}</div>'
    elif not configured:
        note = ("Пароль ещё не задан. На сервере: python3 admin.py --set-password")
        form = f'<div class="empty">{esc(note)}</div>'
    else:
        form = (f'<form method="post" action="{u("/login")}">'
                '<input type="password" name="password" placeholder="Пароль" '
                'autofocus autocomplete="current-password" required>'
                '<button type="submit">Войти</button></form>')
    error = f'<div class="err">{esc(message)}</div>' if message else ""
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Вход · RadarMap</title><style>{CSS}
.login{{max-width:320px;margin:15vh auto;text-align:center}}
.login input{{width:100%;padding:12px;margin:8px 0;border-radius:8px;
border:1px solid #2b3038;background:#16191f;color:#e7e9ee;font-size:16px}}
.login button{{width:100%;padding:12px;font-size:16px}}
.err{{color:#ff6b6b;margin:8px 0;font-size:14px}}</style></head>
<body><main><div class="login"><h1>RadarMap</h1>{error}{form}</div></main></body></html>"""


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
# Положение камеры: карта и очередь подозрительных
# --------------------------------------------------------------------------

# Классы дорог, на которых камера действительно стоит над потоком машин.
# Тот же список, что в приложении (Camera.hasTrustedRoadProfile): снап части
# камер сел на тротуар, переход или платформу — их положение под вопросом
# в первую очередь, и приложение по такому «профилю» ничего не глушит.
VEHICLE_ROAD_CLASSES = {"motorway", "trunk", "primary", "secondary", "tertiary",
                        "residential", "service", "unclassified", "living_street"}

# Предел переноса — тот же, что в приложении (AppConfig.overrideMaxMoveMeters).
# Держим числом здесь, чтобы панель отказывала СРАЗУ, а не показывала правку,
# которую телефоны молча отвергнут.
MAX_MOVE_METERS = 500


def camera_state(camera_id, camera, reported, overrides):
    """Числовой код состояния для карты. Цвет маркера — это и есть очередь
    работы: отдельный список не нужен, если видно, где чинить.

    Порядок важен: уже принятое решение перекрывает любые признаки, жалоба
    водителя перекрывает догадку алгоритма.
    """
    if camera_id in overrides:
        return STATE_DECIDED
    if reported.get(camera_id):
        return STATE_COMPLAINT
    road_class = camera.get("cls") or ""
    if (road_class and road_class not in VEHICLE_ROAD_CLASSES) or not camera.get("road"):
        return STATE_SUSPECT
    return STATE_PLAIN


STATE_PLAIN, STATE_SUSPECT, STATE_COMPLAINT, STATE_DECIDED = 0, 1, 2, 3


def wrong_location_reports(conn):
    """id камеры → сколько открытых жалоб «стоит не там»."""
    reported = {}
    try:
        for row in conn.execute(
                "SELECT camera_id, COUNT(*) n FROM camera_reports "
                "WHERE reason = 'wrong_location' AND resolved = 0 GROUP BY camera_id"):
            reported[row["camera_id"]] = row["n"]
    except sqlite3.OperationalError:
        pass   # таблицу создаёт api.py; см. ensure_api_tables
    return reported


def pending_overrides(conn):
    """id → строка правки. Только непубликованные интересуют карту."""
    return {row["camera_id"]: row for row in conn.execute(
        "SELECT camera_id, op, lat, lon FROM overrides")}


def cameras_payload(conn):
    """Компактная выдача для карты: [id, lat, lon, состояние].

    Массивами, а не объектами: 3467 камер с именами полей — это лишние 200 КБ
    на каждом открытии панели, и через ssh-туннель это заметно.
    """
    reported = wrong_location_reports(conn)
    overrides = pending_overrides(conn)
    items = []
    for camera_id, camera in cameras().items():
        row = overrides.get(camera_id)
        lat = row["lat"] if row and row["op"] == "move" and row["lat"] else camera["lat"]
        lon = row["lon"] if row and row["op"] == "move" and row["lon"] else camera["lon"]
        items.append([camera_id, round(lat, 6), round(lon, 6),
                      camera_state(camera_id, camera, reported, overrides)])
    return items


def camera_details(conn, camera_id):
    """Подробности выбранной камеры — грузятся по клику, а не пачкой со всеми."""
    camera = cameras().get(camera_id)
    if not camera:
        return None
    row = conn.execute("SELECT op, lat, lon FROM overrides WHERE camera_id = ?",
                       (camera_id,)).fetchone()
    profile = []
    if camera.get("cls"):
        profile.append(f"класс: {camera['cls']}")
    if camera.get("axis") is not None:
        profile.append(f"ось {camera['axis']}°")
    if camera.get("dir") is not None:
        profile.append(f"направление {camera['dir']}°")
    if not camera.get("road"):
        profile.append("куска дороги нет")
    reported = wrong_location_reports(conn).get(camera_id, 0)
    return {
        "id": camera_id,
        "title": camera_title(camera_id),
        "origin": [camera["lat"], camera["lon"]],
        "moved": [row["lat"], row["lon"]] if row and row["op"] == "move" else None,
        "hidden": bool(row and row["op"] == "hide"),
        "profile": " · ".join(profile) or "профиля дороги нет",
        "complaints": reported,
        "maxMeters": MAX_MOVE_METERS,
    }


def search_cameras(query, limit=20):
    """Поиск по id или части адреса — чтобы долететь до камеры, а не искать
    её глазами по стране."""
    query = query.strip().lower()
    if not query:
        return []
    found = []
    if query.isdigit() and int(query) in cameras():
        camera_id = int(query)
        found.append({"id": camera_id, "title": camera_title(camera_id),
                      "point": [cameras()[camera_id]["lat"], cameras()[camera_id]["lon"]]})
    for camera_id, camera in cameras().items():
        if len(found) >= limit:
            break
        haystack = f"{camera.get('location', '')} {camera.get('city', '')}".lower()
        if query in haystack and not any(f["id"] == camera_id for f in found):
            found.append({"id": camera_id, "title": camera_title(camera_id),
                          "point": [camera["lat"], camera["lon"]]})
    return found


def render_moderation_map(api_key, pending, camera_count):
    logout_url, moderate_js = u("/logout"), u("/static/moderate.js")
    """Главный экран модерации: одна карта на все камеры.

    Прежний путь «список → страница камеры → перетащить → назад» стоил семи
    действий и двух перезагрузок на одну точку, а район, в котором работаешь,
    терялся при каждом переходе. Здесь всё на одной карте: клик выбирает,
    перетаскивание двигает, сохранение не перезагружает страницу.
    """
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Карта камер · RadarMap</title><style>{CSS}
body{{overflow:hidden}}
#map{{position:absolute;inset:52px 0 0 0}}
.side{{position:absolute;top:64px;right:12px;width:320px;max-height:calc(100vh - 88px);
overflow:auto;background:#12161d;border:1px solid #232a35;border-radius:14px;
padding:14px;z-index:4;display:none}}
.side.on{{display:block}}
.side h3{{margin:0 0 6px;font-size:15px;line-height:1.3}}
.side .muted{{font-size:12px}}
.row{{display:flex;gap:8px;align-items:center;margin:10px 0}}
.row b{{font-size:20px}}
.warn{{background:#2a2013;border:1px solid #6b5320;border-radius:10px;padding:9px 10px;
margin:10px 0;font-size:12px;color:#e3c07b;line-height:1.45}}
.tools{{position:absolute;top:64px;left:12px;z-index:4;display:flex;gap:8px;
flex-direction:column;width:290px}}
.tools input{{width:100%;padding:9px 11px;border-radius:9px;border:1px solid #2b3038;
background:#12161df2;color:#e7e9ee;font-size:14px}}
.chips{{display:flex;gap:6px;flex-wrap:wrap}}
.chip{{padding:6px 10px;border-radius:999px;border:1px solid #2b3038;background:#12161df2;
color:#8ea0bb;font-size:12px;cursor:pointer;user-select:none}}
.chip.on{{background:#101f2e;color:#3cdcff;border-color:#17384d}}
.found{{background:#12161df2;border:1px solid #232a35;border-radius:10px;overflow:hidden}}
.found div{{padding:8px 10px;font-size:12px;cursor:pointer;border-bottom:1px solid #1b2231}}
.found div:hover{{background:#182029}}
.toast{{position:absolute;left:50%;bottom:22px;transform:translateX(-50%);z-index:6;
background:#12161df2;border:1px solid #2b3038;border-radius:12px;padding:10px 14px;
font-size:13px;display:none;gap:12px;align-items:center}}
.toast.on{{display:flex}}
.toast button{{padding:6px 12px;font-size:13px}}
.far{{color:#ff6b6b}}
.legend{{position:absolute;left:12px;bottom:12px;z-index:4;background:#12161de6;
border:1px solid #232a35;border-radius:10px;padding:8px 10px;font-size:11px;
color:#8ea0bb;line-height:1.7}}
.dot{{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px}}
</style></head>
<body><header>{"".join(
    f'<a href="{esc(u(path))}" class="{"on" if path == "/map" else ""}">{esc(name)}</a>'
    for path, name in TABS)}<a href="{logout_url}" class="out">Выход</a></header>
<div id="map"></div>

<div class="tools">
  <input id="q" placeholder="Поиск: id или адрес" autocomplete="off">
  <div class="found" id="found" style="display:none"></div>
  <div class="chips">
    <span class="chip on" data-filter="all">Все · {camera_count}</span>
    <span class="chip" data-filter="work">Требуют проверки</span>
    <span class="chip" data-filter="done">Правки · {pending}</span>
  </div>
</div>

<div class="side" id="side">
  <h3 id="s-title">—</h3>
  <div class="muted" id="s-profile"></div>
  <div class="muted" id="s-complaints" style="color:#ff6b6b"></div>
  <div class="row"><span>сдвиг: <b id="s-dist">0</b> м</span>
    <span class="muted" id="s-coords"></span></div>
  <div class="warn">После переноса камера теряет измеренный профиль дороги —
  ось, направление, геометрию проезжей части: снап мерил их в прежней точке.
  Практически это значит, что камера начнёт предупреждать в обе стороны.
  Двигайте, когда точка не на своей дороге, а не ради десятка метров.</div>
  <div class="row">
    <button id="s-save" disabled>Сохранить</button>
    <button id="s-reset">Вернуть</button>
    <button id="s-close">Закрыть</button>
  </div>
</div>

<div class="toast" id="toast"><span id="toast-text"></span>
  <button id="toast-undo">Отменить</button></div>

<div class="legend">
  <span class="dot" style="background:#ff6b6b"></span>жалоба «стоит не там»<br>
  <span class="dot" style="background:#e3c07b"></span>снап под вопросом<br>
  <span class="dot" style="background:#3ddc84"></span>перенесена, ждёт публикации<br>
  <span class="dot" style="background:#8ea0bb"></span>обычная
</div>

<script src="https://api-maps.yandex.ru/2.1/?apikey={esc(api_key)}&lang=ru_RU"></script>
<script>window.RM_BASE={json.dumps(BASE)};</script>
<script src="{moderate_js}"></script>
</body></html>"""


# --------------------------------------------------------------------------
# Очередь камер
# --------------------------------------------------------------------------

def render_editor(api_key, drafts):
    """Страница конструктора.

    Тот же стек и та же форма, что у /map: своя полная страница вместо page(),
    потому что карта обязана занять экран целиком, а не жить внутри <main> с
    полями. Там уже стоит карта со спутником, ключ, послабленная ровно на одной
    странице CSP и свой скрипт файлом без сборки. Второй стек ради второй карты
    означал бы две подложки, два способа авторизации и две вещи, которые
    ломаются порознь.
    """
    logout_url = u("/logout")
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Конструктор · RadarMap</title><style>{CSS}
body{{overflow:hidden}}
#map{{position:absolute;inset:52px 0 0 0}}
.tools{{position:absolute;top:64px;left:12px;z-index:4;display:flex;gap:8px;
flex-direction:column;width:260px;max-height:calc(100vh - 88px);overflow:auto}}
.tool{{padding:10px 12px;border-radius:10px;border:1px solid #2b3038;
background:#12161df2;color:#8ea0bb;font-size:14px;cursor:pointer;text-align:left}}
.tool.on{{background:#101f2e;color:#3cdcff;border-color:#17384d}}
.legend{{background:#12161de6;border:1px solid #232a35;border-radius:10px;
padding:9px 11px;font-size:12px;color:#8ea0bb;line-height:1.5}}
.card{{position:absolute;top:64px;right:12px;width:300px;z-index:5;
background:#12161d;border:1px solid #232a35;border-radius:14px;padding:14px}}
.card[hidden]{{display:none}}
.card h3{{margin:0 0 4px;font-size:15px}}
.card label{{display:block;margin:10px 0 0;font-size:12px;color:#8ea0bb}}
.card input{{width:100%;margin-top:4px;padding:9px 11px;border-radius:9px;
border:1px solid #2b3038;background:#0d1116;color:#e7e9ee;font-size:14px}}
.card button{{margin-top:12px;margin-right:8px}}
.card button.ghost{{background:#12161d;color:#8ea0bb;border:1px solid #2b3038}}
.card button.pick{{display:block;width:100%;margin-top:8px;text-align:left;
background:#0d1116;color:#e7e9ee;border:1px solid #2b3038;border-left-width:4px}}
.card .keys{{margin-top:12px;padding-top:10px;border-top:1px solid #1b2231;
font-size:11px}}
.hint{{font-size:12px;color:#8ea0bb;line-height:1.5}}
/* Полоска отмены. Не диалог подтверждения: тот тормозит на каждом объекте и
   всё равно проматывается не глядя, а отмена после факта стоит ноль, пока не
   нужна. Ровно так же сделано на карте камер. */
.toast{{position:absolute;left:50%;bottom:22px;transform:translateX(-50%);z-index:6;
background:#12161df2;border:1px solid #2b3038;border-radius:12px;padding:10px 14px;
font-size:13px;display:none;gap:12px;align-items:center}}
.toast.on{{display:flex}}
.toast button{{padding:6px 12px;font-size:13px}}
/* Очередь работы. Панель обязана говорить, что делать дальше: пустой экран
   карты — это вопрос «а где работать?», на который модератор отвечает своей
   памятью, а она кончается на третьем сеансе. */
.todo{{max-height:46vh;overflow:auto;padding:8px}}
.todo-row{{display:block;width:100%;text-align:left;margin-top:4px;padding:6px 8px;
border:1px solid #232a35;border-radius:8px;background:#0d1116;color:#8ea0bb;
font-size:12px;cursor:pointer;line-height:1.35}}
.todo-row:hover{{background:#182029;color:#e7e9ee}}
.todo-row.on{{border-color:#17384d;color:#3cdcff}}
.todo-row.draft{{border-left:3px solid #ffb020}}
</style></head>
<body><header>{"".join(
    f'<a href="{esc(u(path))}" class="{"on" if path == "/editor" else ""}">{esc(name)}</a>'
    for path, name in TABS)}<a href="{logout_url}" class="out">Выход</a></header>
<div id="map"></div>
<div class="tools" data-base="{esc(u(''))}" data-drafts="{drafts}">
  <button data-kind="lanes" class="tool on">1 · Полосы</button>
  <button data-kind="turn_lanes" class="tool">2 · Направления</button>
  <button data-kind="u_turn" class="tool">3 · Разворот</button>
  <div class="legend" id="hint">Черновиков: {drafts}. Клик по дороге ставит
    объект, клик по объекту — правит. Панель ничего не публикует.</div>
  <div class="legend">1–9 вид · Enter принять · Delete снять · Esc закрыть ·
    Ctrl+Z отменить · \\ схема ⇄ спутник · ] [ по очереди</div>
  <div class="legend todo" id="todo"></div>
</div>
<aside class="card" id="card" hidden></aside>
<div class="toast" id="toast"></div>
<script src="https://api-maps.yandex.ru/2.1/?apikey={esc(api_key)}&lang=ru_RU"></script>
<script src="{esc(u('/static/editor.js'))}"></script>
</body></html>"""


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
    cameras_act = u("/cameras/act")
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
  <form method="post" action="{cameras_act}">
    <input type="hidden" name="camera_id" value="{camera_id}">
    <button class="danger" name="action" value="hide"
      onclick="return confirm('Скрыть камеру у всех пользователей? Она перестанет предупреждать.')"
      >Скрыть</button>
    <button name="action" value="reject">Не подтверждаю</button>
    <button name="action" value="snooze">Отложить на 30 дн</button>
    <button name="action" value="resolve">Разобрано</button>
  </form>
  <form method="post" action="{cameras_act}" style="margin-top:6px">
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


def export_edits():
    """Снимок правок конструктора для запекания в тайлы.

    Тот же приём, что у камер: снимок состояния, а не приращение. Сборка
    накладывает его целиком, и «отменить правку» значит собрать тайлы без этой
    строки — отдельного механизма отмены не нужно.
    """
    conn = db()
    try:
        map_edits.ensure_tables(conn)
        items = map_edits.export_accepted(conn)
    finally:
        conn.close()
    return {"version": 1, "updatedAt": time.strftime("%Y-%m-%d"), "items": items}


def sweep_edits(tiles_dir):
    """Прогнать правки по свежесобранной сети → строка отчёта.

    Зовётся сборкой сразу после кандидата и ДО публикации: если правка
    потеряла опору, узнать об этом надо раньше, чем тайл уедет на телефоны.
    Двигает только то, на что автоматика имеет право; снятие с публикации
    остаётся решением человека и ждёт его на странице «Что изменилось».
    """
    roads = map_edits.load_roads(tiles_dir, -90, -180, 90, 180)
    if not roads:
        return "правки не сверялись: тайлов по указанному пути нет"
    conn = db()
    try:
        map_edits.ensure_tables(conn)
        decisions = osm_queue.sweep(conn, roads)
        moved, queued = osm_queue.apply_sweep(conn, decisions)
        counts = osm_queue.summary(decisions)
        log_action(conn, None, "osm-sweep",
                   f"подвинуто {moved}, в очередь {queued}")
        conn.commit()
    finally:
        conn.close()
    return (f"правок сверено {len(decisions)}: на месте "
            f"{counts.get(osm_queue.KEEP, 0)}, подвинуто {moved}, "
            f"в очередь {queued}")


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

    # Обычная политика: панель серверная, скрипты ей не нужны ни свои, ни чужие.
    CSP_STRICT = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
    # Послабление РОВНО для страницы переноса и ровно до доменов Яндекса.
    # Свой скрипт лежит файлом ('self'), поэтому 'unsafe-inline' для скриптов
    # не нужен — внедрить код через данные камеры нельзя.
    CSP_MAP = ("default-src 'none'; form-action 'self'; "
               # yastatic.net обязателен: api-maps.yandex.ru — только загрузчик,
               # сам код карты лежит там. Без него страница открывается, а карта
               # остаётся пустой с «Failed to bundle "full"» в консоли.
               "script-src 'self' https://api-maps.yandex.ru "
               "https://*.maps.yandex.net https://yastatic.net; "
               "style-src 'unsafe-inline'; "
               "img-src 'self' data: blob: https://*.maps.yandex.net "
               "https://*.yandex.ru https://yastatic.net; "
               # 'self' обязателен: карта берёт камеры и сохраняет правки со
               # СВОЕГО же сервера (/api/*). Без него страница открывалась, но
               # оставалась пустой — запросы молча блокировались политикой, и
               # на стенде без CSP этого было не увидеть.
               "connect-src 'self' https://api-maps.yandex.ru "
               "https://*.maps.yandex.net https://*.yandex.ru https://yastatic.net; "
               "font-src data:; worker-src blob:; child-src blob:")

    def _send(self, code, body, content_type="text/html; charset=utf-8", csp=None):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        # same-origin, а НЕ no-referrer: при no-referrer браузер шлёт
        # `Origin: null` даже на свою же форму, и проверка источника ниже
        # отвергала собственный вход с 403. Наружу заголовок всё равно не
        # уходит — панель никуда не ссылается.
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", csp or self.CSP_STRICT)
        self.end_headers()
        self.wfile.write(payload)

    def _redirect(self, path):
        self.send_response(303)
        self.send_header("Location", path)
        self.send_header("Content-Length", "0")
        self.end_headers()


    # --- Вход ---

    def _authorized(self):
        """Пропускать ли дальше. Заодно единственное место, где решается
        вопрос «безопасно ли вообще принимать пароль по этому соединению»."""
        if not admin_auth.require_secure(self.headers, self.client_address[0]):
            return False
        return SESSIONS.valid(admin_auth.cookie_token(self.headers.get("Cookie")))

    def _send_login(self, message="", code=200):
        secure = admin_auth.require_secure(self.headers, self.client_address[0])
        configured = bool(admin_auth.read_config().get("password_hash"))
        self._send(code, login_page(message, secure=secure, configured=configured))

    def _do_login(self, field):
        address = self.client_address[0]
        if not admin_auth.require_secure(self.headers, address):
            return self._send_login(code=403)
        # Перебор гасим ДО проверки пароля: иначе scrypt честно считает хэш
        # на каждую попытку и панель ложится сама от собственной защиты.
        if SESSIONS.blocked(address):
            return self._send_login("Слишком много попыток. Подождите 15 минут.", code=429)
        stored = admin_auth.read_config().get("password_hash")
        if admin_auth.check_password(field("password"), stored):
            SESSIONS.note_success(address)
            token = SESSIONS.issue()
            self.send_response(303)
            self.send_header("Location", "/")
            # SameSite=Lax, а не Strict: со Strict часть браузеров не
            # прикладывает куку к переходу СРАЗУ после входа — человек вводит
            # верный пароль и снова видит форму. Lax блокирует то же, ради чего
            # Strict и ставился, — межсайтовый POST, — но переход по своей же
            # ссылке не ломает.
            self.send_header("Set-Cookie",
                             f"{admin_auth.SESSION_COOKIE}={token}; Path=/; "
                             "HttpOnly; SameSite=Lax; Max-Age="
                             f"{admin_auth.SESSION_TTL}")
            self.send_header("Content-Length", "0")
            return self.end_headers()
        SESSIONS.note_failure(address)
        self._send_login("Неверный пароль", code=401)

    def _do_logout(self):
        SESSIONS.drop(admin_auth.cookie_token(self.headers.get("Cookie")))
        self.send_response(303)
        self.send_header("Location", "/login")
        self.send_header("Set-Cookie",
                         f"{admin_auth.SESSION_COOKIE}=; Path=/; HttpOnly; "
                         "SameSite=Lax; Max-Age=0")
        self.send_header("Content-Length", "0")
        self.end_headers()

    # --- GET ---

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/login":
            return self._send_login()
        if path == "/logout":
            return self._do_logout()
        if not self._authorized():
            return self._send_login(code=401)
        conn = db()
        try:
            _request.counts = pending_counts(conn)
            if path == "/":
                return self._send(200, self.dashboard(conn))
            if path == "/cameras":
                return self._send(200, self.cameras_page(conn))
            if path == "/mobile":
                return self._send(200, self.mobile_page(conn))
            if path == "/feedback":
                return self._send(200, self.feedback_page(conn))
            if path == "/usage":
                return self._send(200, self.usage_page(conn))
            if path == "/health":
                return self._send(200, self.health_page(conn))
            if path == "/map":
                return self.moderation_map(conn)
            if path == "/api/cameras":
                return self._json({"cameras": cameras_payload(conn)})
            if path.startswith("/api/camera/"):
                return self.camera_json(conn, path)
            if path == "/api/search":
                query = parse_qs(urlparse(self.path).query).get("q", [""])[0]
                return self._json({"found": search_cameras(query)})
            if path == "/editor":
                return self.editor_page(conn)
            if path == "/api/edits":
                return self.edits_json(conn)
            if path == "/api/roads":
                return self.roads_json()
            if path == "/changes":
                return self._send(200, self.changes_page(conn))
            if path == "/api/todo":
                return self.todo_json(conn)
            if path in ("/static/moderate.js", "/static/editor.js"):
                return self.static_file(path.rsplit("/", 1)[1],
                                        "application/javascript; charset=utf-8")
            # Старые адреса ведут на карту: два способа делать одно и то же —
            # это рассинхронизация, а ссылки из очереди жалоб должны работать.
            if path == "/positions":
                return self._redirect(u("/map"))
            if path.startswith("/cameras/") and path.endswith("/map"):
                return self._redirect(u("/map#" + path.split("/")[2]))
        finally:
            conn.close()
        self._send(404, page("/", "Не найдено", '<div class="empty">Такой страницы нет</div>'))

    # --- POST ---

    def do_POST(self):
        # Кука сессии помечена SameSite=Lax, но проверку источника оставляем:
        # два независимых заслона от подделки запроса дешевле одного.
        origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
        # "null" означает «браузер решил источник не раскрывать» — это НЕ чужой
        # источник, и отвергать по нему нельзя: именно так панель отказывала
        # собственной форме входа. Настоящий заслон от подделки — кука
        # SameSite=Lax: к межсайтовому POST браузер её не приложит.
        if origin == "null":
            origin = ""
        host = self.headers.get("Host") or ""
        if origin and host and urlparse(origin).netloc != host:
            return self._send(403, page("/", "Отказано",
                                        '<div class="empty">Запрос с чужой страницы</div>'))

        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0 or length > 65536:
            return self._send(400, page("/", "Плохой запрос",
                                        '<div class="empty">Пустая или слишком большая форма</div>'))
        # Тело читается РОВНО ОДИН раз. Форма и JSON разбираются из одних и тех
        # же байтов: попытка перечитать rfile во втором обработчике вешала
        # запрос намертво — сервер ждал данных, которых уже нет.
        raw = self.rfile.read(length).decode("utf-8", "replace")
        form = parse_qs(raw)
        field = lambda name: (form.get(name) or [""])[0].strip()

        path = urlparse(self.path).path.rstrip("/")
        if path == "/login":
            return self._do_login(field)
        if not self._authorized():
            return self._send_login(code=401)

        conn = db()
        try:
            if path == "/api/move":
                return self.move_json(conn, self._json_body(raw))
            if path == "/api/undo":
                return self.undo_json(conn, self._json_body(raw))
            if path == "/api/snap":
                return self.snap_json(self._json_body(raw))
            if path == "/api/edit":
                return self.edit_save_json(conn, self._json_body(raw))
            if path == "/api/edit/withdraw":
                return self.edit_withdraw_json(conn, self._json_body(raw))
            if path == "/changes/act":
                return self.changes_action(conn, field)
            if path == "/cameras/act":
                self.camera_action(conn, field)
                return self._redirect(u("/cameras"))
            if path == "/mobile/act":
                self.mobile_action(conn, field)
                return self._redirect(u("/mobile"))
            if path == "/feedback/act":
                self.feedback_action(conn, field)
                return self._redirect(u("/feedback"))
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
            try:
                conn.execute("UPDATE camera_reports SET snooze_until = ? WHERE camera_id = ?",
                             (now + SNOOZE_DAYS * DAY, camera_id))
            except sqlite3.OperationalError:
                pass   # см. resolve_reports: таблицы может ещё не быть
            log_action(conn, camera_id, "snooze")
        conn.commit()

    def resolve_reports(self, conn, camera_id, status):
        """Закрыть жалобы по камере. Таблицу создаёт api.py — на свежем сервере
        панель может подняться раньше него, и тогда закрывать нечего.

        Раньше её отсутствие роняло весь обработчик, причём ПОСЛЕ записи правки
        и ДО commit: решение модератора терялось молча, а он видел ошибку сети.
        Найдено на локальном стенде с пустой базой."""
        try:
            conn.execute("UPDATE camera_reports SET resolved = ? "
                         "WHERE camera_id = ? AND resolved = ?",
                         (status, camera_id, RESOLVED_NEW))
        except sqlite3.OperationalError:
            pass

    def mobile_action(self, conn, field):
        """Живые отметки правятся мгновенно: это данные сервера, не базы, и
        подписи им не нужно — фейк убирается с карты в ту же секунду."""
        try:
            report_id = int(field("id"))
        except ValueError:
            report_id = 0   # «Снять блокировку» приходит без отметки
        action = field("action")
        if action == "kill":
            conn.execute("UPDATE reports SET active = 0, closed = 'moderator' WHERE id = ?",
                         (report_id,))
            log_action(conn, None, "mobile_kill", f"отметка {report_id}")
        elif action == "extend":
            conn.execute("UPDATE reports SET expires = ? WHERE id = ?",
                         (time.time() + 3 * 3600, report_id))
            log_action(conn, None, "mobile_extend", f"отметка {report_id}")
        elif action == "block":
            # Блокируем оба ключа сразу: адрес переживает ротацию UUID,
            # устройство — смену сети. Сутки, а не навсегда: за адресом в
            # Узбекистане стоит CGNAT, и вечный бан выключил бы вместе со
            # спамером район города. Возврат — кнопкой «Снять».
            row = conn.execute("SELECT device, ip FROM reports WHERE id = ?",
                               (report_id,)).fetchone()
            if row:
                until = time.time() + 86400
                for kind, value in (("device", row["device"]), ("ip", row["ip"])):
                    if not value:
                        continue
                    conn.execute(
                        "INSERT OR REPLACE INTO blocked(kind, value, until, note, created) "
                        "VALUES(?,?,?,?,?)",
                        (kind, value, until, f"отметка {report_id}", time.time()))
                # Живые отметки источника уводим с карты тем же движением:
                # оставить их значит блокировать на будущее и терпеть в
                # настоящем.
                conn.execute(
                    "UPDATE reports SET active = 0, closed = 'blocked' "
                    "WHERE active = 1 AND (device = ? OR (ip != '' AND ip = ?))",
                    (row["device"], row["ip"]))
                log_action(conn, None, "mobile_block", f"источник отметки {report_id}")
        elif action == "unblock":
            kind, value = field("block_kind"), field("block_value")
            if kind in ("ip", "device") and value:
                conn.execute("DELETE FROM blocked WHERE kind = ? AND value = ?",
                             (kind, value))
                log_action(conn, None, "mobile_unblock", f"{kind} {value}")
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


    # --- Положение камеры ---

    def static_file(self, name, content_type):
        """Один каталог, имена из белого списка. Отдавать файлы по имени из URL
        нельзя: так наружу уезжает /etc/passwd."""
        if name not in ("moderate.js", "editor.js"):
            return self._send(404, page("/", "Не найдено", ""))
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static", name)
        try:
            with open(path, encoding="utf-8") as handle:
                body = handle.read()
        except OSError:
            return self._send(404, page("/", "Не найдено",
                                        '<div class="empty">Файл карты не найден</div>'))
        self._send(200, body, content_type)

    def _json(self, payload, code=200):
        self._send(code, json.dumps(payload, ensure_ascii=False),
                   "application/json; charset=utf-8")

    @staticmethod
    def _json_body(raw):
        """Тело запроса как объект. Пустой словарь — не разобралось: обработчик
        тогда честно ответит «плохие поля», а не будет гадать."""
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except ValueError:
            return {}

    def moderation_map(self, conn):
        api_key = admin_auth.read_config().get("yandex_key", "")
        if not api_key:
            return self._send(200, page("/map", "Нет ключа карты",
                '<div class="empty">В /opt/radarmap/admin.conf нет строки '
                'yandex_key=… — без неё карта не загрузится</div>'))
        pending = conn.execute(
            "SELECT COUNT(*) n FROM overrides WHERE published_at IS NULL").fetchone()["n"]
        self._send(200, render_moderation_map(api_key, pending, len(cameras())),
                   csp=self.CSP_MAP)

    # --- Конструктор карты

    def editor_page(self, conn):
        api_key = admin_auth.read_config().get("yandex_key", "")
        if not api_key:
            return self._send(200, page("/editor", "Нет ключа карты",
                '<div class="empty">В /opt/radarmap/admin.conf нет строки '
                'yandex_key=… — без неё карта не загрузится</div>'))
        drafts = conn.execute("SELECT COUNT(*) n FROM map_edits WHERE status = ?",
                              (map_edits.DRAFT,)).fetchone()["n"]
        self._send(200, render_editor(api_key, drafts), csp=self.CSP_MAP)

    def _bbox(self):
        """Рамка карты из запроса. Без неё не отвечаем: в тайле Ташкента
        71 595 дорог, и «отдай всё» убило бы панель на первом открытии."""
        query = parse_qs(urlparse(self.path).query)
        try:
            return tuple(float(query[key][0])
                         for key in ("south", "west", "north", "east"))
        except (KeyError, IndexError, ValueError):
            return None

    def edits_json(self, conn):
        box = self._bbox()
        if box is None:
            return self._json({"error": "нужна рамка карты"}, 400)
        self._json({"edits": map_edits.in_bbox(conn, *box)})

    def roads_json(self):
        """Геометрия для магнита и для предпросмотра — из опубликованных
        тайлов. В панели видно ровно то, что поедет на телефон."""
        box = self._bbox()
        if box is None:
            return self._json({"error": "нужна рамка карты"}, 400)
        roads = map_edits.load_roads(edits_tiles_dir(), *box)

        def described(road):
            flags, cls = road.get("flags", 0), road["cls"]
            return {"cls": cls, "name": road.get("name", ""),
                    "points": road["points"],
                    # Ширину считает СЕРВЕР. Панель обязана рисовать то же, что
                    # увидит водитель, а вторая реализация той же формулы в
                    # JavaScript разошлась бы с первой молча — и разошлась бы
                    # именно там, где это стоит дороже всего: на глазах у
                    # человека, который по этой картинке принимает решение.
                    "lanes": map_edits.road_lanes_of(flags, cls),
                    "width": round(map_edits.road_width_meters(flags, cls), 1),
                    "oneWay": bool(flags & map_edits.FLAG_ONEWAY),
                    "level": 1 if flags & map_edits.FLAG_BRIDGE
                             else (-1 if flags & map_edits.FLAG_TUNNEL else 0),
                    "measured": bool(flags & map_edits.FLAG_LANES_TAGGED)}

        self._json({"roads": [described(r) for r in roads[:2000]]})

    def snap_json(self, field):
        """Магнит. Считает СЕРВЕР, а не браузер, и это не про мощность.

        Пороги посадки — часть контракта с запеканием: тайлы собирает
        build_roads.py теми же числами. Вторая реализация в JavaScript
        разошлась бы с первой молча, и разошлась бы именно там, где дорого, —
        на неоднозначных местах.

        Отдаём СПИСОК кандидатов, а не один ответ. Магнит по-прежнему не
        выбирает за человека, но «приблизьте карту» ответом не является:
        приближение не разводит две проезжие части, они физически в двадцати
        метрах. У каждого кандидата уже посчитана своя посадка — выбор не стоит
        второго запроса.
        """
        try:
            lon, lat = float(field["lon"]), float(field["lat"])
        except (KeyError, TypeError, ValueError):
            return self._json({"error": "нужны lat и lon"}, 400)
        span = 0.002
        roads = map_edits.load_roads(edits_tiles_dir(), lat - span, lon - span,
                                     lat + span, lon + span)
        found = map_edits.candidates((lon, lat), roads)
        result = map_edits.snap((lon, lat), roads,
                                prefer_node=bool(field.get("preferNode")))

        def described(item):
            road = item["road"]
            return {"cls": road["cls"], "name": road.get("name", ""),
                    "points": road["points"], "point": list(item["point"]),
                    "meters": round(item["distance"], 1),
                    "anchor": {"cls": road["cls"], "name": road.get("name", ""),
                               "bearing": round(item["bearing"], 1),
                               "atNode": False}}

        return self._json({
            "point": list(result.point) if result.road else None,
            "onRoad": result.on_road,
            "atNode": result.at_node,
            "anchor": result.anchor,
            # Три — потолок не от лени: четыре строки выбора за рулём панели
            # уже не читаются, а четвёртая дорога в радиусе захвата означает,
            # что человек ткнул не туда.
            "candidates": [described(item) for item in found[:3]],
            "ambiguous": len(result.ambiguous) > 0,
            "fingerprint": map_edits.fingerprint((lon, lat), roads)})

    def todo_json(self, conn):
        """Что делать дальше в видимой рамке.

        Панель обязана отвечать на этот вопрос сама. Пустой экран карты — это
        вопрос «а где работать?», на который модератор отвечает своей памятью,
        а она кончается на третьем сеансе.
        """
        box = self._bbox()
        if box is None:
            return self._json({"error": "нужна рамка карты"}, 400)
        roads = map_edits.load_roads(edits_tiles_dir(), *box)
        edits = map_edits.in_bbox(conn, *box)
        drafts = [e for e in edits if e["status"] == map_edits.DRAFT]
        self._json({
            "lanes": map_edits.todo(roads, edits),
            # Черновики — тоже работа: начал и не закончил. Их в очереди
            # ставим первыми, потому что забытый черновик не едет никуда.
            "drafts": [{"id": e["id"], "kind": e["kind"], "point": e["geom"]}
                       for e in drafts],
        })

    def edit_save_json(self, conn, field):
        """Создать или поправить. Статус выше «принято» отсюда не ставится:
        публикует владелец со своей машины, и панель этого не умеет."""
        kind = field.get("kind")
        if kind not in map_edits.KINDS:
            return self._json({"error": "неизвестный вид правки"}, 400)
        status = field.get("status", map_edits.DRAFT)
        if status not in (map_edits.DRAFT, map_edits.ACCEPTED):
            return self._json({"error": "панель не публикует"}, 400)
        geom, raw_point = field.get("geom"), field.get("raw")
        if not (isinstance(geom, list) and isinstance(raw_point, list)):
            return self._json({"error": "нужна геометрия"}, 400)

        edit_id, version = field.get("id"), field.get("version")
        if edit_id is None:
            new_id = map_edits.create(
                conn, kind, raw=raw_point, snapped=geom,
                anchor=field.get("anchor"), props=field.get("props") or {},
                note=str(field.get("note") or ""),
                author=str(field.get("author") or "panel"),
                fingerprint_value=field.get("fingerprint"), status=status)
            log_action(conn, None, "edit-create", f"{kind} #{new_id}")
            conn.commit()
            return self._json({"id": new_id, "version": 1})
        if not isinstance(version, int):
            return self._json({"error": "нужна версия"}, 409)
        ok = map_edits.update(conn, int(edit_id), version, status=status,
                              geom=geom, raw=raw_point,
                              anchor=field.get("anchor"),
                              props=field.get("props") or {},
                              note=str(field.get("note") or ""))
        if not ok:
            return self._json({"error": "правку изменили в другом окне"}, 409)
        log_action(conn, None, "edit-save", f"{kind} #{edit_id}")
        conn.commit()
        self._json({"id": int(edit_id), "version": version + 1})

    def edit_withdraw_json(self, conn, field):
        try:
            edit_id, version = int(field["id"]), int(field["version"])
        except (KeyError, TypeError, ValueError):
            return self._json({"error": "нужны id и версия"}, 400)
        if not map_edits.withdraw(conn, edit_id, version):
            return self._json({"error": "правку изменили в другом окне"}, 409)
        log_action(conn, None, "edit-withdraw", f"#{edit_id}")
        conn.commit()
        self._json({"ok": True})

    # --- Что изменилось после пересборки OSM

    def changes_page(self, conn):
        """Очередь изменений: что автоматика сделала сама и о чём спрашивает.

        Порядок разделов — по важности, а не по времени: сверху то, что требует
        решения человека, ниже то, что уже сделано и показано просто чтобы
        видеть. Список, отсортированный по дате, заставлял бы каждый раз искать
        среди сделанного то, что ждёт.
        """
        # Баннер СНАЧАЛА, и это не порядок ради порядка. Он рассказывает, что
        # только что сделано, и держит ссылку «вернуть»; уйди страница в ранний
        # возврат раньше него — действие теряло бы и подтверждение, и отмену, а
        # модератор видел бы «сверять не с чем» и решал, что ничего не вышло.
        done = self.changes_banner()
        roads = map_edits.load_roads(edits_tiles_dir(), -90, -180, 90, 180)
        if not roads:
            return page("/changes", "Что изменилось", done +
                        '<div class="empty">Тайлов не видно: RADARMAP_TILES '
                        'указывает не туда, или дороги ещё не публиковались. '
                        'Сверять правки не с чем.</div>')
        decisions = osm_queue.sweep(conn, roads)
        counts = osm_queue.summary(decisions)

        act = esc(u("/changes/act"))

        def button(edit, op, caption, cls=""):
            """Действие одной кнопкой, без диалога подтверждения.

            Подтверждение тормозит на каждой строке и всё равно проматывается
            не глядя. Всё, что здесь делается, обратимо: снятие возвращается,
            метка ставится заново следующей же пересборкой.
            """
            return (f'<form method="post" action="{act}" class="inline">'
                    f'<input type="hidden" name="id" value="{edit["id"]}">'
                    f'<input type="hidden" name="version" value="{edit["version"]}">'
                    f'<input type="hidden" name="op" value="{op}">'
                    f'<button class="{cls}">{esc(caption)}</button></form>')

        def row(decision):
            edit = decision["edit"]
            lat, lon = edit["geom"][1], edit["geom"][0]
            shift = f' · сдвиг {decision["shift"]} м' if decision["shift"] else ""
            place = esc(u("/editor")) + f"#{lat},{lon},19"
            note = esc(edit.get("note") or "")
            actions = button(edit, "withdraw", "Снять", "ghost")
            # «Всё верно» — по МЕТКЕ, а не по вердикту этой сверки. Метку
            # ставит пересадка, и живёт она в заметке: следующая неделя может
            # не найти сдвига вовсе, а метка останется — и снять её будет
            # нечем, то есть счётчик на вкладке не обнулится никогда.
            if (osm_queue.CHECK == decision["verdict"]
                    or map_edits.CHECK_MARK in (edit.get("note") or "")):
                actions = button(edit, "confirm", "Всё верно") + actions
            return (f'<div class="chg"><b>#{edit["id"]}</b> '
                    f'{esc(map_edits.kind_name(edit["kind"]))}{shift} '
                    f'<a href="{place}">на карте</a>{actions}'
                    f'<div class="muted">{note}</div></div>')

        def block(title, verdict, explain):
            rows = [d for d in decisions if d["verdict"] == verdict]
            if not rows:
                return ""
            return (f'<h3>{esc(title)} · {len(rows)}</h3>'
                    f'<div class="muted">{esc(explain)}</div>'
                    + "".join(row(d) for d in rows))

        body = (
            block("OSM догнал нас", osm_queue.CAUGHT_UP,
                  "Рядом с нашей нарисованной дорогой появилась настоящая. "
                  "Дорога, отданная в OSM, поддерживается всем миром, наша — только нами.")
            + block("Правки, потерявшие опору", osm_queue.LOST,
                    "Дорога исчезла или уехала далеко. Автоматика вправе двигать "
                    "объект, но не вправе решать, что он больше не нужен.")
            + block("Пересажены, стоит посмотреть", osm_queue.CHECK,
                    "Подвинули сами, но сдвиг такой, что объект мог оказаться "
                    "не на той стороне.")
            + block("Пересажены молча", osm_queue.RESETTLED,
                    "Сдвиг в пределах обочины: ни полоса, ни сторона перекрёстка "
                    "от такого не меняются.")
        )
        if not body:
            body = (f'<div class="empty">Все {counts.get(osm_queue.KEEP, 0)} правок '
                    'на месте: вокруг них в OSM ничего не изменилось.</div>')
        return page("/changes", "Что изменилось", done + body)

    def changes_banner(self):
        """Что только что сделали и как это отменить.

        Полоски с отменой, как на карте, здесь нет и не нужно: страница
        серверная, без JavaScript, и заводить его ради одной кнопки значило бы
        завести вторую страницу с другими правилами. Ссылка «вернуть» делает то
        же самое и переживает перезагрузку.
        """
        query = parse_qs(urlparse(self.path).query)
        op = (query.get("done") or [""])[0]
        try:
            edit_id = int((query.get("id") or ["0"])[0])
            version = int((query.get("version") or ["0"])[0])
        except ValueError:
            return ""
        if op == "withdraw" and edit_id:
            act = esc(u("/changes/act"))
            return (f'<div class="warn">Снята правка #{edit_id}. '
                    f'<form method="post" action="{act}" class="inline">'
                    f'<input type="hidden" name="id" value="{edit_id}">'
                    f'<input type="hidden" name="version" value="{version}">'
                    f'<input type="hidden" name="op" value="restore">'
                    f'<button>Вернуть</button></form></div>')
        if op == "confirm" and edit_id:
            return f'<div class="warn">Правка #{edit_id} подтверждена.</div>'
        if op == "restore" and edit_id:
            return f'<div class="warn">Правка #{edit_id} возвращена.</div>'
        if op == "stale":
            return ('<div class="warn">Правку изменили в другом окне — '
                    'страница перечитана.</div>')
        return ""

    def changes_action(self, conn, field):
        """Снять, подтвердить или вернуть — одна строка очереди."""
        try:
            edit_id, version = int(field("id")), int(field("version"))
        except ValueError:
            return self._redirect(u("/changes"))
        op = field("op")
        handlers = {"withdraw": map_edits.withdraw,
                    "confirm": map_edits.confirm,
                    "restore": map_edits.restore}
        handler = handlers.get(op)
        if handler is None:
            return self._redirect(u("/changes"))
        if not handler(conn, edit_id, version):
            # Версия устарела: правку изменили в другом окне. Молча
            # перезаписать нельзя — модератор открывает панель и с телефона,
            # и с ноутбука, и второе сохранение затёрло бы первое.
            return self._redirect(u("/changes") + "?done=stale")
        log_action(conn, None, f"changes-{op}", f"#{edit_id}")
        conn.commit()
        self._redirect(u("/changes") +
                       f"?done={op}&id={edit_id}&version={version + 1}")

    def camera_json(self, conn, path):
        try:
            camera_id = int(path.rsplit("/", 1)[1])
        except (IndexError, ValueError):
            return self._json({"error": "bad id"}, 400)
        details = camera_details(conn, camera_id)
        if not details:
            return self._json({"error": "no camera"}, 404)
        self._json(details)

    def move_json(self, conn, data):
        """Перенос с карты. Проверки те же, что у формы, и они ЗДЕСЬ, а не в
        браузере: клиент подсказывает пользователю, а решает сервер."""
        try:
            camera_id = int(data["id"])
            lat, lon = float(data["lat"]), float(data["lon"])
        except (KeyError, TypeError, ValueError):
            return self._json({"error": "bad fields"}, 400)
        camera = cameras().get(camera_id)
        if not camera:
            return self._json({"error": "no camera"}, 404)
        if not (37.0 <= lat <= 46.0 and 55.0 <= lon <= 74.0):
            return self._json({"error": "вне Узбекистана"}, 400)
        moved = haversine(camera["lat"], camera["lon"], lat, lon)
        if moved > MAX_MOVE_METERS:
            # Приложение такую правку всё равно отвергнет — отказываем сразу.
            return self._json({"error": f"дальше {MAX_MOVE_METERS} м"}, 400)
        now = time.time()
        conn.execute("INSERT OR REPLACE INTO overrides"
                     "(camera_id, op, lat, lon, type, note, decided_at, published_at) "
                     "VALUES(?,'move',?,?,NULL,'',?,NULL)", (camera_id, lat, lon, now))
        log_action(conn, camera_id, "move", f"{lat:.6f}, {lon:.6f}")
        self.resolve_reports(conn, camera_id, RESOLVED_DONE)
        conn.commit()
        self._json({"ok": True, "moved": round(moved), "pending": self.pending_count(conn)})

    def undo_json(self, conn, data):
        """Отмена свежего переноса. Правка исчезает целиком — и это же страховка
        от промаха мышью, без которой работать по сотне точек нельзя."""
        try:
            camera_id = int(data["id"])
        except (KeyError, TypeError, ValueError):
            return self._json({"error": "bad fields"}, 400)
        conn.execute("DELETE FROM overrides WHERE camera_id = ?", (camera_id,))
        log_action(conn, camera_id, "undo")
        conn.commit()
        camera = cameras().get(camera_id) or {}
        self._json({"ok": True, "pending": self.pending_count(conn),
                    "origin": [camera.get("lat"), camera.get("lon")]})

    def pending_count(self, conn):
        return conn.execute("SELECT COUNT(*) n FROM overrides "
                            "WHERE published_at IS NULL").fetchone()["n"]

    def cameras_page(self, conn):
        cameras_act = u("/cameras/act")
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
                <form method="post" action="{cameras_act}" class="inline">
                  <input type="hidden" name="camera_id" value="{row['camera_id']}">
                  <button name="action" value="restore">Вернуть камеру</button>
                </form></div>""" for row in overrides.values())
            applied = f"<h1>Действующие правки ({len(overrides)})</h1>{rows}"
        return page("/cameras", "Камеры", f"<h1>Очередь ({len(queue)})</h1>{body}{applied}")

    def mobile_quality(self, conn, now, days=1):
        """Качество краудсорса за окно: сколько отметок дошло до подтверждения
        и сколько было снесено. Без этих двух долей пороги (испытательный срок,
        кворум, штраф за дизлайк) настраиваются вслепую — по ощущению, что
        «вроде работает»."""
        since = now - days * 86400
        total = conn.execute("SELECT COUNT(*) FROM reports WHERE created > ?",
                             (since,)).fetchone()[0]
        if not total:
            return None
        confirmed = conn.execute(
            "SELECT COUNT(*) FROM reports r WHERE r.created > ? AND EXISTS("
            "  SELECT 1 FROM votes v WHERE v.report_id = r.id AND v.value = 1 "
            "  AND v.device != r.device AND v.ip != '' AND v.ip != r.ip)",
            (since,)).fetchone()[0]
        by_reason = dict(conn.execute(
            "SELECT COALESCE(closed, ''), COUNT(*) FROM reports WHERE created > ? "
            "GROUP BY 1", (since,)).fetchall())
        return {"total": total, "confirmed": confirmed,
                "quorum": by_reason.get("quorum", 0),
                "author": by_reason.get("author", 0),
                "moderator": by_reason.get("moderator", 0),
                "blocked": by_reason.get("blocked", 0)}

    def mobile_page(self, conn):
        mobile_act = u("/mobile/act")
        now = time.time()
        rows = conn.execute("""
            SELECT r.id, r.lat, r.lon, r.type, r.created, r.expires, r.up, r.down, r.ip,
                   r.device, r.cls,
                   (SELECT COUNT(DISTINCT v.ip) FROM votes v
                     WHERE v.report_id = r.id AND v.ip != '') AS vote_ips,
                   (SELECT COUNT(*) FROM votes v
                     WHERE v.report_id = r.id AND v.value = -1 AND v.kind = 'pass')
                     AS pass_no,
                   (SELECT COUNT(*) FROM votes v
                     WHERE v.report_id = r.id AND v.kind = 'misplaced') AS misplaced,
                   (SELECT COUNT(*) FROM reports o
                     WHERE o.ip = r.ip AND r.ip != '' AND o.created > ?) AS from_ip
            FROM reports r WHERE r.active = 1 AND r.expires > ?
            ORDER BY r.created DESC""", (now - 86400, now)).fetchall()

        quality = self.mobile_quality(conn, now)
        summary = ""
        if quality:
            share = round(100 * quality["confirmed"] / quality["total"])
            summary = (f'<div class="card"><b>За сутки:</b> отметок {quality["total"]}'
                       f' · подтверждено независимо {quality["confirmed"]} ({share}%)'
                       f' · снято кворумом {quality["quorum"]}'
                       f' · отозвано авторами {quality["author"]}'
                       f' · убрано вручную {quality["moderator"]}'
                       f' · не опубликовано (бан) {quality["blocked"]}</div>')

        blocks = conn.execute(
            "SELECT kind, value, until, note FROM blocked WHERE until > ? ORDER BY until DESC",
            (now,)).fetchall()
        blocked_html = ""
        if blocks:
            items = "".join(
                f'<div class="row"><span class="tag bad">{esc(b["kind"])}</span>'
                f'<code>{esc(b["value"])}</code>'
                f'<span class="muted">ещё {int((b["until"] - now) // 3600)} ч ·'
                f' {esc(b["note"] or "без причины")}</span>'
                f'<form method="post" action="{mobile_act}">'
                f'<input type="hidden" name="block_kind" value="{esc(b["kind"])}">'
                f'<input type="hidden" name="block_value" value="{esc(b["value"])}">'
                f'<button name="action" value="unblock">Снять</button></form></div>'
                for b in blocks)
            blocked_html = f'<div class="card"><b>Блокировки ({len(blocks)})</b>{items}</div>'

        if not rows:
            return page("/mobile", "Передвижные",
                        f'{summary}{blocked_html}<div class="empty">Живых отметок нет</div>')
        cards = []
        for row in rows:
            # Голоса с одного адреса — это один человек, а не кворум. Показываем
            # оба числа рядом: расхождение и есть признак накрутки.
            suspicious = (row["up"] or 0) >= 3 and (row["vote_ips"] or 0) <= 1
            # Дизлайк ПОСЛЕ реального проезда весит больше тапа из карточки:
            # человек был на месте и не увидел радара.
            pass_no = row["pass_no"] or 0
            misplaced = row["misplaced"] or 0
            from_ip = row["from_ip"] or 0
            flags = ""
            if pass_no:
                flags += (f'<span class="tag bad">проехали и не увидели: {pass_no}</span>')
            if misplaced:
                flags += f'<span class="tag bad">стоит не там: {misplaced}</span>'
            if from_ip >= 5:
                flags += f'<span class="tag bad">с этого адреса за сутки: {from_ip}</span>'
            cards.append(f"""<div class="card">
  <div class="row"><b>{esc(row['type'] or 'radar')}</b>
    <span class="tag">+{row['up']} / −{row['down']}</span>
    <span class="tag {'bad' if suspicious else ''}">адресов среди голосов: {row['vote_ips']}</span>
    {'<span class="tag bad">похоже на накрутку</span>' if suspicious else ''}{flags}</div>
  <div class="muted">поставлена {esc(ago(row['created']))} ·
    исчезнет через {int(max(0, row['expires'] - now) // 60)} мин ·
    {esc(row['cls'] or 'класс дороги неизвестен')} · {osm_link(row['lat'], row['lon'])}</div>
  <form method="post" action="{mobile_act}">
    <input type="hidden" name="id" value="{row['id']}">
    <button class="danger" name="action" value="kill">Убрать с карты</button>
    <button name="action" value="extend">Продлить на 3 ч</button>
    <button class="danger" name="action" value="block">Заблокировать источник на сутки</button>
  </form></div>""")
        return page("/mobile", "Передвижные",
                    f"{summary}{blocked_html}<h1>Живые отметки ({len(rows)})</h1>"
                    f"{''.join(cards)}")

    def feedback_page(self, conn):
        feedback_act = u("/feedback/act")
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
  <form method="post" action="{feedback_act}" style="margin-top:6px">
    <input type="hidden" name="id" value="{row['id']}">
    <select name="status">{options}</select>
    <input name="note" value="{esc(row['note'])}" placeholder="заметка" size="24">
    <button class="primary" name="action" value="save">Сохранить</button>
  </form></div>""")
        new_count = sum(1 for row in rows if row["status"] == "new")
        return page("/feedback", "Обращения",
                    f"<h1>Обращения ({new_count} новых из {len(rows)})</h1>{''.join(cards)}")

    def usage_page(self, conn):
        """Воронка и активность. Главная цифра здесь — доля «Всегда»: без этого
        разрешения не работают ни фоновые оповещения, ни автостарт поездки,
        то есть половина продукта, и если её выдаёт меньшинство, то экран
        объяснения важнее любой новой функции."""
        now = time.time()
        window = now - 30 * DAY
        rows = conn.execute(
            "SELECT device, day, app, ios, model, location_auth, onboarded, "
            "trips, km, alerts, passes, reports FROM usage_stats WHERE received > ?",
            (window,)).fetchall()
        if not rows:
            return page("/usage", "Люди", '<div class="empty">Отчётов пока нет. '
                        'Они приходят раз в сутки и только с версий, где включена '
                        'отправка статистики.</div>')

        # По устройству берём ПОСЛЕДНИЙ известный статус: разрешение меняется,
        # и считать по всем строкам значило бы считать один телефон много раз.
        latest, totals = {}, {"trips": 0, "km": 0.0, "alerts": 0,
                              "passes": 0, "reports": 0}
        active_days = {}
        for row in rows:
            latest[row["device"]] = row
            for key in ("trips", "alerts", "passes", "reports"):
                totals[key] += row[key] or 0
            totals["km"] += row["km"] or 0
            active_days[row["device"]] = active_days.get(row["device"], 0) + 1

        devices = len(latest)
        onboarded = sum(1 for r in latest.values() if r["onboarded"])
        auth = {}
        versions = {}
        models = {}
        for row in latest.values():
            auth[row["location_auth"] or "?"] = auth.get(row["location_auth"] or "?", 0) + 1
            versions[row["app"] or "?"] = versions.get(row["app"] or "?", 0) + 1
            models[row["model"] or "?"] = models.get(row["model"] or "?", 0) + 1
        drivers = sum(1 for d, r in latest.items() if (r["trips"] or 0) > 0)
        loyal = sum(1 for count in active_days.values() if count >= 7)

        def share(count):
            return f"{count} · {100 * count / devices:.0f}%" if devices else "0"

        always = auth.get("always", 0)
        always_tone = "t-warn" if devices and always / devices < 0.5 else ""

        def rows_of(mapping, limit=6):
            return " ".join(
                f'<span class="tag">{esc(name)}: {count}</span>'
                for name, count in sorted(mapping.items(), key=lambda kv: -kv[1])[:limit])

        return page("/usage", "Люди", f"""
<h1>Воронка за 30 дней</h1>
<div class="row">
  <div class="card" style="flex:1 1 140px"><div class="big">{devices}</div>
    <div class="muted">устройств прислали отчёт</div></div>
  <div class="card" style="flex:1 1 140px"><div class="big">{esc(share(onboarded))}</div>
    <div class="muted">прошли онбординг</div></div>
  <div class="card" style="flex:1 1 140px">
    <div class="big {always_tone}">{esc(share(always))}</div>
    <div class="muted">дали геолокацию «Всегда»</div></div>
  <div class="card" style="flex:1 1 140px"><div class="big">{esc(share(drivers))}</div>
    <div class="muted">хоть раз поехали</div></div>
  <div class="card" style="flex:1 1 140px"><div class="big">{esc(share(loyal))}</div>
    <div class="muted">пользуются неделю и дольше</div></div>
</div>
<div class="card"><div class="muted">Разрешение геолокации: {rows_of(auth)}</div>
  <div class="muted" style="margin-top:6px">Без «Всегда» не работают фоновые
  оповещения и автостарт поездки — это половина продукта.</div></div>

<h1>Чем пользуются</h1>
<div class="card"><div class="row">
  <span class="tag">поездок: {totals['trips']}</span>
  <span class="tag">километров: {totals['km']:.0f}</span>
  <span class="tag">оповещений: {totals['alerts']}</span>
  <span class="tag">проездов камер: {totals['passes']}</span>
  <span class="tag">отметок и жалоб: {totals['reports']}</span>
</div></div>

<h1>На чём</h1>
<div class="card"><div class="muted">Версии: {rows_of(versions)}</div>
  <div class="muted" style="margin-top:6px">Модели: {rows_of(models, limit=8)}</div></div>
<div class="card"><div class="muted">Ни координат, ни маршрутов, ни времени
событий здесь нет и быть не может — только счётчики за сутки. Идентификатор
ротируется раз в 30 дней.</div></div>""")

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
    ensure_api_tables()
    if "--export" in sys.argv:
        index = sys.argv.index("--export")
        version = int(sys.argv[index + 1]) if len(sys.argv) > index + 1 else 1
        print(json.dumps(export_overrides(version), ensure_ascii=False, separators=(",", ":")))
        return
    if "--sweep" in sys.argv:
        index = sys.argv.index("--sweep")
        tiles = sys.argv[index + 1] if len(sys.argv) > index + 1 else edits_tiles_dir()
        print(sweep_edits(tiles))
        return
    if "--export-edits" in sys.argv:
        print(json.dumps(export_edits(), ensure_ascii=False, separators=(",", ":")))
        return
    if "--set-password" in sys.argv:
        print(admin_auth.set_password_interactively())
        return
    if "--mark-published" in sys.argv:
        index = sys.argv.index("--mark-published")
        version = int(sys.argv[index + 1])
        print(f"помечено опубликованными: {mark_published(version)}")
        return
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
