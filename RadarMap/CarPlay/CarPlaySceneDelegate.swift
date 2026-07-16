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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.syncTripButton() }
        }
    }
}
