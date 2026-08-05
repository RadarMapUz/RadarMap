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
    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private let model = CarPlayMapModel()
    /// Поколение сессии CarPlay: подписки withObservationTracking из прошлых
    /// подключений сверяются с ним и не пересобирают кнопки повторно.
    private var session = 0
    /// Таймер автозакрытия всплывающего подтверждения («Отметка принята»).
    private var toastTask: Task<Void, Never>?
    /// Что было включено до тишины — чтобы вернуть ровно это.
    private var soundBeforeMute = true
    private var voiceBeforeMute = true

    private var env: AppEnvironment { AppEnvironment.shared }

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
        env.location.setCarPlayConnected(true)
        session += 1
        syncTemplate()
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
        // scenePhase не будет — снимаем «передний план» сами.
        AppEnvironment.shared.location.setCarPlayConnected(false)
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

            mapTemplate.leadingNavigationBarButtons = [tripButton(active: tripActive)]
            mapTemplate.trailingNavigationBarButtons = [destinationsButton(routeActive: routeActive),
                                                       reportButton]
            mapTemplate.mapButtons = [soundButton(muted: muted),
                                      zoomInButton, zoomOutButton, recenterButton]
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.syncTemplate()
            }
        }
    }

    // MARK: - Кнопки бара

    /// «Поездка» / «Завершить» — главный тумблер: включает активные оповещения.
    private func tripButton(active: Bool) -> CPBarButton {
        CPBarButton(title: active ? String(localized: "Завершить")
                                  : String(localized: "Поездка")) { [weak self] _ in
            guard let self else { return }
            let location = env.location
            if location.isTripActive { location.endTrip() } else { location.startTrip() }
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
    private var isMuted: Bool { !env.settings.soundEnabled && !env.settings.voiceEnabled }

    private func toggleMute() {
        let settings = env.settings
        if isMuted {
            // Возвращаем ровно то, что было до заглушения: у кого-то голос был
            // выключен намеренно — не включаем его «в подарок».
            settings.soundEnabled = soundBeforeMute
            settings.voiceEnabled = voiceBeforeMute
        } else {
            soundBeforeMute = settings.soundEnabled
            voiceBeforeMute = settings.voiceEnabled
            settings.soundEnabled = false
            settings.voiceEnabled = false
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

        for place in env.settings.recentPlaces.prefix(max(0, 8 - buttons.count)) {
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

    /// Радар, тренога, пост, ДТП — четыре крупные плитки, один тап и обратно
    /// на карту. Координата берётся текущая, ничего уточнять не нужно.
    private func presentReport() {
        let buttons = ReportKind.allCases.map { kind in
            gridButton(symbol: kind.symbol, titles: [kind.title]) { [weak self] in
                self?.submitReport(kind)
            }
        }
        let grid = CPGridTemplate(title: String(localized: "Что впереди?"), gridButtons: buttons)
        interfaceController?.pushTemplate(grid, animated: true) { _, _ in }
    }

    private func submitReport(_ kind: ReportKind) {
        guard let coordinate = env.location.currentCoordinate else {
            showAlert(title: String(localized: "Ждём спутники"),
                      message: String(localized: "Положение ещё не определено — отметку ставить не по чему."))
            return
        }
        popToMap()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await env.mobile.report(at: coordinate, kind: kind)
            switch result {
            case .created:   showToast(String(localized: "Отметка на карте — спасибо!"))
            case .confirmed: showToast(String(localized: "Отметку подтвердили — спасибо!"))
            case .failed:    showToast(String(localized: "Не отправилось: нет связи"))
            }
        }
    }

    // MARK: - Всплывающие сообщения

    private func popToMap() {
        interfaceController?.popToRootTemplate(animated: true) { _, _ in }
    }

    private func showAlert(title: String, message: String) {
        let alert = CPAlertTemplate(titleVariants: [title, message],
                                    actions: [CPAlertAction(title: String(localized: "Понятно"),
                                                            style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
        }])
        interfaceController?.presentTemplate(alert, animated: true) { _, _ in }
    }

    /// Короткое подтверждение без единого тапа: само гаснет через пару секунд —
    /// водителю нечего нажимать.
    private func showToast(_ text: String) {
        let alert = CPAlertTemplate(titleVariants: [text],
                                    actions: [CPAlertAction(title: String(localized: "ОК"),
                                                            style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
        }])
        interfaceController?.presentTemplate(alert, animated: true) { _, _ in }
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
        }
    }
}
