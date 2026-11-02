#!/bin/bash
# Публикация решений модератора: overrides.json — подписанный снимок
# действующих правок поверх базы камер.
#
#   bash server/publish_overrides.sh <версия>
#   bash server/publish_overrides.sh <версия> --dry-run
#   bash server/publish_overrides.sh <версия> --yes     # без вопроса «да» (явно)
#
# Запускает ВЛАДЕЛЕЦ с локальной машины. Панель на VPS ничего не публикует
# сама — и это главное свойство схемы: ключ подписи живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный сервер не может ни скрыть
# камеру у пользователей, ни подсунуть свою. Панель копит решения, публикует
# человек, а приложение проверяет подпись до применения (fail closed).
#
# Но payload собирает панель на VPS, а значит взломанный сервер или ошибка в
# панели доезжают до подписи. Поэтому перед подписью — разница с прошлой
# ПОДПИСАННОЙ публикацией по каждой камере и ввод «да» (overrides_diff.py).
#
# Файл ~2 КБ против мегабайта базы, так что публиковать можно хоть каждый день,
# а откат — это снять правку в панели («Вернуть камеру») и запустить это снова.
set -euo pipefail

VERSION="${1:?номер версии правок (предыдущая +1)}"
# Только цифры: строка уходит внутрь ssh-команды, то есть в шелл на VPS от
# root. `publish_overrides.sh '1; systemctl stop radarmap-api'` исполнял там
# всё после точки с запятой.
[[ "$VERSION" =~ ^[0-9]+$ ]] || { echo "версия правок — только цифры: $VERSION"; exit 1; }
DRY_RUN=0
ASSUME_YES=0
for arg in "${@:2}"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        *) echo "неизвестный ключ: $arg"; exit 1 ;;
    esac
done

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
ADMIN="${RADARMAP_ADMIN:-/opt/radarmap/api/admin.py}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CAMERAS="${RADARMAP_CAMERAS:-$HERE/../RadarMap/Resources/cameras.json}"
# Последний подписанный и выложенный конверт — точка отсчёта для разницы.
# Живёт рядом с ключом: копия на сервере может быть подменена (подпись её
# всё равно проверяется, но своя копия не зависит от VPS вовсе).
LAST="${RADARMAP_OVERRIDES_LAST:-$HOME/.radarmap/overrides_published.json}"

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Забираю решения с сервера…"
ssh "$HOST" "python3 $ADMIN --export $VERSION" > "$WORK/overrides.payload"

# Проверка ДО подписи. Подписанный мусор доехал бы до всех телефонов и был
# молча отброшен ими — то есть решения модератора не применились бы, а понять
# это по факту было бы неоткуда. Пределы — те же, что у приложения, разница —
# против прошлой публикации, подпись которой сошлась ключом приложения.
PREV_ARGS=()
[ -f "$LAST" ] && PREV_ARGS+=(--prev "$LAST")
if scp -q "$HOST:$WEBROOT/overrides.json" "$WORK/published.json" 2>/dev/null; then
    PREV_ARGS+=(--prev "$WORK/published.json")
fi
python3 "$HERE/overrides_diff.py" --new "$WORK/overrides.payload" \
    --cameras "$CAMERAS" "${PREV_ARGS[@]+"${PREV_ARGS[@]}"}" \
    || { echo "не подписываю: исправьте решения в панели"; exit 1; }

if [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
    # Только с живого терминала: из пайпа или cron «да» не придёт.
    [ -t 0 ] || { echo "нет терминала для подтверждения — запустите вручную или с --yes"; exit 1; }
    read -r -p "Подписать и опубликовать v$VERSION? Введите «да»: " ANSWER
    [ "$ANSWER" = "да" ] || { echo "не подтверждено — ничего не подписано"; exit 1; }
fi

SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/overrides.payload" | base64 | tr -d '\n')
PAYLOAD=$(base64 < "$WORK/overrides.payload" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$PAYLOAD" "$SIG" > "$WORK/overrides.json"

openssl pkeyutl -verify -pubin \
    -inkey <(openssl pkey -in "$KEY" -pubout) \
    -rawin -in "$WORK/overrides.payload" \
    -sigfile <(printf '%s' "$SIG" | base64 -d) >/dev/null \
    || { echo "подпись не сошлась локально — не публикую"; exit 1; }

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: собрано и проверено, не заливаю"
    cat "$WORK/overrides.payload"
    exit 0
fi

scp "$WORK/overrides.json" "$HOST:$WEBROOT/overrides.json"
mkdir -p "$(dirname "$LAST")"
cp "$WORK/overrides.json" "$LAST"
ssh "$HOST" "python3 $ADMIN --mark-published $VERSION"
echo "опубликовано: v$VERSION ($(wc -c < "$WORK/overrides.json") байт)"
echo "приложения подхватят в течение 3 часов, на холодном старте — сразу"
