#!/bin/bash
# Ежемесячное обновление лимитов скорости (RadarMap).
#
# ОТДЕЛЬНО ОТ OSRM, И ЭТО ГЛАВНОЕ. Раньше лимиты обновлялись последней строкой
# update_osrm.sh, а тот пересобирает дорожный граф в докере — на сервере с 1.9 ГБ
# памяти это не проходит. Крон выключили 19.07.2026, и лимиты замерли вместе с
# графом на выгрузке от 15 июля, хотя им граф не нужен вовсе: 21 секунда работы
# и 567 МБ пика (замерено 01.09.2026).
#
# Идемпотентно и безопасно: при любой ошибке старый файл продолжает работать —
# сначала ворота (extract_speed_limits.py), и только потом замена по os.replace.
set -e

DIR=/opt/radarmap/osrm
PBF="$DIR/uzbekistan-latest.osm.pbf"
mkdir -p "$DIR"

echo "$(date -Is) качаем выгрузку OSM"
wget -q -O "$DIR/uz-new.osm.pbf" https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf

# Защита от битой/пустой выгрузки: страна весит больше ста мегабайт, и всё,
# что заметно меньше, — это оборванная закачка, а не «в OSM стало меньше дорог».
SIZE=$(stat -c%s "$DIR/uz-new.osm.pbf")
if [ "$SIZE" -lt 50000000 ]; then
    rm -f "$DIR/uz-new.osm.pbf"
    echo "выгрузка всего $SIZE байт — отменяем, старый файл цел"
    exit 1
fi

mv "$DIR/uz-new.osm.pbf" "$PBF"
echo "$(date -Is) выгрузка $((SIZE / 1024 / 1024)) МБ, считаем лимиты"
python3 /opt/radarmap/api/extract_speed_limits.py
echo "$(date -Is) готово"
