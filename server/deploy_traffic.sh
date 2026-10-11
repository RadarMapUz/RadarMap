#!/bin/bash
# Выкладка пробок на VPS: сборщик traffic_build.py, его cron и каталог выхода.
# Приём кусков (POST /api/traffic) живёт в api.py и выкладывается обычным
# deploy_api.sh — сначала он, потом этот скрипт.
#
#   bash server/deploy_traffic.sh            (или RADARMAP_SSH_KEY=… bash …)
#
# nginx: раздел /radarmap/traffic/ из nginx-radarmap-location.conf ставится
# руками (как и весь сниппет: drift.sh покажет расхождение), затем
# `nginx -t && systemctl reload nginx`.
set -euo pipefail

HOST=root@45.130.148.94
SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD=/opt/radarmap/api/traffic_build.py
CRON='*/2 * * * * /usr/bin/python3 /opt/radarmap/api/traffic_build.py >> /var/log/radarmap-traffic.log 2>&1'

echo "→ Локальные тесты сборщика…"
python3 -W ignore -m unittest discover -s "$DIR" -p 'test_traffic_build.py' >/dev/null

echo "→ Заливка и проверка синтаксиса той же версией Python, что на сервере…"
"${SCP[@]}" "$DIR/traffic_build.py" "$HOST:$BUILD.new"
"${SSH[@]}" "$HOST" "
  set -e
  python3 -c \"import ast, sys; ast.parse(open(sys.argv[1]).read())\" $BUILD.new
  mv $BUILD.new $BUILD
  mkdir -p /opt/radarmap/www/traffic
  # Пробный прогон: OSRM отвечает, база создаётся, файл пишется.
  python3 $BUILD
  test -s /opt/radarmap/www/traffic/now.json
  # cron — идемпотентно: строка добавляется один раз.
  ( crontab -l 2>/dev/null | grep -vF 'traffic_build.py'; echo '$CRON' ) | crontab -
  crontab -l | grep -F traffic_build.py
"

echo "→ Смоук: файл отдаётся через nginx…"
curl -sf -o /dev/null -w '  now.json → %{http_code}, %{size_download} байт\n' \
  https://soulmed.uz/radarmap/traffic/now.json || \
  echo "  ⚠ /radarmap/traffic/ не отдаётся — поставьте раздел nginx (см. шапку скрипта)"
echo "✓ Пробки выложены."
