# Профиль OSRM RadarMap и аудит маршрутов (29.E)

Здесь лежит то, что меняет **сам граф** маршрутов. В приложении это не
чинится. Разбор с картинками — `docs/route_audit_2026-10-25.md`.

| Файл | Что это |
|---|---|
| `car_radarmap.lua` | Профиль: стоковый `car.lua` OSRM v26.7.3 (побайтно тот, что в образе на VPS) плюс блок `profile.radarmap` |
| `test_car_radarmap.py` | Проверка профиля на синтетических картах в 5–10 узлов: махалля, светофор, левый поворот, UZ:urban. Нужен Docker, без него идут только статические проверки |
| `route_audit.py` | Аудит 20 пар: fetch → index (pyosmium) → analyze → render |
| `turn_audit.py` | Аудит запретов поворотов, oneway и барьеров в рамке Ташкента: scan (pyosmium) → report (+ GeoJSON) → shots. Разбор — `docs/turn_audit_2026-11-10.md` |
| `render_routes.swift` | PNG по спецификации `route_audit.py render`: CoreGraphics, без зависимостей |
| `audit_pairs.json` | Пары аудита: районы и известные точки, без дома и работы владельца |
| `TRAFFIC.md` | Пробки внутри маршрутизатора (32D): MLD + customize, замеры, стенд на 8094, переключение и откат |
| `traffic_customize.sh` | Цикл стенда на VPS: файл скоростей → customize → подмена слота (в cron выключен) |
| `route_bench.py` | Время ответа CH против MLD на 20 парах, искусственная пробка и проверка объезда |
| `graph_refresh.py` | Еженедельный граф: сборка на маке, аудит против боевого, ночная заливка кандидата, шаги подмены (87, `docs/graph_refresh_2026-11-10.md`) |
| `test_graph_refresh.py` | Ворота нагрузки и аудита, чистка кандидатов, подмена и откат на временном корне |

## Что меняет профиль и почему

| Ручка (`profile.radarmap`) | Значение | Зачем |
|---|---|---|
| `class_speed_caps` | living_street 15, service 20, residential 40 км/ч | В Ташкенте 1358 км living_street помечены maxspeed=60. Стоковый профиль ставит maxspeed поверх класса, и улица махалли весит 48 км/ч, как проспект. Теперь maxspeed может скорость класса снизить, но не поднять |
| `living_street_rate` | 0,6 | Улица махалли годится в начало и конец пути, но не для транзита: срез окупается, только если он втрое короче объезда |
| `traffic_signal_seconds` | 8 с | Стоковые 2 с: на маршруте 17–38 светофоров, ETA врала, и улица со светофорами выглядела не хуже эстакады |
| `left_turn_major_seconds` | 15 с | Левый поворот без светофора там, где на перекрёстке есть trunk…secondary: ждать разрыв в потоке. Запретов в OSM по Ташкенту мало (79 no_left_turn) |
| `maxspeed_table` | `uz:urban` 70, `uz:rural` 100, `uz:motorway` 110, `uz:living_street` 20 | ПДД РУз вместо урезанного дефолта (50 в городе) |

Без изменений: запреты поворотов (`use_turn_restrictions`), правостороннее
движение, `u_turn_penalty` 20 с, классы и исключения.

## Проверить локально (Mac, Docker, ~2 мин)

```bash
python3 server/osrm/test_car_radarmap.py          # 7 проверок, ~40 с

# весь Узбекистан, нативно (arm64) — только для проверки, не для выкладки:
IMG=ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad
W=~/RadarMapBuild/osrm/try && mkdir -p $W && cp ~/RadarMapBuild/osrm/uzbekistan-latest.osm.pbf $W/uz.osm.pbf
docker run --rm -v $W:/data -v $PWD/server/osrm/car_radarmap.lua:/opt/car_radarmap.lua:ro $IMG \
    osrm-extract -p /opt/car_radarmap.lua -t 4 /data/uz.osm.pbf          # ~1 мин, пик 2,3–3,0 ГБ
docker run --rm -v $W:/data $IMG osrm-contract -t 4 /data/uz.osrm        # ~4 мин, пик 1,1 ГБ
docker run -d --name osrm-try -p 127.0.0.1:5104:5000 -v $W:/data $IMG \
    osrm-routed --algorithm ch --mmap 1 /data/uz.osrm

# аудит тех же 20 пар против прода:
python3 server/osrm/route_audit.py fetch --base http://127.0.0.1:5104 --out runs/new --delay 0 \
    --alternatives 3 --extra '&approaches=unrestricted;curb'
python3 server/osrm/route_audit.py index --pbf ~/RadarMapBuild/osrm/uzbekistan-latest.osm.pbf \
    --runs runs/new --out tags.json
python3 server/osrm/route_audit.py analyze --runs runs/new --tags tags.json --out new.json
```

Docker Desktop с памятью меньше 4 ГБ: extract с `-t 8` убивается по
нехватке памяти (код 137) — берите `-t 4` и остановите лишние контейнеры.

Приложение (DEBUG) можно направить на локальный сервер:
`-osrmBase http://127.0.0.1:5104`. Так сняты экраны в `RadarMap-wt/shots_29e/`.

## Выкатка на VPS — делает владелец, после ревью

**Состояние 26.10.2026:** вариант A выкачен — `radarmap-osrm` смотрит в `/opt/radarmap/osrm-29e` (граф с `car_radarmap.lua`, CH, тот же образ v26.7.3). Прежний граф лежит в `/opt/radarmap/osrm` — откат ниже. На VPS нет `rsync`: файлы везли `tar | ssh`.

VPS собрать граф не может: 2 ГБ ОЗУ, пик extract 1,6–3 ГБ, поэтому
`update_osrm.sh` и снят с cron 19.07. Граф собирается на маке, на VPS едут
готовые файлы. Сервер раздаёт их через `--mmap`: резидентно около 50 МБ, и
CH, и MLD.

### Вариант A — новый профиль, режим прежний (CH). Рекомендую первым

Что даёт: махалли, светофоры, левые без светофора, UZ:urban. Чего не даёт:
третьего варианта (CH отдаёт не больше одной альтернативы, приложение уже
просит три).

```bash
# 1. мак: сборка под amd64 той же версией, что на VPS (эмуляция — дольше,
#    оценка 20–40 мин; файлы те же, что соберёт сервер)
bash server/build_osrm_mld.sh --fetch --ch --profile server/osrm/car_radarmap.lua
#    → ~/RadarMapBuild/osrm/ch-uzbekistan/ (uzbekistan.osrm.*, ~1,1 ГБ, manifest.txt)

# 2. мак: проверить набор локально (см. выше: osrm-routed + route_audit.py)

# 3. на VPS — в СОСЕДНИЙ каталог, старый граф не трогаем (свободно 14 ГБ)
rsync -a --progress ~/RadarMapBuild/osrm/ch-uzbekistan/ radarmap-vps:/opt/radarmap/osrm-29e/

# 4. VPS: подмена (простой 5–10 с; образ НЕ обновлять — нужен v26.7.3)
ssh radarmap-vps '
  docker rm -f radarmap-osrm &&
  docker run -d --name radarmap-osrm --restart unless-stopped \
    -p 127.0.0.1:8092:5000 -v /opt/radarmap/osrm-29e:/data \
    ghcr.io/project-osrm/osrm-backend osrm-routed --algorithm ch --mmap 1 /data/uzbekistan.osrm &&
  sleep 5 &&
  curl -sf "http://127.0.0.1:8092/route/v1/driving/69.19617,41.28151;69.28866,41.36612?overview=false" | head -c 200'

# 5. проверка с мака: те же 20 пар по публичному адресу
python3 server/osrm/route_audit.py fetch --base https://soulmed.uz/radarmap/osrm --out runs/prod-29e
```

**Откат** (старые файлы лежат на месте, команда — из `start_when_ready.sh`):

```bash
ssh radarmap-vps '
  docker rm -f radarmap-osrm &&
  docker run -d --name radarmap-osrm --restart unless-stopped \
    -p 127.0.0.1:8092:5000 -v /opt/radarmap/osrm:/data \
    ghcr.io/project-osrm/osrm-backend osrm-routed --algorithm ch --mmap 1 /data/uzbekistan-latest.osrm'
```

Побочный эффект — пробки: `traffic_build.py` при каждом `match` перезаписывает
`traffic_edges.model_kmh`, то есть уровень пробки сам переходит на скорости
нового графа. Улица махалли теперь «свободна» уже на 15 км/ч, а не на 48.
Старые строки `traffic_profile` посчитаны против старой модели и вымоются
за окно профиля.

### Вариант B — MLD (три варианта, дальше — пробки через customize)

```bash
bash server/build_osrm_mld.sh --fetch --profile server/osrm/car_radarmap.lua
#   → ~/RadarMapBuild/osrm/mld-uzbekistan/ (partition+customize, ~1,1 ГБ)
rsync -a ~/RadarMapBuild/osrm/mld-uzbekistan/ radarmap-vps:/opt/radarmap/osrm-29e-mld/
ssh radarmap-vps '
  docker rm -f radarmap-osrm &&
  docker run -d --name radarmap-osrm --restart unless-stopped \
    -p 127.0.0.1:8092:5000 -v /opt/radarmap/osrm-29e-mld:/data \
    ghcr.io/project-osrm/osrm-backend osrm-routed --algorithm mld --mmap 1 \
      --max-alternatives 3 /data/uzbekistan.osrm'
```

Ресурсы, замер на маке 25.10:

| Шаг | Пик ОЗУ | Время, нативно |
|---|---|---|
| extract | 2,3–3,0 ГБ | ~1 мин |
| partition | 0,76 ГБ | 13 с |
| customize | 0,64 ГБ | 4 с |
| contract | 1,1 ГБ | 4 мин |
| `osrm-routed` (mmap), резидентно | ~50 МБ | — |

Набор на диске: MLD — 302 МБ своих файлов вместо 258 МБ у `.hsgr`, весь
набор ~1,1 ГБ в обоих режимах. Запрос Ташкент → Самарканд с alternatives=3:
MLD 0,34 с, CH 1,1 с на холодном кэше, по городу оба ~60 мс. На VPS (2 ядра
QEMU) будет медленнее, но таймаут приложения — 12 с.

Сборку MLD память VPS не держит, раздачу — держит. Customize страны под
пробки на самом VPS замерен 27.10 (32D): 35 с одного ядра, пик 617 МБ, —
влезает; стенд `radarmap-osrm-mld` на 127.0.0.1:8094 поднят, cron выключен.
Всё — в `TRAFFIC.md`.

Откат — та же команда варианта A или исходная. В приложении для MLD ничего
менять не нужно: `alternatives=3` уже уходит, на CH сервер отвечает ≤ 2
вариантами без ошибки.
