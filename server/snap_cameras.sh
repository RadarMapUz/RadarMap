#!/bin/bash
# Snap координат камер к оси дороги через OSRM /nearest.
# Заливает snap_cameras.py, прогоняет на живой базе, кладёт РЯДОМ cameras.snapped.json
# и печатает отчёт. Живую базу НЕ трогает — замену делаете вручную после проверки.
#
# Запуск: bash server/snap_cameras.sh   (спросит пароль root — или настройте SSH-ключ)
set -euo pipefail

HOST=root@45.130.148.94
BASE_DIR=/opt/radarmap/static          # где nginx раздаёт cameras.json / version.json
OSRM=http://127.0.0.1:5000             # внутренний OSRM (docker)
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Заливка snap_cameras.py…"
scp "$DIR/snap_cameras.py" "$HOST:$BASE_DIR/snap_cameras.py"

echo "→ Самотест матчинга имён (без сети)…"
ssh "$HOST" "python3 $BASE_DIR/snap_cameras.py --selftest"

echo "→ Прогон по живой базе (отчёт по переносам > 5 м)…"
ssh "$HOST" "
  set -e
  cd $BASE_DIR
  python3 snap_cameras.py --in cameras.json --out cameras.snapped.json --osrm $OSRM
"

echo
echo "✓ Готово. Рядом с базой лежит cameras.snapped.json (живая база НЕ изменена)."
echo "  Проверьте отчёт выше. Чтобы промоутить в прод и раздать по OTA:"
echo "    ssh $HOST \"cd $BASE_DIR && \\"
echo "      cp cameras.json cameras.json.bak.\\\$(date +%Y%m%d%H%M%S) && \\"
echo "      mv cameras.snapped.json cameras.json && \\"
echo "      v=\\\$(python3 -c \\\"import json;print(json.load(open('version.json'))['version']+1)\\\") && \\"
echo "      n=\\\$(python3 -c \\\"import json;print(len(json.load(open('cameras.json'))))\\\") && \\"
echo "      echo '{\\\"version\\\": '\\\$v', \\\"count\\\": '\\\$n'}' > version.json\""
echo "  Затем обновите bundled-копию в репозитории (RadarMap/Resources/cameras.json) для новых установок."
