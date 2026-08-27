#!/bin/bash
# Выкат дорожного конвейера целиком: панель + сборщик + крон + прогон.
#
#   bash server/rollout.sh          # поставить и прогнать
#   bash server/rollout.sh --dry    # только поставить, без прогона
#
# ПУБЛИКАЦИЮ НЕ ДЕЛАЕТ, и это граница по существу, а не по лени: тайлы уезжают
# на телефоны подписанными, ключ живёт только на машине владельца, и решение
# «эту геометрию видят все» остаётся отдельным осознанным шагом.
#
#   bash server/publish_roads.sh --auto
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="--run"
for arg in "$@"; do [ "$arg" = "--dry" ] && RUN=""; done

echo "=== 1/2: панель (editor.js, map_edits.py, admin.py) ==="
# Только панель: юниты разведены намеренно, и выкатывать api.py заодно значит
# выкатывать всё, что в нём накопилось незапланированного.
RADARMAP_DEPLOY_ONLY=panel bash "$DIR/deploy_api.sh"

echo
echo "=== 2/2: сборщик тайлов, недельный скрипт, крон ==="
bash "$DIR/install_roads_pipeline.sh" $RUN

echo
echo "Поставлено. Публикует владелец: bash server/publish_roads.sh --auto"
