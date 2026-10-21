#!/bin/bash
# Публикация «пульта» — подписанного config.json, которым можно чинить без
# релиза то, что зависит от сервера. Запускает ВЛАДЕЛЕЦ с локальной машины:
# приватный ключ живёт только здесь (~/.radarmap/ota_signing.pem), поэтому
# взломанный VPS не может ни выключить функции, ни показать своё объявление.
#
#   bash server/publish_config.sh '{"features": {"routing": false}}'
#   bash server/publish_config.sh path/to/config.json
#   bash server/publish_config.sh --reset          # вернуть всё к дефолтам сборки
#   bash server/publish_config.sh --dry-run '{…}'  # собрать и проверить, не заливая
#
# Что можно прислать (всё опционально, отсутствующее = дефолт сборки):
#   minVersion          "1.2"      — ниже просим обновиться
#   message             {title, body, until}  — объявление на карте (until: unix-время)
#   mobilePollInterval  180        — интервал опроса радаров, 60…3600
#   features            {routing, mobileReports, metrics, traffic, etaShare, roadWeather,
#                        laneOverlay}
#                                  — что временно выключено (RemoteConfig.Features)
#
# Оповещения о камерах отсюда НЕ управляются и управляться не будут: база лежит
# на телефоне, и предупреждение за рулём обязано работать, даже когда сервера
# нет вовсе (см. RadarMap/Models/RemoteConfig.swift).
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi

INPUT="${1:?нужен JSON, путь к файлу или --reset}"
if [ "$INPUT" = "--reset" ]; then
    RAW='{}'
elif [ -f "$INPUT" ]; then
    RAW="$(cat "$INPUT")"
else
    RAW="$INPUT"
fi

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Проверка формата ДО подписи: подписанный мусор доедет до всех телефонов и
# будет молча отброшен ими как невалидный — то есть пульт окажется мёртвым
# ровно в тот момент, когда он понадобился.
# JSON едет ФАЙЛОМ, а делимитер heredoc — в кавычках. Раньше стояло `<<PY`
# без кавычек и `json.loads(r'''$RAW''')`: bash разворачивал $RAW внутри тела
# скрипта ДО запуска Python, поэтому присланный «конфиг», содержащий тройную
# кавычку и дальше произвольный код, исполнялся бы прямо здесь — на машине,
# где лежит единственный приватный ключ, подписывающий базу камер, пульт,
# правки модератора, хотспоты и тайлы дорог. Заодно чинится честный случай:
# объявление с тройной кавычкой в тексте больше не ломает разбор.
printf '%s' "$RAW" > "$WORK/config.raw"
python3 - "$WORK/config.payload" "$WORK/config.raw" <<'PY'
import json, sys
try:
    with open(sys.argv[2], encoding="utf-8") as source:
        raw = json.loads(source.read())
except (OSError, ValueError) as error:
    sys.exit(f"это не JSON: {error}")
if not isinstance(raw, dict):
    sys.exit("конфиг должен быть объектом JSON")

ALLOWED = {"minVersion", "message", "mobilePollInterval", "features"}
unknown = set(raw) - ALLOWED
if unknown:
    sys.exit(f"неизвестные ключи: {', '.join(sorted(unknown))} (приложение их проигнорирует)")

features = raw.get("features") or {}
if not isinstance(features, dict):
    sys.exit("features должен быть объектом")
# Тот же список, что RemoteConfig.Features в приложении: traffic и etaShare
# приложение понимало, а здесь их отвергало — рубильник пробок не публиковался.
unknown = set(features) - {"routing", "mobileReports", "metrics", "traffic", "etaShare", "roadWeather",
                           "laneOverlay"}
if unknown:
    sys.exit(f"неизвестные features: {', '.join(sorted(unknown))}")
for name, value in features.items():
    if not isinstance(value, bool):
        sys.exit(f"features.{name} должен быть true/false")

interval = raw.get("mobilePollInterval")
if interval is not None and not (60 <= interval <= 3600):
    sys.exit("mobilePollInterval вне 60…3600 — приложение возьмёт дефолт")

message = raw.get("message")
if message is not None:
    if not isinstance(message, dict) or not message.get("title"):
        sys.exit("message должен быть объектом с непустым title")
    unknown = set(message) - {"title", "body", "until"}
    if unknown:
        sys.exit(f"неизвестные поля message: {', '.join(sorted(unknown))}")

# Байты, по которым считается подпись, — ровно эти. Приложение проверяет
# подпись до разбора JSON, поэтому важна не «та же структура», а те же байты.
open(sys.argv[1], "wb").write(json.dumps(raw, ensure_ascii=False,
                                        separators=(",", ":")).encode())
print("конфиг принят:", json.dumps(raw, ensure_ascii=False))
PY

SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/config.payload" | base64 | tr -d '\n')
PAYLOAD=$(base64 < "$WORK/config.payload" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$PAYLOAD" "$SIG" > "$WORK/config.json"

# Самопроверка: подпись обязана сойтись здесь, а не «у пользователей».
openssl pkeyutl -verify -pubin \
    -inkey <(openssl pkey -in "$KEY" -pubout) \
    -rawin -in "$WORK/config.payload" \
    -sigfile <(printf '%s' "$SIG" | base64 -d) >/dev/null \
    || { echo "подпись не сошлась локально — не публикую"; exit 1; }

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: файл собран и проверен, не заливаю"
    cat "$WORK/config.json"
    exit 0
fi

scp "$WORK/config.json" "$HOST:$WEBROOT/config.json"
echo "пульт опубликован ($(wc -c < "$WORK/config.json") байт)"
echo "приложения подхватят в течение 6 часов, на холодном старте — сразу"
