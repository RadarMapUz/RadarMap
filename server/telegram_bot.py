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

ПРИВАТНОСТЬ
  * Telegram-id в открытом виде не хранится НИГДЕ: ни в базе, ни в логах,
    ни в памяти дольше обработки одного сообщения. Вместо него — хэш
    sha256(соль сервера · id · номер 30-дневного окна): устройство для API
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

ЛИМИТЫ — свои, на человека (по хэшу), до API: не больше BOT_DAILY_REPORTS
отметок в сутки и не чаще BOT_MIN_INTERVAL секунд. Счётчики — в bot.db по
хэшу дня, без id.

КОНФИГ: /opt/radarmap/telegram_bot.conf (создаёт владелец, в git не лежит):
    token=<токен бота>
    salt=<длинная случайная строка, например `openssl rand -hex 32`>
Нет конфига — выход 0 с сообщением.

ЗАПУСК: long polling (getUpdates), без вебхука и открытых портов —
systemd-юнит radarmap-bot.service. Тесты без сети: test_telegram_bot.py.
"""
import hashlib
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

DEFAULT_CONFIG = "/opt/radarmap/telegram_bot.conf"
DEFAULT_DB = "/opt/radarmap/api/bot.db"
API_BASE = "http://127.0.0.1:8091"
TG_API = "https://api.telegram.org/bot{token}/{method}"

#: Окно смены хэша-устройства — как ротация UUID в приложении.
ROTATION_SECONDS = 30 * 86400
#: Своя точка без выбранного типа живёт столько.
PENDING_TTL = 10 * 60
BOT_DAILY_REPORTS = 15
BOT_MIN_INTERVAL = 60

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
    "expired": "Точка устарела — отправьте геопозицию ещё раз.",
    "limit": "На сегодня отметок достаточно — спасибо!",
    "slow": "Не так часто — подождите минуту.",
    "created": "Отмечено. Спасибо! Точку увидят водители рядом.",
    "merged": "Рядом уже отмечено — ваш голос засчитан.",
    "amended": "Тип уточнён.",
    "cng_ok": "Спасибо! Статус заправки обновлён.",
    "error": "Не получилось отправить — попробуйте ещё раз чуть позже.",
}


# --- приватность ---------------------------------------------------------------

def period(now):
    return int(now // ROTATION_SECONDS)


def user_hash(salt, user_id, now):
    """Хэш человека на это 30-дневное окно. id в результат не попадает и
    по нему не восстанавливается без соли сервера."""
    return hashlib.sha256(f"{salt}|{user_id}|{period(now)}".encode()).hexdigest()


def device_for(salt, user_id, now):
    return "tg-" + user_hash(salt, user_id, now)[:32]


def pseudo_ip_for(salt, user_id, now):
    return "tg-" + user_hash(salt, user_id, now)[32:48]


# --- лимиты (bot.db, только хэши) ---------------------------------------------

def open_db(path):
    conn = sqlite3.connect(path)
    conn.execute("""CREATE TABLE IF NOT EXISTS bot_limits(
        who TEXT NOT NULL, day TEXT NOT NULL, count INTEGER NOT NULL, last REAL NOT NULL,
        PRIMARY KEY(who, day))""")
    return conn


def check_and_count(conn, who, now):
    """None — можно; иначе ключ текста отказа. Считает только разрешённое."""
    day = time.strftime("%Y-%m-%d", time.gmtime(now + 5 * 3600))
    row = conn.execute("SELECT count, last FROM bot_limits WHERE who = ? AND day = ?",
                       (who, day)).fetchone()
    count, last = row if row else (0, 0.0)
    if count >= BOT_DAILY_REPORTS:
        return "limit"
    if now - last < BOT_MIN_INTERVAL:
        return "slow"
    conn.execute("INSERT OR REPLACE INTO bot_limits(who, day, count, last) VALUES(?,?,?,?)",
                 (who, day, count + 1, now))
    conn.execute("DELETE FROM bot_limits WHERE day < ?",
                 (time.strftime("%Y-%m-%d", time.gmtime(now + 5 * 3600 - 3 * 86400)),))
    conn.commit()
    return None


# --- бот -------------------------------------------------------------------------

def keyboard(rows):
    return {"inline_keyboard": [[{"text": label, "callback_data": data} for data, label in row]
                                for row in rows]}


def chunks(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


class Bot:
    """Логика без сети: `send` и `api_post` подменяются в тестах."""

    def __init__(self, salt, db, send, api_post, now=time.time):
        self.salt = salt
        self.db = db
        self.send = send            # (method, payload) -> dict
        self.api_post = api_post    # (path, body, pseudo_ip) -> (status, dict)
        self.now = now
        # Точки, ждущие типа: ключ — хэш человека (не id), значение — (lat, lon, ts).
        self.pending = {}

    def handle(self, update):
        now = self.now()
        self.pending = {k: v for k, v in self.pending.items() if now - v[2] < PENDING_TTL}
        if "callback_query" in update:
            return self._callback(update["callback_query"], now)
        message = update.get("message") or {}
        chat = (message.get("chat") or {}).get("id")
        user = (message.get("from") or {}).get("id")
        if chat is None or user is None:
            return
        location = message.get("location")
        if location:
            who = user_hash(self.salt, user, now)
            self.pending[who] = (float(location["latitude"]), float(location["longitude"]), now)
            self.send("sendMessage", {"chat_id": chat, "text": TEXTS["pick"],
                                      "reply_markup": keyboard(chunks(REPORT_KINDS, 3))})
            return
        self.send("sendMessage", {"chat_id": chat, "text": TEXTS["start"]})

    def _callback(self, query, now):
        user = (query.get("from") or {}).get("id")
        chat = ((query.get("message") or {}).get("chat") or {}).get("id")
        data = query.get("data") or ""
        self.send("answerCallbackQuery", {"callback_query_id": query.get("id")})
        if user is None or chat is None:
            return
        who = user_hash(self.salt, user, now)
        point = self.pending.get(who)
        if point is None:
            return self.send("sendMessage", {"chat_id": chat, "text": TEXTS["expired"]})
        if data == "cng":
            return self.send("sendMessage", {"chat_id": chat, "text": TEXTS["pick_cng"],
                                             "reply_markup": keyboard(chunks(CNG_KINDS, 2))})
        kinds = dict(REPORT_KINDS)
        cng = dict(CNG_KINDS)
        if data not in kinds and data not in cng:
            return
        refusal = check_and_count(self.db, who, now)
        if refusal:
            return self.send("sendMessage", {"chat_id": chat, "text": TEXTS[refusal]})
        lat, lon, _ = point
        del self.pending[who]
        device = device_for(self.salt, user, now)
        ip = pseudo_ip_for(self.salt, user, now)
        if data in cng:
            status, _ = self.api_post("/api/cng", {"lat": lat, "lon": lon, "kind": data, "device": device}, ip)
            text = TEXTS["cng_ok"] if status == 200 else TEXTS["error"]
        else:
            status, answer = self.api_post("/api/report", {"lat": lat, "lon": lon, "type": data,
                                                           "device": device}, ip)
            if status != 200:
                text = TEXTS["error"]
            elif answer.get("amended"):
                text = TEXTS["amended"]
            elif answer.get("merged"):
                text = TEXTS["merged"]
            else:
                text = TEXTS["created"]
        self.send("sendMessage", {"chat_id": chat, "text": text})


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


def api_post(path, body, pseudo_ip):
    request = urllib.request.Request(API_BASE + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "X-Real-IP": pseudo_ip})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, {}


def main():
    config = read_config(os.environ.get("RADARMAP_BOT_CONFIG", DEFAULT_CONFIG))
    if config is None:
        print("telegram_bot: нет конфига (token, salt) — бот не запущен")
        return 0
    token = config["token"]
    bot = Bot(config["salt"], open_db(os.environ.get("RADARMAP_BOT_DB", DEFAULT_DB)),
              send=lambda method, payload: telegram(token, method, payload, timeout=15),
              api_post=api_post)
    offset = 0
    while True:
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
