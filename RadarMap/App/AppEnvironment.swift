//
//  AppEnvironment.swift
//  RadarMap
//
//  Композиционный корень зависимостей. Создаётся один раз и раздаётся через SwiftUI Environment.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    /// Единый экземпляр: телефонная сцена и CarPlay работают с одним окружением —
    /// CarPlay может подключиться раньше, чем поднимется SwiftUI-сцена телефона.
    static let shared = AppEnvironment()

    let settings: AppSettings
    let cameras: CameraStore
    let notifications: NotificationService
    let alerts: AlertPlayer
    let trip: TripStats
    let location: LocationService
    let sync: RemoteSyncService
    let mobile: MobileCameraService
    let motion: MotionService
    let route = RouteService()
    let speedLimits: SpeedLimitService
    let liveActivity = LiveActivityService()
    /// Мост на Apple Watch: HUD поездки + тук на запястье.
    let watchBridge = WatchBridgeService()
    let metrics = MetricsService()
    let feedback = FeedbackService()
    /// «Пульт»: подписанный config.json с сервера. Умеет погасить маршруты,
    /// краудсорс и метрики и показать объявление — но не трогает оповещения
    /// о камерах: они обязаны работать и без сервера (см. RemoteConfig).
    let config = RemoteConfigService()
    /// Перегрев телефона: под ним карта рисует меньше и реже. Оповещения о
    /// камерах не трогаются ни на одной ступени — за рулём голос важнее картинки.
    let thermal = ThermalService()
    /// Связь: нужна ровно для честной фразы «карта серая, но камеры
    /// предупреждают» — база лежит на телефоне и сети не требует.
    let network = NetworkMonitor()
    /// Дорожные тайлы для схемы приборки: подписанный индекс, ленивые тайлы,
    /// классы дорог и мосты. Пустой источник, пока не приехали, — схема тогда
    /// берёт сеть из индекса лимитов (FallbackRoadNetwork).
    let roads = RoadNetworkService()
    /// Обезличенная статистика использования: без неё неизвестно даже, сколько
    /// людей выдаёт геолокацию «Всегда» — а без неё не работает половина продукта.
    let usage: UsageStatsService

    /// CarPlay подключён. Наблюдаемый флаг для интерфейса телефона: пока едет
    /// машина, телефонная карта уступает место дешёвому экрану передачи —
    /// рисовать MapKit на двух экранах разом значит греть телефон вдвое.
    private(set) var isCarPlayConnected = false

    /// Ставит сцена CarPlay при подключении/отключении.
    func setCarPlayConnected(_ connected: Bool) {
        isCarPlayConnected = connected
        location.setCarPlayConnected(connected)
    }

    init() {
        let settings = AppSettings()
        let cameras = CameraStore()
        self.sync = RemoteSyncService(store: cameras)
        self.mobile = MobileCameraService(store: cameras)
        self.motion = MotionService(settings: settings)
        let notifications = NotificationService(settings: settings)
        let alerts = AlertPlayer(settings: settings)
        let trip = TripStats()

        self.usage = UsageStatsService(settings: settings)
        self.settings = settings
        self.cameras = cameras
        self.notifications = notifications
        self.alerts = alerts
        self.trip = trip
        self.speedLimits = SpeedLimitService(settings: settings)
        self.location = LocationService(
            repository: cameras,
            notifier: notifications,
            settings: settings,
            alerts: alerts,
            trip: trip
        )
        self.location.liveActivity = liveActivity
        self.location.route = route
        self.location.speedLimits = speedLimits
        self.location.watchBridge = watchBridge
        self.location.thermal = thermal   // буст GPS приборки — только пока холодно

        // Пульт раздаём тем, кого он имеет право глушить. Список намеренно
        // короткий: всё это зависит от нашего сервера, а оповещения о камерах
        // работают на локальной базе и остаются вне его досягаемости.
        route.config = config
        mobile.config = config
        metrics.config = config
        usage.config = config
        usage.location = self.location

        // Автостарт/стоп поездки по движению (режим старта — в настройках).
        let location = self.location
        motion.onDrivingStart = { [weak location] in
            guard settings.tripStartMode.usesMotion, let location,
                  !location.isTripActive else { return }
            location.startTrip(auto: true)   // незнакомая машина → вопрос «вы за рулём?»
        }
        motion.onDrivingStop = { [weak location] in
            guard let location else { return }
            location.endPassengerSession()   // «я в такси» действует до конца езды
            guard location.isTripActive else { return }
            // auto: поездку закрыла автоматика, а не человек — значит её ещё можно
            // продолжить как заезд по пути (TripMerge).
            location.endTrip(auto: true)
        }
        // Ответ на «Вы за рулём?»: пассажир — гасим поездку без следа,
        // водитель — запоминаем магнитолу машины, чтобы не переспрашивать.
        notifications.onPassengerConfirmed = { [weak location] in location?.markPassenger() }
        notifications.onDriverConfirmed = { [weak location] in location?.confirmDriver() }

        // Одноразовая ретро-чистка «мостовых» проездов: оси дорог появились в
        // базе v8 — старые «проезды» поперёк оси (мост над камерой) выкидываем.
        // Строго ПОСЛЕ загрузки базы: она декодируется асинхронно, и вызов
        // прямо отсюда получал пустой список камер — миграция молча выключалась.
        cameras.onDatabaseLoaded = { [weak cameras, weak trip] in
            guard let cameras, let trip else { return }
            trip.axisCleanupIfNeeded(axisByID: Dictionary(
                uniqueKeysWithValues: cameras.cameras.compactMap { cam in
                    cam.axis.map { (cam.id, $0) }
                }))
        }

        // Конец поездки: обезличенные счётчики и недельный дайджест.
        //
        // ОДНО назначение на всё, и это не стиль. Здесь стояли два подряд, и
        // второе молча затирало первое — тринадцать строк дайджеста не
        // выполнялись никогда. Спасло только то, что второй блок повторял их
        // слово в слово; правка в первом ушла бы в никуда без единого признака.
        // `onTripFinished` — простое замыкание, а не список подписчиков, и
        // назначать его дважды нельзя по определению: композиционный корень
        // читают как ответ на вопрос «что происходит в конце поездки», и ответ
        // обязан быть один.
        let usage = self.usage
        trip.onTripFinished = { [weak trip, weak notifications, weak usage] in
            guard let trip else { return }
            // История приходит от новых к старым — только что закрытая поездка первая.
            if let last = trip.history.first {
                usage?.noteTrip(distanceMeters: last.distanceMeters)
                usage?.note { $0.passes += last.camerasPassed }
            }
            guard let notifications else { return }
            // Тот же расчёт, что на экране Итогов: пуш и экран не имеют права
            // разойтись в цифрах (раньше здесь смешивались окна 7 и 30 дней).
            let week = TripHistory.summary(days: trip.days, history: trip.history, period: .week)
            guard !week.isEmpty else { return }
            notifications.scheduleWeeklyDigest(
                distance: week.distance,
                cameras: week.cameras,
                rating: week.rating,
                cleanMonth: week.overPasses == 0
            )
        }

        // Голосовое сопровождение маршрута: перестроение, прибытие, манёвры.
        route.onRerouted = { [weak alerts] in
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Маршрут перестроен"))
        }
        route.onArrived = { [weak alerts] in
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Вы прибыли"))
        }
        route.onManeuver = { [weak alerts] text in
            guard settings.turnByTurnVoice else { return }
            alerts?.speak(text)
        }
        speedLimits.onOverspeed = { [weak alerts] in
            alerts?.speak(String(localized: "Превышение скорости"))
        }
    }

    var loadError: String? { cameras.loadError }

    /// Сервисы, нужные любой АКТИВНОЙ сцене — телефонной и CarPlay.
    ///
    /// CarPlay может подключиться первым (телефон остался в кармане), а раньше
    /// весь этот набор стартовал только из телефонной сцены: поездка из машины
    /// шла без базы лимитов — каждый проезд без limitKmh, то есть без рейтинга
    /// и «возможных штрафов», — без краудсорсных радаров и без автостарта по
    /// движению. Все старты идемпотентны, повторный вызов из второй сцены
    /// ничего не дублирует.
    func startDrivingServices() {
        // Пульт — первым: он может отменить всё, что запускается следом.
        Task { await config.refreshIfNeeded() }
        // Досылаем вчерашние счётчики (сегодняшние ещё не полны).
        Task { await usage.flush() }
        // Тихая проверка обновлений базы (не чаще раза в сутки), не блокирует UI.
        Task { await sync.autoCheckIfNeeded() }
        // Дослать репорты/фидбек, не ушедшие в прошлый раз (офлайн-очередь).
        Task { await feedback.flushPending() }
        speedLimits.start()   // база лимитов: локально сразу, сервер раз в неделю
        roads.start()         // дорожные тайлы: индекс локально сразу, сервер раз в неделю
        metrics.start()       // MetricKit: суточные отчёты о батарее/крашах
        guard Storage.bool(.hasCompletedOnboarding) else { return }
        location.bootstrap()
        mobile.startPolling()
        motion.start()
    }
}
