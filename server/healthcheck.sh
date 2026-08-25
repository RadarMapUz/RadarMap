#!/bin/bash
# Сторож RadarMap: раз в 5 минут проверяет, что сервис жив, и пишет владельцу,
# когда это перестаёт быть правдой. Без него первым «мониторингом» становятся
# отзывы в App Store: упавший ночью api никто не заметит до утра.
#
# Ставится на VPS в cron:
#   */5 * * * * RADARMAP_TG_TOKEN=… RADARMAP_TG_CHAT=… /opt/radarmap/healthcheck.sh
#
# Уведомление уходит ТОЛЬКО на смену состояния (было хорошо — стало плохо и
# наоборот). Сообщение каждые 5 минут читать перестают на второй день, и тогда
# сторож бесполезен ровно в тот раз, когда он нужен.
set -uo pipefail

BASE="${RADARMAP_BASE:-http://127.0.0.1:8090}"
STATE="${RADARMAP_HEALTH_STATE:-/var/tmp/radarmap_health}"
DISK_MIN_MB="${RADARMAP_DISK_MIN_MB:-500}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"

problems=()

# 1. API. Проверяем не только код ответа, но и тело: nginx отдаёт 200 и на
#    заглушку, а нам важно, что жив именно процесс за ним.
if ! curl -sf --max-time 10 "$BASE/api/health" | grep -q '"ok"'; then
    problems+=("api не отвечает (/api/health)")
fi

# 2. OSRM. Маршрут внутри Ташкента — самый дешёвый честный запрос: сервис может
#    подняться, но не загрузить граф, и тогда health-порт есть, а маршрутов нет.
if ! curl -sf --max-time 15 \
     "$BASE/osrm/route/v1/driving/69.24,41.31;69.28,41.33?overview=false" \
     | grep -q '"code":"Ok"'; then
    problems+=("osrm не строит маршруты")
fi

# 3. Раздача базы камер: файл на месте и манифест читается.
if ! curl -sf --max-time 10 "$BASE/version.json" | grep -q '"sig"'; then
    problems+=("version.json недоступен — OTA не работает")
fi

# 4. Диск. sqlite при заполненном разделе не пишет, а api это увидит только как
#    ошибки на каждый POST.
free_mb=$(df -Pm "$WEBROOT" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${free_mb:-}" ] && [ "$free_mb" -lt "$DISK_MIN_MB" ]; then
    problems+=("на диске осталось ${free_mb} МБ")
fi

# 5. Свежесть бэкапа: backup_db.sh мог тихо перестать работать месяц назад.
# Дороги обновляются раз в неделю. Три недели без свежего индекса означают,
# что цикл встал — крон не отработал или ворота публикации не пускают. Молча
# устаревающая карта хуже отсутствующей: по ней ездят, считая её свежей.
stale_roads=$(find /opt/radarmap/www -maxdepth 1 -name 'roads_index*.json' -mtime -21 2>/dev/null | head -1)
if [ -z "$stale_roads" ]; then
    problems+=("дорожный индекс не обновлялся больше трёх недель")
fi

newest_backup=$(find /opt/radarmap/backups -name 'reports*.db*' -mtime -2 2>/dev/null | head -1)
if [ -d /opt/radarmap/backups ] && [ -z "$newest_backup" ]; then
    problems+=("бэкапа reports.db нет за последние двое суток")
fi

# Токен и chat_id — из общего конфига (там же хэш пароля панели и ключ карт).
# В crontab их класть нельзя: crontab читается любым процессом владельца, а
# менять секрет пришлось бы в двух местах.
CONF="${RADARMAP_ADMIN_CONF:-/opt/radarmap/admin.conf}"
if [ -f "$CONF" ]; then
    [ -z "${RADARMAP_TG_TOKEN:-}" ] && \
        RADARMAP_TG_TOKEN=$(grep -E '^tg_token=' "$CONF" | cut -d= -f2-)
    [ -z "${RADARMAP_TG_CHAT:-}" ] && \
        RADARMAP_TG_CHAT=$(grep -E '^tg_chat=' "$CONF" | cut -d= -f2-)
    export RADARMAP_TG_TOKEN RADARMAP_TG_CHAT
fi

notify() {
    local text="$1"
    if [ -n "${RADARMAP_TG_TOKEN:-}" ] && [ -n "${RADARMAP_TG_CHAT:-}" ]; then
        curl -sf --max-time 10 -X POST \
            "https://api.telegram.org/bot${RADARMAP_TG_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${RADARMAP_TG_CHAT}" \
            --data-urlencode "text=$text" >/dev/null || true
    fi
    logger -t radarmap-health "$text" 2>/dev/null || true
    echo "$text"
}

was_bad=0
[ -f "$STATE" ] && was_bad=$(cat "$STATE" 2>/dev/null || echo 0)

if [ ${#problems[@]} -gt 0 ]; then
    echo 1 > "$STATE"
    [ "$was_bad" = "1" ] && exit 1   # уже сообщали, молчим до восстановления
    notify "🔴 RadarMap: $(printf '%s; ' "${problems[@]}")"
    exit 1
fi

echo 0 > "$STATE"
[ "$was_bad" = "1" ] && notify "🟢 RadarMap: всё восстановилось"
exit 0
