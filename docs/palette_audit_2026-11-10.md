# Аудит палитры, 10.11.2026

Просьба владельца: «палитру единую красивую сделать». Действующая палитра не
менялась: интерфейс — «Строгий навигатор» (31D, 27.10), карта — «Б — Чистый»
(28.A), пробки — «Сигнал» (33H3), маркеры — «Спокойная карта» (вариант B).
Задача — чтобы всё приложение реально на ней стояло.

## Итог

| | было | стало |
|---|---|---|
| Сырые конструкторы цвета вне `DesignSystem/` (`Color(red:`, `UIColor(red:`, `rgb(0x…)`) | 16 | 2 (исключения линта) |
| Числовые цвета вне `DesignSystem/` (без белого) | 31 | 13 (палитра карты, см. ниже) |
| Hex-строки в стиле движка, написанные руками | 10 | 7 (палитра карты, см. ниже) |
| Системные цвета мимо токенов (`.green`, `.purple`, `.gray`, `.lightGray`, `.darkGray`, серый 0,12) | 6 | 0 |

Один источник чисел — `Shared/WidgetPalette.swift`: из него берут Theme
(приложение), виджеты и часы. Сырой цвет вне `DesignSystem/` ловит
`UnifiedPaletteTests.testNoRawColoursRemainInSources`.

## Место → цвет → токен

| Место | Было | Стало |
|---|---|---|
| `EngineMapView` флаг цели, булавка, «машина здесь» | `#2563D9` (Tailwind blue-600, ушёл с 31D) | `MapIconColors.accentFill` = `Theme.accentFill` дня `#0B62D0` |
| `EnginePlaceIcons` / `EngineMapDetail` парковка | `#2563D9` | `MapIconColors.accentFill` |
| `EnginePlaceIcons` / `EngineMapDetail` заправка, места | `#3B4047` | `MapIconColors.graphite` (то же число — его рисует и спрайт `make_arrows.py`) |
| `EngineMapView` светофор: корпус / огни | `UIColor(red: 0.23…)`, `UIColor(red: 0.85…)` | `MapIconColors.graphite` / `.signalDot` (те же числа) |
| `EngineMapView` знак STOP | `UIColor(red: 0.64, 0.23, 0.22)` | `MapIconColors.stopSign` `#A33B38` (своя роль: знак, ΔE 32 от камеры) |
| `EngineMapView` значок «?» призрака | `#46525E` | `MapIconColors.ghost` = `CameraGlyph.post` |
| `EngineMapView` значок «своя камера» | `#177A41` | `MapIconColors.success` = `Theme.successFill` дня |
| `EngineMapView` перекрытие | `#C2410C` (ΔE 15 от красного камеры — та же ошибка, что «серия» до 31D) | `MapIconColors.warning` = `Theme.warning` дня `#9A5800` |
| `EngineMapView` ремонт | `#9C5300` (почти-дубль warning, ΔE 3,8) | `MapIconColors.warning` |
| `EngineMapView` метан: газ есть / нет / только очередь | `#1E8E3E` / `#4B5563` / `#B45309` | `.success` / `.graphite` / `.warning` |
| `EngineMapView` подпись метана | `UIColor(white: 0.12)` | `MapIconColors.ink` = `textPrimary` дня |
| `EngineMapView.colorExpression` | `UIColor(red:…)` из hex | `Theme.rgb` |
| `EngineRouteVariants` пилюля времени: текст / заливка выбранного / заливка другого | `#111827`/`#F1F4F8`, `#2563D9`/`#2A62D6`, `#FFFFFF`/`#1E232A` | `textPrimary`, `accentFill`, `surface` (обе темы) |
| `EngineLaneFocus.colour` | `UIColor(red:…)` | `Theme.rgb` |
| `EngineMapStyle` зона треноги | `"#F2B200"` (почти-дубль ночного warning ΔE 7,8 и жёлтого действия) | ночной `warning` `#FFB020` |
| `EngineMapStyle` ореол тревоги | `"#D93025"` руками | `CameraGlyph.camera.fillRGB` |
| `EngineMapStyle` точка камеры без цвета | `"#6B6B70"` | `CameraMarkerLook.neutralDay` (графит спокойной камеры) |
| `EngineCarDecor` «Ограничение через N м» | `Color(red: 0.11, 0.12, 0.14)` | `Theme.textPrimary` (плашка закреплена светлой) |
| `CompassRing.northRGB` | `#6BA3FF` (ΔE 2,2 от ночного accent) | `WidgetPalette.accent.dark` `#5FA2FF` |
| `Drive3D` лента днём / ночью | `#0A5FD8` / `#2B63C0` (ΔE 7 от своих токенов) | `RouteColors.body.day` `#0B62D0` / `accentFill` ночи `#1E5DC4` |
| `CameraZone` лента днём | `#E5372B` (ΔE 3,5 от красного камеры) | `CameraGlyph.camera.fillRGB` `#D93025` |
| `CameraMarkerLook.calmNightInkRGB` | `#14181D` руками | `WidgetPalette.alertSurface` |
| `TripMapSnapshot` трек / камера в лимите / подложка | `#4DA3FF`, `#3BE3B0` (мятный «Итогов»), `#0E1014` | ночной `route` `#66A3FF`, ночной `success` `#4CC27A` (в лимите = норма), `alertSurface` |
| `Theme.Stats.ringGround` (календарь колец) | `#0E1014` (ΔE 3,8 от `alertSurface`) | `alertSurface` `#14181D` |
| `Theme.Types.intelligent` → `PeriodShareCard` «время» | `#6A3FD6` (бывший цвет типа камеры) | токен удалён, «время» — `Theme.Icon.time` (как на всех экранах) |
| `ItogiRingsCalendar` запасные цвета легенды | `.green`, `.purple` | `Theme.success`, `Theme.Stats.commute` |
| `PeriodExportPDF` заголовки, линия, подвал | `.darkGray`, `.lightGray`, `.gray` | `textSecondary`/`textTertiary` дня |
| `RadarWatch` `WatchTheme`, `WatchHUDView`; `NextCameraComplication`; виджет `SW` | свои функции `Color(red:)`/`UIColor(red:)` из hex | `WidgetPalette.color(_:)` |

## Изменённые значения токенов

Только ночь колец «Итогов» и виджета — насыщенность OKLCH снижена до 0,165
при той же светлоте и тоне. Причина — «ночь не кислотная»: концы были
0,20–0,25, кислотнее красного камеры (0,19) и всех состояний (≤ 0,165).

| Токен | Было (ночь) | Стало (ночь) | День |
|---|---|---|---|
| `ringRisk` | `#FF5C7A`, `#E0218A` | `#F16B80`, `#C94F88` | не менялся |
| `ringRoad` | `#B49CFF`, `#6C4DFF` | `#B49CFF`, `#6B63D2` | не менялся |

Контраст колец к ночной карточке остаётся ≥ 3:1 (3,4–5,6), к подложке
календаря — выше.

## Новые токены

`MapIconColors` (Theme.swift, числами — значки движка рисуются в UIKit, один
растр на обе темы). Пять из семи — ссылки на токены Theme; свои роли только у
двух: `graphite` (число совпадает со спрайтом выпуска) и `stopSign`.

## Что осталось числами и почему

- `HorizonHaze` (дымка горизонта), `EngineModernStyle.labelHex/haloHex`,
  разметка полос и зебры в `EngineMapStyle`, `AppConfig.carPlayCameraLabelDay`,
  `Drive3D` кант — палитра карты 28.A; её источник — `server/omt/make_style.py`
  и `MapPalette`, проверки — `palette_check.py`, `CarMapStyleTests`.
- `CameraMarkerLook.neutralDay/Night` — графит спокойной камеры, правило
  маркеров «цвет = на нашем пути» (не трогали).
- `CameraZone` ночью `#FF5A4E` — своя роль (лента камеры на тёмном асфальте),
  не почти-дубль: ΔE 18 от ночного `danger`.
- `RadarMap/Resources/MapStyle/*.json` — генерируются `make_style.py`; синий
  ореол «P» там `#2563D9`, но приложение подменяет этот слой своим значком.
- Белый и чёрный с прозрачностью (кромки, тени, знак на заливке, циферблат
  часов) — не оттенок, токен не нужен.
- `CPTimeRemainingColor .green/.orange/.red` — значения API CarPlay, цвет
  выбирает система.

## Исключения линта

`DesignSystem/` (там живут токены), `Shared/WidgetPalette.swift` (числа →
`Color` для виджетов и часов), `Cursor3D.swift` и `CursorRacers.swift`
(рисунки курсоров).

## На согласование (не правилось)

- Дневной «медленно» пробок `#BB731E` при дейтеранопии неотличим от красного
  камеры (ΔE 5). Разводит форма (линия против диска с глифом); цвет — выбор
  владельца 28.10.
- `signRed` `#D90D1A` (кант знака ограничения) на ΔE 7,7 от красного камеры —
  знак рисуется «как на столбе», показан только в HUD.
- Светофор `#3B4047` на ΔE 4 от графита спокойной камеры `#3D4652` — разводит
  форма (капсула против диска).
- Дневной фиолетовый «Итогов» (`Stats.commute` `#5B3DF5`, C 0,255) насыщеннее
  красного камеры. Снижение до 0,19 приблизило бы его к синему интерфейса
  (ΔE 19) — оставлен.

## Снять «до/после»

Карта с флагом цели и булавкой долгого тапа; выбор маршрута (пилюли времени
выбранного и другого варианта, день и ночь); заправки/парковки и метан;
перекрытие и ремонт; зона «здесь часто ставят треногу»; компас машины;
«Вождение 3D» днём и ночью; календарь колец «Итогов» (ночные кольца риска и
пробега); карточка поездки для шеринга (трек и камеры); виджет недели ночью.
