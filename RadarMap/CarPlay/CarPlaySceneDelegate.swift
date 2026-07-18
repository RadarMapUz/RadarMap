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
        template.automaticallyHidesNavigationBar = true
        template.mapButtons = [recenterButton, zoomInButton, zoomOutButton]
        mapTemplate = template
        interfaceController.setRootTemplate(template, animated: true) { _, _ in }

        // В машине приложение «на переднем плане», даже если телефон в кармане.
        env.location.setForeground(true)
        syncTripButton()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        self.interfaceController = nil
        mapTemplate = nil
        // GPS-режимом дальше управляет телефонная сцена (scenePhase в RootView).
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

    /// Кнопка «Поездка/Завершить» в баре шаблона — следит за состоянием поездки.
    private func syncTripButton() {
        guard let mapTemplate else { return }
        let location = AppEnvironment.shared.location

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
            Task { @MainActor [weak self] in self?.syncTripButton() }
        }
    }

    // MARK: «Куда» — маршрут прямо из машины

    /// Кнопка «Куда»: Дом/Работа/Недавние — строим маршрут, не доставая телефон.
    private var destinationsButton: CPBarButton? {
        let env = AppEnvironment.shared
        let places = Self.destinations(env: env)
        guard !places.isEmpty else { return nil }   // мест ещё нет — кнопка не нужна
        return CPBarButton(title: String(localized: "Куда")) { [weak self] _ in
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
        let items = Self.destinations(env: env).map { title, place in
            let item = CPListItem(text: title,
                                  detailText: title == place.title ? nil : place.title)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    if let from = env.location.currentCoordinate {
                        // Без альтернатив: за рулём выбирать некогда, edem сразу.
                        await env.route.build(from: from, to: place.coordinate,
                                              name: place.title, cameras: env.cameras.cameras,
                                              alternatives: false)
                        env.location.startTrip()
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
