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

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
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
    /// Перегрев: буст GPS для схемы на экране CarPlay разрешён только пока
    /// телефон холодный — в жару экономия важнее плавности картинки.
    @ObservationIgnored weak var thermal: ThermalService?
    /// CoreMotion: «телефон стоит» — сторож сигнала не объявляет потерю.
    @ObservationIgnored weak var motion: MotionService?

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentCoordinate: CLLocationCoordinate2D? {
        didSet {
            let has = currentCoordinate != nil
            if has != hasLocation { hasLocation = has }
        }
    }
    /// «Позиция известна» — меняется только на переходе nil ↔ есть. Для вью,
    /// которым нужен сам факт (кнопка «маршрут сюда» есть или нет): чтение
    /// `currentCoordinate` в body подписывало весь экран с картой на каждый
    /// фикс — раз в секунду пересборка ради ответа, который не менялся.
    private(set) var hasLocation = false
    private(set) var speedKmh: Double = 0 { didSet { refreshApproachFlags() } }

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
    private(set) var distanceToNearest: CLLocationDistance? { didSet { refreshApproachFlags() } }
    /// false = пользователь дал только «приблизительную» геолокацию — оповещения ненадёжны.
    private(set) var hasFullAccuracy = true
    /// Режим энергосбережения iOS: снижаем точность GPS (голос о камерах — как всегда).
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Режим «Поездка»: непрерывная геолокация + активные оповещения даже в свёрнутом виде.
    private(set) var isTripActive = false { didSet { refreshApproachFlags() } }

    /// Поездка началась/закончилась. Нужен тем, чей режим работы зависит от
    /// того, за рулём человек или нет, — а не от того, открыт ли экран
    /// (краудсорс опрашивает сервер и с погашенным экраном, пока идёт поездка).
    /// Первое оповещение о камере — дневной счётчик воронки. Хук, а не прямая
    /// ссылка на статистику: гейты не должны знать, что кто-то считает.
    /// Считаем именно ПЕРВОЕ: эскалация по уровням — то же оповещение.
    @ObservationIgnored var onAlertFired: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onAlertFired,
                                               "LocationService.onAlertFired") }
    }

    /// Каждый ПРИНЯТЫЙ фикс (после LocationFilter). Для наблюдателей, которым
    /// нужна позиция и с погашенным экраном: раньше они висели на вью карты
    /// (`onChange(locationTick)`), а вью без экрана не живёт.
    @ObservationIgnored var onAcceptedFix: ((CLLocationCoordinate2D) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onAcceptedFix,
                                               "LocationService.onAcceptedFix") }
    }

    @ObservationIgnored var onTripStateChanged: ((Bool) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onTripStateChanged,
                                               "LocationService.onTripStateChanged") }
    }

    /// «Похоже, вы едете, а поездка не включена».
    ///
    /// Грубый флаг вместо сырой скорости — и это про производительность, а не
    /// про удобство. Нижние панели решают по нему, какую плашку показать, и
    /// пока они читали `speedKmh`, тело главного экрана зависело от значения,
    /// которое пишется КАЖДЫМ фиксом: экран с картой и маркерами пересобирался
    /// раз в секунду ради строки, меняющейся раз в поездку.
    ///
    /// Здесь же гистерезис: у самого порога сглаженная скорость колеблется, а
    /// каждое переключение флага — это пересборка панелей.
    private(set) var isProbablyDriving = false

    /// Чистое правило флага — отдельно, чтобы его можно было проверить.
    nonisolated static func probablyDriving(was: Bool, speedKmh: Double,
                                            tripActive: Bool) -> Bool {
        if tripActive { return false }
        let threshold = was
            ? AppConfig.speakSpeedThresholdKmh - AppConfig.drivingHintHysteresisKmh
            : AppConfig.speakSpeedThresholdKmh
        return speedKmh >= threshold
    }

    /// Записан проезд камеры; строка — чем мы его судили: `tag`, `assumed`
    /// или `none`. Именно из проезда растут деньги, рейтинг и тишина, поэтому
    /// источник лимита считается здесь, а не на каждом тике.
    @ObservationIgnored var onPassRecorded: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onPassRecorded,
                                               "LocationService.onPassRecorded") }
    }

    /// Приложение СКАЗАЛО о камере вслух; строка — насколько многословно:
    /// `brief`, `calm`, `urgent`.
    ///
    /// Счётчик `alerts` считает не это. Он растёт на каждое СРАБАТЫВАНИЕ —
    /// баннер и тук, — а вслух приложение говорит далеко не всегда: своя
    /// камера молчит, пробка откладывает, режим «Молча» выключает голос
    /// целиком. Телеметрия показала 19 срабатываний на поездку и ровно ничего
    /// о том, сколько из них прозвучало. Между тем жалоба владельца была
    /// именно про голос: «много раз проезжаю, а он говорит».
    ///
    /// Без этого числа ставить порог («не больше N фраз за поездку») значило
    /// бы гадать — ровно та ошибка, от которой предостерегает
    /// plan_algorithms.md §10: сперва неделя данных, потом правило.
    @ObservationIgnored var onCameraSpoken: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onCameraSpoken,
                                               "LocationService.onCameraSpoken") }
    }

    /// Поездка кончилась — вот чего стоила работа предупреждений: сколько
    /// камер проехали и о скольких успели сказать (`AlertRecall`). Единственная
    /// цифра, по которой вообще можно судить, работает конвейер или нет.
    @ObservationIgnored var onAlertRecall: ((AlertRecall.Tally) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onAlertRecall,
                                               "LocationService.onAlertRecall") }
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
    private(set) var isSignalStale = false { didSet { refreshApproachFlags() } }
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
    /// Охват предупреждений за поездку: камеры, мимо которых проехали, против
    /// камер, о которых сказали. Считается НЕЗАВИСИМО от записи проезда — у
    /// той свои, намеренно более строгие гейты, и мерить ими себя нельзя.
    @ObservationIgnored private var alertRecall = AlertRecall()
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
    private(set) var alertContext: AlertPolicy.Context = .city { didSet { refreshApproachFlags() } }
    // Два независимых «передних плана»: телефонная сцена и CarPlay. Один флаг
    // они затирали друг другу (блокировка телефона в машине замораживала HUD CarPlay,
    // а отключение CarPlay в фоне навсегда оставляло «передний» режим GPS).
    @ObservationIgnored private var isPhoneForeground = false
    @ObservationIgnored private var isCarPlayConnected = false
    private var isForeground: Bool { isPhoneForeground || isCarPlayConnected }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    /// Доступ «Всегда». «При использовании» держит экран машины живым, но
    /// фоновые оповещения, геозоны и автостарт при нём молча не работают —
    /// об этой деградации интерфейс обязан говорить, а не догадываться.
    var isAlwaysAuthorized: Bool { authorizationStatus == .authorizedAlways }

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

    /// Координата, от которой можно СТРОИТЬ: грубая не годится.
    ///
    /// `currentCoordinate` заполняется из двух мест. Одно — живой
    /// отфильтрованный фикс. Другое — `seedContext`, грубая точка режима
    /// значимых перемещений; её собственный комментарий гласит, что после неё
    /// расстояние на панели не живое, и рядом выставляется `isPositionCoarse`.
    ///
    /// Маршрут этого флага не проверял и мог быть посчитан от точки за
    /// километры — он выглядит настоящим и ведёт не туда. Здесь мы ждём именно
    /// живой фикс, а не отдаём первый попавшийся, и честно возвращаем `nil`,
    /// если он не пришёл: не построить лучше, чем построить от вчерашнего
    /// места (plan_drive_complaints.md, Ж5).
    func awaitPreciseCoordinate(timeout: TimeInterval = 6) async -> CLLocationCoordinate2D? {
        await awaitPosition(timeout: timeout, precise: true)
    }

    /// Координата для интентов (холодный старт из Siri: bootstrap не выполнялся,
    /// currentCoordinate пуст) — просим одноразовый фикс и ждём его до `timeout`.
    func awaitCoordinate(timeout: TimeInterval = 5) async -> CLLocationCoordinate2D? {
        await awaitPosition(timeout: timeout, precise: false)
    }

    /// Одноразовый фикс и ожидание его до `timeout` — общий цикл обеих
    /// просьб выше. `precise` — грубая точка (фоновый режим) не годится:
    /// маршрут от неё начинается за километры.
    private func awaitPosition(timeout: TimeInterval, precise: Bool) async -> CLLocationCoordinate2D? {
        func ready() -> CLLocationCoordinate2D? {
            precise && isPositionCoarse ? nil : currentCoordinate
        }
        if let point = ready() { return point }
        guard isAuthorized else { return nil }
        manager.requestLocation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let point = ready() { return point }
            await Task.pause(seconds: AppConfig.positionWaitStepSeconds)
        }
        return ready()
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
        // Идущую поездку второй старт НЕ перезапускает: trip.begin обнулил бы
        // километры, трек и проезды, накопленные до этого момента. Все
        // известные вызывающие проверяют isTripActive сами, но «ехал, выбрал
        // «Домой» — данные до этого пропали» (владелец, 11.10) означает, что
        // хотя бы один путь этого не делал. Теперь защита здесь, одна на всех.
        guard !isTripActive else {
            Log.trips.notice("startTrip при идущей поездке — игнорирую (auto: \(auto, privacy: .public))")
            return
        }
        refreshFamiliarCameras()   // «свои» камеры считаем один раз на поездку
        if auto, isPassengerSession { return }   // пассажир уже сказал своё слово
        // Режим «Умный»: сама поездка стартует только в знакомой машине, иначе
        // ждём подтверждения — но вопрос всё равно задаём (ниже), чтобы человек
        // мог включить оповещения одним тапом с локскрина.
        if auto, settings.tripStartMode == .smart, !isDriverRecognized {
            // Четвёртый исход «поездки нет»: она и не начиналась. Машина
            // незнакомая, режим «умный», вопрос задан — но если на него не
            // ответить, записи не будет вовсе, и без журнала это неотличимо
            // от потери (docs/plan_drive_complaints.md, Ж4).
            Log.trips.notice("автостарт отклонён: режим «умный», машина незнакомая — ждём ответа «вы за рулём?»")
            trip.noteDropped("notDriver")
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
        alertRecall.reset()
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
        // Итог работы предупреждений за поездку — до сброса счётчиков.
        // Пассажирская поездка тоже считается: камеры мимо ехали настоящие,
        // и промах конвейера от того, кто за рулём, не зависит.
        let recall = alertRecall.tally()
        if !recall.isEmpty { onAlertRecall?(recall) }
        // Камеры, мимо которых ещё «проезжали» в момент остановки, — ДО сброса
        // счётчика: записи проезда нужно знать, предупреждали ли о камере.
        // После сброса каждый такой проезд выходил «промолчала» — и камера,
        // о которой сказали за 300 м до парковки, звала жаловаться (ревью 19.10).
        let tailPasses = passTracking.flush()
        if !asPassenger { register(passes: tailPasses) }   // пассажирские не считаем
        alertRecall.reset()
        voicedInGroup.removeAll()
        postponedVoice = nil
        notifier.clearDriverCheck()   // вопрос «вы за рулём?» больше не актуален
        let batteryPercent = BatteryProbe.percent()
        if asPassenger {
            if trip.distanceMeters < AppConfig.passengerTripMinMeters { trip.cancel() } else {
                trip.finish(batteryPercent: batteryPercent)
            }
        } else {
            trip.finish(endedManually: !auto, batteryPercent: batteryPercent)
            // Автостоп с телефоном в кармане: короткие итоги на локскрин —
            // цифры дошли до человека, даже если он не откроет приложение.
            // Свежесть по endedAt, а не по новому id: у продолженной поездки
            // (склейка) id остаётся старым.
            if auto, !isPhoneForeground, let record = trip.history.first,
               Date().timeIntervalSince(record.endedAt) < 30 {
                notifier.notifyTripSummary(tripID: record.id, distance: record.distanceMeters,
                                           rating: record.score.map { Int($0) },
                                           fineRisk: TripHistory.fineRisk(of: record.passed))
            }
            // Припарковались у цели — маршрут выполнен, линия не должна висеть на карте.
            route?.finishIfNearDestination(coordinate: currentCoordinate)
        }
        // «Стоп» рукой — конец и маршрута (NavigationFlow): иначе стоп на
        // одном экране оставлял ведение на другом (12.10, машина вела после
        // «Поездка завершена»). Автостоп и «я пассажир» маршрут оставляют.
        let end: NavigationFlow.TripEnd = asPassenger ? .passenger : (auto ? .auto : .manual)
        if !NavigationFlow.keepsRoute(after: end), let route, route.isActive {
            route.clear()
        }
        applyLocationMode()
        liveActivity?.end()
        notifier.clearApproaching()   // конец поездки — убрать висящий баннер камеры
        // Часы сразу в «ожидание», не дожидаясь следующего GPS-тика.
        watchBridge?.update(isTripActive: false, speedKmh: 0, cameraTitle: nil,
                            distanceMeters: nil, alertLevel: 0)
    }

    private func register(passes: [PassTracking.Pass]) {
        // Пишутся проезды камер, которые меряют скорость (не «Пост», не «ДТП»),
        // и не неподтверждённых отметок: подброшенная фальшивка на проспекте
        // стоила бы баллов и «штрафа» каждому, кто мимо проехал (ревью S6).
        for pass in passes where pass.camera.kind.recordsPasses && !pass.camera.isUnconfirmedMobile {
            trip.registerPass(camera: pass.camera, speedKmh: pass.speedKmh,
                              limitKmh: pass.limitKmh, roadLimitKmh: pass.roadLimitKmh,
                              limitAssumed: pass.limitAssumed,
                              courseDegrees: pass.courseDegrees,
                              speedAfterKmh: pass.speedAfterKmh,
                              silent: !alertRecall.wasAlerted(cameraID: pass.camera.id),
                              date: pass.date)
            onPassRecorded?(pass.limitKmh == nil ? "none"
                            : (pass.limitAssumed ? "assumed" : "tag"))
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
            standstill.reset()
            frozenDisplay = nil
            displayCoordinate = nil
            displayCourse = -1
            // Вернулись в тихий фон — геозоны снова единственный способ узнать
            // о камере, и ставить их надо вокруг того места, где мы сейчас.
            // Пока шёл непрерывный GPS, retile их не трогал (см. там), так что
            // без этой строки они остались бы вокруг точки, где экран открыли.
            // Ровно один раз на переход: applyLocationMode зовётся и от смены
            // энергосбережения, и из настроек, а перевзводить двадцать геозон
            // на каждый такой вызов — та же трата, от которой мы и уходим.
            if !geofencesArmed, let coordinate = currentCoordinate {
                retile(around: coordinate)
            }
            return
        }
        // Паузу отдавать системе нельзя ни в поездке, ни в машине: iOS ставит
        // поток фиксов на паузу сама и сама его НЕ возобновляет. В поездке это
        // знали и запрещали давно; на CarPlay запрет забыли — и экран машины
        // замирал на нуле, потому что телефон лежит в держателе неподвижно
        // относительно себя, а система считает это «пользователь остановился».
        manager.pausesLocationUpdatesAutomatically = !(isTripActive || isCarPlayConnected)
        if isTripActive || isCarPlayConnected {
            // Поездка: высокая точность, разрешаем работу в фоне (с «Всегда» —
            // всегда, с «При использовании» — если начата на экране). Экран
            // машины без начатой поездки — это тоже вождение:
            // цифры на нём обязаны быть живыми, а телефон при этом обычно
            // заблокирован в держателе, и без флага фона система вправе
            // перестать слать фиксы. Дальше точность ведёт лестница
            // (tuneAdaptiveAccuracy).
            manager.desiredAccuracy = isLowPowerMode ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
            manager.distanceFilter = isLowPowerMode ? 20 : 5
            // И при «При использовании»: поездка, начатая на экране, вправе
            // жить в фоне (iOS показывает синий индикатор). До 20.10 флаг
            // ставился только для «Всегда», и поездка с «При использовании»
            // молчала, стоило заблокировать телефон или открыть Яндекс
            // (сценарий S2). Автостарт и геозоны «Всегда» по-прежнему требуют.
            manager.allowsBackgroundLocationUpdates =
                [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
            manager.showsBackgroundLocationIndicator = true
        } else {
            // Просто открытое приложение: точный GPS для HUD, фон не держим.
            // Точность — как у Apple Карт (почему — GPSTiers.foreground).
            let request = GPSTiers.foreground(lowPower: isLowPowerMode)
            foregroundIdle = false
            manager.desiredAccuracy = request.accuracy
            manager.distanceFilter = request.distanceFilter
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
        }
        manager.startUpdatingLocation()
        armColdStartWatchdog()
    }

    /// Сторож холодного старта непрерывного GPS.
    ///
    /// Обычный сторож (armStaleWatchdog) взводится только из ПРИНЯТОЙ ветки
    /// фикса и только в движении — то есть с крытого паркинга, где первый фикс
    /// не приходит или бракуется, «Нет сигнала» не зажигалось никогда: док
    /// уверенно показывал «Чисто» и 0 км/ч, схема — «появится в движении»,
    /// и вся эта тишина была неотличима от сломанного приложения. Здесь окно
    /// щедрое (staleWatchdogMaxSeconds): первому фиксу позволено идти долго,
    /// но не бесконечно. Принятый фикс гасит флаг обычным путём, а стоянка с
    /// живым фиксом отменяет этого сторожа через armStaleWatchdog.
    private func armColdStartWatchdog() {
        // Позиция свежая — сторожу нечего сторожить, обычный цикл уже идёт.
        if let accepted = lastAcceptedAt,
           Date().timeIntervalSince(accepted) < AppConfig.gpsStaleSeconds { return }
        fixSequence &+= 1
        staleWatchdogTask?.cancel()
        let sequence = fixSequence
        staleWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConfig.staleWatchdogMaxSeconds))
            guard !Task.isCancelled, let self, self.fixSequence == sequence,
                  self.isTripActive || self.isForeground else { return }
            self.isSignalStale = true
            Log.location.notice("непрерывный GPS запущен, но принятых фиксов нет — сигнал потерян")
        }
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
        // Энергосбережение больше не отменяет лестницу: оно запрещает верхнюю
        // ступень, но оставляет нижние. Раньше стояла отмена целиком, и на
        // стоянке в этом режиме чип работал ВДВОЕ точнее, чем без него.
        // CarPlay без поездки — тоже вождение с живыми оповещениями, и лестница
        // ему положена: раньше он держал «Best» и фильтр 5 м всю сессию, в том
        // числе на стоянке и на трассе вдали от камер (аудит 11.10).
        if !(isTripActive || isCarPlayConnected) { return tuneForegroundAccuracy() }
        guard settings.adaptiveGPS else { return }
        let cameraDistance = distanceToNearest ?? .greatestFiniteMagnitude
        let stepDistance = (route?.isActive == true && route?.nextStep != nil)
            ? (route?.nextStepDistance ?? .greatestFiniteMagnitude)
            : .greatestFiniteMagnitude
        let nearest = min(cameraDistance, stepDistance)

        // Порядок правил (стоянка бьёт близость вне 150 м) — в чистом
        // GPSTiers под тестами.
        let tier = GPSTiers.tier(.init(
            nearestTargetMeters: nearest,
            speedKmh: speedKmh,
            idleSeconds: Date().timeIntervalSince(lastMovementAt)),
                                 lowPower: isLowPowerMode)
        // На карту смотрят (машина или открытый телефон) — фиксы без фильтра
        // расстояния: спидометр и камера карты живут каждую секунду.
        let watched = isForeground
        guard tier != accuracyTier || watched != accuracyWatched else { return }
        accuracyTier = tier
        accuracyWatched = watched
        let request = GPSTiers.request(tier: tier, watched: watched)
        manager.desiredAccuracy = request.accuracy
        manager.distanceFilter = request.distanceFilter
    }
    @ObservationIgnored private var accuracyWatched = false

    /// Открытый экран без поездки: телефон лежит — чип на «до 10 м», тронулись
    /// — снова «Best» (GPSTiers.foreground). Только на принятых фиксах.
    private func tuneForegroundAccuracy() {
        guard isForeground else { return }
        var idle = settings.adaptiveGPS
            && GPSTiers.foregroundIdle(idleSeconds: Date().timeIntervalSince(lastMovementAt),
                                       hasPosition: currentCoordinate != nil,
                                       nearestCameraMeters: distanceToNearest ?? .infinity)
        // Сдвинулись от места, где легли, — уже не лежим, даже если первый
        // фикс после фильтра 30 м ещё показал «0 км/ч».
        if foregroundIdle, let anchor = idleAnchor, let here = currentCoordinate,
           GeoMath.fastDistance(anchor.latitude, anchor.longitude, here.latitude, here.longitude)
            >= AppConfig.gpsIdleLeaveMeters {
            idle = false
            lastMovementAt = Date()
        }
        guard idle != foregroundIdle else { return }
        foregroundIdle = idle
        idleAnchor = idle ? currentCoordinate : nil
        let request = GPSTiers.foreground(lowPower: isLowPowerMode, idle: idle)
        manager.desiredAccuracy = request.accuracy
        manager.distanceFilter = request.distanceFilter
        Log.location.info("открытый экран: \(idle ? "лежит — точность до 10 м" : "движение — точность максимум", privacy: .public)")
    }
    /// Открытый экран сейчас на «лежачей» точности.
    @ObservationIgnored private var foregroundIdle = false
    /// Где легли (выход из «лежачей» точности — по сдвигу от этой точки).
    @ObservationIgnored private var idleAnchor: CLLocationCoordinate2D?

    /// Попросить точную геопозицию на эту сессию (если дана «приблизительная»).
    func requestPreciseLocation() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "CameraAlerts")
    }

    /// Пересобрать мониторинг вокруг текущей позиции (после добавления/скрытия
    /// камеры, догрузки базы или смены радиуса).
    ///
    /// `evaluateNow` — «оповести немедленно, не жди следующего фикса». Нужен
    /// приезду чужой отметки: движок оповещений живёт внутри обработчика
    /// локации, и без этого флага водитель узнавал о радаре впереди только со
    /// следующим фиксом, попавшим в ретайл. Внутри всё идемпотентно
    /// (`alertEngine.evaluate` помнит уровень по камере), лишний вызов не
    /// добавляет ни фразы, ни писка.
    func refreshMonitoring(evaluateNow: Bool = false) {
        anchor = nil
        // Без доступа — замороженная позиция: окно камер и оповещения по ней
        // не пересчитываем (ближайшая снята, и снята насовсем).
        guard let coordinate = currentCoordinate, isAuthorized else { return }
        retile(around: coordinate)
        // Пересчёт ближайшей обязателен, а не «до следующего фикса»: база
        // догружается асинхронно и часто уже ПОСЛЕ первого фикса, а на стоящем
        // телефоне следующий фикс может не прийти вовсе (distanceFilter). Панель
        // тогда навсегда оставалась с «камер рядом нет», хотя камеры на карте
        // видны — она читает базу напрямую, а оповещения ждали окна.
        recomputeNearest(from: coordinate)
        recomputeDirection()
        // Тот же гейт, что и в обработчике локации: активное оповещение — это
        // поездка или открытый экран. В тихом фоне о камере говорят геозоны.
        if evaluateNow, isTripActive || isForeground { runAlertEngine() }
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

    /// Геозоны сейчас стоят вокруг актуальной точки. Ложь означает «их надо
    /// пересобрать при первом же уходе в тихий фон».
    @ObservationIgnored private var geofencesArmed = false
    /// Что именно стоит в locationd — чтобы не переставлять то же самое.
    @ObservationIgnored private var geofencePlan = GeofencePlan()

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
        // Геозоны — без истёкших отметок водителей: слотов всего двадцать.
        let now = Date()
        let nearest = Array(tracked.lazy.filter { !$0.isExpiredMobile(at: now) }
            .prefix(AppConfig.maxMonitoredRegions))
        nearbyCameras = nearest
        alertedCameraIDs.formIntersection(Set(nearest.map(\.id)))
        // Плотность камер вокруг — сигнал «город» для умного режима оповещений.
        // Считаем по всему окну: по двадцатке цифра упиралась в потолок.
        cameraDensity3km = tracked.count { distance(to: $0) <= 3000 }

        // Геозоны — только в ТИХОМ ФОНЕ, где они единственный способ узнать о
        // камере. Пока идёт непрерывный GPS, handleEnter выходит первой
        // строкой, то есть сработать они не могут в принципе, а ретайл каждые
        // 300–1500 м гонит в locationd по сорок синхронных пар
        // stop/startMonitoring — на главном потоке, на ходу.
        //
        // Условие было `!isTripActive`, и это оставляло открытым самый частый
        // сценарий машины: CarPlay подключён, поездку водитель ещё не начал.
        // Непрерывный GPS там уже идёт (applyLocationMode держит его по
        // isCarPlayConnected), фиксы приходят раз в секунду на скорости — и
        // каждые несколько сотен метров главный поток уходил в locationd за
        // невозможным событием. Экран машины при этом продолжает показывать
        // последний кадр: он нарисован, но не живой.
        //
        // Возвращает геозоны applyLocationMode при уходе в тихий фон.
        // База камер ещё читается (процесс подняли в фоне): с пустой базой
        // план «ноль геозон» снял бы все двадцать, и вход, который iOS ещё не
        // доставила, пропал бы. Первую настоящую расстановку сделает загрузка
        // базы (refreshMonitoring по ревизии) — ревью S3, 20.10.
        guard repository.isDatabaseLoaded else {
            geofencesArmed = false
            return
        }
        guard !isTripActive, !isForeground else {
            // Пока идёт непрерывный GPS, геозоны заведомо устаревают: машина
            // уезжает, а они остаются вокруг точки, где экран открыли. Помним
            // это, чтобы уход в тихий фон их пересобрал ровно один раз.
            geofencesArmed = false
            geofencePlan.disarm()
            return
        }
        geofencesArmed = true
        // Наблюдатель ревизии базы (AppEnvironment) зовёт refreshMonitoring на каждое изменение
        // списка, а изменением считается и чужая отметка за пять километров —
        // в двадцатку ближайших она не попадает, и переставлять из-за неё
        // сорок геозон значит платить за краудсорс батареей стоящего телефона.
        guard geofencePlan.needsRearm(cameras: nearest, radius: settings.alertRadius) else { return }
        geofencePlan.arm(cameras: nearest, radius: settings.alertRadius)
        // Сорок синхронных походов в locationd — самый дорогой участок главного
        // потока во всём приложении. Под меткой: если сторож поймает фриз здесь,
        // спорить будет не о чем.
        MainWork.during(MainWork.Name.geofences) {
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

    /// Единственная точка входа фиксов: сначала гейт качества, потом обработка.
    /// Отброшенный фикс не двигает ни трек, ни алерты, ни спидометр.
    /// Крейсер вдали от камер и манёвра — карта может рисовать реже
    /// (EngineMapView.Coordinator.isCruise). Хранимый флаг: пишется только на
    /// смене, вью читают его, а не скорость с дистанцией на каждом фиксе.
    private(set) var isCruising = false

    private func refreshCruise() {
        #if canImport(MapLibre)
        let maneuver = route?.isActive == true && route?.nextStep != nil ? route?.nextStepDistance : nil
        let next = EngineMapView.Coordinator.isCruise(was: isCruising, tripActive: isTripActive,
                                                      speedKmh: speedKmh,
                                                      approachingCamera: isApproachingCamera,
                                                      maneuverMeters: maneuver)
        if next != isCruising { isCruising = next }
        #endif
    }

    /// Время последнего принятого фикса (для трека поездки).
    @ObservationIgnored private(set) var lastFixTime = Date()

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
            // В поездке — тоже. Условие «!isTripActive» здесь выключало
            // единственный запасной путь обновления позиции ровно тогда, когда
            // водитель за рулём: телефон глубоко под стеклом или городской
            // каньон бракует КАЖДЫЙ фикс по точности, и весь экран машины
            // (док, схема, лента) замирал без единого честного слова. Грубая
            // точка идёт только в картинку с флагом isPositionCoarse
            // («Уточняем положение»); алерты, проезды и трек живут строго на
            // принятых фиксах — seedContext их не трогает.
            if reason != .jump, fix.horizontalAccuracy > 0, positionIsOld {
                seedContext(from: CLLocationCoordinate2D(latitude: fix.lat,
                                                         longitude: fix.lon))
            }
            // Замок стоянки. Тир 3 просит у системы точность 100 м, а фильтр
            // пропускает не хуже 65 м. Тир пересматривается только на ПРИНЯТОМ
            // фиксе — и если система отдаёт сотовые 100–300 м (трасса, вышки
            // вместо Wi-Fi), каждый фикс отбрасывается, тир не поднимается
            // никогда, и машина уезжает со стоянки с молчащими оповещениями.
            // Молчание о камере хуже лишнего расхода батареи: забракован по
            // точности на стоянке в поездке — сразу поднимаем точность до
            // верхней ступени; следующий принятый фикс выставит тир по правилам.
            if reason == .accuracy, isTripActive || isCarPlayConnected, accuracyTier == 3 {
                Log.location.notice("стоянка: фикс \(fix.horizontalAccuracy, privacy: .public) м отброшен — поднимаем точность")
                accuracyTier = 0
                let request = GPSTiers.request(tier: 0, watched: isForeground)
                manager.desiredAccuracy = request.accuracy
                manager.distanceFilter = request.distanceFilter
            }
            // То же для открытого экрана без поездки: забракован по точности —
            // просим максимум, иначе метка так и стоит по грубой точке.
            // Телефон лежит, точка уже есть — грубый фикс в помещении не повод
            // будить чип: иначе лежачая точность и подъём сменяли бы друг друга.
            if reason == .accuracy, !isTripActive, isForeground, !foregroundIdle,
               let raised = GPSTiers.escalatedAccuracy(from: manager.desiredAccuracy) {
                Log.location.notice("открытый экран: фикс \(fix.horizontalAccuracy, privacy: .public) м отброшен — поднимаем точность")
                manager.desiredAccuracy = raised
            }
        case .accepted(let good):
            if isSignalStale { isSignalStale = false }
            if isPositionCoarse { isPositionCoarse = false }
            lastAcceptedAt = Date()
            // Время точки трека — время ФИКСА: после фоновой паузы iOS отдаёт
            // фиксы пачкой, и часы обработки дали бы им одно время.
            lastFixTime = min(fix.timestamp, Date())
            horizontalAccuracy = good.accuracy
            handleLocation(coordinate: CLLocationCoordinate2D(latitude: good.lat,
                                                              longitude: good.lon),
                           speed: good.speed ?? -1, course: good.course)
            armStaleWatchdog()
            armSpeedDecay()
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
        // Тик двигаем и здесь: схема и лента CarPlay подписаны на него, а не
        // на координату — без тика они стояли на прошлой точке, пока док уже
        // честно показывал «Уточняем положение» по новой.
        locationTick &+= 1
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
        guard Self.watchdogArms(speedKmh: speedKmh, distanceFilter: manager.distanceFilter) else { return }
        // Заряжен только из-за «фильтра нет» (иначе на этой скорости он бы
        // не встал): если к сроку фильтр появился (ушли с экрана, машина
        // отключилась) — стоим и молчим из-за фильтра, «нет сигнала» — ложь.
        let armedWithoutFilter = speedKmh < AppConfig.staleWatchdogMinSpeedKmh
        let speedMps = speedKmh / 3.6
        let expected = manager.distanceFilter <= 0 ? 1
            : (speedMps > 0 ? manager.distanceFilter / speedMps : .infinity)
        let window = max(AppConfig.gpsStaleSeconds,
                         min(AppConfig.staleWatchdogMaxSeconds,
                             expected * AppConfig.staleWatchdogSlack))
        let sequence = fixSequence
        staleWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self, self.fixSequence == sequence,
                  self.isTripActive || self.isForeground else { return }
            if armedWithoutFilter, self.manager.distanceFilter > 0 { return }
            // Стоим (CoreMotion уверен) — фиксов нет из-за distanceFilter,
            // а не из-за спутников: «нет сигнала» у светофора — ложь.
            if self.motion?.isStationary == true {
                Log.location.debug("фиксов нет, но телефон стоит — сигнал не потерян")
                return
            }
            self.isSignalStale = true
            Log.location.notice("нет фиксов \(window, format: .fixed(precision: 1), privacy: .public) с — сигнал потерян")
        }
    }

    @ObservationIgnored private var staleWatchdogTask: Task<Void, Never>?

    /// Сторож «нет сигнала» заряжается в движении — или при любой скорости,
    /// когда фильтра расстояния нет (экран открыт, CarPlay): тогда фиксы идут
    /// раз в секунду и стоя, и их молчание — потеря сигнала, а не стоянка.
    /// До 20.10 ниже 20 км/ч он не заряжался вовсе: подземный паркинг на
    /// 15 км/ч застывал со старой скоростью и висящим оповещением (S8).
    nonisolated static func watchdogArms(speedKmh: Double, distanceFilter: CLLocationDistance) -> Bool {
        speedKmh >= AppConfig.staleWatchdogMinSpeedKmh || distanceFilter <= 0
    }

    /// Спидометр без фиксов: раз в секунду скорость ограничивается сверху
    /// тем, что опровергает молчание GPS (SpeedBound), пока не станет нулём.
    /// Цикл живёт, только пока цифра ненулевая и фиксов нет, — на ходу его
    /// каждый фикс перезапускает, на стоянке он гаснет за несколько секунд.
    private func armSpeedDecay() {
        speedDecayTask?.cancel()
        guard speedKmh > 0 else { return }
        let fixAt = Date()
        speedDecayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let capped = SpeedBound.capped(self.speedKmh, distanceFilter: self.manager.distanceFilter,
                                               secondsSinceFix: Date().timeIntervalSince(fixAt))
                // Пишем только заметное изменение: speedKmh наблюдаемый.
                if abs(capped - self.speedKmh) >= 0.5 {
                    self.speedKmh = capped
                    // Флаг — следом за цифрой. Раньше он пересчитывался только
                    // на принятом фиксе со скоростью, а в помещении таких нет:
                    // спидометр гас до 0, а «Похоже, вы едете» висело до
                    // следующей поездки (телефон владельца, 11.10).
                    self.refreshDrivingFlag()
                }
                if self.speedKmh == 0 {
                    self.speedSmoother.reset()
                    // Скорость погасла без фиксов — стоим: следующий фикс-шум
                    // стрелку не сдвинет (Standstill).
                    self.standstill.stopIfIdle(at: self.displayCoordinate ?? self.currentCoordinate)
                    return
                }
            }
        }
    }

    @ObservationIgnored private var speedDecayTask: Task<Void, Never>?
    /// Стоянка: скорость 0 и неподвижная стрелка, пока приёмник гуляет на
    /// месте (Standstill). Только скорость и картинка — гейты по сырому фиксу.
    @ObservationIgnored private var standstill = Standstill()
    /// Что рисовать на стоянке: отображаемая точка (уже на оси дороги или
    /// маршрута) и курс в момент остановки.
    @ObservationIgnored private var frozenDisplay: (coordinate: CLLocationCoordinate2D, course: Double)?

    private func freezeDisplayIfStopped(shownBefore: CLLocationCoordinate2D?, courseBefore: CLLocationDirection) {
        guard standstill.isStopped else {
            frozenDisplay = nil
            return
        }
        if frozenDisplay == nil, let point = shownBefore ?? standstill.anchor ?? displayCoordinate {
            frozenDisplay = (point, courseBefore >= 0 ? courseBefore : standstill.anchorCourse)
        }
        guard let frozen = frozenDisplay else { return }
        displayCoordinate = frozen.coordinate
        if frozen.course >= 0 { displayCourse = frozen.course }
    }

    /// «Похоже, вы едете» по текущей цифре спидометра. Присваиваем ТОЛЬКО на
    /// изменение: @Observable будит подписчиков на каждую запись, а смысл
    /// флага ровно в том, чтобы их не будить.
    private func refreshDrivingFlag() {
        let driving = Self.probablyDriving(was: isProbablyDriving, speedKmh: speedKmh,
                                           tripActive: isTripActive)
        if driving != isProbablyDriving { isProbablyDriving = driving }
    }

    private func handleLocation(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, course: CLLocationDirection) {
        // Главный горячий путь приложения: всё, что происходит на GPS-точке, —
        // на главном акторе, раз в секунду, всю поездку. В Instruments это один
        // интервал `handleLocation`; если он вырастет, вырастет и нагрев.
        Perf.measure(Perf.Name.handleLocation) {
            MainWork.during(MainWork.Name.gpsTick) {
                handleLocationBody(coordinate: coordinate, speed: speed, course: course)
            }
        }
    }

    private func handleLocationBody(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed,
                                    course: CLLocationDirection) {
        currentCoordinate = coordinate
        let shownBefore = displayCoordinate
        let courseBefore = displayCourse
        standstill.update(coordinate, rawKmh: speed >= 0 ? speed * 3.6 : -1,
                          accuracy: horizontalAccuracy, course: course, at: Date())
        // Спидометр: сглаживание по ВРЕМЕНИ и мгновенный отклик на настоящий
        // перепад (SpeedSmoother — прежние константные веса на редких тиках
        // адаптивного GPS растягивали хвост торможения на 5+ секунд).
        // speed < 0 — фикс без скорости (туннель, плохая геометрия спутников): держим
        // прошлое значение, нулём считать нельзя — PassTracking берёт МИНИМУМ по зоне
        // проезда, и один такой фикс занизил бы записанную скорость у камеры.
        // На стоянке — ровно ноль: доплеровский шум приёмника на месте (2–7 км/ч)
        // не скорость (Standstill).
        if standstill.isStopped {
            speedSmoother.reset()
            if speedKmh != 0 { speedKmh = 0 }
            refreshDrivingFlag()
        } else if speed >= 0 {
            speedKmh = speedSmoother.update(rawKmh: speed * 3.6, at: Date())
            refreshDrivingFlag()
        }
        if speedKmh >= AppConfig.movementSeenSpeedKmh { lastMovementAt = Date() }
        if currentCourse != course { currentCourse = course }
        locationTick &+= 1
        onAcceptedFix?(coordinate)
        retileIfNeeded(around: coordinate)
        recomputeNearest(from: coordinate, fromFix: true)
        recomputeDirection()

        // Активные оповещения (звук/голос/экран) — в поездке ИЛИ пока приложение открыто.
        if isTripActive || isForeground {
            trip.update(coordinate: coordinate, speedKmh: speedKmh, at: lastFixTime)
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
                // Курс — тот же, которому верит весь конвейер: LocationFilter
                // отдаёт -1 там, где точность курса не доказана, и тогда
                // направление проезда честно остаётся неизвестным.
                course: course,
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
                // settings.voiceEnabled — общий выключатель голоса («Молча»,
                // в том числе кнопкой глушилки в машине). Его здесь не было:
                // камеры замолкали, а фраза о превышении продолжала звучать,
                // хотя человек только что попросил тишины. Настройка
                // overspeedVoice уточняет КОГДА говорить, но не отменяет
                // решения «не говорить вовсе».
                announce: isTripActive && settings.voiceEnabled
                    && !willSpeakAboutCameraAhead
                    && settings.overspeedVoice.allows(cameraAhead: cameraAhead),
                fallbackClass: nearestCamera?.roadClass ?? .unknown,
                // ПДД различают не класс дороги, а населённый пункт: в городе
                // 70 хоть на проспекте, хоть на жилой улице, за городом 100.
                inSettlement: alertContext == .city,
                // Впереди камера — порог превышения становится жёстче
                // штрафного, а подтверждение короче: предупреждение обязано
                // успеть раньше фиксации.
                cameraAhead: cameraAhead)
            // Смена лимита впереди — заранее, а не «превышение» после знака:
            // по линии маршрута или по оси текущей дороги (LimitAhead). Та же
            // тишина, что у фразы о превышении: «Молча», камера говорит сама.
            speedLimits?.checkLimitAhead(
                coordinate: coordinate, course: course, speedKmh: speedKmh,
                // Лениво: путь нужен раз в limitAheadCheckSeconds, а не на каждом тике.
                path: { [weak self] in
                    self?.route?.pathAhead(from: coordinate, meters: AppConfig.limitAheadMaxMeters + 100)
                },
                announce: isTripActive && settings.voiceEnabled && !willSpeakAboutCameraAhead)
            // Память о треногах — строго ПОСЛЕ speedLimits.update: подсказка
            // звучит только при превышении, а знает о нём именно он.
            announceHotspotIfNeeded(from: coordinate)
            // Прижим КАРТИНКИ к оси дороги — тем же RoadHit, что нашёл лимит,
            // без второго запроса. Строго после speedLimits.update и строго
            // только для отображения (см. RoadSnapper): гейты выше уже
            // отработали по сырому фиксу.
            let snapped = roadSnapper.update(course: currentCourse,
                                             hit: speedLimits?.currentRoadHit)
            let shown = snapped?.coordinate ?? coordinate
            if displayCoordinate.map({ $0.latitude != shown.latitude || $0.longitude != shown.longitude }) ?? true {
                displayCoordinate = shown
            }
            let shownCourse = snapped?.courseDegrees ?? currentCourse
            if displayCourse != shownCourse { displayCourse = shownCourse }
            // Стоянка: точка не сдвинулась — прогресс маршрута не мог
            // измениться, пересчёт (проекция, манёвры, префикс) пропускаем.
            // Порог накопительный от последней ОБРАБОТАННОЙ точки: ползание
            // набирает свои 2 м и проходит. У финиша (<300 м) не пропускаем
            // никогда — прибытие ползком в радиус срабатывает тик в тик.
            let progressMoved = lastRouteProgressCoordinate.map {
                GeoMath.fastDistance($0.latitude, $0.longitude,
                                     coordinate.latitude, coordinate.longitude)
            } ?? .greatestFiniteMagnitude
            // Объезд пробки — на каждом фиксе, и стоя: в пробке машина не
            // сдвигается, и прогресс ниже молчит ровно тогда, когда он нужен.
            if isTripActive { route?.considerDetour(coordinate: coordinate, speedKmh: speedKmh) }
            if progressMoved >= MapViewport.standstillMeters
                || (route?.remainingDistance ?? .greatestFiniteMagnitude) < 300 {
                lastRouteProgressCoordinate = coordinate
                // Курс — чтобы положение не прыгнуло на встречную ветку
                // маршрута там, где он возвращается сам к себе.
                route?.updateProgress(coordinate: coordinate, cameras: repository.cameras,
                                      announce: isTripActive, course: course)
            }
            // На маршруте стрелка садится на его линию: OSRM ведёт по нужной
            // проезжей части, и машина на карте едет по своей стороне
            // проспекта, а не рядом с линией (поездка 07.10.2026). Только
            // картинка, как и прижим к оси выше.
            if route?.isActive == true, let snap = route?.displaySnap {
                displayCoordinate = snap.coordinate
                displayCourse = snap.course
            }
            // Стоим — стрелка стоит там, где остановилась, и смотрит, куда
            // ехала: «после остановки куда-то назад уходил» — это блуждание
            // приёмника на месте, а не движение (владелец, 12.10).
            freezeDisplayIfStopped(shownBefore: shownBefore, courseBefore: courseBefore)
            tuneAdaptiveAccuracy()
            refreshCruise()
            // Умный режим: детектор города/трассы (дёшево — пара сравнений).
            contextDetector.update(roadLimitKmh: speedLimits?.certainLimit,
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
            liveActivity?.update(state: activityState,
                                 nearMeters: LiveActivityService.nearZone(alertRadius: effectiveAlertRadius))
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
    ///
    /// Хранимый, а не вычисляемый — как и `isApproachingCamera` ниже. Внутри
    /// вычисляемого читались дистанция и скорость, которые пишутся КАЖДЫМ
    /// фиксом, и каждый, кто смотрел на флаг, становился подписчиком тика:
    /// корень экрана CarPlay пересобирался раз в секунду, а наблюдатели
    /// CarPlay заводили по задаче на тик (аудит 11.10). Хранимое значение
    /// будит читателей только на смене — несколько раз за камеру.
    private(set) var alertLevel = 0
    /// Полноэкранное предупреждение: движемся и ближайшая камера в радиусе
    /// оповещения. Без свежего фикса расстояние на экране — вчерашняя правда:
    /// панель прячем, но состояние эскалации не трогаем (иначе после туннеля
    /// заорём заново).
    private(set) var isApproachingCamera = false

    /// Пересчёт обоих флагов. Зовётся из didSet каждого входа (скорость,
    /// дистанция, сигнал, поездка, контекст), поэтому пропустить путь
    /// обновления нельзя; запись — только на смене значения.
    private func refreshApproachFlags() {
        let radius = effectiveAlertRadius
        let approaching = Self.isApproaching(distance: distanceToNearest, speedKmh: speedKmh,
                                             radius: radius, signalStale: isSignalStale)
        if approaching != isApproachingCamera { isApproachingCamera = approaching }
        let level = Self.alertLevel(distance: distanceToNearest, radius: radius,
                                    tripActive: isTripActive)
        if level != alertLevel { alertLevel = level }
    }

    nonisolated static func isApproaching(distance: CLLocationDistance?, speedKmh: Double,
                                          radius: CLLocationDistance, signalStale: Bool) -> Bool {
        guard !signalStale, let distance,
              speedKmh >= AppConfig.directionalMinSpeedKmh else { return false }
        return distance <= radius
    }

    nonisolated static func alertLevel(distance: CLLocationDistance?, radius: CLLocationDistance,
                                       tripActive: Bool) -> Int {
        guard tripActive, let d = distance else { return 0 }
        return AlertEngine.level(distance: d, radius: radius)
    }

    /// Текущее состояние для Live Activity.
    var activityState: CameraActivityAttributes.ContentState {
        let now = Date()
        return CameraActivityAttributes.ContentState(
            nearestTitle: nearestCamera?.displayTitle,
            nearestSymbol: nearestCamera?.kind.symbolName ?? "checkmark.shield.fill",
            distanceMeters: distanceToNearest,
            arrivesAt: LiveActivityService.arrival(distance: distanceToNearest, speedKmh: speedKmh, now: now),
            since: now
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
            // Пишем только на изменение: @Observable будит читателей на каждую
            // запись, даже того же nil (аудит энергии 19.10).
            if relativeBearingToNearest != nil { relativeBearingToNearest = nil }
            bearingSmoother.reset()
            return
        }
        if nearestViaRoute {
            if relativeBearingToNearest != 0 { relativeBearingToNearest = 0 }   // на маршруте — прямо по ходу
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
        nearestViaRoute = false
        if !clusteredCameras.isEmpty { clusteredCameras = [] }
    }

    @ObservationIgnored private var nearestBuffer: [(camera: Camera, distance: CLLocationDistance, onRoute: Bool)] = []
    /// Ближайшая выбрана по остатку маршрута (а не по прямой): фраза «по
    /// маршруту» и «прямо по ходу» — только тогда. Проеханная камера маршрута,
    /// снова впереди по прямой после разворота, — уже не «по маршруту».
    @ObservationIgnored private var nearestViaRoute = false
    /// Время фикса, по которому последний раз считалась серия «проехали».
    @ObservationIgnored private var geometryFixTime: Date?

    /// `fromFix` — вызов с настоящего фикса GPS (handleLocation). Учёт
    /// «проехали / снова подъезд» — только по ним: пересборка окна (база,
    /// чужие отметки, возврат на экран) повторяет последний фикс, и один кривой
    /// курс засчитывался бы дважды (ревью 20.10).
    private func recomputeNearest(from coordinate: CLLocationCoordinate2D, fromFix: Bool = false) {
        guard !trackedCameras.isEmpty else { clearNearest(); return }
        // Тот же фикс второй раз (iOS повторяет кэшированный после каждого
        // startUpdatingLocation — экран, машина, питание) — не новый шаг серии
        // «проехали / снова впереди» (ревью S4, третий круг).
        let newFix = fromFix && (geometryFixTime.map { lastFixTime > $0 } ?? true)
        if newFix { geometryFixTime = lastFixTime }
        // Сначала дешёвая дистанция по всему окну, и только потом дорогая проверка
        // «наша ли это дорога» — по возрастанию, до первой подходящей. Результат
        // тот же, что у минимума по отфильтрованному списку, но геометрию камеры
        // (кусок дороги, ось, коридор) считаем раз-два на тик, а не 150 раз.
        // fastDistance вместо CLLocation: без аллокаций, и PassTracking меряет
        // траверз тем же способом — цифры на HUD и в проездах сходятся.
        // Буфер переиспользуется между тиками (без новой аллокации на фикс).
        // Полная сортировка оставлена сознательно: окно ≤ trackedCamerasLimit,
        // это микросекунды, а частичный выбор на пути тревоги — лишний риск
        // (аудит энергии 19.10, 2.12).
        var candidates = nearestBuffer
        nearestBuffer = []   // единственная ссылка — иначе removeAll скопирует буфер
        candidates.removeAll(keepingCapacity: true)
        defer { nearestBuffer = candidates }
        // Охват предупреждений меряется по ГЕОГРАФИИ: проехали ближе порога
        // траверса — камера была наша, и молчание о ней обязано попасть в счёт.
        // Ни маршрут, ни гейты, ни правила записи проезда здесь не участвуют:
        // мерить работу конвейера его же решениями значит всегда получать сто
        // процентов. Только в поездке — открытое приложение в кармане пассажира
        // камеры не «проезжает», — и только по ГОДНОМУ фиксу: seedContext
        // зовёт нас же по грубой точке, где ни алертов, ни зачёта проездов нет
        // (см. его комментарий). Кэшированный фикс у камеры иначе записался бы
        // проездом без предупреждения, то есть выдуманным промахом.
        let countsPasses = isTripActive && !isPositionCoarse
        let situation = gateSituation(at: coordinate)
        for camera in trackedCameras {
            let straight = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                camera.lat, camera.lon)
            if countsPasses, straight <= PassGeometry.traverseLimit(for: camera) {
                alertRecall.notePassed(cameraID: camera.id)
            }
            let announced = alertEngine.isAnnounced(camera.id)
            // Проеханные (сценарий S4): о ком сказали, у кого были и кто теперь
            // явно позади — следующий подъезд к ним (разворот, круг) будет
            // новым. Только по годному фиксу — грубая точка из seedContext
            // «проезжать» камеры не вправе. Сказано о единицах камер.
            if announced, newFix, !isPositionCoarse {
                let atTraverse = straight <= max(PassGeometry.traverseLimit(for: camera),
                                                 AppConfig.alertTraverseMeters)
                if atTraverse {
                    alertEngine.noteApproach(camera.id, distance: straight, at: coordinate,
                                             course: situation.course)
                }
                alertEngine.noteGeometry(camera.id, atTraverse: atTraverse,
                                         behind: LocationGates.isClearlyBehind(camera, in: situation),
                                         ahead: alertEngine.isPassed(camera.id)
                                            && LocationGates.isReapproach(camera, in: situation,
                                                                          passLine: alertEngine.passLine(camera.id)))
            }
            // Камера уехала назад по маршруту — стоя не пугаем ею, в движении
            // она снова камера «как все» (маршрут с разворотом).
            guard let candidate = LocationGates.candidateDistance(straight: straight,
                                                                  routeRemaining: routeRemaining(to: camera),
                                                                  announced: alertEngine.isAnnounced(camera.id),
                                                                  in: situation) else { continue }
            candidates.append((camera, candidate.distance, candidate.onRoute))
        }
        candidates.sort { $0.distance < $1.distance }
        // В движении HUD показывает ближайшую камеру НА НАШЕЙ ДОРОГЕ впереди;
        // камеры позади и с соседних улиц не пугают зря.
        guard let index = candidates.firstIndex(where: {
            LocationGates.isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute)
        }) else { clearNearest(); return }
        let found = candidates[index]
        nearestViaRoute = found.onRoute
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
            .filter { LocationGates.isOnOurRoad($0.camera, in: situation, isOnRoute: $0.onRoute) }
            .map(\.camera)
    }

    /// Остаток до камеры ПО МАРШРУТУ; nil — камера не на активном маршруте.
    /// По прямой петля развязки или объезд дают 300 м там, где по дороге 2 км, —
    /// и приложение предупреждало о камере, до которой ещё ехать и ехать.
    /// Остаток по маршруту до его камеры — только пока мы на маршруте.
    /// Съехали (а без сети перестроиться нельзя) — прогресс застыл на
    /// проекции, и камеры старой линии «по маршруту» были нашими без
    /// условий: заслоняли настоящую камеру впереди на новой дороге и
    /// звучали сами (сценарий S7, 20.10). Тогда они — как все: по прямой и
    /// через гейты.
    private func routeRemaining(to camera: Camera) -> CLLocationDistance? {
        guard let route, route.isActive, !route.isOffRoute,
              let onRoute = route.routeCamera(id: camera.id)
        else { return nil }
        return onRoute.distanceAlong - route.progressAlong
    }

    /// Умный радиус оповещения — растёт со скоростью (см. AlertEngine).
    ///
    /// Не приватный: этот же радиус обязан показывать экран. Полноэкранное
    /// предупреждение брало базовые 400 м из настроек, а тревога поднималась
    /// по эффективному — на 130 км/ч это 794 м, и кольцо приближения честно
    /// показывало ноль первые 394 метра, то есть почти одиннадцать секунд.
    var effectiveAlertRadius: CLLocationDistance {
        AlertEngine.effectiveRadius(speedKmh: speedKmh, baseRadius: settings.alertRadius,
                                    context: alertContext)
    }

    /// 0…1 — насколько глубоко вошли в радиус оповещения (полоска приближения в HUD).
    /// nil — ближайшая камера ещё вне радиуса, полоска не нужна.
    var approachProgress: Double? {
        guard !isSignalStale, let distance = distanceToNearest,
              distance < effectiveAlertRadius else { return nil }
        return 1 - distance / max(effectiveAlertRadius, 1)
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
                                                  radius: effectiveAlertRadius,
                                                  moving: isDirectionalFilteringActive) else { return }

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
        onAlertFired?()
        // Дистанция ПЕРВОГО предупреждения: по ней потом видно, успели мы
        // сказать заранее или уже на самой камере. Только в поездке — иначе
        // открытое в кармане приложение копило бы «предупреждения впустую»
        // о камерах, мимо которых никто не ехал, и охват выглядел бы провальным.
        if isTripActive { alertRecall.noteAlert(cameraID: camera.id, distance: distance) }
        // В свёрнутом виде (поездка в фоне) — уведомление зажигает экран и вибрирует.
        // Пользователь управляет: все камеры / только радары / выключено.
        if !isForeground, settings.backgroundAlerts.allows(camera) {
            notifier.notifyApproaching(camera, distanceMeters: distance)
        }
        // Голос о камере — и в энергосбережении (сценарий S1, 20.10): до этого
        // режим Low Power глушил именно камеры, а манёвры, лимиты и пробки
        // говорили. Фраза стоит секунды синтеза; экономит энергосбережение
        // на GPS и карте, а оповещения о камерах не трогает ничто.
        guard settings.voiceEnabled else { return }
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
        guard settings.voiceEnabled else { return }
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
        // Считаем ТОЛЬКО здесь: это единственное место, где фраза о камере
        // действительно уходит в синтезатор. Считать раньше — считать
        // намерения, а их у нас и так девятнадцать на поездку.
        onCameraSpoken?(policy.voice.counterName)
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
        } else if camera == nearestCamera ? nearestViaRoute : isCameraOnRoute(camera) {
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

    /// Входы в геозоны, пришедшие раньше базы камер: приложение подняли в
    /// фоне именно этим событием, а база ещё читается (декод асинхронный).
    /// Вход второй раз не придёт — телефон уже внутри (сценарий S3, 20.10).
    @ObservationIgnored private var pendingRegionEnters = RegionEnterQueue()

    /// База камер прочитана — разобрать входы, пришедшие до неё.
    func processPendingRegionEnters() {
        for id in pendingRegionEnters.drain() { handleEnter(regionID: id) }
    }

    private func handleEnter(regionID: String) {
        // Пока идёт непрерывный GPS — в поездке или при открытом экране, включая
        // экран машины, — о камере говорит движок по точному расстоянию. Геозона
        // дала бы вторым, отставшим на сотни метров, пуш о том же самом.
        guard !isTripActive, !isForeground else { return }
        guard repository.isDatabaseLoaded else {
            pendingRegionEnters.enter(regionID)
            return
        }
        guard let id = Self.cameraID(from: regionID),
              !alertedCameraIDs.contains(id),
              let camera = repository.cameras.first(where: { $0.id == id }),
              // Истёкшая отметка водителей в тихом фоне (опроса нет) — не
              // пугаем (сценарий S5, 20.10).
              !camera.isExpiredMobile(at: Date()),
              settings.backgroundAlerts.allows(camera) else { return }
        alertedCameraIDs.insert(id)
        notifier.notifyApproaching(camera)
        // Live Activity здесь не обновляем: она живёт только в поездке
        // (startIfNeeded зовётся из startTrip), а сюда мы попадаем строго вне
        // её — update() всегда выходил по guard, ветка была мёртвой и только
        // читалась как живой путь.
    }

    private func handleExit(regionID: String) {
        // Вошли и вышли, пока читалась база, — камера уже позади, не пугаем.
        pendingRegionEnters.exit(regionID)
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
        case .denied, .restricted:
            // Доступа нет (отозвали на ходу или не давали) — фиксов не будет.
            // Ни застывшей скорости, ни висящего оповещения (сценарий S8,
            // 20.10). Поездку не закрываем: вернут доступ — applyLocationMode
            // продолжит её, а автостарт и геозоны останутся в порядке.
            manager.stopUpdatingLocation()
            staleWatchdogTask?.cancel()
            speedDecayTask?.cancel()
            isSignalStale = true
            if speedKmh != 0 { speedKmh = 0 }
            refreshDrivingFlag()
            clearNearest()
            if isTripActive { Log.location.notice("доступ к геопозиции отозван посреди поездки") }
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
    /// «За рулём» паузы быть не должно — если случилась, поднимаем GPS сами.
    /// isForeground, а не только isTripActive: режим «CarPlay подключён без
    /// поездки» держит непрерывный GPS точно так же, и пауза там навсегда
    /// замораживала экран машины.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            Log.location.notice("система приостановила обновления геолокации")
            guard self.isTripActive || self.isForeground else { return }
            self.manager.startUpdatingLocation()
            Log.location.error("пауза при активном экране — обновления перезапущены")
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
