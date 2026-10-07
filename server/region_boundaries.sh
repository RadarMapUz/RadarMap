#!/bin/bash
# Границы областей (OSM admin_level=4) для нарезки офлайн-регионов.
#
#   bash server/region_boundaries.sh <выход.geojsonl>
#
# osmium есть только на VPS, и экстракт страны лежит там же — поэтому выборка
# идёт там, во временном каталоге, а сюда приезжает готовый файл (~1 МБ).
# Рабочие данные сервера не трогаются. Полигоны Ферганской области и
# Каракалпакстана в выгрузке Geofabrik не замыкаются — их клетки решает
# build_regions.py рамками (FALLBACK), так и задумано.
set -euo pipefail
OUT="${1:?куда положить geojsonl}"
HOST="${RADARMAP_HOST:-radarmap-vps}"
PBF="${RADARMAP_PBF:-/opt/radarmap/work/uzbekistan.osm.pbf}"
ssh "$HOST" "set -e; T=\$(mktemp -d); trap 'rm -rf \$T' EXIT; \
  osmium tags-filter -O '$PBF' r/admin_level=4 -o \$T/adm4.osm.pbf; \
  osmium export -O \$T/adm4.osm.pbf -f geojsonseq --geometry-types=polygon -o \$T/adm4.geojsonl 2>/dev/null; \
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    f = json.loads(line.lstrip(\"\\x1e\")); p = f[\"properties\"]
    if p.get(\"admin_level\") == \"4\" and p.get(\"ISO3166-2\", \"\").startswith(\"UZ-\"):
        keep = {k: p[k] for k in (\"ISO3166-2\", \"name\", \"name:ru\", \"name:uz\", \"name:en\") if k in p}
        print(json.dumps({\"type\": \"Feature\", \"properties\": keep, \"geometry\": f[\"geometry\"]}, ensure_ascii=False))
' \$T/adm4.geojsonl" > "$OUT"
echo "областей с полигоном: $(wc -l < "$OUT" | tr -d ' ') → $OUT"
