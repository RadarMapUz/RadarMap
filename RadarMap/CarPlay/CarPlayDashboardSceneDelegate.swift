//
//  CarPlayDashboardSceneDelegate.swift
//  RadarMap
//
//  Приборная панель CarPlay (Dashboard) — главный экран машины, где карта
//  навигатора стоит рядом с музыкой и календарём.
//
//  Без этой сцены RadarMap на главном экране машины не появлялся вовсе:
//  водитель видел там чужой навигатор, а наш — только открыв приложение.
//  Здесь та же карта на движке и маленький прибор (скорость, лимит, камера);
//  манёвр в плитке рисует сама машина — из навигационной сессии
//  (CarPlayGuidance), отдельно его вести не нужно.
//
//  Карта живёт только пока панель на экране: основная сцена CarPlay свою
//  карту в фоне выгружает так же, и две карты на движке разом не работают —
//  это и память (docs/crash_carplay_memory.md), и нагрев.
//

import CarPlay
import SwiftUI
import os

final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private let model = CarPlayMapModel()
    private var controller: CPDashboardController?

    private var env: AppEnvironment { .shared }

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                           didConnect dashboardController: CPDashboardController,
                                           to window: UIWindow) {
        Log.carplay.notice("CarPlay: приборная панель подключена")
        controller = dashboardController
        model.carIsDark = window.traitCollection.userInterfaceStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance,
                              coordinate: env.location.currentCoordinate)
        // Тема машины меняется на ходу (фары, тоннель). У панели нет
        // contentStyleDidChange, как у основной сцены, — слушаем трейт окна:
        // иначе в «Авто» панель, подключённая днём, оставалась белой всю ночь.
        window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (window: UIWindow, _: UITraitCollection) in
            guard let self else { return }
            self.model.carIsDark = window.traitCollection.userInterfaceStyle == .dark
            self.model.refreshDaylight(appearance: self.env.settings.mapAppearance,
                                       coordinate: self.env.location.currentCoordinate)
        }
        let host = UIHostingController(rootView: CarPlayDashboardView(model: model).environment(env))
        host.view.backgroundColor = UIColor(Theme.background)
        window.rootViewController = host
        env.startDrivingServices()
        syncShortcuts()
    }

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                           didDisconnect dashboardController: CPDashboardController,
                                           from window: UIWindow) {
        Log.carplay.notice("CarPlay: приборная панель отключена")
        controller = nil
        model.isOnScreen = false
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        model.isOnScreen = true
        syncShortcuts()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        model.isOnScreen = false
    }

    /// Ярлыки «Домой» / «На работу» — когда маршрута нет. С маршрутом панель
    /// показывает карточку манёвра сама, и ярлыки ей не нужны.
    private func syncShortcuts() {
        guard let controller else { return }
        controller.shortcutButtons = PlaceSlot.allCases.compactMap { slot in
            guard let place = env.settings.place(for: slot),
                  let image = UIImage(systemName: slot.symbol) else { return nil }
            return CPDashboardButton(titleVariants: [slot.name], subtitleVariants: [place.title],
                                     image: image) { [weak self] _ in
                self?.route(to: place)
            }
        }
    }

    private func route(to place: SavedPlace) {
        Task { @MainActor [weak self] in
            guard let self, let from = await env.location.awaitPreciseCoordinate() else { return }
            await env.route.build(from: from, to: place.coordinate, name: place.title,
                                  cameras: env.cameras.cameras, alternatives: false)
            env.settings.addRecent(title: place.title, lat: place.lat, lon: place.lon)
            if !env.location.isTripActive { env.location.startTrip() }
            if let error = env.route.errorMessage {
                Log.carplay.error("маршрут с приборной панели: \(error, privacy: .public)")
            }
        }
    }
}

/// Плитка приборной панели: карта и маленький прибор поверх.
struct CarPlayDashboardView: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if model.isOnScreen, CarPlayMapModel.usesEngine(env.settings) {
                #if canImport(MapLibre)
                CarPlayEngineLayer(model: model, compact: true)
                #endif
            } else {
                Theme.background.ignoresSafeArea()
            }
            CarPlayDashboardGauge()
                .padding(10)
                .safeAreaPadding()
        }
        .environment(\.colorScheme, model.isDaylight ? .light : .dark)
        .task {
            while !Task.isCancelled {
                model.refreshDaylight(appearance: env.settings.mapAppearance,
                                      coordinate: env.location.currentCoordinate)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// Скорость, лимит и ближайшая камера — одной плашкой. Отдельная вью:
/// пер-тиковые чтения пересобирают её, а не плитку с картой.
private struct CarPlayDashboardGauge: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 10) {
            Text("\(Int(env.location.speedKmh.rounded()))")
                .font(.rounded(26, .heavy).monospacedDigit())
                .foregroundStyle(env.speedLimits.isOverspeeding ? Theme.danger : Theme.textPrimary)
            if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 32, isAssumed: env.speedLimits.isCurrentLimitAssumed)
            }
            if env.location.isApproachingCamera, let camera = env.location.nearestCamera,
               let distance = env.location.distanceToNearest {
                HStack(spacing: 4) {
                    Image(systemName: camera.kind.symbolName)
                        .font(.rounded(13, .bold))
                        .foregroundStyle(camera.kind.glyphTint)
                        .frame(width: 24, height: 24)
                        .background(camera.kind.tint, in: Circle())
                    Text(Formatting.distance(distance))
                        .font(.rounded(16, .bold).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.background.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        .allowsHitTesting(false)
    }
}
