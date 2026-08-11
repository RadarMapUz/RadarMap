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

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private let model = CarPlayMapModel()
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

        let host = UIHostingController(rootView: CarPlayMapScreen(model: model)
            .environment(env))
        host.view.backgroundColor = UIColor(Theme.background)
        window.rootViewController = host

        let template = CPMapTemplate()
        // Бар НЕ прячем: «Поездка» и «Куда» должны быть на виду всегда —
        // кнопка, которую нужно искать, за рулём бесполезна.
        template.automaticallyHidesNavigationBar = false
        mapTemplate = template
        interfaceController.setRootTemplate(template, animated: true) { _, _ in }

        // В машине приложение «на переднем плане», даже если телефон заблокирован
        // в кармане — у CarPlay свой флаг, телефонная сцена его не затирает.
        // Через окружение: телефонный экран по этому же флагу уступает место
        // экрану передачи (MapKit на двух экранах разом — двойной нагрев).
        env.setCarPlayConnected(true)
        // CarPlay может быть ПЕРВОЙ сценой процесса: без этого вызова база
        // лимитов, краудсорс и автостарт стартовали только из телефонной сцены,
        // и поездка из машины писалась без лимитов — без рейтинга и штрафов.
        env.startDrivingServices()
        session += 1
        syncTemplate()
        // Сразу, а не по первому тапу: без разрешения экран машины не покажет
        // ни скорости, ни камер, и молчание тут неотличимо от поломки.
        if !env.location.isAuthorized { showNoPermissionAlert() }
        observePendingConfirm()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        self.interfaceController = nil
        mapTemplate = nil
        session += 1   // гасим подписки syncTemplate этой сессии
        toastTask?.cancel()
        toastTask = nil
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

    // MARK: - Сборка шаблона

    /// Единая пересборка кнопок: и бар, и кнопки карты зависят от состояния
    /// (идёт поездка, построен маршрут, включён звук). Читаем состояние внутри
    /// withObservationTracking — при любом изменении собираем заново.
    private func syncTemplate() {
        guard let mapTemplate else { return }
        let session = session   // подписка живёт до первого изменения — привязываем к сессии

        withObservationTracking {
            let tripActive = env.location.isTripActive
            let routeActive = env.route.isActive
            let muted = isMuted   // читает оба тумблера — оба и отслеживаем
            let sketchShown = model.showsSketch

            mapTemplate.leadingNavigationBarButtons = [tripButton(active: tripActive),
                                                       viewButton(sketchShown: sketchShown)]
            mapTemplate.trailingNavigationBarButtons = [destinationsButton(routeActive: routeActive),
                                                       reportButton]
            // В режиме схемы зум и «к себе» бессмысленны: охват и центр схема
            // выбирает сама по дистанции до камеры. Оставляем только звук.
            mapTemplate.mapButtons = sketchShown
                ? [soundButton(muted: muted)]
                : [soundButton(muted: muted), zoomInButton, zoomOutButton, recenterButton]
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.syncTemplate()
            }
        }
    }

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
        AppEnvironment.shared.location.setCarPlaySketchVisible(false)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
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
            if location.isTripActive { location.endTrip() } else { location.startTrip() }
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
        CPBarButton(title: sketchShown ? String(localized: "Карта")
                                       : String(localized: "Схема")) { [model] _ in
            model.toggleView()
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
    private var reportButton: CPBarButton {
        CPBarButton(image: Self.buttonImage("exclamationmark.triangle.fill") ?? UIImage()) { [weak self] _ in
            self?.presentReport()
        }
    }

    // MARK: - Кнопки карты

    private var recenterButton: CPMapButton {
        let button = CPMapButton { [model] _ in model.recenterRequests += 1 }
        button.image = Self.buttonImage("location.fill")
        return button
    }

    private var zoomInButton: CPMapButton {
        let button = CPMapButton { [model] _ in model.zoomInRequests += 1 }
        button.image = Self.buttonImage("plus")
        return button
    }

    private var zoomOutButton: CPMapButton {
        let button = CPMapButton { [model] _ in model.zoomOutRequests += 1 }
        button.image = Self.buttonImage("minus")
        return button
    }

    /// Тумблер тишины: заглушить оповещения, не доставая телефон (спит пассажир,
    /// идёт разговор). Иконка показывает текущее состояние.
    private func soundButton(muted: Bool) -> CPMapButton {
        let button = CPMapButton { [weak self] _ in
            self?.toggleMute()   // наблюдение пересоберёт кнопку
        }
        button.image = Self.buttonImage(muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
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

    private static func buttonImage(_ symbol: String) -> UIImage? {
        UIImage(systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
    }

    /// Иконка плитки сетки: шаблонное изображение — CarPlay сам красит его под
    /// тему машины (днём тёмным по светлому, ночью наоборот).
    private static func gridImage(_ symbol: String) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
        let image = UIImage(systemName: symbol, withConfiguration: config) ?? UIImage()
        return image.withRenderingMode(.alwaysTemplate)
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

        let grid = CPGridTemplate(title: String(localized: "Куда"), gridButtons: buttons)
        interfaceController?.pushTemplate(grid, animated: true) { _, _ in }
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
        CPGridButton(titleVariants: titles, image: Self.gridImage(symbol)) { _ in action() }
    }

    /// Длинный адрес в плитку не влезает — короткий вариант для узких экранов.
    private static func shortTitle(_ title: String) -> String {
        let head = title.split(separator: ",").first.map(String.init) ?? title
        return head.count > 18 ? String(head.prefix(17)) + "…" : head
    }

    /// Строим маршрут и сразу едем: за рулём выбирать из альтернатив некогда.
    private func route(to place: SavedPlace) {
        guard let from = env.location.currentCoordinate else {
            showAlert(title: String(localized: "Ждём спутники"),
                      message: String(localized: "Положение ещё не определено — попробуйте через несколько секунд."))
            return
        }
        popToMap()
        Task { @MainActor [weak self] in
            guard let self else { return }
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
        interfaceController?.pushTemplate(grid, animated: true) { _, _ in }
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
