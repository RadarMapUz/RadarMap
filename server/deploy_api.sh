#!/bin/bash
# Деплой api.py на VPS: заливка, проверка синтаксиса, рестарт, смоук-тест.
# Запуск: bash server/deploy_api.sh   (спросит пароль root три раза — или настройте SSH-ключ)
set -euo pipefail

HOST=root@45.130.148.94
API=/opt/radarmap/api/api.py
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Бэкап текущей версии и заливка новой…"
scp "$DIR/api.py" "$HOST:$API.new"

echo "→ Проверка синтаксиса, подмена, рестарт…"
ssh "$HOST" "
  set -e
  python3 -c \"import ast; ast.parse(open('$API.new').read())\" && echo 'syntax ok'
  cp $API $API.bak.\$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  mv $API.new $API
  systemctl restart radarmap-api
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
