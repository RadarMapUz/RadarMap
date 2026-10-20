#!/bin/bash
# Выкладка Telegram-бота отметок (12б.7). Запускает владелец, после
# deploy_api.sh (бот шлёт отметки в тот же API на 127.0.0.1:8091).
#
# Перед первым запуском на сервере нужен конфиг (в git его нет):
#   /opt/radarmap/telegram_bot.conf
#     token=<токен бота от @BotFather>
#     salt=<openssl rand -hex 32>
# Без конфига бот честно выходит и не крутится в перезапусках.
#
#   RADARMAP_SSH_KEY=~/.ssh/radarmap_deploy bash server/deploy_bot.sh
set -euo pipefail

HOST=root@45.130.148.94
SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Тесты бота локально…"
(cd "$DIR" && python3 -W ignore -m unittest -q test_telegram_bot)

echo "→ Заливка…"
"${SCP[@]}" "$DIR/telegram_bot.py" "$HOST:/opt/radarmap/api/telegram_bot.py.new"
"${SCP[@]}" "$DIR/radarmap-bot.service" "$HOST:/etc/systemd/system/radarmap-bot.service"
"${SSH[@]}" "$HOST" "python3 -m py_compile /opt/radarmap/api/telegram_bot.py.new \
    && mv /opt/radarmap/api/telegram_bot.py.new /opt/radarmap/api/telegram_bot.py \
    && systemctl daemon-reload && systemctl enable radarmap-bot >/dev/null \
    && systemctl restart radarmap-bot && sleep 2 && systemctl --no-pager --lines=5 status radarmap-bot || true"
echo "✓ Готово. Нет конфига — в статусе будет «нет конфига», это не ошибка."
