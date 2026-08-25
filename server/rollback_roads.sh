#!/bin/bash
# Откат дорожных тайлов на предыдущий опубликованный набор.
#
#   bash server/rollback_roads.sh
#
# Нужен он будет в худший день, поэтому здесь одна команда и никаких вопросов:
# publish_roads.sh перед каждой выкладкой складывает действующий набор в
# roads_prev, отсюда его и возвращаем. Индексы идут ПОСЛЕДНИМИ — как и при
# публикации: пока индекс новый, клиенты видят согласованный новый набор.
set -euo pipefail
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"

ssh "$HOST" "set -e
    [ -d '$WEBROOT/roads_prev' ] || { echo 'нет прошлого набора — откатывать не на что'; exit 1; }
    rm -rf '$WEBROOT/roads.broken'
    mv '$WEBROOT/roads' '$WEBROOT/roads.broken'
    cp -r '$WEBROOT/roads_prev' '$WEBROOT/roads'
    cp '$WEBROOT/roads_prev_index.json' '$WEBROOT/roads_index.json'
    cp '$WEBROOT/roads_prev_index_v2.json' '$WEBROOT/roads_index_v2.json'
    echo 'откат выполнен; сломанный набор оставлен в roads.broken'"
echo "телефоны вернутся на прежние дороги при ближайшей проверке индекса"
