#!/bin/bash
# Выкладка Telegram-бота отметок (12б.7) и близких (22.3). Запускает
# владелец, после deploy_api.sh: бот шлёт отметки в тот же API на
# 127.0.0.1:8091, а сообщения близким кладёт в очередь сам api.py
# (family_notify.py — его deploy_api.sh уже привёз; здесь тот же файл ещё раз,
# чтобы бот и api не разошлись версиями).
#
# Перед первым запуском на сервере нужен конфиг (в git его нет):
#   /opt/radarmap/telegram_bot.conf
#     token=<токен бота от @BotFather>
#     salt=<openssl rand -hex 32>        (не менять: от неё хэши подписок близких)
#     username=<имя бота без @>          (ссылка t.me/<имя>?start=f_… на странице близкого)
#     venues_dir=/opt/radarmap/www/roads   (необязательно, это значение по умолчанию)
# Без конфига бот честно выходит и не крутится в перезапусках.
# Подписки близких — /opt/radarmap/api/family.db, бот создаёт её сам.
#
# Метан бот принимает только у АГНКС из опубликованных файлов заведений
# (road2_*_v.json в venues_dir, их кладёт publish_roads.sh). Нет файлов —
# на «метан» бот отвечает «сейчас не принимаются» и пишет это в журнал.
#
#   RADARMAP_SSH_KEY=~/.ssh/radarmap_deploy bash server/deploy_bot.sh
set -euo pipefail

HOST=root@45.130.148.94
SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Тесты бота и близких локально…"
(cd "$DIR" && python3 -W ignore -m unittest -q test_telegram_bot test_family_notify)

# Хэш человека — scrypt (аудит 14.3, N6). Python без него бот не запустит —
# проверяем ДО замены рабочего файла, а не после рестарта.
echo "→ Python на сервере: hashlib.scrypt…"
"${SSH[@]}" "$HOST" "/usr/bin/python3 -c 'import hashlib; hashlib.scrypt'" \
    || { echo "✗ в /usr/bin/python3 на сервере нет hashlib.scrypt — бот не выкладываю"; exit 1; }

echo "→ Заливка…"
"${SCP[@]}" "$DIR/telegram_bot.py" "$HOST:/opt/radarmap/api/telegram_bot.py.new"
"${SCP[@]}" "$DIR/family_notify.py" "$HOST:/opt/radarmap/api/family_notify.py.new"
"${SCP[@]}" "$DIR/radarmap-bot.service" "$HOST:/etc/systemd/system/radarmap-bot.service"
"${SSH[@]}" "$HOST" "python3 -m py_compile /opt/radarmap/api/telegram_bot.py.new \
    && python3 -m py_compile /opt/radarmap/api/family_notify.py.new \
    && mv /opt/radarmap/api/family_notify.py.new /opt/radarmap/api/family_notify.py \
    && mv /opt/radarmap/api/telegram_bot.py.new /opt/radarmap/api/telegram_bot.py \
    && systemctl daemon-reload && systemctl enable radarmap-bot >/dev/null \
    && systemctl restart radarmap-bot && sleep 2 && systemctl --no-pager --lines=5 status radarmap-bot || true"
echo "✓ Готово. Нет конфига — в статусе будет «нет конфига», это не ошибка."
