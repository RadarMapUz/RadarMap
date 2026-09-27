#!/bin/bash
# Деплой api.py на VPS: заливка, проверка синтаксиса, рестарт, смоук-тест.
# Запуск: bash server/deploy_api.sh   (спросит пароль root три раза — или настройте SSH-ключ)
set -euo pipefail

HOST=root@45.130.148.94
# Ключ, если он есть. Без него ssh спросит пароль трижды и в неинтерактивной
# сессии просто повиснет — а деплой запускают в том числе из скрипта.
#   RADARMAP_SSH_KEY=~/.ssh/radarmap_deploy bash server/deploy_api.sh
SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi
# Только панель, без публичного api.
#
#   RADARMAP_DEPLOY_ONLY=panel bash server/deploy_api.sh
#
# Юниты разведены намеренно — модерация не должна отваливаться вместе с
# приёмом репортов, — а деплой их до сих пор склеивал: выкатывая правку в
# панели, ты неизбежно выкатывал и api.py, даже если в нём накопилось
# незапланированное. Ровно так и вышло в первый раз, когда панель поехала
# отдельно от api.
ONLY="${RADARMAP_DEPLOY_ONLY:-all}"
API=/opt/radarmap/api/api.py
ADMIN=/opt/radarmap/api/admin.py
AUTH=/opt/radarmap/api/admin_auth.py
NOTIFY=/opt/radarmap/api/notify.py
# Конструктор карты: магнит с хранилищем правок и очередь изменений OSM.
# Панель импортирует оба на старте и без них не поднимется.
EDITS=/opt/radarmap/api/map_edits.py
QUEUE=/opt/radarmap/api/osm_queue.py
# Пульт состояния: крон зовёт его раз в 5 минут, панель читает его отчёт.
STATUS=/opt/radarmap/api/status.py
STATIC=/opt/radarmap/api/static
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Бэкап текущей версии и заливка новой…"
if [ "$ONLY" = "panel" ]; then
    echo "  только панель: api.py не трогаем"
else
    "${SCP[@]}" "$DIR/api.py" "$HOST:$API.new"
fi
"${SCP[@]}" "$DIR/admin.py" "$HOST:$ADMIN.new"
# Модуль входа и скрипт карты: панель без них не поднимется.
"${SCP[@]}" "$DIR/admin_auth.py" "$HOST:$AUTH.new"
# Уведомления в Telegram: api.py импортирует модуль на старте и без него не поднимется.
"${SCP[@]}" "$DIR/notify.py" "$HOST:$NOTIFY.new"
"${SCP[@]}" "$DIR/map_edits.py" "$HOST:$EDITS.new"
"${SCP[@]}" "$DIR/osm_queue.py" "$HOST:$QUEUE.new"
"${SCP[@]}" "$DIR/status.py" "$HOST:$STATUS.new"
"${SSH[@]}" "$HOST" "mkdir -p $STATIC"
"${SCP[@]}" "$DIR/static/moderate.js" "$HOST:$STATIC/moderate.js"
"${SCP[@]}" "$DIR/static/editor.js" "$HOST:$STATIC/editor.js"
# Панель на MapLibre — рядом с рабочей, за адресом /editor-gl. Библиотека
# лежит своим файлом: CSP страницы запрещает чужие источники скриптов, и это
# не формальность — на этой странице сессия модератора.
"${SSH[@]}" "$HOST" "mkdir -p $STATIC/vendor"
"${SCP[@]}" "$DIR/static/editor_gl.js" "$HOST:$STATIC/editor_gl.js"
"${SCP[@]}" "$DIR/static/vendor/maplibre-gl.js" "$HOST:$STATIC/vendor/maplibre-gl.js"
"${SCP[@]}" "$DIR/static/vendor/maplibre-gl.css" "$HOST:$STATIC/vendor/maplibre-gl.css"
# Глифы подписей: три диапазона из трёхсот килобайт — латиница, латиница с
# диакритикой (в узбекских названиях есть oʻ и gʻ) и кириллица. Чужой сервис
# глифов подключается одной строкой и роняет карту модератора вместе с собой.
"${SSH[@]}" "$HOST" "mkdir -p $STATIC/vendor/glyphs"
"${SCP[@]}" "$DIR/static/vendor/glyphs/"*.pbf "$HOST:$STATIC/vendor/glyphs/"

echo "→ Проверка синтаксиса, подмена, рестарт…"
# ВАЖНО: проверять надо ТОЙ ЖЕ версией Python, что стоит на сервере, и падать
# на первой же ошибке. Оба правила написаны кровью: на машине разработчика
# 3.14, на сервере 3.10, и вложенные кавычки в f-строке (разрешены с 3.12)
# прошли локально. А `python3 -c … && echo` не прерывал set -e, потому что
# внутри && ошибка не считается фатальной, — сломанный файл доехал до боевой
# панели и уронил её в цикл перезапуска.
"${SSH[@]}" "$HOST" "
  set -e
  files=\"$ADMIN.new $AUTH.new $NOTIFY.new $EDITS.new $QUEUE.new $STATUS.new\"
  [ '$ONLY' = 'panel' ] || files=\"$API.new \$files\"
  for f in \$files; do
    if python3 -c \"import ast, sys; ast.parse(open(sys.argv[1]).read())\" \"\$f\"; then
      echo \"  \$(basename \$f): синтаксис ок\"
    else
      echo \"  \$(basename \$f): СИНТАКСИЧЕСКАЯ ОШИБКА — деплой отменён, боевые файлы не тронуты\"
      exit 1
    fi
  done
  cp $API $API.bak.\$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  cp $ADMIN $ADMIN.bak.\$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  [ '$ONLY' = 'panel' ] || mv $API.new $API
  mv $ADMIN.new $ADMIN
  mv $AUTH.new $AUTH
  mv $NOTIFY.new $NOTIFY
  mv $EDITS.new $EDITS
  mv $QUEUE.new $QUEUE
  mv $STATUS.new $STATUS
  # Где лежат опубликованные тайлы. Без этого конструктор открывается, но
  # магнит не находит ни одной дороги — путь по умолчанию указывает в каталог,
  # которого на сервере нет. Врезкой, а не правкой юнита: юнит на сервере уже
  # правили руками, и перезаписать его значило бы стереть чужие строки.
  mkdir -p /etc/systemd/system/radarmap-admin.service.d
  printf '[Service]\nEnvironment=RADARMAP_TILES=/opt/radarmap/www/roads\n' \
      > /etc/systemd/system/radarmap-admin.service.d/tiles.conf
  systemctl daemon-reload
  [ '$ONLY' = 'panel' ] || systemctl restart radarmap-api
  # Панель — отдельный юнит: она может быть ещё не установлена, и это не повод
  # валить деплой публичного api.
  systemctl restart radarmap-admin 2>/dev/null || echo 'radarmap-admin не установлен (см. radarmap-admin.service)'
  sleep 1
  [ '$ONLY' = 'panel' ] || systemctl is-active radarmap-api
"

echo "→ Смоук-тест панели: конструктор поднялся и видит дороги…"
"${SSH[@]}" "$HOST" "
  set -e
  systemctl is-active radarmap-admin
  # 401 — правильный ответ: страница под замком. Пятисотка означает, что
  # панель упала на импорте новых модулей.
  code=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8093/editor)
  echo \"  /editor → \$code\"
  test \"\$code\" = 401 -o \"\$code\" = 200
"

if [ "$ONLY" = "panel" ]; then
    echo "✓ Панель выкачена. api.py не тронут."
    exit 0
fi

echo "→ Смоук-тест новых эндпоинтов через nginx…"
curl -sf -X POST https://soulmed.uz/radarmap/api/camera_report \
  -H 'Content-Type: application/json' \
  -d '{"camera_id": 1, "reason": "gone", "lat": 41.31, "lon": 69.28, "db_version": 3, "device": "deploy-smoke-test"}'
echo
curl -sf -X POST https://soulmed.uz/radarmap/api/feedback \
  -H 'Content-Type: application/json' \
  -d '{"message": "smoke test", "device": "deploy-smoke-test", "app_version": "dev"}'
echo
curl -sf https://soulmed.uz/radarmap/api/health
echo
echo "✓ Готово. Смоук-записи можно почистить:"
echo "  ssh $HOST \"sqlite3 /opt/radarmap/api/reports.db \\\"DELETE FROM camera_reports WHERE device='deploy-smoke-test'; DELETE FROM feedback WHERE device='deploy-smoke-test';\\\"\""
