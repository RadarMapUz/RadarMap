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
    python3 admin.py --add-person <имя>   # завести человека (пароль спросит)
    python3 admin.py --drop-person <имя>  # убрать человека
    python3 admin.py --people             # кто может войти
"""
import html
import json
import os
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.error
import urllib.parse
import urllib.request
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


def log_action(conn, camera_id, action, detail="", who=""):
    """Запись в журнал решений.

    `who` — кто это сделал. Раньше журнал писал «edit-withdraw #5», и на
    вопрос «кто снял» ответить было нечем: пароль один, значит все действия
    одинаковы и безымянны. Имя дописывается к подробностям, а не отдельной
    колонкой: у таблицы есть читатели постарше этого изменения, и менять её
    форму ради одного поля дороже, чем оно стоит.
    """
    if who:
        detail = f"{detail} · {who}".strip(" ·")
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
.past { flex-basis:100%; }
.past summary { cursor:pointer; font-size:12px; color:var(--muted); }
.past .muted { font-size:12px; padding-left:14px; }
.chg .pick { width:16px; height:16px; margin:0 6px 0 0; accent-color:#3cdcff; }
/* Поиск и пачка. Очередь читают, ища конкретное, а не подряд: без поиска
   двадцатая строка находится только глазами. */
.bulk { display:flex; gap:8px; align-items:center; margin:0 0 12px; flex-wrap:wrap; }
.bulk .find { flex:1 1 220px; padding:9px 11px; border-radius:10px;
  border:1px solid #2b3038; background:#12161d; color:#e7e9ee; font-size:14px; }
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
        ("/usage", "Люди"), ("/journal", "Журнал"), ("/health", "Здоровье"))

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
        # Имя необязательно: так входили до появления учётных записей, и
        # пустое поле по-прежнему означает владельца. Требовать его сразу
        # значило бы выкинуть из панели единственного человека при обновлении.
        form = (f'<form method="post" action="{u("/login")}">'
                '<input type="text" name="name" placeholder="Имя (пусто — владелец)" '
                'autocomplete="username">'
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


def static_url(name):
    """Адрес скрипта со СЛЕПКОМ его содержимого.

    Без метки версии браузер модератора продолжает выполнять вчерашний файл:
    адрес не изменился, значит можно взять из кэша. Выкатили исправление —
    а панель у человека ведёт себя по-старому, и понять это со стороны нельзя
    вовсе. Метка от времени правки файла: меняется ровно тогда, когда меняется
    сам файл.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static", name)
    try:
        stamp = int(os.path.getmtime(path))
    except OSError:
        stamp = 0
    return u(f"/static/{name}") + f"?v={stamp}"


def render_moderation_map(api_key, pending, camera_count):
    logout_url, moderate_js = u("/logout"), static_url("moderate.js")
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

# Палитра конструктора рисуется, а не подписывается.
#
# Список слов «Проспект / Улица / Жилая / Проезд» требует помнить, чем они
# отличаются, — а отличаются они ШИРИНОЙ И РАЗМЕТКОЙ, то есть ровно тем, что
# видно с одного взгляда. Тона здесь те же, что у полотна на схеме и на
# телефоне: выбранное в палитре и легшее на карту должны совпадать, иначе
# палитра обещает не то, что делает.
ROAD_ICONS = {
    3: """<svg viewBox="0 0 48 28"><rect x="0" y="4" width="48" height="20"
rx="2" fill="#5e5d58"/><path d="M0 11h48M0 17h48" stroke="#7d7c74"
stroke-width="1"/><path d="M0 14h48" stroke="#e0d9b8" stroke-width="1.6"
stroke-dasharray="6 5"/></svg>""",
    4: """<svg viewBox="0 0 48 28"><rect x="0" y="7" width="48" height="14"
rx="2" fill="#525252"/><path d="M0 14h48" stroke="#e0d9b8" stroke-width="1.4"
stroke-dasharray="5 5"/></svg>""",
    6: """<svg viewBox="0 0 48 28"><rect x="0" y="9" width="48" height="10"
rx="2" fill="#464646"/></svg>""",
    7: """<svg viewBox="0 0 48 28"><rect x="0" y="11" width="48" height="6"
rx="2" fill="#3c3c3c"/></svg>""",
}

PROP_ICONS = {
    # Полосы: их считают, поэтому на значке они разделены.
    "lanes": """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48"
height="18" rx="2" fill="#525252"/><path d="M0 11h48M0 17h48" stroke="#cfcabb"
stroke-width="1" stroke-dasharray="4 4"/></svg>""",
    # Направления: стрелки полос — то самое, что рисуется на асфальте.
    "turn_lanes": """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48"
height="18" rx="2" fill="#525252"/><g stroke="#e8e8e8" stroke-width="1.5"
fill="none" stroke-linecap="round"><path d="M10 21v-7l-3 3M10 14l3 3"/>
<path d="M24 21v-9"/><path d="M38 21v-6l3 3M38 15l-3 3"/></g></svg>""",
    "u_turn": """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48"
height="18" rx="2" fill="#525252"/><path d="M18 21v-6a6 6 0 0 1 12 0v6"
stroke="#e8e8e8" stroke-width="1.8" fill="none"/><path d="M27 18l3 4 3-4"
fill="#e8e8e8"/></svg>""",
}

POINT_ICONS = {
    1: """<svg viewBox="0 0 48 28"><rect x="18" y="2" width="12" height="24"
rx="3" fill="#1b1f26" stroke="#3a4250"/><circle cx="24" cy="8" r="3"
fill="#ff4d4f"/><circle cx="24" cy="14" r="3" fill="#ffb020"/>
<circle cx="24" cy="20" r="3" fill="#38e58c"/></svg>""",
    5: """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48" height="18"
rx="2" fill="#4a4a4a"/><g fill="#f2f2f2"><rect x="6" y="7" width="5"
height="14"/><rect x="16" y="7" width="5" height="14"/><rect x="26" y="7"
width="5" height="14"/><rect x="36" y="7" width="5" height="14"/></g></svg>""",
    3: """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48" height="18"
rx="2" fill="#4a4a4a"/><rect x="20" y="5" width="6" height="18"
fill="#f2f2f2"/></svg>""",
    4: """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48" height="18"
rx="2" fill="#4a4a4a"/><path d="M16 22V14a8 8 0 0 1 16 0v8" stroke="#ffb020"
stroke-width="2" fill="none"/><path d="M28 19l4 5 4-5" fill="#ffb020"/></svg>""",
    2: """<svg viewBox="0 0 48 28"><rect x="0" y="5" width="48" height="18"
rx="2" fill="#4a4a4a"/><path d="M12 19a12 8 0 0 1 24 0z" fill="#ffb020"/>
<path d="M12 19h24" stroke="#0d1116" stroke-width="1.5"/></svg>""",
}

AREA_ICONS = {
    # Дом — не заливка, а контур с крышей: он обводится по одному, а не
    # массивом, и на плитке должен читаться как «здание», а не как «зона».
    6: """<svg viewBox="0 0 48 28"><path d="M14 24V12l10-6 10 6v12z"
fill="#212430" stroke="#3a4250" stroke-width="1.5"
stroke-linejoin="round"/></svg>""",
    2: """<svg viewBox="0 0 48 28"><rect x="2" y="3" width="44" height="22"
rx="5" fill="#1d3a24" stroke="#2f6b3c"/></svg>""",
    1: """<svg viewBox="0 0 48 28"><rect x="2" y="3" width="44" height="22"
rx="5" fill="#16324a" stroke="#2b6285"/></svg>""",
    4: """<svg viewBox="0 0 48 28"><rect x="2" y="3" width="44" height="22"
rx="5" fill="#1a1d22" stroke="#343a44"/></svg>""",
}

LOCK_ICON = """<svg viewBox="0 0 48 28"><circle cx="24" cy="14" r="11"
fill="#ffb02022" stroke="#ffb020" stroke-width="2"
stroke-dasharray="4 3"/></svg>"""


SELECT_ICON = """<svg viewBox="0 0 48 28"><path d="M20 5l11 16h-6l-2 5z"
fill="#cfd6e3" stroke="#0b0e13" stroke-width="1.2"
stroke-linejoin="round"/></svg>"""


def tool_button(icon, name, key, attrs, extra=""):
    """Плитка палитры: рисунок, имя, клавиша.

    Клавиша ПОКАЗАНА, а не спрятана в справке снизу. Конструктором работают
    двумя руками — левая на клавиатуре, правая на мыши, — и подсмотреть букву
    надо там же, где выбирают инструмент.
    """
    chip = f'<span class="key">{esc(key)}</span>' if key else ""
    return (f'<button class="tool{extra}" {attrs}><span class="ico">{icon}</span>'
            f'<span class="lbl">{esc(name)}</span>{chip}</button>')


# Поиск и выбор в очереди. Скрипт страницей, а не файлом: он в двадцать строк
# и живёт ровно на одной странице; отдельный файл здесь стоил бы запроса и
# ещё одного места, где можно забыть обновить версию.
CHANGES_JS = """<script>
(function () {
  const rows = Array.prototype.slice.call(document.querySelectorAll('.chg'));
  const find = document.getElementById('qfind');
  const picked = document.getElementById('picked');
  const all = document.getElementById('pickall');
  function count() {
    const n = rows.filter(function (row) {
      const box = row.querySelector('.pick');
      return box && box.checked && row.style.display !== 'none';
    }).length;
    picked.textContent = n ? 'выбрано ' + n : '';
  }
  if (find) {
    find.addEventListener('input', function () {
      const want = find.value.trim().toLowerCase();
      rows.forEach(function (row) {
        row.style.display = !want || row.textContent.toLowerCase().indexOf(want) >= 0
          ? '' : 'none';
      });
      count();
    });
  }
  if (all) {
    all.addEventListener('click', function () {
      const visible = rows.filter(function (row) { return row.style.display !== 'none'; });
      const turnOn = visible.some(function (row) {
        const box = row.querySelector('.pick');
        return box && !box.checked;
      });
      visible.forEach(function (row) {
        const box = row.querySelector('.pick');
        if (box) { box.checked = turnOn; }
      });
      count();
    });
  }
  rows.forEach(function (row) {
    const box = row.querySelector('.pick');
    if (box) { box.addEventListener('change', count); }
  });
})();
</script>"""


def mvt_stamp():
    """Когда в последний раз менялось дерево MVT. 0 — его ещё нет."""
    root = os.path.join(edits_tiles_dir() or "", "mvt")
    newest = 0
    for folder, _dirs, files in os.walk(root):
        for name in files:
            try:
                newest = max(newest, int(os.path.getmtime(
                    os.path.join(folder, name))))
            except OSError:
                continue
        # Дерево тайлов — тысячи файлов; на метку хватает первой сотни, а
        # обход целиком стоил бы полсекунды на каждое открытие страницы.
        if newest:
            break
    return newest


def render_editor_gl():
    """Панель на MapLibre — рядом с рабочей, за флагом.

    Переход на векторный стек делается ПАРАЛЛЕЛЬНО, а не заменой: конструктор
    — единственный инструмент разметки, и если он неделю ведёт себя странно,
    встаёт вся работа по картам. Обе панели работают одновременно, картинки
    сравниваются на одних и тех же местах, откат — это адрес.

    Чужих источников на странице нет вовсе: библиотека лежит своим файлом,
    тайлы свои, спутника пока нет. Ровно поэтому CSP здесь строже, чем у
    рабочей панели, а не мягче.
    """
    logout_url = u("/logout")
    # Метка сборки в адресе тайла. Без неё браузер модератора показывает
    # вчерашнюю карту после публикации и не спрашивает сервер: адрес тот же,
    # значит можно взять из кэша. Понять это со стороны нельзя вовсе.
    stamp = mvt_stamp()
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Конструктор на MapLibre</title>
<link rel="stylesheet" href="{static_url("vendor/maplibre-gl.css")}">
<style>
 html,body{{margin:0;height:100%;background:#0e1013;color:#e8e8e8;
   font:14px/1.4 -apple-system,Segoe UI,Roboto,sans-serif}}
 #map{{position:absolute;inset:0}}
 .bar{{position:absolute;left:12px;top:12px;z-index:5;display:flex;gap:8px;
   align-items:center;background:#161a20cc;border:1px solid #2a2f38;
   border-radius:10px;padding:8px 12px;backdrop-filter:blur(6px)}}
 .bar a{{color:#8ab4f8;text-decoration:none}}
 .bar b{{font-weight:600}}
 .note{{position:absolute;right:12px;bottom:12px;z-index:5;max-width:360px;
   background:#161a20cc;border:1px solid #2a2f38;border-radius:10px;
   padding:10px 12px;color:#9aa3af}}
 #count{{color:#9aa3af}}
 #find{{background:#0e1013;border:1px solid #2a2f38;border-radius:8px;
   color:#e8e8e8;padding:6px 10px;width:190px;font:inherit}}
 .found{{position:absolute;left:12px;top:56px;z-index:6;min-width:260px;
   background:#161a20f2;border:1px solid #2a2f38;border-radius:10px;
   overflow:hidden}}
 .found button{{display:block;width:100%;text-align:left;background:none;
   border:0;color:#e8e8e8;padding:8px 12px;font:inherit;cursor:pointer}}
 .found button:hover{{background:#1f2530}}
</style></head><body>
<div id="map" data-stamp="{stamp}"></div>
<div class="bar">
  <b>MapLibre</b>
  <input id="find" type="search" placeholder="улица и дом" autocomplete="off">
  <span id="count">каркас</span>
  <a id="same" href="{u("/editor")}">та же точка в рабочей</a>
  <a href="{logout_url}">выйти</a>
</div>
<div id="found" class="found" hidden></div>
<div class="note">
<b>Q W E R</b> — рисовать дорогу · <b>H</b> — обвести дом ·
<b>1</b> — полосы · <b>A</b> светофор, <b>S</b> переход, <b>D</b> стоп-линия,
<b>F</b> разворот, <b>G</b> лежачий.<br>
<b>Enter</b> закончить · <b>Esc</b> отменить · <b>Backspace</b> убрать вершину.
Вершину можно тянуть — узел поедет со всеми улицами.</div>
<script src="{static_url("vendor/maplibre-gl.js")}"></script>
<script src="{static_url("editor_gl.js")}"></script>
</body></html>"""


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
#map{{position:absolute;inset:52px 0 0 0;background:#0e1013}}
/* Земля своей карты.
   Красить контейнер бесполезно: ymaps кладёт поверх свою панель со СВОЕЙ
   светлой картинкой-фоном (тот самый «в клеточку»), и наша ночная схема
   выходила чёрным по белому. Гасим картинку и задаём цвет там, где он
   действительно виден. Селектор по куску класса, а не по версии: версия
   библиотеки в имени класса и меняется вместе с ней. */
#map ymaps[class*="i-ua_js"], #map ymaps[class$="ground-pane"]
{{background-image:none;background-color:#0e1013}}
.tools{{position:absolute;top:64px;left:12px;z-index:4;display:flex;gap:8px;
flex-direction:column;width:260px;max-height:calc(100vh - 88px);overflow:auto}}
.tool{{display:flex;align-items:center;gap:10px;padding:7px 10px;
border-radius:10px;border:1px solid #2b3038;background:#12161df2;color:#8ea0bb;
font-size:13px;cursor:pointer;text-align:left}}
.tool.on{{background:#101f2e;color:#3cdcff;border-color:#17384d}}
.tool:hover{{border-color:#3a4453}}
.ico{{flex:0 0 auto;width:48px;height:28px;border-radius:6px;overflow:hidden;
background:#0b0e13;display:block}}
.ico svg{{display:block;width:48px;height:28px}}
.lbl{{flex:1 1 auto}}
.key{{flex:0 0 auto;font-size:11px;color:#5d6b80;border:1px solid #2b3038;
border-radius:5px;padding:1px 6px}}
.tool.on .key{{color:#3cdcff;border-color:#17384d}}
/* Холст выбирается наверху и одним движением. Своя карта отвечает на вопрос
   «что увидит водитель», спутник — «где объект стоит на самом деле»;
   переключаться приходится ежеминутно, и прятать это в клавишу нельзя. */
.views{{display:flex;gap:6px;background:#12161df2;border:1px solid #232a35;
border-radius:10px;padding:4px}}
.view{{flex:1;padding:8px 10px;border-radius:8px;border:0;background:transparent;
color:#8ea0bb;font-size:13px;cursor:pointer}}
.view.on{{background:#101f2e;color:#3cdcff}}
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
.find{{width:100%;padding:10px 12px;border-radius:10px;border:1px solid #2b3038;
background:#12161df2;color:#e7e9ee;font-size:14px}}
.found{{background:#12161df2;border:1px solid #232a35;border-radius:10px;
overflow:hidden}}
.found button{{display:block;width:100%;margin:0;text-align:left;padding:9px 11px;
font-size:12px;background:transparent;border:0;border-bottom:1px solid #1b2231;
color:#8ea0bb;border-radius:0}}
.found button:hover{{background:#182029;color:#e7e9ee}}
.toolrow{{display:flex;gap:8px;flex-direction:column}}
.toolrow.draw{{padding:8px}}
.card select{{width:100%;margin-top:4px;padding:9px 11px;border-radius:9px;
border:1px solid #2b3038;background:#0d1116;color:#e7e9ee;font-size:14px}}
.work{{background:#12161de6;border:1px solid #232a35;border-radius:10px}}
.work summary{{padding:9px 11px;font-size:12px;color:#8ea0bb;cursor:pointer;
list-style:none}}
.work summary::-webkit-details-marker{{display:none}}
.work[open] summary{{border-bottom:1px solid #1b2231}}
.todo{{max-height:42vh;overflow:auto;padding:8px}}
.todo-row{{display:block;width:100%;text-align:left;margin-top:4px;padding:6px 8px;
border:1px solid #232a35;border-radius:8px;background:#0d1116;color:#8ea0bb;
font-size:12px;cursor:pointer;line-height:1.35}}
.todo-row:hover{{background:#182029;color:#e7e9ee}}
.todo-row.on{{border-color:#17384d;color:#3cdcff}}
.todo-row.draft{{border-left:3px solid #ffb020}}
.todo-row.done{{border-left:3px solid #2f6b3c;color:#6f8299}}

/* Телефон. Это ОСНОВНОЙ сценарий, а не запасной: очередь разбирают в дороге и
   в перерыве. На столе панель инструментов слева стоит на месте, а на экране
   в четыреста точек она съедает половину карты — и работать становится не
   с чем.

   Поэтому инструменты уезжают вниз одной строкой (большой палец достаёт до
   низа, а не до верха), карточка становится листом снизу вверх, а очередь
   складывается — её открывают, когда ищут работу, а не когда её делают. */
@media (max-width:700px) {{
  /* Потолок высоты обязателен. Без него панель инструментов со всеми
     раскрытыми списками занимает экран целиком и закрывает карту — то есть
     ровно то, ради чего её открыли. */
  .tools{{position:absolute;top:auto;left:8px;right:8px;bottom:8px;width:auto;
          max-height:52vh;overflow:auto;gap:6px}}
  .toolrow{{flex-direction:row;overflow-x:auto;scrollbar-width:none}}
  .toolrow::-webkit-scrollbar{{display:none}}
  .tool{{flex:0 0 auto;font-size:15px;padding:12px 14px}}
  .keyhelp{{display:none}}
  .todo{{max-height:30vh}}
  /* Свёрнутые списки на телефоне — одна строка вместо шести кнопок. */
  .work summary{{padding:11px}}
  #map{{inset:52px 0 0 0}}
  .card{{top:auto;left:0;right:0;bottom:0;width:auto;border-radius:16px 16px 0 0;
         max-height:72vh;overflow:auto;padding:16px}}
  .card input{{padding:12px;font-size:16px}}
  .card button{{width:100%;margin:10px 0 0;padding:13px;font-size:16px}}
  .card button.pick{{padding:14px;font-size:15px}}
  .toast{{left:8px;right:8px;bottom:auto;top:60px;transform:none;
          justify-content:space-between}}
}}
</style></head>
<body><header>{"".join(
    f'<a href="{esc(u(path))}" class="{"on" if path == "/editor" else ""}">{esc(name)}</a>'
    for path, name in TABS)}<a href="{logout_url}" class="out">Выход</a></header>
<div id="map"></div>
<div class="tools" data-base="{esc(u(''))}" data-drafts="{drafts}">
  <input id="find" class="find" placeholder="Место, «41.31, 69.28» или «#12»"
         autocomplete="off" enterkeyhint="search">
  <div class="found" id="found" hidden></div>
  <div class="views">
    <button id="viewschema" class="view on">Своя карта</button>
    <button id="viewsat" class="view">Спутник</button>
  </div>
  <div class="toolrow">
    {tool_button(SELECT_ICON, "Выбрать", "V", 'data-kind="select"', " on")}
    {tool_button(PROP_ICONS["lanes"], "Полосы", "1", 'data-kind="lanes"')}
    {tool_button(PROP_ICONS["turn_lanes"], "Направления", "2",
                 'data-kind="turn_lanes"')}
    {tool_button(PROP_ICONS["u_turn"], "Разворот", "3", 'data-kind="u_turn"')}
  </div>
  <details class="work" id="drawbox" open>
    <summary>Нарисовать дорогу</summary>
    <div class="toolrow draw">
      {tool_button(ROAD_ICONS[3], "Проспект", "Q",
                   'data-kind="geometry" data-cls="3"')}
      {tool_button(ROAD_ICONS[4], "Улица", "W",
                   'data-kind="geometry" data-cls="4"')}
      {tool_button(ROAD_ICONS[6], "Жилая", "E",
                   'data-kind="geometry" data-cls="6"')}
      {tool_button(ROAD_ICONS[7], "Проезд", "R",
                   'data-kind="geometry" data-cls="7"')}
    </div>
  </details>
  <details class="work" id="pointbox" open>
    <summary>Поставить обстановку</summary>
    <div class="toolrow draw">
      {tool_button(POINT_ICONS[1], "Светофор", "A",
                   'data-kind="point" data-point="1"')}
      {tool_button(POINT_ICONS[5], "Переход", "S",
                   'data-kind="point" data-point="5"')}
      {tool_button(POINT_ICONS[3], "Стоп-линия", "D",
                   'data-kind="point" data-point="3"')}
      {tool_button(POINT_ICONS[4], "Разворот", "F",
                   'data-kind="point" data-point="4"')}
      {tool_button(POINT_ICONS[2], "Лежачий", "G",
                   'data-kind="point" data-point="2"')}
    </div>
  </details>
  <div class="legend cover" id="cover"></div>
  <details class="work" id="landbox" open>
    <summary>Обвести дом и местность</summary>
    <div class="toolrow draw">
      {tool_button(AREA_ICONS[6], "Дом", "H", 'data-kind="area" data-area="6"')}
      {tool_button(AREA_ICONS[2], "Зелень", "", 'data-kind="area" data-area="2"')}
      {tool_button(AREA_ICONS[1], "Вода", "", 'data-kind="area" data-area="1"')}
      {tool_button(AREA_ICONS[4], "Квартал", "", 'data-kind="area" data-area="4"')}
    </div>
  </details>
  <details class="work" id="areabox">
    <summary>Отметить своё</summary>
    <div class="toolrow draw">
      {tool_button(LOCK_ICON, "Размечено руками", "Z", 'data-kind="lock"')}
    </div>
    <div class="legend">Внутри размеченной области воскресная пересборка
      смотрит и докладывает, но ничего не двигает сама.</div>
  </details>
  <div class="legend" id="hint">Черновиков: {drafts}. Клик по дороге ставит
    объект, клик по объекту — правит. Панель ничего не публикует.</div>
  <div class="legend keyhelp">V выбрать · 1–3 свойства · Q W E R дорога ·
    Ctrl+D не примыкать · H дом ·
    A S D F G обстановка · Z разметить область ·
    Enter закончить · Backspace снять вершину ·
    Delete убрать вершину · Esc отменить · Ctrl+Z вернуть ·
    \\ схема ⇄ спутник · ] [ по очереди</div>
  <details class="work" id="work">
    <summary id="worksum">Здесь работать</summary>
    <div class="todo" id="todo"></div>
  </details>
</div>
<aside class="card" id="card" hidden></aside>
<div class="toast" id="toast"></div>
<script src="https://api-maps.yandex.ru/2.1/?apikey={esc(api_key)}&lang=ru_RU"></script>
<script src="{esc(static_url('editor.js'))}"></script>
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
    if not os.path.isdir(tiles_dir or ""):
        return "правки не сверялись: тайлов по указанному пути нет"
    conn = db()
    try:
        map_edits.ensure_tables(conn)
        # Вокруг каждой правки, а не по всей земле: сборка запускается на той
        # же машине, где живёт панель, и «дай все дороги» съедало бы её память
        # ровно тогда, когда она нужна сборке.
        decisions = osm_queue.sweep(conn, tiles_dir=tiles_dir)
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
    # Отметку о публикации ставит НЕ человек в панели, а команда владельца
    # с его машины. Имени вошедшего здесь нет и быть не может.
    log_action(conn, None, "publish", f"версия {version}, новых правок {count}",
               who="публикация")
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
    # Страница на MapLibre. Чужих источников тут нет вовсе: библиотека лежит
    # своим файлом, тайлы — свои, шрифтов и спутника пока нет.
    #
    # blob: обязателен и не является послаблением «на всякий случай»: MapLibre
    # поднимает свои воркеры из blob-URL, и без worker-src карта не рисует
    # ничего, молча. img-src blob: — по той же причине, там живут текстуры.
    # Спутник — ЕДИНСТВЕННЫЙ чужой источник на странице, и это неизбежно:
    # своих снимков у нас нет и не будет, съёмка города — отдельный бизнес.
    #
    # Спутник Яндекса под MapLibre брать НЕЛЬЗЯ — это их условия, а не наша
    # осторожность. Esri World Imagery правообладатель разрешил использовать
    # для обводки в OSM явно; именно её показывают iD и JOSM. Окончательное
    # решение по лицензии — за владельцем, здесь только техническая часть.
    #
    # Открыт ровно один хост и ровно для картинок: скрипты по-прежнему только
    # свои, потому что на этой странице лежит сессия модератора.
    SATELLITE = "https://server.arcgisonline.com"
    CSP_GL = ("default-src 'none'; form-action 'self'; "
              "script-src 'self'; worker-src blob:; child-src blob:; "
              "style-src 'self' 'unsafe-inline'; "
              f"img-src 'self' data: blob: {SATELLITE}; "
              f"connect-src 'self' {SATELLITE}; "
              "font-src 'self'")
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

    def _send(self, code, body, content_type="text/html; charset=utf-8", csp=None,
              extra=None):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for header, value in (extra or {}).items():
            self.send_header(header, value)
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
        who = admin_auth.who_signs_in(field("name"), field("password"))
        if who:
            SESSIONS.note_success(address)
            token = SESSIONS.issue(name=who)
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
        # «Имя или пароль», а не «неверный пароль»: иначе форма отвечает,
        # существует ли такое имя, — и список людей вычитывается перебором.
        self._send_login("Неверное имя или пароль", code=401)

    def who(self):
        """Кто сейчас работает. Пусто не бывает: кука без имени выдана до
        появления учётных записей, и это владелец."""
        token = admin_auth.cookie_token(self.headers.get("Cookie"))
        return SESSIONS.name_of(token) or admin_auth.OWNER

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
            if path == "/api/areas":
                return self.areas_json()
            if path == "/api/candidates":
                return self.candidates_json()
            if path == "/api/roads":
                return self.roads_json()
            if path == "/journal":
                return self._send(200, self.journal_page(conn))
            if path == "/changes":
                return self._send(200, self.changes_page(conn))
            if path == "/api/todo":
                return self.todo_json(conn)
            if path == "/api/points":
                return self.points_json(conn)
            if path == "/api/geocode":
                return self.geocode_json()
            if path == "/api/address":
                return self.search_json()
            if path.startswith("/api/edit/") and path.endswith("/osm"):
                return self.edit_osm(conn, path)
            if path.startswith("/api/edit/") and path.endswith("/history"):
                return self.edit_history(conn, path)
            if path in ("/static/moderate.js", "/static/editor.js",
                        "/static/editor_gl.js"):
                return self.static_file(path.rsplit("/", 1)[1],
                                        "application/javascript; charset=utf-8")
            if path == "/static/vendor/maplibre-gl.js":
                return self.static_file("vendor/maplibre-gl.js",
                                        "application/javascript; charset=utf-8")
            if path == "/static/vendor/maplibre-gl.css":
                return self.static_file("vendor/maplibre-gl.css",
                                        "text/css; charset=utf-8")
            if path.startswith("/mvt/"):
                return self.mvt_tile(path)
            if path.startswith("/glyphs/"):
                return self.glyph_range(path)
            if path == "/editor-gl":
                return self._send(200, render_editor_gl(), csp=self.CSP_GL)
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
            if path == "/api/edit/street":
                return self.street_lanes_json(conn, self._json_body(raw))
            if path == "/api/edit/withdraw":
                return self.edit_withdraw_json(conn, self._json_body(raw))
            if path == "/changes/act":
                return self.changes_action(conn, field, form)
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
            log_action(conn, camera_id, "hide", who=self.who())
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
            log_action(conn, camera_id, "move", f"{lat:.6f}, {lon:.6f}", who=self.who())
            self.resolve_reports(conn, camera_id, RESOLVED_DONE)

        elif action == "restore":
            # Откат: правка исчезает из снимка, и после публикации камера
            # возвращается всем. Это и есть страховка от ошибки модератора.
            conn.execute("DELETE FROM overrides WHERE camera_id = ?", (camera_id,))
            log_action(conn, camera_id, "restore", who=self.who())

        elif action == "reject":
            self.resolve_reports(conn, camera_id, RESOLVED_REJECTED)
            log_action(conn, camera_id, "reject", who=self.who())

        elif action == "resolve":
            self.resolve_reports(conn, camera_id, RESOLVED_DONE)
            log_action(conn, camera_id, "resolve", who=self.who())

        elif action == "snooze":
            try:
                conn.execute("UPDATE camera_reports SET snooze_until = ? WHERE camera_id = ?",
                             (now + SNOOZE_DAYS * DAY, camera_id))
            except sqlite3.OperationalError:
                pass   # см. resolve_reports: таблицы может ещё не быть
            log_action(conn, camera_id, "snooze", who=self.who())
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
            log_action(conn, None, "mobile_kill", f"отметка {report_id}", who=self.who())
        elif action == "extend":
            conn.execute("UPDATE reports SET expires = ? WHERE id = ?",
                         (time.time() + 3 * 3600, report_id))
            log_action(conn, None, "mobile_extend", f"отметка {report_id}", who=self.who())
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
                log_action(conn, None, "mobile_block", f"источник отметки {report_id}", who=self.who())
        elif action == "unblock":
            kind, value = field("block_kind"), field("block_value")
            if kind in ("ip", "device") and value:
                conn.execute("DELETE FROM blocked WHERE kind = ? AND value = ?",
                             (kind, value))
                log_action(conn, None, "mobile_unblock", f"{kind} {value}", who=self.who())
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
        # Своя карта на сводке. Конструктор — половина панели, а сводка о нём
        # не знала вовсе: человек открывал главную, видел ноль камер и уходил,
        # не узнав ни про висящие черновики, ни про правки, которые ждут
        # решения после воскресной сверки.
        #
        # Считаем дешёвыми запросами, а не пересборкой очереди: сводка
        # открывается первой и обязана открываться мгновенно.
        map_work = {"drafts": 0, "check": 0, "accepted": 0, "locks": 0}
        try:
            map_work["drafts"] = conn.execute(
                "SELECT COUNT(*) FROM map_edits WHERE status = ?",
                (map_edits.DRAFT,)).fetchone()[0]
            map_work["check"] = conn.execute(
                "SELECT COUNT(*) FROM map_edits WHERE status != ? AND note LIKE ?",
                (map_edits.WITHDRAWN, f"%{map_edits.CHECK_MARK}%")).fetchone()[0]
            map_work["accepted"] = conn.execute(
                "SELECT COUNT(*) FROM map_edits WHERE status = ?",
                (map_edits.ACCEPTED,)).fetchone()[0]
            map_work["locks"] = conn.execute(
                "SELECT COUNT(*) FROM map_edits "
                "WHERE kind = 'lock' AND status != ?",
                (map_edits.WITHDRAWN,)).fetchone()[0]
        except sqlite3.Error:
            pass

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
<h1>Своя карта</h1>
<div class="row">
  {tile(map_work["drafts"], "черновиков в конструкторе",
        "t-warn" if map_work["drafts"] else "")}
  {tile(map_work["check"], "правок ждут решения",
        "t-warn" if map_work["check"] else "")}
  {tile(map_work["accepted"], "принято и ждёт публикации")}
  {tile(map_work["locks"], "размеченных областей")}
</div>
{publish_hint}
<div class="card"><div class="muted">Всего в очереди: {len(queue)} камер ·
самый старый неразобранный репорт: {esc(ago(oldest))}</div></div>
{'<div class="empty">Пусто — можно закрыть вкладку</div>'
 if not (ready or disputed or new_feedback or unpublished
         or map_work["drafts"] or map_work["check"]) else ''}""")


    # --- Положение камеры ---

    def glyph_range(self, path):
        """Кусок шрифта для подписей. Три файла, имена — числами.

        Готовый сервис глифов существует, и подключить его — одна строка. Но
        тогда карта модератора перестаёт работать, когда лежит чужой сервис, а
        CSP приходится открывать на ещё один источник — на странице, где лежит
        его сессия. Триста килобайт своих файлов дешевле обоих последствий.
        """
        name = path.rsplit("/", 1)[1]
        if name not in ("0-255.pbf", "256-511.pbf", "1024-1279.pbf"):
            # Пустой диапазон — это 204, а не 404: у шрифта их 256, и
            # красная строка в консоли на каждый несуществующий кусок
            # означала бы двести пятьдесят строк на одну карту.
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        full = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "static", "vendor", "glyphs", name)
        try:
            with open(full, "rb") as handle:
                blob = handle.read()
        except OSError:
            return self._send(404, page("/", "Не найдено", ""))
        self.send_response(200)
        self.send_header("Content-Type", "application/x-protobuf")
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        self.send_header("Content-Security-Policy", self.CSP_STRICT)
        self.end_headers()
        self.wfile.write(blob)

    def mvt_tile(self, path):
        """Тайл MVT. Отдаёт ПАНЕЛЬ, а не вебрут, и это про CSP.

        Тайлы лежат в вебруте и раздаются оттуда боевому клиенту. Панели
        ходить туда значило бы открыть connect-src на другой источник — на той
        самой странице, где лежит сессия модератора. Свой адрес того же
        источника обходится без послабления.
        """
        parts = path[len("/mvt/"):].split("/")
        if len(parts) != 3 or not parts[2].endswith(".mvt"):
            return self._send(404, page("/", "Не найдено", ""))
        zoom, column, row = parts[0], parts[1], parts[2][:-len(".mvt")]
        # Числа, и только числа: имя из URL идёт в путь файла.
        if not all(piece.isdigit() for piece in (zoom, column, row)):
            return self._send(404, page("/", "Не найдено", ""))
        full = os.path.join(edits_tiles_dir() or "", "mvt", zoom, column,
                            f"{row}.mvt")
        try:
            with open(full, "rb") as handle:
                blob = handle.read()
        except OSError:
            # Пустой тайл — это 204, а не 404: у клиента «нет данных здесь» и
            # «адрес неверный» ведут к разному поведению, и путать их значит
            # получать в консоли красные строки на каждом пустом квадрате.
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.mapbox-vector-tile")
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "public, max-age=600")
        self.send_header("Content-Security-Policy", self.CSP_STRICT)
        self.end_headers()
        self.wfile.write(blob)

    def static_file(self, name, content_type):
        """Один каталог, имена из белого списка. Отдавать файлы по имени из URL
        нельзя: так наружу уезжает /etc/passwd."""
        if name not in ("moderate.js", "editor.js", "editor_gl.js",
                        "vendor/maplibre-gl.js", "vendor/maplibre-gl.css"):
            return self._send(404, page("/", "Не найдено", ""))
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "static", *name.split("/"))
        try:
            with open(path, encoding="utf-8") as handle:
                body = handle.read()
        except OSError:
            return self._send(404, page("/", "Не найдено",
                                        '<div class="empty">Файл карты не найден</div>'))
        # Кэшируется НАДОЛГО и намеренно: адрес несёт метку версии, поэтому
        # новый файл приезжает новым адресом, а старый можно не перепроверять.
        self._send(200, body, content_type,
                   extra={"Cache-Control": "public, max-age=31536000, immutable"})

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
        # Поиск по номеру идёт мимо рамки: номер называют, когда о правке уже
        # говорили, и искать её глазами по карте — не поиск.
        query = parse_qs(urlparse(self.path).query)
        if query.get("id"):
            try:
                edit_id = int(query["id"][0])
            except ValueError:
                return self._json({"error": "номер не число"}, 400)
            found = map_edits.by_id(conn, edit_id)
            return self._json({"edits": [found] if found else []})
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
        # Потолок ПО ОХВАТУ: на квартале читаем всё, на городе — костяк.
        # Один потолок на все случаи означал «покажи шестую часть города и
        # молчи», и молчал он именно там, где пустой экран неотличим от
        # отсутствия данных.
        # Охват ЭКРАНА приходит отдельно: рамка запроса шире него на запас,
        # и считать потолок по ней значит прятать дороги на ровном месте.
        query = parse_qs(urlparse(self.path).query)
        try:
            span = float(query["span"][0])
        except (KeyError, IndexError, ValueError):
            span = None
        try:
            mpp = float(query["mpp"][0])
        except (KeyError, IndexError, ValueError):
            mpp = None
        limits = map_edits.frame_limits(*box, span=span, mpp=mpp)
        report = {}
        roads = map_edits.load_roads(edits_tiles_dir(), *box,
                                     sets=limits["sets"],
                                     limits=limits, report=report)

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
                    "measured": bool(flags & map_edits.FLAG_LANES_TAGGED),
                    # Своё против чужого. Вести свою карту вслепую нельзя: на
                    # третьем сеансе никто не помнит, какие перекрёстки уже
                    # размечены, и работа начинает ходить по кругу.
                    "drawn": bool(flags & map_edits.FLAG_HAND_DRAWN)}

        # Здесь стоял ВТОРОЙ потолок — roads[:2000], молча и поверх первого.
        # Именно он обрезал город: файлов читалось шесть, а до панели доезжали
        # первые две тысячи дорог из них. Два потолка, о которых не знает ни
        # тот, кто смотрит, ни тот, кто их поставил, — это не защита, а
        # необъяснимая пустота на экране.
        report["shown"] = len(roads)
        self._json({"roads": [described(r) for r in roads], "limits": report})

    def areas_json(self):
        """Местность из тайлов: вода, зелень, рельсы, кварталы, тротуары, дома.

        Без неё панель показывает не схему, а чертёж — серые линии на чёрном.
        Ровно так она и выглядела: наборы местности собираются с апреля, а
        читались только дороги.
        """
        box = self._bbox()
        if box is None:
            return self._json({"error": "нужна рамка карты"}, 400)
        query = parse_qs(urlparse(self.path).query)
        try:
            mpp = float(query["mpp"][0])
        except (KeyError, IndexError, ValueError):
            mpp = None
        # Наборы — по масштабу. Полотно дорог на кадре города это 4,8 МБ ради
        # ленты шириной в полтора пикселя, поверх которой и так рисуется сама
        # дорога; тротуар в два метра на девятнадцати метрах в пикселе — это
        # одна десятая пикселя.
        limits = map_edits.frame_limits(*box, mpp=mpp)
        self._json({"areas": map_edits.load_areas(
            edits_tiles_dir(), *box, sets=map_edits.area_sets(mpp),
            budget=limits["bytes"], objects=map_edits.area_objects(mpp),
            keep=(mpp or 0))})

    def candidates_json(self):
        """Кандидаты от нейросети: обводки зданий, которых в OSM ещё нет.

        Обводить руками то, что уже обвели, — самая дорогая ошибка в этой
        работе. Замерено на живой рамке центра: нейросеть находит 4 914
        контуров там, где OSM знает 4 217 домов, и после сверки остаётся 1 090
        действительно новых — остальные 78 % уже нарисованы.

        Ответ ничего не публикует: принятый кандидат становится обычной
        правкой и проходит ту же проверку, что нарисованное мышью.
        """
        box = self._bbox()
        if box is None:
            return self._json({"error": "нужна рамка карты"}, 400)
        self._json({"houses": map_edits.load_candidates(edits_tiles_dir(), *box)})

    def street_lanes_json(self, conn, field):
        """Полосы НА ВСЮ УЛИЦУ, а не на кусок.

        Сборка режет дороги по перекрёсткам, чтобы получился граф, и это верно
        на своём месте. Но полосы — свойство улицы, а не куска: размечать
        проспект пятнадцатью правками значит платить пятнадцать раз за один
        ответ. Замерено на центре Ташкента: сто самых длинных улиц это 808
        правок поштучно и 100 целиком.

        Каждый кусок всё равно получает СВОЮ правку: у них разные опоры и
        разные версии, и слить их в одну запись значило бы потерять
        возможность снять одну, не тронув остальные.
        """
        lanes = field.get("lanes")
        if not isinstance(lanes, int) or not (1 <= lanes <= 15):
            return self._json({"error": "полос от 1 до 15"}, 400)
        try:
            lat, lon = float(field["lat"]), float(field["lon"])
        except (KeyError, TypeError, ValueError):
            return self._json({"error": "нужна точка"}, 400)

        span = 0.02
        roads = map_edits.load_roads(edits_tiles_dir(), lat - span, lon - span,
                                     lat + span, lon + span)
        result = map_edits.snap((lon, lat), roads)
        if result.road is None:
            return self._json({"error": "вне дороги"}, 400)
        pieces = map_edits.street_pieces(roads, result.road)

        made, failed = [], 0
        for piece in pieces:
            middle = map_edits.middle_of(piece["points"])
            if middle is None:
                continue
            spot = map_edits.snap((middle[0], middle[1]), roads)
            if spot.road is None:
                failed += 1
                continue
            new_id = map_edits.create(
                conn, "lanes", raw=list(middle), snapped=list(spot.point),
                anchor=spot.anchor, props={"lanes": lanes},
                note="улица целиком", author=self.who(),
                fingerprint_value=map_edits.fingerprint(
                    (middle[0], middle[1]), roads),
                status=map_edits.ACCEPTED)
            made.append(new_id)
        log_action(conn, None, "edit-street",
                   f"полосы {lanes} на {len(made)} кусках", who=self.who())
        conn.commit()
        # Сколько кусков НЕ получилось — говорим вслух: молчаливая половина
        # работы выглядит как сделанная целиком.
        self._json({"made": len(made), "pieces": len(pieces),
                    "failed": failed,
                    "name": (result.road.get("name") or "").strip()})

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
        # Палец накрывает на экране телефона метров сорок городской улицы.
        # Требовать от него точности курсора — значит требовать невозможного.
        reach = (map_edits.TOUCH_SNAP_METERS if field.get("touch")
                 else map_edits.SNAP_METERS)
        roads = map_edits.load_roads(edits_tiles_dir(), lat - span, lon - span,
                                     lat + span, lon + span)
        found = map_edits.candidates((lon, lat), roads, reach)
        result = map_edits.snap((lon, lat), roads, meters=reach,
                                prefer_node=bool(field.get("preferNode")))

        def described(item):
            road = item["road"]
            flags = road.get("flags", 0)
            cls = road["cls"]
            # Кандидат несёт ВСЁ о дороге, а не только имя и класс. Стрелкой
            # берут улицу прямо из результата магнита — и карточка обязана
            # сразу сказать, сколько там полос и какой ширины полотно, не
            # ходя за этим вторым запросом.
            return {"cls": cls, "name": road.get("name", ""),
                    "points": road["points"], "point": list(item["point"]),
                    "meters": round(item["distance"], 1),
                    "lanes": map_edits.road_lanes_of(flags, cls),
                    "width": round(map_edits.road_width_meters(flags, cls), 1),
                    "oneWay": bool(flags & map_edits.FLAG_ONEWAY),
                    "drawn": bool(flags & map_edits.FLAG_HAND_DRAWN),
                    "anchor": {"cls": road["cls"], "name": road.get("name", ""),
                               "bearing": round(item["bearing"], 1),
                               "atNode": False}}

        # Опора на id из OSM — ПОДСКАЗКА к якорю, а не замена ему. Кладём её
        # рядом с классом, именем и азимутом: воскресная сверка сначала ищет
        # дорогу по id (мгновенно и точно), и только если id исчез — прежним
        # геометрическим поиском.
        anchor = result.anchor
        if anchor is not None:
            osm_id = map_edits.identity_at(edits_tiles_dir(), (lon, lat),
                                           result.bearing_degrees)
            if osm_id:
                anchor = dict(anchor, osmId=osm_id)

        return self._json({
            "point": list(result.point) if result.road else None,
            "onRoad": result.on_road,
            "atNode": result.at_node,
            "anchor": anchor,
            # Три — потолок не от лени: четыре строки выбора за рулём панели
            # уже не читаются, а четвёртая дорога в радиусе захвата означает,
            # что человек ткнул не туда.
            "candidates": [described(item) for item in found[:3]],
            "ambiguous": len(result.ambiguous) > 0,
            "fingerprint": map_edits.fingerprint((lon, lat), roads)})

    def edit_osm(self, conn, path):
        """Нарисованная дорога файлом для редактора OSM.

        Дорога, отданная в OSM, поддерживается всем миром; наша — только нами.
        Кнопка не украшение, а способ перестать платить за поддержку в одиночку:
        отданная дорога вернётся к нам сама обычной воскресной пересборкой, и
        своя копия снимется по правилу «OSM догнал».
        """
        try:
            edit_id = int(path.split("/")[3])
        except (IndexError, ValueError):
            return self._json({"error": "номер не число"}, 400)
        edit = map_edits.by_id(conn, edit_id)
        if edit is None or edit["kind"] != "geometry":
            return self._json({"error": "это не нарисованная дорога"}, 404)
        body = map_edits.as_osm(edit)
        if not body:
            return self._json({"error": "у правки нет геометрии"}, 400)
        payload = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Disposition",
                         f'attachment; filename="radarmap-{edit_id}.osm"')
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Security-Policy", self.CSP_STRICT)
        self.end_headers()
        self.wfile.write(payload)

    def edit_history(self, conn, path):
        """Как правка выглядела раньше.

        «Кто и когда сдвинул эту улицу» через полгода спросят обязательно, а
        восстановить это неоткуда: ручная работа — единственное в системе, что
        нельзя пересобрать из OSM.
        """
        try:
            edit_id = int(path.split("/")[3])
        except (IndexError, ValueError):
            return self._json({"error": "номер не число"}, 400)
        self._json({"history": map_edits.history(conn, edit_id)})

    def search_json(self):
        """Поиск по СВОЕМУ адресному индексу — адрес `/api/address`.

        Имя не случайное: `/api/search` в панели уже занят поиском КАМЕР, и
        второй обработчик на том же адресе просто никогда не вызвался бы —
        маршрут разбирается сверху вниз. Ровно это и произошло: строка поиска
        отвечала `{"found": []}` от чужого обработчика.

        Ни ключа, ни чужого сервиса.

        Геокодер Яндекса требует отдельного ключа и без него отвечает 403 —
        а на этой странице он и не нужен: адреса собраны нами и лежат рядом с
        тайлами. Свой поиск работает и когда чужой сервис лежит, и когда за
        него не заплачено.
        """
        query = parse_qs(urlparse(self.path).query)
        text = (query.get("q") or [""])[0].strip()
        if not text:
            return self._json({"places": []})
        near = None
        try:
            near = (float(query["lat"][0]), float(query["lon"][0]))
        except (KeyError, IndexError, ValueError):
            near = None
        found = map_edits.search_addresses(edits_tiles_dir(), text, near=near)
        self._json({"places": [
            {"title": f"{item['street']}, {item['house']}",
             "lat": item["lat"], "lon": item["lon"]} for item in found]})

    def geocode_json(self):
        """Поиск адреса — ЧЕРЕЗ СВОЙ сервер, а не из браузера.

        Геокодер Яндекса в JS-API работает через JSONP: он подгружает с чужого
        хоста СКРИПТ, а не данные, и ответ исполняется как код. Разрешить это в
        CSP панели значило бы открыть выполнение чужого кода на странице, где
        лежит сессия модератора, — ради строки поиска. Здесь запрос уходит с
        сервера, обратно приходит JSON, и ключ карты остаётся на сервере.
        """
        query = parse_qs(urlparse(self.path).query)
        text = (query.get("q") or [""])[0].strip()
        if not text:
            return self._json({"places": []})
        # Ключ ОТДЕЛЬНЫЙ. Геокодер у Яндекса — своя услуга со своим ключом:
        # тот, что рисует карту, на неё не годится и отвечает 403. Падаем на
        # ключ карты только затем, чтобы владельцу, у которого оба ключа один,
        # ничего не пришлось менять.
        config = admin_auth.read_config()
        key = config.get("yandex_geocoder_key") or config.get("yandex_key", "")
        if not key:
            return self._json({"error": "в admin.conf нет ключа карты"}, 503)
        url = ("https://geocode-maps.yandex.ru/1.x/?format=json&results=6"
               f"&apikey={urllib.parse.quote(key)}"
               f"&geocode={urllib.parse.quote(text)}")
        # Рамка карты сужает поиск: «Навои» есть не в одном городе, а модератор
        # ищет ту улицу, над которой сейчас сидит.
        box = self._bbox()
        if box:
            south, west, north, east = box
            url += (f"&bbox={west},{south}~{east},{north}&rspn=1")
        try:
            with urllib.request.urlopen(url, timeout=6) as answer:
                payload = json.loads(answer.read().decode())
        except urllib.error.HTTPError as error:
            print(f"геокодер: {error}", file=sys.stderr)
            if error.code in (401, 403):
                # Самая частая причина, и «поиск недоступен» её прячет.
                # Владелец должен узнать, ЧТО именно чинить, из панели, а не
                # из логов, в которые он не смотрит.
                return self._json({"error": "Геокодеру нужен свой ключ: заведите "
                                            "его в кабинете Яндекса и положите "
                                            "в admin.conf строкой "
                                            "yandex_geocoder_key=…"}, 502)
            return self._json({"error": "поиск недоступен"}, 502)
        except Exception as error:  # сеть, формат — наружу одинаково
            print(f"геокодер: {error}", file=sys.stderr)
            return self._json({"error": "поиск недоступен"}, 502)

        members = (payload.get("response", {})
                   .get("GeoObjectCollection", {}).get("featureMember", []))
        places = []
        for member in members:
            obj = member.get("GeoObject") or {}
            point = (obj.get("Point") or {}).get("pos", "")
            parts = point.split()
            if len(parts) != 2:
                continue
            meta = (obj.get("metaDataProperty") or {}).get("GeocoderMetaData") or {}
            places.append({"title": meta.get("text") or obj.get("name") or text,
                           "lat": float(parts[1]), "lon": float(parts[0])})
        self._json({"places": places})

    def points_json(self, conn):
        """Обстановка для подложки схемы: из тайлов и своя из правок.

        Панель обязана показывать ТО ЖЕ, что увидит водитель, а без обстановки
        схема — половина картинки: дорога есть, а перекрёсток на ней ничем не
        отличается от прямого участка.

        Своя обстановка идёт РЯДОМ с тайловой и помечена отдельно: модератор
        должен видеть, что из этого уже уехало на телефоны, а что ещё лежит в
        панели и ждёт публикации.
        """
        box = self._bbox()
        if box is None:
            return self._json({"error": "нужна рамка карты"}, 400)
        south, west, north, east = box
        from_tiles = map_edits.load_points(edits_tiles_dir(), *box)
        mine = []
        for edit in map_edits.in_bbox(conn, *box):
            if edit["kind"] != "point":
                continue
            code = (edit["props"] or {}).get("point")
            if code:
                mine.append({"kind": code, "point": edit["geom"],
                             "id": edit["id"], "mine": True})
        self._json({"points": from_tiles[:1500] + mine})

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
                # Автор — ВОШЕДШИЙ, а не то, что прислал браузер. Строка из
                # тела запроса подписывала бы правку любым именем, и журнал
                # врал бы именно там, где на него полагаются.
                author=self.who(),
                fingerprint_value=field.get("fingerprint"), status=status)
            log_action(conn, None, "edit-create", f"{kind} #{new_id}", who=self.who())
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
        log_action(conn, None, "edit-save", f"{kind} #{edit_id}", who=self.who())
        conn.commit()
        self._json({"id": int(edit_id), "version": version + 1})

    def edit_withdraw_json(self, conn, field):
        try:
            edit_id, version = int(field["id"]), int(field["version"])
        except (KeyError, TypeError, ValueError):
            return self._json({"error": "нужны id и версия"}, 400)
        if not map_edits.withdraw(conn, edit_id, version):
            return self._json({"error": "правку изменили в другом окне"}, 409)
        log_action(conn, None, "edit-withdraw", f"#{edit_id}", who=self.who())
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
        tiles = edits_tiles_dir()
        if not os.path.isdir(tiles):
            return page("/changes", "Что изменилось", done +
                        '<div class="empty">Тайлов не видно: RADARMAP_TILES '
                        'указывает не туда, или дороги ещё не публиковались. '
                        'Сверять правки не с чем.</div>')
        # Сверяем ВОКРУГ КАЖДОЙ правки, а не по всей земле. «Дай все дороги»
        # открывало на боевом 210 файлов и упирало панель в MemoryMax — после
        # чего она переставала отвечать вовсе.
        decisions = osm_queue.sweep(conn, tiles_dir=tiles)
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

        def past(edit):
            """Как эта правка выглядела раньше.

            Свёрнуто, а не списком под каждой строкой: очередь читают ради
            решения «принять или снять», и десять прошлых версий над этим
            решением — шум. Но открыть их надо здесь же: модератор, увидевший
            сдвиг, первым делом спрашивает, куда объект стоял до него, а
            восстановить это больше неоткуда — ручную работу не пересобрать
            из OSM.
            """
            rows = map_edits.history(conn, edit["id"])
            if not rows:
                return ""
            lines = []
            for old_row in rows:
                when = time.strftime("%d.%m.%Y %H:%M",
                                     time.localtime(old_row["at"]))
                where = old_row["geom"]
                if where and isinstance(where[0], list):
                    where = where[0]
                try:
                    spot = f"{float(where[1]):.5f}, {float(where[0]):.5f}"
                except (TypeError, ValueError, IndexError):
                    spot = "координат нет"
                who = esc(old_row["author"] or "панель")
                lines.append(f'<div class="muted">в{old_row["version"]} · '
                             f'{esc(when)} · {esc(spot)} · {who}</div>')
            return (f'<details class="past"><summary>Было раньше · '
                    f'{len(rows)}</summary>{"".join(lines)}</details>')

        def row(decision):
            edit = decision["edit"]
            spot = (edit.get("draw") or {}).get("point") or edit["geom"]
            lat, lon = spot[1], spot[0]
            shift = f' · сдвиг {decision["shift"]} м' if decision["shift"] else ""
            place = esc(u("/editor")) + f"#{lat},{lon},19"
            note = esc(edit.get("note") or "")
            # Строка обязана отвечать сама: где это, когда завели, кто и на
            # сколько сдвинулось. Раньше здесь стояло «#5 Своя геометрия», и
            # чтобы понять хоть что-то, надо было уйти на карту и вернуться —
            # на каждой строке очереди.
            where = decision.get("place") or ""
            who = (edit.get("author") or "").strip()
            when = ago(edit.get("updated") or edit.get("created") or 0)
            facts = " · ".join(part for part in (
                esc(where), esc(when), esc(who)) if part)
            actions = button(edit, "withdraw", "Снять", "ghost")
            # «Всё верно» — по МЕТКЕ, а не по вердикту этой сверки. Метку
            # ставит пересадка, и живёт она в заметке: следующая неделя может
            # не найти сдвига вовсе, а метка останется — и снять её будет
            # нечем, то есть счётчик на вкладке не обнулится никогда.
            if (osm_queue.CHECK == decision["verdict"]
                    or map_edits.CHECK_MARK in (edit.get("note") or "")):
                actions = button(edit, "confirm", "Всё верно") + actions
            return (f'<div class="chg">'
                    f'<input type="checkbox" class="pick" form="bulk" '
                    f'name="id" value="{edit["id"]}" '
                    f'data-version="{edit["version"]}" '
                    f'aria-label="выбрать правку {edit["id"]}">'
                    f'<b>#{edit["id"]}</b> '
                    f'{esc(map_edits.kind_name(edit["kind"]))}{shift} '
                    f'<a href="{place}">на карте</a>{actions}'
                    f'<div class="muted">{facts}</div>'
                    f'<div class="muted">{note}</div>{past(edit)}</div>')

        def block(title, verdict, explain):
            rows = [d for d in decisions if d["verdict"] == verdict]
            if not rows:
                return ""
            return (f'<h3>{esc(title)} · {len(rows)}</h3>'
                    f'<div class="muted">{esc(explain)}</div>'
                    + "".join(row(d) for d in rows))

        # Поиск и групповое снятие. Три правки, потерявшие опору, снимались по
        # одной; при двадцати это перестаёт быть работой и становится
        # обязанностью. Поиск — по номеру, виду и месту: очередь читают, ища
        # конкретное, а не подряд.
        tools = (
            f'<form method="post" action="{act}" id="bulk" class="bulk">'
            f'<input type="hidden" name="op" value="withdraw-many">'
            f'<input class="find" id="qfind" placeholder="Номер, вид или улица" '
            f'autocomplete="off">'
            f'<button class="ghost" id="pickall" type="button">Выбрать все</button>'
            f'<button>Снять выбранные</button>'
            f'<span class="muted" id="picked"></span></form>')

        body = (
            block("Размечено руками — решайте сами", osm_queue.LOCKED,
                  "Внутри размеченной области OSM сдвинулся, но автоматика её "
                  "не трогала: здесь разбирались руками, и переставлять эту "
                  "работу она не вправе.")
            + block("OSM догнал нас", osm_queue.CAUGHT_UP,
                    "Рядом с нашей нарисованной дорогой появилась настоящая. "
                    "Дорога, отданная в OSM, поддерживается всем миром, наша — "
                    "только нами.")
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
            return page("/changes", "Что изменилось", done +
                        f'<div class="empty">Все {counts.get(osm_queue.KEEP, 0)} '
                        'правок на месте: вокруг них в OSM ничего не '
                        'изменилось.</div>')
        return page("/changes", "Что изменилось", done + tools + body + CHANGES_JS)

    def changes_bulk(self, conn, form):
        """Снять сразу несколько правок.

        Три правки, потерявшие опору, снимались по одной; при двадцати это
        перестаёт быть работой и становится обязанностью.

        Версию каждой правки читаем ЗДЕСЬ, а не берём из формы: между
        отрисовкой страницы и нажатием кнопки правку могли изменить в другом
        окне, и групповое действие не должно быть способом обойти проверку
        версий, которая для одиночного стоит.
        """
        ids = []
        for raw in form.get("id") or []:
            try:
                ids.append(int(raw))
            except ValueError:
                continue
        done, stale = 0, 0
        for edit_id in ids[:200]:
            edit = map_edits.by_id(conn, edit_id)
            if edit is None:
                stale += 1
                continue
            if map_edits.withdraw(conn, edit_id, edit["version"]):
                log_action(conn, None, "edit-withdraw", f"#{edit_id} · пачкой", who=self.who())
                done += 1
            else:
                stale += 1
        conn.commit()
        # Возврата у пачки НЕТ, и это сказано вслух на баннере: вернуть
        # двадцать правок одной кнопкой значит уметь и снять их одной ошибкой.
        # Поштучный возврат остался — он в строке каждой снятой правки.
        self._redirect(u("/changes") + f"?done=many&n={done}&stale={stale}")

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
        if op == "many":
            done = query.get("n", ["0"])[0]
            stale = query.get("stale", ["0"])[0]
            tail = (f' Не вышло: {esc(stale)} — их изменили в другом окне.'
                    if stale not in ("0", "") else "")
            return (f'<div class="warn">Снято правок: {esc(done)}.{tail} '
                    'Вернуть можно каждую по отдельности.</div>')
        if op == "stale":
            return ('<div class="warn">Правку изменили в другом окне — '
                    'страница перечитана.</div>')
        return ""

    def changes_action(self, conn, field, form=None):
        """Снять, подтвердить или вернуть — одна строка очереди."""
        if field("op") == "withdraw-many":
            return self.changes_bulk(conn, form or {})
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
        log_action(conn, None, f"changes-{op}", f"#{edit_id}", who=self.who())
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
        log_action(conn, camera_id, "move", f"{lat:.6f}, {lon:.6f}", who=self.who())
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
        log_action(conn, camera_id, "undo", who=self.who())
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

    def journal_page(self, conn):
        """Журнал решений: что делали, когда и кто.

        Отдельной страницей, а не хвостом «Здоровья», и с поиском. Двадцать
        последних записей отвечают на «что было только что», а спрашивают
        обычно другое: «кто снял правку #5», «что делали с этой камерой»,
        «что происходило в прошлый вторник». По списку из двадцати строк без
        поиска на такое не ответишь.
        """
        query = parse_qs(urlparse(self.path).query)
        want = (query.get("q") or [""])[0].strip()
        try:
            limit = min(500, max(20, int((query.get("n") or ["200"])[0])))
        except ValueError:
            limit = 200

        sql = ("SELECT at, camera_id, action, detail FROM moderation_log "
               "{where} ORDER BY id DESC LIMIT ?")
        args = []
        where = ""
        if want:
            # По действию и по подробностям: там лежат и номер правки, и имя
            # человека. Поиск по номеру камеры — тем же полем, потому что
            # спрашивают «что было с 1234», а не «поле camera_id равно».
            where = "WHERE action LIKE ? OR detail LIKE ? OR camera_id = ?"
            args = [f"%{want}%", f"%{want}%", want if want.isdigit() else -1]
        rows = conn.execute(sql.format(where=where), args + [limit]).fetchall()

        def row(item):
            place = ""
            if item["camera_id"]:
                link = esc(u("/map")) + f'#{item["camera_id"]}'
                place = (f' · <a href="{link}">камера '
                         f'{esc(camera_title(item["camera_id"]))}</a>')
            elif item["detail"] and "#" in item["detail"]:
                # Ссылка на правку: номер лежит в подробностях как «#5».
                number = item["detail"].split("#", 1)[1].split()[0].strip(" ·,")
                if number.isdigit():
                    link = esc(u("/editor")) + f"?edit={number}"
                    place = f' · <a href="{link}">правка #{esc(number)}</a>'
            when = time.strftime("%d.%m.%Y %H:%M", time.localtime(item["at"]))
            return (f'<div class="chg"><b>{esc(item["action"])}</b>'
                    f'<span class="muted">{esc(when)}{place} · '
                    f'{esc(item["detail"] or "")}</span></div>')

        found = "".join(row(item) for item in rows)
        if not found:
            found = ('<div class="empty">Ничего не нашлось. Попробуйте номер '
                     'правки, имя человека или вид действия.</div>')
        act = esc(u("/journal"))
        tools = (f'<form method="get" action="{act}" class="bulk">'
                 f'<input class="find" name="q" value="{esc(want)}" '
                 f'placeholder="Номер правки, имя, действие" autocomplete="off">'
                 f'<button>Искать</button>'
                 f'<span class="muted">записей: {len(rows)}</span></form>')
        return page("/journal", "Журнал", tools + found)

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
    if "--add-person" in sys.argv:
        # Пароль спрашиваем, а не берём из аргументов: командная строка видна
        # в списке процессов и остаётся в истории оболочки.
        index = sys.argv.index("--add-person")
        try:
            name = sys.argv[index + 1]
        except IndexError:
            print("нужно имя: --add-person <имя>")
            return
        import getpass
        password = getpass.getpass(f"Пароль для «{name}»: ")
        if len(password) < 12:
            print("слишком короткий пароль: не меньше двенадцати знаков")
            return
        if password != getpass.getpass("Ещё раз: "):
            print("пароли не совпали")
            return
        try:
            print(admin_auth.write_account(name, password))
        except ValueError as error:
            print(error)
        return
    if "--drop-person" in sys.argv:
        index = sys.argv.index("--drop-person")
        try:
            name = sys.argv[index + 1]
        except IndexError:
            print("нужно имя: --drop-person <имя>")
            return
        print("убран" if admin_auth.drop_account(name) else "такого нет")
        return
    if "--people" in sys.argv:
        for name in sorted(admin_auth.accounts()):
            print(name)
        return
    if "--mark-published" in sys.argv:
        index = sys.argv.index("--mark-published")
        version = int(sys.argv[index + 1])
        print(f"помечено опубликованными: {mark_published(version)}")
        return
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
