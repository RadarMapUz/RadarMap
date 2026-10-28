#!/bin/bash
# Выкладка пробок на VPS: сборщик traffic_build.py, его cron и каталог выхода,
# модель обычных пробок (33G) и скрипты стенда MLD (/opt/radarmap/osrm-mld/bin).
# Приём кусков (POST /api/traffic) живёт в api.py и выкладывается обычным
# deploy_api.sh — сначала он, потом этот скрипт.
#
#   bash server/deploy_traffic.sh            (или RADARMAP_SSH_KEY=… bash …)
#   RADARMAP_TRAFFIC_MODEL=путь bash server/deploy_traffic.sh   # другой файл модели
#
# Модель (traffic_model.json.gz) собирается на маке (traffic_model.py build,
# раз в месяц вместе с графом) и едет сюда же; нет файла — сборщик и стенд
# работают без модели (отказ = граф).
#
# Откат: каждый заменённый файл остаётся рядом как <имя>.bak-<метка> (метка —
# в выводе скрипта); вернуть — `bash server/deploy_traffic.sh --rollback <метка>`.
#
# nginx: раздел /radarmap/traffic/ стоит (nginx-radarmap-location.conf — байт в
# байт серверный сниппет); новый комментарий к нему ждёт владельца в
# nginx-radarmap-location.pending.conf. nginx ставится только руками.
set -euo pipefail

HOST=root@45.130.148.94
SSH=(ssh); SCP=(scp)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH=(ssh -i "$RADARMAP_SSH_KEY"); SCP=(scp -i "$RADARMAP_SSH_KEY")
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
API=/opt/radarmap/api
STAND=/opt/radarmap/osrm-mld/bin
BUILD=$API/traffic_build.py
CRON='*/2 * * * * /usr/bin/python3 /opt/radarmap/api/traffic_build.py >> /var/log/radarmap-traffic.log 2>&1'
MODEL="${RADARMAP_TRAFFIC_MODEL:-$HOME/RadarMapBuild/traffic_model/traffic_model.json.gz}"
# Модули сборщика: traffic_build.py импортирует traffic_config (константы),
# зовёт traffic_profile (profile.json, 33C), а тот — traffic_model (33G). Без
# любого из них прогон падает на ModuleNotFoundError (27.10, первая выкатка 33).
API_FILES=(traffic_config.py traffic_model.py traffic_profile.py traffic_build.py)
# Стенд: цикл traffic_customize.sh зовёт traffic_speeds.py → traffic_profile →
# traffic_model, traffic_build (формулы), traffic_config.
STAND_FILES=(traffic_config.py traffic_model.py traffic_profile.py traffic_build.py traffic_speeds.py)

if [ "${1:-}" = "--rollback" ]; then
    STAMP="${2:?--rollback: нужна метка выкладки}"
    "${SSH[@]}" "$HOST" "
      set -e
      for f in $API/traffic_*.py $API/traffic_model.json.gz $STAND/traffic_*.py; do
        [ -e \"\$f.bak-$STAMP\" ] && mv \"\$f.bak-$STAMP\" \"\$f\" && echo \"  вернул \$f\"
      done
      for f in $API/traffic_model.py $API/traffic_model.json.gz $STAND/traffic_model.py; do
        [ -e \"\$f.new-$STAMP\" ] && rm -f \"\$f\" \"\$f.new-$STAMP\" && echo \"  убрал \$f (до $STAMP его не было)\"
      done
      true
    "
    echo "✓ Откат на выкладку до $STAMP."
    exit 0
fi

# Ворота ДО заливки: горячую правку на сервере выкатка не затирает (drift.sh
# --gate; обход — RADARMAP_ALLOW_DRIFT=1).
echo "→ Ворота: сервер не разошёлся с репо по файлам этой выкатки…"
# shellcheck disable=SC2086
RADARMAP_HOST="$HOST" bash "$DIR/drift.sh" --gate "${STAND_FILES[@]}" osrm/route_bench.py || {
    echo "✗ Выкатка остановлена до заливки: файлы на сервере не тронуты."; exit 1; }

STAMP=$(date +%Y%m%d%H%M%S)
echo "→ Локальные тесты сборщика и модели…"
python3 -W ignore -m unittest discover -s "$DIR" -p 'test_traffic_build.py' >/dev/null
python3 -W ignore -m unittest discover -s "$DIR" -p 'test_traffic_model.py' >/dev/null
python3 -W ignore -m unittest discover -s "$DIR" -p 'test_traffic_profile.py' >/dev/null
SHIP_MODEL=0
if [ -s "$MODEL" ]; then
    (cd "$DIR" && python3 -c "import sys, traffic_model as tm; m = tm.load_model(sys.argv[1], enabled=True); assert m, 'модель пуста'; print(f'  модель: рёбер {len(m)}')" "$MODEL")
    SHIP_MODEL=1
else
    echo "  ⚠ модели нет ($MODEL) — сервер без модели обычных пробок"
fi

echo "→ Заливка (метка $STAMP) и проверка синтаксиса той же версией Python, что на сервере…"
for f in "${API_FILES[@]}"; do "${SCP[@]}" "$DIR/$f" "$HOST:$API/$f.new"; done
[ "$SHIP_MODEL" = 0 ] || "${SCP[@]}" "$MODEL" "$HOST:$API/traffic_model.json.gz.new"
"${SSH[@]}" "$HOST" "
  set -e
  cd $API
  for f in ${API_FILES[*]}; do python3 -c \"import ast, sys; ast.parse(open(sys.argv[1]).read())\" \$f.new; done
  [ ! -e traffic_model.json.gz.new ] || python3 -c \"import gzip, json, sys; d = json.load(gzip.open(sys.argv[1])); assert d['v'] == 1 and d['edges']\" traffic_model.json.gz.new
  # Прежние версии — рядом с меткой (откат: --rollback $STAMP); новых до сих пор
  # не было — метка .new-, откат их удалит.
  for f in ${API_FILES[*]} traffic_model.json.gz; do
    [ -e \$f.new ] || continue
    if [ -e \$f ]; then cp -p \$f \$f.bak-$STAMP; else : > \$f.new-$STAMP; fi
  done
  for f in ${API_FILES[*]} traffic_model.json.gz; do [ ! -e \$f.new ] || mv \$f.new \$f; done
  mkdir -p /opt/radarmap/www/traffic
  # Пробный прогон: OSRM отвечает, база создаётся, файл пишется.
  python3 $BUILD
  test -s /opt/radarmap/www/traffic/now.json
  # «Обычно по водителям» (8.8.16): первый прогон пишет все 48 файлов.
  test -s /opt/radarmap/www/traffic/typical/wd-08.json
  # profile.json (33C) — с моделью (33G): переписать сейчас, не ждать суток.
  python3 -c \"
import sqlite3, sys, time
sys.path.insert(0, '$API')
import traffic_build as tb
conn = sqlite3.connect(tb.DB_PATH, timeout=5)
count, trimmed = tb.write_profile_json(conn, time.time())
print(f'  profile.json: рёбер {count}, обрезано {trimmed}')
\"
  # cron — идемпотентно: строка добавляется один раз.
  ( crontab -l 2>/dev/null | grep -vF 'traffic_build.py'; echo '$CRON' ) | crontab -
  crontab -l | grep -F traffic_build.py
"

echo "→ Стенд MLD: скрипты в $STAND…"
for f in "${STAND_FILES[@]}"; do "${SCP[@]}" "$DIR/$f" "$HOST:$STAND/$f.new"; done
"${SCP[@]}" "$DIR/osrm/route_bench.py" "$HOST:$STAND/route_bench.py"
"${SSH[@]}" "$HOST" "
  set -e
  cd $STAND
  for f in ${STAND_FILES[*]}; do python3 -c \"import ast, sys; ast.parse(open(sys.argv[1]).read())\" \$f.new; done
  for f in ${STAND_FILES[*]}; do
    if [ -e \$f ]; then cp -p \$f \$f.bak-$STAMP; else : > \$f.new-$STAMP; fi
    mv \$f.new \$f
  done
  # Сухой расчёт файла скоростей в сторону (рабочий speeds.csv не трогаем):
  # модули стыкуются, модель читается.
  python3 traffic_speeds.py --source route --out /tmp/radarmap-speeds-check.csv
  rm -f /tmp/radarmap-speeds-check.csv /tmp/radarmap-speeds-check.csv.lock
"

echo "→ Смоук: файлы отдаются через nginx…"
curl -sf -o /dev/null -w '  now.json → %{http_code}, %{size_download} байт\n' \
  https://soulmed.uz/radarmap/traffic/now.json || \
  echo "  ⚠ /radarmap/traffic/ не отдаётся — поставьте раздел nginx (см. шапку скрипта)"
curl -sf -o /dev/null -w '  typical/wd-08.json → %{http_code}, %{size_download} байт\n' \
  https://soulmed.uz/radarmap/traffic/typical/wd-08.json || \
  echo "  ⚠ typical/ не отдаётся — тот же раздел nginx"
curl -sf -o /dev/null -w '  profile.json → %{http_code}, %{size_download} байт\n' \
  https://soulmed.uz/radarmap/traffic/profile.json || \
  echo "  ⚠ profile.json не отдаётся"
echo "✓ Пробки выложены (метка $STAMP; откат: bash server/deploy_traffic.sh --rollback $STAMP)."
