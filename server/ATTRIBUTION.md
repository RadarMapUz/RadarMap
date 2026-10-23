# Источники данных и их лицензии

Что в приложении и на сервере взято у других, на каких условиях и где это
лежит. Если добавляется новый источник — строка сюда и ссылка в заголовок
файла, который из него собран.

| Что | Источник | Лицензия | Где у нас |
|---|---|---|---|
| Дороги, адреса, заведения, лимиты скорости | [OpenStreetMap](https://www.openstreetmap.org/copyright), © участники OpenStreetMap | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) | тайлы и клетки `road2_*`, `speed_limits*.json`, OSRM-граф |
| Стационарные камеры (реестр МВД, набор 1-008-0027) | [data.egov.uz](https://data.egov.uz) — портал открытых данных Республики Узбекистан | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) | `RadarMap/Resources/cameras.json` (через `update_cameras.py`) |
| Областные наборы камер (Бухара, Навои, Хорезм, Каракалпакстан) | data.egov.uz, Статкомитет | CC BY-SA 4.0 | `server/review/camera_candidates.json` (`build_camera_candidates.py`), только очередь проверки |
| Банкоматы (реестр Центрального банка, набор 4-009-0061) | [data.egov.uz/ru/data/664af8be2f776a551cd0b845](https://data.egov.uz/ru/data/664af8be2f776a551cd0b845) | CC BY-SA 4.0 | `server/poi/egov_atm.geojsonl` (`import_poi_egov.py`) → клетки заведений `v` |
| Сертифицированные гостиницы (набор 2-017-0007) | [data.egov.uz/ru/data/662758862f776a551cc8b7c6](https://data.egov.uz/ru/data/662758862f776a551cc8b7c6) | CC BY-SA 4.0 | `server/poi/egov_hotel.geojsonl` (`import_poi_egov.py`) → клетки заведений `v` |
| Базовая карта (векторные тайлы `omt/`) | Схема [OpenMapTiles](https://openmaptiles.org/) (© OpenMapTiles), собрана [Planetiler](https://github.com/onthegomap/planetiler) из выгрузки OSM | схема — [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), данные — ODbL; Planetiler (Apache 2.0) — только инструмент сборки, в поставку не входит | `server/omt/build_omt.sh` → тайлы `omt/` на сервере; подпись «© OpenMapTiles © OpenStreetMap» — на карте («i») |
| Стиль карты | [OSM Bright](https://github.com/openmaptiles/osm-bright-gl-style) © MapTiler.com & OpenMapTiles contributors, © Mapbox | код — BSD 3-Clause, оформление — CC BY 4.0 | `server/omt/osm-bright.json` → `make_style.py` → `RadarMap/Resources/MapStyle/*.json` (вшит) |
| Значки POI (`*_11` в спрайте) | [Maki](https://github.com/mapbox/maki) (Mapbox) через спрайт OSM Bright | CC0 1.0 (упоминание не требуется, но указано) | `server/omt/sprite/base*.{json,png}`; стрелки полос, светофор, асфальт, деревья, штриховка — наши (`make_arrows.py`) |
| Шрифты подписей (глифы) | Noto Sans Regular/Bold/Italic из [openmaptiles/fonts](https://github.com/openmaptiles/fonts) v2.0, Copyright 2012 Google Inc. | [SIL OFL 1.1](https://openfontlicense.org/) | `server/omt/build_omt.sh` → `glyphs/` на сервере (`glyph_subset.py` — подмножество для офлайна); текст OFL — в приложении |
| Движок карты | [MapLibre Native](https://github.com/maplibre/maplibre-native) 6.29.0 (SPM `maplibre-gl-native-distribution`), © MapLibre contributors, © MapTiler.com, © Mapbox | BSD 2-Clause + уведомления вшитых библиотек (Boost, RapidJSON, Metal-cpp — Apache 2.0, FreeType — FTL, HarfBuzz, FastPFOR — Apache 2.0, …) | бинарь в приложении; тексты — `RadarMap/Resources/Licenses/` |
| Погода на перевалах и трассах (прогноз по часам: температура, осадки, снег, видимость, ветер) | [Open-Meteo.com](https://open-meteo.com/) — «Weather data by Open-Meteo.com» | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); бесплатный API — для некоммерческого использования | `weather/roads.json` (`build_road_weather.py`, точки — `road_weather_points.json`); подпись — «Источники данных» |

## Где это видно в приложении (28.F)

- **Карта** — «i» в левом нижнем углу (в навигации — над кругом скорости) и
  подпись «© OpenMapTiles © OpenStreetMap», которая тает через 5 секунд
  (`Features/Map/Engine/MapAttribution.swift`). Касание «i» — лист со
  ссылками на openmaptiles.org и openstreetmap.org/copyright и переходом к
  «Источникам данных» и «Лицензиям». Встроенные логотип и кнопка MapLibre
  выключены: своя кнопка стоит над нашими панелями, а системная — у края
  вида карты, под нижней панелью.
- **Настройки → О приложении → «Источники данных»** — по строке на источник
  со ссылкой и названием лицензии (`DataSource` в `Models/Attribution.swift`).
- **Настройки → О приложении → «Лицензии»** — полный текст (английский
  оригинал, не переводится) лицензий MapLibre Native, OSM Bright, Noto Sans
  и ссылки на ODbL / CC BY 4.0 / CC BY-SA 4.0 (`ThirdPartyLicense`).
- **CarPlay** — только подпись на 5 секунд: окно машины не принимает
  касаний, кнопке там не место, а в шаблоне CarPlay поля для атрибуции нет.
  Лицензии доступны на телефоне.

## Что требует OpenMapTiles

- Лицензия стиля OSM Bright и схемы: продукт на тайлах OpenMapTiles должен
  заметно упоминать «OpenMapTiles» со ссылкой на https://openmaptiles.org/;
  у интерактивной карты подпись — в углу карты: «© OpenMapTiles
  © OpenStreetMap contributors». Отказ от подписи — только письменным
  разрешением MapTiler AG.
- Оформление стиля (CC BY 4.0) — упоминание «разумно доступно» с карты: строка
  OSM Bright в «Источниках данных».

## Что требуют лицензии кода и шрифтов

- **BSD 2/3-Clause** (MapLibre Native, OSM Bright): бинарная поставка
  воспроизводит копирайт, условия и отказ от гарантий «в документации или
  других материалах» — это экран «Лицензии». Тексты:
  `license-maplibre-native.txt` — LICENSE.md пакета SPM 6.29.0;
  `license-maplibre-native-ios.txt` — `platform/ios/LICENSE.md` тега
  `ios-v6.29.0` (в xcframework этих уведомлений нет, но их требуют
  BSD/MIT/Apache/FTL вшитых библиотек). **При обновлении MapLibre — заменить
  оба файла текстами новой версии.**
- **OFL 1.1** (Noto Sans): копирайт и лицензия сопровождают шрифт; имя
  «Noto» — товарный знак Google, наши глифы — подмножество диапазонов без
  переименования. Шрифт отдельно не продаётся.

## Что требует CC BY-SA 4.0

- **Указание источника** — «Данные портала открытых данных Республики
  Узбекистан (data.egov.uz), CC BY-SA 4.0». Первая строка каждого
  `egov_*.geojsonl` несёт это в поле `attribution`; в приложении — строка
  со ссылкой в «Источниках данных».
- **ShareAlike** — производные наборы (наши файлы заведений в части,
  собранной из портала) распространяются на тех же условиях. Файлы
  заведений не подписываются как «наши собственные данные».
- Изменения указываются: координаты проверены на границы Узбекистана,
  дубли схлопнуты (20 м при одном названии), название банка/гостиницы
  очищено от правовой формы. ИНН и номера сертификатов не берутся.

## Что требует CC BY 4.0 (Open-Meteo)

- **Указание источника** со ссылкой: «Weather data by Open-Meteo.com» —
  в приложении строкой со ссылкой в «Источниках данных».
- Изменения указываются: из часовых рядов выведены только флаги опасности
  (снег, гололёд, туман, ветер) с окнами времени и текущие температура и
  видимость; сами ряды не публикуются.
- Бесплатный API open-meteo — для некоммерческого использования и до 10 000
  вызовов в сутки. Приложение бесплатное и без рекламы; сборщик делает один
  запрос на все точки раз в 30 минут (13 точек — 624 вызова в сутки). Если
  приложение станет коммерческим — нужен платный ключ API.

## Что НЕ берётся

- Датасет ДТП МВД пуст (см. `update_cameras.py`, `probe_accidents`).
- Никаких наборов с персональными данными.
