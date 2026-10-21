#!/usr/bin/env python3
"""telegram_bot.py — отметки водителей через Telegram (план 19.10, 12б.7).

Водители уже сидят в Telegram-чатах «где стоят». Канал (telegram_publish.py)
отдаёт им подтверждённое; бот замыкает круг — принимает отметки тех, у кого
приложения нет: геопозиция → тип кнопкой → тот же POST /api/report, что у
приложения, с тем же жизненным циклом доверия (испытательный срок,
подтверждение независимым водителем).

КАК ЭТО РАБОТАЕТ
  * человек шлёт геопозицию («Отправить местоположение» в Telegram);
  * бот отвечает кнопками: радар, тренога, пост, ДТП, перекрыто, метан;
  * «метан» — второй ряд: газ есть / нет / очередь; уходит в POST /api/cng;
  * точка без типа живёт 10 минут в памяти и забывается.

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
Нет конфига — выход 0 с сообщением. Соль не менять: от неё и хэши
подписок близких — со сменой их /stop перестанет находить.

ЗАПУСК: long polling (getUpdates), без вебхука и открытых портов —
systemd-юнит radarmap-bot.service. Тесты без сети: test_telegram_bot.py.
"""
import hashlib
import json
import math
import os
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request

import family_notify

DEFAULT_CONFIG = "/opt/radarmap/telegram_bot.conf"
DEFAULT_DB = "/opt/radarmap/api/bot.db"
#: Опубликованные файлы заведений — каталог `roads/` webroot (publish_roads.sh).
DEFAULT_VENUES_DIR = "/opt/radarmap/www/roads"
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

#: Кнопки типа → тип API. «Метан» открывает второй ряд.
REPORT_KINDS = [("radar", "📡 Радар"), ("tripod", "📷 Тренога"), ("post", "👮 Пост"),
                ("accident", "💥 ДТП"), ("closure", "⛔ Перекрыто"), ("cng", "⛽ Метан")]
CNG_KINDS = [("gas", "✅ Газ есть"), ("nogas", "❌ Газа нет"),
             ("queue15", "⏳ Очередь ~15 мин"), ("queue60", "⏳ Очередь 30+ мин")]

TEXTS = {
    "start": ("Отправьте геопозицию (📎 → Геопозиция) — и выберите, что там: "
              "радар, тренога, пост, ДТП, перекрытие или метан на заправке. "
              "Отметку увидят водители в приложении RadarMap и в канале."),
    "pick": "Что здесь?",
    "pick_cng": "Как на заправке?",
    "pick_cng_at": "Как на заправке «{name}»?",
    "expired": "Точка устарела — отправьте геопозицию ещё раз.",
    "limit": "На сегодня отметок достаточно — спасибо!",
    "slow": "Не так часто — подождите пару минут и нажмите ещё раз.",
    "busy": "Не так часто — отметок от вас сейчас достаточно, попробуйте позже.",
    "cng_far": "Рядом нет заправки метаном в нашей базе — отправьте геопозицию у самой колонки.",
    "cng_unavailable": "Отметки о метане сейчас не принимаются — попробуйте позже.",
    "created": "Отмечено. Спасибо! Точку увидят водители рядом.",
    "merged": "Рядом уже отмечено — ваш голос засчитан.",
    "amended": "Тип уточнён.",
    "cng_ok": "Спасибо! Статус заправки обновлён.",
    "error": "Не получилось отправить — попробуйте ещё раз чуть позже.",
}


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
    conn = sqlite3.connect(path)
    # `last` — время последней принятой отметки. Интервал по нему больше не
    # считается (он теперь по категориям и в памяти), колонка оставлена,
    # чтобы bot.db с сервера открывался без миграции.
    conn.execute("""CREATE TABLE IF NOT EXISTS bot_limits(
        who TEXT NOT NULL, day TEXT NOT NULL, count INTEGER NOT NULL, last REAL NOT NULL,
        PRIMARY KEY(who, day))""")
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


def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


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


class Bot:
    """Логика без сети: `send` и `api_post` подменяются в тестах."""

    def __init__(self, salt, db, send, api_post, now=time.time, venues=None, family=None):
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
        # Точки, ждущие типа: ключ — хэш человека (не id), значение — (lat, lon, ts).
        self.pending = {}
        # Созданные отметки для копии интервала API: хэш → категория →
        # [(время, тип, id отметки)]. Ни id человека, ни координат.
        self.recent = {}

    def handle(self, update):
        now = self.now()
        self.pending = {k: v for k, v in self.pending.items() if now - v[2] < PENDING_TTL}
        self._prune_recent(now)
        if "callback_query" in update:
            return self._callback(update["callback_query"], now)
        message = update.get("message") or {}
        chat = (message.get("chat") or {}).get("id")
        user = (message.get("from") or {}).get("id")
        if chat is None or user is None:
            return
        text = message.get("text")
        if self.family is not None and isinstance(text, str):
            reply = self.family.command(text, chat, (message.get("from") or {}).get("language_code"), now)
            if reply is not None:
                self.send("sendMessage", {"chat_id": chat, "text": reply})
                return
        location = message.get("location")
        if location:
            who = user_hash(self.salt, user, now)
            self.pending[who] = (float(location["latitude"]), float(location["longitude"]), now)
            self.send("sendMessage", {"chat_id": chat, "text": TEXTS["pick"],
                                      "reply_markup": keyboard(chunks(REPORT_KINDS, 3))})
            return
        self.send("sendMessage", {"chat_id": chat, "text": TEXTS["start"]})

    def _prune_recent(self, now):
        fresh = {}
        for who, by_category in self.recent.items():
            kept = {c: [r for r in rows if now - r[0] < AMEND_WINDOW] for c, rows in by_category.items()}
            kept = {c: rows for c, rows in kept.items() if rows}
            if kept:
                fresh[who] = kept
        self.recent = fresh

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
        user = (query.get("from") or {}).get("id")
        chat = ((query.get("message") or {}).get("chat") or {}).get("id")
        data = query.get("data") or ""
        self.send("answerCallbackQuery", {"callback_query_id": query.get("id")})
        kinds = dict(REPORT_KINDS)
        cng = dict(CNG_KINDS)
        if user is None or chat is None or (data not in kinds and data not in cng):
            return
        say = lambda key: self.send("sendMessage", {"chat_id": chat, "text": TEXTS[key]})
        # Хэш — один раз на нажатие: устройство и адрес — срезы того же хэша.
        who = user_hash(self.salt, user, now)
        point = self.pending.get(who)
        if point is None:
            return say("expired")
        if data == "cng":
            venue, refusal = self._station(point)
            if refusal:
                return say(refusal)
            text = TEXTS["pick_cng_at"].format(name=venue[2]) if venue[2] else TEXTS["pick_cng"]
            return self.send("sendMessage", {"chat_id": chat, "text": text,
                                             "reply_markup": keyboard(chunks(CNG_KINDS, 2))})
        if limit_reached(self.db, who, now):
            return say("limit")
        device, ip = device_of(who), pseudo_ip_of(who)
        if data in cng:
            # Проверка заново, а не память о первом ряде: callback_data
            # присылает клиент, и «nogas» может прийти без «метана» до него.
            venue, refusal = self._station(point)
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
        if status == 429:
            # Точка остаётся: подождал — нажал ту же кнопку ещё раз.
            return say("slow" if answer.get("error") == "too fast" else "busy")
        if status != 200:
            return say("error")
        count_accepted(self.db, who, now)
        del self.pending[who]
        say(text)

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
    threading.Thread(target=courier.run, name="family-courier", daemon=True).start()
    return commands


def main():
    config = read_config(os.environ.get("RADARMAP_BOT_CONFIG", DEFAULT_CONFIG))
    if config is None:
        print("telegram_bot: нет конфига (token, salt) — бот не запущен")
        return 0
    if not hasattr(hashlib, "scrypt"):
        # Без scrypt хэш пришлось бы считать sha256 — то есть молча снять
        # защиту прошлых отметок от перебора (см. «Почему scrypt»).
        print("telegram_bot: в этом Python нет hashlib.scrypt (нужен OpenSSL ≥ 1.1) — бот не запущен")
        return 0
    token = config["token"]
    send = lambda method, payload: telegram(token, method, payload, timeout=15)
    venues = CngVenues(config.get("venues_dir") or DEFAULT_VENUES_DIR)
    bot = Bot(config["salt"], open_db(os.environ.get("RADARMAP_BOT_DB", DEFAULT_DB)),
              send=send, api_post=api_post, venues=venues,
              family=start_family(config, send))
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
                                                    "allowed_updates": ["message", "callback_query"]})
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
