#!/bin/bash
# Публикация офлайн-регионов: /radarmap/regions/<N>/*.pmtiles + подписанный
# /radarmap/regions.json. docs/plan_map_offline.md §2.3.
#
#   bash server/region_boundaries.sh /tmp/adm4.geojsonl            # границы
#   python3 server/build_regions.py --mvt ~/RadarMapBuild/cand/mvt \
#       --omt ~/RadarMapBuild/omt/uz.mbtiles --adm4 /tmp/adm4.geojsonl \
#       --out ~/RadarMapBuild/regions --version <N>                 # нарезка
#   bash server/publish_regions.sh ~/RadarMapBuild/regions          # выкладка
#
# Запускает ВЛАДЕЛЕЦ с мака: ключ подписи живёт только здесь. Телефон проверит
# sha256 всего файла против подписанного regions.json до того, как движок
# увидит хоть байт, — подменить регион на сервере нельзя, не подделав подпись.
#
# Порядок: файлы → проверка sha на сервере → каталог версии → regions.json
# ПОСЛЕДНИМ. Пока лежит старый regions.json, телефоны видят старый набор
# целиком. Держим два последних набора: телефон, начавший качать по прошлому
# списку, докачает.
set -euo pipefail

OUT="${1:?каталог с нарезкой (build_regions.py --out)}"
KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-radarmap-vps}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
KEEP="${RADARMAP_REGIONS_KEEP:-2}"

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }
PAYLOAD="$OUT/regions_payload.json"
[ -f "$PAYLOAD" ] || { echo "нет $PAYLOAD — сначала build_regions.py"; exit 1; }
VERSION=$(python3 -c "import json;print(json.load(open('$PAYLOAD'))['version'])")
echo "=== регионы v$VERSION ==="

# Самопроверка до подписи: каждый файл из списка есть и сходится по sha.
python3 - "$OUT" "$PAYLOAD" <<'EOF'
import hashlib, json, os, sys
out, payload = sys.argv[1], json.load(open(sys.argv[2]))
total = 0
for region in payload["regions"]:
    for kind, meta in region["files"].items():
        path = os.path.join(out, meta["file"])
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if digest != meta["sha256"] or os.path.getsize(path) != meta["bytes"]:
            sys.exit(f"{meta['file']}: не сходится с regions_payload.json — не публикую")
        total += meta["bytes"]
print(f"    файлов сверено, всего {total / 1e6:.0f} МБ")
EOF

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$PAYLOAD" | base64 | tr -d '\n')
payload=$(base64 < "$PAYLOAD" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$payload" "$sig" > "$WORK/regions.json"
# Подпись проверяется тем же открытым ключом, что вшит в приложение: битый
# конверт не должен уехать на сервер даже на минуту.
openssl pkey -in "$KEY" -pubout -out "$WORK/pub.pem" 2>/dev/null
printf '%s' "$sig" | base64 -d > "$WORK/sig.bin"
openssl pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin -in "$PAYLOAD" \
    -sigfile "$WORK/sig.bin" >/dev/null \
    || { echo "подпись не сошлась локально — не публикую"; exit 1; }
echo "    regions.json подписан и проверен"

DEST="$WEBROOT/regions/$VERSION"
ssh "$HOST" "mkdir -p '$DEST.new'"
# По файлу и с повтором: регион весит до ~50 МБ, а связь до VPS рвётся.
for file in $(python3 -c "import json;[print(f['file']) for r in json.load(open('$PAYLOAD'))['regions'] for f in r['files'].values()]"); do
    want=$(shasum -a 256 "$OUT/$file" | cut -d' ' -f1)
    for attempt in 1 2 3 4; do
        got=$(ssh "$HOST" "sha256sum '$DEST.new/$file' 2>/dev/null | cut -d' ' -f1" || true)
        [ "$got" = "$want" ] && break
        scp -q -o ServerAliveInterval=15 "$OUT/$file" "$HOST:$DEST.new/$file" || sleep 5
    done
    got=$(ssh "$HOST" "sha256sum '$DEST.new/$file' | cut -d' ' -f1")
    [ "$got" = "$want" ] || { echo "$file не дошёл целым — регионы не опубликованы"; exit 1; }
done
ssh "$HOST" "set -e; rm -rf '$DEST'; mv '$DEST.new' '$DEST'; echo \"    на сервере: \$(ls '$DEST' | wc -l) файлов, \$(du -sh '$DEST' | cut -f1)\""

scp -q "$WORK/regions.json" "$HOST:$WEBROOT/regions.json.new"
ssh "$HOST" "mv '$WEBROOT/regions.json.new' '$WEBROOT/regions.json'"
echo "    regions.json выложен"

ssh "$HOST" "cd '$WEBROOT/regions' && ls -1 | grep -E '^[0-9]+\$' | sort -n | head -n -$KEEP | xargs -r rm -rf; \
    echo \"    наборы на сервере: \$(ls -1 | grep -E '^[0-9]+\$' | tr '\n' ' ')\""
echo "готово: регионы v$VERSION"
