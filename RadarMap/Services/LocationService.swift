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

    // Тип разрезан на расширения по файлам (LocationService+*.swift, план
    // 3.2): сеттеры состояния, которое пишут расширения, внутренние — у Swift
    // нет «приватного для типа» сеттера через границу файла. Писать их можно
    // ТОЛЬКО из LocationService*.swift; снаружи — только читать (ревью).
    let manager = CLLocationManager()
    let repository: CameraRepository
    let notifier: NotificationService
    let settings: AppSettings
    let alerts: AlertPlayer
    let trip: TripStats
    /// Live Activity на локскрине (подключается после инициализации, см. AppEnvironment).
    @ObservationIgnored weak var liveActivity: LiveActivityService?
    /// Призрак дороги на работу для плашки Live Activity (8.8.3б): прибытие,
    /// готовая подпись на языке приложения и тревожность. Подаёт
    /// AppEnvironment из CommuteLiveService — сервис геопозиции о призраке не знает.
    @ObservationIgnored var activityGhost: (() -> (clock: Date, caption: String, alert: Bool)?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: activityGhost,
                                               "LocationService.activityGhost") }
    }
    @ObservationIgnored weak var watchBridge: WatchBridgeService?
    @ObservationIgnored weak var route: RouteService?
    @ObservationIgnored weak var speedLimits: SpeedLimitService?
    /// Память о треногах: места, где водители отмечали радар снова и снова.
    @ObservationIgnored weak var hotspots: HotspotService?
    /// О каких точках уже сказали в этой поездке. Живёт только в памяти:
    /// повторяться нельзя внутри поездки, а завтра то же место — снова новость.
    @ObservationIgnored var voicedHotspots: Set<Int64> = []
    /// Перекрытия и ремонт (12б.5): ставит AppEnvironment (MobileCameraService).
    /// Голос — один раз за поездку на событие (`voicedRoadEvents`).
    @ObservationIgnored var roadEvents: (() -> [RoadEvent])?
    /// Скорость погасла до нуля без нового фикса — стоим (метан, 12б.4).
    @ObservationIgnored var onStoppedWithoutFix: ((CLLocationCoordinate2D) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onStoppedWithoutFix,
                                               "LocationService.onStoppedWithoutFix") }
    }
    @ObservationIgnored var voicedRoadEvents: Set<Int> = []
    /// Погода на перевалах (19.2): ставит AppEnvironment. Голос — ниже камеры
    /// (LocationService+RoadWeather).
    @ObservationIgnored weak var roadWeather: RoadWeatherService?
    /// CoreMotion: «телефон стоит» — сторож сигнала не объявляет потерю.
    @ObservationIgnored weak var motion: MotionService?

    var authorizationStatus: CLAuthorizationStatus
    var currentCoordinate: CLLocationCoordinate2D? {
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
    /// «Где машина» (ParkedCar): точка конца поездки за рулём. Хранится на
    /// телефоне, сбрасывается новой поездкой, возвращением и сроком.
    @ObservationIgnored var parkedCar: ParkedCar? = ParkedCar.load() {
        didSet { if parkedCar != oldValue { ParkedCar.save(parkedCar) } }
    }
    /// Машина на карте (метка) — меняется только на показе и скрытии: её читает
    /// слой карты, и запись на каждом фиксе пересобирала бы его.
    var parkedCarOnMap: ParkedCar?
    /// Строка «Машина · 350 м» — ступенями (ParkedCar.Hint); читает только она.
    var parkedCarHint: ParkedCar.Hint?
    @ObservationIgnored var parkedCarRecheck: Task<Void, Never>?
    /// Последняя точка, где ещё ехали (ParkedCar.Fix): ею паркуемся.
    @ObservationIgnored var lastDrivenFix: ParkedCar.Fix?
    var speedKmh: Double = 0 { didSet { refreshApproachFlags() } }

    /// GPS-курс движения (0–360°, −1 = недостоверен: стоим или нет сигнала).
    var currentCourse: CLLocationDegrees = -1
    /// 20 ближайших камер — для списка «рядом» и Live Activity (столько же
    /// геозон, сколько разрешает iOS).
    var nearbyCameras: [Camera] = []
    /// Окно кандидатов на оповещение: шире двадцатки геозон, потому что в
    /// плотном городе 20-я камера бывает ближе, чем мы успеваем проехать до
    /// следующего пересчёта, — и камера впереди выпадала из кандидатов.
    @ObservationIgnored var trackedCameras: [Camera] = []
    /// Радиус окна кандидатов (до самой дальней камеры в нём) — по нему
    /// решается, когда пересчёт обязателен.
    @ObservationIgnored var trackedRadius: CLLocationDistance = 0
    var nearestCamera: Camera?
    /// Камеры вплотную за ближайшей (перекрёсток, где их две-три): голос говорит
    /// о них одной фразой, поэтому их собственный анонс потом пропускается.
    @ObservationIgnored var clusteredCameras: [Camera] = []
    /// Про эти камеры голос уже сказал групповой фразой — второй раз не надо.
    @ObservationIgnored var voicedInGroup: Set<Int> = []
    /// Солнце для ночного голоса (12.6), с моментом расчёта: пересчёт не
    /// чаще `nightVoiceRecheckSeconds` — план голоса читается на тиках у камеры.
    @ObservationIgnored var sunForVoice: (at: Date, day: Bool)?
    /// Камера, о которой голос промолчал, потому что мы ползли в пробке: скажем
    /// про неё, как только поедем (пока она ещё впереди и в радиусе).
    @ObservationIgnored var postponedVoice: Int?
    var distanceToNearest: CLLocationDistance? { didSet { refreshApproachFlags() } }

    /// Камера, которую показ держит ВМЕСТО камеры предупреждения (25.I): ниже
    /// порога гейтов недолго — последняя «наша впереди», а не боковая.
    /// nil почти всегда — тогда показ и есть `nearestCamera`. Пишется только
    /// на тиках удержания.
    struct HeldNearest: Equatable {
        let camera: Camera
        let distance: CLLocationDistance
    }
    var heldNearest: HeldNearest?
    @ObservationIgnored var nearestDisplayHold = NearestDisplayHold()

    /// Ближайшая камера ДЛЯ ПОКАЗА: HUD, чип, часы, Live Activity, кадр и
    /// маркер карты. Не мигает на пороге 10 км/ч в пробке (NearestDisplayHold).
    /// Тревога, уровни, голос, баннеры и полноэкранное предупреждение читают
    /// `nearestCamera`/`distanceToNearest` — их выбор удержание не трогает.
    var displayNearestCamera: Camera? { heldNearest?.camera ?? nearestCamera }
    /// Расстояние до `displayNearestCamera` — так же, как у предупреждения:
    /// по маршруту или по прямой.
    var displayDistanceToNearest: CLLocationDistance? {
        heldNearest.map(\.distance) ?? distanceToNearest
    }
    /// false = пользователь дал только «приблизительную» геолокацию — оповещения ненадёжны.
    var hasFullAccuracy = true
    /// Режим энергосбережения iOS: снижаем точность GPS (голос о камерах — как всегда).
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Режим «Поездка»: непрерывная геолокация + активные оповещения даже в свёрнутом виде.
    var isTripActive = false { didSet { refreshApproachFlags() } }

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
    var isProbablyDriving = false

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
    @ObservationIgnored var anchor: CLLocationCoordinate2D?
    @ObservationIgnored var alertedCameraIDs: Set<Int> = []   // фон, дебаунс уведомлений
    /// Гейт качества фикса и доверенный курс (чистый модуль, покрыт тестами).
    @ObservationIgnored var locationFilter = LocationFilter()
    /// Номер последнего принятого фикса — по нему сторож определяет, что новых нет.
    @ObservationIgnored var fixSequence = 0
    /// true — фиксов нет дольше gpsStaleSeconds: данные на экране устарели.
    var isSignalStale = false { didSet { refreshApproachFlags() } }
    /// Позиция получена из фикса, который в алерты не пускается: кэш при запуске
    /// или слабый сигнал в помещении. Окрестности показать можно, но расстояние
    /// на панели нельзя подавать как живое.
    var isPositionCoarse = false
    /// Когда последний раз пришёл ГОДНЫЙ фикс — по нему решаем, устарела ли
    /// позиция настолько, что грубая точка будет лучше.
    @ObservationIgnored var lastAcceptedAt: Date?
    /// Погрешность последнего принятого фикса (метры): на ней смягчаются
    /// геометрические проверки — на плохом фиксе они не должны ничего отбрасывать.
    /// @ObservationIgnored намеренно: пишется каждый тик, а читается только
    /// изнутри сервиса — будить SwiftUI-подписчиков этой записью значило бы
    /// перерисовывать экран раз в секунду ради числа, которого нет на экране.
    @ObservationIgnored var horizontalAccuracy: Double = -1
    /// Последний принятый фикс подменён программой (LocationFilter.Fix.isSimulated).
    @ObservationIgnored var isFixSimulated = false
    /// Пороги приближения (передний план): чистый движок, покрыт тестами.
    @ObservationIgnored var alertEngine = AlertEngine()
    /// Учёт прохождения камер (траверз + зона измерения): чистый модуль, покрыт тестами.
    @ObservationIgnored var passTracking = PassTracking()
    /// Охват предупреждений за поездку: камеры, мимо которых проехали, против
    /// камер, о которых сказали. Считается НЕЗАВИСИМО от записи проезда — у
    /// той свои, намеренно более строгие гейты, и мерить ими себя нельзя.
    @ObservationIgnored var alertRecall = AlertRecall()
    /// Детектор «город/трасса» для умного режима оповещений (чистый, покрыт тестами).
    @ObservationIgnored var contextDetector = AlertPolicy.Detector()
    /// Камер в радиусе 3 км — сигнал плотности для детектора (пересчёт на ретайле).
    @ObservationIgnored var cameraDensity3km = 0
    /// «Свои» камеры: проезжаем регулярно и спокойно — голос о них молчит
    /// (см. CameraFamiliarity). Пересчитывается на старте поездки: история за
    /// 30 дней меняется медленно, а на тике это была бы лишняя работа.
    /// Наблюдаемое намеренно: маркер на карте и HUD показывают спокойное
    /// состояние, иначе тишина выглядит поломкой, а не заботой.
    var familiarCameraIDs: Set<Int> = []
    /// Текущий контекст для чипа на HUD (в режиме «Авто»).
    var alertContext: AlertPolicy.Context = .city { didSet { refreshApproachFlags() } }
    // Два независимых «передних плана»: телефонная сцена и CarPlay. Один флаг
    // они затирали друг другу (блокировка телефона в машине замораживала HUD CarPlay,
    // а отключение CarPlay в фоне навсегда оставляло «передний» режим GPS).
    @ObservationIgnored var isPhoneForeground = false
    @ObservationIgnored var isCarPlayConnected = false
    var isForeground: Bool { isPhoneForeground || isCarPlayConnected }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    /// Доступ «Всегда». «При использовании» держит экран машины живым, но
    /// фоновые оповещения, геозоны и автостарт при нём молча не работают —
    /// об этой деградации интерфейс обязан говорить, а не догадываться.
    var isAlwaysAuthorized: Bool { authorizationStatus == .authorizedAlways }

    /// Окно повышения до «Всегда» уже запрашивали: iOS показывает его один
    /// раз, дальше кнопка ведёт в Настройки (LocationAccessStep). Наблюдаемое:
    /// отказ в окне статус не меняет, а подсказка под кнопкой появиться должна.
    private(set) var alwaysAccessAsked = Storage.bool(.alwaysAccessAsked) {
        didSet { Storage.set(alwaysAccessAsked, for: .alwaysAccessAsked) }
    }

    /// Что сейчас сделает кнопка доступа к геопозиции.
    var accessStep: LocationAccessStep {
        LocationAccessStep.next(status: authorizationStatus, alwaysAsked: alwaysAccessAsked)
    }

    /// Шаг к «Всегда» по кнопке (онбординг, баннер на карте). Окна iOS
    /// больше не будет — открываем Настройки приложения.
    func takeAccessStep() {
        switch accessStep {
        case .askWhenInUse: bootstrap()   // спросит «При использовании», как и раньше
        case .askAlways: requestAlwaysAccess()
        case .openSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .done: break
        }
    }

    /// Единственное место, где просим «Всегда»: запрос помечается, чтобы
    /// следующее касание вело в Настройки, а не в пустоту.
    func requestAlwaysAccess() {
        #if DEBUG
        // Скриншот-автоматизация: симулятор показывает диалог апгрейда «Всегда»
        // на каждом запуске и перекрывает экран — в тестовых прогонах не просим.
        if ProcessInfo.processInfo.arguments.contains("-skipAlwaysPrompt") { return }
        #endif
        // Без лишней записи: каждая будит наблюдателей, а зовут нас и на
        // каждом запуске с «При использовании».
        if !alwaysAccessAsked { alwaysAccessAsked = true }
        manager.requestAlwaysAuthorization()
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

    func powerModeChanged(_ low: Bool) {
        isLowPowerMode = low
        applyLocationMode()
    }

    // MARK: - Разрешения / запуск

    func bootstrap() {
        // «Свои» камеры нужны и вне поездки: карта рисует их спокойными, и
        // список обязан быть готов до первого показа маркеров.
        refreshFamiliarCameras()
        #if DEBUG
        // Снимки «Где машина»: машина в ~330 м к северу от точки симулятора
        // по умолчанию (41.3111, 69.2797), поставлена 10 минут назад.
        if ProcessInfo.processInfo.arguments.contains("-demoParkedCar") {
            parkedCar = ParkedCar(lat: 41.3141, lon: 69.2797,
                                  parkedAt: Date().addingTimeInterval(-600), hasLeft: true)
        }
        #endif
        refreshParkedCar()   // трое суток могли пройти, пока приложение спало
        // Плашка прошлого процесса подхвачена (S14): поездка не возобновилась
        // за пару минут — сирота, снять, а не держать до восьмичасового предела.
        if liveActivity?.isActive == true {
            Task { [weak self] in
                await Task.pause(seconds: AppConfig.liveActivityOrphanGraceSeconds)
                guard let self, !self.isTripActive, self.liveActivity?.isActive == true else { return }
                Log.alerts.notice("Live Activity прошлого процесса снята: поездки нет")
                self.liveActivity?.end()
            }
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            requestAlwaysAccess()
            startBackgroundMonitoring()
        case .authorizedAlways:
            startBackgroundMonitoring()
        default:
            break
        }
    }

    func startBackgroundMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    /// Пассажирская сессия («я в такси»): автостарт молчит до конца этой езды.
    /// Хранится со сроком: система перезапускает приложение посреди езды, и
    /// в такси вопрос «вы за рулём?» звучал на каждом пробуждении (S29).
    var isPassengerSession = LocationService.passengerSessionRestored(
        until: Storage.date(.passengerSessionUntil), now: Date()) {
        didSet {
            guard isPassengerSession != oldValue else { return }
            if isPassengerSession {
                Storage.set(Date().addingTimeInterval(AppConfig.passengerSessionMaxSeconds),
                            for: .passengerSessionUntil)
            } else {
                Storage.remove(.passengerSessionUntil)
            }
        }
    }

    /// Тир точности GPS в поездке. Переключаем только на границах (гистерезис по тиру),
    /// а не каждый тик — реконфигурация CLLocationManager не бесплатна.
    @ObservationIgnored var accuracyTier = -1

    @ObservationIgnored var accuracyWatched = false

    /// Открытый экран сейчас на «лежачей» точности.
    @ObservationIgnored var foregroundIdle = false
    /// Где легли (выход из «лежачей» точности — по сдвигу от этой точки).
    @ObservationIgnored var idleAnchor: CLLocationCoordinate2D?

    /// Геозоны сейчас стоят вокруг актуальной точки. Ложь означает «их надо
    /// пересобрать при первом же уходе в тихий фон».
    @ObservationIgnored var geofencesArmed = false
    /// Что именно стоит в locationd — чтобы не переставлять то же самое.
    @ObservationIgnored var geofencePlan = GeofencePlan()

    // MARK: - Обработчики (MainActor)

    /// Растёт на каждое обновление локации — карта в режиме следования подписывается на это.
    var locationTick = 0
    /// Цифра спидометра: стоянка, сглаживание по времени и молчание GPS в
    /// одном порядке (чистая структура, покрыта SpeedometerTests).
    @ObservationIgnored var speedometer = Speedometer()
    /// Прижим картинки к оси дороги (чистая структура, RoadSnapperTests).
    @ObservationIgnored var roadSnapper = RoadSnapper()
    /// Координата и курс ДЛЯ КАРТИНКИ: прижаты к оси дороги, когда мы на ней
    /// (схема приборки, ведение камеры карты). Гейты оповещений, запись
    /// проездов и трек этим НЕ пользуются — они работают по сырому фиксу:
    /// подменять измерение предположением там, где решается «глушить или
    /// предупреждать», нельзя (см. RoadSnapper).
    var displayCoordinate: CLLocationCoordinate2D?
    var displayCourse: CLLocationDirection = -1
    /// Курс оси дороги под прижатой точкой (RoadSnapper), пока прижим держит и
    /// курс дороги совпал с нашим; nil — прижима нет. Пишется только на смене
    /// отрезка. Только картинка: камера на оси нашей дороги без маршрута
    /// (CameraOnLine.roadSpot, 27.B).
    var displayRoadBearing: Double?
    /// Последний фикс для значка «я» между фиксами (MarkerPredictor): точка и
    /// курс — те же displayCoordinate/displayCourse, плюс скорость, время
    /// фикса и линия маршрута вперёд. Пишется раз на фикс, в том же тике,
    /// что и displayCoordinate, — лишней перерисовки нет. Только картинка.
    var markerMotion: MarkerPredictor.Fix?
    /// Когда машина в последний раз реально двигалась (для тира «стоянка»).
    @ObservationIgnored var lastMovementAt = Date()
    /// Последняя точка, по которой считали прогресс маршрута (гейт стоянки).
    @ObservationIgnored var lastRouteProgressCoordinate: CLLocationCoordinate2D?
    /// Прибытие к цели, после которого поездка закроется сама на стоянке
    /// (ArrivalFinish). Своя копия: карточку «Вы на месте» закрывают крестиком
    /// и таймером, а следить надо дальше.
    @ObservationIgnored var arrivalWatch: ArrivalFinish.Arrival?
    /// Проверка без фикса: на стоянке их нет (distanceFilter).
    @ObservationIgnored var arrivalRecheck: Task<Void, Never>?
    /// Как кончилась последняя поездка — ставится до `onTripStateChanged(false)`:
    /// близким (22.1) мало «поездки нет» — им нужно «у цели», «рукой» или
    /// «автостоп» (магазин по пути склеится, «Стоп» — нет).
    @ObservationIgnored var lastTripEnd: (kind: NavigationFlow.TripEnd, atDestination: Bool) = (.manual, false)

    /// Единственная точка входа фиксов: сначала гейт качества, потом обработка.
    /// Отброшенный фикс не двигает ни трек, ни алерты, ни спидометр.

    /// Время последнего принятого фикса (для трека поездки).
    @ObservationIgnored var lastFixTime = Date()

    @ObservationIgnored var staleWatchdogTask: Task<Void, Never>?

    @ObservationIgnored var speedDecayTask: Task<Void, Never>?
    /// Стоянка: скорость 0 и неподвижная стрелка, пока приёмник гуляет на
    /// месте (Standstill внутри Speedometer). Только скорость и картинка —
    /// гейты по сырому фиксу.
    var standstill: Standstill { speedometer.standstill }
    /// Что рисовать на стоянке: отображаемая точка (уже на оси дороги или
    /// маршрута) и курс в момент остановки.
    @ObservationIgnored var frozenDisplay: (coordinate: CLLocationCoordinate2D, course: Double)?

    /// Непрерывный уровень тревоги (та же лестница порогов, что в AlertEngine):
    /// 0 — тихо, 1…3 — эскалация. Его показывают часы и приборная панель CarPlay.
    ///
    /// Хранимый, а не вычисляемый — как и `isApproachingCamera` ниже. Внутри
    /// вычисляемого читались дистанция и скорость, которые пишутся КАЖДЫМ
    /// фиксом, и каждый, кто смотрел на флаг, становился подписчиком тика:
    /// корень экрана CarPlay пересобирался раз в секунду, а наблюдатели
    /// CarPlay заводили по задаче на тик (аудит 11.10). Хранимое значение
    /// будит читателей только на смене — несколько раз за камеру.
    var alertLevel = 0
    /// Полноэкранное предупреждение: движемся и ближайшая камера в радиусе
    /// оповещения. Без свежего фикса расстояние на экране — вчерашняя правда:
    /// панель прячем, но состояние эскалации не трогаем (иначе после туннеля
    /// заорём заново).
    var isApproachingCamera = false

    /// Сглаженный азимут камеры относительно курса (0 = прямо по ходу, растёт по часовой).
    /// nil — стоим/курс недостоверен. Камера на активном маршруте — всегда «прямо»:
    /// она на твоём пути по определению, боковое смещение точки в базе не путает.
    @ObservationIgnored var bearingSmoother = AngleSmoother()
    var relativeBearingToNearest: Double?

    @ObservationIgnored var nearestBuffer: [LocationGates.Candidate] = []
    /// Ближайшая выбрана по остатку маршрута (а не по прямой): фраза «по
    /// маршруту» и «прямо по ходу» — только тогда. Проеханная камера маршрута,
    /// снова впереди по прямой после разворота, — уже не «по маршруту».
    @ObservationIgnored var nearestViaRoute = false
    /// Время фикса, по которому последний раз считалась серия «проехали».
    @ObservationIgnored var geometryFixTime: Date?

    /// Входы в геозоны, пришедшие раньше базы камер: приложение подняли в
    /// фоне именно этим событием, а база ещё читается (декод асинхронный).
    /// Вход второй раз не придёт — телефон уже внутри (сценарий S3, 20.10).
    @ObservationIgnored var pendingRegionEnters = RegionEnterQueue()

    // MARK: Тихий фон и своя машина (этап 26)

    /// Своя машина подключена (CarLinkService) — ставит AppEnvironment.
    @ObservationIgnored var carLinked: (() -> Bool)?
    /// Поколение чтения аудио-портов для автостарта: решает последнее.
    @ObservationIgnored var autoStartRead = 0
    /// Пробуждение тихого фона (фикс, геозона): AppEnvironment перечитывает
    /// аудио-маршрут — Bluetooth машины сам приложение не будит.
    @ObservationIgnored var onQuietWake: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onQuietWake,
                                               "LocationService.onQuietWake") }
    }
    /// Идущая поездка началась от подключения к машине (или застала его):
    /// отключение её закончит («Только в машине»).
    @ObservationIgnored var tripFromCarLink = false
    /// Сырые фиксы тихого фона — доказательство езды для QuietAlertGate.
    @ObservationIgnored var quietFixes: [LocationFilter.Fix] = []
    /// Камеры, по которым решение тихого фона ещё ждёт доказательства.
    @ObservationIgnored var quietPending: Set<Int> = []
    /// Выученные Дом/Работа (FrequentPlaces) — ставит AppEnvironment и
    /// хранит на диске: геозона будит процесс без сцены, выученное там не
    /// пересчитывается.
    @ObservationIgnored var learnedQuietZones: [CLLocationCoordinate2D] =
        (Storage.decoded([[Double]].self, for: .quietZones) ?? [])
            .compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } {
        didSet {
            Storage.encode(learnedQuietZones.map { [$0.latitude, $0.longitude] }, for: .quietZones)
        }
    }

}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    // nonisolated, как остальные шесть колбэков: с дефолтной MainActor-изоляцией
    // витнесс nonisolated-требования ObjC-протокола получал динамический
    // precondition на самом горячем колбэке.
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        // Пачка (после фоновой паузы, после занятого главного потока) — все
        // точки по порядку, а не только последняя: иначе пробег шёл хордой, а
        // проезд камеры между точками пропадал вовсе (S13, 20.10). Устаревшие
        // (старше maxFixAgeSeconds) фильтр отбросит сам.
        let fixes = locations.map(LocationFilter.Fix.init)
        guard !fixes.isEmpty else { return }
        Task { @MainActor in
            for fix in fixes { self.handleFix(fix) }
        }
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
