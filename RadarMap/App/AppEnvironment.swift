//
//  AppEnvironment.swift
//  RadarMap
//
//  Композиционный корень зависимостей. Создаётся один раз и раздаётся через SwiftUI Environment.
//

import CoreLocation
import Foundation
import Observation
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppEnvironment {

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
    /// Офлайн-карты: скачанные области для карты без связи.
    let offlineMaps = OfflineMapService()
    /// Дорожные тайлы: подписанный индекс, ленивые тайлы улиц вокруг машины
    /// (посадка отметки «Радар!» на дорогу, схема развязки в CarPlay) и файлы
    /// адресов и заведений для поиска. Пока тайлы не приехали — индекс
    /// лимитов (`roads.vehicleNetwork`).
    let roads = RoadNetworkService()
    /// Профиль дороги дом↔работа по участкам и журнал поездок для «дороги».
    let commuteProfiles = CommuteProfileStore()
    /// «Поделиться прибытием» — ссылка с временем прибытия для знакомого.
    let etaShare = EtaShareService()
    /// Горячие точки треног: подписанный список мест, где водители отмечали
    /// радар снова и снова. Не камеры и не отметки — память, поэтому и живут
    /// отдельным сервисом с недельным обновлением и своим тихим тоном.
    let hotspots = HotspotService()
    /// Обезличенная статистика использования: без неё неизвестно даже, сколько
    /// людей выдаёт геолокацию «Всегда» — а без неё не работает половина продукта.
    let usage: UsageStatsService
    /// Пробки: помогаем считать (куски следа поездки) и показываем (карта,
    /// время маршрута). На оповещения не влияют.
    let traffic: TrafficService

    /// CarPlay подключён. Наблюдаемый флаг для интерфейса телефона: пока едет
    /// машина, телефонная карта уступает место дешёвому экрану передачи —
    /// рисовать MapKit на двух экранах разом значит греть телефон вдвое.
    private(set) var isCarPlayConnected = false
    /// Телефонная сцена активна (ставит RootView). Вместе с isCarPlayConnected
    /// отвечает на вопрос «смотрит ли кто-нибудь на экран»: опрос передвижных
    /// радаров жив, пока жив ХОТЬ ОДИН экран, — раньше он был привязан только
    /// к телефонной сцене и тёк в обе стороны (поездка «только CarPlay»
    /// опрашивала сервер вечно, а телефон в кармане глушил отметки на экране
    /// машины).
    @ObservationIgnored private(set) var isPhoneSceneActive = false

    /// Ставит сцена CarPlay при подключении/отключении.
    func setCarPlayConnected(_ connected: Bool) {
        isCarPlayConnected = connected
        location.setCarPlayConnected(connected)
        refreshTrafficWanted()
        if connected {
            mobile.startPolling()
        } else if !isPhoneSceneActive, !mobile.isTripActive {
            mobile.stopPolling()
        }
    }

    /// Тема интерфейса: днём светлая, ночью тёмная — по той же настройке, что
    /// подложка карты (`AppSettings.mapAppearance`; «Авто» — по солнцу в точке
    /// пользователя). Пишется только на смене: её читает корень приложения, и
    /// запись на каждом пересчёте пересобирала бы всё дерево.
    private(set) var interfaceIsDaylight = false

    /// Пересчёт темы: на старте, при открытии, при смене настройки и раз в
    /// пять минут (RootView) — закат не ждёт перезапуска.
    func refreshInterfaceAppearance() {
        let day = settings.mapAppearance.isDaylight(at: location.currentCoordinate, now: Date())
        if day != interfaceIsDaylight { interfaceIsDaylight = day }
    }

    /// Пробки нужны, пока на них кто-то смотрит: экран телефона, машина или
    /// идущая поездка (её время в пути).
    func refreshTrafficWanted() {
        traffic.setWanted(isPhoneSceneActive || isCarPlayConnected || location.isTripActive)
    }

    /// Ставит RootView по scenePhase телефона.
    func setPhoneSceneActive(_ active: Bool) {
        isPhoneSceneActive = active
        refreshTrafficWanted()
        if active {
            mobile.startPolling()
        } else if !isCarPlayConnected, !mobile.isTripActive {
            // Экран погас, но человек едет — опрос продолжается: это и есть
            // единственный момент, когда чужая отметка чего-то стоит.
            mobile.stopPolling()
        }
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
        self.traffic = TrafficService(settings: settings)
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
        self.location.hotspots = hotspots
        self.location.watchBridge = watchBridge
        self.location.motion = motion     // «стоим» — сигнал не потерян
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
        // Опрос чужих отметок живёт по поездке, а не по экрану: за рулём телефон
        // обычно в кармане или экран погашен — а это ровно тот момент, когда
        // отметка о треноге впереди и должна доехать.
        location.onTripStateChanged = { [weak self] active in
            guard let self else { return }
            self.mobile.setTripActive(active)
            if active { self.traffic.tripStarted() } else { self.traffic.tripEnded() }
            self.refreshTrafficWanted()
            if !active, !self.isPhoneSceneActive, !self.isCarPlayConnected {
                self.mobile.stopPolling()
            }
        }
        // Ответ на «Вы за рулём?»: пассажир — гасим поездку без следа,
        // водитель — запоминаем магнитолу машины, чтобы не переспрашивать.
        notifications.onPassengerConfirmed = { [weak location] in location?.markPassenger() }
        notifications.onDriverConfirmed = { [weak location] in location?.confirmDriver() }

        // Одноразовая ретро-чистка «мостовых» проездов: оси дорог появились в
        // базе v8 — старые «проезды» поперёк оси (мост над камерой) выкидываем.
        // Строго ПОСЛЕ загрузки базы: она декодируется асинхронно, и вызов
        // прямо отсюда получал пустой список камер — миграция молча выключалась.
        // История приезжает с диска уже после первого кадра, поэтому всё,
        // что из неё выводится, пересчитывается по этому сигналу, а не один
        // раз на старте сцены.
        mobile.onReportSent = { [weak usage] in usage?.noteReport() }
        // Счётчик оповещений уходил на сервер вечным нулём: метод существовал,
        // а звать его было некому. Главная цифра воронки — «сколько раз в день
        // приложение реально предупредило» — была ложью.
        location.onAlertFired = { [weak usage] in usage?.noteAlert() }
        // Качество решений, а не только их число (plan_algorithms.md, А3).
        // Счётчик проездов был такой же ложью, что и счётчик оповещений:
        // notePass существовал и не звался ниоткуда. Теперь он подключён и
        // заодно приносит источник лимита, которым проезд судили.
        location.onPassRecorded = { [weak usage] source in usage?.notePass(limitSource: source) }
        // Охват предупреждений: цифра уходит и в суточный отчёт, и в Итоги —
        // человек вправе видеть, как работает то, за чем он это приложение
        // держит, не хуже, чем это видим мы.
        location.onAlertRecall = { [weak usage, weak trip] tally in
            usage?.noteAlertRecall(tally)
            trip?.addAlertRecall(tally)
        }
        // Голос о камерах — отдельно от срабатываний: жалоба «он говорит»
        // была про фразы, а счётчик до сих пор считал баннеры.
        location.onCameraSpoken = { [weak usage] grade in usage?.noteCameraSpoken(grade) }
        // «Радар ещё стоял?» — наблюдение за проездом мимо передвижных точек
        // на каждом фиксе, и с погашенным экраном тоже (MobileCameraService).
        location.onAcceptedFix = { [weak self, weak mobile, weak traffic, weak location, weak route, weak alerts] coordinate in
            // Без withAnimation: транзакция анимации на КАЖДОМ фиксе, в том
            // числе в фоне, ради смены вопроса раз в поездку. Появление
            // вопроса анимирует сам гейт (MobileConfirmGate).
            mobile?.trackPasses(from: coordinate)
            // Улицы вокруг машины — для посадки «Радар!» на дорогу и схемы
            // развязки в CarPlay. После удаления схемы приборки (11.10)
            // ensureCoverage не звал никто, сеть была пустой, и отметки уходили
            // сырой координатой водителя (аудит 19.10). В поездке, с машиной
            // или когда похоже, что едем без поездки («Радар!» доступен и так);
            // гейт внутри — дёшево, пока окрестность та же.
            if let self, let location,
               location.isTripActive || location.isProbablyDriving || self.isCarPlayConnected {
                self.roads.ensureCoverage(around: coordinate)
            }
            traffic?.note(coordinate, speedKmh: location?.speedKmh ?? -1)
            if let traffic, let route, route.isActive { route.refreshTrafficDelay(revision: traffic.revision) }
            // «Впереди пробка» — только без маршрута: с маршрутом пробки уже в
            // ETA и в предложении объезда. Одна фраза на пробку (JamAhead).
            if let traffic, let location, let route, location.isTripActive, !route.isActive,
               settings.voiceEnabled,
               let jam = traffic.jamToAnnounce(position: coordinate, course: location.currentCourse) {
                alerts?.speak(jam.spoken)
            }
        }
        route.trafficSnapshot = { [weak traffic] in
            guard let traffic, traffic.isShown, let snapshot = traffic.snapshot,
                  snapshot.isFresh(now: Date()) else { return nil }
            return snapshot
        }
        // Пробки: пульт и сеть — отсюда; приватные зоны — дом, работа (ручные и
        // выученные) и все сохранённые места: рядом с ними след не собирается.
        traffic.allowedByConfig = { [weak config] in config?.current.isTrafficEnabled ?? true }
        etaShare.route = route
        etaShare.allowedByConfig = { [weak config] in config?.current.isEtaShareEnabled ?? true }
        traffic.isOnline = { [weak network] in network?.isOnline ?? false }
        traffic.privacyZones = { [weak self] in
            guard let self else { return [] }
            // Выученные места считаются и при выключенных подсказках: зона
            // нужна для защиты, а не для подсказки, и никуда не сохраняется.
            let learned = self.learnedPlaces.isEmpty
                ? FrequentPlaces.learn(history: self.trip.history, now: Date())
                : self.learnedPlaces
            var zones = learned.map(\.coordinate)
            zones += [self.settings.place(for: .home), self.settings.place(for: .work)]
                .compactMap { $0?.coordinate }
            return zones
        }
        route.onManeuverSpoken = { [weak usage] kind in usage?.noteManeuver(kind) }
        trip.onTripDropped = { [weak usage] reason in usage?.noteTripDropped(reason) }
        // Поездка дом↔работа — строкой в профиль участков (будущий «призрак»).
        // Направление — тем же правилом, что «Дорога на работу» в Итогах.
        trip.onTrackFinished = { [weak self] record, track, times in
            guard let self, self.settings.commuteLearning, let ends = self.commuteEnds,
                  let direction = Commute.trips(history: [record], home: ends.home,
                                                work: ends.work).first?.direction else { return }
            self.commuteProfiles.ingest(record: record, track: track, times: times,
                                        direction: direction, limits: self.speedLimits.limitIndex)
        }
        // Стёртые человеком поездки забываются и в журнале, и в профиле.
        trip.onRecordsErased = { [weak self] ids in
            self?.commuteProfiles.forget(ids)
            self?.refreshCommute()
        }
        commuteProfiles.onLoaded = { [weak self] in self?.refreshCommute() }
        trip.recordsTimedTrack = settings.recordTimedTrack
        // Снап отметки на ось дороги и очередь без сети — обе зависимости
        // слабые: отметка обязана уходить и когда тайлов нет, и когда сеть
        // молчит.
        mobile.roads = roads
        mobile.network = network
        // Где тайлов улиц ещё нет — линии из индекса лимитов: он уже лежит на
        // телефоне и знает настоящие оси дорог (класса не знает — посадке
        // отметки класс не нужен).
        roads.fallbackSource = { [weak speedLimits] in speedLimits?.limitIndex }
        // Тайлы дорог — туда же: без покрытия сеть не будится, диск читается
        // как читался (см. RoadNetworkService.load).
        roads.connectivity = network
        // Единственная новость, ради которой стоит трогать человека по поводу
        // краудсорса: она отвечает на вопрос «работает ли мой тап вообще».
        // Расписание опроса смотрит на скорость и на нагрев: чаще на трассе,
        // где чужая отметка устаревает за минуту, реже на стоянке и на жаре.
        mobile.drivingContext = { [weak location, weak thermal] in
            (speedKmh: location?.speedKmh ?? 0, thermal: thermal?.mode ?? .full)
        }
        mobile.onMyReportConfirmed = { [weak notifications] report in
            let kind = ReportKind(rawValue: report.kind)?.title
                ?? String(localized: "отметка")
            notifications?.notifyReportConfirmed(kind: kind)
        }
        trip.onHistoryLoaded = { [weak self] in
            self?.refreshLearnedPlaces()
            self?.refreshWidgetSnapshot()
            // «Свои камеры» считаются ПО ИСТОРИИ, а bootstrap() успевает
            // раньше, чем она приедет с диска: список выходил пустым, и до
            // первой поездки на карте не было ни одной зелёной галочки, а
            // умная тишина не работала для фоновых оповещений по геозонам.
            self?.location.refreshFamiliarCameras()
            // Чистка мостовых проездов ждёт ОБА источника: базу камер и
            // историю. Кто из них приедет вторым — заранее не известно,
            // поэтому пробуем с каждого; метод идемпотентен и выходит по
            // своему флагу.
            self?.runAxisCleanupIfPossible()
        }
        cameras.onDatabaseLoaded = { [weak self] in
            self?.runAxisCleanupIfPossible()
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
        // История поездок пишется с главного потока только на переднем плане:
        // в фоне приложение могут приостановить с недописанной очередью.
        trip.mustWriteSynchronously = { UIApplication.shared.applicationState == .background }
        let usage = self.usage
        trip.onTripFinished = { [weak self, weak trip, weak notifications, weak usage] in
            guard let trip else { return }
            // История приходит от новых к старым — только что закрытая поездка первая.
            if let last = trip.history.first {
                usage?.noteTrip(distanceMeters: last.distanceMeters)
                usage?.note { $0.passes += last.camerasPassed }
            }
            // Виджет — сразу: автозавершение в фоне иначе оставляло бы его
            // с цифрами «до поездки» до следующего открытия приложения.
            self?.refreshWidgetSnapshot()
            // Свежая поездка меняет распорядок — подсказка «Домой» обязана
            // знать о новом доме сразу, а не со следующего запуска.
            self?.refreshLearnedPlaces()
            guard let notifications else { return }
            // Тот же расчёт, что на экране Итогов: пуш и экран не имеют права
            // разойтись в цифрах (раньше здесь смешивались окна 7 и 30 дней).
            let week = TripHistory.summary(days: trip.days, history: trip.history, period: .week)
            guard !week.isEmpty else { return }
            // Дельта — к прошлой календарной неделе, зависшие штрафы — по всей
            // истории: пуш повторяет то, что показал бы экран.
            let previous = TripHistory.summary(
                days: trip.days, history: trip.history, period: .week,
                anchor: Date().addingTimeInterval(-7 * 86400))
            notifications.scheduleWeeklyDigest(
                week: week,
                previousRating: previous.rating,
                pendingChecks: TripHistory.pendingFineNudge(trip.history)?.count ?? 0
            )
        }

        // Голосовое сопровождение маршрута: перестроение, прибытие, манёвры.
        route.onRerouted = { [weak alerts] in
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Маршрут перестроен"))
        }
        // Объезд пробки: сказать — голосом, решить — касанием (телефон или
        // машина). Маршрут сам не меняется.
        route.onDetourOffer = { [weak alerts] offer in
            guard settings.voiceEnabled else { return }
            alerts?.speak(offer.spoken)
        }
        route.onArrived = { [weak alerts] in
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Вы прибыли"))
        }
        // Выбор варианта по своим поездкам: история читается в момент
        // построения маршрута, а не копится заранее.
        route.personalHistory = { [weak trip] in
            guard settings.personalRoutes, let trip else { return nil }
            return RouteChoice.history(from: trip.history, now: Date())
        }
        // Имена улиц в манёврах — на языке приложения (баннер и голос).
        route.streetNameLanguage = { settings.appLanguage.mapCode }
        route.onManeuver = { [weak alerts] text in
            guard settings.turnByTurnVoice else { return }
            alerts?.speak(text)
        }
        speedLimits.onOverspeed = { [weak alerts] in
            alerts?.speak(String(localized: "Превышение скорости"))
        }
        speedLimits.onLimitAhead = { [weak alerts] notice in
            alerts?.speak(notice.spoken)
        }
        // Тема интерфейса — до первого кадра: днём приложение не должно
        // мигнуть тёмным при запуске.
        refreshInterfaceAppearance()
        observeCameraRevision()
    }

    /// База камер изменилась (загрузка, своя камера, скрытие, чужая отметка) —
    /// пересобрать окно ближайших камер и оценить сразу. ОДНА точка: до 19.10
    /// то же делали хук отметок, MapScreen и экран машины — три пересборки
    /// окна и сетки на одну отметку при открытом телефоне и машине (аудит
    /// энергии). Здесь, а не во вью: среда жива всегда, тело вью со сложенным
    /// телефоном не исполняется — а именно там водитель и едет.
    private func observeCameraRevision() {
        withObservationTracking {
            _ = cameras.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.location.refreshMonitoring(evaluateNow: true)
                self.observeCameraRevision()
            }
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
        refreshLearnedPlaces()
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
        // Горячие точки треног: кэш поднят в init, с сервера — раз в неделю.
        // Настройка выключена — не тянем вовсе и чистим то, что уже лежит.
        if settings.tripodHints {
            Task { await hotspots.refreshIfNeeded() }
        } else {
            hotspots.clear()
        }
        metrics.start()       // MetricKit: суточные отчёты о батарее/крашах
        guard Storage.bool(.hasCompletedOnboarding) else { return }
        location.bootstrap()
        mobile.startPolling()
        motion.start()
    }

    /// Дом и работа, выученные по истории поездок (FrequentPlaces). Пересчёт —
    /// событийный: на старте сцены и в конце поездки. Распорядок за 30 дней
    /// меняется медленно, считать его в body главного экрана незачем.
    private(set) var learnedPlaces: [FrequentPlaces.Place] = []

    /// Дорога на работу и домой (Commute) за 30 дней — пересчитывается там же,
    /// где места: на старте сцены, в конце поездки, после загрузки истории и
    /// смены мест в настройках. Порядок — по времени суток.
    private(set) var commute: [Commute.Summary] = []

    /// Разовая чистка проездов, засчитанных с моста над камерой. Нужны и оси
    /// камер, и прочитанная история; порядок их прихода не определён.
    private func runAxisCleanupIfPossible() {
        let axes = Dictionary(uniqueKeysWithValues: cameras.cameras.compactMap { camera in
            camera.axis.map { (camera.id, $0) }
        })
        trip.axisCleanupIfNeeded(axisByID: axes)
    }

    // MARK: - Копия своих данных

    /// Собрать копию. Живёт в композиционном корне, потому что данные лежат в
    /// трёх разных сервисах, и сшивать их — не дело ни одного из них.
    func makeBackup() -> TripBackup {
        var backup = TripBackup()
        backup.appVersion = Bundle.main
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        backup.history = trip.history
        backup.days = trip.days
        backup.lifetime = trip.lifetime
        backup.customCameras = cameras.custom
        backup.hiddenCameraIDs = Array(cameras.hiddenIDs).sorted()
        return backup
    }

    /// Влить копию. Возвращает, сколько записей реально добавилось — это и
    /// показываем человеку вместо безликого «готово».
    @discardableResult
    func restore(from backup: TripBackup) -> (trips: Int, days: Int) {
        let merged = TripBackupMerge.merge(backup,
                                           history: trip.history,
                                           days: trip.days,
                                           lifetime: trip.lifetime,
                                           customCameras: cameras.custom,
                                           hiddenCameraIDs: cameras.hiddenIDs)
        trip.applyRestored(history: merged.history, days: merged.days,
                           lifetime: merged.lifetime)
        cameras.applyRestored(custom: merged.customCameras,
                              hidden: merged.hiddenCameraIDs)
        // Виджет и выученные места считаются из истории — после вливания они
        // устарели мгновенно.
        refreshLearnedPlaces()
        refreshWidgetSnapshot()
        return (merged.addedTrips, merged.addedDays)
    }

    func refreshLearnedPlaces() {
        guard settings.destinationSuggestions else {
            // Выключили подсказки — забываем и выученное: держать в памяти
            // домашний адрес, которым не пользуемся, незачем. Дорога на работу
            // остаётся только по заданным вручную местам.
            learnedPlaces = []
            refreshCommute()
            return
        }
        learnedPlaces = FrequentPlaces.learn(history: trip.history, now: Date())
        refreshCommute()
    }

    /// «Куда едем?» сейчас — одна догадка для телефона и машины
    /// (DestinationGuess); nil — нечего предложить или подсказки выключены.
    func destinationGuess(now: Date) -> DestinationGuess? {
        guard settings.destinationSuggestions else { return nil }
        return DestinationGuess.make(
            learned: learnedPlaces,
            manual: { [settings] kind in settings.place(for: kind == .home ? .home : .work) },
            usual: { [commute] direction in commute.first { $0.direction == direction }?.usual },
            from: location.currentCoordinate, now: now)
    }

    /// Дом и работа для дороги: заданный вручную адрес старше выученного —
    /// то же правило, что у подсказки «Домой».
    var commuteEnds: (home: CLLocationCoordinate2D, work: CLLocationCoordinate2D)? {
        func end(_ kind: FrequentPlaces.Kind) -> CLLocationCoordinate2D? {
            settings.place(for: kind == .home ? .home : .work)?.coordinate
                ?? learnedPlaces.first { $0.kind == kind }?.coordinate
        }
        guard let home = end(.home), let work = end(.work) else { return nil }
        return (home, work)
    }

    func refreshCommute() {
        // Журнал копит концы поездок 45 дней — история держит только 50
        // записей, и «медиана за 30 дней» на ней была медианой за 12–17.
        guard let ends = commuteEnds else {
            commute = []
            return
        }
        let trips = settings.commuteLearning
            ? Commute.trips(history: commuteProfiles.updateLedger(with: trip.history),
                            home: ends.home, work: ends.work)
            : Commute.trips(history: trip.history, home: ends.home, work: ends.work)
        commute = Commute.summaries(trips: trips, now: Date())
    }

    #if DEBUG
    /// Снимок под скриншот состояния виджета. `-widgetState empty|few|full`.
    /// Состояние «нет доступа» подделать нечем и не нужно: оно наступает само,
    /// когда App Group не выдан подписью.
    private static func demoWidgetSnapshot() -> SharedDefaults.Snapshot? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-widgetState"), index + 1 < args.count
        else { return nil }
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        switch args[index + 1] {
        case "empty":
            return SharedDefaults.Snapshot(weekStart: start, updatedAt: Date())
        case "few":
            return SharedDefaults.Snapshot(
                weekStart: start, weekDistance: 12_400, weekTrips: 1, weekRating: 55,
                weekFineRisk: 2_200_000,
                dayDistances: [12_400, 0, 0, 0, 0, 0, 0],
                dayOverspeed: [true, false, false, false, false, false, false],
                topRiskPlace: "Юнусабад", topRiskPasses: 1,
                monthDistance: 12_400, lifetimeDistance: 12_400,
                weekMovingDuration: 18 * 60,
                lastTripDistance: 12_400,
                lastTripAt: Date().addingTimeInterval(-4 * 3600), updatedAt: Date())
        default:   // full — богатая неделя
            return SharedDefaults.Snapshot(
                weekStart: start, weekDistance: 128_400, weekTrips: 9, weekRating: 67,
                weekFineRisk: 2_200_000, weekDeltaPercent: 12,
                dayDistances: [14_000, 22_000, 31_000, 9_000, 27_000, 0, 25_400],
                dayOverspeed: [false, false, true, false, true, false, false],
                topRiskPlace: "Юнусабад, Амира Темура", topRiskPasses: 4,
                usualWeekDistance: 115_000, monthDistance: 486_000,
                lifetimeDistance: 12_400_000, weekMovingDuration: 4.5 * 3600,
                lastTripDistance: 25_400,
                lastTripAt: Date().addingTimeInterval(-3600), updatedAt: Date())
        }
    }
    #endif

    /// Перепроверить всё, что приходит с сервера, при возврате в приложение.
    /// Каждый сервис держит СВОЙ интервал (пульт 6 ч, правки модератора 3 ч,
    /// база камер сутки), поэтому частые переключения между приложениями
    /// сеть не будят: refreshIfNeeded выйдет сразу. Раньше эта проверка жила
    /// только в холодном старте — а телефон работает неделями без него, и
    /// стоп-кран, включённый вчера, до такого пользователя не доезжал.
    func refreshRemoteIfNeeded() {
        Task { await config.refreshIfNeeded() }
        Task { await sync.autoCheckIfNeeded() }
        if settings.tripodHints {
            Task { await hotspots.refreshIfNeeded() }
        }
    }

    /// Снимок для домашнего виджета: текущая неделя целиком, включая форму по
    /// дням и место наибольшего риска. Зовётся при уходе в фон (RootView) и в
    /// конце каждой поездки — виджет показывает статистику вообще без
    /// открытия приложения, и после автозавершения в кармане она обязана быть
    /// свежей. Считаем ЗДЕСЬ: виджет не имеет права вычислять — у него нет ни
    /// истории, ни права тратить батарею.
    func refreshWidgetSnapshot() {
        #if DEBUG
        // Скриншот-хук `-widgetState empty|few|full`: виджет живёт в основном
        // не на полной неделе, а посмотреть скудные состояния иначе нечем —
        // ждать понедельника или чистить историю каждый раз слишком дорого.
        if let demo = Self.demoWidgetSnapshot() {
            SharedDefaults.write(demo)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        #endif
        let calendar = Calendar.current
        let now = Date()
        let week = TripHistory.summary(days: trip.days, history: trip.history,
                                       period: .week)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        // Форма недели по дням — из тех же дневных сводок, что и календарь в
        // Итогах. День без поездок остаётся нулём на своём месте, а не
        // выпадает: иначе неделя на виджете выглядела бы короче, чем была.
        var distances = [Double](repeating: 0, count: 7)
        var overspeed = [Bool](repeating: false, count: 7)
        if let weekStart {
            for day in trip.days {
                guard let index = calendar.dateComponents([.day], from: weekStart,
                                                          to: calendar.startOfDay(for: day.day)).day,
                      (0...6).contains(index) else { continue }
                distances[index] = day.distanceMeters
                overspeed[index] = day.overPasses > 0
            }
        }
        // «Обычная неделя» — медиана километров за предыдущие восемь, без
        // текущей: она ещё не кончилась и занижала бы норму каждый понедельник.
        // Медиана, а не среднее: одна поездка в Самарканд не должна сделать
        // все следующие недели «провальными».
        var previousWeeks: [Double] = []
        if let weekStart {
            for back in 1...8 {
                let anchor = weekStart.addingTimeInterval(-Double(back) * 7 * 86400)
                guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor)
                else { continue }
                let sum = trip.days
                    .filter { $0.day >= interval.start && $0.day < interval.end }
                    .reduce(0) { $0 + $1.distanceMeters }
                if sum > 0 { previousWeeks.append(sum) }
            }
        }
        let month = TripHistory.summary(days: trip.days, history: trip.history, period: .month)
        let snapshot = SharedDefaults.Snapshot(
            weekStart: weekStart,
            weekDistance: week.distance,
            weekTrips: week.trips,
            weekRating: week.rating ?? -1,
            weekFineRisk: week.fineRisk,
            weekDeltaPercent: week.distanceDeltaPercent,
            dayDistances: distances,
            dayOverspeed: overspeed,
            topRiskPlace: week.topOverLocation,
            topRiskPasses: week.topOverCount,
            usualWeekDistance: WidgetWeek.median(previousWeeks),
            monthDistance: month.distance,
            lifetimeDistance: trip.lifetime.distanceMeters,
            weekMovingDuration: week.movingDuration,
            lastTripDistance: trip.history.first?.distanceMeters ?? 0,
            lastTripAt: trip.history.first?.startedAt
        )
        // Сравниваем с тем, что виджет уже видит: перезагрузка без новых цифр
        // тратит дневной бюджет WidgetKit (см. WidgetWeek.needsRefresh).
        guard WidgetWeek.needsRefresh(previous: SharedDefaults.read(), next: snapshot, now: now)
        else { return }
        SharedDefaults.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
