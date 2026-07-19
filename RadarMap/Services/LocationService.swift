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
import AVFAudio
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
    @ObservationIgnored weak var watchBridge: WatchBridgeService?
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
    /// Пороги приближения (передний план): чистый движок, покрыт тестами.
    @ObservationIgnored private var alertEngine = AlertEngine()
    /// Учёт прохождения камер (траверз + зона измерения): чистый модуль, покрыт тестами.
    @ObservationIgnored private var passTracking = PassTracking()
    /// Детектор «город/трасса» для умного режима оповещений (чистый, покрыт тестами).
    @ObservationIgnored private var contextDetector = AlertPolicy.Detector()
    /// Камер в радиусе 3 км — сигнал плотности для детектора (пересчёт на ретайле).
    @ObservationIgnored private var cameraDensity3km = 0
    /// Текущий контекст для чипа на HUD (в режиме «Авто»).
    private(set) var alertContext: AlertPolicy.Context = .city
    // Два независимых «передних плана»: телефонная сцена и CarPlay. Один флаг
    // они затирали друг другу (блокировка телефона в машине замораживала HUD CarPlay,
    // а отключение CarPlay в фоне навсегда оставляло «передний» режим GPS).
    @ObservationIgnored private var isPhoneForeground = false
    @ObservationIgnored private var isCarPlayConnected = false
    private var isForeground: Bool { isPhoneForeground || isCarPlayConnected }

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
            #if DEBUG
            // Скриншот-автоматизация: симулятор показывает диалог апгрейда «Всегда»
            // на каждом запуске и перекрывает экран — в тестовых прогонах не просим.
            if !ProcessInfo.processInfo.arguments.contains("-skipAlwaysPrompt") {
                manager.requestAlwaysAuthorization()
            }
            #else
            manager.requestAlwaysAuthorization()
            #endif
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

    /// Координата для интентов (холодный старт из Siri: bootstrap не выполнялся,
    /// currentCoordinate пуст) — просим одноразовый фикс и ждём его до `timeout`.
    func awaitCoordinate(timeout: TimeInterval = 5) async -> CLLocationCoordinate2D? {
        if let currentCoordinate { return currentCoordinate }
        guard isAuthorized else { return nil }
        manager.requestLocation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let currentCoordinate { return currentCoordinate }
            await Task.pause(seconds: 0.2)
        }
        return currentCoordinate
    }

    /// Телефонная сцена открыта/свёрнута. Точный GPS для HUD держим, только пока открыто и НЕ в поездке.
    func setForeground(_ foreground: Bool) {
        isPhoneForeground = foreground
        // Открыли приложение — «камерный» баннер из фона больше не нужен (внутри есть свой алерт).
        if foreground { notifier.clearApproaching() }
        applyLocationMode()
    }

    /// Экран в машине подключён/отключён — самостоятельный «передний план»,
    /// не зависящий от того, заблокирован ли телефон в кармане.
    func setCarPlayConnected(_ connected: Bool) {
        isCarPlayConnected = connected
        applyLocationMode()
    }

    /// Настройки сменили GPS-политику (например, тумблер адаптивности) — применить сразу,
    /// не дожидаясь следующей смены состояния поездки.
    func refreshLocationMode() {
        applyLocationMode()
    }

    /// Пассажирская сессия («я в такси»): автостарт молчит до конца этой езды.
    private(set) var isPassengerSession = false

    /// Начать поездку. `auto` — старт от CoreMotion: в незнакомой машине зададим
    /// вопрос «вы за рулём?» (в своей — CarPlay/знакомая магнитола — молча).
    func startTrip(auto: Bool = false) {
        guard isAuthorized else { return }
        if auto, isPassengerSession { return }   // пассажир уже сказал своё слово
        if !auto { isPassengerSession = false }  // ручной старт — точно за рулём
        isTripActive = true
        lastMovementAt = Date()   // не проваливаться в тир «стоянка» со старым штампом
        // Телефон в держателе — экран не гаснет всю поездку (как у навигаторов).
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        alertEngine.reset()
        passTracking.reset()
        trip.begin()
        applyLocationMode()
        liveActivity?.startIfNeeded(state: activityState)
        if auto, !isDriverRecognized { notifier.askDriverCheck() }
    }

    /// Своя машина: CarPlay подключён или знакомая автомобильная магнитола (BT).
    private var isDriverRecognized: Bool {
        if isCarPlayConnected { return true }
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .carAudio
                || ((output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP)
                    && settings.knownCarAudio.contains(output.portName))
        }
    }

    /// «Я за рулём» (кнопка или тап по вопросу): запоминаем магнитолу этой машины —
    /// в следующий раз не переспросим.
    func confirmDriver() {
        notifier.clearDriverCheck()
        for output in AVAudioSession.sharedInstance().currentRoute.outputs
        where output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP {
            if !settings.knownCarAudio.contains(output.portName) {
                settings.knownCarAudio.append(output.portName)
            }
        }
    }

    /// «Я пассажир»: свернуть поездку без следа в истории и молчать до конца езды.
    func markPassenger() {
        notifier.clearDriverCheck()
        isPassengerSession = true
        if isTripActive { endTrip(asPassenger: true) }
    }

    /// Езда закончилась (CoreMotion): следующая поездка — с чистого листа.
    func endPassengerSession() {
        isPassengerSession = false
    }

    /// Завершить поездку: сохранить итоги и вернуться к батареесберегающему фону.
    /// `asPassenger` — «я в такси»: короткий кусок не пишем в историю вовсе.
    func endTrip(asPassenger: Bool = false) {
        isTripActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        alertEngine.reset()
        notifier.clearDriverCheck()   // вопрос «вы за рулём?» больше не актуален
        if asPassenger {
            _ = passTracking.flush()   // пассажирские «проезды» не считаем
            if trip.distanceMeters < 500 { trip.cancel() } else { trip.finish() }
        } else {
            // Камеры, мимо которых ещё «проезжали» в момент остановки.
            register(passes: passTracking.flush())
            trip.finish()
            // Припарковались у цели — маршрут выполнен, линия не должна висеть на карте.
            route?.finishIfNearDestination(coordinate: currentCoordinate)
        }
        applyLocationMode()
        liveActivity?.end()
        notifier.clearApproaching()   // конец поездки — убрать висящий баннер камеры
        // Часы сразу в «ожидание», не дожидаясь следующего GPS-тика.
        watchBridge?.update(isTripActive: false, speedKmh: 0, cameraTitle: nil,
                            distanceMeters: nil, alertLevel: 0)
    }

    private func register(passes: [PassTracking.Pass]) {
        for pass in passes {
            trip.registerPass(camera: pass.camera, speedKmh: pass.speedKmh,
                              limitKmh: pass.limitKmh)
        }
    }

    /// Единая точка выбора режима GPS исходя из (поездка, открыто ли приложение, энергосбережение).
    private func applyLocationMode() {
        guard isAuthorized else { return }
        accuracyTier = -1   // режим сменился — адаптивная точность переоценится на след. тике
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

    /// Тир точности GPS в поездке. Переключаем только на границах (гистерезис по тиру),
    /// а не каждый тик — реконфигурация CLLocationManager не бесплатна.
    @ObservationIgnored private var accuracyTier = -1

    /// Адаптивный GPS в поездке: максимум только в ФИНАЛЬНОМ подходе к камере/манёвру,
    /// где важен точный отсчёт и учёт проезда. На крейсере — 10 м и больший distanceFilter:
    /// GPS-чип работает мягче И весь пайплайн (+ следование карты) тикает реже — меньше нагрев.
    /// В плотном городе, где камера почти всегда «где-то рядом», это ключевая экономия:
    /// бинарный порог 3 км там не срабатывал и точность держалась на максимуме весь путь.
    private func tuneAdaptiveAccuracy() {
        guard isTripActive, settings.adaptiveGPS, !isLowPowerMode else { return }
        let cameraDistance = distanceToNearest ?? .greatestFiniteMagnitude
        let stepDistance = (route?.isActive == true && route?.nextStep != nil)
            ? (route?.nextStepDistance ?? .greatestFiniteMagnitude)
            : .greatestFiniteMagnitude
        let nearest = min(cameraDistance, stepDistance)

        // 0 — финал (Best, частые фиксы), 1 — подъезд (10 м), 2 — крейсер,
        // 3 — стоянка (пробка/светофор >минуты ВДАЛИ от камер: тир 2 гарантирует,
        // что до ближайшей камеры/манёвра больше 1.5 км — грубые фиксы безопасны).
        var tier = nearest < AppConfig.gpsPreciseApproachMeters ? 0
                 : nearest < AppConfig.gpsMidApproachMeters ? 1 : 2
        if tier == 2, speedKmh < 3,
           Date().timeIntervalSince(lastMovementAt) > AppConfig.gpsIdleAfterSeconds {
            tier = 3
        }
        guard tier != accuracyTier else { return }
        accuracyTier = tier
        switch tier {
        case 0:  manager.desiredAccuracy = kCLLocationAccuracyBest
                 manager.distanceFilter = 6
        case 1:  manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                 manager.distanceFilter = 15
        case 2:  manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                 manager.distanceFilter = 25
        default: // стоянка: GPS-чип отдыхает; тронулись — первый тик вернёт тир
                 manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                 manager.distanceFilter = 30
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
        retile(around: coordinate)
    }

    private func retile(around coordinate: CLLocationCoordinate2D) {
        // Якорь ставим здесь, а не только в retileIfNeeded: refreshMonitoring
        // зовёт retile напрямую, и без якоря следующий тик перетайлил бы повторно.
        anchor = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }

        let nearest = repository.nearest(to: coordinate, limit: AppConfig.maxMonitoredRegions)
        nearbyCameras = nearest
        alertedCameraIDs.formIntersection(Set(nearest.map(\.id)))
        // Плотность камер вокруг — сигнал «город» для умного режима оповещений.
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        cameraDensity3km = nearest.count { camera in
            here.distance(from: CLLocation(latitude: camera.coordinate.latitude,
                                           longitude: camera.coordinate.longitude)) <= 3000
        }

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
    /// Когда машина в последний раз реально двигалась (для тира «стоянка»).
    @ObservationIgnored private var lastMovementAt = Date()

    private func handleLocation(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, course: CLLocationDirection) {
        currentCoordinate = coordinate
        // Спидометр без дёрганья: GPS-скорость шумит (68→71→69) — лёгкое экспоненциальное
        // сглаживание, но только по свежим точкам (после паузы берём сырое значение).
        // speed < 0 — фикс без скорости (туннель, плохая геометрия спутников): держим
        // прошлое значение, нулём считать нельзя — PassTracking берёт МИНИМУМ по зоне
        // проезда, и один такой фикс занизил бы записанную скорость у камеры.
        if speed >= 0 {
            let rawKmh = speed * 3.6
            if let lastAt = lastSpeedTickAt, Date().timeIntervalSince(lastAt) < 5 {
                let smoothed = speedKmh * 0.6 + rawKmh * 0.4
                speedKmh = smoothed < 1 ? 0 : smoothed
            } else {
                speedKmh = rawKmh
            }
            lastSpeedTickAt = Date()
        }
        if speedKmh >= 3 { lastMovementAt = Date() }
        currentCourse = course
        locationTick &+= 1
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate)
        recomputeDirection()

        // Активные оповещения (звук/голос/экран) — в поездке ИЛИ пока приложение открыто.
        if isTripActive || isForeground {
            trip.update(coordinate: coordinate, speedKmh: speedKmh)
            register(passes: passTracking.update(
                nearest: nearestCamera, nearestDistance: distanceToNearest,
                coordinate: coordinate, speedKmh: speedKmh,
                roadLimit: speedLimits?.currentLimit, radius: effectiveAlertRadius))
            runAlertEngine()
            // Лимит дороги + превышение; манёвры и прогресс маршрута.
            // Здесь, а не в UI: голос должен работать со свёрнутым приложением.
            speedLimits?.update(coordinate: coordinate, course: course,
                                speedKmh: speedKmh, announce: isTripActive)
            route?.updateProgress(coordinate: coordinate, cameras: repository.cameras,
                                  announce: isTripActive)
            tuneAdaptiveAccuracy()
            // Умный режим: детектор города/трассы (дёшево — пара сравнений).
            contextDetector.update(roadLimitKmh: speedLimits?.currentLimit,
                                   camerasWithin3km: cameraDensity3km,
                                   speedKmh: speedKmh)
            if contextDetector.context != alertContext { alertContext = contextDetector.context }
        }
        // Live Activity живёт только в поездке; update — no-op, если она не запущена.
        liveActivity?.update(state: activityState)
        // Часы: то же состояние (мост квантует и дедупит — без изменений радио молчит).
        watchBridge?.update(isTripActive: isTripActive, speedKmh: speedKmh,
                            cameraTitle: nearestCamera?.displayTitle,
                            distanceMeters: distanceToNearest,
                            alertLevel: currentAlertLevel)
    }

    /// Непрерывный уровень тревоги для часов (та же лестница порогов, что в AlertEngine).
    private var currentAlertLevel: Int {
        guard isTripActive, let d = distanceToNearest else { return 0 }
        let r = effectiveAlertRadius
        return [r, r * 0.6, r * 0.3].filter { d <= $0 }.count
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

    /// Сглаженный азимут камеры относительно курса (0 = прямо по ходу, растёт по часовой).
    /// nil — стоим/курс недостоверен. Камера на активном маршруте — всегда «прямо»:
    /// она на твоём пути по определению, боковое смещение точки в базе не путает.
    @ObservationIgnored private var bearingSmoother = AngleSmoother()
    private(set) var relativeBearingToNearest: Double?

    /// Пересчёт направления на ближайшую камеру — вызывается на каждом GPS-тике.
    private func recomputeDirection() {
        guard isDirectionalFilteringActive,
              let camera = nearestCamera,
              let coordinate = currentCoordinate else {
            relativeBearingToNearest = nil
            bearingSmoother.reset()
            return
        }
        if isCameraOnRoute(camera) {
            relativeBearingToNearest = 0   // на маршруте — прямо по ходу
            bearingSmoother.reset()
            return
        }
        let bearing = GeoMath.bearing(from: coordinate, to: camera.coordinate)
        let raw = (bearing - currentCourse + 360).truncatingRemainder(dividingBy: 360)
        relativeBearingToNearest = bearingSmoother.update(raw)
    }

    /// Ближайшая камера лежит на активном маршруте (в его коридоре).
    private func isCameraOnRoute(_ camera: Camera) -> Bool {
        route?.camerasOnRoute.contains { $0.camera.id == camera.id } ?? false
    }

    /// Направление на ближайшую камеру для голоса/HUD (учитывает мёртвую зону и маршрут).
    var nearestDirection: CameraDirection? {
        relativeBearingToNearest.map { CameraDirection.classify(relativeBearing: $0) }
    }

    /// «впереди» / «впереди справа» / «впереди слева» — для голосового предупреждения.
    private var directionPhrase: String {
        switch nearestDirection {
        case .right, .behindRight: return "впереди справа"
        case .left, .behindLeft:   return "впереди слева"
        default:                   return "впереди"
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

    /// Умный радиус оповещения — растёт со скоростью (см. AlertEngine).
    private var effectiveAlertRadius: CLLocationDistance {
        AlertEngine.effectiveRadius(speedKmh: speedKmh, baseRadius: settings.alertRadius)
    }

    /// 0…1 — насколько глубоко вошли в радиус оповещения (полоска приближения в HUD).
    /// nil — ближайшая камера ещё вне радиуса, полоска не нужна.
    var approachProgress: Double? {
        guard let distance = distanceToNearest, distance < effectiveAlertRadius else { return nil }
        return 1 - distance / max(effectiveAlertRadius, 1)
    }

    /// Показывать полноэкранное предупреждение: движемся и ближайшая камера в радиусе оповещения.
    var isApproachingCamera: Bool {
        guard let d = distanceToNearest, speedKmh >= AppConfig.directionalMinSpeedKmh else { return false }
        return d <= effectiveAlertRadius
    }

    /// Оповещения о приближении: решение принимает AlertEngine (чистый, тестируемый),
    /// здесь — только исполнение: звук, хаптика, голос, уведомление.
    /// nearestCamera уже отфильтрована по курсу: о камерах позади и на встречных
    /// перпендикулярных улицах не предупреждаем (начатая серия порогов не обрывается).
    private func runAlertEngine() {
        guard let camera = nearestCamera, let distance = distanceToNearest else { return }
        guard let decision = alertEngine.evaluate(cameraID: camera.id, distance: distance,
                                                  radius: effectiveAlertRadius) else { return }

        // Умный режим: в городе звук/голос — только про внезапное (передвижной)
        // или при превышении; на трассе — полная эскалация. Вибрация — всегда.
        let policy = AlertPolicy.decision(
            mode: settings.alertMode, detected: alertContext,
            isSuddenCamera: camera.kind == .mobileRadar,
            isOverspeeding: speedLimits?.isOverspeeding == true)

        if settings.soundEnabled && policy.sound { alerts.beep(count: decision.level) }
        // Тактильная эскалация: мягкий «тук» на дальнем пороге → резкий у камеры.
        // Отдельно от звука — работает и в беззвучном режиме, и в энергосбережении.
        alerts.haptic(level: decision.level)
        if decision.level == 1 {
            // В свёрнутом виде (поездка в фоне) — уведомление зажигает экран и вибрирует.
            // Пользователь управляет: все камеры / только радары / выключено.
            if !isForeground, settings.backgroundAlerts.allows(camera) {
                notifier.notifyApproaching(camera, distanceMeters: distance)
            }
            // Голос — самая дорогая часть оповещения, в энергосбережении пропускаем.
            if settings.voiceEnabled && policy.voice && !isLowPowerMode {
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
              let camera = repository.cameras.first(where: { $0.id == id }),
              settings.backgroundAlerts.allows(camera) else { return }
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
            #if DEBUG
            // См. bootstrap(): в скриншот-прогонах симулятора диалог не показываем.
            if !ProcessInfo.processInfo.arguments.contains("-skipAlwaysPrompt") {
                manager.requestAlwaysAuthorization()
            }
            #else
            manager.requestAlwaysAuthorization()
            #endif
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
