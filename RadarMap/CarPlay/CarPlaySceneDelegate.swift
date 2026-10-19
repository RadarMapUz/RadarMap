//
//  CarPlaySceneDelegate.swift
//  RadarMap
//
//  Вход CarPlay (категория Navigation): собственное окно карты + шаблоны
//  управления. Окружение общее с телефоном — камеры, маршрут, поездка живут
//  в одном экземпляре AppEnvironment.
//
//  Раскладка управления рассчитана на слепой тап за рулём:
//  • бар — «Поездка/Завершить» и звук слева, «Куда» и «Радар!» справа;
//  • кнопки карты — зум, осмотр, «к себе»;
//  • осмотр — по правилам CarPlay: в баре одна кнопка «Готово», на карте
//    две кнопки зума (больше система в осмотре не показывает);
//  • «Куда» — сетка крупных плиток (Дом, Работа, недавние) вместо списка:
//    попасть пальцем в плитку на кочке реально, в строку списка — нет.
//

import CarPlay
import SwiftUI
import os

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPMapTemplateDelegate, CPInterfaceControllerDelegate,
                                  CPSessionConfigurationDelegate {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей:
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor изолирует КАЖДЫЙ класс, а не
    /// только помеченный @MainActor, и синтезированный isolated deinit ведёт
    /// к свободе указателя, который никто не выделял (см. MapState).
    nonisolated deinit {}

    var interfaceController: CPInterfaceController?
    /// Баннеры поверх карты — одна очередь на подключение (CarPlayBanners):
    /// камера, объезд, вопрос, подтверждения.
    var banners: CarPlayBanners?
    /// Показанный вопрос «ещё на месте?» и его отметка — чтобы снять его,
    /// когда ответ уже не нужен (CarPlayAlerts.presentPendingConfirmIfNeeded).
    var confirmBanner: CPNavigationAlert?
    var confirmBannerID: Int?
    /// Вопрос, который истёк или закрыт без ответа: это «Пропустить», и
    /// второй раз о той же отметке не спрашиваем.
    var skippedConfirmID: Int?
    /// Вопрос ждёт остановки: скорость — не наблюдаемое событие, проверяем
    /// изредка, пока вопрос висит (CarPlayAlerts.waitToAsk).
    var confirmWatch: Task<Void, Never>?
    /// Начало сессии экрана машины — для суточной статистики (минуты).
    private var connectedAt: Date?
    /// Что машина запрещает на ходу (клавиатура, длинные списки) — держим,
    /// пока подключены: без ссылки делегат не получит ни одного изменения.
    private var sessionConfiguration: CPSessionConfiguration?
    /// Клавиатура сейчас недоступна (на ходу в большинстве машин). Поиск по
    /// адресу тогда — только на стоянке (Руководство CarPlay, стр. 25, 51).
    private(set) var keyboardLimited = false
    /// Показанная сетка «Куда» — её плитку «Поиск» переключаем, когда машина
    /// остановилась или тронулась.
    private weak var destinationsGrid: CPGridTemplate?
    private var mapTemplate: CPMapTemplate?
    /// Постоянный корень окна машины на всё подключение (CarPlayWindowRoot):
    /// хост CarPlay показывает слой именно этого корня, и подменять его нельзя.
    private var windowRoot: CarPlayWindowRoot?
    /// Хост SwiftUI внутри корня — его и пересоздаём, не трогая корень.
    private weak var host: UIHostingController<AnyView>?
    /// Сигналы шаблона карте; тема машины нужна и баннерам (CarPlayAlerts).
    let model = CarPlayMapModel()
    /// Навигационная сессия CarPlay: манёвр, время в пути, полосы, камеры
    /// поверх чужого приложения.
    private lazy var guidance = CarPlayGuidance(model: model)
    /// Поиск адреса в машине: тот же порядок источников, что на телефоне.
    private lazy var search: CarPlaySearch = {
        let search = CarPlaySearch { [weak self] place in self?.route(to: place) }
        search.present = { [weak self] template in self?.pushSearchResults(template) }
        return search
    }()
    /// Чей сейчас экран машины. Переподключение (штатное «моргание» провода
    /// при запуске двигателя) может доставить didDisconnect СТАРОЙ сцены уже
    /// ПОСЛЕ didConnect новой — и старая, уходя, глобально гасила GPS и опрос
    /// отметок у живой. Глобальное состояние трогает только владелец.
    private static weak var activeDelegate: CarPlaySceneDelegate?
    /// Поколение сессии CarPlay: подписки withObservationTracking из прошлых
    /// подключений сверяются с ним и не пересобирают кнопки повторно.
    var session = 0

    var env: AppEnvironment { AppEnvironment.shared }

    // MARK: - Жизненный цикл сцены

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        // templateDidAppear — единственный надёжный момент, когда шаблон уже
        // на экране и бар примется (см. там же).
        interfaceController.delegate = self
        let configuration = CPSessionConfiguration(delegate: self)
        sessionConfiguration = configuration
        keyboardLimited = configuration.limitedUserInterfaces.contains(.keyboard)
        // Сторож фризов main на время сессии машины. В DEBUG он уже стоит с
        // запуска; здесь он нужен ИМЕННО в релизе — жалоба «экран машины стоит»
        // приходит из TestFlight, а прибора под неё до сих пор не существовало.
        HitchWatch.start()
        // Фризы ДО машины к ней не относятся: счёт сессии — с нуля.
        _ = HitchWatch.drain()
        HitchWatch.setCounting(true)
        connectedAt = Date()

        // День/ночь — ДО первого кадра: тема машины (датчик света) в «Авто»
        // старше солнца, и первый кадр раньше всегда был тёмным.
        model.carIsDark = scene.contentStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: env.sunIsUp)

        // Сцена часто подключается в ФОНЕ: телефон с идущей поездкой
        // подключили к машине, а на её экране последним был Яндекс (журнал
        // 11.10, 16:20:28 — BG-Active). Окно в этот момент ещё не привязано к
        // экрану («cannot add handler to 0 from 0» через 80 мс), и строить в
        // нём карту и HUD нельзя: до 2.2.6 проверка была `!= .background`,
        // подключение в состоянии «ещё не на экране» её проходило, дерево
        // строилось вслепую, а сторож пересоздавал его — тоже в фоне. Потом
        // водитель открывал RadarMap, кнопки шаблона жили, а окно стояло.
        // Теперь окно строится только на экране, и всегда заново
        // (sceneWillEnterForeground).
        let shown = Self.isShown(scene)
        model.isOnScreen = shown
        // Корень окна — СРАЗУ и один раз (CarPlayWindowRoot): без него хост
        // CarPlay считает, что видимого окна нет, и экран машины пустой
        // (2.2.6, «not considered visible»). Содержимое — только на экране.
        let root = CarPlayWindowRoot()
        root.onMapButtonInsets = { [weak self] insets in
            Log.carplay.info("кнопки карты занимают: справа \(Int(insets.right), privacy: .public), слева \(Int(insets.left), privacy: .public), снизу \(Int(insets.bottom), privacy: .public)")
            self?.model.mapButtonInsets = EdgeInsets(top: insets.top, leading: insets.left,
                                                     bottom: insets.bottom, trailing: insets.right)
        }
        window.rootViewController = root
        windowRoot = root
        // Содержимое — только когда и сцена на экране, и приложение не в фоне:
        // MLNMapView, созданный при applicationState == .background, стартует
        // «спящим» и будится не всегда (MLNMapView.mm 6.29, dormant) — карта
        // осталась бы пустой или стоящей. Иначе — в sceneDidBecomeActive.
        if shown && UIApplication.shared.applicationState != .background {
            installHost()
        } else {
            needsFreshHost = true
        }
        rootShown = false
        rootSet = nil
        rootRetried = false
        offeredDestination = false

        let template = CPMapTemplate()
        template.mapDelegate = self
        // Бар НЕ прячем: «Поездка» и «Куда» должны быть на виду всегда —
        // кнопка, которую нужно искать, за рулём бесполезна. И кнопки карты
        // вместе с баром не прячем: он и так всегда на виду.
        template.automaticallyHidesNavigationBar = false
        template.hidesButtonsWithNavigationBar = false
        mapTemplate = template
        // Возврат карты к машине (таймер, камера впереди) закрывает и осмотр:
        // иначе в баре оставалась одна «Готово» (аудит 18.10, п. 1).
        model.onClosePanning = { [weak self] in self?.leavePanning(reason: "возврат к машине") }
        let banners = CarPlayBanners(template: template)
        banners.onIdle = { [weak self] in self?.bannersFreed() }
        banners.onDropped = { [weak self] alert in self?.forgetBanner(alert) }
        self.banners = banners
        // В машине приложение «на переднем плане», даже если телефон заблокирован
        // в кармане — у CarPlay свой флаг, телефонная сцена его не затирает.
        // Через окружение: телефонный экран по этому же флагу уступает место
        // экрану передачи (MapKit на двух экранах разом — двойной нагрев).
        Self.activeDelegate = self
        env.setCarPlayConnected(true)
        // CarPlay может быть ПЕРВОЙ сценой процесса: без этого вызова база
        // лимитов, краудсорс и автостарт стартовали только из телефонной сцены,
        // и поездка из машины писалась без лимитов — без рейтинга и штрафов.
        env.startDrivingServices()
        session += 1
        // Кнопки — ДО установки корня: шаблон уходит в машину уже с ними, а
        // не пустым с кнопками вдогонку. Повтор — в templateDidAppear.
        resendButtons()
        observePendingConfirm()
        observeDetour()
        observeTripSaved()
        startFreezeWatch(scene: scene)
        Log.carplay.notice("CarPlay подключён, сцена \(Self.stateName(scene), privacy: .public)")
        // Без анимации: анимированная установка корня у сцены в фоне
        // теряется (так же лечили пропажу кнопок в CoMaps).
        setRoot(template, on: interfaceController)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        Log.carplay.notice("CarPlay отключён")
        previewWatch?.cancel()
        previewWatch = nil
        previewTrip = nil
        previewDestination = nil
        flowPhase = nil
        model.isPreviewing = false
        offerTask?.cancel()
        offerTask = nil
        self.interfaceController = nil
        sessionConfiguration = nil
        mapTemplate = nil
        windowRoot?.setContent(nil)
        windowRoot = nil
        templateWatch?.cancel()
        templateWatch = nil
        freezeWatch?.cancel()
        freezeWatch = nil
        panningFallback?.cancel()
        panningFallback = nil
        stopPanHold()
        isPanning = false
        guidance.detach()
        session += 1   // гасим подписки syncTemplate этой сессии
        banners?.reset()
        banners = nil
        confirmWatch?.cancel()
        confirmWatch = nil
        confirmBanner = nil
        confirmBannerID = nil
        detourAlert = nil
        detourAlertID = nil
        // Глобальное состояние гасит только владелец экрана: запоздавший
        // didDisconnect старой сцены, пришедший после didConnect новой,
        // выключал бы непрерывный GPS и опрос отметок у ЖИВОЙ сессии.
        guard Self.activeDelegate === self else {
            Log.carplay.notice("didDisconnect устаревшей сцены — глобальное состояние не трогаем")
            return
        }
        Self.activeDelegate = nil
        if let connectedAt {
            env.usage.noteCarPlaySession(minutes: Int(Date().timeIntervalSince(connectedAt) / 60),
                                         hitches: HitchWatch.drain())
            self.connectedAt = nil
        }
        HitchWatch.setCounting(false)
        #if !DEBUG
        // В релизе сторож живёт только с машиной (в DEBUG он стоит с запуска).
        HitchWatch.stop()
        #endif
        // Вышли из машины: телефон мог всё это время быть в фоне, события
        // scenePhase не будет — снимаем «передний план» сами.
        AppEnvironment.shared.setCarPlayConnected(false)
        // Тишина — атрибут ПОЕЗДКИ, а не настройка: кнопку жали в машине
        // (спит пассажир, идёт разговор), и без отката телефон навсегда
        // оставался в «Молча», а человек не связал бы это с кнопкой в машине.
        // Откатываем только тишину, включённую КНОПКОЙ машины (маркер в
        // Storage): выключенное руками в настройках не трогаем.
        if Storage.bool(.carPlayMuted) { unmute() }
    }

    /// Машина сменила тему (включились фары, въехали в тоннель).
    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        model.carIsDark = contentStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: env.sunIsUp)
    }

    /// Сторож застывшего окна. 11.10 кнопки шаблона жили, а картинка в окне
    /// машины стояла пиксель в пиксель, и главный поток при этом не висел —
    /// то есть мёртвым было дерево SwiftUI в CPWindow, а не приложение.
    ///
    /// Две улики, обе пишет само дерево (CarPlayLiveness): тик GPS, на который
    /// оно перерисовалось, и пульс TimelineView. Тик один слеп у стоящей
    /// машины — фиксов нет минутами, и 11.10 застывание на столе сторож не
    /// заметил; пульс бьёт и без GPS. Проверка — только когда сцена на
    /// переднем плане: в фоне дерево и не обязано обновляться, и именно там
    /// прежний сторож «чинил» окно, пересоздавая хост вслепую. Чинить больше
    /// carPlayFreezeRepairs раз за показ бессмысленно — дальше только пишем.
    private var freezeWatch: Task<Void, Never>?
    private var freezeRepairs = 0
    private var heartbeatReported = false

    private func startFreezeWatch(scene: CPTemplateApplicationScene) {
        freezeWatch?.cancel()
        freezeWatch = Task { @MainActor [weak self, weak scene] in
            while !Task.isCancelled {
                await Task.pause(seconds: AppConfig.carPlayFreezeCheckSeconds)
                guard let self, let scene, scene.activationState == .foregroundActive,
                      self.model.isOnScreen, self.host != nil else { continue }
                let behind = self.env.location.locationTick - self.model.lastRenderedTick
                let silence = Date().timeIntervalSince(self.model.lastHeartbeat)
                // Пульс TimelineView — только улика, не повод чинить: такт,
                // взятый не от экрана машины, при погашенном экране телефона
                // встаёт (форум Apple 777989), и сторож перезагружал бы живую
                // карту. Чиним только по тикам GPS, которые дерево не отметило.
                if behind <= AppConfig.carPlayFreezeTicks {
                    if silence > AppConfig.carPlayHeartbeatStaleSeconds, !self.heartbeatReported {
                        self.heartbeatReported = true
                        Log.carplay.fault("пульс экрана машины молчит \(Int(silence), privacy: .public) с при живых тиках — только пишу")
                    }
                    continue
                }
                guard self.freezeRepairs < AppConfig.carPlayFreezeRepairs else {
                    Log.carplay.fault("окно машины стоит и после \(self.freezeRepairs, privacy: .public) пересозданий: тиков \(behind, privacy: .public), пульс молчит \(Int(silence), privacy: .public) с")
                    continue
                }
                self.freezeRepairs += 1
                Log.carplay.fault("окно машины застыло: тиков \(behind, privacy: .public), пульс молчит \(Int(silence), privacy: .public) с — пересоздаю хост")
                self.installHost()
            }
        }
    }

    /// Хост окна нужно построить заново при следующем выходе на экран: сцена
    /// подключилась в фоне или побывала в фоне.
    private var needsFreshHost = false

    /// Экран машины — новым содержимым постоянного корня. Только на переднем
    /// плане (см. didConnect): дерево, построенное в окне, которое система не
    /// показывает, потом не оживало. Корень окна при этом не меняется.
    private func installHost() {
        guard let windowRoot else {
            Log.carplay.error("хост экрана машины: корня окна нет")
            return
        }
        let host = UIHostingController(rootView: AnyView(
            CarPlayMapScreen(model: model).environment(env)))
        host.view.backgroundColor = UIColor(Theme.background)
        windowRoot.setContent(host)
        self.host = host
        needsFreshHost = false
        // Новое дерево ещё не успело отметиться — без сброса сторож счёл бы
        // его застывшим по меткам прежнего.
        model.lastHeartbeat = Date()
        model.lastRenderedTick = env.location.locationTick
    }

    /// Сцена на экране машины: на переднем плане (активна или нет — например,
    /// поверх висит системный алерт).
    private static func isShown(_ scene: UIScene) -> Bool {
        scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
    }

    private static func stateName(_ scene: UIScene) -> String {
        switch scene.activationState {
        case .foregroundActive:   return "на экране"
        case .foregroundInactive: return "на экране (неактивна)"
        case .background:         return "в фоне"
        case .unattached:         return "не привязана к экрану"
        @unknown default:         return "неизвестно"
        }
    }

    // MARK: - Сборка шаблона

    /// Поколение подписки syncTemplate: живой остаётся только ПОСЛЕДНЯЯ.
    /// Каждый вызов регистрирует новую одноразовую подписку, и без поколения
    /// каждый тап «Схема/Карта» добавлял по две вечно перевзводящиеся: после
    /// N тапов любое изменение состояния пересобирало шаблон N раз подряд.
    private var syncGeneration = 0

    /// Что сейчас отправлено в магнитолу. Кнопки — не память, а сообщения на
    /// головное устройство: каждое присваивание заменяет их там целиком, и
    /// тап, пришедшийся на замену, теряется. Наблюдение будит пересборку на
    /// любое касание отслеживаемого (а MapKit дёргал слежение на каждом «+»),
    /// поэтому отправляем только реально изменившееся.
    private var sentBar: [Bool]?
    private var sentMapButtons: [Bool]?

    /// Открыт ли сейчас осмотр карты: бар на это время — одна кнопка «Готово».
    private var isPanning = false

    /// Единая пересборка кнопок: и бар, и кнопки карты зависят от состояния
    /// (идёт поездка, построен маршрут, включён звук). Читаем состояние внутри
    /// withObservationTracking — при любом изменении собираем заново.
    func syncTemplate() {
        guard let mapTemplate else { return }
        // Кнопки шаблона живут на головном устройстве: каждое присваивание —
        // сообщение туда, а не запись в память.
        MainWork.note(MainWork.Name.carButtons)
        defer { MainWork.note(MainWork.idle) }
        let session = session   // подписка живёт до первого изменения — привязываем к сессии
        syncGeneration &+= 1
        let generation = syncGeneration

        withObservationTracking {
            let tripActive = env.location.isTripActive
            let routeActive = env.route.isActive
            let muted = isMuted   // читает оба тумблера — оба и отслеживаем
            let following = model.isFollowing
            let panning = isPanning
            let previewing = model.isPreviewing

            // Осмотр по правилам CarPlay: система своей кнопки выхода не даёт
            // и требует её В БАРЕ (заголовок CPMapTemplate). Раньше «выйти»
            // было кнопкой карты, а бар после осмотра никто не возвращал — и
            // в 2.2.3 он исчезал насовсем: без «Поездки», «Куда» и «Радар!».
            let bar = [tripActive, routeActive, muted, panning, previewing]
            if bar != sentBar {
                sentBar = bar
                Log.carplay.notice("бар шаблона: поездка=\(tripActive), маршрут=\(routeActive), тишина=\(muted), осмотр=\(panning), выбор=\(previewing)")
                if panning {
                    mapTemplate.leadingNavigationBarButtons = []
                    mapTemplate.trailingNavigationBarButtons = [panDoneButton]
                } else if previewing {
                    mapTemplate.leadingNavigationBarButtons = [cancelPreviewButton]
                    mapTemplate.trailingNavigationBarButtons = []
                } else {
                    mapTemplate.leadingNavigationBarButtons = [tripButton(active: tripActive),
                                                               soundButton(muted: muted)]
                    mapTemplate.trailingNavigationBarButtons = [destinationsButton(routeActive: routeActive),
                                                                reportButton]
                }
            }
            // В осмотре система показывает не больше двух кнопок карты и
            // прячет лишние с конца — оставляем ровно зум.
            let buttons = [following, panning]
            if buttons != sentMapButtons {
                sentMapButtons = buttons
                mapTemplate.mapButtons = panning
                    ? [zoomInButton, zoomOutButton]
                    : [zoomInButton, zoomOutButton, panButton, recenterButton]
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session,
                      self.syncGeneration == generation else { return }
                self.syncTemplate()
            }
        }
    }

    // MARK: - Осмотр карты

    /// Панорама в машине идёт НЕ через жесты SwiftUI: касаниями на карте
    /// распоряжается шаблон, а приложению приходят команды делегата.
    ///
    /// Сдвиг жеста приходит ПРИРАЩЕНИЕМ за кадр, а не от начала жеста. Замер
    /// 12.10 (carplay11: iOS 26, CarPlay Simulator с сенсорным профилем): за
    /// 2,4 с одного жеста — 135 вызовов по −10…−40 точек, последний около
    /// нуля (палец встал перед отрывом), у трёх из четырёх жестов — ровно 0.
    /// До 2.2.15 сдвиг считали накопленным и брали разницу соседних вызовов —
    /// от пальца оставался шум, и карта стояла: «перетаскиваю, а он не
    /// двигается». Сумма — только для журнала.
    private var panSum = CGPoint.zero

    /// Перетаскивание пальцем. Само окно карты касаний не получает никогда
    /// (CPWindow: «does not receive tap or drag events») — жест приходит
    /// только сюда, и только от машин с сенсорным экраном: «CarPlay doesn't
    /// call this method when connected to some CarPlay systems». В CarPlay
    /// Simulator — только в профиле с `primaryInput: Touch`: в стандартных
    /// мышь идёт как тачпад (нажатия и фокус), и жеста нет вовсе.
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        panSum = .zero
        panUpdates = 0
        Log.carplay.notice("перетаскивание пальцем: начало")
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        panSum = CGPoint(x: panSum.x + translation.x, y: panSum.y + translation.y)
        panUpdates += 1
        if panUpdates <= 3 {
            Log.carplay.notice("перетаскивание: шаг \(Int(translation.x), privacy: .public),\(Int(translation.y), privacy: .public), скорость \(Int(velocity.x), privacy: .public),\(Int(velocity.y), privacy: .public)")
        }
        model.pan(by: CGSize(width: translation.x, height: translation.y))
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        Log.carplay.notice("перетаскивание: конец, обновлений \(self.panUpdates, privacy: .public), сумма \(Int(self.panSum.x), privacy: .public),\(Int(self.panSum.y), privacy: .public)")
        panSum = .zero
    }

    private var panUpdates = 0

    /// Кнопки-стрелки на головных устройствах без сенсора: там панорамируют
    /// крутилкой, и шаг обязан быть заметным — иначе до соседнего квартала
    /// придётся щёлкать полминуты.
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     panWith direction: CPMapTemplate.PanDirection) {
        let step = AppConfig.carPlayPanStep
        var translation = CGSize.zero
        if direction.contains(.left)  { translation.width += step }
        if direction.contains(.right) { translation.width -= step }
        if direction.contains(.up)    { translation.height += step }
        if direction.contains(.down)  { translation.height -= step }
        model.pan(by: translation)
    }

    /// Стрелку держат: панорамируем, пока не отпустят. Один шаг на удержание
    /// заставлял щёлкать до соседнего квартала полминуты.
    ///
    /// Цикл обязан кончиться и без «отпустили»: событие конца теряется, если
    /// осмотр закрылся сам (автовозврат, камера впереди) или машину отключили —
    /// до 19.10 карта тогда ехала вечно, а `self?` без выхода держал шаблон
    /// (аудит CarPlay 19.10). Отсюда отмена в leavePanning/dismiss/disconnect
    /// и потолок шагов `CarPlayBrowse.panHoldContinues`.
    func mapTemplate(_ mapTemplate: CPMapTemplate, panBeganWith direction: CPMapTemplate.PanDirection) {
        stopPanHold()
        panHoldTask = Task { @MainActor [weak self] in
            var steps = 0
            while !Task.isCancelled, CarPlayBrowse.panHoldContinues(steps: steps), let self {
                self.mapTemplate(mapTemplate, panWith: direction)
                steps += 1
                await Task.pause(seconds: AppConfig.carPlayPanHoldInterval)
            }
        }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panEndedWith direction: CPMapTemplate.PanDirection) {
        stopPanHold()
    }

    private func stopPanHold() {
        panHoldTask?.cancel()
        panHoldTask = nil
    }

    private var panHoldTask: Task<Void, Never>?

    /// Щипок на сенсорном экране (iOS 26): масштаб — командой карте.
    ///
    /// SDK: «scale factor relative to the zoom gesture» — то есть от НАЧАЛА
    /// жеста, как у UIPinchGestureRecognizer. Карте нужен множитель шага,
    /// поэтому делим на прошлое значение. До 2.2.16 значение умножалось как
    /// есть каждый кадр и не сбрасывалось между жестами — накопленный масштаб
    /// разгонял бы карту, а остаток прошлого жеста переходил в следующий.
    /// Журнал пишет первые значения: с перетаскиванием документация уже
    /// оказалась неточной (там приходит шаг, а не путь от начала).
    private var pinchLast: CGFloat = 1
    private var pinchUpdates = 0

    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        pinchLast = 1
        pinchUpdates = 0
        model.pinchBegan()
        Log.carplay.notice("щипок: начало")
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint,
                     scale: CGFloat, velocity: CGFloat) {
        pinchUpdates += 1
        if pinchUpdates <= 3 {
            Log.carplay.notice("щипок: масштаб \(Double(scale), format: .fixed(precision: 3), privacy: .public), скорость \(Double(velocity), format: .fixed(precision: 2), privacy: .public)")
        }
        guard scale > 0, pinchLast > 0 else { return }
        model.pinch(scale: Double(scale / pinchLast))
        pinchLast = scale
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        Log.carplay.notice("щипок: конец, обновлений \(self.pinchUpdates, privacy: .public), итог \(Double(self.pinchLast), format: .fixed(precision: 3), privacy: .public)")
        pinchLast = 1
    }

    /// Осмотр открылся — бар становится одной кнопкой «Готово». Своим
    /// вызовом `showPanningInterface` мы это и так знаем, но осмотр умеет
    /// открываться и мимо нас, и состояние кнопок обязано следовать за
    /// шаблоном, а не за нашим тапом.
    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        guard !isPanning else { return }
        isPanning = true
        syncTemplate()
        model.panningShown()
    }

    /// Осмотр закрыт — бар и кнопки карты отправляются ЗАНОВО, даже если по
    /// нашему ключу они «не менялись»: что показывает головное устройство
    /// после осмотра, решаем не мы, и кэш sentBar ему не указ.
    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        stopPanHold()
        isPanning = false
        panningFallback?.cancel()
        panningFallback = nil
        model.panningHidden()
        resendButtons()
    }

    /// Закрыть осмотр: шаблону — `dismissPanningInterface`, бар вернёт его
    /// событие (mapTemplateDidDismissPanningInterface). Событие приходит не
    /// всегда — осмотр мог так и не открыться (кнопку нажали в момент смены
    /// шаблона), — поэтому после паузы бар возвращаем сами: застрявшая
    /// «Готово» — ровно та пропажа кнопок, которую здесь чиним.
    private func leavePanning(reason: String) {
        stopPanHold()
        guard isPanning, let mapTemplate else { return }
        Log.carplay.notice("осмотр закрываю: \(reason, privacy: .public)")
        mapTemplate.dismissPanningInterface(animated: true)
        panningFallback?.cancel()
        panningFallback = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayPanningDismissFallbackSeconds)
            guard !Task.isCancelled, let self, self.isPanning else { return }
            Log.carplay.fault("осмотр: закрытие не подтвердилось — бар возвращаю сам")
            self.isPanning = false
            self.model.panningHidden()
            self.resendButtons()
        }
    }

    private var panningFallback: Task<Void, Never>?

    /// Бар и кнопки карты — заново, мимо кэша «что уже отправлено».
    private func resendButtons() {
        sentBar = nil
        sentMapButtons = nil
        syncTemplate()
    }

    // MARK: - Шаблон на экране

    /// Корневой шаблон показан (после подключения, после закрытого «Куда»,
    /// алерта или поиска). Бар отправленный раньше этого момента головное
    /// устройство теряет: журнал 2.2.3 показал, что хост держал сцену в фоне
    /// и отвечал «No active map template found», а completion у
    /// setRootTemplate пришёл через 25 мс — до показа. Здесь шаблон уже на
    /// экране, и отправка гарантированно доходит.
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        shownTemplate = aTemplate === mapTemplate ? nil : aTemplate
        // Улика для «диалог не показался»: баннеры живут на шаблоне карты и
        // под сеткой или поиском не видны, а templateDidAppear уже оказался
        // ненадёжным для корня (carplay4, carplay10).
        if aTemplate !== mapTemplate {
            Log.carplay.notice("поверх карты: \(String(describing: type(of: aTemplate)), privacy: .public)")
        }
        guard aTemplate === mapTemplate else { return }
        resendButtons()
        rootDidShow(via: "templateDidAppear")
        // Вернулись к карте из «Куда» или поиска — ждавший вопрос теперь видно.
        presentPendingConfirmIfNeeded()
    }

    /// Корень на экране машины — один раз за подключение. Признак — либо
    /// templateDidAppear, либо активная сцена с подтверждённой установкой
    /// (CarPlayRootWatch): первый система присылает не всегда.
    private func rootDidShow(via source: String) {
        guard !rootShown, let mapTemplate else { return }
        rootShown = true
        templateWatch?.cancel()
        Log.carplay.notice("корневой шаблон на экране: \(source, privacy: .public)")
        // Сессия — только на шаблоне, который уже на экране: начатая на
        // летящем корне пропадала, а свой баннер манёвра при этом уже спрятан
        // (hasSystemGuidance) — водитель без манёвра. Completion у
        // setRootTemplate для этого не годится: он приходил через 25 мс, пока
        // хост ещё держал сцену в фоне.
        // Выбор на телефоне уже идёт — тот же выбор и здесь, до сессии.
        observeFlow()
        if let banners { guidance.attach(to: mapTemplate, banners: banners) }
        // Алерт о разрешении — сразу, а не по первому тапу: без разрешения
        // экран машины не покажет ни скорости, ни камер, и молчание
        // неотличимо от поломки. Поверх летящего корня CarPlay его отклонял.
        if !env.location.isAuthorized { return showNoPermissionAlert() }
        offerDestinationSoon()
    }

    // MARK: - Фаза маршрута

    /// Фаза при прошлом решении о выборе (NavigationFlow); nil — с
    /// подключения решений не было.
    private var flowPhase: NavigationFlow.Phase?
    /// Цель, выбор к которой на экране: маршрут заменили на телефоне —
    /// выбор показывает новый.
    private var previewDestination: CLLocationCoordinate2D?

    /// Телефон и машина — в одной фазе: маршрут, построенный на телефоне,
    /// здесь — тот же выбор с «Поехали»; «Поехали» или крестик там закрывают
    /// выбор здесь. Ведение (сессия) следует за той же фазой в CarPlayGuidance.
    private func observeFlow() {
        let session = session
        syncChoice()
        withObservationTracking {
            _ = env.route.isActive
            _ = env.route.isBuilding
            _ = env.route.destinationCoordinate
            _ = env.location.isTripActive
            _ = model.isPreviewing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.observeFlow()
            }
        }
    }

    private func syncChoice() {
        guard mapTemplate != nil, rootShown else { return }
        let route = env.route
        let phase = NavigationFlow.phase(hasRoute: route.isActive, isTripActive: env.location.isTripActive)
        let building = route.isBuilding
        let moving = !CarPlayTripPreview.shouldPreview(speedKmh: env.location.speedKmh)
        let decision = NavigationFlow.carChoice(from: flowPhase, to: phase,
                                                showing: model.isPreviewing, building: building,
                                                moving: moving)
        // Пока строится, фаза промежуточная — прошлой её не считаем: иначе
        // маршрут, достроенный на телефоне, не открыл бы выбор здесь.
        if !building { flowPhase = phase }
        switch decision {
        case .none:
            // Тот же выбор, но маршрут заменили на телефоне — показать новый.
            if model.isPreviewing, !building, phase == .choosing,
               let destination = route.destinationCoordinate, let shown = previewDestination,
               !CarPlayGuidance.same(shown, destination) {
                showPreview(name: route.destinationName, destination: destination)
            }
        case .show:
            guard let destination = route.destinationCoordinate else { return }
            Log.carplay.notice("выбор маршрута — с телефона или после автостопа")
            model.isPreviewing = true
            showPreview(name: route.destinationName, destination: destination)
        case .close:
            endPreview(start: false, keepRoute: true,
                       reason: phase == .free ? "маршрут снят не в машине" : "поехали не из машины")
        }
    }

    // MARK: - Объезд пробки

    /// Предложение объезда, показанное баннером в машине (id из RouteService).
    private var detourAlertID: Int?
    private var detourAlert: CPNavigationAlert?

    /// Одно состояние на два экрана: предложение живёт в RouteService,
    /// ответ на телефоне снимает баннер здесь, и наоборот.
    private func observeDetour() {
        let session = session
        withObservationTracking {
            _ = env.route.detourOffer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.syncDetourAlert()
                self.observeDetour()
            }
        }
    }

    private func syncDetourAlert() {
        guard let banners else { return }
        let offer = env.route.detourOffer
        if let shownID = detourAlertID, offer?.id != shownID {
            // Ответили на телефоне или истекло — снять своё. Пришло другое —
            // новое заменит прежнее само (show): два снятия подряд CarPlay
            // мог бы сложить так, что новое не встало бы.
            let shown = detourAlert
            detourAlertID = nil
            detourAlert = nil
            if offer == nil, let shown { banners.dismiss(shown) }
        }
        guard let offer, detourAlertID == nil else { return }
        let alert = CPNavigationAlert(
            titleVariants: [offer.title],
            subtitleVariants: [offer.subtitle, String(localized: "Объезд пробки")],
            image: CarPlayGuidance.symbol("arrow.triangle.branch", pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Объехать"), style: .default) { [weak self] _ in
                guard let self else { return }
                self.env.route.acceptDetour(cameras: self.env.cameras.cameras)
            },
            secondaryAction: CPAlertAction(title: String(localized: "Остаться"), style: .cancel) { [weak self] _ in
                self?.env.route.declineDetour()
            },
            duration: AppConfig.detourOfferSeconds)
        // Впереди камера — объезд подождёт её и вернётся сам (bannersFreed):
        // до 18.10 он снимал баннер камеры.
        guard banners.show(alert, kind: .detour) else { return }
        detourAlertID = offer.id
        detourAlert = alert
        Log.carplay.notice("объезд: баннер в машине")
    }

    // MARK: - Баннеры: что снято и что вернуть

    /// Экран баннеров освободился — показать ждущих: объезд и вопрос.
    private func bannersFreed() {
        syncDetourAlert()
        presentPendingConfirmIfNeeded()
    }

    /// Система убрала баннер. Снят приложением (вытеснен камерой) — объезд и
    /// вопрос вернутся, когда экран освободится; закрыт водителем или истёк —
    /// нет. Вопрос, закрытый без ответа, — это «Пропустить»: ничего не шлём.
    func mapTemplate(_ mapTemplate: CPMapTemplate, didDismiss navigationAlert: CPNavigationAlert,
                     dismissalContext: CPNavigationAlert.DismissalContext) {
        if dismissalContext == .systemDismissed {
            forgetBanner(navigationAlert)
        } else if navigationAlert === confirmBanner {
            let id = confirmBannerID
            confirmBanner = nil
            confirmBannerID = nil
            // Истёк или закрыт: этот вопрос больше не задаём — иначе onIdle
            // ниже показал бы его снова, пока пропуск ждёт паузу.
            skippedConfirmID = id
            // Кнопка «Да»/«Нет» тоже закрывает баннер, и в каком порядке
            // придут её обработчик и это событие, CarPlay не обещает: пропуск
            // засчитываем с паузой, только если ответа так и не было.
            if let id {
                Task { @MainActor [weak self] in
                    await Task.pause(seconds: AppConfig.carPlayQuestionAnswerGraceSeconds)
                    guard let self, self.env.mobile.pendingConfirm?.id == id else { return }
                    self.env.mobile.answerConfirm(stillThere: nil, for: id)
                }
            }
        }
        banners?.didDismiss(navigationAlert, context: dismissalContext)
    }

    /// Баннер снят приложением или так и не встал (CarPlayBanners.onDropped):
    /// объезд и вопрос забывают, что были показаны, и вернутся, когда экран
    /// освободится.
    private func forgetBanner(_ alert: CPNavigationAlert) {
        if alert === detourAlert {
            detourAlertID = nil
            detourAlert = nil
        }
        if alert === confirmBanner {
            confirmBanner = nil
            confirmBannerID = nil
        }
    }

    /// Ряд полос под манёвром — одной картинкой без текста (CarPlayGuidance.laneRow).
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     displayStyleFor maneuver: CPManeuver) -> CPManeuverDisplayStyle {
        CarPlayGuidance.isLaneRow(maneuver) ? .symbolOnly : []
    }

    // MARK: - Итог поездки

    /// Сохранение, о котором уже сказали (момент сохранения в TripStats).
    private var summarizedSave: Date?

    /// Поездка сохранилась — итог одной строкой, пока машина стоит и экран
    /// наш (CarPlayTripSummary). Подробности — на телефоне.
    private func observeTripSaved() {
        let session = session
        withObservationTracking {
            _ = env.trip.lastSavedAt
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.showTripSummaryIfFresh()
                self.observeTripSaved()
            }
        }
    }

    private func showTripSummaryIfFresh() {
        guard let saved = env.trip.lastSavedAt, saved != summarizedSave,
              Date().timeIntervalSince(saved) < AppConfig.tripEndCardFreshSeconds,
              Self.activeDelegate === self, model.isOnScreen, shownTemplate == nil,
              env.location.speedKmh < AppConfig.carPlayPreviewMaxKmh,
              let record = env.trip.history.first else { return }
        summarizedSave = saved
        Log.carplay.notice("итог поездки в машине")
        showToast(CarPlayTripSummary.lines(for: record)[0], variants: CarPlayTripSummary.lines(for: record))
    }

    // MARK: - «Куда едем?»

    /// Предложение цели уже было в этом подключении — второй раз за одну
    /// посадку в машину не спрашиваем.
    private var offeredDestination = false
    private var offerTask: Task<Void, Never>?

    /// Сев в машину, водитель чаще всего едет туда же, куда всегда: утром из
    /// дома — на работу, вечером — домой (DestinationGuess — та же догадка,
    /// что строка на телефоне). Одно касание вместо «Куда → Работа».
    /// Пауза — на первый точный фикс: догадка смотрит, где мы стоим.
    private func offerDestinationSoon() {
        guard !offeredDestination else { return }
        offerTask?.cancel()
        offerTask = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayDestinationOfferDelay)
            guard let self, !Task.isCancelled else { return }
            self.offerDestinationIfUseful()
        }
    }

    private func offerDestinationIfUseful() {
        guard !offeredDestination, Self.activeDelegate === self, model.isOnScreen,
              shownTemplate == nil, !model.isPreviewing, !env.route.isActive,
              env.location.speedKmh < AppConfig.carPlayPreviewMaxKmh,
              let guess = env.destinationGuess(now: Date()) else { return }
        offeredDestination = true
        let title = guess.kind.suggestionTitle
        let place = SavedPlace(title: guess.placeTitle ?? guess.kind.title,
                               lat: guess.coordinate.latitude, lon: guess.coordinate.longitude)
        let alert = CPNavigationAlert(
            titleVariants: [guess.usualText.map { "\(title) · \($0)" } ?? title, title],
            subtitleVariants: [guess.subtitle],
            image: CarPlayGuidance.symbol(guess.kind.symbol, pointSize: 30,
                                          onDark: model.carIsDark ?? !model.isDaylight),
            primaryAction: CPAlertAction(title: String(localized: "Поехали"), style: .default) { [weak self] _ in
                Log.carplay.notice("«куда едем?»: принято — \(guess.kind.rawValue, privacy: .public)")
                // Цель подтверждена этим касанием — второй экран выбора не нужен:
                // ведём рекомендованным с учётом пробок.
                self?.route(to: place, allowPreview: false)
            },
            secondaryAction: CPAlertAction(title: String(localized: "Не сейчас"), style: .cancel) { _ in
                Log.carplay.notice("«куда едем?»: отказ")
            },
            duration: AppConfig.carPlayDestinationOfferSeconds)
        guard banners?.show(alert, kind: .suggestion) == true else { return }
        Log.carplay.notice("«куда едем?»: предлагаю \(guess.kind.rawValue, privacy: .public)")
    }

    /// Что сейчас показано поверх карты (алерт, сетка, поиск). Своя
    /// запись вместо `interfaceController.presentedTemplate`: то свойство
    /// может синхронно ходить в процесс хоста, а читается оно на пути тревоги
    /// (правило 21). Ведут templateDidAppear/templateDidDisappear.
    private(set) var shownTemplate: CPTemplate?

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if shownTemplate === aTemplate { shownTemplate = nil }
    }

    /// Корневой шаблон уже показывался в этой сессии: сессия навигации и
    /// алерт о разрешении — один раз, а не на каждое возвращение к карте.
    private var rootShown = false
    /// Ответ системы на установку корня: nil — ещё нет, true — установлен,
    /// false — ошибка.
    private var rootSet: Bool?
    /// Корень в этом подключении уже ставили повторно.
    private var rootRetried = false

    /// Навигацию забрала система (другое приложение, встроенный навигатор
    /// машины): сессии больше нет, и свой баннер манёвра обязан вернуться —
    /// иначе до конца маршрута ни манёвра, ни прибытия нигде.
    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        Log.carplay.notice("CarPlay: навигацию отменила система")
        guidance.systemCancelled()
    }

    /// Метаданные манёвра для приборки и проекции на стекло — ВЫКЛЮЧЕНЫ.
    ///
    /// Включили их в 2.2.4, и с тех пор карточка манёвра на экране машины
    /// показывала одно расстояние — без стрелки и текста (CarPlay Simulator,
    /// 11.10, 2.2.5–2.2.7). Руководство CarPlay (июнь 2026) требует для
    /// метаданных тип манёвра, ТИП ПЕРЕКРЁСТКА и сторону движения плюс
    /// состояние манёвра по ходу подъезда — типа перекрёстка и состояния у нас
    /// нет. Навигатор Mapbox метаданные не включает и карточку собирает только
    /// из стрелки, текста и начальной оценки. Вернём, когда будут все поля
    /// и проверка в машине с приборкой.
    /// С 2.2.16 поля есть все (тип перекрёстка, угол съезда, состояние
    /// манёвра — CarPlayGuidanceMapping), но включение — флагом
    /// `carPlayNavigationMetadata`: проверить сначала в CarPlay Simulator на
    /// втором дисплее «приборка» (профиль Widescreen, showsInstruments).
    func mapTemplateShouldProvideNavigationMetadata(_ mapTemplate: CPMapTemplate) -> Bool {
        AppConfig.carPlayNavigationMetadata
    }

    // MARK: - Системные баннеры, когда на экране машины не мы

    /// Манёвр и камера доходят до водителя и поверх музыки или звонка:
    /// ради этого сессия и заведена.
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldShowNotificationFor maneuver: CPManeuver) -> Bool { true }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldUpdateNotificationFor maneuver: CPManeuver,
                     with travelEstimates: CPTravelEstimates) -> Bool { true }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldShowNotificationFor navigationAlert: CPNavigationAlert) -> Bool { true }

    /// Плитка главного экрана вышла на экран: сессии — свежий манёвр и оценки.
    static func refreshGuidance(reason: String) {
        activeDelegate?.guidance.refresh(reason: reason)
    }

    // MARK: - Уход с экрана машины

    /// Наше приложение ушло с экрана машины (водитель открыл другое), но
    /// сцена жива и подключена: камеры поверх чужого приложения — системными
    /// алертами навигационной сессии (guidance.isOnScreen).
    func sceneWillResignActive(_ scene: UIScene) {
        Log.carplay.notice("сцена машины: resign active")
        // Только владелец: события устаревшей сцены не должны гасить буст живой.
        guard Self.activeDelegate === self else { return }
        guidance.isOnScreen = false
        guidance.refresh(reason: "ушли с экрана машины")
    }

    /// На экране машины другое приложение или приборная панель — карту
    /// выгружаем (model.isOnScreen); вернулись — поднимаем заново.
    func sceneDidEnterBackground(_ scene: UIScene) {
        Log.carplay.notice("сцена машины: background, владелец \(Self.activeDelegate === self, privacy: .public)")
        // Своё окно выгружаем всегда — чужая сцена или нет, рисовать в фоне
        // ему нечего. Владелец важен только для глобального состояния.
        model.isOnScreen = false
        // Хост, переживший фон, не пере-используем: при возвращении — новый.
        needsFreshHost = true
        guard Self.activeDelegate === self else { return }
        // В фоне приложение могут приостановить, и сторож записал бы паузу
        // процесса как фриз — счёт только пока экран машины наш.
        HitchWatch.setCounting(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        let appInBackground = UIApplication.shared.applicationState == .background
        Log.carplay.notice("сцена машины: foreground, свежий хост \(self.needsFreshHost || self.host == nil, privacy: .public), приложение в фоне \(appInBackground, privacy: .public)")
        // Окно — заново, ДО первого кадра на экране: дерево, построенное или
        // пересозданное, пока сцена была в фоне, потом не оживало (11.10).
        // Карта в фоне и так выгружена, так что цена — сборка дерева SwiftUI.
        // Приложение ещё в фоне (телефон заблокирован) — карту сейчас не
        // создаём (MapLibre стартовал бы «спящим»): прежнее содержимое
        // снимаем и строим в sceneDidBecomeActive.
        if needsFreshHost || host == nil {
            if appInBackground {
                windowRoot?.setContent(nil)
                host = nil
            } else {
                installHost()
            }
        }
        freezeRepairs = 0
        heartbeatReported = false
        model.isOnScreen = true
        HitchWatch.setCounting(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Log.carplay.notice("сцена машины: active")
        // Стали видимым экраном машины — значит, мы и владелец.
        Self.activeDelegate = self
        guidance.isOnScreen = true
        guidance.refresh(reason: "вернулись на экран машины", driverReturned: true)
        model.isOnScreen = true
        // Бар — заново: что показывает головное устройство после чужого
        // приложения, решаем не мы.
        resendButtons()
        // Окно и хост обязаны быть нашими: при «дрожании» сцены кнопки могли
        // уйти в одно подключение, а экран показывать окно другого. Это та
        // самая улика по застывшему окну 11.10, которой не хватало.
        if let scene = scene as? CPTemplateApplicationScene {
            // Корень окна обязан быть нашим постоянным: подменивший его
            // оставил бы машину показывать чужой слой.
            let ours = windowRoot != nil && scene.carWindow.rootViewController === windowRoot
            Log.carplay.notice("сцена машины: окно наше — \(ours, privacy: .public), хост \(self.host != nil, privacy: .public)")
            if !ours, let windowRoot { scene.carWindow.rootViewController = windowRoot }
            if needsFreshHost || host == nil { installHost() }
        }
        watchRootTemplate()
        presentPendingConfirmIfNeeded()
    }

    /// Проверка «корень действительно на экране машины», когда сцена стала
    /// активной. Решение — CarPlayRootWatch: подтверждённый системой корень
    /// после паузы на анимацию считается показанным, даже если
    /// templateDidAppear не пришёл (журналы 12.10: так бывает, когда машина
    /// подключилась при сцене не на экране). Неподтверждённый — ставим заново
    /// один раз за подключение, и только по таймауту.
    private var templateWatch: Task<Void, Never>?

    private func watchRootTemplate() {
        templateWatch?.cancel()
        guard !rootShown else { return }
        let session = session
        templateWatch = Task { @MainActor [weak self] in
            await Task.pause(seconds: AppConfig.carPlayRootSettleDelay)
            guard let self, !Task.isCancelled, self.session == session, self.model.isOnScreen else { return }
            if self.applyRootWatch(timedOut: false) == .markShown { return }
            await Task.pause(seconds: max(0, AppConfig.carPlayTemplateShowTimeout - AppConfig.carPlayRootSettleDelay))
            guard !Task.isCancelled, self.session == session, self.model.isOnScreen else { return }
            self.applyRootWatch(timedOut: true)
        }
    }

    @discardableResult
    private func applyRootWatch(timedOut: Bool) -> CarPlayRootWatch.Action {
        let action = CarPlayRootWatch.action(rootShown: rootShown, rootSet: rootSet,
                                             retried: rootRetried, timedOut: timedOut)
        switch action {
        case .none:
            break
        case .markShown:
            rootDidShow(via: "сцена активна, установка подтверждена")
        case .setAgain:
            guard let mapTemplate, let interfaceController else { break }
            rootRetried = true
            Log.carplay.fault("корневой шаблон не подтверждён за \(Int(AppConfig.carPlayTemplateShowTimeout), privacy: .public) с — ставлю заново")
            setRoot(mapTemplate, on: interfaceController)
        }
        return action
    }

    /// Установка корня без анимации (анимированная у сцены в фоне теряется).
    /// Подтверждение системы запоминается для CarPlayRootWatch; пришло, пока
    /// сцена на экране, — проверка «показан» запускается сразу.
    private func setRoot(_ template: CPMapTemplate, on interfaceController: CPInterfaceController) {
        rootSet = nil
        let session = session
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, error in
            if let error {
                Log.carplay.error("setRootTemplate: \(error.localizedDescription, privacy: .public)")
            }
            let confirmed = success && error == nil
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.rootSet = confirmed
                if confirmed, self.model.isOnScreen, !self.rootShown { self.watchRootTemplate() }
            }
        }
    }

    // MARK: - Кнопки бара

    /// «Поездка» / «Завершить» — главный тумблер: включает активные оповещения.
    /// Кнопки бара — значками, как у Amap и Google на том же экране: в баре
    /// CarPlay с iOS 26 кнопка — стеклянная капсула, и слово в ней читалось
    /// мельче и дольше значка. Фолбэк — словом (`barButton`), а не пустой
    /// картинкой: невидимая нажимаемая кнопка хуже подписи.
    ///
    /// Значки — голые глифы, без своей подложки: капсулу рисует система, и
    /// ▶ в круге, ромб и пузырь внутри неё читались тяжёлыми чёрными кляксами
    /// разной формы («иконки красиво нужно», владелец, 12.10). И те же, что
    /// на телефоне: ▶ / ■ — «Начать поездку» и «Стоп», ⚠ — «Радар!», динамик —
    /// звук. Один глиф на одно действие на обоих экранах.
    private func barButton(symbol: String, title: String,
                           handler: @escaping (CPBarButton) -> Void) -> CPBarButton {
        if let image = buttonImage(symbol) {
            return CPBarButton(image: image, handler: handler)
        }
        return CPBarButton(title: title, handler: handler)
    }

    private func tripButton(active: Bool) -> CPBarButton {
        barButton(symbol: active ? "stop.fill" : "play.fill",
                  title: active ? String(localized: "Завершить")
                                : String(localized: "Поездка")) { [weak self] _ in
            guard let self else { return }
            let location = env.location
            // Без разрешения startTrip выходит первой строкой и молча ничего
            // не делает: заголовок кнопки остаётся «Поездка», водитель жмёт
            // ещё раз и решает, что приложение сломано. Говорим вслух.
            guard location.isAuthorized else { return self.showNoPermissionAlert() }
            // Второе нажатие сразу после переключения — это «нажалось ли?», а
            // не решение. Журнал 12.10 (carplay12): старт и через 0,6–0,9 с
            // конец «0 м, не сохранена», дважды подряд, — водитель не видел
            // ответа на первое нажатие и жал ещё раз, а стоя второе нажатие
            // завершает без вопроса. Кнопка «не работала».
            if let last = lastTripToggle,
               Date().timeIntervalSince(last) < AppConfig.carPlayTripToggleGuard {
                Log.carplay.notice("поездка: повторное нажатие через \(Date().timeIntervalSince(last), format: .fixed(precision: 1), privacy: .public) с — пропускаю")
                return
            }
            lastTripToggle = Date()
            guard location.isTripActive else {
                location.startTrip()
                // Ответ на нажатие — словами: смена значка в баре доходит до
                // машины не сразу, и одной её мало.
                if location.isTripActive {
                    showToast(String(localized: "Поездка началась — слежу за камерами"), speakIfHidden: true)
                }
                return
            }
            // На ходу — подтверждение: «Завершить» соседствует со звуком, и
            // промах слепого тапа молча выключал бы оповещения о камерах.
            // На стоянке тап осознанный — завершаем сразу, как раньше.
            if location.speedKmh >= AppConfig.carPlayEndTripConfirmKmh {
                confirmEndTrip()
            } else {
                endTripAndRoute()
            }
        }
    }

    /// «Стоп» в машине — конец ведения целиком, как «Завершить» в Apple Maps.
    /// До 12.10 маршрут переживал стоп, и машина продолжала по нему вести —
    /// карточка «Поверните налево», прибытие — под тостом «Поездка
    /// завершена» и кнопкой ▶ («пишет завершена, но не сбрасывается»).
    /// `toast` — ответ словами на слепой тап; после диалога «Завершить?»
    /// ответ уже дан, а второй модальный шаблон вслед закрывающемуся CarPlay
    /// отклоняет.
    private func endTripAndRoute(toast: Bool = true) {
        let hadRoute = env.route.isActive
        env.location.endTrip()   // ручной стоп снимает и маршрут (NavigationFlow)
        Log.carplay.notice("стоп из машины: маршрут \(hadRoute ? "снят" : "не был", privacy: .public)")
        guard toast else { return }
        showToast(hadRoute ? String(localized: "Маршрут завершён")
                           : String(localized: "Поездка завершена"), speakIfHidden: true)
    }

    /// Когда кнопку «Поездка» нажимали в последний раз.
    private var lastTripToggle: Date?

    /// «Завершить поездку?» на ходу. Тот же паттерн, что у Apple Maps: конец
    /// маршрута не висит одним тапом на баре.
    ///
    /// С 19.10 — баннер навигатора, а не окно на весь экран: карта и манёвр
    /// под ним остаются (аудит CarPlay 18.10, P0-3; модальное окно на ходу
    /// Руководство оставляет только ошибкам). Окно — запасной путь, если
    /// баннер сейчас не встанет: на экране баннер камеры, он важнее.
    private func confirmEndTrip() {
        let title = env.route.isActive ? String(localized: "Завершить маршрут?")
                                       : String(localized: "Завершить поездку?")
        if let banners {
            let banner = CPNavigationAlert(
                titleVariants: [title],
                subtitleVariants: [],
                image: nil,
                primaryAction: CPAlertAction(title: String(localized: "Завершить"),
                                             style: .destructive) { [weak self] _ in
                    self?.endTripAndRoute(toast: false)
                },
                secondaryAction: CPAlertAction(title: String(localized: "Продолжить"),
                                               style: .cancel) { _ in },
                duration: AppConfig.carPlayEndConfirmSeconds)
            if banners.show(banner, kind: .request) { return }
        }
        let alert = CPAlertTemplate(
            titleVariants: [title],
            actions: [
                CPAlertAction(title: String(localized: "Завершить"),
                              style: .destructive) { [weak self] _ in
                    self?.dismissTopTemplate()
                    self?.endTripAndRoute(toast: false)
                },
                CPAlertAction(title: String(localized: "Отмена"),
                              style: .cancel) { [weak self] _ in
                    self?.dismissTopTemplate()
                },
            ])
        interfaceController?.presentTemplate(alert, animated: true) { _, error in
            if let error {
                Log.carplay.error("presentTemplate(завершение): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Закрыть верхний модальный шаблон, не глотая ошибку.
    func dismissTopTemplate() {
        interfaceController?.dismissTemplate(animated: true) { _, error in
            if let error {
                Log.carplay.error("dismissTemplate: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Единственная причина, по которой экран машины может быть мёртв целиком.
    /// Настройки iOS с CarPlay не открыть, поэтому честно объясняем, что
    /// сделать на телефоне.
    private func showNoPermissionAlert() {
        showAlert(title: String(localized: "Нет доступа к геопозиции"),
                  message: String(localized: "Откройте RadarMap на телефоне и разрешите доступ «Всегда» — без него я не вижу дорогу и молчу о камерах."))
    }

    /// «Куда» — сетка направлений (с маршрутом — и заезд, и «Завершить
    /// маршрут»). Лупа в обоих состояниях: кнопка на том же месте с тем же
    /// значком находится вслепую; ромб «маршрут» прежде менял её облик
    /// посреди поездки.
    private func destinationsButton(routeActive: Bool) -> CPBarButton {
        barButton(symbol: "magnifyingglass",
                  title: routeActive ? String(localized: "Маршрут")
                                     : String(localized: "Куда")) { [weak self] _ in
            self?.presentDestinations()
        }
    }

    /// Отметить засаду прямо на ходу — иконкой, чтобы бар не распухал.
    ///
    /// Треугольник, как у жёлтой «Радар!» на телефоне и у команды Siri:
    /// водитель учит один значок, а не два. Речевой пузырь (до 12.10) был
    /// единственным местом с другим глифом — и читался как «сообщения».
    ///
    /// Фолбэк — заголовком, а не пустой картинкой: `?? UIImage()` давал бы
    /// нажимаемую кнопку-невидимку в баре.
    private var reportButton: CPBarButton {
        guard let image = buttonImage("exclamationmark.triangle.fill") else {
            return CPBarButton(title: String(localized: "Радар")) { [weak self] _ in
                self?.presentReport()
            }
        }
        return CPBarButton(image: image) { [weak self] _ in
            self?.presentReport()
        }
    }

    // MARK: - Кнопки карты

    /// «К себе». Значок показывает СОСТОЯНИЕ, а не только действие: залитый —
    /// карта едет за машиной, контурный — водитель отпанорамировал в сторону и
    /// карта стоит. Раньше значок был один на оба случая, и единственный способ
    /// понять, следит ли карта, был подождать и посмотреть, уехала ли метка.
    private var recenterButton: CPMapButton {
        let button = CPMapButton { [model] _ in model.recenter() }
        button.image = buttonImage(model.isFollowing ? "location.fill" : "location")
        return button
    }

    /// Вход в осмотр карты. Обязателен: на машинах без сенсора крутилкой
    /// панорамируют только из осмотра. Выход — «Готово» в баре (так требует
    /// CarPlay: своей кнопки выхода система не рисует). Значок — стрелки в
    /// четыре стороны, как у Apple Maps в машине: «рука» читалась как
    /// «рисовать».
    private var panButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in
            guard let self, let mapTemplate else { return }
            // Бар «Готово» — ДО входа: если отправка после DidShow потеряется,
            // из осмотра будет не выйти.
            if !isPanning {
                isPanning = true
                syncTemplate()
            }
            mapTemplate.showPanningInterface(animated: true)
            // Таймер бездействия — с открытия: осмотр, в котором ничего не
            // тронули, тоже закроется сам.
            model.panningShown()
        }
        button.image = buttonImage("arrow.up.and.down.and.arrow.left.and.right")
        return button
    }

    /// «Готово» — выход из осмотра, единственная кнопка бара на это время.
    private var panDoneButton: CPBarButton {
        CPBarButton(title: String(localized: "Готово")) { [weak self] _ in
            self?.leavePanning(reason: "Готово")
        }
    }

    private var zoomInButton: CPMapButton {
        let button = CPMapButton { [model] _ in
            model.zoom(in: true)
        }
        button.image = buttonImage("plus")
        return button
    }

    private var zoomOutButton: CPMapButton {
        let button = CPMapButton { [model] _ in
            model.zoom(in: false)
        }
        button.image = buttonImage("minus")
        return button
    }

    /// Тумблер тишины: заглушить оповещения, не доставая телефон (спит пассажир,
    /// идёт разговор). Значок показывает текущее состояние, а HUD пишет
    /// «Без звука» (CarPlayStatusChips) — в баре звук стоит рядом с
    /// «Поездкой», и промах слепого тапа не должен глушить камеры незаметно.
    private func soundButton(muted: Bool) -> CPBarButton {
        barButton(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                  title: muted ? String(localized: "Без звука")
                               : String(localized: "Звук")) { [weak self] _ in
            self?.toggleMute()   // наблюдение пересоберёт кнопку
        }
    }

    /// Тишина — это молчат и писк, и голос: водитель, нажавший «динамик», ждёт
    /// тишины, а не «звук выключил, а голос остался».
    ///
    /// Читает ТОЛЬКО @Observable-настройки: isMuted стоит внутри
    /// withObservationTracking, и чтение Storage здесь оставило бы кнопку
    /// без перерисовки после нажатия.
    private var isMuted: Bool {
        !env.settings.soundEnabled && env.settings.voiceMode == .off
    }

    private func toggleMute() {
        if isMuted {
            unmute()
        } else {
            // «До тишины» — в Storage, а не в полях делегата: при
            // переподключении делегат создаётся заново, и поля-умолчания
            // «включали в подарок» звук и голос тем, кто выключил их намеренно.
            // Хранится сам rawValue VoiceMode: восстановление через фасад
            // voiceEnabled превращало «Обо всех» в «Умно».
            Storage.set(env.settings.soundEnabled, for: .carPlaySoundBeforeMute)
            Storage.set(env.settings.voiceMode.rawValue, for: .carPlayVoiceBeforeMute)
            Storage.set(true, for: .carPlayMuted)
            env.settings.soundEnabled = false
            env.settings.voiceMode = .off
        }
    }

    /// Возвращаем ровно то, что было до заглушения. Если тишину включили не
    /// кнопкой машины (всё выключено руками в настройках), «размучивание» —
    /// осознанное желание слышать: включаем разумный минимум.
    ///
    /// Восстановление слепым быть не может. Пока водитель ехал молча, он мог
    /// на светофоре взять телефон и поменять настройки сам — например выбрать
    /// профиль, который ставит свой `voiceMode`. Вернуть тогда «как было до
    /// кнопки» значит затереть его же осознанный выбор более поздним
    /// прошлым. Поэтому откатываем только то, что с тех пор никто не трогал:
    /// поле восстанавливается, лишь если оно и сейчас в том состоянии, в
    /// которое его поставила кнопка машины (звук выключен, голос молчит).
    private func unmute() {
        defer { Storage.set(false, for: .carPlayMuted) }
        guard Storage.bool(.carPlayMuted) else {
            env.settings.soundEnabled = true
            env.settings.voiceMode = .smart
            return
        }
        if env.settings.soundEnabled == false {
            env.settings.soundEnabled = Storage.bool(.carPlaySoundBeforeMute)
        }
        if env.settings.voiceMode == .off {
            env.settings.voiceMode = Storage.string(.carPlayVoiceBeforeMute)
                .flatMap(VoiceMode.init(rawValue:)) ?? .smart
        }
    }

    /// Значок кнопки машины. 24 пункта, а не 20: систему кнопок рисует
    /// CarPlay, и круг под значком крупный — двадцатка сидела в нём мелкой
    /// точкой. Плитки сетки рядом идут на 36, так что 24 — это середина шкалы,
    /// а не выдуманное число.
    private func buttonImage(_ symbol: String) -> UIImage? {
        UIImage(systemName: symbol,
                withConfiguration: carConfiguration(pointSize: 24, weight: .semibold))
    }

    /// Иконка плитки сетки: шаблонное изображение — CarPlay сам красит его под
    /// тему машины (днём тёмным по светлому, ночью наоборот).
    /// Значок плитки сетки — не больше `CPGridTemplate.maximumGridButtonImageSize`
    /// (40×40). Символ в 36 pt выходил 52×44 (проверено пробой, 12.10), и
    /// машина ужимала или обрезала его сама. Кегль подбирается по
    /// фактическому размеру: у разных символов разные пропорции.
    private func gridImage(_ symbol: String) -> UIImage {
        let limit: CGSize
        if #available(iOS 26.0, *) {
            limit = CPGridTemplate.maximumGridButtonImageSize
        } else {
            limit = CGSize(width: AppConfig.carPlayGridImageMaxPoints, height: AppConfig.carPlayGridImageMaxPoints)
        }
        var pointSize: CGFloat = 36
        var image = UIImage(systemName: symbol,
                            withConfiguration: carConfiguration(pointSize: pointSize, weight: .semibold))
        if let size = image?.size, size.width > limit.width || size.height > limit.height,
           size.width > 0, size.height > 0 {
            pointSize *= min(limit.width / size.width, limit.height / size.height) * 0.98
            image = UIImage(systemName: symbol,
                            withConfiguration: carConfiguration(pointSize: pointSize, weight: .semibold))
        }
        return (image ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }

    /// Конфигурация значка с трейтами ЭКРАНА МАШИНЫ. Без них картинка несёт
    /// масштаб телефона: на головном устройстве с другим display scale растр
    /// пережимается уже там и приезжает не того размера и мыльным. Apple для
    /// изображений CarPlay прямо велит carTraitCollection.
    private func carConfiguration(pointSize: CGFloat,
                                  weight: UIImage.SymbolWeight) -> UIImage.SymbolConfiguration {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let traits = interfaceController?.carTraitCollection else { return config }
        return config.applying(UIImage.SymbolConfiguration(traitCollection: traits))
    }

    // MARK: - Ограничения на ходу

    /// Машина тронулась или остановилась: клавиатура пропала или вернулась.
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        let limited = limitedUserInterfaces.contains(.keyboard)
        guard limited != keyboardLimited else { return }
        keyboardLimited = limited
        Log.carplay.notice("клавиатура в машине: \(limited ? "недоступна" : "доступна", privacy: .public)")
        destinationsGrid?.updateGridButtons(destinationButtons())
    }

    // MARK: - «Куда»: горячие плитки

    /// Дом, Работа и недавние — маршрут в один тап. Сетка ограничена восемью
    /// плитками, поэтому недавние добираем тем, что осталось.
    private func presentDestinations() {
        // Заголовок совпадает с кнопкой, которой сюда пришли: тап «Маршрут»,
        // открывший экран «Куда», читался как промах.
        let grid = CPGridTemplate(title: env.route.isActive ? String(localized: "Маршрут")
                                                            : String(localized: "Куда"),
                                  gridButtons: destinationButtons())
        destinationsGrid = grid
        interfaceController?.pushTemplate(grid, animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(куда): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func destinationButtons() -> [CPGridButton] {
        var buttons: [CPGridButton] = []

        // Активный маршрут: первым делом даём его сбросить — это самая частая
        // причина зайти сюда во время движения.
        if env.route.isActive {
            buttons.append(gridButton(symbol: "xmark.circle.fill",
                                      titles: [String(localized: "Отменить маршрут"),
                                               String(localized: "Стоп")]) { [weak self] in
                guard let self else { return }
                env.route.clear()
                popToMap()
            })
        }

        for slot in PlaceSlot.allCases {
            buttons.append(placeButton(slot: slot))
        }

        // Поиск — третьей плиткой, сразу за Домом и Работой: адрес, которого
        // нет в недавних, раньше можно было задать только на телефоне. На
        // ходу клавиатура в машине недоступна, и экран поиска был бы пустым
        // обещанием (аудит 18.10, п. 3): плитка стоит на своём месте, но
        // выключена и говорит, когда заработает.
        let search = gridButton(symbol: "magnifyingglass",
                                titles: keyboardLimited
                                    ? [String(localized: "Поиск на стоянке"), String(localized: "Поиск")]
                                    : [String(localized: "Поиск")]) { [weak self] in
            self?.presentSearch()
        }
        search.isEnabled = !keyboardLimited
        buttons.append(search)
        // АЗС или зарядка — частый вопрос в дороге, и ответ на него — одна
        // плитка. Какая — по машине (Настройки → Поездка → «Машина»): у
        // электромобиля «Зарядка» вместо «АЗС», у гибрида обе.
        for kind in env.settings.vehicleEnergy.stops {
            buttons.append(gridButton(symbol: kind.symbol, titles: [kind.title]) { [weak self] in
                self?.presentNearest(kind)
            })
        }

        // Дом и Работа уже стоят своими плитками выше — в «недавних» они
        // дублируются и съедают места из восьми, которые есть у сетки.
        // Сравниваем по координате, а не по названию: одно и то же место
        // может называться по-разному.
        let pinned = PlaceSlot.allCases.compactMap { env.settings.place(for: $0)?.coordinate }
        let recent = env.settings.recentPlaces.filter { place in
            !pinned.contains { GeoMath.fastDistance($0.latitude, $0.longitude,
                                                    place.coordinate.latitude,
                                                    place.coordinate.longitude)
                < AppConfig.carPlayRecentDuplicateMeters }
        }
        for place in recent.prefix(max(0, AppConfig.carPlayGridLimit - buttons.count)) {
            buttons.append(gridButton(symbol: "clock.arrow.circlepath",
                                      titles: [place.title, Self.shortTitle(place.title)]) { [weak self] in
                self?.route(to: place)
            })
        }

        return buttons
    }

    /// Ближайшие заведения вида списком: тап — маршрут.
    /// Действия водителя, которые ждут сеть или поиск. ПОВТОР того же
    /// касания в эти секунды — «не сработало?», а не новое намерение: без
    /// этого он открывал второй список или строил маршрут дважды (аудит
    /// CarPlay 19.10). Другое касание (передумал: «АЗС» → «Дом») проходит.
    private var actionsInFlight: Set<String> = []

    private func presentNearest(_ kind: Venue.Kind) {
        let key = "nearest:\(kind.rawValue)"
        guard actionsInFlight.insert(key).inserted else {
            return Log.carplay.notice("повторное касание — список уже ищется")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.actionsInFlight.remove(key) }
            let found = await search.nearest(kind)
            guard !found.isEmpty else {
                return showAlert(title: String(format: String(localized: "%@ рядом не нашлось"), kind.title),
                                 message: String(localized: "Без сети ищу только по своей карте."))
            }
            let items = found.map { place, detail, alongRoute -> CPListItem in
                let item = CPListItem(text: place.title, detailText: detail)
                item.handler = { [weak self] _, completion in
                    // Найдено впереди по маршруту — заезд, цель остаётся.
                    if alongRoute { self?.addStop(place) } else { self?.route(to: place) }
                    completion()
                }
                return item
            }
            let list = CPListTemplate(title: kind.title, sections: [CPListSection(items: items)])
            interfaceController?.pushTemplate(list, animated: true) { _, error in
                if let error {
                    Log.carplay.error("pushTemplate(\(kind.title, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Полный список найденного по «Найти» на клавиатуре — поверх поиска.
    private func pushSearchResults(_ template: CPTemplate) {
        interfaceController?.pushTemplate(template, animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(результаты поиска): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Поиск для слота Дом/Работа: выбранное место сохраняется в слот и к
    /// нему сразу строится маршрут. Делегат шаблона поиска слабый — держим
    /// объект, пока шаблон на экране.
    private var assignSearch: CarPlaySearch?

    func presentAssign(_ slot: PlaceSlot) {
        guard !keyboardLimited else {
            return showAlert(title: String(format: String(localized: "«%@» — на стоянке"), slot.name),
                             message: String(localized: "Поиск адреса на ходу недоступен — задайте место, когда машина остановится."))
        }
        let search = CarPlaySearch { [weak self] place in
            guard let self else { return }
            env.settings.setPlace(place, for: slot)
            assignSearch = nil
            route(to: place)
        }
        search.present = { [weak self] template in self?.pushSearchResults(template) }
        assignSearch = search
        interfaceController?.pushTemplate(search.makeTemplate(), animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(поиск для слота): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Вход с приборной панели: касание её кнопки запускает основную сцену
    /// CarPlay, но обработчик кнопки приходит раньше, чем сцена подключилась.
    /// Ждём её коротко и открываем поиск для слота.
    static func presentAssignWhenReady(_ slot: PlaceSlot) {
        Task { @MainActor in
            for _ in 0..<AppConfig.carPlaySceneWaitAttempts {
                if let delegate = activeDelegate, delegate.interfaceController != nil {
                    delegate.presentAssign(slot)
                    return
                }
                await Task.pause(seconds: AppConfig.carPlaySceneWaitStep)
            }
            Log.carplay.notice("слот \(slot.rawValue, privacy: .public): основная сцена не подключилась вовремя")
        }
    }

    private func presentSearch() {
        interfaceController?.pushTemplate(search.makeTemplate(), animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(поиск): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Плитка Дом/Работа. Место не задано — плитку всё равно показываем: она
    /// всегда на одном месте (мышечная память), а тап задаёт место поиском.
    private func placeButton(slot: PlaceSlot) -> CPGridButton {
        let place = env.settings.place(for: slot)
        let titles = place.map { [ "\(slot.name) · \($0.title)", slot.name ] } ?? [slot.name]
        return gridButton(symbol: slot.symbol, titles: titles) { [weak self] in
            guard let self else { return }
            // Не задано — задаём здесь же поиском, как с плитки главного
            // экрана: сценарий в машине обязан проходить без телефона
            // (Руководство CarPlay, стр. 5; аудит 18.10, п. 8).
            guard let place else { return presentAssign(slot) }
            route(to: place)
        }
    }

    private func gridButton(symbol: String, titles: [String],
                            action: @escaping () -> Void) -> CPGridButton {
        CPGridButton(titleVariants: titles, image: gridImage(symbol)) { _ in action() }
    }

    /// Длинный адрес в плитку не влезает — короткий вариант для узких экранов.
    private static func shortTitle(_ title: String) -> String {
        let head = title.split(separator: ",").first.map(String.init) ?? title
        let limit = AppConfig.carPlayTileTitleLimit
        return head.count > limit ? String(head.prefix(limit - 1)) + "…" : head
    }

    /// Строим маршрут и сразу едем: за рулём выбирать из альтернатив некогда.
    private func route(to place: SavedPlace, allowPreview: Bool = true) {
        let key = "route:\(place.lat),\(place.lon)"
        guard actionsInFlight.insert(key).inserted else {
            return Log.carplay.notice("повторное касание — маршрут уже строится")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.actionsInFlight.remove(key) }
            // Грубая точка фонового режима сюда не годится: маршрут от неё
            // начинается за километры (plan_drive_complaints.md, Ж5).
            guard let from = await env.location.awaitPreciseCoordinate() else {
                showAlert(title: String(localized: "Ждём спутники"),
                          message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
                return
            }
            popToMap()
            // Выбор маршрута — только стоя (CarPlayTripPreview): на ходу
            // ведём рекомендованным, как раньше. Флаг — ДО построения: иначе
            // сессия навигации стартовала бы на первом варианте раньше выбора.
            let preview = allowPreview && CarPlayTripPreview.shouldPreview(speedKmh: env.location.speedKmh)
            if previewTrip != nil { mapTemplate?.hideTripPreviews() }
            previewTrip = nil
            model.isPreviewing = preview
            await env.route.build(from: from, to: place.coordinate,
                                  name: place.title, cameras: env.cameras.cameras,
                                  alternatives: preview)
            env.settings.addRecent(title: place.title, lat: place.lat, lon: place.lon)
            if preview, env.route.isActive, env.route.errorMessage == nil {
                showPreview(name: place.title, destination: place.coordinate)
                return
            }
            if preview { endPreview(start: false, keepRoute: true, reason: "маршрут не построен") }
            // Едем уже с активной поездкой — не обнулять её накат.
            if !env.location.isTripActive { env.location.startTrip() }
            if let error = env.route.errorMessage {
                showAlert(title: String(localized: "Маршрут не построен"), message: error)
            }
        }
    }

    // MARK: - Выбор маршрута

    /// Поездка на экране выбора (CPTrip с вариантами). Держим, чтобы
    /// обновлять оценки и закрыть выбор.
    private var previewTrip: CPTrip?
    /// Тронулись, пока выбор на экране, — выбор принят.
    private var previewWatch: Task<Void, Never>?

    /// Варианты с нашими метками и временем с пробками; рекомендованный —
    /// первым и выбранным. Линия — целиком на экране.
    private func showPreview(name: String, destination: CLLocationCoordinate2D) {
        guard let mapTemplate else {
            return endPreview(start: true, keepRoute: true, reason: "шаблона нет")
        }
        let route = env.route
        let variants = route.variants
        let ordered = variants.filter { $0.id == route.selectedID } + variants.filter { $0.id != route.selectedID }
        let choices = ordered.map { variant -> CPRouteChoice in
            let text = CarPlayTripPreview.text(for: variant, among: variants)
            let choice = CPRouteChoice(summaryVariants: text.summary,
                                       additionalInformationVariants: text.additional,
                                       selectionSummaryVariants: text.selection)
            choice.userInfo = variant.id
            return choice
        }
        let origin = MKMapItem(placemark: MKPlacemark(coordinate: env.location.currentCoordinate ?? destination))
        let target = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        target.name = name
        let trip = CPTrip(origin: origin, destination: target, routeChoices: choices)
        if previewTrip != nil { mapTemplate.hideTripPreviews() }
        previewTrip = trip
        previewDestination = destination
        let text = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "Поехали"),
                                                  additionalRoutesButtonTitle: String(localized: "Варианты"),
                                                  overviewButtonTitle: String(localized: "Обзор"))
        mapTemplate.showTripPreviews([trip], selectedTrip: trip, textConfiguration: text)
        updatePreviewEstimates(route.selected)
        model.showOverview()
        Log.carplay.notice("выбор маршрута: вариантов \(variants.count, privacy: .public)")
        watchMovingOff()
    }

    private func updatePreviewEstimates(_ variant: RouteService.Variant?) {
        guard let trip = previewTrip, let variant, let mapTemplate else { return }
        let estimates = CarPlayGuidance.estimates(meters: variant.distance, seconds: variant.expectedTime)
        let color: CPTimeRemainingColor = switch CarPlayTripPreview.timeColor(trafficDelay: variant.trafficDelay) {
        case .standard: .default
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
        mapTemplate.update(estimates, for: trip, with: color)
    }

    /// Водитель отметил другой вариант: линия на карте — его, оценки — его.
    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip,
                     using routeChoice: CPRouteChoice) {
        guard trip === previewTrip, let id = routeChoice.userInfo as? Int else { return }
        env.route.selectVariant(id)
        updatePreviewEstimates(env.route.selected)
        model.showOverview()
    }

    /// «Поехали».
    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip,
                     using routeChoice: CPRouteChoice) {
        if let id = routeChoice.userInfo as? Int { env.route.selectVariant(id) }
        endPreview(start: true, keepRoute: true, reason: "Поехали")
    }

    /// Закрыть выбор. `keepRoute` — ехать выбранным; нет — маршрут снят
    /// («Отмена»). Сессия навигации начнётся сама, как только выбор закрыт.
    private func endPreview(start: Bool, keepRoute: Bool, reason: String) {
        previewWatch?.cancel()
        previewWatch = nil
        if previewTrip != nil { mapTemplate?.hideTripPreviews() }
        previewTrip = nil
        previewDestination = nil
        guard model.isPreviewing else { return }
        if !keepRoute { env.route.clear() }
        model.isPreviewing = false
        model.recenter()
        if start, !env.location.isTripActive { env.location.startTrip() }
        Log.carplay.notice("выбор маршрута закрыт: \(reason, privacy: .public)")
    }

    private func watchMovingOff() {
        previewWatch?.cancel()
        previewWatch = Task { @MainActor [weak self] in
            var watch = CarPlayTripPreview.MovingWatch()
            while !Task.isCancelled {
                guard let self, self.model.isPreviewing else { return }
                if watch.update(speedKmh: self.env.location.speedKmh, at: Date()) {
                    self.endPreview(start: true, keepRoute: true, reason: "тронулись — едем выбранным")
                    return
                }
                await Task.pause(seconds: 1)
            }
        }
    }

    /// «Отмена» в баре на время выбора — единственная кнопка: выбор закрыт,
    /// маршрут снят, карта снова за машиной.
    private var cancelPreviewButton: CPBarButton {
        CPBarButton(title: String(localized: "Отмена")) { [weak self] _ in
            self?.endPreview(start: false, keepRoute: false, reason: "Отмена")
        }
    }

    /// Заезд по пути: маршрут к той же цели через `place`. Не вышло — прежний
    /// маршрут остаётся, и машина говорит почему.
    private func addStop(_ place: SavedPlace) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let from = await env.location.awaitPreciseCoordinate() else {
                showAlert(title: String(localized: "Ждём спутники"),
                          message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
                return
            }
            popToMap()
            await env.route.addStop(place.coordinate, name: place.title,
                                    from: from, cameras: env.cameras.cameras)
            if let error = env.route.errorMessage {
                showAlert(title: String(localized: "Не удалось заехать по пути"), message: error)
            }
        }
    }

    // MARK: - Отметка засады из машины

    /// Радар, тренога, ДТП — крупные плитки, один тап и обратно на карту.
    /// Координата берётся текущая, ничего уточнять не нужно. Набор типов —
    /// общий с телефоном (`ReportKind.offered`), чтобы из машины нельзя было
    /// поставить то, чего нет на экране.
    private func presentReport() {
        let buttons = ReportKind.offered.map { kind in
            gridButton(symbol: kind.symbol, titles: [kind.title]) { [weak self] in
                self?.submitReport(kind)
            }
        }
        let grid = CPGridTemplate(title: String(localized: "Что впереди?"), gridButtons: buttons)
        interfaceController?.pushTemplate(grid, animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(отметка): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Отметка засады из машины.
    ///
    /// Идёт тем же путём, что тап на телефоне (`quickReport`), а не прямым
    /// `report(at:)`. Разница не косметическая: прямой вызов проходил мимо
    /// `ReportGuard` — не работала защита от повтора (не понял, нажалось ли, —
    /// поставил вторую точку рядом), отметка не попадала в дневную статистику,
    /// и главное: при отсутствии сети она УЖЕ ложилась в очередь и уходила
    /// позже, а водителю говорили «не отправилось». Врать про потерю того,
    /// что не потеряно, — худший из ответов.
    private func submitReport(_ kind: ReportKind) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await env.mobile.quickReport(
                kind: kind,
                coordinate: env.location.currentCoordinate,
                speedKmh: env.location.speedKmh,
                isTripActive: env.location.isTripActive,
                course: env.location.currentCourse)
            // Фраза одна и та же, что звучит голосом на телефоне: экран машины
            // и голос не имеют права расходиться в оценке того, что случилось.
            // Тост — после возврата к карте: поверх летящего pop CarPlay
            // диалог отклонял, и подтверждения водитель не видел.
            // И голосом, как на телефоне (ReportRadarButton): пока впереди
            // камера, баннер ответа уступает ей, а ответ на тап обязан дойти.
            env.alerts.speak(outcome.spoken)
            popToMap { [weak self] in self?.showToast(outcome.spoken) }
        }
    }
}
