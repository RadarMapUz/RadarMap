//
//  CarPlaySceneDelegate.swift
//  RadarMap
//
//  Вход CarPlay (категория Navigation): собственное окно карты + шаблоны
//  управления. Окружение общее с телефоном — камеры, маршрут, поездка живут
//  в одном экземпляре AppEnvironment.
//
//  Раскладка управления рассчитана на слепой тап за рулём:
//  • бар — «Поездка/Завершить», «Куда» и отметка засады;
//  • кнопки карты — звук, зум, «к себе»;
//  • «Куда» — сетка крупных плиток (Дом, Работа, недавние) вместо списка:
//    попасть пальцем в плитку на кочке реально, в строку списка — нет.
//

import CarPlay
import SwiftUI
import os

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPMapTemplateDelegate {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей:
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor изолирует КАЖДЫЙ класс, а не
    /// только помеченный @MainActor, и синтезированный isolated deinit ведёт
    /// к свободе указателя, который никто не выделял (см. MapState).
    nonisolated deinit {}

    var interfaceController: CPInterfaceController?
    /// Начало сессии экрана машины — для суточной статистики (минуты).
    private var connectedAt: Date?
    private var mapTemplate: CPMapTemplate?
    private let model = CarPlayMapModel()
    /// Навигационная сессия CarPlay: манёвр, время в пути, полосы, камеры
    /// поверх чужого приложения.
    private lazy var guidance = CarPlayGuidance(model: model)
    /// Поиск адреса в машине: тот же порядок источников, что на телефоне.
    private lazy var search = CarPlaySearch { [weak self] place in self?.route(to: place) }
    /// Чей сейчас экран машины. Переподключение (штатное «моргание» провода
    /// при запуске двигателя) может доставить didDisconnect СТАРОЙ сцены уже
    /// ПОСЛЕ didConnect новой — и старая, уходя, глобально гасила GPS и опрос
    /// отметок у живой. Глобальное состояние трогает только владелец.
    private static weak var activeDelegate: CarPlaySceneDelegate?
    /// Поколение сессии CarPlay: подписки withObservationTracking из прошлых
    /// подключений сверяются с ним и не пересобирают кнопки повторно.
    var session = 0
    /// Таймер автозакрытия всплывающего подтверждения («Отметка принята»).
    var toastTask: Task<Void, Never>?

    var env: AppEnvironment { AppEnvironment.shared }

    // MARK: - Жизненный цикл сцены

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        // Сторож фризов main на время сессии машины. В DEBUG он уже стоит с
        // запуска; здесь он нужен ИМЕННО в релизе — жалоба «экран машины стоит»
        // приходит из TestFlight, а прибора под неё до сих пор не существовало.
        HitchWatch.start()
        // Фризы ДО машины к ней не относятся: счёт сессии — с нуля.
        _ = HitchWatch.drain()
        HitchWatch.setCounting(true)
        connectedAt = Date()
        // Режим меняет не только кнопка, но и автоматика жары — из вью.
        // Кнопки шаблона обязаны пойти следом в обоих случаях.
        if model.onViewModeChanged == nil {
            model.onViewModeChanged = { [weak self] in self?.syncTemplate() }
        }

        // День/ночь — ДО первого кадра: тема машины (датчик света) в «Авто»
        // старше солнца, и первый кадр раньше всегда был тёмным.
        model.carIsDark = scene.contentStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance,
                              coordinate: env.location.currentCoordinate)
        let host = UIHostingController(rootView: CarPlayMapScreen(model: model)
            .environment(env))
        host.view.backgroundColor = UIColor(Theme.background)
        window.rootViewController = host

        let template = CPMapTemplate()
        template.mapDelegate = self
        // Бар НЕ прячем: «Поездка» и «Куда» должны быть на виду всегда —
        // кнопка, которую нужно искать, за рулём бесполезна.
        template.automaticallyHidesNavigationBar = false
        mapTemplate = template
        Log.carplay.notice("CarPlay подключён")
        interfaceController.setRootTemplate(template, animated: true) { [weak self] _, error in
            if let error {
                Log.carplay.error("setRootTemplate: \(error.localizedDescription, privacy: .public)")
            } else if let self, self.mapTemplate === template {
                // Сессия — только на шаблоне, который уже на экране: начатая
                // на летящем корне могла пропасть, а свой баннер манёвра при
                // этом уже спрятан (hasSystemGuidance) — водитель без манёвра.
                self.guidance.attach(to: template)
            }
            // Алерт о разрешении — ПОСЛЕ установки корня: presentTemplate
            // поверх летящей корневой транзакции CarPlay отклоняет, и раньше
            // объяснение «почему экран молчит» само молча терялось.
            // Сразу, а не по первому тапу: без разрешения экран машины не
            // покажет ни скорости, ни камер, и молчание неотличимо от поломки.
            guard let self, !self.env.location.isAuthorized else { return }
            self.showNoPermissionAlert()
        }

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
        sentBar = nil
        sentMapButtons = nil
        syncTemplate()
        observePendingConfirm()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        Log.carplay.notice("CarPlay отключён")
        self.interfaceController = nil
        mapTemplate = nil
        guidance.detach()
        session += 1   // гасим подписки syncTemplate этой сессии
        toastTask?.cancel()
        toastTask = nil
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
        // Вышли из машины: телефон мог всё это время быть в фоне, события
        // scenePhase не будет — снимаем «передний план» сами. И флаг схемы
        // тоже: onDisappear у вью внутри сносимого CPWindow не гарантирован,
        // а залипший флаг тихо держал бы GPS-буст (тир 2 → 1) весь процесс.
        AppEnvironment.shared.setCarPlayConnected(false)
        AppEnvironment.shared.location.setCarPlaySketchVisible(false)
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
        model.refreshDaylight(appearance: env.settings.mapAppearance,
                              coordinate: env.location.currentCoordinate)
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

    /// Открыт ли сейчас осмотр схемы. Кнопка обязана знать: при
    /// `automaticallyHidesNavigationBar = false` CarPlay своей «Готово» не
    /// рисует, и без обратного вызова осмотр был дверью в одну сторону.
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
            let sketchShown = model.showsSketch

            let following = model.isFollowing

            let bar = [tripActive, routeActive, sketchShown]
            if bar != sentBar {
                sentBar = bar
                mapTemplate.leadingNavigationBarButtons = [tripButton(active: tripActive),
                                                           viewButton(sketchShown: sketchShown)]
                mapTemplate.trailingNavigationBarButtons = [destinationsButton(routeActive: routeActive),
                                                           reportButton]
            }
            // В режиме схемы зум и «к себе» отдаёт сам шаблон, когда открыт
            // осмотр; своя кнопка тут нужна одна — вход в него.
            let buttons = [muted, sketchShown, following, isPanning]
            if buttons != sentMapButtons {
                sentMapButtons = buttons
                mapTemplate.mapButtons = sketchShown
                    ? [soundButton(muted: muted), panButton]
                    : [soundButton(muted: muted), zoomInButton, zoomOutButton, recenterButton]
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session,
                      self.syncGeneration == generation else { return }
                self.syncTemplate()
            }
        }
    }

    // MARK: - Осмотр схемы на экране машины

    /// Панорама в машине идёт НЕ через жесты SwiftUI.
    ///
    /// Наша вью живёт внутри CPWindow, а касаниями на карте распоряжается
    /// шаблон: он сам рисует режим осмотра, сам ловит перетаскивание и сам
    /// показывает «Готово». Жест SwiftUI до схемы там просто не дойдёт —
    /// поэтому для машины это отдельная ветка, приводящая к тому же состоянию.
    ///
    /// Модель осмотра общая с телефоном (SketchState), и это принципиально:
    /// правило возврата — по бездействию и по тревоге — обязано быть одним.
    ///
    /// Сдвиг жеста приходит НАКОПЛЕННЫМ от его начала (как у
    /// UIPanGestureRecognizer), а схема и карта двигаются приращениями: без
    /// разницы с прошлым вызовом осмотр разгонялся — каждый кадр жеста
    /// добавлял весь путь пальца заново.
    private var panSoFar = CGPoint.zero

    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        panSoFar = .zero
        if model.showsSketch { model.sketch.beginInspect() }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        let step = CGSize(width: translation.x - panSoFar.x, height: translation.y - panSoFar.y)
        panSoFar = translation
        pan(by: step)
    }

    func mapTemplateDidEndPanGesture(_ mapTemplate: CPMapTemplate,
                                     velocity: CGPoint) {
        panSoFar = .zero
        if model.showsSketch { model.sketch.endInspect() }
    }

    /// Панорама туда, где она видна: схема — своим осмотром, карта (движок
    /// или MapKit) — командой. Раньше всё уходило в схему, и в режиме карты
    /// жест двигал невидимое.
    private func pan(by step: CGSize) {
        if model.showsSketch {
            model.sketch.pan(by: step)
        } else {
            model.pan(by: step)
        }
    }

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
        guard model.showsSketch else { return model.pan(by: translation) }
        model.sketch.beginInspect()
        model.sketch.pan(by: translation)
        model.sketch.endInspect()
    }

    /// Осмотр открылся — кнопка становится «выйти». Своим вызовом
    /// `showPanningInterface` мы этот флаг тоже поднимем, но осмотр умеет
    /// открываться и мимо нас (жест по карте на сенсорном устройстве), и
    /// состояние кнопки обязано следовать за шаблоном, а не за нашим тапом.
    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        guard !isPanning else { return }
        isPanning = true
        syncTemplate()
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        model.sketch.returnToMe()
        guard isPanning else { return }
        isPanning = false
        syncTemplate()
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

    // MARK: - Уход с экрана машины

    /// Наше приложение ушло с экрана машины (водитель открыл другое), но
    /// сцена жива и подключена.
    ///
    /// Схема при этом продолжала считать точку зрения на каждый GPS-тик и
    /// докачивать дорожные тайлы для картинки, которой никто не видит:
    /// `setCarPlaySketchVisible(true)` снимался только через `onDisappear`, а
    /// он при перекрытии чужим приложением не приходит. Батарея — приоритет
    /// номер один, и считать невидимое ей противоречит.
    func sceneWillResignActive(_ scene: UIScene) {
        // Только владелец: события устаревшей сцены не должны гасить буст живой.
        guard Self.activeDelegate === self else { return }
        AppEnvironment.shared.location.setCarPlaySketchVisible(false)
        guidance.isOnScreen = false
    }

    /// На экране машины другое приложение или приборная панель — карту
    /// выгружаем (model.isOnScreen); вернулись — поднимаем заново.
    func sceneDidEnterBackground(_ scene: UIScene) {
        guard Self.activeDelegate === self else { return }
        model.isOnScreen = false
        // В фоне приложение могут приостановить, и сторож записал бы паузу
        // процесса как фриз — счёт только пока экран машины наш.
        HitchWatch.setCounting(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        model.isOnScreen = true
        HitchWatch.setCounting(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Стали видимым экраном машины — значит, мы и владелец.
        Self.activeDelegate = self
        guidance.isOnScreen = true
        // Вернулись на экран машины — схема снова имеет смысл, но только если
        // она и выбрана: в режиме карты частые фиксы ей не нужны.
        AppEnvironment.shared.location.setCarPlaySketchVisible(model.showsSketch)
    }

    // MARK: - Кнопки бара

    /// «Поездка» / «Завершить» — главный тумблер: включает активные оповещения.
    private func tripButton(active: Bool) -> CPBarButton {
        CPBarButton(title: active ? String(localized: "Завершить")
                                  : String(localized: "Поездка")) { [weak self] _ in
            guard let self else { return }
            let location = env.location
            // Без разрешения startTrip выходит первой строкой и молча ничего
            // не делает: заголовок кнопки остаётся «Поездка», водитель жмёт
            // ещё раз и решает, что приложение сломано. Говорим вслух.
            guard location.isAuthorized else { return self.showNoPermissionAlert() }
            guard location.isTripActive else { return location.startTrip() }
            // На ходу — подтверждение: «Завершить» соседствует со «Схема», и
            // промах слепого тапа молча выключал бы оповещения о камерах.
            // На стоянке тап осознанный — завершаем сразу, как раньше.
            if location.speedKmh >= AppConfig.carPlayEndTripConfirmKmh {
                confirmEndTrip()
            } else {
                location.endTrip()
            }
        }
    }

    /// «Завершить поездку?» на ходу. Тот же паттерн, что у Apple Maps: конец
    /// маршрута не висит одним тапом на баре.
    private func confirmEndTrip() {
        let alert = CPAlertTemplate(
            titleVariants: [String(localized: "Завершить поездку?")],
            actions: [
                CPAlertAction(title: String(localized: "Завершить"),
                              style: .destructive) { [weak self] _ in
                    self?.env.location.endTrip()
                    self?.dismissTopTemplate()
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

    /// «Схема» ⇄ «Карта»: режим экрана машины. Схема — самый дешёвый рендер
    /// (телефон перестаёт греться об тайлы), карта — самый подробный. В жару
    /// автоматика предпочитает схему, но нажатая кнопка старше автоматики.
    private func viewButton(sketchShown: Bool) -> CPBarButton {
        // model — сильным захватом, а не через self: содержимое экрана обязано
        // переключаться, даже если делегат по какой-то причине умер раньше
        // шаблона. Ровно эту гарантию давала 1.1.0, и терять её нельзя.
        CPBarButton(title: sketchShown ? String(localized: "Карта")
                                       : String(localized: "Схема")) { [weak self, model] _ in
            model.toggleView()
            // Пересобираем шаблон СРАЗУ, не полагаясь на наблюдение.
            //
            // Кнопки живут вне цикла обновления SwiftUI: их держит CPMapTemplate,
            // и обновляются они только этой пересборкой. Наблюдение
            // (withObservationTracking) её обычно и вызывает, но у него есть
            // окно: подписка одноразовая и восстанавливается асинхронно, а
            // изменения, случившиеся в этом промежутке, теряются. В машине это
            // выглядело так: содержимое уже схема, а на кнопке всё ещё «Схема»
            // и рядом четыре кнопки карты — то есть шаблон остался в прежнем
            // режиме. Прямой вызов делает состояние кнопок следствием нажатия,
            // а не гонки.
            self?.syncTemplate()
        }
    }

    /// «Куда» — сетка направлений; при активном маршруте подписью намекаем,
    /// что там же лежит «Стоп».
    private func destinationsButton(routeActive: Bool) -> CPBarButton {
        CPBarButton(title: routeActive ? String(localized: "Маршрут")
                                       : String(localized: "Куда")) { [weak self] _ in
            self?.presentDestinations()
        }
    }

    /// Отметить засаду прямо на ходу — иконкой, чтобы бар не распухал.
    ///
    /// Речевой пузырь, а не треугольник. Треугольник в приложении уже занят и
    /// занят прочно: `exclamationmark.triangle.fill` — это тип камеры «ДТП», он
    /// стоит на маркерах карты и в ленте. Один глиф на две разные вещи в
    /// пределах одного экрана — это не стиль, это ошибка чтения. Пузырь же
    /// говорит ровно то, что делает кнопка: рассказать другим.
    ///
    /// Фолбэк — заголовком, а не пустой картинкой: `?? UIImage()` давал бы
    /// нажимаемую кнопку-невидимку в баре.
    private var reportButton: CPBarButton {
        guard let image = buttonImage("exclamationmark.bubble.fill") else {
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

    /// Осмотр схемы — ТУМБЛЕР, а не вход.
    ///
    /// «Готово» рисует не приложение, а CarPlay, и только когда прячет
    /// навигационный бар. Бар мы держим на виду намеренно («Поездка» и «Куда»
    /// за рулём искать нельзя), поэтому кнопки выхода на экране не появлялось
    /// вовсе: `showPanningInterface` был, `dismissPanningInterface` — нигде.
    /// Водитель, тронувший осмотр, оставался в нём до конца поездки, а повторный
    /// тап открывал осмотр заново поверх уже открытого.
    ///
    /// Панораму внутри осмотра по-прежнему ведёт сам шаблон: он ловит
    /// перетаскивание и стрелки, приложение только входит и выходит.
    private var panButton: CPMapButton {
        let panning = isPanning
        let button = CPMapButton { [weak self] _ in
            guard let template = self?.mapTemplate else { return }
            if panning {
                template.dismissPanningInterface(animated: true)
            } else {
                template.showPanningInterface(animated: true)
            }
        }
        button.image = buttonImage(panning ? "checkmark" : "hand.draw")
        return button
    }

    private var zoomInButton: CPMapButton {
        let button = CPMapButton { [model] _ in
            model.zoom(in: true, engine: CarPlayMapModel.usesEngine(AppEnvironment.shared.settings))
        }
        button.image = buttonImage("plus")
        return button
    }

    private var zoomOutButton: CPMapButton {
        let button = CPMapButton { [model] _ in
            model.zoom(in: false, engine: CarPlayMapModel.usesEngine(AppEnvironment.shared.settings))
        }
        button.image = buttonImage("minus")
        return button
    }

    /// Тумблер тишины: заглушить оповещения, не доставая телефон (спит пассажир,
    /// идёт разговор). Иконка показывает текущее состояние.
    private func soundButton(muted: Bool) -> CPMapButton {
        let button = CPMapButton { [weak self] _ in
            self?.toggleMute()   // наблюдение пересоберёт кнопку
        }
        button.image = buttonImage(muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        return button
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
    private func gridImage(_ symbol: String) -> UIImage {
        let image = UIImage(systemName: symbol,
                            withConfiguration: carConfiguration(pointSize: 36, weight: .semibold))
            ?? UIImage()
        return image.withRenderingMode(.alwaysTemplate)
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

    // MARK: - «Куда»: горячие плитки

    /// Дом, Работа и недавние — маршрут в один тап. Сетка ограничена восемью
    /// плитками, поэтому недавние добираем тем, что осталось.
    private func presentDestinations() {
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
        // нет в недавних, раньше можно было задать только на телефоне.
        buttons.append(gridButton(symbol: "magnifyingglass",
                                  titles: [String(localized: "Поиск")]) { [weak self] in
            self?.presentSearch()
        })
        // АЗС — частый вопрос в дороге, и ответ на него — одна плитка.
        buttons.append(gridButton(symbol: Venue.Kind.fuel.symbol,
                                  titles: [Venue.Kind.fuel.title]) { [weak self] in
            self?.presentNearest(.fuel)
        })

        // Дом и Работа уже стоят своими плитками выше — в «недавних» они
        // дублируются и съедают места из восьми, которые есть у сетки.
        // Сравниваем по координате, а не по названию: одно и то же место
        // может называться по-разному.
        let pinned = PlaceSlot.allCases.compactMap { env.settings.place(for: $0)?.coordinate }
        let recent = env.settings.recentPlaces.filter { place in
            !pinned.contains { GeoMath.fastDistance($0.latitude, $0.longitude,
                                                    place.coordinate.latitude,
                                                    place.coordinate.longitude) < 120 }
        }
        for place in recent.prefix(max(0, 8 - buttons.count)) {
            buttons.append(gridButton(symbol: "clock.arrow.circlepath",
                                      titles: [place.title, Self.shortTitle(place.title)]) { [weak self] in
                self?.route(to: place)
            })
        }

        // Заголовок совпадает с кнопкой, которой сюда пришли: тап «Маршрут»,
        // открывший экран «Куда», читался как промах.
        let grid = CPGridTemplate(title: env.route.isActive ? String(localized: "Маршрут")
                                                            : String(localized: "Куда"),
                                  gridButtons: buttons)
        interfaceController?.pushTemplate(grid, animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(куда): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ближайшие заведения вида списком: тап — маршрут.
    private func presentNearest(_ kind: Venue.Kind) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await search.nearest(kind)
            guard !found.isEmpty else {
                return showAlert(title: String(format: String(localized: "%@ рядом не нашлось"), kind.title),
                                 message: String(localized: "Без сети ищу только по своей карте."))
            }
            let items = found.map { place, detail -> CPListItem in
                let item = CPListItem(text: place.title, detailText: detail)
                item.handler = { [weak self] _, completion in
                    self?.route(to: place)
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

    private func presentSearch() {
        interfaceController?.pushTemplate(search.makeTemplate(), animated: true) { _, error in
            if let error {
                Log.carplay.error("pushTemplate(поиск): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Плитка Дом/Работа. Место не задано — плитку всё равно показываем: она
    /// всегда на одном месте (мышечная память), а тап объясняет, где её завести.
    private func placeButton(slot: PlaceSlot) -> CPGridButton {
        let place = env.settings.place(for: slot)
        let titles = place.map { [ "\(slot.name) · \($0.title)", slot.name ] } ?? [slot.name]
        return gridButton(symbol: slot.symbol, titles: titles) { [weak self] in
            guard let self else { return }
            guard let place else {
                showAlert(title: String(localized: "Место не задано"),
                          message: String(format: String(localized: "Задайте «%@» в настройках RadarMap на iPhone."),
                                          slot.name))
                return
            }
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
        return head.count > 18 ? String(head.prefix(17)) + "…" : head
    }

    /// Строим маршрут и сразу едем: за рулём выбирать из альтернатив некогда.
    private func route(to place: SavedPlace) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Грубая точка фонового режима сюда не годится: маршрут от неё
            // начинается за километры (plan_drive_complaints.md, Ж5).
            guard let from = await env.location.awaitPreciseCoordinate() else {
                showAlert(title: String(localized: "Ждём спутники"),
                          message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
                return
            }
            popToMap()
            await env.route.build(from: from, to: place.coordinate,
                                  name: place.title, cameras: env.cameras.cameras,
                                  alternatives: false)
            env.settings.addRecent(title: place.title, lat: place.lat, lon: place.lon)
            // Едем уже с активной поездкой — не обнулять её накат.
            if !env.location.isTripActive { env.location.startTrip() }
            if let error = env.route.errorMessage {
                showAlert(title: String(localized: "Маршрут не построен"), message: error)
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
        popToMap()
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
            showToast(outcome.spoken)
        }
    }
}
