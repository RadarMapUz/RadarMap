#!/bin/bash
# Деплой api.py на VPS: заливка, проверка синтаксиса, рестарт, смоук-тест.
# Запуск: bash server/deploy_api.sh   (спросит пароль root три раза — или настройте SSH-ключ)
set -euo pipefail

HOST=root@45.130.148.94
API=/opt/radarmap/api/api.py
ADMIN=/opt/radarmap/api/admin.py
AUTH=/opt/radarmap/api/admin_auth.py
STATIC=/opt/radarmap/api/static
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Бэкап текущей версии и заливка новой…"
scp "$DIR/api.py" "$HOST:$API.new"
scp "$DIR/admin.py" "$HOST:$ADMIN.new"
# Модуль входа и скрипт карты: панель без них не поднимется.
scp "$DIR/admin_auth.py" "$HOST:$AUTH.new"
ssh "$HOST" "mkdir -p $STATIC"
scp "$DIR/static/moderate.js" "$HOST:$STATIC/moderate.js"

echo "→ Проверка синтаксиса, подмена, рестарт…"
ssh "$HOST" "
  set -e
  python3 -c \"import ast; ast.parse(open('$API.new').read())\" && echo 'api syntax ok'
  python3 -c \"import ast; ast.parse(open('$ADMIN.new').read())\" && echo 'admin syntax ok'
  python3 -c \"import ast; ast.parse(open('$AUTH.new').read())\" && echo 'admin_auth syntax ok'
  cp $API $API.bak.\$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  cp $ADMIN $ADMIN.bak.\$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  mv $API.new $API
  mv $ADMIN.new $ADMIN
  mv $AUTH.new $AUTH
  systemctl restart radarmap-api
  # Панель — отдельный юнит: она может быть ещё не установлена, и это не повод
  # валить деплой публичного api.
  systemctl restart radarmap-admin 2>/dev/null || echo 'radarmap-admin не установлен (см. radarmap-admin.service)'
  sleep 1
  systemctl is-active radarmap-api
"

echo "→ Смоук-тест новых эндпоинтов через nginx…"
curl -sf -X POST http://45.130.148.94:8090/api/camera_report \
  -H 'Content-Type: application/json' \
  -d '{"camera_id": 1, "reason": "gone", "lat": 41.31, "lon": 69.28, "db_version": 3, "device": "deploy-smoke-test"}'
echo
curl -sf -X POST http://45.130.148.94:8090/api/feedback \
  -H 'Content-Type: application/json' \
  -d '{"message": "smoke test", "device": "deploy-smoke-test", "app_version": "dev"}'
echo
curl -sf http://45.130.148.94:8090/api/health
echo
echo "✓ Готово. Смоук-записи можно почистить:"
echo "  ssh $HOST \"sqlite3 /opt/radarmap/api/reports.db \\\"DELETE FROM camera_reports WHERE device='deploy-smoke-test'; DELETE FROM feedback WHERE device='deploy-smoke-test';\\\"\""
