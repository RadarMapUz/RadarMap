#!/bin/bash
# Привязка Telegram-бота к чату владельца.
#
# Токен у бота один, а вот КОМУ он пишет — узнать неоткуда, пока владелец сам
# не напишет боту: Telegram не отдаёт chat_id по токену. Поэтому порядок такой:
#
#   1. Открыть @radarmapuz_bot и отправить ему любое сообщение (проще /start).
#   2. Запустить этот скрипт на сервере:  bash /opt/radarmap/api/tg_bind.sh
#
# Скрипт читает токен из /opt/radarmap/admin.conf (в git его нет и не будет),
# спрашивает у Telegram последние сообщения, берёт оттуда chat_id, дописывает
# его в тот же конфиг и отправляет проверочное сообщение.
#
# Идемпотентен: повторный запуск просто перезапишет chat_id тем же значением.
set -euo pipefail

CONF="${RADARMAP_ADMIN_CONF:-/opt/radarmap/admin.conf}"

TOKEN=$(grep -E '^tg_token=' "$CONF" 2>/dev/null | cut -d= -f2- || true)
if [ -z "$TOKEN" ]; then
    echo "В $CONF нет строки tg_token=… — сначала положите туда токен бота." >&2
    exit 1
fi

CHAT=$(curl -sf --max-time 15 "https://api.telegram.org/bot${TOKEN}/getUpdates" \
       | python3 -c '
import json, sys
data = json.load(sys.stdin)
ids = []
for update in data.get("result", []):
    message = update.get("message") or update.get("channel_post") or {}
    chat = message.get("chat") or {}
    if chat.get("id") and chat["id"] not in ids:
        ids.append(chat["id"])
# Последний написавший — тот, кто только что нажал /start.
print(ids[-1] if ids else "")
')

if [ -z "$CHAT" ]; then
    cat >&2 <<'EOF'
Боту никто не писал — привязывать не к чему.

Откройте в Telegram @radarmapuz_bot, отправьте /start и запустите скрипт снова.
(Если бот уже читал сообщения раньше, Telegram мог их отдать и забыть —
просто напишите ему ещё раз.)
EOF
    exit 1
fi

if grep -q '^tg_chat=' "$CONF"; then
    sed -i "s|^tg_chat=.*|tg_chat=${CHAT}|" "$CONF"
else
    echo "tg_chat=${CHAT}" >> "$CONF"
fi
chmod 600 "$CONF"

curl -sf --max-time 15 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
     --data-urlencode "chat_id=${CHAT}" \
     --data-urlencode "text=✅ RadarMap на связи. Сюда будут приходить письма из приложения, жалобы на камеры и сообщения сторожа." \
     >/dev/null

echo "Готово: chat_id ${CHAT} записан в $CONF, проверочное сообщение отправлено."
echo "Осталось включить сторожа (healthcheck) — см. server/HTTPS.md."
