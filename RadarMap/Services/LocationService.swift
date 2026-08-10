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
    /// Память о треногах: места, где водители отмечали радар снова и снова.
    @ObservationIgnored weak var hotspots: HotspotService?
    /// О каких точках уже сказали в этой поездке. Живёт только в памяти:
    /// повторяться нельзя внутри поездки, а завтра то же место — снова новость.
    @ObservationIgnored private var voicedHotspots: Set<Int64> = []
    /// Перегрев: буст GPS для открытой приборки разрешён только пока телефон
    /// холодный — в жару экономия важнее плавности картинки.
    @ObservationIgnored weak var thermal: ThermalService?

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var speedKmh: Double = 0
    /// Последний ДОСТОВЕРНЫЙ курс. Живёт дольше самого курса намеренно.
    ///
    /// `currentCourse` становится −1 на каждой остановке: на светофоре, в
    /// пробке, при потере сигнала. От него зависят стрелка на камеру, слово
    /// стороной и вся схема дороги — то есть на красном свете панель гасла
    /// целиком и загоралась заново на трогании. Мигание на каждом светофоре
    /// водитель читает как поломку.
    ///
    /// Стоя мы никуда не повернули, поэтому прошлый курс — честное описание
    /// того, как машина стоит. Схема продолжает рисоваться, но приглушённо:
    /// «это последнее, что мы знали», а не «это происходит сейчас».
    private(set) var lastTrustedCourse: CLLocationDegrees = -1

    /// GPS-курс движения (0–360°, −1 = недостоверен: стоим или нет сигнала).
    private(set) var currentCourse: CLLocationDegrees = -1
    /// 20 ближайших камер — для списка «рядом» и Live Activity (столько же
    /// геозон, сколько разрешает iOS).
    private(set) var nearbyCameras: [Camera] = []
    /// Окно кандидатов на оповещение: шире двадцатки геозон, потому что в
    /// плотном городе 20-я камера бывает ближе, чем мы успеваем проехать до
    /// следующего пересчёта, — и камера впереди выпадала из кандидатов.
    @ObservationIgnored private var trackedCameras: [Camera] = []
    /// Радиус окна кандидатов (до самой дальней камеры в нём) — по нему
    /// решается, когда пересчёт обязателен.
    @ObservationIgnored private var trackedRadius: CLLocationDistance = 0
    private(set) var nearestCamera: Camera?
    /// Камеры вплотную за ближайшей (перекрёсток, где их две-три): голос говорит
    /// о них одной фразой, поэтому их собственный анонс потом пропускается.
    @ObservationIgnored private var clusteredCameras: [Camera] = []
    /// Про эти камеры голос уже сказал групповой фразой — второй раз не надо.
    @ObservationIgnored private var voicedInGroup: Set<Int> = []
    /// Камера, о которой голос промолчал, потому что мы ползли в пробке: скажем
    /// про неё, как только поедем (пока она ещё впереди и в радиусе).
    @ObservationIgnored private var postponedVoice: Int?
    private(set) var distanceToNearest: CLLocationDistance?
    /// false = пользователь дал только «приблизительную» геолокацию — оповещения ненадёжны.
    private(set) var hasFullAccuracy = true
    /// Режим энергосбережения iOS: снижаем точность GPS и отключаем голос.
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Режим «Поездка»: непрерывная геолокация + активные оповещения даже в свёрнутом виде.
    private(set) var isTripActive = false

    /// Поездка началась/закончилась. Нужен тем, чей режим работы зависит от
    /// того, за рулём человек или нет, — а не от того, открыт ли экран
    /// (краудсорс опрашивает сервер и с погашенным экраном, пока идёт поездка).
    @ObservationIgnored var onTripStateChanged: ((Bool) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onTripStateChanged,
                                               "LocationService.onTripStateChanged") }
    }

    /// Точка последнего пере-тайлинга. Координата, а не `CLLocation`: расстояние
    /// до неё меряется тем же `GeoMath.fastDistance`, что и всё остальное в
    /// пайплайне, и не создаёт двух объектов на каждый тик ради одного числа.
    @ObservationIgnored private var anchor: CLLocationCoordinate2D?
    @ObservationIgnored private var alertedCameraIDs: Set<Int> = []   // фон, дебаунс уведомлений
    /// Гейт качества фикса и доверенный курс (чистый модуль, покрыт тестами).
    @ObservationIgnored private var locationFilter = LocationFilter()
    /// Номер последнего принятого фикса — по нему сторож определяет, что новых нет.
    @ObservationIgnored private var fixSequence = 0
    /// true — фиксов нет дольше gpsStaleSeconds: данные на экране устарели.
    private(set) var isSignalStale = false
    /// Позиция получена из фикса, который в алерты не пускается: кэш при запуске
    /// или слабый сигнал в помещении. Окрестности показать можно, но расстояние
    /// на панели нельзя подавать как живое.
    private(set) var isPositionCoarse = false
    /// Когда последний раз пришёл ГОДНЫЙ фикс — по нему решаем, устарела ли
    /// позиция настолько, что грубая точка будет лучше.
    @ObservationIgnored private var lastAcceptedAt: Date?
    /// Погрешность последнего принятого фикса (метры): на ней смягчаются
    /// геометрические проверки — на плохом фиксе они не должны ничего отбрасывать.
    /// @ObservationIgnored намеренно: пишется каждый тик, а читается только
    /// изнутри сервиса — будить SwiftUI-подписчиков этой записью значило бы
    /// перерисовывать экран раз в секунду ради числа, которого нет на экране.
    @ObservationIgnored private(set) var horizontalAccuracy: Double = -1
    /// Пороги приближения (передний план): чистый движок, покрыт тестами.
    @ObservationIgnored private var alertEngine = AlertEngine()
    /// Учёт прохождения камер (траверз + зона измерения): чистый модуль, покрыт тестами.
    @ObservationIgnored private var passTracking = PassTracking()
    /// Детектор «город/трасса» для умного режима оповещений (чистый, покрыт тестами).
    @ObservationIgnored private var contextDetector = AlertPolicy.Detector()
    /// Камер в радиусе 3 км — сигнал плотности для детектора (пересчёт на ретайле).
    @ObservationIgnored private var cameraDensity3km = 0
    /// «Свои» камеры: проезжаем регулярно и спокойно — в городе они молчат
    /// (см. CameraFamiliarity). Пересчитывается на старте поездки: история за
    /// 30 дней меняется медленно, а на тике это была бы лишняя работа.
    /// «Свои» камеры: проезжаем регулярно и спокойно — голос о них молчит.
    /// Наблюдаемое намеренно: маркер на карте и HUD показывают спокойное
    /// состояние, иначе тишина выглядит поломкой, а не заботой.
    private(set) var familiarCameraIDs: Set<Int> = []
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

        // [weak self] и на ВНЕШНЕМ замыкании: чтобы внутренняя Task могла
        // сослаться на self слабо, внешнее без списка захвата держало бы его
        // сильно — NotificationCenter владел бы сервисом вечно (тот же паттерн,
        // что в ThermalService).
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor [weak self] in self?.powerModeChanged(low) }
        }
    }

    private func powerModeChanged(_ low: Bool) {
        isLowPowerMode = low
        applyLocationMode()
    }

    // MARK: - Разрешения / запуск

    func bootstrap() {
        // «Свои» камеры нужны и вне поездки: карта рисует их спокойными, и
        // список обязан быть готов до первого показа маркеров.
        refreshFamiliarCameras()
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
        // Вернулись в приложение — пересчитать по последней известной точке, не
        // дожидаясь фикса: стоящий телефон может не дать его ещё долго.
        if foreground, let coordinate = currentCoordinate {
            recomputeNearest(from: coordinate)
        }
        // Поездка, начатая в фоне (автостарт по CoreMotion в кармане), Live
        // Activity не получала вовсе: ActivityKit не даёт запрашивать её из
        // фона, а повторной попытки не было — водитель открывал приложение и
        // не находил на локскрине ничего. Метод идемпотентен (guard activity
        // == nil), поэтому одна попытка на поездку, не чаще.
        if foreground, isTripActive {
            liveActivity?.startIfNeeded(state: activityState)
        }
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
        refreshFamiliarCameras()   // «свои» камеры считаем один раз на поездку
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
        onTripStateChanged?(true)
        lastMovementAt = Date()   // не проваливаться в тир «стоянка» со старым штампом
        // Телефон в держателе — экран не гаснет всю поездку (как у навигаторов).
        // Кроме поездки за рулём CarPlay: там телефон показывает экран передачи,
        // и прибитый экран сводил бы «телефон отдыхает и не греется» к нулю.
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && !isCarPlayConnected
        alertEngine.reset()
        passTracking.reset()
        locationFilter.reset()
        speedSmoother.reset()
        roadSnapper.reset()
        voicedInGroup.removeAll()
        voicedHotspots.removeAll()
        postponedVoice = nil
        // Заезд по пути — не новая поездка: если пауза похожа на «забежал в
        // магазин», поднимаем прошлую запись обратно в живую сессию.
        // Заряд читаем один раз здесь: дельта за поездку — это видимая цена
        // приложения, ради которой приборка и строилась.
        let batteryPercent = BatteryProbe.percent()
        if !resumePreviousTripIfMerged(batteryPercent: batteryPercent) {
            trip.begin(batteryPercent: batteryPercent)
        }
        applyLocationMode()
        liveActivity?.startIfNeeded(state: activityState)
        if auto, !isDriverRecognized { notifier.askDriverCheck() }
    }

    /// Продолжить прошлую поездку вместо новой. Решение принимает чистый
    /// TripMerge; здесь только собираем факты. true — склеили.
    private func resumePreviousTripIfMerged(batteryPercent: Int? = nil) -> Bool {
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
        trip.resume(previous, stoppedUntil: now, batteryPercent: batteryPercent)
        return true
    }

    private var savedPlaces: [CLLocationCoordinate2D] { settings.savedPlaceCoordinates }

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
        onTripStateChanged?(false)
        UIApplication.shared.isIdleTimerDisabled = false
        // Всю поездку геозоны не перерегистрировались (retile их пропускает —
        // сработать они всё равно не могли). Возвращаясь в тихий фон, ставим
        // их вокруг места парковки, а не города въезда.
        if let coordinate = currentCoordinate { retile(around: coordinate) }
        alertEngine.reset()
        voicedInGroup.removeAll()
        postponedVoice = nil
        notifier.clearDriverCheck()   // вопрос «вы за рулём?» больше не актуален
        let batteryPercent = BatteryProbe.percent()
        if asPassenger {
            _ = passTracking.flush()   // пассажирские «проезды» не считаем
            if trip.distanceMeters < 500 { trip.cancel() } else {
                trip.finish(batteryPercent: batteryPercent)
            }
        } else {
            // Камеры, мимо которых ещё «проезжали» в момент остановки.
            register(passes: passTracking.flush())
            trip.finish(endedManually: !auto, batteryPercent: batteryPercent)
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
                              limitKmh: pass.limitKmh, limitAssumed: pass.limitAssumed)
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
            speedSmoother.reset()
            roadSnapper.reset()
            displayCoordinate = nil
            displayCourse = -1
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

        // Порядок правил (стоянка бьёт близость вне 150 м, буст только с
        // крейсера и на холодном телефоне) — в чистом GPSTiers под тестами.
        let tier = GPSTiers.tier(.init(
            nearestTargetMeters: nearest,
            speedKmh: speedKmh,
            idleSeconds: Date().timeIntervalSince(lastMovementAt),
            sketchVisible: isDashboardVisible || isCarPlaySketchVisible,
            isForeground: isForeground,
            thermalIsFull: (thermal?.mode ?? .full) == .full))
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

    /// Приборка на экране (см. буст в tuneAdaptiveAccuracy).
    @ObservationIgnored private var isDashboardVisible = false
    /// Схема на экране CarPlay — тот же буст, что у приборки телефона.
    @ObservationIgnored private var isCarPlaySketchVisible = false

    /// Открытие/закрытие приборки: пересматриваем тир GPS сразу, не дожидаясь
    /// следующего фикса — на стоящем в пробке телефоне он может прийти нескоро.
    func setDashboardVisible(_ visible: Bool) {
        guard isDashboardVisible != visible else { return }
        isDashboardVisible = visible
        accuracyTier = -1
        tuneAdaptiveAccuracy()
    }

    /// Схема CarPlay показана/скрыта: та же немедленная переоценка тира.
    func setCarPlaySketchVisible(_ visible: Bool) {
        guard isCarPlaySketchVisible != visible else { return }
        isCarPlaySketchVisible = visible
        accuracyTier = -1
        tuneAdaptiveAccuracy()
    }

    /// Попросить точную геопозицию на эту сессию (если дана «приблизительная»).
    func requestPreciseLocation() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "CameraAlerts")
    }

    /// Пересобрать мониторинг вокруг текущей позиции (после добавления/скрытия
    /// камеры, догрузки базы или смены радиуса).
    func refreshMonitoring() {
        anchor = nil
        guard let coordinate = currentCoordinate else { return }
        retile(around: coordinate)
        // Пересчёт ближайшей обязателен, а не «до следующего фикса»: база
        // догружается асинхронно и часто уже ПОСЛЕ первого фикса, а на стоящем
        // телефоне следующий фикс может не прийти вовсе (distanceFilter). Панель
        // тогда навсегда оставалась с «камер рядом нет», хотя камеры на карте
        // видны — она читает базу напрямую, а оповещения ждали окна.
        recomputeNearest(from: coordinate)
        recomputeDirection()
    }

    // MARK: - Пере-тайлинг 20 ближайших

    private func retileIfNeeded(around coordinate: CLLocationCoordinate2D) {
        // Пустое окно = данные ещё не загрузились на прошлом тайлинге — пробуем снова.
        guard let anchor, !trackedCameras.isEmpty else { return retile(around: coordinate) }
        // Окно обязано покрывать всё, до чего мы доедем до следующего пересчёта:
        // иначе камера впереди не попадёт в кандидаты и мы о ней промолчим. В
        // плотном городе радиус окна маленький в метрах — там пересчитываем чаще.
        let reach = max(AppConfig.retileMinDistance,
                        min(AppConfig.retileDistance,
                            trackedRadius - AppConfig.trackedCoverageMeters))
        let moved = GeoMath.fastDistance(anchor.latitude, anchor.longitude,
                                         coordinate.latitude, coordinate.longitude)
        if moved < reach { return }
        retile(around: coordinate)
    }

    private func retile(around coordinate: CLLocationCoordinate2D) {
        // Якорь ставим здесь, а не только в retileIfNeeded: refreshMonitoring
        // зовёт retile напрямую, и без якоря следующий тик перетайлил бы повторно.
        anchor = coordinate

        // Окно кандидатов на оповещение — широкое; геозоны — только 20 ближайших
        // из него (жёсткий лимит iOS). Раньше это был один список на двоих, и
        // движок алертов видел ровно те 20 камер, что и геозоны.
        let tracked = repository.nearest(to: coordinate, limit: AppConfig.trackedCamerasLimit)
        trackedCameras = tracked
        // fastDistance, а не CLLocation: окно из 150 камер — это 300 объектов на
        // каждый пересчёт, а погрешность приближения тут доли процента.
        func distance(to camera: Camera) -> CLLocationDistance {
            GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                 camera.lat, camera.lon)
        }
        // Радиус окна — до самой дальней камеры в нём (список отсортирован).
        trackedRadius = tracked.last.map(distance(to:)) ?? .greatestFiniteMagnitude
        let nearest = Array(tracked.prefix(AppConfig.maxMonitoredRegions))
        nearbyCameras = nearest
        alertedCameraIDs.formIntersection(Set(nearest.map(\.id)))
        // Плотность камер вокруг — сигнал «город» для умного режима оповещений.
        // Считаем по всему окну: по двадцатке цифра упиралась в потолок.
        cameraDensity3km = tracked.count { distance(to: $0) <= 3000 }

        // Геозоны — только вне поездки: в поездке handleEnter выходит первой
        // строкой, то есть они не могут сработать в принципе, а ретайл каждые
        // 300–1500 м гнал в locationd сотни пар stop/startMonitoring за поездку
        // ради невозможного события. Окно кандидатов выше живёт как жило;
        // геозоны пересинхронизирует endTrip.
        guard !isTripActive else { return }
        manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
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
    /// Сглаживание спидометра: по времени, с мгновенным откликом на настоящий
    /// перепад (чистая структура, покрыта SpeedSmootherTests).
    @ObservationIgnored private var speedSmoother = SpeedSmoother()
    /// Прижим картинки к оси дороги (чистая структура, RoadSnapperTests).
    @ObservationIgnored private var roadSnapper = RoadSnapper()
    /// Координата и курс ДЛЯ КАРТИНКИ: прижаты к оси дороги, когда мы на ней
    /// (схема приборки, ведение камеры карты). Гейты оповещений, запись
    /// проездов и трек этим НЕ пользуются — они работают по сырому фиксу:
    /// подменять измерение предположением там, где решается «глушить или
    /// предупреждать», нельзя (см. RoadSnapper).
    private(set) var displayCoordinate: CLLocationCoordinate2D?
    private(set) var displayCourse: CLLocationDirection = -1
    /// Когда машина в последний раз реально двигалась (для тира «стоянка»).
    @ObservationIgnored private var lastMovementAt = Date()
    /// Последняя точка, по которой считали прогресс маршрута (гейт стоянки).
    @ObservationIgnored private var lastRouteProgressCoordinate: CLLocationCoordinate2D?
    /// Долгая стоянка (>dashboardDimIdleSeconds): приборка гасит яркость.
    private(set) var isStandingStill = false

    /// Единственная точка входа фиксов: сначала гейт качества, потом обработка.
    /// Отброшенный фикс не двигает ни трек, ни алерты, ни спидометр.
    private func handleFix(_ fix: LocationFilter.Fix) {
        switch locationFilter.accept(fix) {
        case .rejected(let reason):
            Log.location.debug("фикс отброшен: \(reason.rawValue, privacy: .public), точность \(fix.horizontalAccuracy, privacy: .public) м")
            // Фикс не годится для алертов, проездов и трека — на этом и построен
            // гейт. Но для карты и списка «рядом» он лучше устаревшей точки:
            // район тот же. Раньше так подхватывался только САМЫЙ первый
            // кэшированный фикс; если следующие тоже отбрасывались (в помещении
            // точность легко 70–100 м), панель до конца сессии уверенно
            // показывала расстояние от места, где телефон был в прошлый раз —
            // посреди Ташкента это выглядело как «10.4 км до камеры».
            // Перелёт (jump) не берём: это заведомо мусорная координата.
            let positionIsOld = currentCoordinate == nil
                || Date().timeIntervalSince(lastAcceptedAt ?? .distantPast) > AppConfig.gpsStaleSeconds
            if reason != .jump, fix.horizontalAccuracy > 0, !isTripActive, positionIsOld {
                seedContext(from: CLLocationCoordinate2D(latitude: fix.lat,
                                                         longitude: fix.lon))
            }
        case .accepted(let good):
            if isSignalStale { isSignalStale = false }
            if isPositionCoarse { isPositionCoarse = false }
            lastAcceptedAt = Date()
            horizontalAccuracy = good.accuracy
            handleLocation(coordinate: CLLocationCoordinate2D(latitude: good.lat,
                                                              longitude: good.lon),
                           speed: good.speed ?? -1, course: good.course)
            armStaleWatchdog()
        }
    }

    /// Окрестности по грубой точке: камеры вокруг и ближайшая для HUD.
    /// Ни алертов, ни трека, ни зачёта проездов — только контекст на экране.
    /// Флаг `isPositionCoarse` обязателен: расстояние на панели после этого не
    /// живое, и выдавать его за живое было бы обманом.
    private func seedContext(from coordinate: CLLocationCoordinate2D) {
        currentCoordinate = coordinate
        isPositionCoarse = true
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate)
    }

    /// Сторож потери сигнала: перезаряжается на каждом принятом фиксе, поэтому
    /// срабатывает только если новых фиксов действительно не пришло.
    ///
    /// Отменяемая Task, а не asyncAfter: тот отменить нельзя, и каждый его
    /// блок ВСЁ РАВНО просыпался в свой дедлайн — при фиксе раз в 1.5 с и окне
    /// 8 с это 5–6 висящих таймеров и лишнее пробуждение main на каждый фикс
    /// всю поездку. Отмена Task будит его один раз сразу (в текущей работе),
    /// а не по будильнику в будущем.
    ///
    /// Заряжается ТОЛЬКО в движении и с окном по ожидаемому интервалу фиксов:
    /// на стоянке и в пробке фиксы не приходят из-за distanceFilter, а не из-за
    /// спутников, и «нет сигнала» было бы прямой ложью водителю.
    private func armStaleWatchdog() {
        fixSequence &+= 1   // прошлый сторож обесценен даже если новый не ставим
        staleWatchdogTask?.cancel()
        guard speedKmh >= AppConfig.staleWatchdogMinSpeedKmh else { return }
        let speedMps = speedKmh / 3.6
        let expected = speedMps > 0 ? manager.distanceFilter / speedMps : .infinity
        let window = max(AppConfig.gpsStaleSeconds,
                         min(AppConfig.staleWatchdogMaxSeconds,
                             expected * AppConfig.staleWatchdogSlack))
        let sequence = fixSequence
        staleWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self, self.fixSequence == sequence,
                  self.isTripActive || self.isForeground else { return }
            self.isSignalStale = true
            Log.location.notice("нет фиксов \(window, format: .fixed(precision: 1), privacy: .public) с — сигнал потерян")
        }
    }

    @ObservationIgnored private var staleWatchdogTask: Task<Void, Never>?

    private func handleLocation(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, course: CLLocationDirection) {
        // Главный горячий путь приложения: всё, что происходит на GPS-точке, —
        // на главном акторе, раз в секунду, всю поездку. В Instruments это один
        // интервал `handleLocation`; если он вырастет, вырастет и нагрев.
        Perf.measure(Perf.Name.handleLocation) {
            handleLocationBody(coordinate: coordinate, speed: speed, course: course)
        }
    }

    private func handleLocationBody(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed,
                                    course: CLLocationDirection) {
        currentCoordinate = coordinate
        // Спидометр: сглаживание по ВРЕМЕНИ и мгновенный отклик на настоящий
        // перепад (SpeedSmoother — прежние константные веса на редких тиках
        // адаптивного GPS растягивали хвост торможения на 5+ секунд).
        // speed < 0 — фикс без скорости (туннель, плохая геометрия спутников): держим
        // прошлое значение, нулём считать нельзя — PassTracking берёт МИНИМУМ по зоне
        // проезда, и один такой фикс занизил бы записанную скорость у камеры.
        if speed >= 0 {
            speedKmh = speedSmoother.update(rawKmh: speed * 3.6, at: Date())
        }
        if speedKmh >= 3 { lastMovementAt = Date() }
        currentCourse = course
        locationTick &+= 1
        if currentCourse >= 0 { lastTrustedCourse = currentCourse }
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate)
        recomputeDirection()

        // Активные оповещения (звук/голос/экран) — в поездке ИЛИ пока приложение открыто.
        if isTripActive || isForeground {
            trip.update(coordinate: coordinate, speedKmh: speedKmh)
            // Геометрия проверяется в точке сближения, а не при захвате:
            // коридор оповещений на подходе широк намеренно (о камере за
            // поворотом молчать нельзя), и камера соседней улицы, попав под
            // него однажды, доезжала до записи в историю.
            register(passes: passTracking.update(
                nearest: nearestCamera, nearestDistance: distanceToNearest,
                coordinate: coordinate, speedKmh: speedKmh,
                roadLimit: speedLimits?.currentLimit,
                roadLimitAssumed: speedLimits?.isCurrentLimitAssumed ?? false,
                radius: effectiveAlertRadius,
                offRoad: PassGeometry.isProvenOffRoad(camera:at:)))
            runAlertEngine()
            speakPostponedVoice()
            // Лимит дороги + превышение; манёвры и прогресс маршрута.
            // Здесь, а не в UI: голос должен работать со свёрнутым приложением.
            // Класс дороги ближайшей камеры — фолбэк лимита там, где OSM молчит.
            //
            // announce: отдельная фраза «Превышение скорости» звучит, только
            // если впереди НЕТ камеры, о которой мы сейчас скажем. Иначе
            // водитель получал две реплики внахлёст, и одна из них терялась —
            // чаще всего именно та, что про камеру. Про камеру фраза и так
            // содержит скорость с лимитом. Плюс настройка OverspeedVoice:
            // в режиме «У камер» фраза заслужена, только когда впереди по
            // нашей дороге камера в радиусе оповещения (просьба из реальной
            // поездки: честное по лимиту «превышение» без камеры — ворчание).
            let cameraAhead = (distanceToNearest ?? .greatestFiniteMagnitude)
                <= effectiveAlertRadius
            speedLimits?.update(
                coordinate: coordinate, course: course, speedKmh: speedKmh,
                announce: isTripActive && !willSpeakAboutCameraAhead
                    && settings.overspeedVoice.allows(cameraAhead: cameraAhead),
                fallbackClass: nearestCamera?.roadClass ?? .unknown)
            // Память о треногах — строго ПОСЛЕ speedLimits.update: подсказка
            // звучит только при превышении, а знает о нём именно он.
            announceHotspotIfNeeded(from: coordinate)
            // Прижим КАРТИНКИ к оси дороги — тем же RoadHit, что нашёл лимит,
            // без второго запроса. Строго после speedLimits.update и строго
            // только для отображения (см. RoadSnapper): гейты выше уже
            // отработали по сырому фиксу.
            let snapped = roadSnapper.update(course: currentCourse,
                                             hit: speedLimits?.currentRoadHit)
            displayCoordinate = snapped?.coordinate ?? coordinate
            displayCourse = snapped?.courseDegrees ?? currentCourse
            // Стоянка: точка не сдвинулась — прогресс маршрута не мог
            // измениться, пересчёт (проекция, манёвры, префикс) пропускаем.
            // Порог накопительный от последней ОБРАБОТАННОЙ точки: ползание
            // набирает свои 2 м и проходит. У финиша (<300 м) не пропускаем
            // никогда — прибытие ползком в радиус срабатывает тик в тик.
            let progressMoved = lastRouteProgressCoordinate.map {
                GeoMath.fastDistance($0.latitude, $0.longitude,
                                     coordinate.latitude, coordinate.longitude)
            } ?? .greatestFiniteMagnitude
            if progressMoved >= RoadSketch.standstillMeters
                || (route?.remainingDistance ?? .greatestFiniteMagnitude) < 300 {
                lastRouteProgressCoordinate = coordinate
                route?.updateProgress(coordinate: coordinate, cameras: repository.cameras,
                                      announce: isTripActive)
            }
            tuneAdaptiveAccuracy()
            // Долгая стоянка (стояночное затемнение приборки): пишем только
            // на смене — наблюдатели не будятся каждым тиком.
            let standing = GPSTiers.isStanding(
                speedKmh: speedKmh,
                idleSeconds: Date().timeIntervalSince(lastMovementAt),
                idleAfter: AppConfig.dashboardDimIdleSeconds)
            if standing != isStandingStill { isStandingStill = standing }
            // Умный режим: детектор города/трассы (дёшево — пара сравнений).
            contextDetector.update(roadLimitKmh: speedLimits?.currentLimit,
                                   camerasWithin3km: cameraDensity3km,
                                   speedKmh: speedKmh,
                                   roadClass: nearestCamera?.roadClass ?? .unknown)
            if contextDetector.context != alertContext { alertContext = contextDetector.context }
        }
        // Live Activity живёт только в поездке. Проверяем ЗДЕСЬ, а не полагаемся
        // на no-op внутри: `activityState` — вычисляемое свойство, и оно
        // собиралось каждую секунду ради вызова, который тут же выходил по
        // guard. Плашка не запущена почти всю жизнь приложения.
        if liveActivity?.isActive == true {
            liveActivity?.update(state: activityState)
        }
        // Часы: только в поездке. Вне её HUD часов рисует «нет поездки» без
        // цифр, а меняющаяся скорость пробивала дедуп и будила BT-радио ради
        // данных, которые часы не показывают. Переход в «нет поездки» шлёт
        // endTrip явными нулями.
        if isTripActive {
            watchBridge?.update(isTripActive: true, speedKmh: speedKmh,
                                cameraTitle: nearestCamera?.displayTitle,
                                distanceMeters: distanceToNearest,
                                alertLevel: alertLevel)
        }
    }

    /// Непрерывный уровень тревоги (та же лестница порогов, что в AlertEngine):
    /// 0 — тихо, 1…3 — эскалация. Его показывают часы и приборная панель CarPlay.
    /// Без промежуточных массивов: читается каждый тик и на каждую перерисовку
    /// часового моста и дока CarPlay.
    var alertLevel: Int {
        guard isTripActive, let d = distanceToNearest else { return 0 }
        let r = effectiveAlertRadius
        if d <= r * 0.3 { return 3 }
        if d <= r * 0.6 { return 2 }
        if d <= r { return 1 }
        return 0
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

    /// Обстановка для гейтов «наша ли камера» (чистый модуль LocationGates).
    /// Собирается здесь и только здесь: гейт не должен уметь дотянуться до
    /// сервиса, иначе он перестанет быть проверяемой функцией от геометрии.
    ///
    /// Координата — параметром, а не из `currentCoordinate`: гейты зовутся с
    /// точкой ТЕКУЩЕГО тика, и подмена её на свойство развела бы решение о
    /// камере и точку, для которой оно принимается.
    private func gateSituation(at coordinate: CLLocationCoordinate2D) -> LocationGates.Situation {
        LocationGates.Situation(coordinate: coordinate, course: currentCourse,
                                speedKmh: speedKmh, horizontalAccuracy: horizontalAccuracy,
                                context: alertContext)
    }

    /// Фильтр направления активен, когда едем достаточно быстро и GPS-курс достоверен.
    var isDirectionalFilteringActive: Bool {
        LocationGates.isFilteringActive(gateSituation(at: currentCoordinate ?? .init()))
    }

    /// Направление на камеру для ЭКРАНА: живое, а если курс пропал (светофор,
    /// пробка) — по последнему достоверному. Гейты оповещений этим НЕ
    /// пользуются: глушить камеру по устаревшему курсу нельзя, а нарисовать
    /// стрелку — можно, стоя мы никуда не повернули.
    var displayBearingToNearest: Double? {
        if let live = relativeBearingToNearest { return live }
        guard lastTrustedCourse >= 0, let camera = nearestCamera,
              let coordinate = currentCoordinate else { return nil }
        let bearing = GeoMath.bearing(from: coordinate, to: camera.coordinate)
        return (bearing - lastTrustedCourse + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Камера «наша». Вся политика — в `LocationGates` (чистый модуль со своими
    /// тестами); сервис отвечает только за то, что гейт вообще не может знать
    /// сам: лежит ли камера на построенном маршруте.
    private func isOnOurRoad(_ camera: Camera, from coordinate: CLLocationCoordinate2D) -> Bool {
        LocationGates.isOnOurRoad(camera, in: gateSituation(at: coordinate),
                                  isOnRoute: isCameraOnRoute(camera))
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
        route?.routeCamera(id: camera.id) != nil
    }

    /// Направление на ближайшую камеру для голоса/HUD (учитывает мёртвую зону и маршрут).
    var nearestDirection: CameraDirection? {
        relativeBearingToNearest.map { CameraDirection.classify(relativeBearing: $0) }
    }

    /// Одно слово стороны — для приборки: «прямо» / «справа» / «слева».
    ///
    /// Отдельно от голосовой фразы намеренно: в речи нужен оборот («впереди
    /// справа»), на экране, который читают боковым зрением, — одно слово.
    /// `nil` только если курса не было ни разу. На остановке берётся последний
    /// достоверный: стоя мы никуда не повернули, и слово остаётся правдой —
    /// а мигание на каждом светофоре читается как поломка.
    var nearestSideWord: String? {
        guard let bearing = displayBearingToNearest else { return nil }
        switch CameraDirection.classify(relativeBearing: bearing) {
        case .right, .behindRight: return String(localized: "справа")
        case .left, .behindLeft:   return String(localized: "слева")
        case .ahead:               return String(localized: "прямо")
        }
    }

    /// Камера на построенном маршруте — самый сильный ответ на «какая именно».
    func isOnActiveRoute(_ camera: Camera) -> Bool { isCameraOnRoute(camera) }

    /// «впереди» / «впереди справа» / «впереди слева» — для голосового предупреждения.
    private var directionPhrase: String {
        switch nearestDirection {
        case .right, .behindRight: return String(localized: "впереди справа")
        case .left, .behindLeft:   return String(localized: "впереди слева")
        default:                   return String(localized: "впереди")
        }
    }

    /// Обнулить «ближайшую» без лишних оповещений наблюдателям: @Observable не
    /// сравнивает значения, и голая перезапись тем же nil будила бы всех
    /// подписчиков (HUD, карту, CarPlay) на каждом тике без камеры впереди —
    /// то есть почти всегда.
    private func clearNearest() {
        if nearestCamera != nil { nearestCamera = nil }
        if distanceToNearest != nil { distanceToNearest = nil }
        if !clusteredCameras.isEmpty { clusteredCameras = [] }
    }

    private func recomputeNearest(from coordinate: CLLocationCoordinate2D) {
        guard !trackedCameras.isEmpty else { clearNearest(); return }
        // Сначала дешёвая дистанция по всему окну, и только потом дорогая проверка
        // «наша ли это дорога» — по возрастанию, до первой подходящей. Результат
        // тот же, что у минимума по отфильтрованному списку, но геометрию камеры
        // (кусок дороги, ось, коридор) считаем раз-два на тик, а не 150 раз.
        // fastDistance вместо CLLocation: без аллокаций, и PassTracking меряет
        // траверз тем же способом — цифры на HUD и в проездах сходятся.
        var candidates: [(camera: Camera, distance: CLLocationDistance)] = []
        candidates.reserveCapacity(trackedCameras.count)
        for camera in trackedCameras {
            guard let remaining = routeRemaining(to: camera) else {
                candidates.append((camera, GeoMath.fastDistance(
                    coordinate.latitude, coordinate.longitude, camera.lat, camera.lon)))
                continue
            }
            // Камера уехала назад по маршруту — уже проехали, не пугаем.
            guard remaining > -AppConfig.routePassedToleranceMeters else { continue }
            candidates.append((camera, max(0, remaining)))
        }
        candidates.sort { $0.distance < $1.distance }
        // В движении HUD показывает ближайшую камеру НА НАШЕЙ ДОРОГЕ впереди;
        // камеры позади и с соседних улиц не пугают зря.
        guard let index = candidates.firstIndex(where: { isOnOurRoad($0.camera, from: coordinate) })
        else { clearNearest(); return }
        let found = candidates[index]
        // Камера чаще всего ТА ЖЕ, что тик назад: перезапись тем же значением
        // всё равно будит всех наблюдателей @Observable, и до этой проверки
        // карта с двумя сотнями маркеров перерисовывалась каждую секунду.
        if nearestCamera != found.camera { nearestCamera = found.camera }
        distanceToNearest = found.distance
        // Камеры, стоящие вплотную за ближайшей: на перекрёстке их две-три, и
        // сказать о них надо одной фразой. Проверяем только тех, кто попал в
        // группу по расстоянию — это ноль-два лишних вычисления геометрии.
        clusteredCameras = candidates[(index + 1)...]
            .prefix { $0.distance <= found.distance + AppConfig.voiceGroupMeters }
            .filter { isOnOurRoad($0.camera, from: coordinate) }
            .map(\.camera)
    }

    /// Остаток до камеры ПО МАРШРУТУ; nil — камера не на активном маршруте.
    /// По прямой петля развязки или объезд дают 300 м там, где по дороге 2 км, —
    /// и приложение предупреждало о камере, до которой ещё ехать и ехать.
    private func routeRemaining(to camera: Camera) -> CLLocationDistance? {
        guard let route, route.isActive,
              let onRoute = route.routeCamera(id: camera.id)
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

    /// Ползём: пробка или светофор. Голос в этот момент бесполезен — камеру
    /// впереди показывает панель, а решать водителю пока нечего.
    private var isCrawling: Bool { speedKmh < AppConfig.voiceMinSpeedKmh }

    /// Градус оповещения: тишина (тумблер или пробка) → короткая фраза (город) →
    /// полная фраза (трасса) → крик (устойчивое превышение или внезапная точка).
    /// Именно УСТОЙЧИВОЕ превышение: мгновенный флаг щёлкает от шума GPS, и
    /// «превысил на 1 км/ч» поднимал спокойный анонс до сирены.
    /// Скажем ли мы сейчас про камеру впереди. Если да — отдельную фразу про
    /// превышение подавляем: камера важнее, и говорить надо о ней одной.
    private var willSpeakAboutCameraAhead: Bool {
        guard let camera = nearestCamera, let distance = distanceToNearest,
              distance <= effectiveAlertRadius else { return false }
        return voicePlan(for: camera, crawling: isCrawling).voice != .none
    }

    /// Пересчитать «свои» камеры по истории. Зовётся на старте поездки:
    /// история за 30 дней меняется медленно, на каждом тике это лишняя работа.
    func refreshFamiliarCameras() {
        // Выключили умную тишину — забываем список: гейт в VoiceDirector
        // работает по нему, и пустое множество и есть «говорить обо всех».
        guard settings.smartSilence else {
            familiarCameraIDs = []
            return
        }
        familiarCameraIDs = CameraFamiliarity.familiarIDs(history: trip.history, now: Date())
    }

    private func voicePlan(for camera: Camera, crawling: Bool) -> VoiceDirector.Plan {
        VoiceDirector.decide(situation(for: camera, crawling: crawling))
    }

    /// Обстановка для арбитра: всё, что он должен видеть разом, собирается
    /// здесь. Раньше эти же факты читались из трёх мест в разные моменты
    /// времени — отсюда и брались фразы внахлёст и молчание о камере.
    private func situation(for camera: Camera, crawling: Bool) -> VoiceDirector.Situation {
        let context: AlertPolicy.Context = switch settings.alertMode {
        case .auto: alertContext
        case .city: .city
        case .highway: .highway
        }
        // Превышение — только УСТОЙЧИВОЕ: мгновенный флаг щёлкает от шума GPS,
        // и «превысил на 1 км/ч» поднимал спокойный анонс до сирены.
        let over: Double? = if speedLimits?.isOverspeedingSustained == true,
                               let limit = speedLimits?.currentLimit {
            speedKmh - Double(limit)
        } else {
            nil
        }
        return VoiceDirector.Situation(
            mode: settings.voiceMode,
            context: context,
            isSudden: camera.kind.isSudden,
            isFamiliar: familiarCameraIDs.contains(camera.id),
            overKmh: over,
            limitKmh: speedLimits?.currentLimit,
            isCrawling: crawling)
    }

    /// Оповещения о приближении: решение принимает AlertEngine (чистый, тестируемый),
    /// здесь — только исполнение: звук, хаптика, голос, уведомление.
    /// nearestCamera уже отфильтрована коридором дороги (isOnOurRoad): о камерах
    /// позади, на параллельных и перпендикулярных улицах не предупреждаем.
    private func runAlertEngine() {
        guard let camera = nearestCamera, let distance = distanceToNearest else { return }
        guard let decision = alertEngine.evaluate(cameraID: camera.id, distance: distance,
                                                  radius: effectiveAlertRadius) else { return }

        let policy = voicePlan(for: camera, crawling: isCrawling)

        // Сирена — только в срочном режиме: спокойный анонс не пищит.
        if settings.soundEnabled, policy.beeps { alerts.beep(count: decision.level) }
        // Вибрация никому не мешает и работает в беззвучном режиме: эскалация
        // «мягкий тук → резкий у камеры» — только в срочном, иначе один тук на входе.
        if policy.escalates {
            alerts.haptic(level: decision.level)
        } else if decision.isFirst {
            alerts.haptic(level: 1)   // спокойный режим: один тук на камеру
        }

        // Баннер и голос — один раз на камеру, на ПЕРВОМ оповещении о ней. Раньше
        // условием был level == 1, но камеру бывает видно поздно (поворот прямо
        // перед ней, возврат сигнала, соседняя была ближе) — она входит сразу на
        // втором-третьем уровне, и приложение молчало о ней совсем.
        guard decision.isFirst else { return }
        // В свёрнутом виде (поездка в фоне) — уведомление зажигает экран и вибрирует.
        // Пользователь управляет: все камеры / только радары / выключено.
        if !isForeground, settings.backgroundAlerts.allows(camera) {
            notifier.notifyApproaching(camera, distanceMeters: distance)
        }
        // Голос — самая дорогая часть оповещения, в энергосбережении пропускаем.
        guard settings.voiceEnabled, !isLowPowerMode else { return }
        guard policy.voice != .none else {
            // Промолчали из-за пробки — это ОТСРОЧКА, а не отмена: камера,
            // вошедшая в радиус пока мы разгоняемся от светофора, иначе осталась
            // бы без голоса совсем (уровень уже зачтён, второй раз не придёт).
            // Отложить фразу «поедем — скажу» имеет смысл только там, где она
            // вообще прозвучала бы: в «Умно» и «Молча» голоса нет по замыслу.
            if policy.postpone { postponedVoice = camera.id }
            return
        }
        speak(about: camera, distance: distance, policy: policy)
    }

    /// Сказать про камеру, отложенную пробкой, как только поехали. Зовётся с
    /// каждого тика — дешёвая проверка одного идентификатора.
    private func speakPostponedVoice() {
        guard let id = postponedVoice else { return }
        guard let camera = nearestCamera, camera.id == id,
              let distance = distanceToNearest, distance <= effectiveAlertRadius else {
            postponedVoice = nil   // камеру проехали или сменили — отсрочка не нужна
            return
        }
        guard !isCrawling else { return }   // всё ещё стоим
        postponedVoice = nil
        guard settings.voiceEnabled, !isLowPowerMode else { return }
        let policy = voicePlan(for: camera, crawling: false)
        guard policy.voice != .none else { return }
        speak(about: camera, distance: distance, policy: policy)
    }

    private func speak(about camera: Camera, distance: CLLocationDistance,
                       policy: VoiceDirector.Plan) {
        // Про эту камеру уже сказали групповой фразой на предыдущей — молчим
        // (тук и баннер при этом сработали, камера не потерялась).
        if voicedInGroup.remove(camera.id) != nil { return }
        let group = clusteredCameras
        voicedInGroup.formUnion(group.map(\.id))
        alerts.speak(announcement(for: camera, distance: distance,
                                  urgent: policy.voice == .urgent,
                                  speaksLimit: policy.speaksLimit,
                                  brief: policy.isBrief,
                                  groupCount: group.count))
    }

    /// «Здесь часто ставят треногу» — один раз за поездку на точку и только
    /// при превышении. Решение целиком в чистом `HotspotAlert` (тесты там же);
    /// здесь — доступ к живым данным и собственно голос.
    ///
    /// Почему это НЕ ведёт себя как камера: у камеры молчание хуже лишнего
    /// сигнала, поэтому она предупреждает и при сомнении. Здесь сомнение
    /// означает молчание — подсказка про прошлое, выданная за факт, стоит
    /// доверия ко всему приложению. Точка при этом остаётся на карте: показать
    /// и сказать — разные вещи.
    private func announceHotspotIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard let hotspots, !hotspots.spots.isEmpty, settings.voiceMode != .off else { return }
        let situation = HotspotAlert.Situation(
            coordinate: coordinate,
            course: currentCourse,   // уже прошёл LocationFilter; < 0 — курса нет
            isTripActive: isTripActive,
            isOverspeeding: speedLimits?.isOverspeeding ?? false,
            hintsEnabled: settings.tripodHints)
        guard let spot = HotspotAlert.spotToAnnounce(in: hotspots.spots, situation: situation,
                                                     alreadyVoiced: voicedHotspots) else { return }
        voicedHotspots.insert(spot.key)
        alerts.speak(HotspotAlert.phrase(for: spot))
    }

    /// Фраза предупреждения. Спокойная — как у навигатора, только тип и округлённое
    /// расстояние; про скорость и лимит говорим лишь в срочном режиме, потому что
    /// именно превышение и есть причина повышать голос.
    ///
    /// `brief` — городской вариант в два слова: камеры идут одна за другой, и
    /// полная фраза на каждую превращается в болтовню. `groupCount` — сколько
    /// камер стоит вплотную за этой: о них говорим здесь же, одной фразой.
    private func announcement(for camera: Camera, distance: CLLocationDistance,
                              urgent: Bool, speaksLimit: Bool = false,
                              brief: Bool = false, groupCount: Int = 0) -> String {
        // Округляем как манёвры маршрута: «через 743 метра» звучит по-роботски.
        let step: Double = distance >= 400 ? 100 : 50
        let rounded = Int((distance / step).rounded() * step)
        var phrase: String
        if groupCount > 0 {
            phrase = String(format: String(localized: "Камеры впереди, %lld метров"), rounded)
        } else if brief {
            phrase = String(format: String(localized: "%@, %lld метров"),
                            camera.kind.shortName, rounded)
        } else if isCameraOnRoute(camera) {
            phrase = String(format: String(localized: "По маршруту %@ через %lld метров"),
                            camera.kind.displayName.lowercased(), rounded)
        } else {
            phrase = String(format: String(localized: "%@ %@, %lld метров"),
                            camera.kind.displayName, directionPhrase, rounded)
        }
        // Неподтверждённая отметка водителей: предупреждаем всегда (тишина
        // хуже лишнего сигнала), но слух не выдаём за факт — называем источник.
        // Атрибуция честнее «возможно»: она объясняет, откуда точка взялась, и
        // заодно делает сообщество видимым — водитель слышит, что чужие отметки
        // работают, и начинает отмечать сам. Множественное число безопасно:
        // «отметка водителей» — это категория источника, а не счёт людей.
        // Групповую фразу не трогаем: там несколько камер.
        if camera.isUnconfirmedMobile, groupCount == 0 {
            phrase = String(format: String(localized: "Отметка водителей: %@"),
                            phrase.prefix(1).lowercased() + phrase.dropFirst())
        }
        // Срочно — полная картина: своя скорость и лимит. Иначе (трасса) —
        // только лимит: «здесь 60» помогает, перечисление своей скорости при
        // спокойной езде лишнее.
        if urgent {
            if let limit = speedLimits?.currentLimit {
                phrase += String(format: String(localized: ". Ваша скорость %lld, лимит %lld"),
                                 Int(speedKmh.rounded()), limit)
            } else if speedKmh >= AppConfig.speakSpeedThresholdKmh {
                phrase += String(format: String(localized: ". Ваша скорость %lld"),
                                 Int(speedKmh.rounded()))
            }
        } else if speaksLimit, let limit = speedLimits?.currentLimit {
            phrase += String(format: String(localized: ", здесь %lld"), limit)
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
        // Live Activity здесь не обновляем: она живёт только в поездке
        // (startIfNeeded зовётся из startTrip), а сюда мы попадаем строго вне
        // её — update() всегда выходил по guard, ветка была мёртвой и только
        // читалась как живой путь.
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
    // nonisolated, как остальные шесть колбэков: с дефолтной MainActor-изоляцией
    // витнесс nonisolated-требования ObjC-протокола получал динамический
    // precondition на самом горячем колбэке.
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
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
