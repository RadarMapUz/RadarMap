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
# Панель живёт своим каталогом и туда её кладёт deploy_api.sh. Копия в work
# разъезжалась бы с боевой при первом же выкате панели, а сверка правок
# сравнивала бы очередь со старым кодом.
ADMIN="${RADARMAP_ADMIN:-/opt/radarmap/api/admin.py}"
[ -f "$ADMIN" ] || ADMIN="$WORK/admin.py"

cd "$WORK"

# Один прогон за раз — ЗАМКОМ, а не разглядыванием ps.
#
# Прогон идёт десятки минут, и его запускают из двух мест: крон по
# воскресеньям и владелец руками. Наложиться они не должны: каталог работы
# один, экстракты одни, и вторая сборка писала бы в те же файлы под первой.
#
# Проверка через `ps | grep` для этого не годится, и это проверено на себе:
# строка «update_roads.sh» есть в командной строке самой проверки, поэтому
# она находит саму себя и отвечает «уже работает» даже на мёртвой машине.
# Замок ядра не ошибается и снимается сам, когда процесс умирает, — в том
# числе когда его убивает OOM.
exec 9>/var/lock/radarmap-roads.lock
if ! flock -n 9; then
    echo "=== $(date -Is) прогон уже идёт, второй не запускаем ==="
    exit 0
fi

echo "=== $(date -Is) обновление дорог ==="

echo "--- 1/4: свежий OSM"
# Повторный запуск после сбоя не должен качать страну заново.
#
# Экстракт весит 123 МБ, а зеркало отдаёт его неровно: в один заход это две
# минуты, в другой — десять, и разница решает, доживёт ли закачка до своего
# лимита. Когда сборку убило по памяти, качать те же байты ещё раз незачем —
# на диске лежит ровно тот файл, из которого её и собирали.
#
#   RADARMAP_REUSE_PBF=1 /opt/radarmap/update_roads.sh
#
# Крон эту переменную не ставит и качает всегда: смысл недельного прогона в
# том, что данные свежие.
if [ "${RADARMAP_REUSE_PBF:-0}" = "1" ] && [ -s uzbekistan.osm.pbf ]; then
    echo "    берём лежащий экстракт от $(date -Is -r uzbekistan.osm.pbf)"
else
# Лимит и докачка подобраны по ЗАМЕРУ, а не на глаз.
#
# Прежние пятнадцать минут выглядели щедро и оказались вдвое меньше нужного:
# зеркало отдавало 8,5 МБ из 123 за всё это время — около девяти килобайт в
# секунду. Прогон падал на первом же шаге, уже скачав часть.
#
# Отсюда три правки. Час вместо четверти — ночной сборке спешить некуда.
# --continue-at продолжает с места обрыва, а не начинает сначала. --retry
# переживает разрыв, а не считает его концом света.
#
# Но докачка — только внутри одного прогона. Хвост прошлой недели удаляем:
# иначе --continue-at дописывает к нему последние байты НОВОГО выпуска
# Geofabrik, выходит склейка двух файлов, и md5 падает каждое воскресенье
# (так дороги стояли с 30.08 по 27.09.2026 — четыре прогона подряд).
rm -f uzbekistan-new.osm.pbf uzbekistan-new.osm.pbf.md5
curl -sSfL --max-time 3600 --retry 3 --retry-delay 30 \
     --continue-at - -o uzbekistan-new.osm.pbf "$PBF_URL"
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
fi

echo "--- 2/4: экстракт дорог и местности"
# Свой шаг, а не хвост снапа камер: дороги для схемы обновляются по своему
# расписанию и не зависят от того, гоняли ли снап.
osmium tags-filter uzbekistan.osm.pbf w/highway -o roads.osm.pbf --overwrite
# -u type_id добавляет к каждой дороге её идентификатор в OSM («w12345678»).
#
# Он не едет в тайл — запись дороги там [класс, биты, дельты, имя?], и пятый
# элемент отправил бы в nil ВЕСЬ тайл у сборок, которые о нём не знают.
# Идентификатор нужен только панели: id способа в OSM меняется, когда способ
# разрезали или удалили, а не когда подвинули точку, — то есть в большинстве
# случаев он находит ту же дорогу мгновенно и точно, там где геометрический
# поиск каждую неделю кладёт в очередь «посмотрите» то, что не двигалось.
osmium export roads.osm.pbf -f geojsonseq --geometry-types=linestring \
    -u type_id -o roads.geojsonl --overwrite
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
    n/highway=traffic_signals,stop,crossing n/traffic_calming n/road_marking=stop_line \
    -o points.osm.pbf --overwrite
osmium export points.osm.pbf -f geojsonseq --geometry-types=point \
    -o points.geojsonl --overwrite
echo "    точек в экстракте: $(wc -l < points.geojsonl)"

# Деревья: отдельные и ряды (аллеи вдоль улиц). Рисуются кронами, как у
# Яндекса; лицензия OSM это разрешает.
osmium tags-filter uzbekistan.osm.pbf n/natural=tree w/natural=tree_row \
    -o trees.osm.pbf --overwrite
osmium export trees.osm.pbf -f geojsonseq --geometry-types=point,linestring \
    -o trees.geojsonl --overwrite
echo "    деревьев в экстракте: $(wc -l < trees.geojsonl)"

# Дома. Самый большой слой по числу объектов: в одном кадре центра Ташкента их
# 54 094 против семисот дорог, и приезжают они в том же .pbf, что и всё
# остальное, — отдельной закачки не нужно.
#
# Берём OSM, а не готовые обводки нейросети, и это замер, а не предпочтение: в
# том же кадре Microsoft ML нашёл 82 418 зданий против 54 094 в OSM — то есть
# в полтора раза больше контуров, — но НИ ОДНОГО адреса. Адрес есть только в
# OSM: 21 808 домов с номером и 16 586 с номером и улицей. Дом без адреса
# отвечает лишь на «сюда ли сворачивать», дом с адресом — ещё и на «куда
# ехать», а вторая цепочка данных ради полутора раз по контурам стоит дороже,
# чем даёт.
osmium tags-filter uzbekistan.osm.pbf wa/building -o houses.osm.pbf --overwrite
osmium export houses.osm.pbf -f geojsonseq --geometry-types=polygon \
    -o houses.geojsonl --overwrite
echo "    домов в экстракте: $(wc -l < houses.geojsonl)"

# Адреса. Берём и узлы, и контуры: в OSM адрес живёт и тем, и другим — в кадре
# центра Ташкента 17 153 контура против 1 517 точек.
#
# Это единственное, ради чего стоит держать свой поиск: поиск в приложении
# работает через Apple и только по сети. В роуминге, в тоннеле и на краю
# покрытия «Куда» перестаёт существовать — а свой индекс работает всегда.
osmium tags-filter uzbekistan.osm.pbf \
    n/addr:street w/addr:street a/addr:street -o addresses.osm.pbf --overwrite
osmium export addresses.osm.pbf -f geojsonseq \
    --geometry-types=point,linestring,polygon -o addresses.geojsonl --overwrite
echo "    адресов в экстракте: $(wc -l < addresses.geojsonl)"

# Населённые пункты. Ровно те виды, которые подписывают на карте: город,
# посёлок, кишлак, хутор и район города. Всё остальное из `place` — это
# страны, области и континенты, и на схеме за рулём им делать нечего.
#
# Берём и узлы, и границы: город в OSM бывает и тем, и другим.
osmium tags-filter uzbekistan.osm.pbf \
    n/place=city,town,village,hamlet,suburb,neighbourhood \
    a/place=city,town,village,hamlet,suburb,neighbourhood \
    -o places.osm.pbf --overwrite
osmium export places.osm.pbf -f geojsonseq \
    --geometry-types=point,polygon -o places.geojsonl --overwrite
echo "    мест в экстракте: $(wc -l < places.geojsonl)"

# Правки конструктора. Снимок, а не приращение: сборка накладывает состояние
# целиком, и «отменить правку» значит собрать тайлы без этой строки.
#
# Нет панели — нет правок, и это не ошибка: сборка обязана работать на машине,
# где панели никогда не было. Пустой файл в этом случае и пишем.
EDITS="$WORK/edits.json"
if python3 "$ADMIN" --export-edits > "$EDITS.new" 2>/dev/null; then
    mv "$EDITS.new" "$EDITS"
    echo "    правок панели: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$EDITS")"
else
    rm -f "$EDITS.new"
    echo '{"version":1,"items":[]}' > "$EDITS"
    echo "    панели нет — собираем без правок"
fi

echo "--- 3/4: сборка кандидата"
rm -rf "$CANDIDATE" && mkdir -p "$CANDIDATE"

# Поверхность дорог (набор d) пишется потоком, по одной фигуре, — но склейка
# кусков в улицы всё равно живёт в памяти целиком: улица не должна рваться на
# границе тайла, значит сеть надо видеть всю сразу. Замерено: 350 байт на
# дорогу, то есть около 212 МБ на 604 522 дороги страны.
#
# Первый боевой прогон эту цену и не выдержал, но не из-за поверхности: слой
# домов, называвшийся потоковым, в конце всё равно собирал все записи в
# память — 439 байт на дом при 1 653 195 домах, то есть 0,73 ГБ. Оба места
# теперь пишут файл сразу; порог остаётся страховкой на случай, когда рядом
# работают API и панель.
SURFACE=""
FREE_MB=$(free -m | awk '/^Mem:/ {print $7}')
if [ "${FREE_MB:-0}" -lt 600 ]; then
    SURFACE="--no-surface"
    echo "    свободно $FREE_MB МБ — поверхность дорог НЕ считаем"
else
    echo "    свободно $FREE_MB МБ — поверхность дорог считаем"
fi

python3 "$WORK/build_roads.py" --in roads.geojsonl --areas areas.geojsonl \
    --points points.geojsonl --houses houses.geojsonl \
    --places places.geojsonl --trees trees.geojsonl \
    --addresses addresses.geojsonl --edits "$EDITS" $SURFACE --mvt \
    --tiles "$CANDIDATE"

# Сверка правок конструктора со свежей сетью — ДО публикации.
#
# Если правка потеряла опору, узнать об этом надо раньше, чем тайл уедет на
# телефоны. Автоматика двигает только то, на что имеет право; снятие с
# публикации остаётся решением человека и ждёт его на странице «Что изменилось».
if [ -f "$ADMIN" ]; then
    python3 "$ADMIN" --sweep "$CANDIDATE" || \
        echo "    сверка правок не удалась — публикуем как есть"
fi

# Самопроверка детерминизма. Недетерминированная сборка меняет sha256 ВСЕХ
# тайлов каждую неделю, и каждый телефон перекачивает свои файлы впустую —
# при том что в дорогах не изменилось ничего.
echo "--- 4/4: детерминизм"
rm -rf "$CANDIDATE.check" && mkdir -p "$CANDIDATE.check"
# ТЕ ЖЕ аргументы, что у кандидата. Иначе проверка сравнивает разные сборки и
# останавливает конвейер на себе самой: слой домов или адресов, поданный одной
# и не поданный другой, — это гарантированное расхождение. Это же относится и
# к --mvt: сверяются каталоги целиком, и дерево тайлов, написанное одной
# сборкой и не написанное другой, остановило бы конвейер на ровном месте.
python3 "$WORK/build_roads.py" --in roads.geojsonl --areas areas.geojsonl \
    --points points.geojsonl --houses houses.geojsonl \
    --places places.geojsonl --trees trees.geojsonl \
    --addresses addresses.geojsonl --edits "$EDITS" $SURFACE --mvt \
    --tiles "$CANDIDATE.check" >/dev/null
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
