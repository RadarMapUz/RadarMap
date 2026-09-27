#!/bin/bash
# Публикация базовой карты: подпись индекса ключом владельца и выкладка.
# Запускается ТОЛЬКО на машине владельца — ключ живёт там (~/.radarmap/ota_signing.pem).
# Порядок как у дорог: сначала тайлы, шрифты, иконки, стиль, ПОСЛЕДНИМ —
# подписанный индекс: телефон не увидит новой карты, пока не легли все её тайлы.
set -euo pipefail
OUT="${1:-$HOME/RadarMapBuild/omt/publish}"
HOST="${RADARMAP_HOST:-radarmap-vps}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
[ -f "$OUT/omt_index_payload.json" ] || { echo "нет сборки: bash server/omt/build_omt.sh"; exit 1; }
[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

echo "→ подпись индекса"
sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$OUT/omt_index_payload.json" | base64 | tr -d '\n')
payload=$(base64 < "$OUT/omt_index_payload.json" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$payload" "$sig" > "$OUT/omt_index.json"

echo "→ выкладка (тайлы, шрифты, иконки, стиль)"
ssh -o BatchMode=yes "$HOST" "mkdir -p $WEBROOT/omt.new && rm -rf $WEBROOT/omt.new/*"
tar -C "$OUT" -cf - omt glyphs sprite style.json | gzip -1 | \
    ssh -o BatchMode=yes "$HOST" "tar -xzf - -C $WEBROOT/omt.new"
ssh -o BatchMode=yes "$HOST" "
  set -e
  cd $WEBROOT
  rm -rf omt.prev && [ -d omt ] && mv omt omt.prev || true
  mv omt.new/omt omt
  mkdir -p glyphs sprite && cp -R omt.new/glyphs/* glyphs/ && cp -R omt.new/sprite/* sprite/
  cp omt.new/style.json map_style.json && rm -rf omt.new"
echo "→ индекс последним"
scp -q -o BatchMode=yes "$OUT/omt_index.json" "$HOST:$WEBROOT/omt_index.json"
echo "опубликовано: $(python3 -c "import json;print(len(json.load(open('$OUT/omt_index_payload.json'))['tiles']))") тайлов"
