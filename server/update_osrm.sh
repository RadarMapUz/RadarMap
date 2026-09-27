#!/bin/bash
# Ежемесячное обновление графа дорог OSRM (RadarMap). Идемпотентно и безопасно:
# при любой ошибке старый граф продолжает работать.
set -e
cd /opt/radarmap/osrm
wget -q -O uz-new.osm.pbf https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf
# защита от битой/пустой выгрузки
[ "$(stat -c%s uz-new.osm.pbf)" -lt 50000000 ] && { rm -f uz-new.osm.pbf; exit 1; }
mv uz-new.osm.pbf uzbekistan-latest.osm.pbf
docker run --rm -v /opt/radarmap/osrm:/data ghcr.io/project-osrm/osrm-backend osrm-extract -p /opt/car.lua -t 2 /data/uzbekistan-latest.osm.pbf
docker run --rm -v /opt/radarmap/osrm:/data ghcr.io/project-osrm/osrm-backend osrm-contract -t 2 /data/uzbekistan-latest.osrm
docker restart radarmap-osrm
python3 /opt/radarmap/api/extract_speed_limits.py
echo "$(date -Is) osrm graph updated"
