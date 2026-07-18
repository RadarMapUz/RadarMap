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

```bash
# Юнит-тесты (55+ XCTest, чистые функции: гео, скор, треки, лимиты)
xcodebuild test -project RadarMap.xcodeproj -scheme RadarMap \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet

# Сборка телефона на симулятор
xcodebuild -project RadarMap.xcodeproj -scheme RadarMap \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -quiet
```

**Каверза watch-таргета**: пока в Xcode не выполнен вход в аккаунт, сборка телефона
падает на подписи RadarWatch. Временно отцепить embed (строки `4BFACE0A… /* Embed Watch
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
- Замер при сомнении: `xctrace record --template 'Energy Log'` на устройстве.

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

```bash
# UDID актуального сима: xcrun simctl list devices | grep Booted
# Хуки: -showStats -showSettings -showCameraDetail -demoRoute -driveDemo
#       -shareStats -carplayPreview -rotateMap -skipAlwaysPrompt -endTripAfter N
xcrun simctl launch <UDID> uz.rasul.radarmap -demoRoute -skipAlwaysPrompt
xcrun simctl io <UDID> screenshot /tmp/smoke.png
```

Минимум: главный экран (компас, glass-кнопки), Итоги (`-showStats`), карточка камеры,
демо-маршрут (баннер манёвра + HUD). Скриншоты смотреть глазами, не только exit code.

## 7. Финал

- Каждый фикс из ревью — с тестом, если логика чистая (в `RadarMapTests`, XCTest).
- Коммиты небольшие, по-русски, в стиле репо («Компас: …», «CarPlay: …»); пушить в main.
- Новые правила, всплывшие в ревью, — дописывать в `ARCHITECTURE.md`, а не только чинить точечно.
- Секреты (VPS-пароль) не писать никуда; SSH на прод не ходить — деплой запускает пользователь.
