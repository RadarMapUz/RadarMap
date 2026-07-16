#!/bin/bash
# Snap координат камер к оси дороги по ИМЕНОВАННОЙ геометрии OSM.
# Готовит roads.geojsonl из pbf (osmium), прогоняет snap на живой базе и кладёт
# РЯДОМ: cameras.snapped.json + snap_report.csv + snap_moves.geojson.
# Живую базу НЕ трогает — замену и bump version.json делаете вручную после
# визуальной проверки переносов (snap_moves.geojson на geojson.io).
#
# Запуск:  bash server/snap_cameras.sh [/путь/к/uzbekistan.osm.pbf]
#          (pbf — тот же, из которого собран OSRM; если не указать, ищем сами)
set -euo pipefail

HOST=root@45.130.148.94
BASE_DIR=/opt/radarmap/static          # где nginx раздаёт cameras.json / version.json
PBF_ARG="${1:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "→ Заливка snap_cameras.py…"
scp "$DIR/snap_cameras.py" "$HOST:$BASE_DIR/snap_cameras.py"

echo "→ Самотест логики (без сети): ловушка параллельной улицы + транслит…"
ssh "$HOST" "python3 $BASE_DIR/snap_cameras.py --selftest"

echo "→ Подготовка дорог из pbf (osmium) + snap по живой базе…"
ssh "$HOST" "PBF_ARG='$PBF_ARG' BASE_DIR='$BASE_DIR' bash -s" <<'REMOTE'
set -euo pipefail
cd "$BASE_DIR"

# 1) Найти OSM pbf: аргумент → частые пути → поиск.
PBF="$PBF_ARG"
if [ -z "$PBF" ]; then
  for p in /opt/radarmap/osrm/*.osm.pbf /opt/osrm/*.osm.pbf \
           /opt/radarmap/*.osm.pbf ./*.osm.pbf; do
    [ -f "$p" ] && PBF="$p" && break
  done
fi
if [ -z "$PBF" ] || [ ! -f "$PBF" ]; then
  echo "!! Не найден OSM pbf. Укажи путь: bash snap_cameras.sh /путь/uzbekistan.osm.pbf" >&2
  echo "   (тот же pbf, из которого собирали OSRM)" >&2
  exit 1
fi
echo "   pbf: $PBF"

# 2) osmium: только дороги (highway) с геометрией и тегами имён → GeoJSON-seq.
command -v osmium >/dev/null || { echo "!! нет osmium-tool: apt-get install -y osmium-tool" >&2; exit 1; }
osmium tags-filter "$PBF" w/highway -o roads.osm.pbf --overwrite
osmium export roads.osm.pbf -f geojsonseq --geometry-types=linestring \
    -o roads.geojsonl --overwrite
echo "   дорог: $(wc -l < roads.geojsonl) линий"

# 3) Snap по живой базе (её НЕ меняем).
python3 snap_cameras.py --roads roads.geojsonl \
    --in cameras.json --out cameras.snapped.json \
    --report snap_report.csv --moves snap_moves.geojson

echo
echo "Топ переносов (id, метры, причина, адрес):"
head -13 snap_report.csv
REMOTE

echo
echo "✓ Готово. Рядом с базой лежат (живая база НЕ изменена):"
echo "    cameras.snapped.json · snap_report.csv · snap_moves.geojson"
echo
echo "  1) СНАЧАЛА проверить переносы глазами:"
echo "       scp $HOST:$BASE_DIR/snap_moves.geojson ./ "
echo "       → перетащить на https://geojson.io — каждая линия это старое→новое"
echo "         положение камеры. Убедиться, что никто не прыгнул на чужую дорогу."
echo
echo "  2) Промоутить в прод и раздать по OTA:"
echo "       ssh $HOST \"cd $BASE_DIR && \\"
echo "         cp cameras.json cameras.json.bak.\\\$(date +%Y%m%d%H%M%S) && \\"
echo "         mv cameras.snapped.json cameras.json && \\"
echo "         v=\\\$(python3 -c \\\"import json;print(json.load(open('version.json'))['version']+1)\\\") && \\"
echo "         n=\\\$(python3 -c \\\"import json;print(len(json.load(open('cameras.json'))))\\\") && \\"
echo "         echo '{\\\"version\\\": '\\\$v', \\\"count\\\": '\\\$n'}' > version.json\""
echo
echo "  3) Обновить bundled-копию в репозитории (RadarMap/Resources/cameras.json)"
echo "     для новых установок."
