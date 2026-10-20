#!/bin/bash
# Выкладка погоды на трассах (19.1) на VPS: сборщик build_road_weather.py,
# список точек road_weather_points.json, cron раз в 30 минут и каталог выхода.
#
#   bash server/deploy_road_weather.sh            (или RADARMAP_SSH_KEY=… bash …)
#
# Перед выкладкой владелец проверяет точки (поле check у каждой — «проверить»):
# координата на оси трассы, участок верный.
#
# nginx: раздел /radarmap/weather/ из nginx-radarmap-location.conf ставится
# руками (как и весь сниппет: drift.sh покажет расхождение), затем
# `nginx -t && systemctl reload nginx`. Без него файл отдаёт общий
# /radarmap/ с кэшем на 5 минут — работает, но ETag проверяется реже.
set -euo pipefail

HOST=root@45.130.148.94
SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
API_DIR=/opt/radarmap/api
BUILD=$API_DIR/build_road_weather.py
POINTS=$API_DIR/road_weather_points.json
OUT=/opt/radarmap/www/weather/roads.json
CRON='*/30 * * * * /usr/bin/python3 /opt/radarmap/api/build_road_weather.py >> /var/log/radarmap-weather.log 2>&1'

echo "→ Локальные тесты сборщика и проверка списка точек…"
python3 -W ignore -m unittest discover -s "$DIR" -p 'test_build_road_weather.py' >/dev/null
python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import build_road_weather as rw; print('  точек', len(rw.load_points(sys.argv[2])))" \
    "$DIR" "$DIR/road_weather_points.json"

echo "→ Заливка и проверка синтаксиса той же версией Python, что на сервере…"
"${SCP[@]}" "$DIR/build_road_weather.py" "$HOST:$BUILD.new"
"${SCP[@]}" "$DIR/road_weather_points.json" "$HOST:$POINTS.new"
"${SSH[@]}" "$HOST" "
  set -e
  python3 -c \"import ast, sys; ast.parse(open(sys.argv[1]).read())\" $BUILD.new
  python3 -c \"import json, sys; json.load(open(sys.argv[1]))\" $POINTS.new
  mv $BUILD.new $BUILD
  mv $POINTS.new $POINTS
  mkdir -p /opt/radarmap/www/weather
  # Пробный прогон: open-meteo отвечает, файл пишется.
  python3 $BUILD
  test -s $OUT
  # cron — идемпотентно: строка добавляется один раз.
  ( crontab -l 2>/dev/null | grep -vF 'build_road_weather.py'; echo '$CRON' ) | crontab -
  crontab -l | grep -F build_road_weather.py
"

echo "→ Смоук: файл отдаётся через nginx…"
curl -sf -o /dev/null -w '  roads.json → %{http_code}, %{size_download} байт\n' \
  https://soulmed.uz/radarmap/weather/roads.json || \
  echo "  ⚠ /radarmap/weather/ не отдаётся — поставьте раздел nginx (см. шапку скрипта)"
echo "✓ Погода на трассах выложена."
