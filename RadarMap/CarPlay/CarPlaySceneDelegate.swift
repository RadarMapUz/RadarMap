//
//  CarPlaySceneDelegate.swift
//  RadarMap
//
//  Вход CarPlay (категория Navigation): собственное окно карты + шаблоны
//  управления. Окружение общее с телефоном — камеры, маршрут, поездка живут
//  в одном экземпляре AppEnvironment.
//
//  Раскладка управления рассчитана на слепой тап за рулём:
//  • бар — «Поездка/Завершить» и звук слева, «Куда» и «Радар!» (словом)
//    справа;
//  • кнопки карты — зум, осмотр, «к себе»; в поездке первой — крупная
//    «Радар!», а осмотр и «к себе» делят одно место (CarPlayMapButtons);
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

    // Тип разрезан на расширения по файлам (CarPlaySceneDelegate+*.swift,
    // план 3.2): состояние, которое пишут расширения, без private — у Swift
    // нет «приватного для типа» доступа через границу файла. Писать его можно
    // ТОЛЬКО из CarPlaySceneDelegate*.swift (ревью).

    var interfaceController: CPInterfaceController?
    /// Баннеры поверх карты — одна очередь на подключение (CarPlayBanners):
    /// камера, объезд, вопрос, подтверждения.
    var banners: CarPlayBanners?
    /// Показанный вопрос «ещё на месте?» и его отметка — чтобы снять его,
    /// когда ответ уже не нужен (CarPlayAlerts.presentPendingConfirmIfNeeded).
    var confirmBanner: CPNavigationAlert?
    var confirmBannerID: Int?
    /// Погода на перевале впереди (19.2) — свой баннер в общей очереди.
    let roadWeatherBanner = CarPlayRoadWeatherBanner()
    /// Вопрос, который истёк или закрыт без ответа: это «Пропустить», и
    /// второй раз о той же отметке не спрашиваем.
    var skippedConfirmID: Int?
    /// Вопрос ждёт остановки: скорость — не наблюдаемое событие, проверяем
    /// изредка, пока вопрос висит (CarPlayAlerts.waitToAsk).
    var confirmWatch: Task<Void, Never>?
    /// Начало сессии экрана машины — для суточной статистики (минуты).
    var connectedAt: Date?
    /// Что машина запрещает на ходу (клавиатура, длинные списки) — держим,
    /// пока подключены: без ссылки делегат не получит ни одного изменения.
    var sessionConfiguration: CPSessionConfiguration?
    /// Клавиатура сейчас недоступна (на ходу в большинстве машин). Поиск по
    /// адресу тогда — только на стоянке (Руководство CarPlay, стр. 25, 51).
    var keyboardLimited = false
    /// Показанная сетка «Куда» — её плитку «Поиск» переключаем, когда машина
    /// остановилась или тронулась.
    weak var destinationsGrid: CPGridTemplate?
    var mapTemplate: CPMapTemplate?
    /// Постоянный корень окна машины на всё подключение (CarPlayWindowRoot):
    /// хост CarPlay показывает слой именно этого корня, и подменять его нельзя.
    var windowRoot: CarPlayWindowRoot?
    /// Хост SwiftUI внутри корня — его и пересоздаём, не трогая корень.
    weak var host: UIHostingController<AnyView>?
    /// Сигналы шаблона карте; тема машины нужна и баннерам (CarPlayAlerts).
    let model = CarPlayMapModel()
    /// Навигационная сессия CarPlay: манёвр, время в пути, полосы, камеры
    /// поверх чужого приложения.
    lazy var guidance = CarPlayGuidance(model: model)
    /// Панель «…» плашки прибытия (iOS 27, 25.H1): камеры впереди, звук,
    /// «Завершить маршрут».
    lazy var optionsPanel: CarPlayOptionsPanel = {
        let panel = CarPlayOptionsPanel()
        panel.onToggleSound = { [weak self] in self?.toggleSoundFromPanel() }
        panel.onEndRoute = { [weak self] in
            guard let self, env.route.isActive else { return }
            env.route.clear()
        }
        return panel
    }()
    /// Поиск адреса в машине: тот же порядок источников, что на телефоне.
    lazy var search: CarPlaySearch = {
        let search = CarPlaySearch { [weak self] place in self?.pickFromSearch(place) }
        search.present = { [weak self] template in self?.pushSearchResults(template) }
        return search
    }()
    /// Чей сейчас экран машины. Переподключение (штатное «моргание» провода
    /// при запуске двигателя) может доставить didDisconnect СТАРОЙ сцены уже
    /// ПОСЛЕ didConnect новой — и старая, уходя, глобально гасила GPS и опрос
    /// отметок у живой. Глобальное состояние трогает только владелец.
    static weak var activeDelegate: CarPlaySceneDelegate?
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
        guidanceAttached = false
        guidanceAttachedInBackground = false
        guidingAtConnect = NavigationFlow.phase(hasRoute: env.route.isActive,
                                                isTripActive: env.location.isTripActive) == .guiding
        // Камеры поверх чужого приложения — системными алертами, пока сцена
        // не на экране машины.
        guidance.isOnScreen = shown

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
        observeRoadWeather()
        observeTripSaved()
        startFreezeWatch(scene: scene)
        Log.carplay.notice("CarPlay подключён, сцена \(Self.stateName(scene), privacy: .public), метаданные приборки \(self.env.settings.carPlayNavigationMetadata ? "вкл" : "выкл", privacy: .public)")
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
        optionsPanel.reset()
        guidanceAttached = false
        guidanceAttachedInBackground = false
        session += 1   // гасим подписки syncTemplate этой сессии
        banners?.reset()
        banners = nil
        confirmWatch?.cancel()
        confirmWatch = nil
        confirmBanner = nil
        confirmBannerID = nil
        detourAlert = nil
        detourAlertID = nil
        roadWeatherBanner.reset()
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
        // Звук, выбранный в машине, — атрибут ПОЕЗДКИ (restoreCarSound).
        restoreCarSound()
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
    var freezeWatch: Task<Void, Never>?
    var freezeRepairs = 0
    var heartbeatReported = false

    /// Хост окна нужно построить заново при следующем выходе на экран: сцена
    /// подключилась в фоне или побывала в фоне.
    var needsFreshHost = false

    // MARK: - Сборка шаблона

    /// Поколение подписки syncTemplate: живой остаётся только ПОСЛЕДНЯЯ.
    /// Каждый вызов регистрирует новую одноразовую подписку, и без поколения
    /// каждая внеочередная пересборка (когда-то — тап «Схема/Карта», теперь —
    /// возврат на экран, конец осмотра) добавляла по вечно перевзводящейся:
    /// после N таких любое изменение состояния пересобирало шаблон N раз подряд.
    var syncGeneration = 0

    /// Что сейчас отправлено в магнитолу. Кнопки — не память, а сообщения на
    /// головное устройство: каждое присваивание заменяет их там целиком, и
    /// тап, пришедшийся на замену, теряется. Наблюдение будит пересборку на
    /// любое касание отслеживаемого (а MapKit дёргал слежение на каждом «+»),
    /// поэтому отправляем только реально изменившееся.
    var sentBar: [Bool]?
    /// Звук, с которым собран бар (10.1): значок кнопки — нынешний выбор.
    var sentSound: CarPlaySoundChoice?
    var sentMapButtons: [CarPlayMapButtons.Kind]?

    /// Открыт ли сейчас осмотр карты: бар на это время — одна кнопка «Готово».
    var isPanning = false

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
    var panSum = CGPoint.zero

    var panUpdates = 0

    var panHoldTask: Task<Void, Never>?

    /// Щипок на сенсорном экране (iOS 26): масштаб — командой карте.
    ///
    /// SDK: «scale factor relative to the zoom gesture» — то есть от НАЧАЛА
    /// жеста, как у UIPinchGestureRecognizer. Карте нужен множитель шага,
    /// поэтому делим на прошлое значение. До 2.2.16 значение умножалось как
    /// есть каждый кадр и не сбрасывалось между жестами — накопленный масштаб
    /// разгонял бы карту, а остаток прошлого жеста переходил в следующий.
    /// Журнал пишет первые значения: с перетаскиванием документация уже
    /// оказалась неточной (там приходит шаг, а не путь от начала).
    var pinchLast: CGFloat = 1
    var pinchUpdates = 0

    var panningFallback: Task<Void, Never>?

    /// Ведение (сессия, баннеры камер, плитка приборки) подключено в этом
    /// подключении; в фоне — до первого показа корня.
    var guidanceAttached = false
    var guidanceAttachedInBackground = false
    /// При подключении уже шло ведение по нашему маршруту.
    var guidingAtConnect = false

    // MARK: - Фаза маршрута

    /// Фаза при прошлом решении о выборе (NavigationFlow); nil — с
    /// подключения решений не было.
    var flowPhase: NavigationFlow.Phase?
    /// Цель, выбор к которой на экране: маршрут заменили на телефоне —
    /// выбор показывает новый.
    var previewDestination: CLLocationCoordinate2D?

    // MARK: - Объезд пробки

    /// Предложение объезда, показанное баннером в машине (id из RouteService).
    var detourAlertID: Int?
    var detourAlert: CPNavigationAlert?

    // MARK: - Итог поездки

    /// Сохранение, о котором уже сказали (момент сохранения в TripStats).
    var summarizedSave: Date?

    // MARK: - «Куда едем?»

    /// Предложение цели уже было в этом подключении — второй раз за одну
    /// посадку в машину не спрашиваем.
    var offeredDestination = false
    var offerTask: Task<Void, Never>?

    /// Что сейчас показано поверх карты (алерт, сетка, поиск). Своя
    /// запись вместо `interfaceController.presentedTemplate`: то свойство
    /// может синхронно ходить в процесс хоста, а читается оно на пути тревоги
    /// (правило 21). Ведут templateDidAppear/templateDidDisappear.
    var shownTemplate: CPTemplate?

    /// Корневой шаблон уже показывался в этой сессии: сессия навигации и
    /// алерт о разрешении — один раз, а не на каждое возвращение к карте.
    var rootShown = false
    /// Ответ системы на установку корня: nil — ещё нет, true — установлен,
    /// false — ошибка.
    var rootSet: Bool?
    /// Корень в этом подключении уже ставили повторно.
    var rootRetried = false

    // MARK: - Уход с экрана машины

    /// Наше приложение ушло с экрана машины (водитель открыл другое), но
    /// сцена жива и подключена: камеры поверх чужого приложения — системными
    /// алертами навигационной сессии (guidance.isOnScreen).
    func sceneWillResignActive(_ scene: UIScene) {
        // Siri или звонок поверх карты — сцена неактивна, но ещё на экране:
        // баннер камеры не должен прыгать в «уведомление» и обратно
        // (сценарий D1, 20.10). С экрана мы уходим в sceneDidEnterBackground.
        Log.carplay.notice("сцена машины: resign active")
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
        // Ушли с экрана машины: камеры поверх чужого приложения — системными
        // алертами сессии, манёвр и оценки для приборки — заново.
        guidance.isOnScreen = false
        guidance.refresh(reason: "ушли с экрана машины")
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
        guidance.refresh(reason: "вернулись на экран машины")
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
        retryOneTimeShows()
    }

    /// Проверка «корень действительно на экране машины», когда сцена стала
    /// активной. Решение — CarPlayRootWatch: подтверждённый системой корень
    /// после паузы на анимацию считается показанным, даже если
    /// templateDidAppear не пришёл (журналы 12.10: так бывает, когда машина
    /// подключилась при сцене не на экране). Неподтверждённый — ставим заново
    /// один раз за подключение, и только по таймауту.
    var templateWatch: Task<Void, Never>?

    /// Когда кнопку «Поездка» нажимали в последний раз.
    var lastTripToggle: Date?

    /// Ближайшие заведения вида списком: тап — маршрут.
    /// Действия водителя, которые ждут сеть или поиск. ПОВТОР того же
    /// касания в эти секунды — «не сработало?», а не новое намерение: без
    /// этого он открывал второй список или строил маршрут дважды (аудит
    /// CarPlay 19.10). Другое касание (передумал: «АЗС» → «Дом») проходит.
    var actionsInFlight: Set<String> = []

    /// Поиск для слота Дом/Работа: выбранное место сохраняется в слот и к
    /// нему сразу строится маршрут. Делегат шаблона поиска слабый — держим
    /// объект, пока шаблон на экране.
    var assignSearch: CarPlaySearch?

    // MARK: - Один экран за раз

    /// Второй тап «Куда», «Радар!» или плитки до того, как первый экран
    /// встал, клал второй такой же экран сверху — «Назад» будто не работал
    /// (сценарий D1, 20.10). Пока экран едет — новый не кладём. Ответа
    /// системы может и не быть — тогда замок отпускает время.
    var pushStartedAt: Date?

    // MARK: - Выбор маршрута

    /// Поездка на экране выбора (CPTrip с вариантами). Держим, чтобы
    /// обновлять оценки и закрыть выбор.
    var previewTrip: CPTrip?
    /// Тронулись, пока выбор на экране, — выбор принят.
    var previewWatch: Task<Void, Never>?

}
