---
name: quality
description: Полный проход качества RadarMap — архитектура, код-ревью, батарея, локализация, сборка и тесты на высшем уровне. Запускать перед релизом, после крупной фичи или по просьбе «проверь всё».
---

# /quality — планка качества RadarMap

Цель: после прохода проект собирается, тесты зелёные, архитектура не расползлась,
батарея не деградировала, локализация ru/uz полная. Ничего не «кажется» — всё проверено
командой или тестом.

Канон правил — `ARCHITECTURE.md` в корне. Этот скилл — его исполняемая версия.

## 0. Планка (не обсуждается)

1. **Батарея — приоритет №1.** Любой таймер, GPS-режим, повторяющаяся анимация — с обоснованием в комментарии.
2. **Тёмный радар-детекторный UI**, цвета только из `Theme`, компоненты из `DesignSystem/`.
3. **Всё пользовательское — ru + uz.** Новый ключ без uz-перевода = незаконченная работа.
4. **MV-архитектура**: View → `@Observable` модель → `nonisolated static` чистые функции. Никаких ViewModel.
5. **Файл ≤ 400 строк**, одна ответственность.

## 1. Сборка и тесты (обязательный минимум)

Только через `mcp__xcode__*` — они работают с уже открытым Xcode, переиспользуют его
состояние сборки и потому в разы быстрее на итерациях. **`xcodebuild` и другие CLI не
использовать.** Если Xcode не запущен — открыть в нём проект, а не уходить в CLI.

1. `mcp__xcode__XcodeListWindows` — **один раз в начале прохода**: даёт `tabIdentifier`
   (и заодно активную схему с destination). Все остальные вызовы принимают его.
2. `mcp__xcode__BuildProject` — сборка активной схемы, ждёт завершения.
3. `mcp__xcode__GetBuildLog` — разбор результата. `severity: "error"` — упало ли;
   потом **обязательно `severity: "warning"`**: предупреждения concurrency/deprecation
   считаются долгом, а не шумом (последний проход чинил ровно их). `pattern`/`glob`
   сужают лог до нужного файла вместо чтения всего.
4. `mcp__xcode__RunAllTests` — весь тест-план (**478 XCTest**: гео, скор, треки, лимиты,
   алерт-пайплайн, периоды, склейка и штрафы). Разбор падений — `mcp__xcode__GetTestList`
   (полный grep-friendly список в `fullTestListPath`) + `mcp__xcode__RunSomeTests` по
   конкретному классу/тесту (таргет `RadarMapTests`, идентификатор `RoadCorridorTests`
   или `RoadCorridorTests/testHighwayCorridorIsWiderThanCity`).
5. `mcp__xcode__XcodeListNavigatorIssues` — то, что висит в Issue Navigator (в том числе
   проблемы workspace/пакетов, которых нет в логе сборки).

В цикле «правлю один файл» полная сборка не нужна: `mcp__xcode__XcodeRefreshCodeIssuesInFile`
даёт живые диагностики компилятора по файлу. Чистую геометрию/стор быстрее проверить
`mcp__xcode__RunCodeSnippet` (видит `fileprivate` контекста файла), а внешний вид
экрана — `mcp__xcode__RenderPreview` по `sourceFilePath` + индексу `#Preview`.

Файлы добавлять/двигать/удалять только через `mcp__xcode__Xcode{Write,MV,RM,MakeDir}`:
они правят `.xcodeproj` и членство в таргетах, чего обычная запись в файл не делает.

**Каверза watch-таргета** (проверить, актуальна ли — `DEVELOPMENT_TEAM` в проекте уже
прописан, так что при выполненном входе в Xcode её быть не должно): без аккаунта в Xcode
сборка телефона падает на подписи RadarWatch — в `GetBuildLog` это ошибка подписи
RadarWatch, а не кода. Обход: временно отцепить embed (строки `4BFACE0A… /* Embed Watch
Content */,` и `4BFACE0D… /* PBXTargetDependency */,` в `project.pbxproj` удалить через
python-replace), собрать, затем **обязательно** `git checkout RadarMap.xcodeproj/project.pbxproj`.
Никогда не коммитить pbxproj без этих строк.

## 2. Архитектурные греп-проверки

Каждый хит — либо фикс, либо комментарий-обоснование рядом. Голых нарушений быть не должно:

```bash
# Магические числа мимо AppConfig не ловятся грепом — но эти ловятся:
grep -rn "UserDefaults.standard" RadarMap --include="*.swift" | grep -v "AppSettings\|Storage"   # УД только через Storage/AppSettings
grep -rn "URLSession.shared" RadarMap --include="*.swift" | grep -v "APIClient"                   # сеть только через APIClient
grep -rn "try? " RadarMap --include="*.swift" | grep -v "Log\.\|// "                              # try? без лога и без комментария
grep -rn 'Text(.*? "' RadarMap/Features --include="*.swift" | grep '? "'                          # тернарники литералов в Text (обход локализации)
find RadarMap RadarWatch Shared -name "*.swift" | xargs wc -l | awk '$1>400 {print}'              # файлы толще 400 строк
```

## 3. Батарея-чеклист (руками по диффу)

- Тик GPS раз в секунду: всё в `LocationService` на тике — O(малое)? Новые вычисления на тике — в грид-индекс/кэш.
- Адаптивные тиры GPS (`accuracyTier`) не сломаны? <500 м камера = Best/6м, <1500 = TenMeters/15м, крейсер = TenMeters/25м, с гистерезисом.
- `.repeatForever`-анимации — только на видимых маленьких слоях, гасятся при закрытии.
- `isIdleTimerDisabled = true` всегда парный: `onDisappear`/`endTrip` возвращает false.
- `CHHapticEngine` — `isAutoShutdownEnabled = true`; таймеры инвалидируются.
- WatchConnectivity — только квантованные значения (скорость/2, дистанция/25), без спама applicationContext.
- Замер при сомнении: `xctrace record --template 'Energy Log'` на устройстве — Instruments
  единственное, что не покрыто ни `mcp__xcode__*`, ни `ios-debugger-agent`, поэтому здесь
  CLI законен.

## 4. Локализация uz — скрипт полноты

```bash
python3 - <<'EOF'
import json
d = json.load(open("Shared/Localizable.xcstrings"))
bad = [k for k, v in d["strings"].items()
       if (u := v.get("localizations", {}).get("uz")) is None
       or u.get("stringUnit", {}).get("state") != "translated"
       or not u.get("stringUnit", {}).get("value")]
print(f"без uz: {len(bad)}"); [print(" -", k) for k in bad[:20]]
EOF
```

То же для `RadarMap/InfoPlist.xcstrings` (4 permission-строки). Ноль пропусков — иначе допереводить.

**Вторая проверка — литералы МИМО каталога.** Скрипт выше видит только ключи,
которые в каталоге уже есть; строка, которую забыли добавить, остаётся русской
на всех языках и в отчёте не всплывает (так «Прослушать оповещение» и десяток
accessibility-строк жили без перевода). Ревизия литералов кода против каталога:

```bash
python3 - <<'EOF'
import json, re, pathlib
catalog = set(json.load(open("Shared/Localizable.xcstrings"))["strings"].keys())
pattern = re.compile(
    r'(?:Text|Label|Button|String\(localized:|LocalizedStringKey|TextField|navigationTitle|accessibilityLabel\(Text|accessibilityHint\(Text|SectionHeader)\s*\(\s*"((?:[^"\\]|\\.)*)"')
missing = {}
for path in pathlib.Path("RadarMap").rglob("*.swift"):
    for m in pattern.finditer(path.read_text()):
        s = m.group(1)
        if not re.search(r'[а-яА-ЯёЁ]', s) or '\\(' in s:
            continue
        key = s.replace('\\n', '\n').replace('\\"', '"')
        if key not in catalog:
            missing.setdefault(key, str(path))
print(f"литералов мимо каталога: {len(missing)}")
[print(" -", k, "←", p) for k, p in sorted(missing.items())]
EOF
```

Строки с интерполяцией `\(…)` скрипт пропускает — их ключи в каталоге в формате
`%@`/`%lld`, проверять руками по месту.

## 5. Код-ревью веером агентов

На «проверь всё» — четыре параллельных read-only агента по зонам, каждый читает файлы
целиком и возвращает только подтверждённые находки `file:line | severity | сценарий сбоя`:

1. `Services/` + `Support/` — гонки, retain cycles, батарея, MainActor, глотание ошибок.
2. `Features/` + `DesignSystem/` — вычисления в body, незакрытые состояния, локализация, доступность.
3. `App/` + `CarPlay/` + `RadarWatch/` + `Models/` — лайфсайкл сцен, интенты, Codable-совместимость со старыми данными пользователя (переименование поля = потеря истории!), UserDefaults-дефолты.
4. `server/` + гигиена — валидация входа API, секреты в репо, .gitignore, полнота uz, дыры в тестах.

Каждую severity ≥ major находку **перепроверить чтением кода самому** до фикса: в проекте
много осознанных решений с комментариями-обоснованиями, агенты их иногда принимают за баги.

## 6. Смоук на симуляторе (DEBUG-хуки)

Запуск и вождение приложения — единственное, чего `mcp__xcode__*` не умеет: для этого
скилл **`ios-debugger-agent`** (XcodeBuildMCP) — он собирает, ставит на загруженный
симулятор, запускает **с аргументами**, снимает скриншоты и отдаёт логи. `xcrun simctl`
руками не нужен.

Экраны открываются DEBUG-хуками из `ProcessInfo.processInfo.arguments` вместо тапов.
Актуальный список брать из кода (он растёт быстрее этого файла):

```bash
grep -rhno '"-[a-zA-Z]*"' RadarMap | grep -o '"-[a-zA-Z]*"' | sort -u | tr -d '"'
```

Ключевые: `-skipAlwaysPrompt` (без него висит системный запрос гео и скриншот пустой),
`-demoHistory` / `-demoHistoryOld` (засеять историю — без неё Итоги пустые),
`-showStats`, `-showMonth`, `-showPeriodMap`, `-openFirstTrip`, `-showRatingInfo`,
`-showSavingsInfo`, `-showSettings`, `-showCameraDetail`, `-demoRoute` / `-driveDemo`,
`-rotateMap`, `-quickToggles`, `-mapMenu`, `-reportPicker`, `-askDriver`,
`-carplayPreview`, `-endTripAfter N`, `-dumpShareCards` (карточки шеринга в PNG),
`-hideCameraAlert` (чистые кадры turn-by-turn для заявки CarPlay).

Минимум прохода: главный экран (компас, glass-кнопки), Итоги с историей, отчёт за
период, карточка камеры, демо-маршрут (баннер манёвра + HUD), CarPlay-превью.
Скриншоты смотреть глазами, не только exit code: половина регрессий этого раздела —
«кнопка есть, но белым по белому».

## 7. Финал

- Каждый фикс из ревью — с тестом, если логика чистая (в `RadarMapTests`, XCTest);
  прогонять точечно `mcp__xcode__RunSomeTests`, а перед коммитом — `RunAllTests` целиком.
- Перед коммитом `GetBuildLog` с `severity: "warning"` должен быть пуст по затронутым файлам.
- Коммиты небольшие, по-русски, в стиле репо («Компас: …», «CarPlay: …»); пушить в main.
- Новые правила, всплывшие в ревью, — дописывать в `ARCHITECTURE.md`, а не только чинить точечно.
- Секреты (VPS-пароль) не писать никуда; SSH на прод не ходить — деплой запускает пользователь.
