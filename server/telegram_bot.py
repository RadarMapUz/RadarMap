#!/usr/bin/env python3
"""telegram_bot.py — отметки водителей через Telegram (план 19.10, 12б.7).

Водители уже сидят в Telegram-чатах «где стоят». Канал (telegram_publish.py)
отдаёт им подтверждённое; бот замыкает круг — принимает отметки тех, у кого
приложения нет: геопозиция → тип кнопкой → тот же POST /api/report, что у
приложения, с тем же жизненным циклом доверия (испытательный срок,
подтверждение независимым водителем).

КАК ЭТО РАБОТАЕТ
  * человек шлёт геопозицию (постоянная кнопка «📍 Отправить геопозицию»);
  * сначала польза (план 23, docs/plan_bot_2026-10-21.md): ОДНО сообщение
    «что рядом» — живые отметки в 5 км, стационарные камеры, перекрытия,
    ближайший метан (bot_near.py), кнопки «Отметить, что видите» и
    «Дальше — 15 км»; не чаще раза в 20 с на человека;
  * «Отметить» — кнопки: радар, тренога, пост, ДТП, перекрыто, метан
    (`/report` — сразу они); «метан» — второй ряд: газ есть / нет /
    очередь; уходит в POST /api/cng. Созданную отметку 2 минуты можно
    отменить кнопкой (POST /api/report/cancel, устройство то же);
  * точка без типа живёт 10 минут в памяти и забывается;
  * трансляция геопозиции — раз в минуту только новое впереди по ходу и
    «ещё стоит?» после проезда чужой отметки (→ /api/vote kind=pass);
  * /metan, /pereval, /city, /my, /lang, /help, /privacy, /app, /stop;
    /stats — только владельцу (owner_hash в конфиге);
  * подписки на перевалы и город и их рассылка — bot_subs.py (bot.db),
    доставка — family_notify.Courier в своём потоке;
  * тексты — bot_texts.py, русский и узбекский: /lang, иначе язык Telegram;
  * имя, описания и меню команд бот выставляет сам при запуске, если они
    изменились (ensure_profile); аватар — только в @BotFather;
  * пульт features.bot = false (подписанный config.json) выключает всё,
    кроме отметок, близких и /my, /stop.

ГЕОПОЗИЦИЯ «ЧТО РЯДОМ» не пишется ни в базу, ни в журнал: она нужна для
одного ответа (и ждёт выбора типа в памяти до 10 минут, как прежде).
Трансляция держит последнюю точку в памяти до своего конца.

МЕТАН — НА ТОЧКЕ ЗАПРАВКИ, А НЕ НА ТОЧКЕ ЧЕЛОВЕКА (аудит 14.3, N3)
  Станцию сервер узнаёт по координате, округлённой до 1e-4° (api.py
  cng_station_key): у телефонов она одна — точка заведения из файла заведений.
  Своя геопозиция человека из Telegram — это ДРУГАЯ станция: отметка бота не
  сливалась с отметками приложения у той же колонки, не подтверждала их и
  рисовала на карте свою плашку там, где стоял человек.
  Поэтому бот берёт АГНКС (вид 12) из тех же опубликованных файлов заведений,
  что качают телефоны (`road2_<клетка>_v.json` в webroot, publish_roads.sh),
  с диска по пути `venues_dir` из конфига, и шлёт отметку в координате
  ближайшей колонки не дальше CNG_SNAP_METERS — того же радиуса, в котором
  приложение задаёт свой вопрос (AppConfig.cngAskMeters). Координата
  получается тем же действием, что в VenueBook.decode — целое 1e-5° делится
  на 1e5 (не умножается на 1e-5: последний бит другой) — значит ключ станции
  совпадает с ключом телефона до бита.
  Рядом нет АГНКС — отказ с просьбой встать у колонки; в суточный лимит не
  идёт. Файлов нет, каталог не читается, файл битый — метан не принимаем
  вовсе (fail closed) и пишем в журнал один раз: отметка в выдуманной точке
  хуже, чем никакой. Файлы держатся в памяти и перечитываются, когда меняются
  на диске (сверка по mtime/размеру при каждом обращении).

ПРИВАТНОСТЬ
  * Telegram-id в открытом виде не хранится НИГДЕ: ни в базе, ни в логах,
    ни в памяти дольше обработки одного сообщения. Вместо него — хэш
    scrypt(id · номер 30-дневного окна, соль сервера): устройство для API
    меняется раз в 30 дней, как ротируемый UUID приложения, и по базе
    отметок человека нельзя ни найти, ни связать месяцы между собой.
  * Тот же хэш (другой его срез) уходит API как адрес (`X-Real-IP: tg-…`):
    иначе все пользователи бота делили бы один адрес 127.0.0.1 — и не могли
    бы подтверждать друг друга, а суточный кап адреса был бы общим на всех.
    Порт API (127.0.0.1:8091) снаружи недоступен — подделать заголовок может
    только процесс на самом сервере.
  * Свою отметку бот-пользователь не подтверждает: повтор от того же
    человека — то же устройство и тот же адрес, API считает это одним
    голосом (confirmed_independently).
  * Исключение — близкие (22.3, family_notify.py): чтобы написать близкому,
    нужен номер его чата. В подписке он ЗАШИФРОВАН ключом из семейной
    ссылки, которого на сервере нет (его приносит телефон водителя с каждым
    обновлением); для /stop и капа на чат — scrypt-хэш номера с той же
    солью. Открытым номер лежит только в очереди сообщений — до 10 минут.

ПОЧЕМУ SCRYPT, А НЕ SHA256 (аудит 14.3, N6)
  Соль лежит в конфиге на том же VPS. Взломавший сервер получает и соль, и
  базу отметок с устройствами `tg-…`, а пространство Telegram-id — около
  10^10 чисел подряд. Под sha256 (0,4 мкс на попытку, замер 20.10 на M3 Pro)
  это 10^10 × 0,4 мкс ≈ час одного ядра на 30-дневное окно, на видеокарте —
  секунды: все прошлые отметки бота привязывались бы к аккаунтам Telegram.
  scrypt N=2^12, r=8, p=1 (4 МБ памяти) — 6,6 мс на попытку на том же M3 Pro:
  10^10 попыток ≈ 2 года одного ядра на КАЖДОЕ окно (номер окна — во входе
  хэша, окна перебираются порознь). Память — главное: видеокарта ускоряет
  scrypt несравнимо меньше, чем sha256. Это «дорого», а не «невозможно»:
  решительный атакующий с фермой видеокарт всё равно справится за дни на
  окно. И честно о том, чего хэш НЕ даёт: проверить ОДИН известный id — одна
  попытка, мгновенно; а взломщик на сервере и так видит новые сообщения с
  открытыми id. Защищается прошлое от массового раскрытия, не будущее.
  Цена для нас: ровно одно вычисление на входящее сообщение или нажатие
  (6,6 мс на M3 Pro, на маленьком VPS ожидаемо 15–20 мс — с запасом ниже
  50 мс); сообщения бот обрабатывает по одному, так что наплыв съедает не
  больше одного ядра. Нет hashlib.scrypt (Python без OpenSSL ≥ 1.1) — бот не
  стартует: тихо откатиться на sha256 значило бы снять защиту, не сказав.
  Смена хэша при выкатке — то же, что граница 30-дневного окна: у всех
  пользователей бота новые устройство и адрес, счётчики суток с нуля.

ЛИМИТЫ — свои, на человека (по хэшу), до API (аудит 14.3, N9):
  * не больше BOT_DAILY_REPORTS ПРИНЯТЫХ отметок в сутки: считается только
    ответ 200. Отказ API (429), его ошибка, «рядом нет АГНКС» — не в счёт:
    раньше второй тап через 61–119 с получал 429, показывал «не получилось»
    и всё равно сжигал одну из пятнадцати;
  * интервал — тот же, что у API: BOT_MIN_INTERVAL = 120 с между СОЗДАННЫМИ
    отметками одной категории (камеры / события дороги — api.py is_road);
    голос в чужую отметку (merge) интервал не начинает, уточнение своей
    отметки другим типом (amend, 400 м / 10 мин) API пропускает в обход
    интервала — бот тоже. Бот прежде держал 60 с, и окно 61–119 с упиралось
    в 429. Своя копия правила — чтобы не тратить на заведомый отказ суточный
    кап адреса в API (30 запросов); решает всё равно API, и его 429 —
    «Не так часто», а точка остаётся: кнопку можно нажать ещё раз;
  * у метана интервала нет и в API: повтор на той же станции заменяет свой
    прошлый ответ («передумал — не второй голос»).
  Счётчики суток — в bot.db по хэшу, без id; время последних созданных
  отметок (для интервала) — только в памяти, по хэшу, не дольше 10 минут.

БЛИЗКИЕ В TELEGRAM (22.3)
  /start f_<адрес семейной ссылки> — подписка: бот пишет «едет домой —
  будет примерно в 18:40», «задерживается», «дома»; /stop — снять все
  подписки этого чата. Решает и кладёт сообщения в очередь api.py
  (family_notify.on_update), отправляет — поток Courier этого процесса,
  чтобы долгий getUpdates (30 с) не держал «едет домой». Логика, тексты и
  сроки — family_notify.py; база — family.db рядом с bot.db.

КОНФИГ: /opt/radarmap/telegram_bot.conf (создаёт владелец, в git не лежит):
    token=<токен бота>
    salt=<длинная случайная строка, например `openssl rand -hex 32`>
    username=<имя бота без @>   (ссылка t.me/<имя>?start=f_… на странице близкого;
                                 читать — family_notify.read_username, только этот ключ)
    venues_dir=/opt/radarmap/www/roads   (необязательно; это значение по умолчанию)
    app_url=<ссылка App Store>  (необязательно; нет — /app: «скоро в App Store»)
    owner_hash=<hex>            (необязательно; /stats. Открытого id владельца в
                                 конфиге нет: `echo <id> | python3 telegram_bot.py
                                 --owner-hash` печатает строку, см. RUNBOOK.md)
    webroot, cameras_path, weather_path, pult_path, reports_db — необязательно,
    по умолчанию — пути сервера (/opt/radarmap/www/…, /opt/radarmap/api/reports.db).
Нет конфига — выход 0 с сообщением. Соль не менять: от неё и хэши
подписок близких — со сменой их /stop перестанет находить.

ЗАПУСК: long polling (getUpdates), без вебхука и открытых портов —
systemd-юнит radarmap-bot.service. Тесты без сети: test_telegram_bot.py.
"""
import hashlib
import hmac
import json
import math
import os
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request

import bot_near
import bot_subs
import bot_texts
import family_notify
import telegram_publish
from bot_near import haversine

DEFAULT_CONFIG = "/opt/radarmap/telegram_bot.conf"
DEFAULT_DB = "/opt/radarmap/api/bot.db"
#: Опубликованные файлы заведений — каталог `roads/` webroot (publish_roads.sh).
DEFAULT_VENUES_DIR = "/opt/radarmap/www/roads"
#: Webroot: cameras.json (deploy_db.sh), weather/roads.json, config.json (пульт).
DEFAULT_WEBROOT = "/opt/radarmap/www"
#: База отметок — только чтение, для подписок на город (выборка канала).
DEFAULT_REPORTS_DB = "/opt/radarmap/api/reports.db"
DEFAULT_PRIVACY_URL = "https://soulmed.uz/radarmap/privacy.html"
#: edited_message — правки живой геопозиции (трансляция, 23.4).
ALLOWED_UPDATES = ["message", "edited_message", "callback_query"]
API_BASE = "http://127.0.0.1:8091"
TG_API = "https://api.telegram.org/bot{token}/{method}"

#: Окно смены хэша-устройства — как ротация UUID в приложении.
ROTATION_SECONDS = 30 * 86400
#: Своя точка без выбранного типа живёт столько.
PENDING_TTL = 10 * 60
BOT_DAILY_REPORTS = 15
#: Суточные счётчики (хэш человека — псевдоустройство) живут трое суток
#: (RETENTION.md); чистка — при каждой принятой отметке и раз в час из цикла,
#: чтобы молчащий бот не держал хэши вечно.
BOT_LIMITS_KEEP_DAYS = 3
BOT_LIMITS_PRUNE_SECONDS = 3600
#: = api.py: «минимум 120 с между отметками» устройства одной категории.
BOT_MIN_INTERVAL = 120
#: = api.AMEND_WINDOW: своя отметка моложе этого уточняется другим типом.
AMEND_WINDOW = 10 * 60
#: = api.ROAD_TYPES: события дороги — своя категория капов и интервала.
ROAD_TYPES = ("closure", "roadwork")

#: scrypt хэша человека: 4 МБ памяти, ~7 мс (см. «Почему scrypt»).
KDF_N = 1 << 12
KDF_R = 8
KDF_P = 1

#: Файлы заведений — контракт с build_roads.py и VenueBook.swift.
VENUE_CNG = 12               # build_roads.VENUE_CNG ↔ Venue.Kind.cng
VENUE_SCALE = 1e5            # build_roads.SCALE ↔ RoadTiles.scale
VENUE_CELL_DEGREES = 0.5     # build_roads.ADDRESS_DEGREES ↔ AddressBook.cellDegrees
#: Колонка не дальше этого — та же, что у вопроса приложения (AppConfig.cngAskMeters).
CNG_SNAP_METERS = 60.0
#: Каталог пересматривается при смене его mtime и не реже этого — на случай,
#: если файл появился в тот же тик часов, что и прошлый просмотр.
VENUES_RESCAN_SECONDS = 10 * 60

#: Кнопки типа → тип API, в этом порядке. «Метан» открывает второй ряд.
#: Подписи на двух языках — bot_texts.KIND_NAMES / CNG_NAMES.
REPORT_KINDS = [(kind, bot_texts.KIND_NAMES["ru"][kind])
                for kind in ("radar", "tripod", "post", "accident", "closure", "cng")]
CNG_KINDS = [(kind, bot_texts.CNG_NAMES["ru"][kind]) for kind in ("gas", "nogas", "queue15", "queue60")]

#: Все тексты — bot_texts.TEXTS[язык][ключ] (ru, uz).
TEXTS = bot_texts.TEXTS


def log(text):
    print(f"telegram_bot: {text}", file=sys.stderr, flush=True)


# --- приватность ---------------------------------------------------------------

def period(now):
    return int(now // ROTATION_SECONDS)


def _kdf(password, salt):
    """Медленный хэш (см. «Почему scrypt»). Одна точка — чтобы тест мог
    сосчитать вызовы: на сообщение — ровно один."""
    return hashlib.scrypt(password, salt=salt, n=KDF_N, r=KDF_R, p=KDF_P, dklen=32)


def user_hash(salt, user_id, now):
    """Хэш человека на это 30-дневное окно (64 hex). id в результат не
    попадает и по нему не восстанавливается без соли сервера — и даже с ней
    только перебором по scrypt."""
    return _kdf(f"{user_id}|{period(now)}".encode(), salt.encode()).hex()


def device_of(digest):
    return "tg-" + digest[:32]


def pseudo_ip_of(digest):
    return "tg-" + digest[32:48]


def device_for(salt, user_id, now):
    return device_of(user_hash(salt, user_id, now))


def pseudo_ip_for(salt, user_id, now):
    return pseudo_ip_of(user_hash(salt, user_id, now))


# --- лимиты (bot.db, только хэши) ---------------------------------------------

def open_db(path):
    """bot.db: суточные счётчики (здесь) и всё из bot_subs.SCHEMA — язык,
    подписки, очередь. Файл делят поток опроса и поток доставки — WAL и
    ожидание блокировки вместо мгновенного «database is locked»."""
    conn = sqlite3.connect(path, timeout=5.0)
    if path != ":memory:":
        conn.execute("PRAGMA journal_mode = WAL")
    # `last` — время последней принятой отметки. Интервал по нему больше не
    # считается (он теперь по категориям и в памяти), колонка оставлена,
    # чтобы bot.db с сервера открывался без миграции.
    conn.execute("""CREATE TABLE IF NOT EXISTS bot_limits(
        who TEXT NOT NULL, day TEXT NOT NULL, count INTEGER NOT NULL, last REAL NOT NULL,
        PRIMARY KEY(who, day))""")
    bot_subs.init_schema(conn)
    return conn


def _day(now):
    """Сутки по Ташкенту (UTC+5)."""
    return time.strftime("%Y-%m-%d", time.gmtime(now + 5 * 3600))


def daily_count(conn, who, now):
    row = conn.execute("SELECT count FROM bot_limits WHERE who = ? AND day = ?",
                       (who, _day(now))).fetchone()
    return row[0] if row else 0


def limit_reached(conn, who, now):
    """Суточный лимит исчерпан. Только проверка — счёт ведёт count_accepted."""
    return daily_count(conn, who, now) >= BOT_DAILY_REPORTS


def count_accepted(conn, who, now):
    """+1 к суткам — только за отметку, которую API принял (200)."""
    conn.execute("INSERT OR REPLACE INTO bot_limits(who, day, count, last) VALUES(?,?,?,?)",
                 (who, _day(now), daily_count(conn, who, now) + 1, now))
    prune_limits(conn, now)


def prune_limits(conn, now):
    """Счётчики старше BOT_LIMITS_KEEP_DAYS суток — прочь."""
    conn.execute("DELETE FROM bot_limits WHERE day < ?",
                 (_day(now - BOT_LIMITS_KEEP_DAYS * 86400),))
    conn.commit()


def category_of(rtype):
    return "road" if rtype in ROAD_TYPES else "camera"


def too_soon(recent, rtype, now):
    """Копия правила API «120 с между отметками одной категории».

    `recent` — созданные этим человеком отметки категории: [(время, тип, id)].
    True — API заведомо ответит 429, не стоит и спрашивать. Уточнение своей
    отметки другим типом API разбирает ДО интервала, поэтому если среди своих
    свежих есть отметка другого типа — решает API (оно и расстояние знает)."""
    live = [row for row in recent if now - row[0] < AMEND_WINDOW]
    if not live or now - max(row[0] for row in live) >= BOT_MIN_INTERVAL:
        return False
    return all(row[1] == rtype for row in live)


# --- АГНКС из файлов заведений -----------------------------------------------------

class VenueSourceError(Exception):
    """Файлов заведений нет или они не читаются — метан не принимаем."""


def venue_cell(lat, lon):
    """Ключ клетки заведений — как build_roads.address_key и VenueBook.key."""
    row = int(math.floor((lat + 90) / VENUE_CELL_DEGREES))
    column = int(math.floor((lon + 180) / VENUE_CELL_DEGREES))
    return f"{row}_{column}"


def venue_cells_around(lat, lon, meters):
    """Клетки, которых касается круг `meters`: рамка много меньше клетки, и
    каждая задетая клетка содержит хотя бы один её угол. У границы клетки
    колонка через дорогу лежит в соседнем файле."""
    dlat = meters / 111_320.0
    dlon = meters / (111_320.0 * max(0.01, math.cos(math.radians(lat))))
    return sorted({venue_cell(lat + a, lon + b) for a in (-dlat, dlat) for b in (-dlon, dlon)})


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def parse_cng(blob):
    """Файл клетки {"version":1,"venues":[[код, имя, lat, lon], …]} → АГНКС
    [(lat, lon, имя)]. Координата — РОВНО как в VenueBook.decode: число,
    делённое на 1e5. Чужой формат — ValueError."""
    root = json.loads(blob)
    rows = root.get("venues") if isinstance(root, dict) else None
    if not isinstance(rows, list):
        raise ValueError("нет списка venues")
    out = []
    for row in rows:
        if not isinstance(row, list) or len(row) < 4:
            continue
        code, name, lat, lon = row[:4]
        if not _number(code) or int(code) != VENUE_CNG or not _number(lat) or not _number(lon):
            continue
        out.append((float(lat) / VENUE_SCALE, float(lon) / VENUE_SCALE,
                    name if isinstance(name, str) else ""))
    return out


class CngVenues:
    """АГНКС из опубликованных файлов заведений, с диска, с кэшем в памяти.

    Каталог читается списком только при смене его mtime (публикация удаляет
    и копирует файлы — каталог меняется) и не реже VENUES_RESCAN_SECONDS;
    файл клетки — только когда у него сменились mtime, размер или inode.
    В памяти — одни АГНКС тех клеток, о которых спрашивали."""

    def __init__(self, directory, logger=log, clock=time.monotonic):
        self.directory = directory
        self.log = logger
        self.clock = clock
        self._dir_stamp = None
        self._scanned_at = None
        self._cells = frozenset()
        self._files = {}
        self._logged = set()

    def nearest(self, lat, lon, meters=CNG_SNAP_METERS):
        """(lat, lon, имя) ближайшей АГНКС не дальше `meters`; None — рядом
        нет. VenueSourceError — источника нет, метан не принимаем."""
        self._scan()
        best = None
        for key in venue_cells_around(lat, lon, meters):
            if key not in self._cells:
                continue
            for venue in self._load(key):
                distance = haversine(lat, lon, venue[0], venue[1])
                if distance <= meters and (best is None or distance < best[0]):
                    best = (distance, venue)
        return best[1] if best else None

    def around(self, lat, lon, meters):
        """[(метры, (lat, lon, имя))] — АГНКС в круге, ближние первыми (/metan,
        «что рядом»). Источник тот же и так же fail closed."""
        self._scan()
        found = []
        for key in venue_cells_around(lat, lon, meters):
            if key not in self._cells:
                continue
            for venue in self._load(key):
                distance = haversine(lat, lon, venue[0], venue[1])
                if distance <= meters:
                    found.append((distance, venue))
        found.sort(key=lambda pair: pair[0])
        return found

    def _fail(self, key, text):
        """Отказ источника: в журнал — один раз, пока источник не поправится."""
        if key not in self._logged:
            self._logged.add(key)
            self.log(f"метан не принимаем — {text}")
        raise VenueSourceError(text)

    def _scan(self):
        now = self.clock()
        try:
            stamp = os.stat(self.directory).st_mtime_ns
            if (stamp != self._dir_stamp or self._scanned_at is None
                    or now - self._scanned_at >= VENUES_RESCAN_SECONDS):
                cells = set()
                with os.scandir(self.directory) as entries:
                    for entry in entries:
                        name = entry.name
                        if name.startswith("road2_") and name.endswith("_v.json"):
                            cells.add(name[len("road2_"):-len("_v.json")])
                self._cells = frozenset(cells)
                self._dir_stamp = stamp
                self._scanned_at = now
        except OSError as error:
            self._dir_stamp = None
            self._cells = frozenset()
            self._fail(("dir",), f"каталог заведений {self.directory} не читается ({type(error).__name__})")
        if not self._cells:
            self._fail(("empty",), f"в {self.directory} нет файлов заведений road2_*_v.json")
        self._logged.discard(("dir",))
        self._logged.discard(("empty",))

    def _load(self, key):
        path = os.path.join(self.directory, f"road2_{key}_v.json")
        try:
            info = os.stat(path)
        except OSError as error:
            # Файл был в списке и пропал — идёт публикация: набор меняется
            # прямо сейчас, и отвечать «рядом нет» по половине набора нельзя.
            self._dir_stamp = None
            self._fail(("file", path, type(error).__name__),
                       f"{os.path.basename(path)} не читается ({type(error).__name__})")
        stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        cached = self._files.get(path)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        try:
            with open(path, "rb") as handle:
                venues = parse_cng(handle.read())
        except (OSError, ValueError, TypeError) as error:
            self._fail(("file", path, stamp),
                       f"{os.path.basename(path)} не разобран ({type(error).__name__})")
        self._files[path] = (stamp, venues)
        self._logged = {k for k in self._logged if not (k[0] == "file" and k[1] == path)}
        return venues


# --- бот -------------------------------------------------------------------------

def keyboard(rows):
    return {"inline_keyboard": [[{"text": label, "callback_data": data} for data, label in row]
                                for row in rows]}


def chunks(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def reply_keyboard(lang):
    """Постоянная клавиатура внизу: геопозиция одним касанием (23.1)."""
    return {"keyboard": [[{"text": bot_texts.text(lang, "kb_location"), "request_location": True},
                          {"text": bot_texts.text(lang, "kb_metan")}]],
            "resize_keyboard": True, "is_persistent": True}


def kinds_keyboard(lang):
    return keyboard(chunks([(data, bot_texts.KIND_NAMES[lang][data]) for data, _ in REPORT_KINDS], 3))


def cng_keyboard(lang):
    return keyboard(chunks([(data, bot_texts.CNG_NAMES[lang][data]) for data, _ in CNG_KINDS], 2))


def parse_command(text):
    """(«/near», остаток) — «/near@RadarMapBot x» тоже; не команда — (None, текст)."""
    parts = text.strip().split(None, 1)
    if not parts or not parts[0].startswith("/"):
        return None, text.strip()
    return parts[0].split("@", 1)[0].lower(), (parts[1].strip() if len(parts) > 1 else "")


def owner_hash_of(salt, user_id):
    """Хэш владельца для `owner_hash` в конфиге: тот же scrypt с солью бота,
    свой домен «owner|». Открытый id владельца в конфиге не лежит."""
    return _kdf(f"owner|{user_id}".encode(), salt.encode()).hex()


#: Отменить свою отметку бот даёт столько (API — 10 минут; кнопке хватит двух).
CANCEL_WINDOW = 120
#: «Что рядом» и /metan — не чаще раза в столько на человека.
NEAR_GAP = 20.0
#: Намерение «/metan, а геопозиции ещё нет» ждёт точку столько.
INTENT_TTL = PENDING_TTL
#: Список АГНКС /metan — номер кнопки к станции, в памяти столько.
STATIONS_TTL = PENDING_TTL
METAN_LABELS = {bot_texts.TEXTS[lang]["kb_metan"] for lang in bot_texts.LANGS}


class Bot:
    """Логика без сети: `send`, `api_post` и источники подменяются в тестах.

    Хэши — по одному на обновление: хэш человека (язык, отметки, «что
    рядом», трансляция) и, только у команд подписок (/my, /stop, «🔔», город,
    «убрать»), второй — хэш чата, которым подписки найдены. Оба
    запоминаются на время одного обновления и забываются."""

    def __init__(self, salt, db, send, api_post, now=time.time, venues=None, family=None,
                 sources=None, pult=None, config=None, subs_key=None, couriers=()):
        self.salt = salt
        self.db = db
        self.send = send            # (method, payload) -> dict
        self.api_post = api_post    # (path, body, pseudo_ip) -> (status, dict)
        self.now = now
        # Нет источника заведений — метан не принимаем (fail closed).
        self.venues = venues
        # Подписки близких (family_notify.FamilyCommands); None — выключены,
        # и /start f_… получает обычное приветствие.
        self.family = family
        # Что бот отдаёт (bot_near.Sources); None — только отметки, как до 23.x.
        self.sources = sources
        self.pult = pult
        self.config = config if config is not None else {}
        self.subs_key = subs_key or bot_subs.box_key(salt)
        self.couriers = tuple(couriers)
        # Точки, ждущие типа: ключ — хэш человека (не id), значение — (lat, lon, ts).
        self.pending = {}
        # Созданные отметки для копии интервала API: хэш → категория →
        # [(время, тип, id отметки)]. Ни id человека, ни координат.
        self.recent = {}
        # «Что нужно от следующей геопозиции» (/report, /metan, /near без точки): хэш → (вид, ts).
        self.intents = {}
        # /metan: номера кнопок «отметить статус» → АГНКС, хэш → ([(номер, станция)], ts).
        self.stations = {}
        # Станция, выбранная кнопкой /metan, для второго ряда метана: хэш → (станция, ts).
        self.anchors = {}
        # Когда человек последний раз получал «что рядом» / /metan: хэш → ts.
        self.data_at = {}
        # Трансляции: хэш → bot_near.LiveSession. Только память.
        self.live = {}
        # Остановленные /stop трансляции: хэш → (время начала той трансляции,
        # её конец). Её правки идут и дальше — они не должны её оживить.
        self.stopped = {}
        # Счётчики с запуска для /stats — только числа.
        self.stats = {"near": 0, "metan": 0, "live": 0, "votes": 0, "cancelled": 0}
        self._memo = {}

    # --- служебное --------------------------------------------------------------

    def _who(self, user, now):
        key = ("who", user)
        if key not in self._memo:
            self._memo[key] = user_hash(self.salt, user, now)
        return self._memo[key]

    def _tag(self, chat):
        key = ("tag", chat)
        if key not in self._memo:
            self._memo[key] = family_notify.chat_tag(self.salt, chat, lambda password, salt: _kdf(password, salt))
        return self._memo[key]

    def _lang(self, who, code):
        try:
            stored = bot_subs.get_lang(self.db, who)
        except sqlite3.Error as error:
            log(f"язык не прочитан — {type(error).__name__}")
            stored = None
        return stored or bot_texts.lang_of(code)

    def _extras(self):
        """Всё, что сверх отметок (что рядом, метан, трансляция, перевалы,
        город): есть источники и пульт не выключил."""
        return self.sources is not None and (self.pult is None or self.pult.enabled())

    def _say(self, chat, lang, key, markup=None, **values):
        payload = {"chat_id": chat, "text": bot_texts.text(lang, key, **values)}
        if markup is not None:
            payload["reply_markup"] = markup
        return self.send("sendMessage", payload)

    def _post(self, chat, text, markup=None):
        payload = {"chat_id": chat, "text": text, "disable_web_page_preview": True}
        if markup is not None:
            payload["reply_markup"] = markup
        return self.send("sendMessage", payload)

    def _allow_data(self, who, now):
        last = self.data_at.get(who)
        if last is not None and now - last < NEAR_GAP:
            return False
        self.data_at[who] = now
        return True

    def _point(self, who, now):
        point = self.pending.get(who)
        return (point[0], point[1]) if point and now - point[2] < PENDING_TTL else None

    def _prune(self, now):
        self.pending = {k: v for k, v in self.pending.items() if now - v[2] < PENDING_TTL}
        self.intents = {k: v for k, v in self.intents.items() if now - v[1] < INTENT_TTL}
        self.stations = {k: v for k, v in self.stations.items() if now - v[1] < STATIONS_TTL}
        self.anchors = {k: v for k, v in self.anchors.items() if now - v[1] < PENDING_TTL}
        self.data_at = {k: v for k, v in self.data_at.items() if now - v < NEAR_GAP}
        self.live = {k: v for k, v in self.live.items() if v.alive(now)}
        self.stopped = {k: v for k, v in self.stopped.items() if now < v[1]}
        self._prune_recent(now)

    def _prune_recent(self, now):
        fresh = {}
        for who, by_category in self.recent.items():
            kept = {c: [r for r in rows if now - r[0] < AMEND_WINDOW] for c, rows in by_category.items()}
            kept = {c: rows for c, rows in kept.items() if rows}
            if kept:
                fresh[who] = kept
        self.recent = fresh

    def _own_ids(self, who):
        return {rid for rows in self.recent.get(who, {}).values() for _, _, rid in rows}

    # --- вход -------------------------------------------------------------------

    def handle(self, update):
        now = self.now()
        self._memo = {}
        try:
            self._prune(now)
            if "callback_query" in update:
                return self._callback(update["callback_query"], now)
            if "edited_message" in update:
                return self._edited(update["edited_message"], now)
            return self._message(update.get("message") or {}, now)
        finally:
            self._memo = {}

    def _message(self, message, now):
        chat = (message.get("chat") or {}).get("id")
        sender = message.get("from") or {}
        user = sender.get("id")
        if chat is None or user is None:
            return
        code = sender.get("language_code")
        text = message.get("text")
        if isinstance(text, str):
            word, rest = parse_command(text)
            if word == "/stop":
                return self._stop(chat, user, code, now)
            if self.family is not None:
                reply = self.family.command(text, chat, code, now)
                if reply is not None:
                    self.send("sendMessage", {"chat_id": chat, "text": reply})
                    return
            return self._command(word, text, chat, user, code, now)
        location = message.get("location")
        if location:
            return self._location(message, location, chat, user, code, now)
        who = self._who(user, now)
        lang = self._lang(who, code)
        self._say(chat, lang, "start", reply_keyboard(lang))

    # --- команды ------------------------------------------------------------------

    def _command(self, word, text, chat, user, code, now):
        who = self._who(user, now)
        lang = self._lang(who, code)
        if word in ("/near", "/report", "/metan") or text.strip() in METAN_LABELS:
            intent = {"/near": "near", "/report": "report"}.get(word, "metan")
            return self._ask_or_answer(intent, chat, who, lang, now)
        if word == "/help":
            return self._say(chat, lang, "help", reply_keyboard(lang))
        if word == "/privacy":
            return self._post(chat, bot_texts.text(lang, "privacy", url=self.config.get("privacy_url")
                                                   or DEFAULT_PRIVACY_URL))
        if word == "/app":
            url = (self.config.get("app_url") or "").strip()
            return self._post(chat, bot_texts.text(lang, "app_link", url=url) if url
                              else bot_texts.text(lang, "app_soon"))
        if word == "/lang":
            return self._say(chat, lang, "lang_pick", keyboard([[("lang:ru", "Русский"), ("lang:uz", "Oʻzbekcha")]]))
        if word == "/pereval":
            return self._pereval(chat, lang, now)
        if word == "/city":
            if not self._extras():
                return self._say(chat, lang, "off")
            cities = [(f"ct:{i}", bot_texts.city_name(city[0], lang))
                      for i, city in enumerate(telegram_publish.CITIES)]
            return self._say(chat, lang, "city_pick", keyboard(chunks(cities, 3)))
        if word == "/my":
            return self._my(chat, lang, now)
        if word == "/stats" and self._is_owner(user):
            return self._post(chat, self._stats_text(now))
        return self._say(chat, lang, "start", reply_keyboard(lang))

    def _ask_or_answer(self, intent, chat, who, lang, now):
        """/near, /report, /metan: есть свежая точка — ответ по ней; нет —
        попросить геопозицию и запомнить, зачем она (10 минут, в памяти)."""
        if intent != "report" and not self._extras():
            return self._say(chat, lang, "off", reply_keyboard(lang))
        point = self._point(who, now)
        if point is None:
            self.intents[who] = (intent, now)
            key = "need_location_report" if intent == "report" else "need_location"
            return self._say(chat, lang, key, reply_keyboard(lang))
        if intent == "report":
            return self._say(chat, lang, "pick", kinds_keyboard(lang))
        if intent == "metan":
            return self._metan(chat, who, lang, point, now)
        return self._near(chat, who, lang, point, bot_near.NEAR_RADIUS, now)

    def _is_owner(self, user):
        expected = (self.config.get("owner_hash") or "").strip().lower()
        return bool(expected) and hmac.compare_digest(owner_hash_of(self.salt, user), expected)

    # --- геопозиция ----------------------------------------------------------------

    def _location(self, message, location, chat, user, code, now):
        who = self._who(user, now)
        lang = self._lang(who, code)
        point = (float(location["latitude"]), float(location["longitude"]))
        self.pending[who] = (point[0], point[1], now)
        self.anchors.pop(who, None)          # станция из прошлого /metan — не для новой точки
        intent = self.intents.pop(who, (None, 0))[0]
        if not self._extras() or intent == "report":
            return self._say(chat, lang, "pick", kinds_keyboard(lang))
        if location.get("live_period"):
            return self._live_start(message, location, chat, who, lang, point, now)
        if intent == "metan":
            return self._metan(chat, who, lang, point, now)
        return self._near(chat, who, lang, point, bot_near.NEAR_RADIUS, now)

    def _near(self, chat, who, lang, point, radius, now, limit=True):
        if limit and not self._allow_data(who, now):
            return self._say(chat, lang, "near_slow", kinds_keyboard(lang))
        text, shown = bot_near.near_card(lang, self.sources, point, radius, now)
        self.stats["near"] += 1
        buttons = [("mark", bot_texts.text(lang, "btn_mark"))]
        if radius < bot_near.FAR_RADIUS:
            buttons.append(("near15", bot_texts.text(lang, "btn_further")))
        self._post(chat, text, keyboard([buttons]))
        return shown

    def _metan(self, chat, who, lang, point, now):
        if not self._allow_data(who, now):
            return self._say(chat, lang, "near_slow", kinds_keyboard(lang))
        text, markable = bot_near.metan_list(lang, self.sources, point)
        self.stats["metan"] += 1
        rows = []
        if markable:
            self.stations[who] = (markable, now)
            rows = [[(f"cs:{index}", bot_texts.text(lang, "btn_cng_mark", name=bot_near.short(
                venue[2] or bot_texts.text(lang, "cng_station"), 32)))] for index, venue in markable]
        self._post(chat, text, keyboard(rows) if rows else None)

    # --- трансляция (23.4) ------------------------------------------------------------

    @staticmethod
    def _live_until(message, location, now):
        period = location.get("live_period")
        start = message.get("date") if bot_near._number(message.get("date")) else now
        if not bot_near._number(period) or period <= 0:
            return None
        return start + min(float(period), bot_near.LIVE_MAX_SECONDS)

    def _live_start(self, message, location, chat, who, lang, point, now):
        until = self._live_until(message, location, now)
        session = bot_near.LiveSession(now, (until or now) - now, own=self._own_ids(who))
        session.started = message.get("date")
        session.move(point)
        self.stopped.pop(who, None)
        self.live[who] = session          # одна трансляция на человека: новая заменяет старую
        self.stats["live"] += 1
        self._say(chat, lang, "live_on")
        shown = self._near(chat, who, lang, point, bot_near.NEAR_RADIUS, now, limit=False) or set()
        session.announced.update(("r", rid) for rid in shown)

    def _edited(self, message, now):
        location = message.get("location")
        chat = (message.get("chat") or {}).get("id")
        sender = message.get("from") or {}
        user = sender.get("id")
        if not location or chat is None or user is None:
            return
        who = self._who(user, now)
        session = self.live.get(who)
        until = self._live_until(message, location, now)
        if until is None or now >= until:
            # Трансляцию остановили (правка без live_period) или срок вышел.
            self.live.pop(who, None)
            return
        if who in self.stopped and self.stopped[who][0] == message.get("date"):
            return                          # остановлена /stop — её правки молчат
        if not self._extras():
            return
        lang = self._lang(who, sender.get("language_code"))
        point = (float(location["latitude"]), float(location["longitude"]))
        # «Отметить, что видите» во время трансляции — в той точке, где человек сейчас.
        self.pending[who] = (point[0], point[1], now)
        if session is None:
            # Бот перезапускался посреди трансляции — начинаем заново.
            return self._live_start(message, location, chat, who, lang, point, now)
        session.until = until
        session.own |= self._own_ids(who)
        session.move(point)
        mobile = self.sources.mobile.value() if self.sources.mobile is not None else None
        road = self.sources.road.value() if self.sources.road is not None else None
        report = session.passed(point, now, mobile)
        if report is not None:
            word = bot_texts.KIND_WORDS[lang].get(report["type"], bot_texts.KIND_WORDS[lang]["radar"])
            rid = report["id"]
            self._say(chat, lang, "live_still", keyboard([[
                (f"pv:{rid}:y", bot_texts.text(lang, "btn_yes")), (f"pv:{rid}:n", bot_texts.text(lang, "btn_no")),
                (f"pv:{rid}:x", bot_texts.text(lang, "btn_unseen"))]]), kind=word)
        cameras = (self.sources.cameras.around(point[0], point[1], bot_near.LIVE_CAMERA_AHEAD)
                   if self.sources.cameras is not None else None)
        found = session.ahead(point, now, (mobile or []) + (road or []), cameras)
        if found:
            self._post(chat, bot_near.live_text(lang, found, point, now, self.sources))

    # --- перевалы, мои подписки, /stop -------------------------------------------------

    def _pereval(self, chat, lang, now):
        if not self._extras():
            return self._say(chat, lang, "off")
        statuses = bot_near.pass_status(self.sources.weather(), now)
        buttons = [[(f"ps:{group}", bot_texts.text(lang, "btn_pass_sub", name=bot_near.pass_name(lang, item, group)))]
                   for group, item in statuses.items()]
        self._post(chat, bot_near.pereval_text(lang, statuses), keyboard(buttons) if buttons else None)

    def _my(self, chat, lang, now):
        tag = self._tag(chat)
        try:
            family = self.family.listed(tag) if self.family is not None else []
            own = bot_subs.listed(self.db, tag, now)
        except sqlite3.Error as error:
            log(f"/my не прочитан — {type(error).__name__}")
            return self._say(chat, lang, "unknown_busy")
        if not family and not own:
            return self._say(chat, lang, "my_none")
        statuses = bot_near.pass_status(self.sources.weather(), now) if self.sources is not None else {}
        lines, rows = [bot_texts.text(lang, "my_head")], []
        for sid, created in family:
            date = time.strftime("%d.%m", time.gmtime(created + bot_near.TASHKENT))
            lines.append(bot_texts.text(lang, "my_family", date=date))
            rows.append([(f"rm:f:{sid}", bot_texts.text(lang, "btn_remove",
                                                         what=bot_texts.text(lang, "btn_family", date=date)))])
        for sid, kind, target in own:
            name = bot_subs.target_name(kind, target, lang, statuses)
            lines.append(bot_texts.text(lang, "my_city" if kind == "city" else "my_pass", city=name, name=name))
            rows.append([(f"rm:b:{sid}", bot_texts.text(lang, "btn_remove", what=name))])
        self._post(chat, "\n".join(lines), keyboard(rows))

    def _stop(self, chat, user, code, now):
        tag = self._tag(chat)
        who = self._who(user, now)
        lang = self._lang(who, code)
        removed = 0
        try:
            if self.family is not None:
                removed += self.family.stop_tag(tag)
            removed += bot_subs.stop(self.db, tag)
        except sqlite3.Error as error:
            log(f"/stop не выполнен — {type(error).__name__}")
            return self._say(chat, lang, "unknown_busy")
        session = self.live.pop(who, None)
        stopped_live = session is not None
        if stopped_live:
            self.stopped[who] = (session.started, session.until)
        self.intents.pop(who, None)
        parts = []
        if removed or not stopped_live:
            parts.append(bot_texts.text(lang, "stop_done" if removed else "stop_none"))
        if stopped_live:
            parts.append(bot_texts.text(lang, "stop_live"))
        self._post(chat, " ".join(parts), reply_keyboard(lang))

    def _stats_text(self, now):
        """Только владельцу: числа, ни одного хэша и номера."""
        day = _day(now)
        try:
            accepted = self.db.execute("SELECT COALESCE(SUM(count), 0), COUNT(*) FROM bot_limits WHERE day = ?",
                                       (day,)).fetchone()
            subs = bot_subs.counts(self.db)
            family = (self.family.conn.execute("SELECT COUNT(*), COUNT(DISTINCT chat) FROM family_subs").fetchone()
                      if self.family is not None else (0, 0))
        except sqlite3.Error as error:
            return f"Статистика не прочитана — {type(error).__name__}"
        cities = ", ".join(f"{target} {n}" for (kind, target), n in sorted(subs.items()) if kind == "city") or "нет"
        passes = ", ".join(f"{target} {n}" for (kind, target), n in sorted(subs.items()) if kind == "pass") or "нет"
        delivery = {"sent": 0, "failed": 0, "gone": 0, "drop": 0}
        for courier in self.couriers:
            for key in delivery:
                delivery[key] += courier.totals.get(key, 0)
        return (f"📊 Бот, {day} (Ташкент)\n"
                f"Отметок принято сегодня: {accepted[0]} (людей: {accepted[1]})\n"
                f"С запуска: «что рядом» {self.stats['near']}, метан {self.stats['metan']}, "
                f"трансляций {self.stats['live']} (сейчас {len(self.live)}), «ещё стоит?» {self.stats['votes']}, "
                f"отмен {self.stats['cancelled']}\n"
                f"Близкие: подписок {family[0]}, чатов {family[1]}\n"
                f"Города: {cities}\nПеревалы: {passes}\n"
                f"Доставка с запуска: ушло {delivery['sent']}, не доставлено {delivery['failed']}, "
                f"отказ Telegram {delivery['drop']}, чат закрыт {delivery['gone']}")

    # --- кнопки ---------------------------------------------------------------------

    def _station(self, point):
        """(АГНКС, None) или (None, ключ текста отказа)."""
        if self.venues is None:
            return None, "cng_unavailable"
        try:
            venue = self.venues.nearest(point[0], point[1])
        except VenueSourceError:
            return None, "cng_unavailable"
        return (venue, None) if venue else (None, "cng_far")

    def _callback(self, query, now):
        sender = query.get("from") or {}
        user = sender.get("id")
        chat = ((query.get("message") or {}).get("chat") or {}).get("id")
        data = query.get("data") or ""
        self.send("answerCallbackQuery", {"callback_query_id": query.get("id")})
        if user is None or chat is None or not isinstance(data, str):
            return
        head, _, rest = data.partition(":")
        kinds = dict(REPORT_KINDS)
        cng = dict(CNG_KINDS)
        if data not in kinds and data not in cng and head not in CALLBACKS:
            return
        # Хэш — один раз на нажатие: устройство и адрес — срезы того же хэша.
        who = self._who(user, now)
        lang = self._lang(who, sender.get("language_code"))
        if head in CALLBACKS:
            return getattr(self, CALLBACKS[head])(rest, chat, who, lang, now)
        say = lambda key, markup=None: self._say(chat, lang, key, markup)
        point = self.pending.get(who)
        if point is None:
            return say("expired")
        anchor = self.anchors.get(who)
        if data == "cng":
            venue, refusal = (anchor[0], None) if anchor else self._station(point)
            if refusal:
                return say(refusal)
            text = (bot_texts.text(lang, "pick_cng_at", name=venue[2]) if venue[2]
                    else bot_texts.text(lang, "pick_cng"))
            return self.send("sendMessage", {"chat_id": chat, "text": text, "reply_markup": cng_keyboard(lang)})
        if limit_reached(self.db, who, now):
            return say("limit")
        device, ip = device_of(who), pseudo_ip_of(who)
        markup = None
        if data in cng:
            # Проверка заново, а не память о первом ряде: callback_data
            # присылает клиент, и «nogas» может прийти без «метана» до него.
            # Станция из /metan — тоже проверенная: её номер выдал бот, а
            # расстояние до человека сверено при выборе.
            venue, refusal = (anchor[0], None) if anchor else self._station(point)
            if refusal:
                return say(refusal)
            status, answer = self.api_post("/api/cng", {"lat": venue[0], "lon": venue[1],
                                                        "kind": data, "device": device}, ip)
            text = "cng_ok"
        else:
            category = category_of(data)
            mine = self.recent.get(who, {}).get(category, [])
            if too_soon(mine, data, now):
                return say("slow")
            status, answer = self.api_post("/api/report", {"lat": point[0], "lon": point[1],
                                                           "type": data, "device": device}, ip)
            if status == 200:
                text = self._remember(who, category, data, answer, now)
                if text == "created" and isinstance(answer.get("id"), int):
                    markup = keyboard([[(f"cx:{answer['id']}", bot_texts.text(lang, "btn_cancel"))]])
        if status == 429:
            # Точка остаётся: подождал — нажал ту же кнопку ещё раз.
            return say("slow" if answer.get("error") == "too fast" else "busy")
        if status != 200:
            return say("error")
        count_accepted(self.db, who, now)
        del self.pending[who]
        self.anchors.pop(who, None)
        say(text, markup)

    def _remember(self, who, category, rtype, answer, now):
        """Ответ 200 → текст; созданная отметка начинает интервал, как в API."""
        rows = self.recent.setdefault(who, {}).setdefault(category, [])
        if answer.get("amended"):
            # Уточнение: строка та же, время создания то же, тип — новый.
            rows[:] = [(t, rtype, rid) if rid == answer.get("id") else (t, kind, rid)
                       for t, kind, rid in rows]
            return "amended"
        if answer.get("merged"):
            return "merged"     # голос в чужую отметку — своей строки нет
        rows.append((now, rtype, answer.get("id")))
        return "created"

    def _on_mark(self, rest, chat, who, lang, now):
        if self._point(who, now) is None:
            return self._say(chat, lang, "expired")
        self._say(chat, lang, "pick", kinds_keyboard(lang))

    def _on_further(self, rest, chat, who, lang, now):
        point = self._point(who, now)
        if point is None:
            return self._say(chat, lang, "expired")
        if not self._extras():
            return self._say(chat, lang, "off")
        self._near(chat, who, lang, point, bot_near.FAR_RADIUS, now)

    def _on_station(self, rest, chat, who, lang, now):
        listed = self.stations.get(who)
        choice = dict(listed[0]).get(int(rest)) if listed and rest.isdigit() else None
        point = self._point(who, now)
        if choice is None or point is None:
            return self._say(chat, lang, "expired")
        if haversine(point[0], point[1], choice[0], choice[1]) > bot_near.CNG_MARK_MAX_METERS:
            return self._say(chat, lang, "cng_too_far")
        self.anchors[who] = (choice, now)
        text = (bot_texts.text(lang, "pick_cng_at", name=choice[2]) if choice[2]
                else bot_texts.text(lang, "pick_cng"))
        self.send("sendMessage", {"chat_id": chat, "text": text, "reply_markup": cng_keyboard(lang)})

    def _on_vote(self, rest, chat, who, lang, now):
        rid, _, answer = rest.partition(":")
        session = self.live.get(who)
        if not rid.isdigit() or answer not in ("y", "n", "x"):
            return
        rid = int(rid)
        if session is None or not session.answerable(rid, now):
            return self._say(chat, lang, "vote_gone")
        session.asked[rid] = float("-inf")       # ответ один: второй тап — «уже погасла»
        if answer == "x":
            # «Не видел» не отправляется вовсе: «не знаю» портит данные хуже
            # тишины (то же правило, что у приложения).
            return self._say(chat, lang, "vote_skip")
        status, _ = self.api_post("/api/vote", {"id": rid, "device": device_of(who),
                                                "value": 1 if answer == "y" else -1, "kind": "pass"},
                                  pseudo_ip_of(who))
        if status == 200:
            self.stats["votes"] += 1
            return self._say(chat, lang, "vote_thanks")
        self._say(chat, lang, "vote_gone" if status == 404 else "busy" if status == 429 else "error")

    def _on_cancel(self, rest, chat, who, lang, now):
        if not rest.isdigit():
            return
        rid = int(rest)
        found = None
        for category, rows in self.recent.get(who, {}).items():
            for row in rows:
                if row[2] == rid:
                    found = (category, row)
        if found is None or now - found[1][0] > CANCEL_WINDOW:
            return self._say(chat, lang, "cancel_late")
        status, answer = self.api_post("/api/report/cancel", {"id": rid, "device": device_of(who)},
                                       pseudo_ip_of(who))
        if status == 200:
            # Погашенная отметка интервал API больше не держит — и наша копия тоже.
            self.recent[who][found[0]].remove(found[1])
            self.stats["cancelled"] += 1
            return self._say(chat, lang, "cancelled")
        if status == 409:
            return self._say(chat, lang, "cancel_confirmed" if answer.get("error") == "confirmed by others"
                             else "cancel_late")
        self._say(chat, lang, "error")

    def _on_lang(self, rest, chat, who, lang, now):
        if rest not in bot_texts.LANGS:
            return
        try:
            bot_subs.set_lang(self.db, who, rest, now)
        except sqlite3.Error as error:
            log(f"язык не сохранён — {type(error).__name__}")
            return self._say(chat, lang, "unknown_busy")
        self._say(chat, rest, "lang_set", reply_keyboard(rest))

    def _on_pass(self, rest, chat, who, lang, now):
        if not self._extras():
            return self._say(chat, lang, "off")
        statuses = bot_near.pass_status(self.sources.weather(), now)
        if rest not in statuses and rest not in bot_subs.PASS_NAMES:
            return
        item = statuses.get(rest)
        name = bot_subs.target_name("pass", rest, lang, statuses)
        if not self._subscribe("pass", rest, chat, lang, now):
            return self._say(chat, lang, "unknown_busy")
        text = bot_texts.text(lang, "pass_subscribed", where=bot_subs.target_where(rest, lang, statuses))
        if item is not None:
            text += "\n" + bot_texts.text(lang, "pereval_line", name=name, what=bot_near.pass_what(lang, item))
        self._post(chat, text)

    def _on_city(self, rest, chat, who, lang, now):
        if not self._extras():
            return self._say(chat, lang, "off")
        if not rest.isdigit() or int(rest) >= len(telegram_publish.CITIES):
            return
        city = telegram_publish.CITIES[int(rest)][0]
        if not self._subscribe("city", city, chat, lang, now):
            return self._say(chat, lang, "unknown_busy")
        self._say(chat, lang, "city_subscribed", city=bot_texts.city_name(city, lang))

    def _subscribe(self, kind, target, chat, lang, now):
        try:
            return bot_subs.subscribe(self.db, kind, target, self._tag(chat),
                                      family_notify.seal_key(self.subs_key, chat), lang, now)
        except sqlite3.Error as error:
            log(f"подписка не сохранена — {type(error).__name__}")
            return False

    def _on_remove(self, rest, chat, who, lang, now):
        source, _, sid = rest.partition(":")
        if source not in ("f", "b") or not sid.isdigit():
            return
        tag = self._tag(chat)
        try:
            if source == "f":
                done = self.family is not None and self.family.remove(tag, int(sid))
            else:
                done = bot_subs.remove(self.db, tag, int(sid))
        except sqlite3.Error as error:
            log(f"подписка не снята — {type(error).__name__}")
            return self._say(chat, lang, "unknown_busy")
        self._say(chat, lang, "removed" if done else "remove_missing")


#: Кнопки «вид:данные» → обработчик Bot.
CALLBACKS = {"mark": "_on_mark", "near15": "_on_further", "cs": "_on_station", "pv": "_on_vote",
             "cx": "_on_cancel", "lang": "_on_lang", "ps": "_on_pass", "ct": "_on_city", "rm": "_on_remove"}


# --- профиль бота (23.1) ------------------------------------------------------------

def profile_calls():
    """Вызовы Bot API, которые выставляют профиль: имя, описания, меню на
    ru и uz и по умолчанию (русское), кнопка меню — список команд."""
    calls = []
    for lang in (None,) + bot_texts.LANGS:
        profile = bot_texts.PROFILE[lang or "ru"]
        extra = {"language_code": lang} if lang else {}
        calls.append(("setMyName", dict(extra, name=profile["name"])))
        calls.append(("setMyShortDescription", dict(extra, short_description=profile["short"])))
        calls.append(("setMyDescription", dict(extra, description=profile["description"])))
        calls.append(("setMyCommands", dict(extra, commands=[
            {"command": command, "description": profile["commands"][command]} for command in bot_texts.COMMANDS])))
    calls.append(("setChatMenuButton", {"menu_button": {"type": "commands"}}))
    return calls


def ensure_profile(send, db, logger=log):
    """Выставить профиль, только если он изменился: отпечаток последнего
    выставленного — в bot_meta. Сбой любого вызова — отпечаток не пишется,
    попытка при следующем запуске (setMyName у Telegram ещё и с лимитом)."""
    calls = profile_calls()
    digest = hashlib.sha256(json.dumps(calls, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    row = db.execute("SELECT value FROM bot_meta WHERE key = 'profile'").fetchone()
    if row and row[0] == digest:
        return False
    for method, payload in calls:
        try:
            answer = send(method, payload)
        except Exception as error:      # сеть, 400, 429 — профиль подождёт перезапуска
            logger(f"профиль не выставлен ({method}) — {type(error).__name__}")
            return False
        if isinstance(answer, dict) and answer.get("ok") is False:
            logger(f"профиль не выставлен ({method}) — Telegram отказал")
            return False
    with db:
        db.execute("INSERT OR REPLACE INTO bot_meta(key, value) VALUES('profile', ?)", (digest,))
    logger("профиль и меню выставлены")
    return True

# --- сеть ----------------------------------------------------------------------------

def read_config(path):
    if not os.path.exists(path):
        return None
    config = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if "=" in line and not line.strip().startswith("#"):
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()
    return config if config.get("token") and config.get("salt") else None


def telegram(token, method, payload, timeout=40):
    request = urllib.request.Request(TG_API.format(token=token, method=method),
                                     data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def _json_or_empty(blob):
    try:
        value = json.loads(blob or b"{}")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def api_post(path, body, pseudo_ip):
    """(статус, тело). Тело ошибки читается тоже: «too fast» отличает
    интервал от прочих 429. API не отвечает — (0, {}): «не получилось»."""
    request = urllib.request.Request(API_BASE + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "X-Real-IP": pseudo_ip})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, _json_or_empty(response.read())
    except urllib.error.HTTPError as error:
        return error.code, _json_or_empty(error.read())
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        log(f"API недоступен — {type(error).__name__}")
        return 0, {}


def api_get(path):
    """GET к API (списки отметок, метан). (статус, тело); недоступно — (0, {})."""
    try:
        with urllib.request.urlopen(API_BASE + path, timeout=10) as response:
            return response.status, _json_or_empty(response.read())
    except urllib.error.HTTPError as error:
        return error.code, {}
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        log(f"API недоступен — {type(error).__name__}")
        return 0, {}


def start_family(config, send, path=None):
    """Подписки близких и поток доставки. Не открылась база — без них:
    отметки водителей важнее, бот поднимается всё равно."""
    path = path or family_notify.DB_PATH
    if family_notify.clean_username(config.get("username")) is None:
        log("в конфиге нет username — страница близкого не покажет ссылку на бота")
    try:
        family_notify.init_db(path)
        commands = family_notify.FamilyCommands(family_notify.connect(path), config["salt"],
                                                kdf=lambda password, salt: _kdf(password, salt))
    except sqlite3.Error as error:
        log(f"близкие: база не открылась — {type(error).__name__}; подписки выключены")
        return None
    courier = family_notify.Courier(send, path=path)
    commands.courier = courier
    threading.Thread(target=courier.run, name="family-courier", daemon=True).start()
    return commands


def delivery_loop(pusher, courier, pult, stop=None, sleep=time.sleep):
    """Поток подписок бота: Pusher решает, что прислать (город, перевалы),
    Courier из family_notify разбирает bot_outbox. Сбой прохода не убивает
    поток — журнал и пауза, как у очереди близких."""
    while stop is None or not stop.is_set():
        pause = family_notify.DRAIN_INTERVAL
        try:
            pusher.step(enabled=pult is None or pult.enabled())
            courier.step()
        except Exception as error:
            log(f"подписки бота: проход не удался — {type(error).__name__}")
            pause = family_notify.FAILURE_PAUSE
            for owner in (pusher, courier):
                if owner._conn is not None:
                    try:
                        owner._conn.close()
                    except sqlite3.Error:
                        pass
                    owner._conn = None
        sleep(pause)


def start_delivery(config, send, db_path, sources, pult):
    """Подписки на город и перевалы: свой поток, свои соединения с bot.db."""
    key = bot_subs.box_key(config["salt"])
    pusher = bot_subs.Pusher(db_path, key, sources, reports_db=config.get("reports_db") or DEFAULT_REPORTS_DB)
    courier = family_notify.Courier(send, path=db_path, outbox="bot_outbox", subs="bot_subs",
                                    sweeper=lambda conn, now: bot_subs.sweep(conn, now, key),
                                    extra={"disable_web_page_preview": True})
    threading.Thread(target=delivery_loop, args=(pusher, courier, pult), name="bot-delivery", daemon=True).start()
    return courier


def build_sources(config):
    webroot = config.get("webroot") or DEFAULT_WEBROOT
    venues_dir = config.get("venues_dir") or DEFAULT_VENUES_DIR
    venues = CngVenues(venues_dir)
    sources = bot_near.Sources(
        api_get=api_get,
        cameras=bot_near.CameraDb(config.get("cameras_path") or os.path.join(webroot, "cameras.json")),
        venues=venues,
        addresses=bot_near.Addresses(venues_dir),
        weather_path=config.get("weather_path") or os.path.join(webroot, "weather", "roads.json"))
    pult = bot_near.Pult(config.get("pult_path") or os.path.join(webroot, "config.json"))
    return venues, sources, pult


def print_owner_hash(config, stream=sys.stdin, out=sys.stdout):
    """`--owner-hash`: id владельца читается со stdin (не из аргументов — не
    останется в истории оболочки), печатается строка для конфига."""
    raw = stream.readline().strip()
    if not raw.isdigit():
        print("нужен числовой Telegram-id (его показывает, например, @userinfobot)", file=sys.stderr)
        return 1
    print(f"owner_hash={owner_hash_of(config['salt'], int(raw))}", file=out)
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    config = read_config(os.environ.get("RADARMAP_BOT_CONFIG", DEFAULT_CONFIG))
    if config is None:
        print("telegram_bot: нет конфига (token, salt) — бот не запущен")
        return 0
    if not hasattr(hashlib, "scrypt"):
        # Без scrypt хэш пришлось бы считать sha256 — то есть молча снять
        # защиту прошлых отметок от перебора (см. «Почему scrypt»).
        print("telegram_bot: в этом Python нет hashlib.scrypt (нужен OpenSSL ≥ 1.1) — бот не запущен")
        return 0
    if argv[:1] == ["--owner-hash"]:
        return print_owner_hash(config)
    token = config["token"]
    send = lambda method, payload: telegram(token, method, payload, timeout=15)
    db_path = os.environ.get("RADARMAP_BOT_DB", DEFAULT_DB)
    db = open_db(db_path)
    venues, sources, pult = build_sources(config)
    family = start_family(config, send)
    couriers = [start_delivery(config, send, db_path, sources, pult)]
    if family is not None:
        couriers.append(family.courier)
    try:
        ensure_profile(send, db)
    except sqlite3.Error as error:
        log(f"профиль: bot.db не читается — {type(error).__name__}")
    bot = Bot(config["salt"], db, send=send, api_post=api_post, venues=venues, family=family,
              sources=sources, pult=pult, config=config, couriers=couriers)
    offset = 0
    pruned_at = 0.0
    while True:
        if time.time() - pruned_at >= BOT_LIMITS_PRUNE_SECONDS:
            pruned_at = time.time()
            try:
                prune_limits(bot.db, pruned_at)
            except sqlite3.Error as error:
                log(f"чистка счётчиков не удалась — {type(error).__name__}")
        try:
            answer = telegram(token, "getUpdates", {"timeout": 30, "offset": offset,
                                                    "allowed_updates": ALLOWED_UPDATES})
            for update in answer.get("result", []):
                offset = max(offset, update["update_id"] + 1)
                try:
                    bot.handle(update)
                except Exception as error:   # одно плохое сообщение не роняет бота
                    print(f"telegram_bot: сообщение не обработано — {type(error).__name__}", file=sys.stderr)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            print(f"telegram_bot: Telegram недоступен — {type(error).__name__}", file=sys.stderr)
            time.sleep(5)


if __name__ == "__main__":
    sys.exit(main())
