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
#     app_url=<ссылка App Store>         (необязательно; нет — /app скажет «скоро в App Store»)
#     owner_hash=<хэш владельца>         (необязательно; /stats. Получить на сервере:
#                                         echo <ваш Telegram-id> | python3 /opt/radarmap/api/telegram_bot.py --owner-hash)
# Без конфига бот честно выходит и не крутится в перезапусках.
# Подписки близких — /opt/radarmap/api/family.db, бот создаёт её сам; подписки
# на город и перевалы, язык и очередь — в bot.db рядом.
#
# Профиль (имя, описания, меню команд ru/uz) бот выставляет сам при запуске,
# если текст изменился. Аватар — только руками в @BotFather (/setuserpic).
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
MODULES="telegram_bot.py bot_texts.py bot_near.py bot_subs.py family_notify.py telegram_publish.py"

# Ворота ДО всего: горячую правку на сервере выкатка не затирает (drift.sh
# --gate; обход — RADARMAP_ALLOW_DRIFT=1). Юнит тоже перезаписывается — он в списке.
echo "→ Ворота: сервер не разошёлся с репо по файлам этой выкатки…"
# shellcheck disable=SC2086
RADARMAP_HOST="$HOST" bash "$DIR/drift.sh" --gate $MODULES radarmap-bot.service || {
    echo "✗ Выкатка остановлена до заливки: боевые файлы не тронуты."; exit 1; }

echo "→ Тесты бота и близких локально…"
(cd "$DIR" && python3 -W ignore -m unittest -q test_telegram_bot test_bot_features test_family_notify)

# Хэш человека — scrypt (аудит 14.3, N6). Python без него бот не запустит —
# проверяем ДО замены рабочего файла, а не после рестарта.
echo "→ Python на сервере: hashlib.scrypt…"
"${SSH[@]}" "$HOST" "/usr/bin/python3 -c 'import hashlib; hashlib.scrypt'" \
    || { echo "✗ в /usr/bin/python3 на сервере нет hashlib.scrypt — бот не выкладываю"; exit 1; }

echo "→ Заливка…"
# Модули бота (23.x) и то, что он берёт у канала (telegram_publish.py — его же
# возит deploy_api.sh; здесь тот же файл, чтобы бот и крон не разошлись).
# Список — MODULES в начале скрипта (по нему же ворота).
for f in $MODULES; do
    "${SCP[@]}" "$DIR/$f" "$HOST:/opt/radarmap/api/$f.new"
done
"${SCP[@]}" "$DIR/radarmap-bot.service" "$HOST:/etc/systemd/system/radarmap-bot.service"
"${SSH[@]}" "$HOST" "cd /opt/radarmap/api \
    && for f in $MODULES; do python3 -m py_compile \$f.new || exit 1; done \
    && for f in $MODULES; do mv \$f.new \$f; done \
    && systemctl daemon-reload && systemctl enable radarmap-bot >/dev/null \
    && systemctl restart radarmap-bot && sleep 2 && systemctl --no-pager --lines=5 status radarmap-bot || true"
echo "→ Сверка сервера с репо (drift.sh)…"
RADARMAP_HOST="$HOST" bash "$DIR/drift.sh" --quiet || echo "  ⚠ сервер разошёлся с репо — см. строки выше"
echo "✓ Готово. Нет конфига — в статусе будет «нет конфига», это не ошибка."
