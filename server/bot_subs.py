#!/usr/bin/env python3
"""bot_subs.py — что бот хранит о людях в bot.db и что он присылает сам
(план 23.1, 23.5–23.7).

ТАБЛИЦЫ (сроки — RETENTION.md, RETENTION_DAYS ниже, тест сверяет):
  bot_prefs       язык по хэшу человека (тот же 30-дневный хэш, что у
                  отметок: язык теряется на границе окна — человек снова
                  получает язык Telegram; связать окна нельзя по построению);
  bot_subs        подписки на перевал или город: scrypt-хэш номера чата (тот
                  же family_notify.chat_tag — /stop одним хэшем снимает и
                  близких, и свои), номер чата ЗАШИФРОВАННЫМ (family_notify.
                  seal_key), язык, когда создана, когда человек последний раз
                  командовал подписками; 55 дней без его команд — удаляется,
                  а ему уходит одно «подписка закончилась»;
  bot_outbox      очередь — та же форма, что family_outbox, и та же доставка
                  (family_notify.Courier): номер чата в ней открыт, но не
                  дольше 10 минут;
  bot_city_sent   какие отметки уже ушли подписке города — сутки;
  bot_pass_state  есть ли сейчас опасность на перевале — про погоду, не про людей;
  bot_meta        служебное: отпечаток профиля бота (23.1).

ШИФР НОМЕРА ЧАТА — ЧЕСТНО. У близких ключ приносит телефон водителя, на
сервере его нет. Здесь присылать нужно в любую минуту (опасность на
перевале появилась ночью), поэтому ключ — из соли бота (конфиг). Украденная
bot.db без конфига номеров чатов не даёт; bot.db вместе с конфигом — даёт.
Соль, как и у хэшей, не менять: подписки перестанут расшифровываться.

ЧТО И КОГДА ПРИСЫЛАЕМ (Pusher, поток доставки бота):
  * перевал: одно сообщение, когда опасность ПОЯВИЛАСЬ, и одно — когда ушла
    (ушла — значит её нет уже PASS_CLEAR_HOLD: прогноз на границе не
    перебрасывает «опасно/спокойно» каждые полчаса). Первое наблюдение после
    запуска только запоминается — выкладка не рассылает «опасность» всем.
    Тихих часов нет: водитель, выезжающий на Камчик в пять утра, — ровно
    тот, кому это нужно;
  * город: только ПОДТВЕРЖДЁННЫЕ треноги и посты (telegram_publish.
    select_confirmed — та же выборка, что у канала), в тихие часы 23:00–07:00
    по Ташкенту — ничего (утром уйдёт то, что ещё стоит), не больше
    CITY_HOURLY сообщений в час на подписку (одна подписка на город на чат).
"""
import hashlib
import os
import sqlite3
import sys
import time
import urllib.parse

import bot_near
import bot_texts
import family_notify
import telegram_publish

#: = family_notify.KEEP_DAYS = api.LIVE_MAX_DAYS: подписка без команд человека.
KEEP_DAYS = 55
#: Хэш человека меняется раз в 30 дней — его язык дольше не нужен.
PREFS_KEEP_DAYS = 30
#: Сколько ушедших отметок помнит подписка города (отметка живёт до 6 ч).
CITY_SENT_KEEP_DAYS = 1
CITY_HOURLY = 6
CITY_PER_MESSAGE = 5
QUIET_FROM, QUIET_TO = 23, 7           # по Ташкенту
CITY_KINDS = ("tripod", "post")
#: Опасность ушла — если её нет уже столько.
PASS_CLEAR_HOLD = 3600
#: Как часто Pusher смотрит: город — раз в минуту, перевалы — раз в 5 минут.
CITY_EVERY = 60.0
PASS_EVERY = 300.0
MAX_SUBSCRIPTIONS = 20000

#: Таблица → потолок, дней (RETENTION.md; тест). «—» в документе — None.
RETENTION_DAYS = {"bot_prefs": PREFS_KEEP_DAYS, "bot_subs": KEEP_DAYS, "bot_outbox": 1,
                  "bot_city_sent": CITY_SENT_KEEP_DAYS, "bot_pass_state": None, "bot_meta": None}

SCHEMA = (
    """CREATE TABLE IF NOT EXISTS bot_prefs(
        who TEXT PRIMARY KEY,
        lang TEXT NOT NULL,
        seen REAL NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS bot_meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS bot_subs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        target TEXT NOT NULL,
        chat TEXT NOT NULL,
        box TEXT NOT NULL,
        lang TEXT NOT NULL,
        created REAL NOT NULL,
        seen REAL NOT NULL,
        quota_start REAL NOT NULL DEFAULT 0,
        quota_used INTEGER NOT NULL DEFAULT 0,
        UNIQUE(kind, target, chat))""",
    "CREATE INDEX IF NOT EXISTS bot_subs_chat ON bot_subs(chat)",
    """CREATE TABLE IF NOT EXISTS bot_outbox(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sub INTEGER NOT NULL,
        chat_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        created REAL NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_try REAL NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS bot_outbox_next ON bot_outbox(next_try)",
    """CREATE TABLE IF NOT EXISTS bot_city_sent(
        sub INTEGER NOT NULL,
        report INTEGER NOT NULL,
        sent REAL NOT NULL,
        PRIMARY KEY(sub, report))""",
    """CREATE TABLE IF NOT EXISTS bot_pass_state(
        grp TEXT PRIMARY KEY,
        hazard INTEGER NOT NULL,
        clear_since REAL,
        changed REAL NOT NULL)""",
)


def log(text):
    """Только виды событий и числа: ни номеров чатов, ни текстов, ни мест."""
    print(f"telegram_bot: {text}", file=sys.stderr, flush=True)


def init_schema(conn):
    for statement in SCHEMA:
        conn.execute(statement)
    conn.commit()


def box_key(salt):
    """Ключ шифра номера чата подписок бота — из соли, в своём домене (не
    совпадает ни с одним хэшем, лежащим в базе)."""
    return hashlib.sha256(b"radarmap-bot-subs|" + salt.encode()).digest()


def quiet(now):
    hour = time.gmtime(now + bot_near.TASHKENT).tm_hour
    return hour >= QUIET_FROM or hour < QUIET_TO


# --- язык ------------------------------------------------------------------------

def get_lang(conn, who):
    row = conn.execute("SELECT lang FROM bot_prefs WHERE who = ?", (who,)).fetchone()
    return row[0] if row and row[0] in bot_texts.LANGS else None


def set_lang(conn, who, lang, now):
    with conn:
        conn.execute("INSERT OR REPLACE INTO bot_prefs(who, lang, seen) VALUES(?, ?, ?)", (who, lang, now))


# --- подписки (поток опроса бота) ----------------------------------------------------

def subscribe(conn, kind, target, tag, box, lang, now):
    """True — подписан (или уже был: обновлены язык и «когда командовал»).
    Город — один на чат: новый заменяет прежний. False — потолок."""
    with conn:
        if kind == "city":
            conn.execute("DELETE FROM bot_subs WHERE kind = 'city' AND chat = ? AND target != ?", (tag, target))
        row = conn.execute("SELECT id FROM bot_subs WHERE kind = ? AND target = ? AND chat = ?",
                           (kind, target, tag)).fetchone()
        if row is not None:
            conn.execute("UPDATE bot_subs SET lang = ?, seen = ? WHERE id = ?", (lang, now, row[0]))
            return True
        if conn.execute("SELECT COUNT(*) FROM bot_subs").fetchone()[0] >= MAX_SUBSCRIPTIONS:
            log(f"подписок бота уже {MAX_SUBSCRIPTIONS} — новые не принимаем")
            return False
        conn.execute("INSERT INTO bot_subs(kind, target, chat, box, lang, created, seen) "
                     "VALUES(?, ?, ?, ?, ?, ?, ?)", (kind, target, tag, box, lang, now, now))
    return True


def listed(conn, tag, now=None):
    """[(номер, вид, цель)] подписок чата. С now — это команда человека:
    его подписки живут ещё 55 дней."""
    with conn:
        if now is not None:
            conn.execute("UPDATE bot_subs SET seen = ? WHERE chat = ?", (now, tag))
        return conn.execute("SELECT id, kind, target FROM bot_subs WHERE chat = ? ORDER BY id",
                            (tag,)).fetchall()


def remove(conn, tag, sid):
    with conn:
        done = conn.execute("DELETE FROM bot_subs WHERE id = ? AND chat = ?", (sid, tag)).rowcount
        if done:
            conn.execute("DELETE FROM bot_outbox WHERE sub = ?", (sid,))
            conn.execute("DELETE FROM bot_city_sent WHERE sub = ?", (sid,))
    return bool(done)


def stop(conn, tag):
    with conn:
        ids = [row[0] for row in conn.execute("SELECT id FROM bot_subs WHERE chat = ?", (tag,))]
        for sid in ids:
            conn.execute("DELETE FROM bot_outbox WHERE sub = ?", (sid,))
            conn.execute("DELETE FROM bot_city_sent WHERE sub = ?", (sid,))
        conn.execute("DELETE FROM bot_subs WHERE chat = ?", (tag,))
    return len(ids)


def counts(conn):
    """Для /stats: {(вид, цель): подписчиков}."""
    return {(kind, target): n for kind, target, n in
            conn.execute("SELECT kind, target, COUNT(*) FROM bot_subs GROUP BY kind, target")}


# --- сроки (поток доставки, раз в час) ----------------------------------------------

def sweep(conn, now, key):
    """Сроки bot.db (RETENTION.md). Подписке, у которой кончился срок, —
    одно «подписка закончилась» (номер отправки 0: не привязано к строке,
    которой уже нет). {что: строк}."""
    done = {}
    with family_notify.transaction(conn):
        old = conn.execute("SELECT id, kind, target, box, lang FROM bot_subs WHERE seen < ?",
                           (now - KEEP_DAYS * 86400,)).fetchall()
        for sid, kind, target, box, lang in old:
            chat_id = family_notify.unseal_key(key, box)
            if chat_id is not None:
                what = target_name(kind, target, lang, {})
                command = "/city" if kind == "city" else "/pereval"
                conn.execute("INSERT INTO bot_outbox(sub, chat_id, text, created, next_try) VALUES(0, ?, ?, ?, ?)",
                             (chat_id, bot_texts.text(lang, "sub_expired", what=what, command=command), now, now))
            conn.execute("DELETE FROM bot_subs WHERE id = ?", (sid,))
        done["subs"] = len(old)
        for name, sql, args in (
                ("outbox", "DELETE FROM bot_outbox WHERE created < ? OR (sub != 0 AND sub NOT IN "
                           "(SELECT id FROM bot_subs))", (now - family_notify.OUTBOX_TTL,)),
                ("sent", "DELETE FROM bot_city_sent WHERE sent < ? OR sub NOT IN (SELECT id FROM bot_subs)",
                 (now - CITY_SENT_KEEP_DAYS * 86400,)),
                ("prefs", "DELETE FROM bot_prefs WHERE seen < ?", (now - PREFS_KEEP_DAYS * 86400,))):
            done[name] = conn.execute(sql, args).rowcount
    touched = {k: n for k, n in done.items() if n}
    if touched:
        log("сроки хранения bot.db: " + ", ".join(f"{k} {n}" for k, n in sorted(touched.items())))
    return done


PASS_NAMES = {"kamchik": {"ru": "Камчик", "uz": "Qamchiq"},
              "takhtakaracha": {"ru": "Тахтакарача", "uz": "Taxtaqoracha"}}


def target_name(kind, target, lang, statuses):
    if kind == "city":
        return bot_texts.city_name(target, lang)
    item = statuses.get(target)
    if item:
        return bot_near.pass_name(lang, item, target)
    return PASS_NAMES.get(target, {}).get(lang) or target


# --- рассылка (поток доставки) -------------------------------------------------------

class Pusher:
    """Решает, что прислать подпискам, и кладёт в bot_outbox; отправляет
    family_notify.Courier того же потока. Соединения — свои, в этом потоке."""

    def __init__(self, path, key, sources, reports_db=None, now=time.time):
        self.path = path
        self.key = key
        self.sources = sources
        self.reports_db = reports_db
        self.now = now
        self._conn = None
        self._city_at = 0.0
        self._pass_at = 0.0
        self._logged = set()
        self.pushed = 0

    def _db(self):
        if self._conn is None:
            self._conn = family_notify.connect(self.path)
        return self._conn

    def _queue(self, conn, sid, box, text, now):
        chat_id = family_notify.unseal_key(self.key, box)
        if chat_id is None:
            conn.execute("DELETE FROM bot_subs WHERE id = ?", (sid,))
            log("подписка бота не расшифровалась — снята")
            return False
        conn.execute("INSERT INTO bot_outbox(sub, chat_id, text, created, next_try) VALUES(?, ?, ?, ?, ?)",
                     (sid, chat_id, text, now, now))
        self.pushed += 1
        return True

    def step(self, enabled=True):
        """Один проход; enabled=False — пульт выключил бота: ничего не шлём."""
        now = self.now()
        done = {"pass": 0, "city": 0}
        if not enabled:
            return done
        if now - self._pass_at >= PASS_EVERY:
            self._pass_at = now
            done["pass"] = self.pass_step(now)
        if now - self._city_at >= CITY_EVERY:
            self._city_at = now
            done["city"] = self.city_step(now)
        return done

    # перевалы
    def pass_step(self, now):
        statuses = bot_near.pass_status(self.sources.weather(), now)
        conn = self._db()
        queued = 0
        for group, item in statuses.items():
            if item["stale"]:
                continue            # нет свежих данных — не «опасность ушла»
            hazard = bool(item["hazards"])
            with family_notify.transaction(conn):
                row = conn.execute("SELECT hazard, clear_since FROM bot_pass_state WHERE grp = ?",
                                   (group,)).fetchone()
                if row is None:
                    conn.execute("INSERT INTO bot_pass_state(grp, hazard, clear_since, changed) VALUES(?, ?, NULL, ?)",
                                 (group, int(hazard), now))
                    continue
                was, clear_since = bool(row[0]), row[1]
                kind = None
                if hazard and not was:
                    conn.execute("UPDATE bot_pass_state SET hazard = 1, clear_since = NULL, changed = ? WHERE grp = ?",
                                 (now, group))
                    kind = "pass_alert"
                elif hazard and clear_since is not None:
                    conn.execute("UPDATE bot_pass_state SET clear_since = NULL WHERE grp = ?", (group,))
                elif not hazard and was:
                    if clear_since is None:
                        conn.execute("UPDATE bot_pass_state SET clear_since = ? WHERE grp = ?", (now, group))
                    elif now - clear_since >= PASS_CLEAR_HOLD:
                        conn.execute("UPDATE bot_pass_state SET hazard = 0, clear_since = NULL, changed = ? "
                                     "WHERE grp = ?", (now, group))
                        kind = "pass_clear"
                if kind is None:
                    continue
                subs = conn.execute("SELECT id, box, lang FROM bot_subs WHERE kind = 'pass' AND target = ?",
                                    (group,)).fetchall()
                for sid, box, lang in subs:
                    name = bot_near.pass_name(lang, item, group)
                    if kind == "pass_alert":
                        text = bot_texts.text(lang, kind, name=name, what=bot_near.pass_what(lang, item))
                    else:
                        temp = bot_near._temp(lang, item.get("t"))
                        text = bot_texts.text(lang, kind, name=name, temp=f", {temp}" if temp else "")
                    queued += self._queue(conn, sid, box, text, now)
        if queued:
            log(f"перевалы: в очередь {queued}")
        return queued

    # город
    def _confirmed(self, now):
        if not self.reports_db or not os.path.exists(self.reports_db):
            if "reports" not in self._logged:
                self._logged.add("reports")
                log("нет базы отметок — подписки на город молчат")
            return None
        try:
            conn = sqlite3.connect("file:" + urllib.parse.quote(self.reports_db) + "?mode=ro", uri=True, timeout=2.0)
            try:
                rows = telegram_publish.select_confirmed(conn, now=now)
            finally:
                conn.close()
        except sqlite3.Error as error:
            log(f"база отметок не читается — {type(error).__name__}")
            return None
        self._logged.discard("reports")
        return [r for r in rows if r["type"] in CITY_KINDS]

    def city_step(self, now):
        if quiet(now):
            return 0                # утром уйдёт то, что ещё стоит
        conn = self._db()
        subs = conn.execute("SELECT id, target, box, lang, quota_start, quota_used FROM bot_subs "
                            "WHERE kind = 'city'").fetchall()
        if not subs:
            return 0
        reports = self._confirmed(now)
        if not reports:
            return 0
        by_city = {}
        for report in reports:
            city = bot_near.city_of(report["lat"], report["lon"])
            if city is not None:
                by_city.setdefault(city, []).append(report)
        queued = 0
        for sid, city, box, lang, quota_start, quota_used in subs:
            items = by_city.get(city)
            if not items:
                continue
            with family_notify.transaction(conn):
                sent = {row[0] for row in conn.execute("SELECT report FROM bot_city_sent WHERE sub = ?", (sid,))}
                fresh = [r for r in items if r["id"] not in sent][:CITY_PER_MESSAGE]
                if not fresh:
                    continue
                if now - quota_start >= 3600:
                    quota_start, quota_used = now, 0
                if quota_used >= CITY_HOURLY:
                    continue        # подождёт следующего часа, если ещё будет стоять
                text = bot_near.city_message(lang, city, fresh, self.sources.address)
                if not self._queue(conn, sid, box, text, now):
                    continue
                conn.executemany("INSERT OR IGNORE INTO bot_city_sent(sub, report, sent) VALUES(?, ?, ?)",
                                 [(sid, r["id"], now) for r in fresh])
                conn.execute("UPDATE bot_subs SET quota_start = ?, quota_used = ? WHERE id = ?",
                             (quota_start, quota_used + 1, sid))
                queued += 1
        if queued:
            log(f"города: в очередь {queued}")
        return queued
