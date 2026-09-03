# Падение на CarPlay: nil как ключ кластера

Разбор падения, которое шло с 28 августа по 3 сентября 2026 и ни разу не
воспроизвелось на маке.

---

## 0. Улика

Отчётов `.ips` на маке нет ни одного — падало на телефоне, в машине. Но
приложение само шлёт диагностику MetricKit (`MetricsService.didReceive` →
`POST /api/metrics`, `kind='diagnostic'`), и она лежит на VPS:

```
sqlite3 /opt/radarmap/api/reports.db
  SELECT id, datetime(received,'unixepoch','+5 hours'), payload
  FROM metrics WHERE kind='diagnostic' ORDER BY received DESC;
```

**14 падений, все с одной подписью.** Сборки 38, 44, 46; iOS 26.6 и 26.6.1;
iPhone 16 Pro. Последнее — 3 сентября 06:45.

```
NSInvalidArgumentException
*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil   → SIGABRT (signal 6)
```

Кадры MapKit символизируются локально, без dSYM — по системным символам
устройства:

```
atos -o "~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 26.6 (23G71)/Symbols\
/System/Library/Frameworks/MapKit.framework/MapKit" -arch arm64e -l 0x1a483b000 <addr>
```

где `addr = 0x1a483b000 + offsetIntoBinaryTextSegment` из отчёта.

## 1. Стек

Снаружи внутрь (в JSON MetricKit дерево лежит листом вверх):

```
SwiftUI → CarPlayMapView.updateUIView
        → Coordinator.applyTarget
        → CameraMarkerView.setTarget
          → -[MKAnnotationView setDisplayPriority:]
            → -[MKAnnotationContainerView _updateAnnotationViewsForReason:updatePositions:]
              → -[MKAnnotationContainerView _updateClusterableAnnotationViews:withID:]
                → -[MKMapView annotationContainer:requestAddingClusterForAnnotationViews:]
                  → -[MKAnnotationManager addRepresentationForAnnotation:]
                    → -[MKMapView addAnnotationRepresentation:allowAnimation:]
                      → -[MKAnnotationContainerView addAnnotationView:allowAnimation:]
                        → -[MKAnnotationContainerView _existingClusterViewsForClusterID:]
                          → setObject:forKey: с nil-ключом
```

Главное в этом стеке — что `setDisplayPriority:` не «запоминает число», а
**синхронно, прямо внутри сеттера**, гонит полную пересборку групп.

## 2. Причина

```swift
clusteringIdentifier = tier == .target ? nil : "camera"   // было
```

Цель исключалась из кластеров через nil. На маркере, который MapKit уже держит
в своей кластеризации, это оставляет группу с nil-идентификатором; следующая
пересборка доходит до `_existingClusterViewsForClusterID:` и кладёт nil ключом
в словарь.

Окно, в котором маркер живёт с чужим ключом, открывала асимметрия: ключ цели
ставил `applyTier`, а возвращал его обратно только следующий пересчёт тиров в
`reloadCameras` — тот реже, чем `applyTarget`, который приходит каждый тик из
`updateUIView`.

Падало **только на CarPlay**: `CameraMarkerView`/`CarPlayMapView` в Release
больше нигде не используются (телефонный вход в `RootView` под `#if DEBUG`, сам
экран телефона — SwiftUI `Map` с `Annotation`, `MKAnnotationView` там нет).

## 3. Лечение

nil не нужен: группа собирается из ДВУХ и более маркеров с одинаковым ключом,
значит достаточно дать цели свой ключ по номеру камеры — слипаться ей не с кем.

```swift
static func clusterID(isTarget: Bool, cameraID: Int) -> String {
    isTarget ? "camera.target.\(cameraID)" : baseClusterID
}
```

Плюс три правила вокруг, без которых починка неполная:

- ключ выставляется **симметрично** — и когда цель появилась, и когда ушла;
- ключ ставится **до** `displayPriority`: пересборка групп стартует в сеттере
  важности, и к этому моменту маркер обязан числиться в правильной группе;
- присваивание — **только на изменение** (и ключа, и важности): каждое лишнее
  заставляет MapKit пересобирать группы, а `setTarget` приходит каждый тик.

`CameraClusterIDTests` сторожит обе стороны: цель вне групп, обычные маркеры —
в одной, ключ никогда не пустой.

## 4. Чего это НЕ было

Не баг рантайма с isolated deinit (см. `plan_trip_crash_cameras.md`) — тот
закрыт в сборке 14 и даёт другую подпись, «pointer being freed was not
allocated». Здесь честное исключение Objective-C из MapKit.
