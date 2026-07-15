//
//  LocationService.swift
//  RadarMap
//
//  Батареесберегающая геолокация + гибридный режим для HUD и голосовых предупреждений.
//
//  ФОН (почти без GPS): significant-location-change будит приложение ~каждые 500 м;
//  на смещение > retileDistance пересчитываем 20 ближайших камер и вешаем CLCircularRegion
//  (лимит iOS — 20). Въезд в радиус детектит система → локальное уведомление.
//
//  ПЕРЕДНИЙ ПЛАН (приложение открыто): точные обновления → скорость и живое расстояние для HUD,
//  а также движок голосовых предупреждений с порогами (эскалация сигналов по мере приближения).
//

import Foundation
import CoreLocation
import Observation
import UIKit

@MainActor
@Observable
final class LocationService: NSObject {
    private let manager = CLLocationManager()
    private let repository: CameraRepository
    private let notifier: NotificationService
    private let settings: AppSettings
    private let alerts: AlertPlayer
    private let trip: TripStats
    /// Live Activity на локскрине (подключается после инициализации, см. AppEnvironment).
    @ObservationIgnored weak var liveActivity: LiveActivityService?
    @ObservationIgnored weak var route: RouteService?
    @ObservationIgnored weak var speedLimits: SpeedLimitService?

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var speedKmh: Double = 0
    /// GPS-курс движения (0–360°, −1 = недостоверен: стоим или нет сигнала).
    private(set) var currentCourse: CLLocationDegrees = -1
    private(set) var nearbyCameras: [Camera] = []
    private(set) var nearestCamera: Camera?
    private(set) var distanceToNearest: CLLocationDistance?
    /// false = пользователь дал только «приблизительную» геолокацию — оповещения ненадёжны.
    private(set) var hasFullAccuracy = true
    /// Режим энергосбережения iOS: снижаем точность GPS и отключаем голос.
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Режим «Поездка»: непрерывная геолокация + активные оповещения даже в свёрнутом виде.
    private(set) var isTripActive = false

    @ObservationIgnored private var anchor: CLLocation?
    @ObservationIgnored private var alertedCameraIDs: Set<Int> = []   // фон, дебаунс уведомлений
    @ObservationIgnored private var announcedLevel: [Int: Int] = [:]  // передний план, эскалация
    /// Отслеживание прохождения: минимальная дистанция и скорость в ней, по каждой камере в зоне.
    @ObservationIgnored private var passTracking: [Int: (camera: Camera, minDist: Double, speedAtMin: Double)] = [:]
    @ObservationIgnored private var isForeground = false

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    init(repository: CameraRepository, notifier: NotificationService,
         settings: AppSettings, alerts: AlertPlayer, trip: TripStats) {
        self.repository = repository
        self.notifier = notifier
        self.settings = settings
        self.alerts = alerts
        self.trip = trip
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .automotiveNavigation
        hasFullAccuracy = manager.accuracyAuthorization == .fullAccuracy

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor in self?.powerModeChanged(low) }
        }
    }

    private func powerModeChanged(_ low: Bool) {
        isLowPowerMode = low
        applyLocationMode()
    }

    // MARK: - Разрешения / запуск

    func bootstrap() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            startBackgroundMonitoring()
        case .authorizedAlways:
            startBackgroundMonitoring()
        default:
            break
        }
    }

    private func startBackgroundMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    // MARK: - Режимы геолокации

    /// Приложение открыто/свёрнуто. Точный GPS для HUD держим, только пока открыто и НЕ в поездке.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        applyLocationMode()
    }

    /// Начать поездку: непрерывная геолокация + активные оповещения даже в свёрнутом виде.
    func startTrip() {
        guard isAuthorized else { return }
        isTripActive = true
        announcedLevel.removeAll()
        passTracking.removeAll()
        trip.begin()
        applyLocationMode()
        liveActivity?.startIfNeeded(state: activityState)
    }

    /// Завершить поездку: сохранить итоги и вернуться к батареесберегающему фону.
    func endTrip() {
        isTripActive = false
        announcedLevel.removeAll()
        // Зафиксировать камеры, мимо которых ещё «проезжали» в момент остановки.
        for (_, t) in passTracking { trip.registerPass(camera: t.camera, speedKmh: t.speedAtMin) }
        passTracking.removeAll()
        trip.finish()
        // Припарковались у цели — маршрут выполнен, линия не должна висеть на карте.
        route?.finishIfNearDestination(coordinate: currentCoordinate)
        applyLocationMode()
        liveActivity?.end()
    }

    /// Единая точка выбора режима GPS исходя из (поездка, открыто ли приложение, энергосбережение).
    private func applyLocationMode() {
        guard isAuthorized else { return }
        guard isTripActive || isForeground else {
            // Тихий фон: непрерывный GPS выключен, работают SLC + геозоны (будят на уведомление).
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            return
        }
        if isTripActive {
            // Поездка: высокая точность, разрешаем работу в фоне (нужен доступ «Всегда»).
            manager.desiredAccuracy = isLowPowerMode ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
            manager.distanceFilter = isLowPowerMode ? 20 : 5
            manager.allowsBackgroundLocationUpdates = (manager.authorizationStatus == .authorizedAlways)
            manager.showsBackgroundLocationIndicator = true
        } else {
            // Просто открытое приложение: точный GPS для HUD, фон не держим.
            manager.desiredAccuracy = isLowPowerMode ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = isLowPowerMode ? 50 : 10
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
        }
        manager.startUpdatingLocation()
    }

    /// Адаптивный GPS в поездке: далеко от камер и манёвров сантиметровая точность не нужна —
    /// чип GPS работает мягче, батарея живёт дольше. Ближе 3 км всё возвращается к максимуму.
    private func tuneAdaptiveAccuracy() {
        guard isTripActive, settings.adaptiveGPS, !isLowPowerMode else { return }
        let cameraDistance = distanceToNearest ?? .greatestFiniteMagnitude
        let stepDistance = (route?.isActive == true && route?.nextStep != nil)
            ? (route?.nextStepDistance ?? .greatestFiniteMagnitude)
            : .greatestFiniteMagnitude
        if min(cameraDistance, stepDistance) > 3000 {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 30
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5
        }
    }

    /// Попросить точную геопозицию на эту сессию (если дана «приблизительная»).
    func requestPreciseLocation() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "CameraAlerts")
    }

    /// Пересобрать мониторинг вокруг текущей позиции (после добавления/скрытия камеры или смены радиуса).
    func refreshMonitoring() {
        anchor = nil
        if let coordinate = currentCoordinate { retile(around: coordinate) }
    }

    // MARK: - Пере-тайлинг 20 ближайших

    private func retileIfNeeded(around coordinate: CLLocationCoordinate2D) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Пустой nearbyCameras = данные ещё не загрузились на прошлом тайлинге — пробуем снова.
        if let anchor, !nearbyCameras.isEmpty,
           anchor.distance(from: location) < AppConfig.retileDistance { return }
        anchor = location
        retile(around: coordinate)
    }

    private func retile(around coordinate: CLLocationCoordinate2D) {
        manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }

        let nearest = repository.nearest(to: coordinate, limit: AppConfig.maxMonitoredRegions)
        nearbyCameras = nearest
        alertedCameraIDs.formIntersection(Set(nearest.map(\.id)))

        for camera in nearest {
            let region = CLCircularRegion(
                center: camera.coordinate,
                radius: settings.alertRadius,
                identifier: Self.regionID(for: camera.id)
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    // MARK: - Обработчики (MainActor)

    /// Растёт на каждое обновление локации — карта в режиме следования подписывается на это.
    private(set) var locationTick = 0
    @ObservationIgnored private var lastSpeedTickAt: Date?

    private func handleLocation(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, course: CLLocationDirection) {
        currentCoordinate = coordinate
        // Спидометр без дёрганья: GPS-скорость шумит (68→71→69) — лёгкое экспоненциальное
        // сглаживание, но только по свежим точкам (после паузы берём сырое значение).
        let rawKmh = max(0, speed) * 3.6
        if let lastAt = lastSpeedTickAt, Date().timeIntervalSince(lastAt) < 5 {
            let smoothed = speedKmh * 0.6 + rawKmh * 0.4
            speedKmh = smoothed < 1 ? 0 : smoothed
        } else {
            speedKmh = rawKmh
        }
        lastSpeedTickAt = Date()
        currentCourse = course
        locationTick &+= 1
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate)

        // Активные оповещения (звук/голос/экран) — в поездке ИЛИ пока приложение открыто.
        if isTripActive || isForeground {
            trip.update(coordinate: coordinate, speedKmh: speedKmh)
            updatePassTracking(from: coordinate)
            runAlertEngine()
            // Лимит дороги + превышение; манёвры и прогресс маршрута.
            // Здесь, а не в UI: голос должен работать со свёрнутым приложением.
            speedLimits?.update(coordinate: coordinate, course: course,
                                speedKmh: speedKmh, announce: isTripActive)
            route?.updateProgress(coordinate: coordinate, cameras: repository.cameras,
                                  announce: isTripActive)
            tuneAdaptiveAccuracy()
        }
        // Live Activity живёт только в поездке; update — no-op, если она не запущена.
        liveActivity?.update(state: activityState)
    }

    /// Текущее состояние для Live Activity.
    var activityState: CameraActivityAttributes.ContentState {
        CameraActivityAttributes.ContentState(
            nearestTitle: nearestCamera?.displayTitle,
            nearestSymbol: nearestCamera?.kind.symbolName ?? "checkmark.shield.fill",
            distanceMeters: distanceToNearest,
            camerasNearby: nearbyCameras.count
        )
    }

    /// Фильтр направления активен, когда едем достаточно быстро и GPS-курс достоверен.
    var isDirectionalFilteringActive: Bool {
        currentCourse >= 0 && speedKmh >= AppConfig.directionalMinSpeedKmh
    }

    /// Камера «по курсу» — в секторе ±directionalMaxAngle относительно направления движения.
    private func isAhead(_ camera: Camera, from coordinate: CLLocationCoordinate2D) -> Bool {
        guard isDirectionalFilteringActive else { return true }   // стоим/курс неизвестен → не фильтруем
        let bearing = GeoMath.bearing(from: coordinate, to: camera.coordinate)
        return GeoMath.angleDifference(bearing, currentCourse) <= AppConfig.directionalMaxAngle
    }

    /// Азимут ближайшей камеры относительно курса (0 = прямо по ходу, 90 = справа, 270 = слева).
    var relativeBearingToNearest: Double? {
        guard isDirectionalFilteringActive,
              let camera = nearestCamera,
              let coordinate = currentCoordinate else { return nil }
        let bearing = GeoMath.bearing(from: coordinate, to: camera.coordinate)
        return (bearing - currentCourse + 360).truncatingRemainder(dividingBy: 360)
    }

    /// «впереди» / «впереди справа» / «впереди слева» — для голосового предупреждения.
    private var directionPhrase: String {
        guard let rel = relativeBearingToNearest else { return "впереди" }
        switch rel {
        case ..<25, 335...: return "впереди"
        case 25..<90:       return "впереди справа"
        case 270..<335:     return "впереди слева"
        default:            return "впереди"
        }
    }

    private func recomputeNearest(from coordinate: CLLocationCoordinate2D) {
        guard !nearbyCameras.isEmpty else {
            nearestCamera = nil; distanceToNearest = nil; return
        }
        // В движении HUD показывает ближайшую камеру ВПЕРЕДИ; камеры позади не пугают зря.
        let candidates = nearbyCameras.filter { isAhead($0, from: coordinate) }
        let ranked = candidates
            .map { ($0, $0.distance(from: coordinate)) }
            .min { $0.1 < $1.1 }
        nearestCamera = ranked?.0
        distanceToNearest = ranked?.1
    }

    /// Фиксация скорости прохождения — как у настоящего радара: скорость в точке
    /// максимального сближения (траверз камеры), а не на подходе.
    private func updatePassTracking(from coordinate: CLLocationCoordinate2D) {
        let radius = effectiveAlertRadius
        // Вошли в радиус камеры впереди — начинаем следить.
        if let camera = nearestCamera, let distance = distanceToNearest,
           distance <= radius, passTracking[camera.id] == nil {
            passTracking[camera.id] = (camera, distance, speedKmh)
        }
        // Точку сближения обновляем для ВСЕХ отслеживаемых: после проезда камера уходит
        // из «ближайших впереди» (направленный фильтр), но траверз ещё не пройден.
        for (id, entry) in passTracking {
            var tracked = entry
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                tracked.camera.lat, tracked.camera.lon)
            if distance < tracked.minDist {
                tracked.minDist = distance
                tracked.speedAtMin = speedKmh
                passTracking[id] = tracked
            } else if distance > radius + 120 {
                // Отъехали — «пройдено» со скоростью в момент проезда.
                trip.registerPass(camera: tracked.camera, speedKmh: tracked.speedAtMin)
                passTracking.removeValue(forKey: id)
            }
        }
    }

    /// Умный радиус: предупреждаем за `alertLeadTimeSeconds` до камеры.
    /// Радиус растёт со скоростью (на трассе — раньше), но не опускается ниже базового из настроек.
    private var effectiveAlertRadius: CLLocationDistance {
        let bySpeed = (speedKmh / 3.6) * AppConfig.alertLeadTimeSeconds
        return min(AppConfig.maxDynamicRadius, max(settings.alertRadius, bySpeed))
    }

    /// Показывать полноэкранное предупреждение: движемся и ближайшая камера в радиусе оповещения.
    var isApproachingCamera: Bool {
        guard let d = distanceToNearest, speedKmh >= AppConfig.directionalMinSpeedKmh else { return false }
        return d <= effectiveAlertRadius
    }

    /// Пороги приближения (передний план): чем ближе — тем больше сигналов; голос — на первом пороге.
    /// nearestCamera уже отфильтрована по курсу: о камерах позади и на встречных
    /// перпендикулярных улицах не предупреждаем (начатая серия порогов не обрывается).
    private func runAlertEngine() {
        guard let camera = nearestCamera, let distance = distanceToNearest else { return }
        let radius = effectiveAlertRadius
        let thresholds = [radius, radius * 0.6, radius * 0.3]   // по убыванию
        let level = thresholds.filter { distance <= $0 }.count
        let previous = announcedLevel[camera.id] ?? 0

        if distance > radius + 80 {          // вышли из зоны (с гистерезисом)
            announcedLevel[camera.id] = 0
            return
        }
        guard level > previous else { return }
        announcedLevel[camera.id] = level

        if settings.soundEnabled { alerts.beep(count: level) }
        if level == 1 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            // В свёрнутом виде (поездка в фоне) — уведомление зажигает экран и вибрирует.
            if !isForeground { notifier.notifyApproaching(camera) }
            // Голос — самая дорогая часть оповещения, в энергосбережении пропускаем.
            if settings.voiceEnabled && !isLowPowerMode {
                var phrase = "\(camera.kind.displayName) \(directionPhrase). \(Int(distance)) метров"
                if speedKmh >= AppConfig.speakSpeedThresholdKmh {
                    phrase += ". Ваша скорость \(Int(speedKmh.rounded()))"
                }
                alerts.speak(phrase)
            }
        }
    }

    private func handleEnter(regionID: String) {
        // В поездке оповещает движок по точному расстоянию — геозона не нужна (без дублей).
        guard !isTripActive else { return }
        guard let id = Self.cameraID(from: regionID),
              !alertedCameraIDs.contains(id),
              let camera = repository.cameras.first(where: { $0.id == id }) else { return }
        alertedCameraIDs.insert(id)
        notifier.notifyApproaching(camera)
        if !isForeground {
            liveActivity?.update(state: CameraActivityAttributes.ContentState(
                nearestTitle: camera.displayTitle,
                nearestSymbol: camera.kind.symbolName,
                distanceMeters: settings.alertRadius,
                camerasNearby: nearbyCameras.count
            ))
        }
    }

    private func handleExit(regionID: String) {
        guard let id = Self.cameraID(from: regionID) else { return }
        alertedCameraIDs.remove(id)
    }

    private func handleAuthChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        hasFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        switch status {
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            startBackgroundMonitoring()
            applyLocationMode()
        case .authorizedAlways:
            startBackgroundMonitoring()
            applyLocationMode()
        default:
            break
        }
    }

    // MARK: - Идентификаторы регионов

    private static func regionID(for cameraID: Int) -> String { "camera-\(cameraID)" }
    private static func cameraID(from identifier: String) -> Int? {
        let prefix = "camera-"
        guard identifier.hasPrefix(prefix) else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        let speed = location.speed
        let course = location.course
        Task { @MainActor in self.handleLocation(coordinate: coordinate, speed: speed, course: course) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.handleEnter(regionID: id) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.handleExit(regionID: id) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handleAuthChange(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}
