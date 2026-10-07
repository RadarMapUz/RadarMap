#!/bin/bash
# Выпуск тайлов по версии: /radarmap/v/<N>/{mvt,omt,idx} + подписанный корень.
#
#   bash server/publish_tileset.sh            # выпустить из опубликованного
#   bash server/publish_tileset.sh --dry-run  # собрать и подписать, не выкладывая
#
# Запускает ВЛАДЕЛЕЦ с мака, ПОСЛЕ publish_roads.sh и publish_omt.sh: выпуск
# ничего не собирает, он замораживает то, что уже опубликовано и подписано.
# Источник правды — подписанные mvt_index.json и omt_index.json с сервера,
# проверенные здесь открытым ключом: корзины не могут разойтись с тайлами.
#
# Зачем (docs/plan_map_offline.md §2.2):
#  - адрес тайла с версией не меняет содержимого никогда, и nginx отдаёт его с
#    кэшем на год (`immutable`) — телефон перестаёт перекачивать тайлы каждые
#    5 минут, а новая публикация не делает дыр: у неё другие адреса;
#  - индекс корзинами по клетке z10 (16–55 КБ своего района) вместо 50 МБ
#    на страну.
#
# Тайлы выпуска — жёсткие ссылки на опубликованные (cp -al): ноль лишнего
# места. Это безопасно, потому что публикации НЕ переписывают файлы на месте —
# они собирают новый каталог и переименовывают его поверх (mvt.new → mvt), и
# старые inode остаются за выпуском нетронутыми.
#
# Старые адреса (/radarmap/mvt/, /radarmap/omt/) не трогаются: приложения,
# которые уже у людей, продолжают работать как работали.
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-radarmap-vps}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
KEEP="${RADARMAP_TILESET_KEEP:-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl pkey -in "$KEY" -pubout -out "$WORK/pub.pem" 2>/dev/null

# Номер выпуска — время до минуты: растёт сам, и по нему видно, когда выпущено.
VERSION="$(date -u +%y%m%d%H%M)"
echo "=== выпуск v$VERSION ==="

# --- 1. Подписанные индексы с сервера, проверка открытым ключом ---
open_signed() {   # $1 — имя на сервере, $2 — куда положить полезную нагрузку
    scp -q "$HOST:$WEBROOT/$1" "$WORK/$1"
    python3 - "$WORK/$1" "$2" "$WORK/$1.sig" <<'EOF'
import base64, json, sys
envelope = json.load(open(sys.argv[1]))
open(sys.argv[2], "wb").write(base64.b64decode(envelope["payload"]))
open(sys.argv[3], "wb").write(base64.b64decode(envelope["sig"]))
EOF
    openssl pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin \
        -in "$2" -sigfile "$WORK/$1.sig" >/dev/null \
        || { echo "подпись $1 не сошлась — выпуск остановлен"; exit 1; }
    echo "    $1: подпись верна"
}
open_signed mvt_index.json "$WORK/mvt_payload.json"
open_signed omt_index.json "$WORK/omt_payload.json"

# --- 2. Корзины и корень ---
python3 "$HERE/tile_buckets.py" "$VERSION" "$WORK/out" \
    "mvt=$WORK/mvt_payload.json:mvt:mvt" "omt=$WORK/omt_payload.json:omt:pbf"

sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/out/tiles_root_payload.json" | base64 | tr -d '\n')
payload=$(base64 < "$WORK/out/tiles_root_payload.json" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$payload" "$sig" > "$WORK/tiles_root.json"
echo "    корень подписан: $(wc -c < "$WORK/tiles_root.json" | tr -d ' ') байт"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: на сервер ничего не выкладывалось"
    exit 0
fi

# --- 3. Тайлы выпуска: жёсткие ссылки на опубликованное ---
# Самопроверка выборкой: тайл на диске обязан совпасть с подписанным sha.
# Расхождение значит, что между скачиванием индекса и снимком прошла другая
# публикация, — тогда выпуск не выкладывается вовсе.
python3 - "$WORK/mvt_payload.json" "$WORK/omt_payload.json" > "$WORK/sample.txt" <<'EOF'
import json, random, sys
rng = random.Random(0)
for path, folder, ext in ((sys.argv[1], "mvt", "mvt"), (sys.argv[2], "omt", "pbf")):
    tiles = json.load(open(path))["tiles"]
    for key in rng.sample(sorted(tiles), 40):
        meta = tiles[key]
        print(f"{meta['sha256'] if isinstance(meta, dict) else meta}  {folder}/{key}.{ext}")
EOF
scp -q "$WORK/sample.txt" "$HOST:/tmp/radarmap_tileset_sample.txt"
ssh "$HOST" "set -e; D='$WEBROOT/v/$VERSION'; rm -rf \"\$D.new\"; mkdir -p \"\$D.new\"; \
    cp -al '$WEBROOT/mvt' \"\$D.new/mvt\"; cp -al '$WEBROOT/omt' \"\$D.new/omt\"; \
    cd \"\$D.new\" && sha256sum --quiet -c /tmp/radarmap_tileset_sample.txt \
      || { echo 'выборка тайлов не сошлась с подписанным индексом — выпуск остановлен'; rm -rf \"\$D.new\"; exit 1; }; \
    echo '    тайлы выпуска на месте, выборка 80/80 сошлась'"

# --- 4. Корзины ---
COPYFILE_DISABLE=1 tar --no-xattrs -C "$WORK/out" -czf - idx | \
    ssh "$HOST" "set -e; D='$WEBROOT/v/$VERSION'; tar -xzf - -C \"\$D.new\"; \
        find \"\$D.new/idx\" -name '*.bin' | wc -l | xargs echo '    корзин:'; \
        mv \"\$D.new\" \"\$D\""

# --- 5. Корень — ПОСЛЕДНИМ: телефон не увидит выпуска, пока не легло всё ---
scp -q "$WORK/tiles_root.json" "$HOST:$WEBROOT/tiles_root.json.new"
ssh "$HOST" "mv '$WEBROOT/tiles_root.json.new' '$WEBROOT/tiles_root.json'"
echo "    tiles_root.json выложен"

# --- 6. Старые выпуски: держим $KEEP последних ---
# Телефон, взявший прошлый корень минуту назад, ещё качает по его адресам.
ssh "$HOST" "cd '$WEBROOT/v' && ls -1 | grep -E '^[0-9]+\$' | sort -n | head -n -$KEEP | xargs -r rm -rf; \
    echo \"    выпуски на сервере: \$(ls -1 | grep -E '^[0-9]+\$' | tr '\n' ' ')\""
echo "готово: v$VERSION"
