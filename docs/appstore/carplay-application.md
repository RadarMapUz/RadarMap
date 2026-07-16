# Заявка на CarPlay entitlement (категория Navigation)

Подаётся с платного Apple Developer аккаунта: <https://developer.apple.com/contact/carplay/>
Выбрать категорию **Navigation (turn-by-turn)**. Ниже — готовый текст для полей формы.

## App description (EN)

> RadarMap is a driver-assistance and turn-by-turn navigation app for Uzbekistan.
> It provides its own routing engine (self-hosted OSRM over OpenStreetMap data),
> voice-guided turn-by-turn navigation in Russian and Uzbek, road speed limits,
> and proximity alerts for official traffic-enforcement cameras published by the
> Ministry of Internal Affairs of Uzbekistan.
>
> The CarPlay experience shows the app's own map with the active route,
> turn-by-turn maneuvers, current speed against the road speed limit, and
> camera proximity alerts — so drivers keep their eyes on the road instead of
> the phone. Camera data is official and legal in Uzbekistan; the app helps
> drivers comply with posted speed limits.

## Ответы на типовые вопросы формы

- **Does your app provide turn-by-turn navigation?** Yes — own OSRM routing,
  route variants, voice maneuvers (AVSpeechSynthesizer), rerouting, arrival detection.
- **Data source**: OpenStreetMap (roads, ODbL attribution included) + official
  camera dataset from mvd.uz, updated over-the-air.
- **Regions**: Uzbekistan.
- **Entitlement requested**: `com.apple.developer.carplay-maps`.

## После гранта

1. В Xcode: Signing & Capabilities → профиль обновится автоматически
   (entitlement появится в App ID в developer portal).
2. Перенести ключ `com.apple.developer.carplay-maps` из
   `RadarMap/RadarMapCarPlay.entitlements` в `RadarMap/RadarMap.entitlements`
   (сейчас ключ подключён только для сборок под симулятор — сборка на
   устройство без гранта не подписалась бы).
3. Проверка без машины: Simulator → I/O → External Displays → CarPlay.
4. Проверка в машине: подключить iPhone к BYD (кабель/беспроводно) — иконка
   RadarMap появится на экране мультимедиа.
