#!/bin/bash
# Публикация подписанного индекса лимитов скорости (speed_limits_index.json).
# Запускает ВЛАДЕЛЕЦ с локальной машины: приватный ключ живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный VPS не может подсунуть
# телефонам свои лимиты — индекс с sha256 и размером каждого файла подписан, а
# файл, не сошедшийся с ним, телефон отбрасывает.
#
#   bash server/publish_limits.sh            # забрать, проверить, подписать, выложить
#   bash server/publish_limits.sh --dry-run  # забрать, проверить и подписать, не выкладывая
#
# КОГДА: после месячного крона лимитов (update_speed_limits.sh, 2-го числа в
# 04:40). Крон обновляет speed_limits*.json для старых сборок; сборки с
# подписью видят новый месяц только после этого запуска, а до него держат
# прошлый подписанный набор — не остаются без лимитов.
#
# ЧТО ПОДПИСЫВАЕТСЯ. Файлы забираются с VPS сюда, проверяются здесь
# (build_limits_index.py) и уезжают обратно ИМЕННО ЭТИ байты — под именами с
# sha в limits/. Подписывать то, что лежит на сервере, «по месту» нельзя: крон
# мог переписать файл между хэшем и копией, и подпись ушла бы под другие байты.
#
# ПОРЯДОК не случаен: сначала файлы, потом индекс. Пока индекс старый,
# телефоны видят согласованный старый набор; новый приезжает последним и
# ссылается на уже лежащие файлы.
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
DIR="$(cd "$(dirname "$0")" && pwd)"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== 1/5: самотест сборщика индекса (локально) ==="
(cd "$DIR" && python3 -m unittest test_build_limits_index test_limit_overrides 2>&1 | tail -3)

echo "=== 2/5: забираю файлы лимитов с VPS ==="
scp -q "$HOST:$WEBROOT/speed_limits.json" "$WORK/speed_limits.json"
scp -q "$HOST:$WEBROOT/speed_limits_v2.json" "$WORK/speed_limits_v2.json"

echo "=== 3/5: ворота и payload (локально) ==="
# Не прошли ворота — дальше не идём: подписанный мусор доехал бы до всех
# телефонов, и отозвать его тихо было бы уже нельзя. Отказ здесь же, если крон
# собрал файл без поправки из limit_overrides.json (сверка с файлом из репо).
python3 "$DIR/build_limits_index.py" \
    --v1 "$WORK/speed_limits.json" --v2 "$WORK/speed_limits_v2.json" \
    --overrides "$DIR/limit_overrides.json" \
    --out "$WORK/stage"

echo "=== 4/5: подпись локально ==="
# Тот же конверт, что у дорог, пульта и правок: base64 ТОЧНЫХ байтов payload
# плюс подпись Ed25519 под ними (SignedPayload в приложении).
sign_index() {
    local payload="$1" out="$2"
    local sig payload_b64
    sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$payload" | base64 | tr -d '\n')
    payload_b64=$(base64 < "$payload" | tr -d '\n')
    printf '{"payload": "%s", "sig": "%s"}\n' "$payload_b64" "$sig" > "$out"
    # Самопроверка: подпись обязана сойтись здесь, а не «у пользователей».
    openssl pkeyutl -verify -pubin \
        -inkey <(openssl pkey -in "$KEY" -pubout) \
        -rawin -in "$payload" \
        -sigfile <(printf '%s' "$sig" | base64 -d) >/dev/null \
        || { echo "подпись не сошлась локально ($payload) — не публикую"; exit 1; }
}
sign_index "$WORK/stage/index_payload.json" "$WORK/speed_limits_index.json"

# Имена и хэши — из payload, который только что подписан: другого источника
# правды о наборе нет.
files_of() {
    python3 -c 'import json,sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f["sha256"] + "  " + f["name"])' "$1"
}
files_of "$WORK/stage/index_payload.json" > "$WORK/manifest.txt"
echo "индекс подписан:"
sed 's/^/    /' "$WORK/manifest.txt"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: проверено и подписано, не выкладываю"
    exit 0
fi

echo "=== 5/5: файлы — первыми, индекс — последним ==="
# Какие файлы ссылается действующий индекс — их не трогаем при уборке: телефон,
# взявший старый индекс минуту назад, ещё качает по нему.
ssh "$HOST" "cat '$WEBROOT/speed_limits_index.json' 2>/dev/null" > "$WORK/live_envelope.json" || true
python3 - "$WORK/live_envelope.json" > "$WORK/live_names.txt" <<'PYLIVE' || true
import base64, json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.loads(base64.b64decode(json.load(handle)["payload"]))
    for entry in payload["files"]:
        print(entry["name"])
except Exception:
    pass   # индекса ещё нет или он битый — беречь нечего
PYLIVE

ssh "$HOST" "mkdir -p '$WEBROOT/limits'"
while read -r _sha name; do
    # Через .tmp и mv: по этому адресу никто не должен увидеть полфайла.
    scp -q "$WORK/stage/$name" "$HOST:$WEBROOT/$name.tmp"
    # .gz рядом — обязательно и тоже атомарно. nginx раздаёт каталог с
    # gzip_static on и на Accept-Encoding: gzip (URLSession шлёт его всегда)
    # отдаёт готовый .gz, не глядя на сам файл: устаревший .gz уже стоил
    # телефонам месяца старых лимитов (см. extract_speed_limits.write_published).
    # ssh -n: без него ssh съедает stdin цикла, и после первого файла цикл
    # молча кончается — второй файл не выкладывается, а проверка ниже это
    # поймает уже как «на сервере не те байты».
    ssh -n "$HOST" "set -e; cd '$WEBROOT'; mv '$name.tmp' '$name'; \
        gzip -9 -n -c '$name' > '$name.gz.tmp'; mv '$name.gz.tmp' '$name.gz'"
done < "$WORK/manifest.txt"

# Проверка на сервере: лежат ли там ровно подписанные байты — и в обычной
# отдаче, и в сжатой. Не сошлось — индекс не выкладываем вовсе.
ssh "$HOST" "cd '$WEBROOT' && sha256sum --quiet -c -" < "$WORK/manifest.txt" \
    || { echo "на сервере не те байты — индекс НЕ выложен"; exit 1; }
while read -r _sha name; do
    ssh -n "$HOST" "cd '$WEBROOT' && gzip -dc '$name.gz' | cmp -s - '$name'" \
        || { echo "$name.gz расходится с файлом — индекс НЕ выложен"; exit 1; }
done < "$WORK/manifest.txt"

scp -q "$WORK/speed_limits_index.json" "$HOST:$WEBROOT/speed_limits_index.json.tmp"
ssh "$HOST" "mv '$WEBROOT/speed_limits_index.json.tmp' '$WEBROOT/speed_limits_index.json'"
echo "    индекс выложен: $WEBROOT/speed_limits_index.json"

# Уборка limits/: оставляем файлы нового и предыдущего индекса, остальное —
# прошлые месяцы, которые никто больше не запросит.
{ awk '{print $2}' "$WORK/manifest.txt"; cat "$WORK/live_names.txt"; } \
    | sed 's#^limits/##' | sort -u > "$WORK/keep.txt"
ssh "$HOST" "cd '$WEBROOT/limits' || exit 0
    keep=\$(cat)
    for f in speed_limits*.json speed_limits*.json.gz; do
        [ -e \"\$f\" ] || continue
        printf '%s\n' \"\$keep\" | grep -qxF \"\${f%.gz}\" && continue
        rm -f -- \"\$f\" && echo \"    убран \$f\"
    done" < "$WORK/keep.txt"

echo "готово. Телефоны подхватят при недельной проверке, свежая установка — сразу."
echo "Проверка: /status в панели, строка «Лимиты скорости» — «подпись: подписаны»."
