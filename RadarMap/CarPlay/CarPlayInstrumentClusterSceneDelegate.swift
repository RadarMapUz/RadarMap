//
//  CarPlayInstrumentClusterSceneDelegate.swift
//  RadarMap
//
//  Приборка CarPlay (25.H2): наша карта в окне кластера машины — под глазами
//  водителя, рядом с его спидометром. Для антирадара лучшее место: камера
//  впереди и лимит видны, не отводя взгляд от дороги.
//
//  Устроено как плитка главного экрана (CarPlayDashboardSceneDelegate), с
//  двумя отличиями из заголовков CarPlay (iOS 15.4):
//  • окно приходит не с подключением сцены, а отдельно — делегатом
//    контроллера (`instrumentClusterControllerDidConnectWindow`) — и может
//    уйти и вернуться, пока сцена жива (водитель переключил вид приборки);
//  • машина говорит, рисовать ли нам знак лимита и компас
//    (`speedLimitSetting`, `compassSetting`) — CarPlayCluster.
//
//  Правила окна — общие для всех окон машины (2.2.6–2.2.7): постоянный корень
//  (CarPlayWindowRoot) на всё время жизни окна, меняется только содержимое;
//  содержимое — только когда сцена на экране и приложение не в фоне; после
//  фона — заново. Касаний и кнопок нет: приближение приходит от машины
//  (`instrumentClusterControllerDidZoomIn/Out`), карта всегда следит.
//
//  Сцена создаётся, только если в UIApplicationSceneManifest есть
//  CPSupportsInstrumentClusterNavigationScene и конфигурация роли
//  CPTemplateApplicationInstrumentClusterSceneSessionRoleApplication
//  (Info.plist — ВНУТРИ манифеста, как ключ плитки).
//

import CarPlay
import SwiftUI
import os

/// Настройки машины для приборки — наблюдаемые: знак и компас появляются и
/// пропадают по делегату контроллера, без пересоздания окна.
@MainActor
@Observable
final class CarPlayClusterState {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    var speedLimit: CarPlayCluster.Setting = .unspecified
    var compass: CarPlayCluster.Setting = .unspecified
}

extension CarPlayCluster.Setting {
    init(_ setting: CPInstrumentClusterSetting) {
        switch setting {
        case .enabled:        self = .enabled
        case .disabled:       self = .disabled
        case .userPreference: self = .userPreference
        case .unspecified:    self = .unspecified
        @unknown default:     self = .unspecified
        }
    }

    /// Для журнала.
    var logName: String {
        switch self {
        case .unspecified:    "не сказано"
        case .enabled:        "рисовать"
        case .disabled:       "не рисовать"
        case .userPreference: "по выбору водителя"
        }
    }
}

final class CarPlayInstrumentClusterSceneDelegate: UIResponder,
    CPTemplateApplicationInstrumentClusterSceneDelegate, CPInstrumentClusterControllerDelegate {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private let model = CarPlayMapModel()
    private let state = CarPlayClusterState()
    private var controller: CPInstrumentClusterController?
    /// Окно кластера и его постоянный корень. Окно приходит и уходит само
    /// по себе (делегат контроллера); корень живёт ровно столько, сколько окно.
    private weak var window: UIWindow?
    private var windowRoot: CarPlayWindowRoot?
    private var needsFreshHost = true
    /// Поколение наблюдения за поездкой: отключение гасит старое.
    private var observeGeneration = 0

    private var env: AppEnvironment { .shared }

    // MARK: - Сцена

    func templateApplicationInstrumentClusterScene(
        _ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
        didConnect instrumentClusterController: CPInstrumentClusterController) {
        let scene = templateApplicationInstrumentClusterScene
        controller = instrumentClusterController
        instrumentClusterController.delegate = self
        state.speedLimit = .init(instrumentClusterController.speedLimitSetting)
        state.compass = .init(instrumentClusterController.compassSetting)
        model.carIsDark = scene.contentStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: env.sunIsUp)
        // Сцена подключается и в фоне (как плитка, журнал 11.10): на экране
        // она только в foreground-состояниях, «пока не сказали иначе» — нет.
        model.isOnScreen = scene.activationState == .foregroundActive
            || scene.activationState == .foregroundInactive
        Log.carplay.notice("CarPlay: приборка подключена, на экране \(self.model.isOnScreen, privacy: .public), лимит — \(self.state.speedLimit.logName, privacy: .public), компас — \(self.state.compass.logName, privacy: .public), окно \(instrumentClusterController.instrumentClusterWindow != nil, privacy: .public)")
        observeGeneration &+= 1
        observeTrip()
        // Окно могло подключиться раньше, чем у контроллера появился делегат:
        // тогда вызова «окно подключено» не будет — берём его со свойства.
        if let window = instrumentClusterController.instrumentClusterWindow { attach(window) }
    }

    func templateApplicationInstrumentClusterScene(
        _ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
        didDisconnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController) {
        Log.carplay.notice("CarPlay: приборка отключена")
        observeGeneration &+= 1
        instrumentClusterController.delegate = nil
        controller = nil
        model.isOnScreen = false
        detachWindow()
    }

    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        model.carIsDark = contentStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: env.sunIsUp)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        model.isOnScreen = true
        if needsFreshHost {
            if UIApplication.shared.applicationState == .background {
                windowRoot?.setContent(nil)   // построим в sceneDidBecomeActive
            } else {
                updateContent()
            }
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        model.isOnScreen = true
        updateContent()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Приборку переключили на приборы машины (или другое приложение):
        // карта уходит сразу — её никто не видит, а это вторая карта на движке.
        model.isOnScreen = false
        needsFreshHost = true
        windowRoot?.setContent(nil)
        Log.carplay.notice("приборка: не на экране — карта выгружена")
    }

    // MARK: - Окно кластера (CPInstrumentClusterControllerDelegate)

    func instrumentClusterControllerDidConnect(_ instrumentClusterWindow: UIWindow) {
        attach(instrumentClusterWindow)
    }

    func instrumentClusterControllerDidDisconnectWindow(_ instrumentClusterWindow: UIWindow) {
        Log.carplay.notice("приборка: окно отключено")
        guard instrumentClusterWindow === window else { return }
        detachWindow()
    }

    func instrumentClusterControllerDidZoom(in instrumentClusterController: CPInstrumentClusterController) {
        model.zoom(in: true)
    }

    func instrumentClusterControllerDidZoomOut(_ instrumentClusterController: CPInstrumentClusterController) {
        model.zoom(in: false)
    }

    func instrumentClusterController(_ instrumentClusterController: CPInstrumentClusterController,
                                     didChangeCompassSetting compassSetting: CPInstrumentClusterSetting) {
        state.compass = .init(compassSetting)
        Log.carplay.notice("приборка: компас — \(self.state.compass.logName, privacy: .public)")
    }

    func instrumentClusterController(_ instrumentClusterController: CPInstrumentClusterController,
                                     didChangeSpeedLimitSetting speedLimitSetting: CPInstrumentClusterSetting) {
        state.speedLimit = .init(speedLimitSetting)
        Log.carplay.notice("приборка: лимит — \(self.state.speedLimit.logName, privacy: .public)")
    }

    // MARK: - Содержимое

    /// Постоянный корень — один раз на окно (CarPlayWindowRoot): замена
    /// rootViewController оставляла машине слой прежнего корня (2.2.5).
    private func attach(_ newWindow: UIWindow) {
        guard newWindow !== window else { return }
        detachWindow()
        let root = CarPlayWindowRoot()
        newWindow.rootViewController = root
        window = newWindow
        windowRoot = root
        needsFreshHost = true
        Log.carplay.notice("приборка: окно подключено, \(Int(newWindow.bounds.width), privacy: .public)×\(Int(newWindow.bounds.height), privacy: .public) pt, отступы \(Int(newWindow.safeAreaInsets.top), privacy: .public)/\(Int(newWindow.safeAreaInsets.left), privacy: .public)/\(Int(newWindow.safeAreaInsets.bottom), privacy: .public)/\(Int(newWindow.safeAreaInsets.right), privacy: .public)")
        updateContent()
    }

    private func detachWindow() {
        windowRoot?.setContent(nil)
        windowRoot = nil
        window = nil
        needsFreshHost = true
    }

    /// Хост SwiftUI в окне — по CarPlayCluster.installsContent; после фона —
    /// всегда заново (MapLibre, переживший фон, мог остаться спящим).
    private func updateContent() {
        guard let windowRoot else { return }
        let wanted = CarPlayCluster.installsContent(
            windowConnected: true, onScreen: model.isOnScreen,
            appInBackground: UIApplication.shared.applicationState == .background)
        guard wanted, needsFreshHost || windowRoot.content == nil else { return }
        let host = UIHostingController(rootView: CarPlayClusterView(model: model, state: state).environment(env))
        host.view.backgroundColor = UIColor(Theme.background)
        windowRoot.setContent(host)
        needsFreshHost = false
        Log.carplay.notice("приборка: карта поставлена")
    }

    // MARK: - Подпись без ведения

    /// `inactiveDescriptionVariants` — по поездке; пишется только на смене
    /// (каждое присваивание — сообщение машине).
    private func observeTrip() {
        let generation = observeGeneration
        guard let controller else { return }
        let variants = CarPlayCluster.inactiveDescription(tripActive: env.location.isTripActive)
        if controller.inactiveDescriptionVariants != variants {
            controller.inactiveDescriptionVariants = variants
        }
        withObservationTracking {
            _ = env.location.isTripActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observeGeneration == generation else { return }
                self.observeTrip()
            }
        }
    }
}

/// Окно приборки: карта и, если машина просит, знак лимита и компас.
struct CarPlayClusterView: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel
    let state: CarPlayClusterState

    var body: some View {
        ZStack {
            if CarPlayCluster.showsMap(onScreen: model.isOnScreen, performance: env.thermal.mode) {
                #if canImport(MapLibre)
                CarPlayEngineLayer(model: model, surface: .cluster)
                #else
                Theme.background.ignoresSafeArea()
                #endif
            } else {
                Theme.background.ignoresSafeArea()
            }
            // Знак и компас — тоже только на экране: они читают лимит и курс
            // каждого фикса.
            if model.isOnScreen {
                CarPlayClusterMarks(model: model, state: state)
            }
        }
        .environment(\.colorScheme, model.isDaylight ? .light : .dark)
        .onChange(of: env.sunIsUp, initial: true) { _, day in
            model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: day)
        }
        .onChange(of: env.settings.mapAppearance) { _, appearance in
            model.refreshDaylight(appearance: appearance, sunDay: env.sunIsUp)
        }
    }
}

/// Знак лимита и компас — отдельная вью: пер-тиковые чтения пересобирают её,
/// а не окно с картой. Лежат в safe area окна: края кластера закрывают
/// стрелки приборов машины.
private struct CarPlayClusterMarks: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel
    let state: CarPlayClusterState

    var body: some View {
        HStack(alignment: .top) {
            if CarPlayCluster.drawsSpeedLimit(state.speedLimit, limitsEnabled: env.settings.speedLimitsEnabled),
               let limit = env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 34, isAssumed: env.speedLimits.isCurrentLimitAssumed)
            }
            Spacer(minLength: 0)
            if CarPlayCluster.drawsCompass(state.compass) {
                compass
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    /// Стрелка на север: карта крутится по курсу, и без компаса на приборке
    /// не понять, куда смотрит картинка. Поворот — тот, что нарисовал движок,
    /// без курса — последний известный.
    private var compass: some View {
        let course = env.location.displayCourse
        let heading = course >= 0 ? course : (model.mapDirection ?? 0)
        return Image(systemName: "location.north.fill")
            .font(.rounded(15, .bold))
            // Не красная: красное на этой карте — камера.
            .foregroundStyle(Theme.accent)
            .rotationEffect(.degrees(-heading))
            .frame(width: 30, height: 30)
            .background(Theme.background.opacity(0.9), in: Circle())
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
