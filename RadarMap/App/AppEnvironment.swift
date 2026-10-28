//
//  AppEnvironment.swift
//  RadarMap
//
//  Композиционный корень зависимостей. Создаётся один раз и раздаётся через SwiftUI Environment.
//

import BackgroundTasks
import CoreLocation
import Foundation
import Observation
import UIKit
import WidgetKit
import os

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
    /// Метан на АГНКС (12б.4).
    let cng: CngService
    let motion: MotionService
    /// Своя машина подключена (CarPlay / выбранная магнитола) — «Только в машине».
    let carLink: CarLinkService
    let route = RouteService()
    let speedLimits: SpeedLimitService
    let liveActivity = LiveActivityService()
    /// «Радар!» с плашки или часов в пути (`remoteRadarReport`).
    @ObservationIgnored var remoteReportInFlight = false
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
    /// Призрак дороги на работу на ходу (этап 8).
    let commuteLive = CommuteLiveService()
    /// «Поделиться прибытием» — ссылка с временем прибытия для знакомого.
    let etaShare = EtaShareService()
    /// Семейная ссылка прибытия домой (12б.6).
    let family = FamilyShareService()
    /// Граф трасс для маршрута без сети (12б.10).
    let offlineRoutes = OfflineRouteService()
    /// Слой полос (20.8): подписанные ряды полос там, где OSRM молчит.
    let laneOverlay = LaneOverlayService()
    /// Коридор длинного маршрута (19.3): карта и граф по пути, «По пути».
    let corridor = RouteCorridorService()
    /// «Нужное сейчас» на карте (29.H): заправки по пути, парковки у цели,
    /// ближайшие из «По пути» — данные значков; что показать, решает
    /// MapDetailPolicy в каждой карте.
    let mapDetail = MapDetailService()
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
    /// «Обычно по водителям» (8.8.16): файлы traffic/typical по запросу — для
    /// дороги на работу, пока своих поездок меньше трёх.
    let typicalTraffic = TypicalTrafficService()
    /// Типичные пробки по часу недели (33C) — время прибытия во времени.
    let trafficProfile = TrafficProfileService()
    /// Личный темп (33E) — поправка времени прибытия, только на телефоне.
    let personalPace = PersonalPaceStore()
    /// Погода на перевалах (19.2): файл сервера по open-meteo, одна фраза и
    /// баннер о снеге или тумане впереди. На оповещения о камерах не влияет.
    let roadWeather: RoadWeatherService
    /// Обслуживание машины (18): пробег, масло, документы — только на телефоне.
    let maintenance: MaintenanceService
    /// Пришедшие штрафы (этап 17): только на телефоне; сверка и сроки — AppEnvironment+Fines.
    let fines = FineStore()
    /// Журнал заправок и зарядок (21.6): только на телефоне; цена профиля и
    /// правдоподобие — AppEnvironment+EnergyJournal.
    let energyJournal = EnergyJournalStore()
    /// «Хранить поездки: только на iPhone / в iCloud» (27.F): приватная база
    /// человека в его iCloud; нам не видна. Источники — AppEnvironment+Cloud.
    let cloud = CloudSyncService()
    /// Свои дороги и новые камеры на них (31E): память клеток и новости.
    let roadMemory = RoadMemoryService()

    /// CarPlay подключён. Наблюдаемый флаг для интерфейса телефона: пока едет
    /// машина, телефонная карта уступает место дешёвому экрану передачи —
    /// рисовать MapKit на двух экранах разом значит греть телефон вдвое.
    private(set) var isCarPlayConnected = false
    /// «Впереди пробка» для экрана машины (27.E): последняя объявленная пробка
    /// без маршрута; CarPlay показывает её баннером, пока не истекла.
    private(set) var jamNotice: JamAhead.Notice?
    @ObservationIgnored private var jamNoticeCounter = 0

    /// Пробку объявили (голосом или нет) — машине баннер; без машины не
    /// пишем: наблюдать некому, а запись будила бы зрителей на каждой пробке.
    func noteJamAhead(_ jam: JamAhead.Jam, now: Date = Date()) {
        guard isCarPlayConnected else { return }
        jamNoticeCounter += 1
        jamNotice = JamAhead.Notice(id: jamNoticeCounter, jam: jam,
                                    until: now.addingTimeInterval(AppConfig.carPlayJamBannerSeconds))
    }
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
        if connected { Storage.set(true, for: .carPlaySeen) }
        carLink.setCarPlay(connected)
        refreshTrafficWanted()
        updateThemeClock()
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
    /// Солнце над точкой пользователя — без оглядки на настройку. CarPlay
    /// берёт его, а не interfaceIsDaylight: в «Авто» у машины своя тема
    /// (фары), и смешивать её с результатом под прежнюю настройку нельзя.
    private(set) var sunIsUp = false

    /// Пересчёт темы: на старте, при открытии, при смене настройки и раз в
    /// пять минут, пока на экран смотрят (themeClock) — закат не ждёт
    /// перезапуска. Один источник дня/ночи для интерфейса, карты телефона,
    /// HUD, CarPlay и плитки: до 19.10 их было пять, со своими точками и
    /// циклами (аудит архитектуры).
    func refreshInterfaceAppearance() {
        let sun = Sun.isDaytime(at: location.currentCoordinate, now: Date())
        if sun != sunIsUp { sunIsUp = sun }
        let day: Bool
        switch settings.mapAppearance {
        case .dark:  day = false
        case .light: day = true
        case .auto:  day = sun
        }
        if day != interfaceIsDaylight { interfaceIsDaylight = day }
    }

    /// Настройка темы сменилась — пересчитать сразу, а не ждать часов темы:
    /// без телефонной сцены (только машина) RootView этого не сделает.
    private func observeAppearanceSetting() {
        withObservationTracking {
            _ = settings.mapAppearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshInterfaceAppearance()
                self?.observeAppearanceSetting()
            }
        }
    }
    /// Первая точка пришла — тема по солнцу ЗДЕСЬ, а не по запасному правилу
    /// 6–19 ч до следующего тика часов (холодный старт в 19:20 в июне).
    @ObservationIgnored private var themeHadPosition = false

    /// Часы темы: идут, пока на экран смотрят — телефон или машина (CarPlay
    /// может подключиться без телефонной сцены вовсе, и тогда раньше закат
    /// не замечал никто).
    @ObservationIgnored private var themeClock: Task<Void, Never>?

    private func updateThemeClock() {
        if isPhoneSceneActive || isCarPlayConnected {
            guard themeClock == nil else { return }
            themeClock = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refreshInterfaceAppearance()
                    await Task.pause(seconds: AppConfig.interfaceThemeRefreshSeconds)
                }
            }
        } else {
            themeClock?.cancel()
            themeClock = nil
        }
    }

    /// Пробки нужны, пока на них кто-то смотрит: экран телефона, машина или
    /// идущая поездка (её время в пути).
    func refreshTrafficWanted() {
        let wanted = isPhoneSceneActive || isCarPlayConnected || location.isTripActive
        traffic.setWanted(wanted)
        // Слой «обычно в это время» (33G) — по тому же правилу, что живые.
        trafficProfile.setWanted(wanted)
        // Погода на перевалах — по тому же правилу: экран, машина или поездка.
        roadWeather.setWanted(wanted)
    }

    /// Ритм сети в поездке (NetworkRhythm): пробки — одним тактом и вместе с
    /// опросом отметок, реже при погашенном экране без маршрута.
    private func wireNetworkRhythm() {
        traffic.intervalProvider = { [weak self] in
            guard let self else { return AppConfig.trafficRefreshInterval }
            return NetworkRhythm.trafficInterval(screenOn: self.isPhoneSceneActive || self.isCarPlayConnected,
                                                 hasRoute: self.route.isActive)
        }
        // Метан — тем же тактом радио, своим интервалом (только машина на метане).
        mobile.onRadioAwake = { [weak self, weak traffic, weak cng] in
            traffic?.radioIsAwake()
            cng?.refreshIfDue()
            // Маршрут без сети — серверным, даже если связь для системы не
            // пропадала и onOnline не придёт (ревью 14.2). Свой срок — внутри.
            if let self, self.network.isOnline {
                self.route.retryOfflineRouteIfDue(from: self.location.currentCoordinate,
                                                  heading: self.location.routeHeading,
                                                  cameras: self.cameras.cameras)
            }
        }
    }

    /// Ставит RootView по scenePhase телефона.
    func setPhoneSceneActive(_ active: Bool) {
        isPhoneSceneActive = active
        if !active { cloud.sceneEnteredBackground() }
        refreshTrafficWanted()
        updateThemeClock()
        if active {
            // Автоэконом: заряд мог упасть, пока экран был погашен (12.3).
            thermal.refreshBattery()
            mobile.startPolling()
            // Ожидание склейки у близких могло выйти, пока приложение спало.
            family.update()
            Task { await offlineRoutes.refreshIfDue() }
            Task { await laneOverlay.refreshIfDue() }
            cloud.sceneBecameActive()
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
        self.cng = CngService(settings: settings)
        self.motion = MotionService(settings: settings)
        self.carLink = CarLinkService(settings: settings)
        let notifications = NotificationService(settings: settings)
        let alerts = AlertPlayer(settings: settings)
        let trip = TripStats()

        self.usage = UsageStatsService(settings: settings)
        self.traffic = TrafficService(settings: settings)
        self.roadWeather = RoadWeatherService(settings: settings)
        self.settings = settings
        self.cameras = cameras
        self.notifications = notifications
        self.alerts = alerts
        self.trip = trip
        self.maintenance = MaintenanceService(trip: trip, settings: settings)
        self.speedLimits = SpeedLimitService(settings: settings)
        self.location = LocationService(
            repository: cameras,
            notifier: notifications,
            settings: settings,
            alerts: alerts,
            trip: trip
        )
        self.location.liveActivity = liveActivity
        // Маршрут по своей дороге на работу — остаток по призраку (8.8.11).
        self.route.personalRemaining = { [weak self] in self?.commuteLive.routeRemaining(now: Date()) }
        // Плашка Live Activity — прибытие: по маршруту (9.1) — время и остаток
        // до места; без маршрута — строка призрака (8.8.3б), те же слова, что
        // на панели поездки.
        self.location.activityGhost = { [weak self] in
            guard let self else { return nil }
            if self.route.isActive {
                let arrival = Date(timeIntervalSince1970: (self.route.arrivalDate.timeIntervalSince1970 / 60).rounded() * 60)
                let left = Formatting.distance(self.route.remainingDistance)
                let name = self.route.destinationName
                return (arrival, name.isEmpty ? left : "\(name) · \(left)", false)
            }
            guard let ghost = self.commuteLive.display else { return nil }
            return (ghost.arrival, GhostText.caption(ghost), GhostText.isAlert(ghost))
        }
        // Кнопки плашки (9.1б): система выполняет их намерения в процессе
        // приложения, исполнитель — здесь (Shared/ActivityIntents).
        ActivityActions.perform = { [weak self] action in
            await self?.performActivityAction(action)
        }
        self.location.route = route
        self.location.speedLimits = speedLimits
        self.location.hotspots = hotspots
        self.location.roadWeather = roadWeather
        self.location.watchBridge = watchBridge
        // «Радар!» с часов (9.3) — та же дверь, что у плашки.
        watchBridge.onReport = { [weak self] in
            guard let self else { return false }
            return await self.remoteRadarReport()?.pointExists
        }
        self.location.motion = motion     // «стоим» — сигнал не потерян

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
        motion.onDrivingStart = { [weak self, weak location] in
            guard settings.tripStartMode.usesMotion, let location,
                  !location.isTripActive else { return }
            // История ещё читается — подождать (склейка, восстановление);
            // не читается вовсе (до первой разблокировки) — не ждать: поездка
            // нужна сейчас, а пришедшее за окно встанет поверх прочитанного.
            if let trip = self?.trip, !trip.isLoaded, !trip.isLoadBlocked {
                self?.pendingAutoStart = true
                return
            }
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
            // iCloud в поездке молчит; после — отправит с паузой.
            self.cloud.tripStateChanged(active: active)
            if active { self.traffic.tripStarted() } else { self.traffic.tripEnded() }
            // Поехали — выбор сделан: ярлыки вариантов больше не двигаются.
            if active { self.route.noteChoiceTouched() }
            if active { self.roadWeather.tripStarted() } else { self.roadWeather.tripEnded() }
            self.commuteGhostPending = active
            if active { self.tryStartCommuteGhost() } else { self.commuteLive.stop() }
            if active {
                self.family.tripStarted()
                // Склейку (TripMerge) startTrip решает после этого колбэка —
                // решение близких ждёт конца хода: магазин по пути не должен
                // начать у мамы поездку заново.
                Task { @MainActor [weak self] in self?.family.update() }
            } else {
                // Дома — «дома в 18:47»; «Стоп» и пассажир — «сейчас не в
                // пути»; автостоп в другом месте — ждём склейки (22.4).
                self.familyTripEnded()
            }
            // Едем — сегодняшнего «пора выезжать» нет (и показанное — снять);
            // кончили поездку — план заново (машину переставили во дворе —
            // напоминание вернётся).
            self.refreshDepartureReminders(tripEdge: true)
            // Обслуживание: в поездке поставленное снять, после — машина стоит.
            self.refreshMaintenanceReminders(moment: .parked)
            self.refreshTrafficWanted()
            if !active, !self.isPhoneSceneActive, !self.isCarPlayConnected {
                self.mobile.stopPolling()
            }
        }
        wireCommuteVoice()
        wireCarLink()
        // Ответ на «Вы за рулём?»: пассажир — гасим поездку без следа,
        // водитель — запоминаем магнитолу машины, чтобы не переспрашивать.
        notifications.onPassengerConfirmed = { [weak location] in location?.markPassenger() }
        notifications.onDriverConfirmed = { [weak location] in location?.confirmDriver() }
        // Обслуживание: правка на экране — пересчёт напоминаний; то, что
        // человек только что правил, он уже видел.
        maintenance.onEdited = { [weak self] seen in self?.maintenanceEdited(seen) }

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
        location.onAcceptedFix = { [weak self, weak mobile, weak traffic, weak location, weak route, weak alerts, weak cng] coordinate in
            // Метан: встали у АГНКС — вопрос через 3 мин, тронулись — снять.
            cng?.noteFix(coordinate, speedKmh: location?.speedKmh ?? -1)
            // Без withAnimation: транзакция анимации на КАЖДОМ фиксе, в том
            // числе в фоне, ради смены вопроса раз в поездку. Появление
            // вопроса анимирует сам гейт (MobileConfirmGate).
            mobile?.trackPasses(from: coordinate, course: location?.currentCourse ?? -1)
            // Автоэконом (12.3): заряд перечитывается не чаще раза в минуту —
            // на фиксе это сравнение дат. С фикса, а не с экрана: CarPlay
            // рисует карту и с погашенным телефоном.
            self?.thermal.refreshBattery()
            if let self, !self.themeHadPosition {
                self.themeHadPosition = true
                self.refreshInterfaceAppearance()
            }
            // Улицы вокруг машины — для посадки «Радар!» на дорогу и числа
            // полос на подъезде к манёвру (совет о ряде, 20.2). После
            // удаления схемы приборки (11.10) ensureCoverage не звал никто,
            // сеть была пустой, и отметки уходили
            // сырой координатой водителя (аудит 19.10). В поездке, с машиной
            // или когда похоже, что едем без поездки («Радар!» доступен и так);
            // гейт внутри — дёшево, пока окрестность та же.
            if let self, let location,
               location.isTripActive || location.isProbablyDriving || self.isCarPlayConnected {
                self.roads.ensureCoverage(around: coordinate)
            }
            traffic?.note(coordinate, speedKmh: location?.speedKmh ?? -1,
                          simulated: location?.isFixSimulated ?? false)
            // Значки «нужного сейчас» (29.H): дёшево, поиск — только на смене
            // километра пути, цели или подъезда к ней.
            self?.mapDetail.note(position: coordinate)
            if let self, let location, location.isTripActive {
                if self.commuteGhostPending { self.tryStartCommuteGhost() }
                if self.commuteLive.isRunning {
                    // Пробки впереди по своему пути (8.8.10) — до прогноза;
                    // маршрут по своей дороге (8.8.11) — сверить один раз.
                    self.commuteLive.noteTraffic(self.traffic.snapshot, revision: self.traffic.revision,
                                                 now: location.lastFixTime)
                    if let route {
                        self.commuteLive.noteRoute(key: route.polyline.map(ObjectIdentifier.init),
                                                   coordinates: route.isActive ? route.routeCoordinates : nil)
                    }
                    self.commuteLive.note(coordinate, accuracy: location.horizontalAccuracy,
                                          at: location.lastFixTime)
                }
                // Близкие видят прибытие (12б.6, 22.1): кому и что — FamilyShare.
                self.family.update()
            }
            if let traffic, let route, route.isActive { route.refreshTrafficDelay(revision: traffic.revision) }
            // «Впереди пробка» — только без маршрута: с маршрутом пробки уже в
            // ETA и в предложении объезда. Одна фраза на пробку (JamAhead) и,
            // в машине, баннер (27.E) — он и при выключенном голосе.
            if let traffic, let location, let route, location.isTripActive, !route.isActive,
               settings.voiceEnabled || self?.isCarPlayConnected == true,
               let jam = traffic.jamToAnnounce(position: coordinate, course: location.currentCourse) {
                if settings.voiceEnabled { alerts?.speak(jam.spoken, event: jam.voiceEvent) }
                self?.noteJamAhead(jam)
            }
        }
        route.roadEvents = { [weak mobile] in mobile?.roadEvents ?? [] }
        // Метан (12б.4): пульт, заведения, уведомление «Как на заправке?».
        cng.crowdEnabled = { [weak mobile] in mobile?.isEnabled ?? false }
        cng.venues = { [weak roads] point in await roads?.venueBook(for: point, allowDownload: false) }
        location.onStoppedWithoutFix = { [weak cng] here in cng?.noteFix(here, speedKmh: 0) }
        cng.notifier = notifications
        cng.network = network
        notifications.onCngAnswer = { [weak cng] answer, point in await cng?.answer(answer, point: point) }
        location.roadEvents = { [weak mobile] in mobile?.roadEvents ?? [] }
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
        family.allowedByConfig = { [weak config] in config?.current.isEtaShareEnabled ?? true }
        family.context = { [weak self] in self?.familyContext() }
        family.telegramBot = { [weak etaShare] in etaShare?.telegramBot }
        // Маршрут без сети (12б.10): свой граф трасс, а связь вернулась —
        // приблизительный маршрут молча заменяется серверным.
        offlineRoutes.network = network
        route.offlinePath = { [weak offlineRoutes] from, to in await offlineRoutes?.path(from: from, to: to) }
        // Коридор длинного маршрута (19.3): области карты и граф по пути,
        // файлы заведений «По пути» — сам он ничего не качает без правил.
        corridor.maps = offlineMaps
        corridor.graph = offlineRoutes
        corridor.roads = roads
        corridor.network = network
        mapDetail.roads = roads
        mapDetail.corridor = corridor
        mapDetail.route = route
        mapDetail.fuelKinds = { [weak settings] in settings?.vehicleEnergy.stops ?? [.fuel] }
        // Слой полос (20.8): пульт (`features.laneOverlay`) и сеть; маршрут
        // спрашивает слой при построении и прикладывает заново, когда тот
        // приехал или снят.
        laneOverlay.network = network
        laneOverlay.allowedByConfig = { [weak config] in config?.current.isLaneOverlayEnabled ?? true }
        laneOverlay.onChange = { [weak route] in route?.laneOverlayChanged() }
        route.laneOverlay = { [weak laneOverlay] in laneOverlay?.current() }
        network.onOnline = { [weak self] in
            guard let self else { return }
            self.route.replaceOfflineRoute(from: self.location.currentCoordinate,
                                           heading: self.location.routeHeading,
                                           cameras: self.cameras.cameras)
            Task { await self.offlineRoutes.refreshIfDue() }
            Task { await self.laneOverlay.refreshIfDue() }
        }
        traffic.isOnline = { [weak network] in network?.isOnline ?? false }
        // Погода на перевалах: пульт (`features.roadWeather`) и сеть.
        roadWeather.allowedByConfig = { [weak config] in config?.current.isRoadWeatherEnabled ?? true }
        roadWeather.isOnline = { [weak network] in network?.isOnline ?? false }
        // «Обычно по водителям» — под теми же выключателями, что пробки.
        typicalTraffic.isAllowed = { [weak traffic] in traffic?.isShown ?? false }
        typicalTraffic.isOnline = { [weak network] in network?.isOnline ?? false }
        // Обычная пробка часа в ETA любого маршрута (27.E): маршрут берёт
        // файлы из памяти и просит недостающие; пришли — досчитывает время.
        route.typicalTraffic = { [weak typicalTraffic] bucket in typicalTraffic?.cached(bucket)?.snapshot }
        // Профиль часа недели (33C): те же выключатели (пульт `features.traffic`
        // и «Пробки»), маршрут берёт его из памяти и просит обновить; пришёл
        // новый — время вариантов и остатка пересчитывается.
        trafficProfile.isAllowed = { [weak traffic] in traffic?.isShown ?? false }
        trafficProfile.isOnline = { [weak network] in network?.isOnline ?? false }
        // «Обычно в это время» — тем же слоем линий, что живые (33H).
        trafficProfile.onUsualChanged = { [weak traffic] in traffic?.setUsual($0) }
        route.trafficProfile = { [weak trafficProfile] in trafficProfile?.current() }
        // Личный темп (33E): «Учитывать мою манеру езды» и пульт пробок.
        personalPace.isEnabled = { [weak settings, weak config] in
            (settings?.personalPace ?? false) && (config?.current.isTrafficEnabled ?? true)
        }
        route.paceFactor = { [weak personalPace] roadClass in personalPace?.factor(for: roadClass) ?? 1 }
        // Свежий now.json, пока варианты выбирают, — их время и (до касания
        // панели) ярлыки по нему; в пути остаток ведёт refreshTrafficDelay.
        traffic.onSnapshotChanged = { [weak route, weak location] in
            guard location?.isTripActive != true else { return }
            route?.liveTrafficArrived()
        }
        route.onPaceSample = { [weak personalPace] sample in personalPace?.add(sample) }
        route.prefetchProfile = { [weak trafficProfile, weak route] in
            guard let trafficProfile else { return }
            Task {
                if await trafficProfile.refreshIfDue() { route?.typicalTrafficArrived() }
            }
        }
        route.prefetchTypical = { [weak typicalTraffic, weak route] buckets in
            guard let typicalTraffic else { return }
            // Досчитывать — только если что-то пришло или сменилось: часа,
            // которого на сервере нет, маршрут просит на каждом пересчёте
            // остатка, и «пришло то же» иначе гоняло бы пересчёт по кругу.
            let ordered = buckets.sorted { $0.name < $1.name }
            let before = ordered.map { typicalTraffic.cached($0)?.snapshot.generated }
            Task {
                _ = await typicalTraffic.files(for: buckets)
                let after = ordered.map { typicalTraffic.cached($0)?.snapshot.generated }
                if after != before { route?.typicalTrafficArrived() }
            }
        }
        #if canImport(MapLibre)
        // Сервер карты лёг при живой связи (S22): сторож тайлов сообщает, карта
        // уходит на скачанную область, плашка говорит правду. С областью
        // онлайн-запросов нет — через 3 минуты пробуем онлайн снова.
        EngineTileGuard.observeHealth { [weak self] down in
            guard let self else { return }
            Task { @MainActor in self.tileServerHealthChanged(down: down) }
        }
        #endif
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
            guard let self else { return }
            // Своя дорога — для «новых камер на ваших дорогах» (31E): и рейс,
            // и личная поездка; только на телефоне.
            self.roadMemory.note(track: track.map { ($0.lat, $0.lon) }, on: record.startedAt)
            // Рабочий рейс — не дорога на работу (12б.9).
            guard self.settings.commuteLearning, record.work != true, let ends = self.commuteEnds,
                  let direction = Commute.trips(history: [record], home: ends.home,
                                                work: ends.work).first?.direction else {
                // Склейка продолжила поездку не туда (магазин → не работа):
                // прежняя запись журнала про неё больше не правда.
                self.commuteProfiles.recordAccuracy(nil, tripID: record.id)
                return
            }
            self.commuteProfiles.ingest(record: record, track: track, times: times,
                                        direction: direction, limits: self.speedLimits.limitIndex)
            // Журнал точности (24.1): что призрак сказал и когда доехали.
            let stops = (record.stops ?? []).map { $0.from...max($0.from, $0.to) }
            let entry = self.commuteLive.finishAccuracy(tripID: record.id, departure: record.startedAt,
                                                        endedAt: record.endedAt, stops: stops)
            self.commuteProfiles.recordAccuracy(entry?.direction == direction ? entry : nil, tripID: record.id)
        }
        // Стёртые человеком поездки забываются и в журнале, и в профиле.
        trip.onRecordsErased = { [weak self] ids in
            self?.commuteProfiles.forget(ids)
            self?.refreshCommute()
        }
        commuteProfiles.onLoaded = { [weak self] in self?.refreshCommute() }
        trip.recordsTimedTrack = settings.recordTimedTrack
        // Слепок живой поездки помнит режим «Работаю водителем»: рейс, который
        // оборвала смерть процесса, восстанавливается рейсом (ревью 14.1).
        trip.workMode = { [weak settings] in settings?.workDriverMode == true }
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
            // Нагрев, а не итоговая ступень: автоэконом батареи не повод
            // узнавать о треноге позже (AutoEconomy).
            (speedKmh: location?.speedKmh ?? 0, thermal: thermal?.heatMode ?? .full)
        }
        mobile.onMyReportConfirmed = { [weak notifications] report in
            let kind = ReportKind(rawValue: report.kind)?.title
                ?? String(localized: "отметка")
            notifications?.notifyReportConfirmed(kind: kind)
        }
        // История не читается (старт до разблокировки) — автостарт, ждавший
        // её, не ждёт дальше: CoreMotion зовёт onDrivingStart один раз на
        // начало езды, и первая поездка после перезагрузки пропала бы (ревью S9).
        trip.onLoadBlocked = { [weak self] in self?.startPendingAutoStart() }
        observeProtectedData()
        trip.onHistoryLoaded = { [weak self] in
            // Автостарт, ждавший историю, — сейчас, если всё ещё едем.
            self?.startPendingAutoStart()
            // История прочлась (после разблокировки — пусть и по повтору, без
            // уведомления): прочие хранилища — тоже, не дожидаясь экрана (S9).
            self?.cameras.reloadUserDataIfNeeded()
            self?.commuteProfiles.retryLoadNow()
            self?.refreshLearnedPlaces()
            self?.refreshWidgetSnapshot()
            // Пробег обслуживания считается по дням поездок — теперь он верный.
            self?.refreshMaintenanceReminders(moment: .opened)
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
            self?.refreshCameraNews()
            // Вход в геозону, разбудивший приложение раньше базы, — сейчас.
            self?.location.processPendingRegionEnters()
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
            // Склейка — та же поездка: в статистику только прибавка километров.
            // Проезды уже посчитаны по одному (notePass): здесь их не добавляем,
            // иначе каждый считался дважды (сценарий S11, 20.10).
            if trip.lastFinishWasContinuation {
                usage?.note { $0.kilometres = (($0.kilometres + trip.lastFinishDistanceDelta / 1000) * 10).rounded() / 10 }
            } else if trip.history.first != nil {
                usage?.noteTrip(distanceMeters: trip.lastFinishDistanceDelta)
            }
            // Виджет — сразу: автозавершение в фоне иначе оставляло бы его
            // с цифрами «до поездки» до следующего открытия приложения.
            self?.refreshWidgetSnapshot()
            // Свежая поездка меняет распорядок — подсказка «Домой» обязана
            // знать о новом доме сразу, а не со следующего запуска.
            self?.refreshLearnedPlaces()
            // Пробег вырос на эту поездку — пороги обслуживания по нему.
            self?.refreshMaintenanceReminders(moment: .parked)
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
        route.detourScreenAvailable = { [weak self] in
            guard let self else { return false }
            return self.isPhoneSceneActive || self.isCarPlayConnected
        }
        route.onDetourOffer = { [weak alerts] offer in
            guard settings.voiceEnabled else { return }
            alerts?.speak(offer.spoken, event: offer.voiceEvent)
        }
        route.onArrived = { [weak alerts, weak location, weak route] in
            // Поездка закроется сама, когда встанем у цели или заглушим
            // машину (ArrivalFinish) — до 21.10 она шла дальше, пока не
            // нажмут «Завершить поездку».
            location?.watchArrival(route?.lastArrival)
            guard settings.voiceEnabled else { return }
            alerts?.speak(String(localized: "Вы прибыли"))
        }
        // Выбор варианта по своим поездкам: история читается в момент
        // построения маршрута, а не копится заранее.
        route.personalHistory = { [weak trip, weak self] in
            guard settings.personalRoutes, let trip else { return nil }
            // Линии своего пути дом↔работа (45 дней) — «Знакомый» видит месяц,
            // а не неделю треков (24.4).
            let profile = settings.commuteLearning && self?.commuteProfiles.isLoaded == true
                ? self?.commuteProfiles.book : nil
            return RouteChoice.history(from: trip.history, profile: profile, now: Date())
        }
        // «Моя дорога» (24.4): цель — дом или работа, и путь туда наезжен.
        // Выключается тем же «Учитывать мои поездки» и обучением дороги.
        route.myRoadPlan = { [weak self] source, destination in
            guard let self, settings.personalRoutes, settings.commuteLearning,
                  !settings.workDriverMode, self.commuteProfiles.isLoaded,
                  let ends = self.commuteEnds,
                  let direction = MyRoad.direction(destination: destination, home: ends.home, work: ends.work)
            else { return nil }
            var plan = MyRoad.plan(variants: self.commuteProfiles.book[direction], direction: direction,
                                   source: source, destination: destination, home: ends.home, work: ends.work)
            // Та же поправка журнала, что у призрака в пути (24.2).
            plan?.bias = CommuteAccuracy.biasFactor(self.commuteProfiles.accuracy, direction: direction)
            return plan
        }
        // Имена улиц в манёврах — на языке приложения (баннер и голос).
        route.streetNameLanguage = { settings.appLanguage.mapCode }
        route.onManeuver = { [weak alerts] text, event in
            guard settings.turnByTurnVoice else { return }
            alerts?.speak(text, event: event)
        }
        // Совет о ряде без полос OSRM: сколько полос в нашу сторону на подъезде
        // к манёвру — по тайлам улиц (знают класс и тег lanes), иначе по
        // индексу лимитов, который класса не знает и края не даст.
        route.approachRoads = { [weak roads] point, radius in
            roads?.vehicleNetwork.roads(near: point, radius: radius) ?? []
        }
        speedLimits.onOverspeed = { [weak alerts] in
            alerts?.speak(String(localized: "Превышение скорости"))
        }
        speedLimits.onLimitAhead = { [weak alerts] notice in
            alerts?.speak(notice.spoken, event: notice.voiceEvent)
        }
        // Тема интерфейса — до первого кадра: днём приложение не должно
        // мигнуть тёмным при запуске.
        refreshInterfaceAppearance()
        observeCameraRevision()
        observeAppearanceSetting()
        observeCommuteSettings()
        wireNetworkRhythm()
        wireCloud()
        startCoreServices()
    }

    /// То, что нужно при ЛЮБОМ запуске процесса, — и когда систему подняла его
    /// в фоне (смена места, геозона после выгрузки), а окна нет: сцена не
    /// поднимается, и startDrivingServices (его зовёт сцена) не звался — не
    /// стартовал CoreMotion, автостарт поездки молчал до открытия приложения,
    /// и вся поездка шла в тихом режиме геозон (сценарий S3, 20.10). Только
    /// автостарт, лимиты и геопозиция: опрос отметок, сеть и прочее — по
    /// сцене или поездке, иначе каждое фоновое пробуждение тихого режима
    /// ходило бы на сервер. Повторные вызовы безопасны.
    private func startCoreServices() {
        Task { @MainActor [weak self] in
            guard let self, Storage.bool(.hasCompletedOnboarding) else { return }
            self.location.bootstrap()
            self.motion.start()
            self.speedLimits.start()
            // Поднятые в фоне: окно ~10 с, а уверенный автостарт CoreMotion
            // ждёт подтверждения 8 с — даём ему успеть (ревью S3).
            if UIApplication.shared.applicationState == .background {
                self.holdBackgroundWindow()
            }
        }
    }

    @ObservationIgnored private var launchBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func holdBackgroundWindow() {
        guard launchBackgroundTask == .invalid else { return }
        launchBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "autostart") { [weak self] in
            self?.endBackgroundWindow()
        }
        Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.backgroundLaunchWindowSeconds)
            self?.endBackgroundWindow()
        }
    }

    private func endBackgroundWindow() {
        guard launchBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(launchBackgroundTask)
        launchBackgroundTask = .invalid
    }

    /// Автостарт пришёл раньше истории с диска (процесс подняли в фоне на
    /// ходу): склейка с только что прерванной поездкой и восстановление
    /// снимка ещё не видят её — ждём историю (ревью S3, 20.10).
    @ObservationIgnored var pendingAutoStart = false
    /// Отключились от машины — поездка закончится после паузы (AppEnvironment+CarLink).
    @ObservationIgnored var carLinkStopTask: Task<Void, Never>?
    /// Меняется на ответе на предложение «Только в машине» — экран настроек
    /// перечитывает `offersCarOnlyMode` (флаги лежат в Storage, не наблюдаемы).
    var carOnlyOfferRevision = 0

    @ObservationIgnored private var tileProbeTask: Task<Void, Never>?

    #if canImport(MapLibre)
    private func tileServerHealthChanged(down: Bool) {
        network.setTileServerDown(down)
        tileProbeTask?.cancel()
        guard down else { return }
        tileProbeTask = Task { [weak self] in
            await Task.pause(seconds: AppConfig.tileServerProbeSeconds)
            guard !Task.isCancelled else { return }
            EngineTileGuard.resetHealthForProbe()
            self?.network.setTileServerDown(false)
        }
    }
    #endif

    /// Автостарт, отложенный до истории, — сейчас, если всё ещё едем.
    private func startPendingAutoStart() {
        guard pendingAutoStart else { return }
        pendingAutoStart = false
        guard !location.isTripActive else { return }
        if settings.tripStartMode == .carOnly {
            if carLink.isLinked { location.startTrip(byCarLink: true) }
        } else if motion.isDriving, settings.tripStartMode.usesMotion {
            location.startTrip(auto: true)
        }
    }

    /// Данные телефона стали доступны (разблокировка после перезагрузки,
    /// возврат на экран): хранилища, не прочитанные на старте, — сейчас, а не
    /// через паузу повтора (ревью S9, третий круг).
    func reloadProtectedStores() {
        trip.retryLoadNow()
        maintenance.reloadIfNeeded()
        energyJournal.reloadIfNeeded()
        trip.retryLegacyLifetime()
        commuteProfiles.retryLoadNow()
        cameras.reloadUserDataIfNeeded()
    }

    private func observeProtectedData() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadProtectedStores() }
            }
    }

    /// База камер изменилась (загрузка, своя камера, скрытие, чужая отметка) —
    /// пересобрать окно ближайших камер и оценить сразу. ОДНА точка: до 19.10
    /// то же делали хук отметок, MapScreen и экран машины — три пересборки
    /// окна и сетки на одну отметку при открытом телефоне и машине (аудит
    /// энергии). Здесь, а не во вью: среда жива всегда, тело вью со сложенным
    /// телефоном не исполняется — а именно там водитель и едет.
    ///
    /// Оценка тревоги СРАЗУ — только когда сменились чужие отметки (новый
    /// радар впереди не ждёт фикса); загрузка базы, своя камера и скрытие
    /// оцениваются на следующем фиксе, как и раньше, — не по позиции
    /// минутной давности стоящей машины.
    private func observeCameraRevision() {
        withObservationTracking {
            _ = cameras.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mobileChanged = self.cameras.mobileRevision != self.seenMobileRevision
                self.seenMobileRevision = self.cameras.mobileRevision
                // Новая версия базы (OTA) — сверка «новых на ваших дорогах»;
                // сервис сам пропускает уже сверенную версию.
                if self.cameras.isDatabaseLoaded { self.refreshCameraNews() }
                self.location.refreshMonitoring(evaluateNow: mobileChanged)
                self.observeCameraRevision()
            }
        }
    }
    @ObservationIgnored private var seenMobileRevision = 0

    /// Сверить базу с виденным набором (31E). Своих дорог до первой поездки
    /// нет — подсеваем их из треков истории, что ещё лежат.
    func refreshCameraNews() {
        let points = cameras.basePoints
        let version = cameras.dbVersion
        if trip.isLoaded { roadMemory.seedIfEmpty(from: trip.history) }
        Task { await roadMemory.refresh(points: points, version: version) }
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
        // Слой полос: индекс раз в неделю (и из машины — телефонной сцены
        // может не быть вовсе); в память — первым маршрутом.
        Task { await laneOverlay.refreshIfDue() }
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
    /// Срок, о котором можно спросить («вам нужно быть к 9:00?», 8.6), —
    /// минута суток или nil. Пересчитывается вместе с «дорогой», не в body.
    private(set) var workTargetSuggestion: Int?
    /// «Сейчас на работу ~44 мин» до выезда (8.8.6): профиль пути на этот час
    /// плюс пробки now.json сверх обычного — всё на телефоне. Считается по
    /// событиям (refreshDepartureEstimates), не в body.
    private(set) var departureEstimates: [Commute.Direction: CommuteEstimate.Estimate] = [:]
    /// Когда оценка посчитана: старше `commuteEstimateMaxAgeSeconds` — не
    /// «сейчас» (машина спрашивает догадку и без строки на телефоне).
    @ObservationIgnored private var departureEstimatesAt: Date?
    /// От чего посчитано: те же пробки, тот же профиль и та же четверть часа —
    /// пересчитывать нечего.
    @ObservationIgnored private var departureEstimatesKey: DepartureEstimateKey?
    /// Растёт при каждом запросе и сбросе: опоздавший ответ (обучение уже
    /// выключили, история стёрта, пришёл запрос новее) не пишется.
    @ObservationIgnored private var departureEstimatesGeneration = 0

    private struct DepartureEstimateKey: Equatable {
        let traffic: Int
        let book: Int
        let slot: Int
    }

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

    /// Смены таксиста для «Итогов» (12б.9): журнал закрытых плюс идущая из
    /// истории. Пересчёт — на старте сцены и в конце поездки, не в body.
    private(set) var workShifts: [WorkShift] = []
    @ObservationIgnored private var workShiftLog: [WorkShift] = AppEnvironment.loadShiftLog()

    func refreshWorkShifts(now: Date = Date()) {
        let history = trip.history
        // Идущий рейс — ещё не в истории, но смену продолжает: без него она
        // закрылась бы посреди рейса (WorkShift.isClosed). Рейс ли это,
        // решает режим на финише (trip.finish(work:)) — им и судим.
        let ongoing = location.isTripActive && settings.workDriverMode ? trip.startedAt : nil
        let next = WorkShift.logged(workShiftLog, history: history, now: now, ongoingSince: ongoing)
        if next != workShiftLog {
            workShiftLog = next
            do {
                Storage.set(try JSONEncoder().encode(next), for: .workShiftLog)
            } catch {
                Log.trips.error("журнал смен не записался: \(error.localizedDescription, privacy: .public)")
            }
        }
        let display = WorkShift.display(log: workShiftLog, history: history)
        if display != workShifts { workShifts = display }
    }

    /// «Удалить всю историю» (15.3): журнал закрытых смен копит рейсы 90
    /// дней отдельно от истории — без этого смены пережили бы удаление.
    func clearWorkShifts() {
        workShiftLog = []
        Storage.remove(.workShiftLog)
        if !workShifts.isEmpty { workShifts = [] }
    }

    private static func loadShiftLog() -> [WorkShift] {
        guard let data = Storage.data(.workShiftLog) else { return [] }
        do {
            return try JSONDecoder().decode([WorkShift].self, from: data)
        } catch {
            Log.trips.error("журнал смен не прочитался: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func refreshLearnedPlaces() {
        // Тем же тактом (старт сцены, конец поездки) — журнал смен (12б.9).
        defer { refreshWorkShifts() }
        guard settings.destinationSuggestions else {
            // Выключили подсказки — забываем и выученное: держать в памяти
            // домашний адрес, которым не пользуемся, незачем. Дорога на работу
            // остаётся только по заданным вручную местам.
            learnedPlaces = []
            noteLearnedQuietZones()
            refreshCommute()
            return
        }
        // Концы рабочих рейсов — адреса пассажиров, не свои Дом и Работа.
        learnedPlaces = FrequentPlaces.learn(history: trip.history.filter { $0.work != true }, now: Date())
        noteLearnedQuietZones()
        refreshCommute()
    }

    /// «Куда едем?» сейчас — одна догадка для телефона и машины
    /// (DestinationGuess); nil — нечего предложить или подсказки выключены.
    func destinationGuess(now: Date) -> DestinationGuess? {
        // В смене «Домой/На работу» — не та подсказка (12б.9).
        guard settings.destinationSuggestions, !settings.workDriverMode else { return nil }
        return DestinationGuess.make(
            learned: learnedPlaces,
            manual: { [settings] kind in settings.place(for: kind == .home ? .home : .work) },
            usual: { [commute] direction in commute.first { $0.direction == direction }?.usual },
            crowd: { [weak self] direction in self?.crowdUsual(direction) },
            estimate: { [departureEstimates, departureEstimatesAt] direction in
                guard let at = departureEstimatesAt,
                      now.timeIntervalSince(at) <= AppConfig.commuteEstimateMaxAgeSeconds else { return nil }
                return departureEstimates[direction]
            },
            from: location.currentCoordinate, now: now)
    }

    /// Пересчитать «сейчас ~44 мин», если что-то поменялось: пробки (или их
    /// выключили), профиль пути (свёртка поездки, стирание) или четверть часа
    /// на часах. Иначе — ничего: звать можно часто. Сверка линии с рёбрами —
    /// вне main.
    func refreshDepartureEstimates(now: Date = Date()) {
        guard settings.commuteLearning, commuteProfiles.isLoaded else {
            resetDepartureEstimates()
            return
        }
        let shown = traffic.isShown
        let key = DepartureEstimateKey(traffic: shown ? traffic.revision : -1,
                                       book: commuteProfiles.revision,
                                       slot: Int(now.timeIntervalSince1970 / AppConfig.commuteEstimateSlotSeconds))
        guard key != departureEstimatesKey else { return }
        departureEstimatesKey = key
        departureEstimatesGeneration &+= 1
        let generation = departureEstimatesGeneration
        let book = commuteProfiles.book
        let snapshot = shown ? traffic.snapshot : nil
        let accuracy = commuteProfiles.accuracy
        Task {
            let next = await Self.departureEstimates(book: book, snapshot: snapshot,
                                                     accuracy: accuracy, now: now)
            guard generation == departureEstimatesGeneration, settings.commuteLearning else { return }
            departureEstimatesAt = now
            if next != departureEstimates { departureEstimates = next }
            // Пробки «+8 мин» на виджет — запись только при смене минут.
            refreshCommuteWidget(now: now)
        }
    }

    private func resetDepartureEstimates() {
        departureEstimatesGeneration &+= 1
        departureEstimatesKey = nil
        departureEstimatesAt = nil
        if !departureEstimates.isEmpty { departureEstimates = [:] }
    }

    @concurrent
    private static func departureEstimates(book: CommuteProfile.Book, snapshot: TrafficSnapshot?,
                                           accuracy: [CommuteAccuracy.Entry],
                                           now: Date) async -> [Commute.Direction: CommuteEstimate.Estimate] {
        var result: [Commute.Direction: CommuteEstimate.Estimate] = [:]
        for direction in Commute.Direction.allCases {
            // Та же поправка журнала, что у призрака в пути (24.2).
            result[direction] = CommuteEstimate.beforeDeparture(
                variants: book[direction], now: now, snapshot: snapshot,
                bias: CommuteAccuracy.biasFactor(accuracy, direction: direction))
        }
        return result
    }

    /// Голос призрака — ниже камеры и манёвра; с маршрутом время прибытия
    /// говорит навигация, а не призрак. Фраза засчитывается только сказанной
    /// (`true`): под оповещением о камере она ждёт следующего пересчёта, а
    /// не теряется. «Камера занята» — то же правило, что у событий дороги и
    /// погоды: оповещение идёт, о камере вот-вот скажут или до её радиуса
    /// меньше восьми секунд пути (синтезатор ставит фразы в очередь, и
    /// камера ждала бы конца «Прибытие сдвинулось…», 24.3).
    private func wireCommuteVoice() {
        commuteLive.onAnnounce = { [weak self] phrase in
            guard let self, self.settings.voiceEnabled else { return true }
            guard !self.location.isCameraBusyForRoadNotes, !self.route.isActive else { return false }
            self.alerts.speak(phrase)
            return true
        }
    }

    /// Поездка началась, а призрак ещё не решён: на старте часто не из чего
    /// решать (запуск Siri до первого фикса, профиль ещё читается с диска,
    /// выученные места ещё не пересчитаны), поэтому решение повторяется на
    /// фиксах — до `commuteGhostStartWaitSeconds`.
    @ObservationIgnored private var commuteGhostPending = false

    /// Призрак: только при включённом «Время дороги на работу», с известными
    /// домом и работой и стартом поездки у одного из них.
    private func tryStartCommuteGhost() {
        guard commuteGhostPending else { return }
        guard settings.commuteLearning, !settings.workDriverMode else {
            commuteGhostPending = false
            return
        }
        let startedAt = trip.startedAt ?? Date()
        guard let start = trip.startCoordinate ?? location.currentCoordinate,
              commuteProfiles.isLoaded, let ends = commuteEnds else {
            if Date().timeIntervalSince(startedAt) > AppConfig.commuteGhostStartWaitSeconds {
                commuteGhostPending = false
                // Почему призрака нет — в журнал, без координат (учения В5).
                Log.trips.info("призрак: не дождались — старт \(self.trip.startCoordinate != nil || self.location.currentCoordinate != nil, privacy: .public), профиль \(self.commuteProfiles.isLoaded, privacy: .public), места \(self.commuteEnds != nil, privacy: .public)")
            }
            return
        }
        commuteGhostPending = false
        guard let direction = CommuteLiveService.direction(start: start, home: ends.home, work: ends.work)
        else {
            Log.trips.info("призрак: старт не у дома и не у работы")
            return
        }
        // Срок — от того, когда едем сейчас: склеенная поездка хранит начало
        // утренней (спортзал в 5:40), и окно «не раньше чем за 3 ч» по нему
        // теряло срок. Выборка «обычно» — по исходному выезду.
        let target = direction == .toWork ? settings.workArrivalTarget : nil
        commuteLive.start(direction: direction, variants: commuteProfiles.book[direction],
                          departure: startedAt,
                          deadline: target?.deadline(forDeparture: Date()),
                          workday: target?.applies(on: startedAt) ?? false,
                          bias: CommuteAccuracy.biasFactor(commuteProfiles.accuracy, direction: direction))
    }

    /// Включили или выключили «Выезжайте раньше» — в настройках или из
    /// предложения в «Итогах». Включение спрашивает разрешение на уведомления.
    func setDepartureReminders(_ on: Bool) {
        settings.departureRemindersAsked = true
        if settings.departureReminders != on { settings.departureReminders = on }
        guard on else { return refreshDepartureReminders() }
        // Ответ на вопрос о разрешении — до расписания: «нет» выключает
        // напоминания обратно, а не оставляет их включёнными впустую.
        Task {
            let granted = await notifications.requestAuthorizationResult()
            if !granted, settings.departureReminders {
                Log.app.notice("напоминания о выезде: уведомления запрещены — выключаю")
                settings.departureReminders = false
            }
            refreshDepartureReminders()
        }
    }

    /// Срок, места, обучение дороги и сами напоминания — пересчёт сразу при
    /// смене, а не со следующей поездки: перенесли «быть к» с 9:00 на 8:00 в
    /// воскресенье — в понедельник напоминание уже про 8:00 (ревью 20.10).
    private func observeCommuteSettings() {
        withObservationTracking {
            _ = settings.workArrivalTarget
            _ = settings.homePlace
            _ = settings.workPlace
            _ = settings.commuteLearning
            _ = settings.departureReminders
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCommute()
                self?.observeCommuteSettings()
            }
        }
    }

    /// Выключили «Время дороги на работу» посреди поездки — призрак гаснет
    /// сразу, а не на финише.
    func commuteLearningChanged() {
        if !settings.commuteLearning {
            commuteGhostPending = false
            commuteLive.stop()
            commuteProfiles.clear()
            resetDepartureEstimates()
        }
        refreshCommute()
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
        // Что бы ни случилось ниже — «сейчас ~44 мин» и напоминания следом:
        // места забыли — напоминания по ним сняты (ревью 20.10).
        defer {
            refreshDepartureEstimates()
            refreshDepartureReminders()
            refreshCrowdUsual()
        }
        // Журнал копит концы поездок 45 дней — история держит только 50
        // записей, и «медиана за 30 дней» на ней была медианой за 12–17.
        guard let ends = commuteEnds else {
            commute = []
            workTargetSuggestion = nil
            refreshCommuteWidget()
            return
        }
        let trips = settings.commuteLearning
            ? Commute.trips(history: commuteProfiles.updateLedger(with: trip.history.filter { $0.work != true }),
                            home: ends.home, work: ends.work)
            : Commute.trips(history: trip.history.filter { $0.work != true }, home: ends.home, work: ends.work)
        commute = Commute.summaries(trips: trips, now: Date())
        refreshCommuteWidget()
        // Вопрос о сроке — про выученный распорядок: обучение выключено —
        // не спрашиваем (и срок без призрака ничего бы не дал).
        workTargetSuggestion = settings.commuteLearning
            ? ArrivalTarget.suggestion(arrivals: trips.filter { $0.direction == .toWork }.map(\.arrival),
                                       now: Date())
            : nil
    }

    // MARK: - Обычно по водителям (8.8.16)

    /// «Обычно ~35 мин (по водителям)» по направлениям: линия своего пути,
    /// сложенная с обычными скоростями чужих поездок в час своего выезда.
    /// Считается событийно (refreshCommute), не в body.
    private(set) var crowdUsualTimes: [Commute.Direction: TimeInterval] = [:]
    /// Опоздавший ответ (места забыли, своё «обычно» уже появилось) не пишется.
    @ObservationIgnored private var crowdUsualGeneration = 0

    /// Оценка по водителям для показа: только пока своего «обычно» нет и
    /// пробки включены (выключили — строка гаснет сразу, не со следующего
    /// пересчёта).
    func crowdUsual(_ direction: Commute.Direction) -> TimeInterval? {
        guard traffic.isShown,
              commute.first(where: { $0.direction == direction })?.usual == nil else { return nil }
        return crowdUsualTimes[direction]
    }

    /// Что спросить: направления без своего «обычно», у которых уже есть
    /// свой путь в профиле и известен час выезда. Дом и работа нужны —
    /// без них направлений нет.
    private func crowdRequests() -> [Commute.Direction: TypicalTraffic.Request] {
        guard traffic.isShown, settings.commuteLearning, commuteProfiles.isLoaded,
              commuteEnds != nil else { return [:] }
        var out: [Commute.Direction: TypicalTraffic.Request] = [:]
        for direction in Commute.Direction.allCases {
            let summary = commute.first { $0.direction == direction }
            guard summary?.usual == nil,
                  let path = TypicalTraffic.line(of: commuteProfiles.book[direction]),
                  let departure = summary?.last.departure ?? path.lastDeparture else { continue }
            out[direction] = TypicalTraffic.Request(line: path.coordinates,
                                                    bucket: TypicalTraffic.bucket(for: departure))
        }
        return out
    }

    func refreshCrowdUsual() {
        crowdUsualGeneration &+= 1
        let generation = crowdUsualGeneration
        let requests = crowdRequests()
        guard !requests.isEmpty else {
            if !crowdUsualTimes.isEmpty { crowdUsualTimes = [:] }
            return
        }
        Task {
            let files = await typicalTraffic.files(for: Set(requests.values.map(\.bucket)))
            let next = await Self.crowdUsualTimes(requests: requests, files: files)
            guard generation == crowdUsualGeneration else { return }
            if next != crowdUsualTimes {
                crowdUsualTimes = next
                Log.trips.info("обычно по водителям: направлений \(next.count, privacy: .public)")
            }
        }
    }

    /// Сверка линий с рёбрами — вне main: файл по городу — тысячи рёбер.
    @concurrent
    private static func crowdUsualTimes(requests: [Commute.Direction: TypicalTraffic.Request],
                                        files: [TypicalTraffic.Bucket: TypicalTraffic])
        async -> [Commute.Direction: TimeInterval] {
        var out: [Commute.Direction: TimeInterval] = [:]
        for (direction, request) in requests {
            guard let file = files[request.bucket],
                  let estimate = TypicalTraffic.travelTime(along: request.line, typical: file) else { continue }
            out[direction] = estimate.seconds
        }
        return out
    }

    /// Виджет «Дорога на работу» (9.4): готовые минуты в App Group; пишется и
    /// перезагружается, только когда числа сменились (бюджет WidgetKit).
    private func refreshCommuteWidget(now: Date = Date()) {
        // Пока история или профиль дороги не прочитаны, «дороги нет» значит
        // «ещё не знаем»: профиль читается раньше истории, выученных мест
        // ещё нет — и запись стирала виджет и снимала фоновую заявку на каждом
        // холодном старте, а в фоновом подъёме — ровно утром (ревью 14.1).
        // Прочитается второе из двух — его колбэк и перепишет.
        guard trip.isLoaded, commuteProfiles.isLoaded else { return }
        let target = settings.commuteLearning ? settings.workArrivalTarget : nil
        func direction(_ kind: Commute.Direction) -> CommuteWidgetData.Direction? {
            guard let summary = commute.first(where: { $0.direction == kind }), let usual = summary.usual else {
                return nil
            }
            var leaveBy: Date?
            if kind == .toWork, let target {
                // Ближайший день, когда срок действует, и выезд к нему ещё впереди.
                for offset in 0...7 {
                    guard let day = Calendar.current.date(byAdding: .day, value: offset,
                                                          to: Calendar.current.startOfDay(for: now)),
                          target.applies(on: day) else { continue }
                    let leave = day.addingTimeInterval(Double(target.minute) * 60 - usual
                                                       - Double(AppConfig.departureReminderMarginMinutes) * 60)
                    if leave > now { leaveBy = leave; break }
                }
            }
            var result = CommuteWidgetData.Direction(usualSeconds: usual,
                                                     usualDepartureMinute: summary.usualDepartureMinute,
                                                     bestStartMinute: summary.best?.startMinute,
                                                     bestSeconds: summary.best?.medianDuration,
                                                     leaveBy: leaveBy)
            // «Сейчас ~44 мин» (12б.2): окно ближайшего выезда по 15 минут —
            // медиана своих поездок этого часа, без пробок (пробки — отдельно
            // и со сроком). Окно без своих поездок не пишется: обещать нечего.
            if settings.commuteLearning, commuteProfiles.isLoaded, let departure = summary.usualDepartureMinute {
                let variants = commuteProfiles.book[kind]
                let slots = WidgetCommute.slotStarts(usualDepartureMinute: departure, now: now).compactMap { start in
                    CommuteEstimate.beforeDeparture(variants: variants, now: start, snapshot: nil)
                        .map { CommuteWidgetData.Slot(start: start, seconds: $0.seconds) }
                }
                result.slots = slots.isEmpty ? nil : slots
            }
            // Пробки — из последнего пересчёта «сейчас» (на экране или в
            // фоновом обновлении перед выездом), с его временем: виджет сам
            // погасит их через 30 минут.
            if let at = departureEstimatesAt, let jam = departureEstimates[kind]?.jamSeconds,
               jam >= WidgetCommute.jamMinSeconds {
                result.jam = CommuteWidgetData.Jam(extraSeconds: (jam / 60).rounded() * 60, at: at)
            }
            return result
        }
        let toWork = direction(.toWork), toHome = direction(.toHome)
        var data = toWork == nil && toHome == nil
            ? nil : CommuteWidgetData(toWork: toWork, toHome: toHome, updatedAt: now)
        // Где телефон — только «дом»/«работа», без координат; позиции нет
        // (фоновый подъём) — прежняя отметка (WidgetCommute.placeMark).
        let stored = WidgetCommute.read()
        if let mark = WidgetCommute.placeMark(current: commuteWidgetPlace(),
                                              positionKnown: location.currentCoordinate != nil,
                                              previous: stored, now: now) {
            data?.lastPlace = mark.place
            data?.lastPlaceAt = mark.at
        }
        scheduleCommuteBackgroundRefresh(data, now: now)
        guard !WidgetCommute.sameNumbers(stored, data) else { return }
        WidgetCommute.write(data)
        WidgetCenter.shared.reloadTimelines(ofKind: "RadarCommuteWidget")
    }

    /// Последний заказанный системе фоновый подъём: заявка переставляется
    /// только при смене времени, а не на каждом пересчёте пробок.
    @ObservationIgnored private var commuteRefreshScheduledFor: Date?

    /// Попросить систему разбудить приложение за 30 мин до обычного выезда —
    /// за пробками для виджета. Только при включённых пробках и обучении:
    /// иначе будить не за чем.
    private func scheduleCommuteBackgroundRefresh(_ data: CommuteWidgetData?, now: Date) {
        guard settings.commuteLearning, traffic.isShown,
              let at = WidgetCommute.nextBackgroundRefresh(data: data, now: now,
                                                           lead: AppConfig.commuteRefreshLeadSeconds) else {
            if commuteRefreshScheduledFor != nil {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppConfig.commuteRefreshTaskID)
                commuteRefreshScheduledFor = nil
            }
            return
        }
        guard at != commuteRefreshScheduledFor else { return }
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.commuteRefreshTaskID)
        request.earliestBeginDate = at
        do {
            try BGTaskScheduler.shared.submit(request)
            commuteRefreshScheduledFor = at
        } catch {
            Log.app.notice("фоновое обновление дороги не заказано: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Фоновое пробуждение перед выездом: свежие пробки → «сейчас» по дороге
    /// → виджет. Без GPS: место телефона берётся из последней отметки.
    func commuteBackgroundRefresh() async {
        Log.app.notice("фоновое обновление дороги на работу")
        commuteRefreshScheduledFor = nil   // заявка израсходована
        // Процесс поднят ради этого подъёма: и профиль, и история ещё читаются
        // с диска — без истории нет выученных мест, а значит и дороги.
        var steps = 0
        while !(commuteProfiles.isLoaded && trip.isLoaded), steps < AppConfig.commuteRefreshProfileWaitSteps {
            await Task.pause(seconds: 0.1)
            steps += 1
        }
        guard settings.commuteLearning, commuteProfiles.isLoaded, trip.isLoaded else { return }
        if commute.isEmpty { refreshCommute() }
        // Поколение (правило 12): пока ждали пробки и считали, обучение могли
        // выключить (resetDepartureEstimates) или пересчитать свежее
        // (refreshDepartureEstimates) — тогда этот результат опоздал.
        departureEstimatesGeneration &+= 1
        let generation = departureEstimatesGeneration
        await traffic.refresh()
        let now = Date()
        let next = await Self.departureEstimates(book: commuteProfiles.book, snapshot: traffic.snapshot,
                                                 accuracy: commuteProfiles.accuracy, now: now)
        guard generation == departureEstimatesGeneration, settings.commuteLearning else { return }
        departureEstimatesAt = now
        if next != departureEstimates { departureEstimates = next }
        refreshCommuteWidget(now: now)
    }

    /// Телефон у дома или у работы (точная позиция, радиус концов дороги).
    private func commuteWidgetPlace() -> CommuteWidgetData.Place? {
        guard let ends = commuteEnds, let here = location.currentCoordinate,
              !location.isPositionCoarse else { return nil }
        func near(_ place: CLLocationCoordinate2D) -> Bool {
            GeoMath.fastDistance(here.latitude, here.longitude, place.latitude, place.longitude)
                <= AppConfig.commutePlaceRadiusMeters
        }
        if near(ends.home) { return .home }
        if near(ends.work) { return .work }
        return nil
    }

    /// Напоминать есть о чём (выгодный выезд или срок) — для предложения в «Итогах».
    private(set) var departureReminderAvailable = false

    /// Последний поставленный план «Выезжайте раньше»: переставляем только
    /// при изменении — не трогаем центр уведомлений на каждом пересчёте.
    @ObservationIgnored private var scheduledReminders: [DepartureReminder.Reminder]?

    /// «Выезжайте раньше» (8.8.7): по будням за 10 мин до выгодного выезда —
    /// из своей истории, без сервера. Выключено — снимаем всё поставленное.
    func refreshDepartureReminders(now: Date = Date(), tripEdge: Bool = false) {
        // Пока история или профиль дороги не прочитаны, пустой план — «ещё не
        // знаем»: снимать по нему поставленное нельзя (DepartureReminder.step).
        let loaded = trip.isLoaded && commuteProfiles.isLoaded
        var plan: [DepartureReminder.Reminder] = []
        if loaded {
            // Срок — только пока учится дорога: без неё его и задать негде.
            let target = settings.commuteLearning ? settings.workArrivalTarget : nil
            let candidate = DepartureReminder.plan(summary: commute.first { $0.direction == .toWork },
                                                   target: target, now: now, tripActive: location.isTripActive)
            // Есть что напомнить и куда показать — предложение в «Итогах» имеет смысл.
            let available = !candidate.isEmpty && notifications.authorizationStatus != .denied
            if departureReminderAvailable != available { departureReminderAvailable = available }
            plan = settings.departureReminders ? candidate : []
        }
        switch DepartureReminder.step(plan: plan, scheduled: scheduledReminders, dataLoaded: loaded,
                                      tripEdge: tripEdge, tripActive: location.isTripActive) {
        case .keep:
            return
        case .dropToday:
            Log.app.info("напоминания о выезде: поехали до чтения истории — снято только сегодняшнее")
            notifications.dropTodayDepartureReminder(now: now)
        case .replace(let deliveredToday):
            // Без разрешения не запоминаем «поставлено»: разрешат — поставим.
            scheduledReminders = notifications.canNotify ? plan : nil
            notifications.scheduleDepartureReminders(plan, now: now, deliveredToday: deliveredToday)
        }
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
        // «Дорога на работу»: где телефон остался (дом/работа) — направление
        // на утро; запись — только если что-то сменилось.
        refreshCommuteWidget()
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
            // То же правило, что в «Итогах» (31E): процент — только у
            // сопоставимых целых недель, идущая неделя его не получает.
            weekDeltaPercent: week.distanceChange?.percent,
            dayDistances: distances,
            dayOverspeed: overspeed,
            topRiskPlace: week.topOverLocation,
            topRiskPasses: week.topOverCount,
            usualWeekDistance: WidgetWeek.median(previousWeeks),
            monthDistance: month.distance,
            // «За всё время» ещё не перенесено (старт до разблокировки) —
            // прошлое значение, а не журнал одного процесса (ревью S9).
            lifetimeDistance: trip.isLifetimeTrusted ? trip.lifetime.distanceMeters
                                                     : SharedDefaults.read().lifetimeDistance,
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
