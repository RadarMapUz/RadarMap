# Пробки внутри маршрутизатора (32D, 27.10.2026)

До сих пор пробки жили **поверх** маршрута: OSRM (CH) выбирает путь по графу
пустых дорог, телефон прибавляет к времени варианта задержку пробки
(`TrafficSnapshot.delay`). Путь через пробку остаётся путём через пробку —
меняется только цифра. Здесь — как сделать, чтобы OSRM сам строил путь в
объезд: MLD + `osrm-customize` с файлом скоростей из `traffic_build.py`.

**Состояние 27.10:** стенд `radarmap-osrm-mld` поднят на VPS рядом с продом
(127.0.0.1:8094, граф без пробок), cron **выключен**, прод (8092) и nginx не
тронуты. Включение и переключение — решение владельца, команды ниже.

## Архитектура

```
телефоны ─ POST /api/traffic ─► traffic.db ─► traffic_build.py (cron */2, match на 8092)
                                    │            └─► now.json, typical/*.json → телефоны (как было)
                                    ▼
             traffic_speeds.py --source auto --mode weight   (стенд, только чтение базы)
                                    ▼ speeds.csv: u,v,скорость графа,rate
             traffic_customize.sh (cron */5, только при изменении файла)
               эталон pristine/ → слот a|b → osrm-customize → current → restart
                                    ▼
             radarmap-osrm-mld  127.0.0.1:8094  (MLD, --mmap, 3 варианта)
```

| Файл | Что это |
|---|---|
| `server/traffic_speeds.py` | Файл скоростей из `traffic.db`: те же правила публикации, что у `now.json` и «обычно» |
| `server/osrm/traffic_customize.sh` | Один цикл на VPS: файл → customize в запасном слоте → подмена → проба, откат при сбое |
| `server/osrm/route_bench.py` | Замер: время ответа на 20 парах (`time`), искусственная пробка (`jam`), проверка объезда (`check`) |
| `server/build_osrm_mld.sh` | Сборка графа MLD на маке (тот же образ OSRM v26.7.3, linux/amd64) |
| `server/crontab.txt` | Строка цикла — закомментирована |

### Файл скоростей — что попадает в граф

Ключ — направленное ребро OSM `(u, v)`, ровно те пары узлов, что отдаёт
`match` (`annotations=nodes`); они постоянны между пересборками графа.

* **Только подтверждённое.** `now` — рёбра `now.json` (`live_edges`: ≥ 2
  независимых куска, прошедших ребро насквозь, за 15 минут) **и только
  медленные** (уровень ≥ 2, ниже 0,6 скорости графа). `typical` — рёбра
  файла «обычно» класса дня и часа (≥ 5 эффективных кусков и «не один
  человек») медленнее 0,6 графа. `auto` — объединение, живое главнее.
* **Не выше графа, не ниже 5 км/ч.** Свободный поток в граф не пишется: двор
  на 60 км/ч по двум машинам — вред. 0 для OSRM — «ребро закрыто», а ниже
  5 км/ч медиана — уже стояние у светофора и дрожь GPS. 5 км/ч — 12 мин/км,
  любой разумный объезд выигрывает и так.
* **Нет данных — нет строки:** ребро остаётся профильным (`car_radarmap.lua`).
  Пустой файл — граф эталона без customize.

### Два режима: что OSRM делает с файлом (проверено на v26.7.3)

| Режим | Строка | Вес (выбор пути) | Время (`duration`) |
|---|---|---|---|
| **weight** — по умолчанию | `u,v,скорость графа,rate` | по пробке: длина / rate | граф, без пробки |
| duration | `u,v,скорость пробки` | по пробке | с пробкой |

Без `rate` OSRM пишет в журнал «Speed values were used to update … segments
for 'routability' profile» — вес и время берутся из скорости. С `rate` вес
идёт от него, время — от скорости (`rate` в м/с, та же единица, что
`forward_rate` в профиле). Замер на одном куске Амира Темура внутри пробки:
вес 550 в обоих режимах, время 527 с (duration) против 350 с (weight).

**Почему weight.** Телефон уже прибавляет задержку пробки сам. Ответ с
пробкой во времени (duration) дал бы её дважды: в ETA, в «Быстром», в
`DetourAdvisor`. В режиме weight сервер меняет только выбор пути, приложение
переключать не нужно. Duration — когда (и если) телефон научится не
прибавлять свою задержку к ответу такого сервера.

### Цикл на VPS (`traffic_customize.sh`)

```
/opt/radarmap/osrm-mld/
  pristine/   набор build_osrm_mld.sh (страна, 847 МБ) — эталон, только чтение
  a/ b/       слоты
  current ->  b   (относительная ссылка; контейнер открывает /data/current/uzbekistan.osrm)
  bin/        traffic_speeds.py, traffic_build.py, traffic_customize.sh, route_bench.py, audit_pairs.json
  speeds.csv  последний файл; customize.log — журнал последнего customize
  test/       синтетика замеров: jam-multi.csv (4 пробки), stress.csv (14 600 рёбер)
```

1. `traffic_speeds.py` → `speeds.csv`; совпал с файлом рабочего слота —
   «без изменений», конец (это почти все циклы).
2. Запасной слот **с эталона**: `.mldgr` и `.geometry` customize читает и
   переписывает на месте — копии (243 МБ); `.cell_metrics` и
   `.datasource_names` он создаёт сам; остальные 23 файла — жёсткие ссылки
   на эталон (проверено по mtime и sha: customize их на запись не
   открывает). Жёсткая ссылка на переписываемый файл испортила бы эталон;
   слот поверх прошлого слота сохранил бы снятую пробку.
3. `osrm-customize -t 1` в контейнере `-m 900m --memory-swap 900m --cpus 1`.
   Упал (предел памяти) — слот без пробок: старая пробка хуже никакой (то же
   правило, что у `now.json` старше 10 минут).
4. Ссылка `current` → новый слот одним `rename(2)`, `docker restart`,
   проба `route` до 30 с; не ответил — ссылка назад и снова restart.

**Почему restart, а не `osrm-datastore`.** Подмена без простоя у OSRM —
`osrm-routed --shared-memory` + `osrm-datastore --only-metric`, но в
разделяемой памяти набор страны лежит резидентно (~0,9 ГБ), а на VPS
свободно 1,2 ГБ на всё. С `--mmap` резидентно ~60 МБ, `osrm-routed`
поднимается меньше чем за секунду: простой стенда по журналу — 0–1 с.
Для прода простой закрывает nginx (резерв CH, ниже).

## Цифры

### Сборка графа (мак, amd64 через эмуляцию, машина под нагрузкой соседей)

Весь `build_osrm_mld.sh` страны — **83 с** (extract, partition — бисекция 12 с,
customize). Пик OSRM: extract ~3 ГБ (как у CH), partition 790 МБ, customize
681 МБ. Набор 856 МБ (CH — 802 МБ).

### `osrm-customize` с файлом скоростей

| Где | Файл | Время | Пик памяти |
|---|---|---|---|
| мак, эмуляция, `-t 1…2`, LA 24–28 | 59 / 354 / 14 600 рёбер | 9–25 с | VmHWM 634 МБ |
| **VPS**, `-t 1 --cpus 1` | 14 600 рёбер (синтетика) | **34–35 с** (ячейки 25 с) | **VmHWM 617 МБ**, OSRM 648 МБ |
| **VPS**, полный цикл скрипта | 354 ребра (4 пробки) | 39 с customize + **1 с простоя** | — |

Время и память от размера файла почти не зависят: customize пересчитывает
метрику всех ячеек страны. 14 600 рёбер — впятеро больше, чем `traffic.db`
вообще знает рёбер (2 929).

Во время customize на VPS: свободная память (available) падала с 1195 до
**617 МБ**, page cache — с 1354 до 890 МБ, своп +44 МБ, OOM нет. Прод в это
время (40 запросов приложения): медиана 16 мс, p90 39, макс 104 — против
13 / 34 / 85 в покое.

### Время ответа `route` (20 пар аудита, запрос приложения: alternatives=3, steps, overview=full, approaches)

| Где | CH (прод 8092) | MLD (стенд 8094) |
|---|---|---|
| VPS, первый круг (холодный кэш) | медиана 24 мс, p90 156, макс 427 | медиана 24 мс, p90 84, макс 146 |
| VPS, 3 круга, тёплый | 13 / 34 / 85 мс | 14 / 31 / 42 мс |
| мак, 3 круга | 11 / 25 / 62 мс | 11 / 20 / 36 мс |
| вариантов в среднем | 1,45 | **1,90** |

MLD не медленнее CH, а хвост короче; и даёт до трёх вариантов там, где CH —
не больше двух (приложение уже просит три).

### Объезд искусственной пробки (VPS, стенд после цикла)

`route_bench.py jam` — середина маршрута пары (35–65 %) по 5 км/ч; четыре
пробки в одном файле (354 ребра), режим weight:

| Пара | Прод CH | Стенд MLD с пробками |
|---|---|---|
| Чиланзар → Юнусабад | 15,0 км, 24,4 мин, **59 рёбер пробки** | 16,35 км, 26,4 мин, 0 рёбер |
| Сергели → пл. Амира Темура | 14,9 км, 109 рёбер | 17,2 км, 26,3 мин, 0 |
| Мирзо-Улугбек → аэропорт | 11,5 км, 122 ребра | 13,3 км, 22,7 мин, 0 |
| Аэропорт → Tashkent City | 6,8 км, 64 ребра | 8,6 км, 15,3 мин, 0 |

Все первые варианты обходят пробку целиком; время — графовое (режим weight),
задержку на оставшихся рёбрах пробки по-прежнему добавит телефон.

## Влезает ли на VPS

**Да, с запасом по памяти и с условием по частоте.** VPS: 2 ядра QEMU,
1963 МБ ОЗУ (available ~1,2 ГБ), своп 3 ГБ, диск 13 ГБ свободно после стенда.

* Память: пик customize 617 МБ при 1,2 ГБ свободных, предел контейнера 900 МБ
  без свопа — соседей в OOM он не утянет, сам упадёт и цикл перейдёт на граф
  без пробок. `osrm-routed` стенда — ~60 МБ (предел 512 МБ).
* ЦП: одно ядро на ~35 с на **изменение** файла. При изменении каждые 5 минут
  — 12 % одного ядра; второе ядро всегда у прода и соседей.
* Диск: на изменение — копия 243 МБ и ~430 МБ записи customize; стенд
  целиком ~1,7 ГБ (эталон + два слота).

Цикл каждые 2 минуты (как `traffic_build.py`) не нужен: живое окно — 15 минут,
и 35 с счёта в каждые 120 — уже треть ядра. Раз в 5 минут и только при
изменении — разумно. Если соседи на VPS вырастут: реже (10 мин), или
городской граф (`build_osrm_mld.sh --city`, ~1/8 страны — customize в разы
легче; нужен osmium), или остаться на CH со «штрафом» на телефоне (как
сейчас) — у каждого варианта своя цена, решение не нужно, пока данных нет.

## Риски

1. **Данных пока нет.** 27.10 в `traffic.db`: 0 живых рёбер, 0 рёбер
   «обычно» (9 489 строк профиля, максимум 2 эффективных куска на строку,
   12 рёбер «не один человек»). Файл скоростей пуст — стенд с пробками сейчас
   строит ровно то же, что без них. Включать cron до появления плотности
   (панель «Пробки», порог `CITY_READY_PIECES_PER_HOUR` = 60) можно —
   он просто будет писать «без изменений».
2. **Замерший cron = вечная пробка.** Пробка снимается следующим циклом;
   если cron остановится, последний слот останется. В `status.py` стоит
   добавить проверку «`speeds.csv` старше 15 минут при включённом cron».
3. **Page cache.** Каждый новый слот — 430 МБ новых файлов; первые запросы
   после подмены холоднее, и customize вытесняет страницы прода (см. замер:
   p90 прода 34 → 39 мс, макс 85 → 104 мс).
4. **Скорость графа в weight — из `traffic_edges.model_kmh`**, то есть из
   ответов `match` прода (CH 29e). Профиль у них общий (`car_radarmap.lua`);
   если граф стенда соберут другим профилем, длительность рёбер с пробкой
   поплывёт на разницу профилей — пересобирать оба вместе.
5. **Двойной учёт** при переходе в режим duration без правки телефона
   (раздел «Два режима»).
6. **Версия.** Набор собран образом v26.7.3 (дайджест a7091038…); обновлять
   образ — только вместе с пересборкой эталона.

## Команды

### Стенд — как поднят (повторить с нуля)

```bash
# мак: граф и выкладка эталона (COPYFILE_DISABLE — без ._-файлов macOS)
bash server/build_osrm_mld.sh --work ~/RadarMapBuild/osrm/mld-32d \
    --profile server/osrm/car_radarmap.lua --pbf ~/RadarMapBuild/osrm/uzbekistan-latest.osm.pbf
ssh radarmap-vps 'mkdir -p /opt/radarmap/osrm-mld/{pristine,bin}'
cd ~/RadarMapBuild/osrm/mld-32d/mld-uzbekistan && COPYFILE_DISABLE=1 tar cf - uzbekistan.osrm* manifest.txt \
    | gzip -1 | ssh radarmap-vps 'cd /opt/radarmap/osrm-mld/pristine && gunzip | tar xf - --no-same-owner'
cd server && COPYFILE_DISABLE=1 tar cf - traffic_speeds.py traffic_build.py -C osrm traffic_customize.sh route_bench.py audit_pairs.json \
    | ssh radarmap-vps 'cd /opt/radarmap/osrm-mld/bin && tar xf - --no-same-owner && chmod +x traffic_customize.sh'

# VPS: первый слот (контейнера ещё нет — только слот), затем контейнер
ssh radarmap-vps '/opt/radarmap/osrm-mld/bin/traffic_customize.sh &&
  docker run -d --name radarmap-osrm-mld --restart unless-stopped -m 512m \
    -p 127.0.0.1:8094:5000 -v /opt/radarmap/osrm-mld:/data:ro \
    ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad \
    osrm-routed --algorithm mld --mmap 1 --max-alternatives 3 /data/current/uzbekistan.osrm'
```

### Проверить стенд

```bash
ssh radarmap-vps 'cd /opt/radarmap/osrm-mld/bin && R=/opt/radarmap/osrm-mld &&
  python3 -I route_bench.py time --base http://127.0.0.1:8092 --base http://127.0.0.1:8094 --rounds 3 &&
  ./traffic_customize.sh --speeds $R/test/jam-multi.csv &&
  python3 -I route_bench.py check --base http://127.0.0.1:8094 --pair chil-yunus --jam $R/test/jam-multi.csv &&
  ./traffic_customize.sh'      # вернуть настоящий файл (сейчас пустой)
```

### Включить цикл (стенд начинает следовать пробкам; прод не меняется)

```bash
ssh radarmap-vps '(crontab -l; echo "3-59/5 * * * * /opt/radarmap/osrm-mld/bin/traffic_customize.sh >> /var/log/radarmap-osrm-mld.log 2>&1") | crontab - && crontab -l | grep traffic_customize'
# журнал: /var/log/radarmap-osrm-mld.log (две строки на цикл)
```

### Переключить приложения на стенд — решение владельца

nginx: OSRM ходит в двух местах — `/etc/nginx/snippets/radarmap-location.conf`
(домен soulmed.uz) и `/etc/nginx/conf.d/radarmap.conf` (старый :8090). Апстрим
со стендом и **CH-продом в резерве**: на секунду перезапуска стенда nginx
отдаёт маршрут CH (без пробок, но маршрут), и ни один запрос не падает.

```bash
ssh radarmap-vps '
  cp /etc/nginx/snippets/radarmap-location.conf /etc/nginx/snippets/radarmap-location.conf.bak-32d &&
  cp /etc/nginx/conf.d/radarmap.conf /etc/nginx/conf.d/radarmap.conf.bak-32d &&
  cat > /etc/nginx/conf.d/radarmap-osrm-upstream.conf <<EOF
upstream radarmap_osrm {
    server 127.0.0.1:8094 max_fails=1 fail_timeout=10s;   # MLD с пробками (стенд)
    server 127.0.0.1:8092 backup;                         # CH-прод: на время перезапуска стенда
}
EOF
  sed -i "s|proxy_pass http://127.0.0.1:8092/;|proxy_pass http://radarmap_osrm/; proxy_next_upstream error timeout http_502 http_503;|" \
    /etc/nginx/snippets/radarmap-location.conf /etc/nginx/conf.d/radarmap.conf &&
  nginx -t && systemctl reload nginx'
# проверка с мака: те же 20 пар по публичному адресу, вариантов должно стать ~1,9
python3 server/osrm/route_bench.py time --base https://soulmed.uz/radarmap/osrm --rounds 1
```

`traffic_build.py` продолжает делать `match` на 8092 (CH) — его не трогаем.
В приложении ничего менять не нужно (режим weight).

### Откат

```bash
ssh radarmap-vps '
  cp /etc/nginx/snippets/radarmap-location.conf.bak-32d /etc/nginx/snippets/radarmap-location.conf &&
  cp /etc/nginx/conf.d/radarmap.conf.bak-32d /etc/nginx/conf.d/radarmap.conf &&
  rm -f /etc/nginx/conf.d/radarmap-osrm-upstream.conf &&
  nginx -t && systemctl reload nginx'
# цикл — закомментировать строку traffic_customize.sh в crontab; стенд целиком:
ssh radarmap-vps 'docker rm -f radarmap-osrm-mld && rm -rf /opt/radarmap/osrm-mld'
```

Откат прод-графа CH (`/opt/radarmap/osrm-29e` → `/opt/radarmap/osrm`) — в
`README.md`, он от стенда не зависит.

### Новый граф (ежемесячно)

Эталон пересобирается на маке (`build_osrm_mld.sh`), едет в
`/opt/radarmap/osrm-mld/pristine.new`, затем `mv pristine pristine.old &&
mv pristine.new pristine && bin/traffic_customize.sh --force`. Файл скоростей
подходит к любому графу — ключи по узлам OSM.
