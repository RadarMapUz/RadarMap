#!/usr/bin/env python3
"""telegram_publish.py — подтверждённые треноги и посты в Telegram-канал.

Водители уже сидят в Telegram-чатах «где стоят» и переписывают друг у друга
точки руками. Наш сервер знает их раньше и точнее: отметка, которую
подтвердил НЕЗАВИСИМЫЙ водитель (другое устройство И другой адрес — тот же
критерий, что у api.confirmed_independently), и есть то, что стоит
публиковать. Канал — бесплатный приток туда, где люди уже есть, и честный:
только подтверждённое, ничего из слухов.

ПРИВАТНОСТЬ. В канал уходит: город, тип, адрес (если есть в наших адресных
клетках) или координаты, округлённые до 4 знаков (~10 м), число подтвердивших
и время, округлённое до 5 минут. НИКОГДА: device, ip, точное время с
секундами, кто отметил. Выборка не читает колонок device/ip вовсе — утечка
невозможна по построению, а тест ещё и грепает сообщения.

Идемпотентность: отправленные id лежат в отдельной telegram.db (таблица
telegram_posted); повторный запуск, упавший прогон, крон дважды — ничего не
шлют второй раз. Отметка помечается отправленной только после ответа API.

Конфиг: /opt/radarmap/telegram.conf, строки `token=…` и `chat_id=…`
(создаёт владелец; в git не лежит). Нет конфига — выход 0 с сообщением:
крон не должен краснеть из-за ещё не созданного канала. Токен может быть
тем же, что у бота владельца (`tg_token` в admin.conf, см. notify.py), но
chat_id здесь — ПУБЛИЧНЫЙ КАНАЛ («@radarmap_uz», бот — его администратор),
а не личный чат владельца: конфиг разведён намеренно, чтобы отметки
водителей не могли уйти не туда из-за одной опечатки.

Запуск:
    python3 telegram_publish.py --dry-run             # печатает, не шлёт
    python3 telegram_publish.py                       # крон, раз в 5 минут
Тесты (без сети):
    python3 test_telegram_publish.py
"""
import argparse
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

API = "https://api.telegram.org/bot{token}/sendMessage"
DEFAULT_CONFIG = "/opt/radarmap/telegram.conf"
DEFAULT_REPORTS_DB = "/opt/radarmap/api/reports.db"
DEFAULT_TELEGRAM_DB = "/opt/radarmap/api/telegram.db"
#: Адресные клетки (road2_<key>_a.json), как их кладёт publish_roads.sh.
DEFAULT_ROADS_DIR = "/opt/radarmap/www/roads"

#: Какие типы публикуются. ДТП — нет: это не то, ради чего канал.
KINDS = {"radar": "радар", "tripod": "тренога", "post": "пост ДПС"}
#: Сколько независимых подтверждений нужно. Одно — порог самого api.
MIN_CONFIRMATIONS = 1
#: Окно выборки: отметка старше — не новость. Крон ходит каждые 5 минут,
#: подтверждение приходит через полчаса-час после отметки.
LOOKBACK_MINUTES = 180
#: Время в канале — местное (UTC+5) и с точностью до 5 минут.
TZ_OFFSET = 5 * 3600
TIME_STEP = 300
#: Координаты — 4 знака (~10 м): достаточно, чтобы найти, и не точнее, чем
#: нужно, чтобы не превращать канал в журнал чьих-то проездов.
COORD_DIGITS = 4
#: Дальше этого от крупного города — «трасса»: «Джизак, 40 км».
CITY_RADIUS_KM = 25
#: Адрес берём, если дом не дальше этого от точки.
ADDRESS_MAX_METERS = 150.0
#: Отметок в одном сообщении: Telegram режет на 4096 символов.
PER_MESSAGE = 15

#: Крупные города: ближайший даёт заголовок. Координаты центров.
CITIES = (
    ("Ташкент", 41.3111, 69.2797), ("Самарканд", 39.6542, 66.9597),
    ("Бухара", 39.7747, 64.4286), ("Наманган", 40.9983, 71.6726),
    ("Андижан", 40.7821, 72.3442), ("Фергана", 40.3864, 71.7864),
    ("Нукус", 42.4531, 59.6103), ("Карши", 38.8606, 65.7891),
    ("Термез", 37.2242, 67.2783), ("Ургенч", 41.5500, 60.6333),
    ("Джизак", 40.1158, 67.8422), ("Навои", 40.0844, 65.3792),
    ("Гулистан", 40.4897, 68.7842),
)
M_PER_DEG_LAT = 111_320.0
ADDRESS_DEGREES = 0.5
ADDRESS_SCALE = 1e5


def distance(lat1, lon1, lat2, lon2):
    kx = M_PER_DEG_LAT * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lat2 - lat1) * M_PER_DEG_LAT, (lon2 - lon1) * kx)


# --- конфиг ----------------------------------------------------------------

def read_config(path):
    """{token, chat_id} или None — нет файла или в нём нет обоих полей."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    conf = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        conf[key.strip()] = value.strip()
    if not conf.get("token") or not conf.get("chat_id"):
        return None
    return {"token": conf["token"], "chat_id": conf["chat_id"]}


# --- выборка ---------------------------------------------------------------

def select_confirmed(conn, *, now, lookback_minutes=LOOKBACK_MINUTES,
                     min_confirmations=MIN_CONFIRMATIONS):
    """Живые отметки нужных типов за окно, подтверждённые независимо.

    Подтверждение — лайк с ДРУГОГО устройства и ДРУГОГО адреса (ровно как
    api.confirmed_independently); считаем РАЗНЫЕ адреса. Из таблицы не
    берутся ни device, ни ip: их просто нет в результате.
    """
    since = now - lookback_minutes * 60
    placeholders = ",".join("?" for _ in KINDS)
    rows = conn.execute(
        f"""SELECT r.id, r.lat, r.lon, r.type, r.created,
                   (SELECT COUNT(DISTINCT v.ip) FROM votes v
                     WHERE v.report_id = r.id AND v.value = 1
                       AND v.device != r.device AND v.ip != '' AND v.ip != r.ip)
                   AS confirmations
            FROM reports r
            WHERE r.active = 1 AND r.expires > ? AND r.created >= ? AND r.created <= ?
              AND r.type IN ({placeholders})
            ORDER BY r.created""",
        (now, since, now, *KINDS)).fetchall()
    return [{"id": int(r[0]), "lat": float(r[1]), "lon": float(r[2]), "type": r[3],
             "created": float(r[4]), "confirmations": int(r[5] or 0)}
            for r in rows if int(r[5] or 0) >= min_confirmations]


# --- адреса ----------------------------------------------------------------

def address_key(lat, lon):
    return (f"{int(math.floor((lat + 90) / ADDRESS_DEGREES))}_"
            f"{int(math.floor((lon + 180) / ADDRESS_DEGREES))}")


def nearest_address(roads_dir, lat, lon, max_meters=ADDRESS_MAX_METERS):
    """«улица, дом» из нашей адресной клетки или None. Формат — как пишет
    build_roads.addresses_by_cell: улицы, номера, координаты дельтами 1e-5°."""
    if not roads_dir:
        return None
    path = os.path.join(roads_dir, f"road2_{address_key(lat, lon)}_a.json")
    try:
        with open(path, encoding="utf-8") as handle:
            cell = json.load(handle)
    except (OSError, ValueError):
        return None
    return nearest_in_cell(cell, lat, lon, max_meters)


def nearest_in_cell(cell, lat, lon, max_meters=ADDRESS_MAX_METERS):
    """Тот же поиск по уже прочитанной клетке. Бот (telegram_bot.py) держит
    клетки в памяти: ему адрес нужен на каждую строку «что рядом», а клетка
    Ташкента — мегабайты."""
    if not isinstance(cell, dict):
        return None
    best, best_meters = None, max_meters
    for street in cell.get("streets") or []:
        numbers, packed = street.get("h") or [], street.get("p") or []
        ilat = ilon = 0
        for index, number in enumerate(numbers):
            if 2 * index + 1 >= len(packed):
                break
            ilat += packed[2 * index]
            ilon += packed[2 * index + 1]
            meters = distance(lat, lon, ilat / ADDRESS_SCALE, ilon / ADDRESS_SCALE)
            if meters < best_meters:
                best_meters = meters
                best = f"{street.get('n', '')}, {number}".strip(", ")
    return best or None


# --- текст -----------------------------------------------------------------

def nearest_city(lat, lon):
    """(город, км до центра). Дальше CITY_RADIUS_KM заголовок скажет «Джизак,
    40 км» — трасса, а не город."""
    name, best = None, None
    for city, clat, clon in CITIES:
        km = distance(lat, lon, clat, clon) / 1000
        if best is None or km < best:
            name, best = city, km
    return name, best


def city_label(lat, lon):
    name, km = nearest_city(lat, lon)
    return name if km <= CITY_RADIUS_KM else f"{name}, {int(round(km))} км"


def drivers(count):
    return "водителем" if count == 1 else "водителями"


def local_time(created):
    """ЧЧ:ММ по Ташкенту, округлённое ВНИЗ до 5 минут."""
    rounded = int(created // TIME_STEP) * TIME_STEP
    return time.strftime("%H:%M", time.gmtime(rounded + TZ_OFFSET))


def osm_link(lat, lon):
    return (f"https://www.openstreetmap.org/?mlat={lat:.{COORD_DIGITS}f}"
            f"&mlon={lon:.{COORD_DIGITS}f}#map=17/{lat:.{COORD_DIGITS}f}/{lon:.{COORD_DIGITS}f}")


def line_for(report, address=None):
    """Одна отметка — одна строка. Адрес есть — он; нет — координаты, и
    ссылка на карту в любом случае второй строкой."""
    lat = round(report["lat"], COORD_DIGITS)
    lon = round(report["lon"], COORD_DIGITS)
    where = address or f"{lat:.{COORD_DIGITS}f}, {lon:.{COORD_DIGITS}f}"
    count = report["confirmations"]
    return (f"📍 {city_label(report['lat'], report['lon'])} · {KINDS.get(report['type'], report['type'])}"
            f" · {where} · подтверждена {count} {drivers(count)} · {local_time(report['created'])}"
            f"\n{osm_link(lat, lon)}")


def group_by_city(reports):
    """{город: [отметки]} в порядке первого появления; внутри — по времени."""
    groups = {}
    for report in sorted(reports, key=lambda r: (r["created"], r["id"])):
        groups.setdefault(city_label(report["lat"], report["lon"]), []).append(report)
    return groups


def messages(reports, roads_dir=None, per_message=PER_MESSAGE):
    """[(текст, [id отметок])] — одно сообщение на город (длинный список
    режется на куски по per_message)."""
    out = []
    for _city, items in group_by_city(reports).items():
        for start in range(0, len(items), per_message):
            chunk = items[start:start + per_message]
            lines = [line_for(r, nearest_address(roads_dir, r["lat"], r["lon"])) for r in chunk]
            out.append(("\n\n".join(lines), [r["id"] for r in chunk]))
    return out


# --- отправка и журнал -----------------------------------------------------

def ensure_posted_table(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS telegram_posted(
        report_id INTEGER PRIMARY KEY,
        posted_at REAL NOT NULL,
        chat_id TEXT NOT NULL,
        message_id INTEGER)""")
    conn.commit()


def already_posted(conn):
    return {row[0] for row in conn.execute("SELECT report_id FROM telegram_posted")}


def mark_posted(conn, report_ids, chat_id, message_id, now):
    conn.executemany(
        "INSERT OR IGNORE INTO telegram_posted(report_id, posted_at, chat_id, message_id) "
        "VALUES(?,?,?,?)",
        [(rid, now, str(chat_id), message_id) for rid in report_ids])
    conn.commit()


def send_message(token, chat_id, text, timeout=30):
    """Bot API sendMessage. Возвращает message_id; исключение — не дошло."""
    body = json.dumps({"chat_id": chat_id, "text": text,
                       "disable_web_page_preview": True}).encode()
    request = urllib.request.Request(API.format(token=token), data=body,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    if not payload.get("ok"):
        raise RuntimeError(f"Telegram: {payload.get('description') or payload}")
    return int((payload.get("result") or {}).get("message_id") or 0)


def run(reports_db, telegram_db, config, *, now, roads_dir=None, dry_run=False,
        sender=send_message, lookback_minutes=LOOKBACK_MINUTES,
        min_confirmations=MIN_CONFIRMATIONS, out=sys.stdout):
    """Один прогон. Возвращает число отправленных сообщений."""
    reports = sqlite3.connect(reports_db)
    journal = sqlite3.connect(telegram_db)
    try:
        ensure_posted_table(journal)
        fresh = select_confirmed(reports, now=now, lookback_minutes=lookback_minutes,
                                 min_confirmations=min_confirmations)
        done = already_posted(journal)
        pending = [r for r in fresh if r["id"] not in done]
        sent = 0
        for text, ids in messages(pending, roads_dir):
            if dry_run:
                print(f"--- [{len(ids)} отм.]\n{text}\n", file=out)
                continue
            try:
                message_id = sender(config["token"], config["chat_id"], text)
            except (urllib.error.URLError, OSError, RuntimeError, ValueError) as error:
                # Не помечаем: следующий прогон попробует снова. Остальные
                # города тоже ждут — у Telegram это, как правило, один сбой.
                print(f"не отправлено ({len(ids)} отм.): {error}", file=sys.stderr)
                break
            mark_posted(journal, ids, config["chat_id"], message_id, now)
            sent += 1
        return sent
    finally:
        reports.close()
        journal.close()


def main():
    ap = argparse.ArgumentParser(description="Подтверждённые треноги и посты — в Telegram-канал")
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--db", default=DEFAULT_REPORTS_DB, help="reports.db (только чтение)")
    ap.add_argument("--journal", default=DEFAULT_TELEGRAM_DB, help="telegram.db (что отправлено)")
    ap.add_argument("--roads", default=DEFAULT_ROADS_DIR, help="каталог адресных клеток")
    ap.add_argument("--lookback-minutes", type=int, default=LOOKBACK_MINUTES)
    ap.add_argument("--min-confirmations", type=int, default=MIN_CONFIRMATIONS)
    ap.add_argument("--dry-run", action="store_true", help="печатать, не слать и не помечать")
    ap.add_argument("--now", type=float, default=None, help="метка времени для воспроизводимости")
    args = ap.parse_args()

    config = read_config(args.config)
    if config is None and not args.dry_run:
        print(f"Telegram не настроен: нет {args.config} с token= и chat_id= — "
              f"канал ещё не создан, ничего не делаю")
        return 0
    if not os.path.exists(args.db):
        print(f"нет базы отметок {args.db}", file=sys.stderr)
        return 1
    now = args.now if args.now is not None else time.time()
    try:
        sent = run(args.db, args.journal, config or {"token": "", "chat_id": ""}, now=now,
                   roads_dir=args.roads, dry_run=args.dry_run,
                   lookback_minutes=args.lookback_minutes,
                   min_confirmations=args.min_confirmations)
    except sqlite3.Error as error:
        print(f"база не читается: {error}", file=sys.stderr)
        return 1
    if sent:
        print(f"отправлено сообщений: {sent}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
