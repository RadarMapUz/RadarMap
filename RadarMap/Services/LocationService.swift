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
import os
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
    /// Гейт качества фикса и доверенный курс (чистый модуль, покрыт тестами).
    @ObservationIgnored private var locationFilter = LocationFilter()
    /// Номер последнего принятого фикса — по нему сторож определяет, что новых нет.
    @ObservationIgnored private var fixSequence = 0
    /// true — фиксов нет дольше gpsStaleSeconds: данные на экране устарели.
    private(set) var isSignalStale = false
    /// Погрешность последнего принятого фикса (метры): на ней смягчаются
    /// геометрические проверки — на плохом фиксе они не должны ничего отбрасывать.
    private(set) var horizontalAccuracy: Double = -1
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
        // Авто-пауза включается только вне поездки (см. applyLocationMode): в
        // поездке iOS вправе приостановить обновления и возобновить их «когда
        // сочтёт нужным» — поездка молча осталась бы без алертов и трека.
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
        // Режим «Умный»: сама поездка стартует только в знакомой машине, иначе
        // ждём подтверждения — но вопрос всё равно задаём (ниже), чтобы человек
        // мог включить оповещения одним тапом с локскрина.
        if auto, settings.tripStartMode == .smart, !isDriverRecognized {
            notifier.askDriverCheck()
            return
        }
        if !auto { isPassengerSession = false }  // ручной старт — точно за рулём
        isTripActive = true
        lastMovementAt = Date()   // не проваливаться в тир «стоянка» со старым штампом
        // Телефон в держателе — экран не гаснет всю поездку (как у навигаторов).
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        alertEngine.reset()
        passTracking.reset()
        locationFilter.reset()
        // Заезд по пути — не новая поездка: если пауза похожа на «забежал в
        // магазин», поднимаем прошлую запись обратно в живую сессию.
        if !resumePreviousTripIfMerged() { trip.begin() }
        applyLocationMode()
        liveActivity?.startIfNeeded(state: activityState)
        if auto, !isDriverRecognized { notifier.askDriverCheck() }
    }

    /// Продолжить прошлую поездку вместо новой. Решение принимает чистый
    /// TripMerge; здесь только собираем факты. true — склеили.
    private func resumePreviousTripIfMerged() -> Bool {
        guard let previous = trip.history.first,
              let previousEnd = previous.endCoordinate else { return false }
        let now = Date()
        // Пока GPS не дал первую точку, берём точку финиша прошлой поездки:
        // автостарт срабатывает раньше первого фикса, и иначе склейка не
        // случилась бы никогда именно в самом частом сценарии.
        let here = currentCoordinate ?? previousEnd
        let context = TripMerge.Context(
            stopDuration: now.timeIntervalSince(previous.endedAt),
            metersFromPreviousEnd: GeoMath.fastDistance(here.latitude, here.longitude,
                                                        previousEnd.latitude,
                                                        previousEnd.longitude),
            endedManually: previous.endedManually ?? false,
            stopNearSavedPlace: TripMerge.isNearSavedPlace(previousEnd, places: savedPlaces),
            crossesDay: !Calendar.current.isDate(previous.endedAt, inSameDayAs: now),
            existingStops: previous.stops?.count ?? 0,
            previousDuration: previous.duration)
        guard TripMerge.shouldMerge(context) else { return false }
        trip.resume(previous, stoppedUntil: now)
        return true
    }

    private var savedPlaces: [CLLocationCoordinate2D] {
        [settings.homePlace?.coordinate, settings.workPlace?.coordinate].compactMap(\.self)
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
    /// в следующий раз не переспросим. В «Умном» режиме вопрос приходит ДО старта
    /// поездки (сама она в чужой машине не стартует) — подтверждение и есть старт.
    func confirmDriver() {
        notifier.clearDriverCheck()
        isPassengerSession = false
        for output in AVAudioSession.sharedInstance().currentRoute.outputs
        where output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP {
            if !settings.knownCarAudio.contains(output.portName) {
                settings.knownCarAudio.append(output.portName)
            }
        }
        if !isTripActive { startTrip() }
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
    /// `auto` — автостоп по CoreMotion (а не кнопка): только такую поездку можно
    /// потом продолжить как заезд по пути.
    func endTrip(asPassenger: Bool = false, auto: Bool = false) {
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
            trip.finish(endedManually: !auto)
            // Автостоп с телефоном в кармане: короткие итоги на локскрин —
            // цифры дошли до человека, даже если он не откроет приложение.
            // Свежесть по endedAt, а не по новому id: у продолженной поездки
            // (склейка) id остаётся старым.
            if auto, !isPhoneForeground, let record = trip.history.first,
               Date().timeIntervalSince(record.endedAt) < 30 {
                notifier.notifyTripSummary(distance: record.distanceMeters,
                                           rating: record.score.map { Int($0) },
                                           fineRisk: TripHistory.fineRisk(of: record.passed))
            }
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
            manager.pausesLocationUpdatesAutomatically = true
            isSignalStale = false   // без непрерывного GPS «нет сигнала» не про нас
            locationFilter.reset()
            return
        }
        // В поездке паузу отдавать системе нельзя — она может не возобновить.
        manager.pausesLocationUpdatesAutomatically = !isTripActive
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

    /// Единственная точка входа фиксов: сначала гейт качества, потом обработка.
    /// Отброшенный фикс не двигает ни трек, ни алерты, ни спидометр.
    private func handleFix(_ fix: LocationFilter.Fix) {
        switch locationFilter.accept(fix) {
        case .rejected(let reason):
            Log.location.debug("фикс отброшен: \(reason.rawValue, privacy: .public), точность \(fix.horizontalAccuracy, privacy: .public) м")
            // Первый фикс после запуска почти всегда кэшированный. Для алертов и
            // проездов он не годится (на этом и построен гейт), но для карты и
            // списка «рядом» он лучше пустоты: район тот же, и человек сразу
            // видит окрестности, не глядя на «камер рядом нет».
            if reason == .stale, currentCoordinate == nil, fix.horizontalAccuracy > 0 {
                seedContext(from: CLLocationCoordinate2D(latitude: fix.lat,
                                                         longitude: fix.lon))
            }
        case .accepted(let good):
            if isSignalStale { isSignalStale = false }
            horizontalAccuracy = good.accuracy
            handleLocation(coordinate: CLLocationCoordinate2D(latitude: good.lat,
                                                              longitude: good.lon),
                           speed: good.speed ?? -1, course: good.course)
            armStaleWatchdog()
        }
    }

    /// Окрестности по кэшированной точке: камеры вокруг и ближайшая для HUD.
    /// Ни алертов, ни трека, ни зачёта проездов — только контекст на экране.
    private func seedContext(from coordinate: CLLocationCoordinate2D) {
        currentCoordinate = coordinate
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate)
    }

    /// Сторож потери сигнала: перезаряжается на каждом принятом фиксе, поэтому
    /// срабатывает только если новых фиксов действительно не пришло (лишних
    /// пробуждений нет — обычный тик GPS его гасит).
    ///
    /// Заряжается ТОЛЬКО в движении и с окном по ожидаемому интервалу фиксов:
    /// на стоянке и в пробке фиксы не приходят из-за distanceFilter, а не из-за
    /// спутников, и «нет сигнала» было бы прямой ложью водителю.
    private func armStaleWatchdog() {
        fixSequence &+= 1   // прошлый сторож обесценен даже если новый не ставим
        guard speedKmh >= AppConfig.staleWatchdogMinSpeedKmh else { return }
        let speedMps = speedKmh / 3.6
        let expected = speedMps > 0 ? manager.distanceFilter / speedMps : .infinity
        let window = max(AppConfig.gpsStaleSeconds,
                         min(AppConfig.staleWatchdogMaxSeconds,
                             expected * AppConfig.staleWatchdogSlack))
        let sequence = fixSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
            guard let self, self.fixSequence == sequence,
                  self.isTripActive || self.isForeground else { return }
            self.isSignalStale = true
            Log.location.notice("нет фиксов \(window, format: .fixed(precision: 1), privacy: .public) с — сигнал потерян")
        }
    }

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
                                   speedKmh: speedKmh,
                                   roadClass: nearestCamera?.roadClass ?? .unknown)
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

    /// Камера «наша»: лежит в коридоре нашей дороги впереди — либо подтверждена
    /// активным маршрутом. Коридор (RoadCorridor) считает боковое отклонение в
    /// метрах и отсекает параллельные улицы, дублёры и эстакады, которые прежний
    /// угловой фильтр пропускал (±70° на дистанции 400 м — это 375 м вбок). Маршрут —
    /// обход: там камера на нашем пути по определению, даже если её координата в
    /// базе смещена вбок от полосы.
    private func isOnOurRoad(_ camera: Camera, from coordinate: CLLocationCoordinate2D) -> Bool {
        guard isDirectionalFilteringActive else { return true }   // стоим/курс неизвестен → не фильтруем
        let shape = RoadShape(camera: camera)

        // 1. НАПРАВЛЕНИЕ проезжей части — самый однозначный признак, но он есть
        // только у односторонних дорог: на разделённой трассе каждая сторона в
        // OSM своя линия. Едем против направления — это камера обратной стороны,
        // и она не наша. У двусторонней улицы направления нет: куда смотрит
        // камера, не знает ни OSM, ни реестр, поэтому там работает ось.
        if let direction = camera.dir {
            if GeoMath.angleDifference(currentCourse, Double(direction))
                > AppConfig.cameraDirectionMaxAngle {
                return false
            }
        } else if let axis = shape?.axis(near: coordinate) ?? camera.axis.map(Double.init) {
            // Ось дороги камеры против курса: едем поперёк — это мост НАД камерой
            // или перпендикулярная улица развязки. Боковое отклонение тут ноль,
            // коридор бессилен — различает только направление. Ось берём с куска
            // дороги, если он есть: на кривой единственная ось всей дороги врёт.
            if GeoMath.axisDifference(course: currentCourse, axis: axis)
                > AppConfig.cameraAxisMaxAngle {
                return false
            }
        }

        // 2. Кусок проезжей части у камеры: вблизи это честная проверка «я на
        // этой дороге» вместо эвристики — различает даже параллельные полосы
        // разделённой дороги в 20 м друг от друга. Дальше куска мы физически не
        // рядом с ним, там решает коридор. Допуск включает погрешность фикса:
        // на плохом GPS проверка обязана молчать, а не глушить камеру.
        if let shape, camera.distance(from: coordinate) <= AppConfig.roadShapeCheckMeters {
            let allowed = RoadGeometry.halfWidth(lanes: camera.lanes,
                                                 roadClass: camera.roadClass)
                + max(AppConfig.roadShapeMinToleranceMeters, horizontalAccuracy)
            if shape.distance(from: coordinate) > allowed { return false }
        }

        if isCameraOnRoute(camera) { return true }
        // Внезапным точкам (краудсорс) — коридор трассы: их координату ставил
        // человек на ходу. Камерам с непроверенной позицией (needsReview: снап
        // не нашёл её дорогу) — тоже: лучше предупредить с запасом, чем
        // промолчать из-за смещённой координаты в реестре.
        let generous = camera.kind.isSudden || camera.needsReview == true
        let context: AlertPolicy.Context = generous ? .highway : alertContext
        // Ширина ближней зоны коридора — от реальной дороги, если она известна.
        // Пол по константе: коридор мерится от линии НАШЕГО курса, а её точность
        // ограничена GPS, поэтому уже 10 м делать нельзя.
        let knowsRoad = camera.cls != nil || camera.lanes != nil
        let nearWidth: CLLocationDistance? = (generous || !knowsRoad) ? nil
            : max(AppConfig.corridorMinNearMeters,
                  RoadGeometry.halfWidth(lanes: camera.lanes, roadClass: camera.roadClass))
        return RoadCorridor.contains(camera: camera.coordinate, from: coordinate,
                                     course: currentCourse, context: context,
                                     nearWidth: nearWidth)
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
        case .right, .behindRight: return String(localized: "впереди справа")
        case .left, .behindLeft:   return String(localized: "впереди слева")
        default:                   return String(localized: "впереди")
        }
    }

    private func recomputeNearest(from coordinate: CLLocationCoordinate2D) {
        guard !nearbyCameras.isEmpty else {
            nearestCamera = nil; distanceToNearest = nil; return
        }
        // В движении HUD показывает ближайшую камеру НА НАШЕЙ ДОРОГЕ впереди;
        // камеры позади и с соседних улиц не пугают зря.
        let ranked = nearbyCameras
            .compactMap { camera -> (Camera, CLLocationDistance)? in
                guard isOnOurRoad(camera, from: coordinate) else { return nil }
                guard let remaining = routeRemaining(to: camera) else {
                    return (camera, camera.distance(from: coordinate))
                }
                // Камера уехала назад по маршруту — уже проехали, не пугаем.
                guard remaining > -AppConfig.routePassedToleranceMeters else { return nil }
                return (camera, max(0, remaining))
            }
            .min { $0.1 < $1.1 }
        nearestCamera = ranked?.0
        distanceToNearest = ranked?.1
    }

    /// Остаток до камеры ПО МАРШРУТУ; nil — камера не на активном маршруте.
    /// По прямой петля развязки или объезд дают 300 м там, где по дороге 2 км, —
    /// и приложение предупреждало о камере, до которой ещё ехать и ехать.
    private func routeRemaining(to camera: Camera) -> CLLocationDistance? {
        guard let route, route.isActive,
              let onRoute = route.camerasOnRoute.first(where: { $0.camera.id == camera.id })
        else { return nil }
        return onRoute.distanceAlong - route.progressAlong
    }

    /// Умный радиус оповещения — растёт со скоростью (см. AlertEngine).
    private var effectiveAlertRadius: CLLocationDistance {
        AlertEngine.effectiveRadius(speedKmh: speedKmh, baseRadius: settings.alertRadius)
    }

    /// 0…1 — насколько глубоко вошли в радиус оповещения (полоска приближения в HUD).
    /// nil — ближайшая камера ещё вне радиуса, полоска не нужна.
    var approachProgress: Double? {
        guard !isSignalStale, let distance = distanceToNearest,
              distance < effectiveAlertRadius else { return nil }
        return 1 - distance / max(effectiveAlertRadius, 1)
    }

    /// Показывать полноэкранное предупреждение: движемся и ближайшая камера в радиусе
    /// оповещения. Без свежего фикса расстояние на экране — вчерашняя правда: панель
    /// прячем, но состояние эскалации не трогаем (иначе после туннеля заорём заново).
    var isApproachingCamera: Bool {
        guard !isSignalStale, let d = distanceToNearest,
              speedKmh >= AppConfig.directionalMinSpeedKmh else { return false }
        return d <= effectiveAlertRadius
    }

    /// Оповещения о приближении: решение принимает AlertEngine (чистый, тестируемый),
    /// здесь — только исполнение: звук, хаптика, голос, уведомление.
    /// nearestCamera уже отфильтрована коридором дороги (isOnOurRoad): о камерах
    /// позади, на параллельных и перпендикулярных улицах не предупреждаем.
    private func runAlertEngine() {
        guard let camera = nearestCamera, let distance = distanceToNearest else { return }
        guard let decision = alertEngine.evaluate(cameraID: camera.id, distance: distance,
                                                  radius: effectiveAlertRadius) else { return }

        // Градус оповещения: тишина (город, едем в лимите) → спокойный анонс
        // (трасса) → крик (устойчивое превышение или внезапная точка).
        // Именно УСТОЙЧИВОЕ превышение: мгновенный флаг щёлкает от шума GPS, и
        // «превысил на 1 км/ч» поднимал спокойный анонс до сирены.
        let policy = AlertPolicy.decision(
            mode: settings.alertMode, detected: alertContext,
            isSuddenCamera: camera.kind.isSudden,
            isOverspeeding: speedLimits?.isOverspeedingSustained == true,
            voiceOnlyWhenOverspeeding: settings.voiceOnlyWhenOverspeeding)

        // Сирена — только в срочном режиме: спокойный анонс не пищит.
        if settings.soundEnabled, policy.beeps { alerts.beep(count: decision.level) }
        // Вибрация никому не мешает и работает в беззвучном режиме: эскалация
        // «мягкий тук → резкий у камеры» — только в срочном, иначе один тук на входе.
        if policy.escalates {
            alerts.haptic(level: decision.level)
        } else if decision.level == 1 {
            alerts.haptic(level: 1)
        }

        guard decision.level == 1 else { return }   // баннер и голос — один раз на камеру
        // В свёрнутом виде (поездка в фоне) — уведомление зажигает экран и вибрирует.
        // Пользователь управляет: все камеры / только радары / выключено.
        if !isForeground, settings.backgroundAlerts.allows(camera) {
            notifier.notifyApproaching(camera, distanceMeters: distance)
        }
        // Голос — самая дорогая часть оповещения, в энергосбережении пропускаем.
        if settings.voiceEnabled, policy.voice, !isLowPowerMode {
            alerts.speak(announcement(for: camera, distance: distance,
                                      urgent: policy.escalates))
        }
    }

    /// Фраза предупреждения. Спокойная — как у навигатора, только тип и округлённое
    /// расстояние; про скорость и лимит говорим лишь в срочном режиме, потому что
    /// именно превышение и есть причина повышать голос.
    private func announcement(for camera: Camera, distance: CLLocationDistance,
                              urgent: Bool) -> String {
        // Округляем как манёвры маршрута: «через 743 метра» звучит по-роботски.
        let step: Double = distance >= 400 ? 100 : 50
        let rounded = Int((distance / step).rounded() * step)
        var phrase = isCameraOnRoute(camera)
            ? String(format: String(localized: "По маршруту %@ через %lld метров"),
                     camera.kind.displayName.lowercased(), rounded)
            : String(format: String(localized: "%@ %@, %lld метров"),
                     camera.kind.displayName, directionPhrase, rounded)
        guard urgent else { return phrase }
        if let limit = speedLimits?.currentLimit {
            phrase += String(format: String(localized: ". Ваша скорость %lld, лимит %lld"),
                             Int(speedKmh.rounded()), limit)
        } else if speedKmh >= AppConfig.speakSpeedThresholdKmh {
            phrase += String(format: String(localized: ". Ваша скорость %lld"),
                             Int(speedKmh.rounded()))
        }
        return phrase
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
        let fix = LocationFilter.Fix(location)
        Task { @MainActor in self.handleFix(fix) }
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

    /// Система всё-таки приостановила обновления (вне поездки это нормально).
    /// В поездке паузы быть не должно — если случилась, поднимаем GPS сами.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Log.location.notice("система приостановила обновления геолокации")
            guard self.isTripActive else { return }
            self.manager.startUpdatingLocation()
            Log.location.error("пауза во время поездки — обновления перезапущены")
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Log.location.notice("обновления геолокации возобновлены")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        Task { @MainActor in
            Log.location.error("геолокация: \(error.localizedDescription, privacy: .public)")
            // Доступ отозвали в настройках на ходу — обновляем состояние, чтобы UI
            // показал экран разрешений вместо мёртвого HUD.
            if code == .denied { self.handleAuthChange(self.manager.authorizationStatus) }
        }
    }
}
