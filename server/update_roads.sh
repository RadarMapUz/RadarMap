#!/bin/bash
# Еженедельная подготовка дорожных тайлов. Ставится на VPS в cron:
#
#   17 4 * * 0 /opt/radarmap/update_roads.sh >> /var/log/radarmap-roads.log 2>&1
#
# ЭТОТ СКРИПТ НИЧЕГО НЕ ПУБЛИКУЕТ И НЕ УМЕЕТ. Он готовит кандидата и отчёт,
# а выкладывает их publish_roads.sh с машины владельца — там живёт ключ
# подписи, и на VPS его нет намеренно: взломанный сервер не должен уметь
# подсунуть телефонам свою геометрию дорог.
#
# До этого скрипта шага «обновить экстракт из свежего OSM» в проекте не было
# вовсе: дороги ехали на хвосте у снапа камер и обновлялись, только когда
# кто-то вспоминал запустить снап руками.
set -euo pipefail

WORK="${RADARMAP_WORK:-/opt/radarmap/work}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
PBF_URL="${RADARMAP_PBF_URL:-https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf}"
CANDIDATE="$WORK/roads_tiles_candidate"

cd "$WORK"
echo "=== $(date -Is) обновление дорог ==="

echo "--- 1/4: свежий OSM"
curl -sSfL --max-time 900 -o uzbekistan-new.osm.pbf "$PBF_URL"
curl -sSfL --max-time 60 -o uzbekistan-new.osm.pbf.md5 "$PBF_URL.md5"
# Контрольная сумма Geofabrik — первая защита: оборванная закачка не должна
# становиться новой картой страны.
(cd "$WORK" && sed "s#uzbekistan-latest.osm.pbf#uzbekistan-new.osm.pbf#" \
    uzbekistan-new.osm.pbf.md5 | md5sum -c -)

# Вторая защита — размер. Файл вправе расти и слегка ужиматься, но не вдвое:
# такое означает, что регион вырезали не тот или зеркало отдало огрызок.
NEW_SIZE=$(stat -c %s uzbekistan-new.osm.pbf)
if [ -f uzbekistan.osm.pbf ]; then
    OLD_SIZE=$(stat -c %s uzbekistan.osm.pbf)
    if [ "$NEW_SIZE" -lt $((OLD_SIZE * 80 / 100)) ]; then
        echo "СТОП:новый pbf $NEW_SIZE байт против прежних $OLD_SIZE — меньше 80%"
        exit 1
    fi
fi
mv uzbekistan-new.osm.pbf uzbekistan.osm.pbf

echo "--- 2/4: экстракт дорог и местности"
# Свой шаг, а не хвост снапа камер: дороги для схемы обновляются по своему
# расписанию и не зависят от того, гоняли ли снап.
osmium tags-filter uzbekistan.osm.pbf w/highway -o roads.osm.pbf --overwrite
osmium export roads.osm.pbf -f geojsonseq --geometry-types=linestring \
    -o roads.geojsonl --overwrite
echo "    дорог в экстракте: $(wc -l < roads.geojsonl)"

# Вода, зелень и рельсы приезжали в этом же .pbf всё это время и
# выбрасывались фильтром по highway. На тёмной схеме вода — единственный
# не-серый цвет, и именно она отличает местность от чертежа. Отдельной
# закачки не нужно: файл уже здесь.
osmium tags-filter uzbekistan.osm.pbf \
    wa/natural=water,wood wa/landuse=reservoir,forest,grass,cemetery \
    wa/leisure=park w/waterway=river,canal w/railway=rail \
    -o areas.osm.pbf --overwrite
osmium export areas.osm.pbf -f geojsonseq \
    --geometry-types=linestring,polygon -o areas.geojsonl --overwrite
echo "    местности в экстракте: $(wc -l < areas.geojsonl)"

# Точечные объекты: светофоры, стоп-знаки, лежачие полицейские, пешеходные
# переходы. Это УЗЛЫ, а не линии, поэтому фильтр по n/ и экспорт точками —
# линейный экспорт их просто не видит. В Ташкенте одних светофоров 1 899, и все
# они уже лежат в этом же .pbf.
#
# Переходы берём УЗЛАМИ, а не линиями footway=crossing. Узел лежит ровно на
# оси проезжей части, то есть там, где чертить; линия перехода пересекает её
# и даёт две точки на тротуарах, между которыми ещё надо искать середину.
# Азимут всё равно считается по дороге, а не по линии перехода, — линия не
# добавляет ничего, кроме работы. В центре Ташкента это 809 узлов.
osmium tags-filter uzbekistan.osm.pbf \
    n/highway=traffic_signals,stop,crossing n/traffic_calming \
    -o points.osm.pbf --overwrite
osmium export points.osm.pbf -f geojsonseq --geometry-types=point \
    -o points.geojsonl --overwrite
echo "    точек в экстракте: $(wc -l < points.geojsonl)"

# Правки конструктора. Снимок, а не приращение: сборка накладывает состояние
# целиком, и «отменить правку» значит собрать тайлы без этой строки.
#
# Нет панели — нет правок, и это не ошибка: сборка обязана работать на машине,
# где панели никогда не было. Пустой файл в этом случае и пишем.
EDITS="$WORK/edits.json"
if python3 "$WORK/admin.py" --export-edits > "$EDITS.new" 2>/dev/null; then
    mv "$EDITS.new" "$EDITS"
    echo "    правок панели: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$EDITS")"
else
    rm -f "$EDITS.new"
    echo '{"version":1,"items":[]}' > "$EDITS"
    echo "    панели нет — собираем без правок"
fi

echo "--- 3/4: сборка кандидата"
rm -rf "$CANDIDATE" && mkdir -p "$CANDIDATE"
python3 "$WORK/build_roads.py" --in roads.geojsonl --areas areas.geojsonl \
    --points points.geojsonl --edits "$EDITS" --tiles "$CANDIDATE"

# Самопроверка детерминизма. Недетерминированная сборка меняет sha256 ВСЕХ
# тайлов каждую неделю, и каждый телефон перекачивает свои файлы впустую —
# при том что в дорогах не изменилось ничего.
echo "--- 4/4: детерминизм"
rm -rf "$CANDIDATE.check" && mkdir -p "$CANDIDATE.check"
python3 "$WORK/build_roads.py" --in roads.geojsonl --areas areas.geojsonl \
    --points points.geojsonl --edits "$EDITS" --tiles "$CANDIDATE.check" >/dev/null
if ! diff -rq "$CANDIDATE" "$CANDIDATE.check" >/dev/null; then
    echo "СТОП: две сборки одного экстракта разошлись — сборка недетерминирована"
    exit 1
fi
rm -rf "$CANDIDATE.check"

# Отчёт: то, на что смотрят ворота публикации и человек в телеграме.
python3 - "$CANDIDATE" "$WEBROOT" <<'PY'
import json, os, sys
candidate, webroot = sys.argv[1], sys.argv[2]
def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return {"tiles": {}}
fresh = load(os.path.join(candidate, "index_payload_v2.json"))
live_raw = load(os.path.join(webroot, "roads_index_v2.json"))
# На сервере лежит подписанный конверт; полезная часть внутри.
if "payload" in live_raw:
    import base64
    live = json.loads(base64.b64decode(live_raw["payload"]))
else:
    live = live_raw
report = {
    "built_at": os.popen("date -Is").read().strip(),
    "candidate": {"tiles": len(fresh.get("tiles", {})),
                  "bytes": sum(m["bytes"] for m in fresh.get("tiles", {}).values()),
                  "tileDegrees": fresh.get("tileDegrees")},
    "live": {"tiles": len(live.get("tiles", {})),
             "bytes": sum(m["bytes"] for m in live.get("tiles", {}).values()),
             "tileDegrees": live.get("tileDegrees")},
}
changed = [k for k, m in fresh.get("tiles", {}).items()
           if live.get("tiles", {}).get(k, {}).get("sha256") != m["sha256"]]
report["changed"] = len(changed)
report["changed_top"] = sorted(changed)[:10]
with open(os.path.join(candidate, "roads_report.json"), "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False, indent=1)
print(f"    кандидат: {report['candidate']['tiles']} файлов, "
      f"{report['candidate']['bytes'] / 1e6:.1f} МБ, изменилось {report['changed']}")
PY

echo "=== кандидат готов: $CANDIDATE (публикует владелец) ==="
