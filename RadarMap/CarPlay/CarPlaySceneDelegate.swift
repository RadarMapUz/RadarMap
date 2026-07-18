//
//  CarPlaySceneDelegate.swift
//  RadarMap
//
//  Вход CarPlay (категория Navigation): собственное окно карты + кнопки
//  шаблона. Окружение общее с телефоном — камеры, маршрут, поездка живут
//  в одном экземпляре AppEnvironment.
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

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController

        let env = AppEnvironment.shared
        let host = UIHostingController(rootView: CarPlayMapScreen(model: model)
            .environment(env))
        host.view.backgroundColor = UIColor(Theme.background)
        window.rootViewController = host

        let template = CPMapTemplate()
        // Бар НЕ прячем: «Поездка» и «Куда» должны быть на виду всегда —
        // кнопка, которую нужно искать, за рулём бесполезна.
        template.automaticallyHidesNavigationBar = false
        template.mapButtons = [recenterButton, zoomInButton, zoomOutButton, routeButton]
        mapTemplate = template
        interfaceController.setRootTemplate(template, animated: true) { _, _ in }

        // В машине приложение «на переднем плане», даже если телефон заблокирован
        // в кармане — у CarPlay свой флаг, телефонная сцена его не затирает.
        env.location.setCarPlayConnected(true)
        session += 1
        syncTripButton()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        self.interfaceController = nil
        mapTemplate = nil
        session += 1   // гасим подписки syncTripButton этой сессии
        // Вышли из машины: телефон мог всё это время быть в фоне, события
        // scenePhase не будет — снимаем «передний план» сами.
        AppEnvironment.shared.location.setCarPlayConnected(false)
    }

    // MARK: Кнопки карты

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

    private static func buttonImage(_ symbol: String) -> UIImage? {
        UIImage(systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
    }

    /// Быстрый маршрут прямо с карты: круглая кнопка → список Дом/Работа/Недавние.
    private var routeButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in self?.presentDestinations() }
        button.image = Self.buttonImage("arrow.triangle.turn.up.right.circle.fill")
        return button
    }

    /// Кнопка «Поездка/Завершить» в баре шаблона — следит за состоянием поездки.
    private func syncTripButton() {
        guard let mapTemplate else { return }
        let location = AppEnvironment.shared.location
        let session = session   // подписка живёт до первого изменения — привязываем к сессии

        withObservationTracking {
            let active = location.isTripActive
            let title = active ? String(localized: "Завершить") : String(localized: "Поездка")
            let button = CPBarButton(title: title) { [weak self] _ in
                let location = AppEnvironment.shared.location
                if location.isTripActive { location.endTrip() } else { location.startTrip() }
                _ = self   // кнопка пересоберётся через наблюдение
            }
            mapTemplate.leadingNavigationBarButtons = [button]
            mapTemplate.trailingNavigationBarButtons = [self.destinationsButton].compactMap { $0 }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                self.syncTripButton()
            }
        }
    }

    // MARK: «Куда» — маршрут прямо из машины

    /// Кнопка «Куда»: Дом/Работа/Недавние — строим маршрут, не доставая телефон.
    private var destinationsButton: CPBarButton? {
        CPBarButton(title: String(localized: "Куда")) { [weak self] _ in
            self?.presentDestinations()
        }
    }

    private static func destinations(env: AppEnvironment) -> [(String, SavedPlace)] {
        var out: [(String, SavedPlace)] = []
        if let home = env.settings.homePlace { out.append((String(localized: "Дом"), home)) }
        if let work = env.settings.workPlace { out.append((String(localized: "Работа"), work)) }
        for recent in env.settings.recentPlaces.prefix(6) {
            out.append((recent.title, recent))
        }
        return out
    }

    private func presentDestinations() {
        let env = AppEnvironment.shared
        let places = Self.destinations(env: env)
        // Мест пока нет — подсказываем, где их завести (список не может быть пустым).
        guard !places.isEmpty else {
            let hint = CPListItem(text: String(localized: "Пока нет сохранённых мест"),
                                  detailText: String(localized: "Задайте Дом и Работу в настройках RadarMap на iPhone."))
            let list = CPListTemplate(title: String(localized: "Куда"),
                                      sections: [CPListSection(items: [hint])])
            interfaceController?.pushTemplate(list, animated: true) { _, _ in }
            return
        }
        let items = places.map { title, place in
            let item = CPListItem(text: title,
                                  detailText: title == place.title ? nil : place.title)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    if let from = env.location.currentCoordinate {
                        // Без альтернатив: за рулём выбирать некогда, edem сразу.
                        await env.route.build(from: from, to: place.coordinate,
                                              name: place.title, cameras: env.cameras.cameras,
                                              alternatives: false)
                        // Едем уже с активной поездкой — не обнулять её накат.
                        if !env.location.isTripActive { env.location.startTrip() }
                    }
                    completion()
                    self?.interfaceController?.popToRootTemplate(animated: true) { _, _ in }
                }
            }
            return item
        }
        let list = CPListTemplate(title: String(localized: "Куда"),
                                  sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true) { _, _ in }
    }
}
