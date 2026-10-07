# Передача контекста: карта дорог RadarMap (07.10.2026)

Файл для продолжения работы в новой сессии Claude Code (другой аккаунт,
сброс контекста). Прочитай его целиком, затем CLAUDE.md и ARCHITECTURE.md.

## Цель владельца

Своя карта дорог «как у Яндекса»: реалистичные перекрёстки, полосы, зебры,
стоп-линии, стрелки, разделительные, островки, деревья, парковки, 3D — по
всей стране. Сверка с Яндексом — только глазами по снимкам владельца;
данные Яндекса/Google/2ГИС не берём (их условия). Источники: OSM, снимки
Bing/Esri — только для правок В OSM.

## Где что лежит

- Сборка: `server/build_roads.py` (OSM → JSON-тайлы + полотно),
  `server/build_mvt.py` (MVT для движка), `server/omt/make_style.py` (стиль),
  `server/omt/make_arrows.py` (спрайт: стрелки, деревья, асфальт, штриховка),
  `server/parking.py` (парковки), `server/lane_inference.py`.
- Метрики качества: `server/road_metrics.py` (ворота публикации, /status).
- Очередь перекрёстков для OSM: `server/junction_worklist.py`, вкладка
  «Перекрёстки» в админке.
- Конвейер: `server/update_roads.sh` (воскресный крон на VPS),
  `server/install_roads_pipeline.sh`, `server/publish_roads.sh --auto`
  (подпись ключом владельца ~/.radarmap/ota_signing.pem — ключ НЕ читать).
- Планы: `docs/plan_junctions_polish.md`, `docs/plan_junction_model.md`,
  `docs/plan_free_mapping.md`, `docs/plan_imagery_ml.md`,
  `docs/plan_ml_roads.md`, `docs/plan_drive_sim.md`.
- Симулятор: `tools/drive_sim/` (make_route.py + drive_sim.js + drive.html).
- Автоподбор параметров: `tools/autotune/autotune.py`.

## Как работаем локально (мак владельца)

- Вырезка Ташкента: `~/RadarMapBuild/tash` (сборка ~2 мин в `out_new`):
  `python3 server/build_roads.py --in roads.geojsonl --areas areas.geojsonl
  --points points.geojsonl --houses houses.geojsonl --places places.geojsonl
  --trees trees.geojsonl --addresses addresses.geojsonl --edits edits.json
  --mvt --tiles out_new`
- Метрики: `python3 server/road_metrics.py ~/RadarMapBuild/tash/out_new
  --islands ~/RadarMapBuild/tash/area_highway.geojsonl --json m.json --compare old.json`
- Превью: `~/RadarMapBuild/omt/web/serve.py 8770 ../uz.mbtiles <tiles>`;
  стили пересобирает scratchpad `regen_styles.py` (из make_style.py, пути /tiles /radar).
- Рендер как на телефоне (без браузера): `server/omt/render_native.js`
  (Node 22 + @maplibre/maplibre-gl-native + pngjs). Node 22 и модуль лежат в
  scratchpad сессии a376e51d (`node-v22.20.0-darwin-arm64`, `mln/`). Звать из
  bash, не zsh (zsh не делит `set -- $spot` → NaN → std::domain_error).
  На 07.10 наклон > 0 даёт segfault и на старых данных — ограничение
  обвязки, наклон проверять телефоном. Headless Chrome — не использовать.
- Страна: `~/RadarMapBuild/build_country.sh` (две сборки подряд + проверка
  байт в байт) или один проход build_roads с `--tiles cand` (~37 мин, пик
  ~14 ГБ после правок 07.10). Docker Desktop закрыть (ВМ держит 4 ГБ).
  Сетки по всей стране — один кортеж на отрезок/площадь, а не копия на клетку:
  копии раздули сборку до 30 ГБ (0deb934, 1bc53b3, 786941c).
- Публикация: tar кандидата → заливка кусками с sha256 (скрипт
  upload_chunks.sh в scratchpad; rsync на VPS нет) → распаковка в
  `/opt/radarmap/work/roads_tiles_candidate` → `admin.py --sweep` →
  `bash server/publish_roads.sh --auto` → стиль: `make_style.py
  https://soulmed.uz/radarmap` → `/opt/radarmap/www/map_style.json`
  (прежний — map_style.prev.json). Всё под `caffeinate -i` (мак засыпает).
- После публикации дорог/основы — `bash server/publish_tileset.sh`: выпуск
  v/<N>/ (кэш на год) и корзины индекса под подписанным tiles_root.json —
  контракт для приложения в docs/plan_map_offline.md §2.6.
- Проверка: `/opt/radarmap/api/status.py` → roads/mvt/omt ok.
- Крон VPS (`update_roads.sh`, вс 04:17) с 07.10 готовит ТОЛЬКО экстракт:
  сборка страны на 2 ГБ невозможна. Вернуть — RADARMAP_BUILD_ON_VPS=1.

## Состояние на 07.10.2026 ~14:50

- ОПУБЛИКОВАНО 07.10 14:45 (тайлы v2 49 675, MVT 165 116, стиль 168 слоёв;
  прежний стиль — map_style.prev.json, тайлы — roads_prev) с:
  парковками, стоп-линиями на подходах, ограждениями мостов, асфальтом с
  зерном, плавными стыками, зебрами на обеих половинах, едиными тонами
  асфальта, без клиньев-галтелей, разметкой до стоп-линии, тёплыми домами,
  отбраковкой «звёзд». Штриховка островков (коммит e24bc7c) — только стиль,
  выкладывается вместе со стилем.
- Тротуары-полосы и поднятый бордюр — УБРАНЫ по решению владельца
  (флаг SIDEWALKS_ENABLED=False). Фаски подходов выключены (FLARES_ENABLED).
- Ждёт: проверка на телефоне в поездке (плавность, нагрев, батарея, 3D).

## Метрики Ташкента (последние)

пунктир в узле ~19 м/км (было 146), зебры за кромкой ~3 %, дубли ~0,4 %,
стрелки за стоп-линией ~13 ‰, разделительные на узле ~1 %, островки под
асфальтом ~4 %, раздутые узлы ~0,1 %.

## Открытые задачи

1. ГЛАВНОЕ: встроить карту в приложение — docs/plan_map_omt.md §3 (~3 дня,
   нужен Xcode). Сейчас ни одна ветка приложения (main, testflight/*) не
   берёт ни map_style.json, ни подложку OMT: стиль вшит в
   `EngineMapStyle.swift` и читает только roads/surface/land/houses/points/
   markings/paint. Деревья, парковки, ограждения, стрелки, подписи мест и вся
   основа видны ТОЛЬКО в превью; публикация тайлов меняет на телефоне лишь
   геометрию дорог и разметки. Пуш в testflight/* запускает сборку в
   TestFlight — туда только релизом приложения, не серверными коммитами.
1а. После встраивания — проверка на телефоне в поездке.
2. Предложено владельцу: газон во дворах по геометрии (ждёт ответа).
3. Режим «съёмка» (камера телефона → знаки/разметка) — план по запросу.
4. Стоп-линии на двусторонних подходах (сейчас только односторонние).
5. Перезапуск автоподбора параметров на новом коде.
6. Владельцу: аккаунт OSM и дорисовка по очереди «Перекрёстки»;
   три решения по камерам ждут подписи (`publish_overrides.sh`).

## Правила (не нарушать)

- Ключ подписи не читать; публикует владельческий скрипт.
- Данные с Яндекса/Google не брать; Bing/Esri — только для правок в OSM.
- Коммиты на русском, ветка `server/vps-stage1`, в main — через merge.
- Каждое изменение: тесты (`python3 -m unittest test_build_mvt
  test_build_roads test_surface_check test_road_metrics`, `cd omt &&
  python3 -m unittest test_make_style`), метрики, рендер эталонных мест.
