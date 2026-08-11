#!/usr/bin/env python3
"""Уведомления владельцу в Telegram.

Почему это отдельный модуль, а не три строки в обработчике: у доставки есть
свои правила, и все три родились из настоящих способов сломать сервис.

1. ДОСТАВКА НЕ БЛОКИРУЕТ ОТВЕТ. Письмо разработчику пишет человек, который уже
   чем-то недоволен; если ради уведомления мы держим его запрос, пока лежит
   api.telegram.org, он получит таймаут вместо «спасибо». Отправка уходит в
   отдельный поток с коротким таймаутом, и её провал не виден снаружи вообще —
   сообщение к этому моменту уже лежит в базе, а бот всего лишь способ узнать
   о нём быстрее.

2. ТЕКСТ ПОЛЬЗОВАТЕЛЯ — ДАННЫЕ, А НЕ РАЗМЕТКА. Он идёт в HTML-режиме Telegram,
   поэтому экранируется целиком. Иначе первое же письмо с «<b>» ломает
   сообщение, а специально составленное — подделывает подпись под ним.

3. КООРДИНАТ ЗДЕСЬ НЕТ И НЕ БУДЕТ. Приложение построено так, что сервер не
   знает, где находится человек; бот — это ещё один канал наружу, и через него
   утечь тоже нечему.

Плюс кап на сообщения в час: десять писем от одного расстроенного человека не
должны превратиться в десять пингов, после которых бота выключают.

Токен и chat_id живут в /opt/radarmap/admin.conf (там же, где хэш пароля
панели и ключ карт) и в git не попадают:

    tg_token=…
    tg_chat=…

chat_id узнаётся один раз: написать боту любое сообщение и открыть
https://api.telegram.org/bot<ТОКЕН>/getUpdates — он в message.chat.id.
"""

import json
import os
import threading
import time
import urllib.parse
import urllib.request

CONFIG_PATH = os.environ.get("RADARMAP_ADMIN_CONF", "/opt/radarmap/admin.conf")

# Потолок сообщений в час. Не защита от злоумышленника (у того есть суточные
# капы в api.py), а защита от ситуации «бот стал шумом и его отключили».
MAX_PER_HOUR = 20
TIMEOUT = 6

_lock = threading.Lock()
_sent = []          # отметки времени отправленных сообщений
_config_cache = (0.0, {})


def _config():
    """Конфиг с кэшем на минуту: читается на каждое письмо, а меняется раз в
    год. Перечитывание нужно, чтобы токен можно было подложить без рестарта."""
    global _config_cache
    stamp, cached = _config_cache
    now = time.time()
    if now - stamp < 60:
        return cached
    config = {}
    try:
        with open(CONFIG_PATH, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                config[key.strip()] = value.strip()
    except OSError:
        pass
    _config_cache = (now, config)
    return config


def is_configured():
    config = _config()
    return bool(config.get("tg_token") and config.get("tg_chat"))


def escape(text):
    """Экранирование под parse_mode=HTML телеграма."""
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _allowed(now):
    """Кап в скользящем часе."""
    with _lock:
        cutoff = now - 3600
        _sent[:] = [t for t in _sent if t > cutoff]
        if len(_sent) >= MAX_PER_HOUR:
            return False
        _sent.append(now)
        return True


def _post(token, chat, text, preview=False):
    payload = urllib.parse.urlencode({
        "chat_id": chat,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "false" if preview else "true",
    }).encode()
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage", data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.status == 200


def send(text, now=None):
    """Отправить в фоне. Возвращает управление немедленно и всегда."""
    config = _config()
    token, chat = config.get("tg_token"), config.get("tg_chat")
    if not token or not chat:
        return False
    if not _allowed(now or time.time()):
        return False

    def worker():
        try:
            _post(token, chat, text)
        except Exception:
            # Молча: бот — удобство, а не часть контракта сервиса. Ошибку
            # доставки видно по тому, что сообщения не пришло.
            pass

    threading.Thread(target=worker, daemon=True).start()
    return True


# --------------------------------------------------------------------------
# Готовые сообщения
# --------------------------------------------------------------------------

def feedback(message, contact, app_version, admin_url=None):
    """Письмо разработчику из формы в настройках."""
    lines = ["📬 <b>Письмо из приложения</b>", "", escape(message[:1500])]
    tail = []
    if contact:
        tail.append(f"контакт: {escape(contact)}")
    if app_version:
        tail.append(f"версия: {escape(app_version)}")
    if tail:
        lines += ["", "<i>" + " · ".join(tail) + "</i>"]
    if admin_url:
        lines += ["", escape(admin_url)]
    return send("\n".join(lines))


def camera_report(camera_id, reason, note=""):
    """Жалоба на камеру в базе: не туда снята, нет её, не тот тип."""
    lines = [f"📍 <b>Жалоба на камеру {int(camera_id)}</b>", escape(reason)]
    if note:
        lines.append(escape(note[:500]))
    return send("\n".join(lines))


def daily_digest(stats):
    """Сводка за сутки. Раз в день, а не на событие: краудсорс шумит, и
    поштучные уведомления об отметках превратили бы бота в ленту."""
    lines = ["📊 <b>RadarMap за сутки</b>", ""]
    for label, value in stats:
        lines.append(f"{escape(label)}: <b>{escape(value)}</b>")
    return send("\n".join(lines))
