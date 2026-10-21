#!/usr/bin/env python3
"""family_notify.py — близкие в Telegram (план 21.10, этап 22.3).

Близкий открывает ссылку t.me/<бот>?start=f_<адрес> и подписывается; бот
присылает «едет домой — будет примерно в 18:40», «задерживается — теперь
около 18:52», «дома, 18:47». Без звонка водителю за рулём — в этом весь
смысл. Модуль общий для двух процессов:

  * api.py (eta_put) зовёт on_update на каждое принятое обновление ссылки:
    решает, пора ли писать (decide — чистая функция), и кладёт сообщения в
    очередь family_outbox. В Telegram api.py не ходит никогда: ответ
    телефону не ждёт чужой сети;
  * telegram_bot.py принимает /start f_<адрес> и /stop (FamilyCommands) и
    отдельным потоком разбирает очередь (Courier): sendMessage, повтор при
    сбое сети, снятие подписки, если чат закрыт.

Адрес — 43 знака base64url(sha256(ключ записи)), тот же, что в
/api/eta/f/<адрес> (14.12). Писать по нему может только телефон: право
записи — знание прообраза. Знание адреса даёт ровно то же, что страница:
подписаться и читать. Старые ссылки без ключа (22 знака) не подписываются —
по ним любой читатель мог бы прислать ложное «дома».

КОГДА ПИШЕМ (decide; тесты — test_family_notify.py)
  * первое «в пути» после тишины — «🚗 Зафар едет домой — будет примерно в
    18:40»; времени нет — «🚗 Зафар едет домой». Не «выехал»: имя задаёт
    водитель, и «Мама выехал» читала бы каждая семья, где за рулём женщина,
    а настоящее время в русском рода не знает;
  * время появилось посреди поездки (построили маршрут домой) — одно
    «🕒 будет дома примерно в 18:40», сразу: первое «едет домой» было без
    времени, и ждать с ним десять минут незачем;
  * время прибытия сдвинулось на DELAY_STEP и больше ПОЗЖЕ последнего
    объявленного, и с прошлого сообщения прошло NOTICE_GAP — «⏱ Зафар
    задерживается — теперь около 18:52». Раньше — не пишем: близкий ждёт к
    объявленному, «дома» придёт само;
  * «на месте» — «🏠 Зафар дома, 18:47», один раз: повтор в течение
    ARRIVED_HOLD молчит;
  * поездка кончилась не дома (ended) — ТИШИНА. «Не едет домой» тревожит
    сильнее молчания, а частый случай — остановка у магазина по дороге:
    если поездка продолжится в течение RESUME_WINDOW, это та же поездка, и
    близкий получит «задерживается», а не второе «едет домой». Страница
    ссылки и так скажет «сейчас не в пути».
  Обновлений нет TRIP_TTL — поездка забыта, следующее «в пути» — новая.
  Времена — по Ташкенту (UTC+5 круглый год) и так же, как на странице
  (секунды отбрасываются): сообщение и страница не спорят.

КОНТРАКТ С ТЕЛЕФОНОМ (поля записи, которую eta_put кладёт в память)
  status — driving / arrived / ended; eta — секунды Unix или нет (без
  маршрута и без «призрака» времени нет, и мы его не выдумываем); name — как
  водитель назвал себя для близких, до NAME_MAX знаков, только для текста
  (нет — «Водитель» / «Haydovchi»); home — необязательно: false значит
  поездка не домой (режим «Каждая поездка»), и тексты говорят «в пути» /
  «на месте» вместо «домой» / «дома». Нет поля — поездка домой.

ПРИВАТНОСТЬ
  * в подписке — sha256 адреса, scrypt-хэш номера чата (для /stop и капа на
    чат: соль бота, без 30-дневного окна — подписка живёт месяцами), язык,
    когда создана и когда водитель последний раз ездил. Сам номер чата —
    ЗАШИФРОВАН ключом из адреса (seal/unseal). Адреса на сервере нет: его
    приносит каждое обновление телефона. Украденная family.db не говорит,
    кто подписан, — номер чата открывается только в ту минуту, когда
    водитель сам пишет в свою ссылку. Чего шифр не даёт: адрес бывает в
    access.log nginx (страница /api/eta/f/<адрес>), и scrypt-хэш чата с
    солью перебирается — дорого, но не невозможно (как у хэша бота);
  * в очереди номер чата открыт — иначе боту некуда слать — и живёт до
    OUTBOX_TTL: устаревшее «едет домой» хуже никакого;
  * имени водителя на диске нет нигде, кроме текста сообщения в очереди (те
    же минуты). Истории времён прибытия нет: в family_trips — только
    последнее объявленное время ТЕКУЩЕЙ поездки, строка уходит с тишиной;
  * в журнал не пишутся ни номер чата, ни имя, ни текст — только виды
    событий и числа.

СРОКИ (RETENTION.md): /stop — сразу; закрытый чат (403) — при первой же
отправке; подписка, по которой водитель не ездил KEEP_DAYS дней, удаляется
сама (sweep: в потоке очереди бота и в часовом проходе api.py). Близкому об
этом не сказать — номер чата без адреса не открыть; подписаться снова — по
той же ссылке.
"""
import base64
import contextlib
import hashlib
import hmac
import json
import math
import os
import re
import sqlite3
import struct
import sys
import time
import urllib.error
import urllib.parse
from collections import namedtuple

DEFAULT_DB = "/opt/radarmap/api/family.db"
DB_PATH = os.environ.get("RADARMAP_FAMILY_DB", DEFAULT_DB)
#: Конфиг бота: отсюда же страница близкого берёт username для ссылки t.me.
DEFAULT_CONFIG = "/opt/radarmap/telegram_bot.conf"

#: /start f_<адрес>: 2 + 43 = 45 знаков из [A-Za-z0-9_-] — в пределах 64,
#: которые Telegram пропускает в параметре start.
START_PREFIX = "f_"
ADDRESS_LENGTH = 43

#: Капы: на одну ссылку (мама переслала папе) и на один чат (несколько
#: водителей в семье); общий — от потопа /start с выдуманными адресами.
MAX_PER_LINK = 5
MAX_PER_CHAT = 10
MAX_SUBSCRIPTIONS = 20000

#: = api.LIVE_MAX_DAYS: подписка без поездок водителя живёт столько (тест).
KEEP_DAYS = 55
#: Отметку «водитель ездил» обновляем не чаще раза в сутки — не запись на
#: каждое обновление ссылки.
SEEN_REFRESH = 86400
#: = api.ETA_TTL: без обновлений столько — поездки нет.
TRIP_TTL = 2 * 3600
#: Конец поездки не дома и снова «в пути» в этом окне — та же поездка.
RESUME_WINDOW = 30 * 60
#: = api.ETA_ARRIVED_TTL: «дома» повторно не пишем столько.
ARRIVED_HOLD = 30 * 60
#: «Задерживается»: сдвиг позже объявленного и промежуток между сообщениями.
DELAY_STEP = 5 * 60
NOTICE_GAP = 10 * 60
#: Сообщение, не ушедшее за столько, снимается: «едет домой» через
#: полчаса — уже неправда.
OUTBOX_TTL = 10 * 60
#: Паузы между попытками при сбое сети; последняя неудача — снять.
RETRY_DELAYS = (5, 20, 60)
SEND_ATTEMPTS = len(RETRY_DELAYS) + 1
DRAIN_BATCH = 20
DRAIN_INTERVAL = 2.0
#: После сбоя прохода (база пропала, диск) — пауза дольше: строка в журнал
#: раз в минуту, а не каждые 2 с.
FAILURE_PAUSE = 60.0
SWEEP_SECONDS = 3600
#: api.py не ждёт family.db дольше: обновление телефона важнее сообщения.
API_BUSY_TIMEOUT = 2.0
NAME_MAX = 32
TASHKENT = 5 * 3600

#: Таблица → потолок в днях (RETENTION.md, тест). Очередь и поездка живут
#: минуты и часы; целое число дней — формат документа.
RETENTION_DAYS = {"family_subs": KEEP_DAYS, "family_trips": 1, "family_outbox": 1}

#: Признаки закрытого чата в ответе 400 (403 — закрыт всегда).
GONE_HINTS = ("chat not found", "user is deactivated", "bot was blocked", "bot was kicked")

_ADDRESS = re.compile(r"^[A-Za-z0-9_-]{%d}$" % ADDRESS_LENGTH)
_USERNAME = re.compile(r"^[A-Za-z0-9_]{5,32}$")
# Управляющие знаки и направление письма: имя не должно ни переносить
# строку, ни переворачивать время в сообщении. ZWJ (U+200D) оставляем — на
# нём держатся смайлики-семьи.
_INVISIBLE = re.compile("[\u0000-\u001f\u007f-\u009f​‎‏"
                        "‪-‮⁠-⁩﻿]")

Trip = namedtuple("Trip", "phase eta noticed updated")

SCHEMA = (
    """CREATE TABLE IF NOT EXISTS family_subs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        link TEXT NOT NULL,
        chat TEXT NOT NULL,
        box TEXT NOT NULL,
        lang TEXT NOT NULL,
        created REAL NOT NULL,
        seen REAL NOT NULL,
        UNIQUE(link, chat))""",
    "CREATE INDEX IF NOT EXISTS family_subs_chat ON family_subs(chat)",
    "CREATE INDEX IF NOT EXISTS family_subs_seen ON family_subs(seen)",
    """CREATE TABLE IF NOT EXISTS family_trips(
        link TEXT PRIMARY KEY,
        phase TEXT NOT NULL,
        eta REAL,
        noticed REAL NOT NULL,
        updated REAL NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS family_outbox(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sub INTEGER NOT NULL,
        chat_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        created REAL NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_try REAL NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS family_outbox_next ON family_outbox(next_try)",
)

NOTICES = {
    "ru": {
        "driver": "Водитель",
        "departed": "🚗 {name} едет домой — будет примерно в {time}",
        "departed_bare": "🚗 {name} едет домой",
        "departed_away": "🚗 {name} в пути — будет на месте примерно в {time}",
        "departed_bare_away": "🚗 {name} в пути",
        "eta": "🕒 {name} будет дома примерно в {time}",
        "eta_away": "🕒 {name} будет на месте примерно в {time}",
        "delayed": "⏱ {name} задерживается — теперь около {time}",
        "delayed_away": "⏱ {name} задерживается — теперь около {time}",
        "arrived": "🏠 {name} дома, {time}",
        "arrived_away": "📍 {name} на месте, {time}",
    },
    "uz": {
        "driver": "Haydovchi",
        "departed": "🚗 {name} uyga ketyapti — taxminan {time} da yetib keladi",
        "departed_bare": "🚗 {name} uyga ketyapti",
        "departed_away": "🚗 {name} yoʻlda — taxminan {time} da yetib boradi",
        "departed_bare_away": "🚗 {name} yoʻlda",
        "eta": "🕒 {name} taxminan {time} da uyda boʻladi",
        "eta_away": "🕒 {name} taxminan {time} da yetib boradi",
        "delayed": "⏱ {name} kechikyapti — endi taxminan {time} da",
        "delayed_away": "⏱ {name} kechikyapti — endi taxminan {time} da",
        "arrived": "🏠 {name} uyda, {time}",
        "arrived_away": "📍 {name} yetib keldi, {time}",
    },
}

REPLIES = {
    "ru": {
        "subscribed": "Готово: сообщим, когда водитель поедет домой и когда доедет. Отписаться — /stop",
        "stopped": "Готово: подписка снята, больше не пишем. Подписаться снова — по ссылке от водителя.",
        "none": "Подписок нет — писать некому.",
        "bad_link": "Ссылка не подошла. Попросите водителя прислать её ещё раз.",
        "link_full": "На этого водителя уже подписаны {link_cap} человек — больше нельзя.",
        "chat_full": "Подписок уже {chat_cap} — больше нельзя. Отписаться от всех — /stop",
        "busy": "Сейчас не получилось — попробуйте чуть позже.",
    },
    "uz": {
        "subscribed": ("Tayyor: haydovchi uyga yoʻlga chiqqanda va yetib kelganda xabar beramiz. "
                       "Obunani bekor qilish — /stop"),
        "stopped": ("Tayyor: obuna bekor qilindi, endi xabar yubormaymiz. "
                    "Qayta obuna boʻlish — haydovchi yuborgan havola orqali."),
        "none": "Obunalar yoʻq — xabar yuboradigan hech kim yoʻq.",
        "bad_link": "Havola toʻgʻri kelmadi. Haydovchidan uni qayta yuborishini soʻrang.",
        "link_full": "Bu haydovchiga allaqachon {link_cap} kishi obuna boʻlgan — boshqa mumkin emas.",
        "chat_full": "Obunalar soni {chat_cap} taga yetdi — boshqa mumkin emas. Hammasini bekor qilish — /stop",
        "busy": "Hozir boʻlmadi — birozdan keyin urinib koʻring.",
    },
}


def log(text):
    """Только виды событий и числа: ни номера чата, ни имени, ни текста."""
    print(f"близкие: {text}", file=sys.stderr, flush=True)


# --- адрес и шифр номера чата ----------------------------------------------------

def valid_address(address):
    """Ровно адрес ссылки с ключом: base64url 32 байт без «=», каноничный
    (последний знак несёт 4 бита — чужой хвост не проходит)."""
    if not isinstance(address, str) or not _ADDRESS.fullmatch(address):
        return False
    try:
        raw = base64.urlsafe_b64decode(address + "=")
    except ValueError:
        return False
    return len(raw) == 32 and base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii") == address


def link_hash(address):
    return hashlib.sha256(address.encode("ascii")).hexdigest()


def _box_key(address):
    # Свой домен: ключ шифра не совпадает с link_hash, который лежит в базе.
    return hashlib.sha256(b"radarmap-family-chat|" + address.encode("ascii")).digest()


def _pad(key, nonce):
    return hmac.new(key, b"enc|" + nonce, hashlib.sha256).digest()[:8]


def _tag(key, nonce, body):
    return hmac.new(key, b"mac|" + nonce + body, hashlib.sha256).digest()[:8]


def seal(address, chat_id, nonce=None):
    """Номер чата, зашифрованный ключом из адреса: nonce(16) · шифр(8) ·
    подпись(8), hex. Подпись — чтобы испорченная строка не превратилась в
    номер ЧУЖОГО чата: такая подписка снимается, а не пишет незнакомцу."""
    key = _box_key(address)
    nonce = nonce if nonce is not None else os.urandom(16)
    body = bytes(a ^ b for a, b in zip(struct.pack(">q", chat_id), _pad(key, nonce)))
    return (nonce + body + _tag(key, nonce, body)).hex()


def unseal(address, box):
    """Номер чата или None — не тот адрес или строка испорчена."""
    try:
        raw = bytes.fromhex(box)
    except (TypeError, ValueError):
        return None
    if len(raw) != 32:
        return None
    key = _box_key(address)
    nonce, body, tag = raw[:16], raw[16:24], raw[24:]
    if not hmac.compare_digest(tag, _tag(key, nonce, body)):
        return None
    return struct.unpack(">q", bytes(a ^ b for a, b in zip(body, _pad(key, nonce))))[0]


def chat_tag(salt, chat_id, kdf):
    """Хэш номера чата для /stop и капа на чат. kdf — scrypt бота
    (telegram_bot._kdf): один вызов на команду, как у хэша человека."""
    return kdf(f"family|{chat_id}".encode(), salt.encode()).hex()


def language_of(code):
    return "uz" if isinstance(code, str) and code.lower().startswith("uz") else "ru"


def clean_name(value):
    """Имя для текста: без управляющих знаков и переворота строки, пробелы
    схлопнуты, не длиннее NAME_MAX. Пусто — None (подставится «Водитель»)."""
    if not isinstance(value, str):
        return None
    name = " ".join(_INVISIBLE.sub(" ", value).split())[:NAME_MAX].strip()
    return name or None


def clean_username(value):
    if not isinstance(value, str):
        return None
    name = value.strip().lstrip("@")
    return name if _USERNAME.fullmatch(name) else None


def read_username(path=None):
    """username бота из его конфига (ключ `username`, без «@») — для ссылки
    на странице близкого. Читается только эта строка: токен и соль из
    файла никуда не попадают. Нет файла или ключа — None."""
    try:
        with open(path or DEFAULT_CONFIG, encoding="utf-8") as handle:
            for line in handle:
                key, sep, value = line.partition("=")
                if sep and key.strip() == "username" and not line.lstrip().startswith("#"):
                    return clean_username(value)
    except OSError:
        return None
    return None


def deep_link(username, address):
    """https://t.me/<бот>?start=f_<адрес> или None."""
    username = clean_username(username)
    if username is None or not valid_address(address):
        return None
    return f"https://t.me/{username}?start={START_PREFIX}{address}"


def clock(ts):
    """Как eta_page в api.py: «18:40» по Ташкенту, секунды отбрасываются."""
    return time.strftime("%H:%M", time.gmtime(ts + TASHKENT))


# --- когда писать (чистая логика) ------------------------------------------------

def _alive(trip, now):
    if trip is None:
        return False
    age = now - trip.updated
    if trip.phase == "driving":
        return age <= TRIP_TTL
    if trip.phase == "paused":
        return age <= RESUME_WINDOW
    return age <= ARRIVED_HOLD


def decide(trip, status, eta, now):
    """(новое состояние или None, извещение или None).

    trip — Trip(фаза driving|paused|arrived, последнее объявленное время,
    когда было последнее сообщение, когда было последнее обновление) или
    None; eta — время прибытия или None. Извещение — (вид, время): departed
    (время или None), eta, delayed, arrived (время приезда)."""
    trip = trip if _alive(trip, now) else None
    if status == "driving":
        if trip is None or trip.phase == "arrived":
            return Trip("driving", eta, now, now), ("departed", eta)
        if eta is not None and trip.eta is None:
            return Trip("driving", eta, now, now), ("eta", eta)
        if eta is not None and eta - trip.eta >= DELAY_STEP and now - trip.noticed >= NOTICE_GAP:
            return Trip("driving", eta, now, now), ("delayed", eta)
        return trip._replace(phase="driving", updated=now), None
    if status == "arrived":
        if trip is not None and trip.phase == "arrived":
            return trip._replace(updated=now), None
        return Trip("arrived", None, now, now), ("arrived", now)
    if status == "ended":
        if trip is None or trip.phase == "arrived":
            return trip, None
        return trip._replace(phase="paused", updated=now), None
    return trip, None


def render(notice, lang, name=None, home=True):
    texts = NOTICES[language_of(lang)]
    kind, at = notice
    key = "departed_bare" if kind == "departed" and at is None else kind
    if not home:
        key += "_away"
    return texts[key].format(name=name or texts["driver"], time=clock(at) if at is not None else "")


def eta_of(item):
    eta = item.get("eta")
    if isinstance(eta, (int, float)) and not isinstance(eta, bool) and math.isfinite(eta) and eta > 0:
        return float(eta)
    return None


# --- база -------------------------------------------------------------------------

def connect(path=None, create=False, timeout=5.0):
    """Соединение в режиме автофиксации; составные шаги — в transaction().
    Без create файл не создаётся: нет family.db — подписок не было."""
    path = path or DB_PATH
    if create:
        conn = sqlite3.connect(path, timeout=timeout)
    else:
        conn = sqlite3.connect("file:" + urllib.parse.quote(path) + "?mode=rw", uri=True, timeout=timeout)
    conn.isolation_level = None
    conn.execute("PRAGMA synchronous = NORMAL")
    return conn


def init_db(path=None):
    conn = connect(path, create=True)
    try:
        conn.execute("PRAGMA journal_mode = WAL")
        for statement in SCHEMA:
            conn.execute(statement)
    finally:
        conn.close()


@contextlib.contextmanager
def transaction(conn):
    """BEGIN IMMEDIATE: прочитать и записать без гонки с соседним
    процессом (api и бот пишут в один файл)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")


def sweep(conn, now):
    """Сроки хранения family.db (RETENTION.md). {что: строк}."""
    statements = (
        ("subs", "DELETE FROM family_subs WHERE seen < ?", (now - KEEP_DAYS * 86400,)),
        ("outbox", "DELETE FROM family_outbox WHERE created < ? "
         "OR sub NOT IN (SELECT id FROM family_subs)", (now - OUTBOX_TTL,)),
        ("trips", "DELETE FROM family_trips WHERE updated < ? "
         "OR link NOT IN (SELECT link FROM family_subs)", (now - TRIP_TTL,)),
    )
    done = {}
    with transaction(conn):
        for key, sql, args in statements:
            done[key] = conn.execute(sql, args).rowcount
    touched = {key: n for key, n in done.items() if n}
    if touched:
        log("сроки хранения: " + ", ".join(f"{key} {n}" for key, n in sorted(touched.items())))
    return done


def sweep_file(now, path=None):
    """Тот же проход для api.py: никогда не бросает. Нет файла — нечего чистить."""
    path = path or DB_PATH
    if not os.path.exists(path):
        return None
    try:
        conn = connect(path, timeout=API_BUSY_TIMEOUT)
        try:
            return sweep(conn, now)
        finally:
            conn.close()
    except sqlite3.Error as error:
        log(f"сроки хранения: проход не удался — {type(error).__name__}")
        return None


# --- api.py: обновление ссылки → очередь ------------------------------------------------

def on_update(address, item, now):
    """Хук api.eta_put после принятой записи. Ничего не бросает и в Telegram
    не ходит: сбой здесь не стоит водителю ответа на обновление."""
    if not isinstance(item, dict) or item.get("keyed") is not True or not valid_address(address):
        return 0
    path = DB_PATH
    if not os.path.exists(path):
        return 0
    try:
        conn = connect(path, timeout=API_BUSY_TIMEOUT)
    except sqlite3.Error as error:
        log(f"база не открылась — {type(error).__name__}")
        return 0
    try:
        return queue_notices(conn, address, item, now)
    except Exception as error:      # хук не роняет POST /api/eta ни при каком сбое
        log(f"обновление не разобрано — {type(error).__name__}")
        return 0
    finally:
        conn.close()


def queue_notices(conn, address, item, now):
    """Решение и очередь для одного обновления. Сколько сообщений легло."""
    link = link_hash(address)
    # Почти у всех ссылок подписчиков нет — для них только чтение, без
    # блокировки записи на каждое обновление.
    if conn.execute("SELECT 1 FROM family_subs WHERE link = ? LIMIT 1", (link,)).fetchone() is None:
        return 0
    with transaction(conn):
        subs = conn.execute("SELECT id, box, lang, seen FROM family_subs WHERE link = ?", (link,)).fetchall()
        if not subs:
            return 0
        row = conn.execute("SELECT phase, eta, noticed, updated FROM family_trips WHERE link = ?",
                           (link,)).fetchone()
        trip, notice = decide(Trip(*row) if row else None, item.get("status"), eta_of(item), now)
        if trip is None:
            conn.execute("DELETE FROM family_trips WHERE link = ?", (link,))
        else:
            conn.execute("INSERT OR REPLACE INTO family_trips(link, phase, eta, noticed, updated) "
                         "VALUES(?, ?, ?, ?, ?)", (link,) + tuple(trip))
        stale = [(now, sid) for sid, _, _, seen in subs if now - seen >= SEEN_REFRESH]
        if stale:
            conn.executemany("UPDATE family_subs SET seen = ? WHERE id = ?", stale)
        if notice is None:
            return 0
        conn.execute("DELETE FROM family_outbox WHERE created < ?", (now - OUTBOX_TTL,))
        name = clean_name(item.get("name"))
        home = item.get("home") is not False
        queued = 0
        for sid, box, lang, _ in subs:
            chat_id = unseal(address, box)
            if chat_id is None:
                conn.execute("DELETE FROM family_subs WHERE id = ?", (sid,))
                log("подписка не расшифровалась — снята")
                continue
            conn.execute("INSERT INTO family_outbox(sub, chat_id, text, created, next_try) "
                         "VALUES(?, ?, ?, ?, ?)", (sid, chat_id, render(notice, lang, name, home), now, now))
            queued += 1
        return queued


# --- бот: /start f_<адрес> и /stop ----------------------------------------------------

class FamilyCommands:
    """Команды близких для telegram_bot.Bot. Своё соединение — из потока
    опроса бота; kdf — scrypt бота."""

    def __init__(self, conn, salt, kdf):
        self.conn = conn
        self.salt = salt
        self.kdf = kdf

    def command(self, text, chat_id, language, now):
        """Ответ или None — команда не наша (обычный /start, текст, точка)."""
        if not isinstance(text, str) or not isinstance(chat_id, int) or isinstance(chat_id, bool):
            return None
        parts = text.strip().split(None, 1)
        if not parts:
            return None
        word = parts[0].split("@", 1)[0].lower()
        payload = parts[1].strip() if len(parts) > 1 else ""
        lang = language_of(language)
        try:
            if word == "/start" and payload.startswith(START_PREFIX):
                key = self._subscribe(payload[len(START_PREFIX):], chat_id, lang, now)
            elif word == "/stop":
                key = self._stop(chat_id)
            else:
                return None
        except sqlite3.Error as error:
            log(f"команда не выполнена — {type(error).__name__}")
            key = "busy"
        return REPLIES[lang][key].format(link_cap=MAX_PER_LINK, chat_cap=MAX_PER_CHAT)

    def _subscribe(self, address, chat_id, lang, now):
        if not valid_address(address):
            return "bad_link"
        tag = chat_tag(self.salt, chat_id, self.kdf)
        link = link_hash(address)
        count = lambda sql, arg: self.conn.execute(sql, arg).fetchone()[0]
        with transaction(self.conn):
            row = self.conn.execute("SELECT id FROM family_subs WHERE link = ? AND chat = ?",
                                    (link, tag)).fetchone()
            if row is not None:
                self.conn.execute("UPDATE family_subs SET lang = ?, seen = ? WHERE id = ?", (lang, now, row[0]))
                return "subscribed"
            if count("SELECT COUNT(*) FROM family_subs WHERE link = ?", (link,)) >= MAX_PER_LINK:
                return "link_full"
            if count("SELECT COUNT(*) FROM family_subs WHERE chat = ?", (tag,)) >= MAX_PER_CHAT:
                return "chat_full"
            if count("SELECT COUNT(*) FROM family_subs", ()) >= MAX_SUBSCRIPTIONS:
                log(f"подписок уже {MAX_SUBSCRIPTIONS} — новые не принимаем")
                return "busy"
            self.conn.execute("INSERT INTO family_subs(link, chat, box, lang, created, seen) "
                              "VALUES(?, ?, ?, ?, ?, ?)", (link, tag, seal(address, chat_id), lang, now, now))
        return "subscribed"

    def _stop(self, chat_id):
        """Все подписки этого чата и их неотправленные сообщения — сразу."""
        tag = chat_tag(self.salt, chat_id, self.kdf)
        with transaction(self.conn):
            ids = [r[0] for r in self.conn.execute("SELECT id FROM family_subs WHERE chat = ?", (tag,))]
            if ids:
                self.conn.executemany("DELETE FROM family_outbox WHERE sub = ?", [(i,) for i in ids])
                self.conn.execute("DELETE FROM family_subs WHERE chat = ?", (tag,))
        return "stopped" if ids else "none"


# --- бот: доставка из очереди --------------------------------------------------------

def _error_body(error):
    try:
        value = json.loads(error.read() or b"{}")
    except (OSError, ValueError, AttributeError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def classify(error, attempts):
    """(исход, пауза): sent; gone — чат закрыт, снять подписку; drop —
    Telegram отказал насовсем, снять сообщение; flood — 429, подождать
    сколько сказано и не слать дальше в этом проходе; later — сеть, повтор."""
    if error is None:
        return "sent", 0
    if isinstance(error, urllib.error.HTTPError):
        body = _error_body(error)
        description = str(body.get("description", "")).lower()
        if error.code == 403 or (error.code == 400 and any(hint in description for hint in GONE_HINTS)):
            return "gone", 0
        if error.code == 429:
            parameters = body.get("parameters")
            retry = parameters.get("retry_after") if isinstance(parameters, dict) else None
            ok = isinstance(retry, int) and not isinstance(retry, bool) and 0 < retry <= OUTBOX_TTL
            return "flood", retry if ok else RETRY_DELAYS[0]
        if 400 <= error.code < 500:
            return "drop", 0
    return "later", RETRY_DELAYS[min(attempts, len(RETRY_DELAYS) - 1)]


class Courier:
    """Поток бота, который разбирает очередь. Соединение — своё, создаётся в
    том потоке, где идёт разбор (sqlite не делит соединение между потоками)."""

    def __init__(self, send, path=None, now=time.time, sleep=time.sleep):
        self.send = send            # (method, payload) -> dict; сбой — исключение urllib
        self.path = path
        self.now = now
        self.sleep = sleep
        self._conn = None
        self._swept = 0.0
        self.sent = 0

    def _db(self):
        if self._conn is None:
            self._conn = connect(self.path)
        return self._conn

    def _try(self, chat_id, text):
        """None — ушло; иначе исключение. Любое: обрыв посреди ответа
        (http.client.IncompleteRead — не OSError) без этого уронил бы проход
        и слал бы то же сообщение каждые 2 с; так — не больше SEND_ATTEMPTS."""
        try:
            self.send("sendMessage", {"chat_id": chat_id, "text": text})
        except Exception as error:      # исход разбирает classify, ничего не теряется
            return error
        return None

    def drain(self):
        """Один проход очереди. {исход: сколько}."""
        conn = self._db()
        now = self.now()
        done = {"sent": 0, "gone": 0, "drop": 0, "later": 0, "flood": 0, "failed": 0}
        done["stale"] = conn.execute("DELETE FROM family_outbox WHERE created < ?",
                                     (now - OUTBOX_TTL,)).rowcount
        if done["stale"]:
            log(f"не ушло за {OUTBOX_TTL // 60} мин — снято {done['stale']}")
        rows = conn.execute("SELECT id, sub, chat_id, text, attempts FROM family_outbox "
                            "WHERE next_try <= ? ORDER BY id LIMIT ?", (now, DRAIN_BATCH)).fetchall()
        closed = set()
        for rid, sub, chat_id, text, attempts in rows:
            if sub in closed:
                continue            # чат уже закрыт этим проходом, его строки сняты
            error = self._try(chat_id, text)
            verdict, pause = classify(error, attempts)
            done[verdict] += 1
            if verdict == "sent":
                conn.execute("DELETE FROM family_outbox WHERE id = ?", (rid,))
                self.sent += 1
            elif verdict == "gone":
                with transaction(conn):
                    conn.execute("DELETE FROM family_outbox WHERE sub = ?", (sub,))
                    conn.execute("DELETE FROM family_subs WHERE id = ?", (sub,))
                closed.add(sub)
                log(f"чат закрыт ({error.code}) — подписка снята")
            elif verdict == "drop":
                conn.execute("DELETE FROM family_outbox WHERE id = ?", (rid,))
                log(f"Telegram отказал ({error.code}) — сообщение снято")
            elif verdict == "flood":
                conn.execute("UPDATE family_outbox SET next_try = ? WHERE id = ?", (now + pause, rid))
                log(f"Telegram просит подождать {pause} с")
                break
            elif attempts + 1 >= SEND_ATTEMPTS:
                conn.execute("DELETE FROM family_outbox WHERE id = ?", (rid,))
                done["failed"] += 1
                log(f"не доставлено за {SEND_ATTEMPTS} попытки ({type(error).__name__}) — снято")
            else:
                conn.execute("UPDATE family_outbox SET attempts = ?, next_try = ? WHERE id = ?",
                             (attempts + 1, now + pause, rid))
        return done

    def step(self):
        """Проход сроков раз в SWEEP_SECONDS (с отчётом, сколько ушло) и разбор."""
        now = self.now()
        if now - self._swept >= SWEEP_SECONDS:
            if self._swept and self.sent:
                log(f"за час отправлено {self.sent}")
            self._swept = now
            self.sent = 0
            sweep(self._db(), now)
        return self.drain()

    def run(self, stop=None):
        while stop is None or not stop.is_set():
            pause = DRAIN_INTERVAL
            try:
                self.step()
            except Exception as error:     # поток не умирает от одного сбоя
                log(f"очередь не разобрана — {type(error).__name__}")
                pause = FAILURE_PAUSE
                if self._conn is not None:
                    try:
                        self._conn.close()
                    except sqlite3.Error as close_error:
                        log(f"соединение не закрылось — {type(close_error).__name__}")
                    self._conn = None
            self.sleep(pause)
