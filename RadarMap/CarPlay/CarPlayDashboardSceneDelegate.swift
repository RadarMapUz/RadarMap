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
    /// Постоянный корень окна плитки (CarPlayWindowRoot) — ставится при
    /// подключении и не меняется; содержимое — только когда плитка на экране
    /// и заново после фона (те же правила, что у основной сцены, 11.10).
    private var windowRoot: CarPlayWindowRoot?
    private var needsFreshHost = true

    private var env: AppEnvironment { .shared }

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                           didConnect dashboardController: CPDashboardController,
                                           to window: UIWindow) {
        // Сцена создаётся, только если ключ CPSupportsDashboardNavigationScene
        // лежит ВНУТРИ UIApplicationSceneManifest. С 10.10 по 2.2.4 он стоял
        // уровнем выше, система его не видела, и эта строка журнала не
        // появлялась ни разу — на главном экране машины была чужая карта.
        Log.carplay.notice("CarPlay: приборная панель подключена")
        controller = dashboardController
        model.carIsDark = window.traitCollection.userInterfaceStyle == .dark
        model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: env.sunIsUp)
        // Тема машины меняется на ходу (фары, тоннель). У панели нет
        // contentStyleDidChange, как у основной сцены, — слушаем трейт окна:
        // иначе в «Авто» панель, подключённая днём, оставалась белой всю ночь.
        window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (window: UIWindow, _: UITraitCollection) in
            guard let self else { return }
            self.model.carIsDark = window.traitCollection.userInterfaceStyle == .dark
            self.model.refreshDaylight(appearance: self.env.settings.mapAppearance, sunDay: self.env.sunIsUp)
        }
        // Панель подключается и в ФОНЕ (журнал 11.10: BG-Active сразу при
        // открытии приложения), а модель раньше считала себя на экране по
        // умолчанию — и в окне, которое никто не видел, поднималась вторая
        // карта на движке рядом с основной. Корень окна — сразу, содержимое —
        // только на экране.
        let root = CarPlayWindowRoot()
        window.rootViewController = root
        windowRoot = root
        let shown = scene.activationState == .foregroundActive
            || scene.activationState == .foregroundInactive
        model.isOnScreen = shown
        // Карта — только в активном приложении: MapLibre, созданный в фоне,
        // стартует «спящим» (см. CarPlaySceneDelegate.didConnect).
        if shown && UIApplication.shared.applicationState != .background { installHost() }
        env.setCarPlayDashboardConnected(true)
        env.startDrivingServices()
        shortcutsGeneration += 1
        observeShortcuts()
    }

    /// Ярлыки следуют за местами: Дом, заданный поиском в машине или на
    /// телефоне, до 19.10 оставался на плитке «не задан» до переподключения —
    /// синхронизация шла только при подключении и выходе на экран.
    private var shortcutsGeneration = 0

    private func observeShortcuts() {
        let generation = shortcutsGeneration
        syncShortcuts()
        withObservationTracking {
            for slot in PlaceSlot.allCases { _ = env.settings.place(for: slot) }
            _ = env.learnedPlaces
            _ = env.commute
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.controller != nil, self.shortcutsGeneration == generation else { return }
                self.observeShortcuts()
            }
        }
    }

    private func installHost() {
        guard let windowRoot else { return }
        let host = UIHostingController(rootView: CarPlayDashboardView(model: model).environment(env))
        host.view.backgroundColor = UIColor(Theme.background)
        windowRoot.setContent(host)
        needsFreshHost = false
    }

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                           didDisconnect dashboardController: CPDashboardController,
                                           from window: UIWindow) {
        Log.carplay.notice("CarPlay: приборная панель отключена")
        controller = nil
        model.isOnScreen = false
        windowRoot?.setContent(nil)
        windowRoot = nil
        env.setCarPlayDashboardConnected(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        if needsFreshHost {
            if UIApplication.shared.applicationState == .background {
                windowRoot?.setContent(nil)   // построим в sceneDidBecomeActive
            } else {
                installHost()
            }
        }
        model.isOnScreen = true
        syncShortcuts()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if needsFreshHost || windowRoot?.content == nil { installHost() }
        // Плитка инструкций рядом с картой рисует манёвр из навигационной
        // сессии основной сцены — освежаем его на каждый показ панели.
        CarPlaySceneDelegate.refreshGuidance(reason: "главный экран машины")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        model.isOnScreen = false
        needsFreshHost = true
    }

    /// Ярлыки «Дом» / «Работа». С маршрутом панель показывает карточку
    /// манёвра сама.
    ///
    /// Раньше незаданный слот просто пропадал, и на главном экране машины у
    /// нас не было ни одной кнопки — рядом с плиткой Amap, где «Home not set»
    /// стоит всегда и ведёт к настройке. Теперь три состояния: адрес задан —
    /// маршрут; не задан, но выучен по поездкам (FrequentPlaces) — маршрут к
    /// выученному; ничего — «не задан», касание открывает поиск в машине, и
    /// выбранное место становится этим слотом.
    private func syncShortcuts() {
        guard let controller else { return }
        controller.shortcutButtons = PlaceSlot.allCases.compactMap { slot in
            guard let image = UIImage(systemName: slot.symbol) else { return nil }
            // Выбор «ручное → выученное» и «обычно 39 мин» — те же, что у
            // «Куда» основного экрана (CarPlaySlotTarget).
            let usual = CarPlaySlotTarget.usual(slot, commute: env.commute)
            let target = CarPlaySlotTarget.resolve(slot, manual: env.settings.place(for: slot),
                                                   learned: env.learnedPlaces)
            switch target {
            case .manual(let place)?:
                return CPDashboardButton(titleVariants: [slot.name],
                                         subtitleVariants: [usual.map { "\(place.title) · \($0)" }, place.title]
                                            .compactMap { $0 },
                                         image: image) { [weak self] _ in
                    self?.route(to: place, remember: true)
                }
            case .learned(let place)?:
                return CPDashboardButton(titleVariants: [slot.name],
                                         subtitleVariants: [usual, String(localized: "по вашим поездкам")]
                                            .compactMap { $0 },
                                         image: image) { [weak self] _ in
                    // Выученное в «недавние» не пишем (см. «Куда»).
                    self?.route(to: place, remember: false)
                }
            case nil:
                return CPDashboardButton(titleVariants: [slot.name], subtitleVariants: [slot.notSetTitle],
                                         image: image) { _ in
                    CarPlaySceneDelegate.presentAssignWhenReady(slot)
                }
            }
        }
    }

    /// Построение и защита от двойного касания — общие с основным экраном
    /// (CarPlayRouteRequest): два тапа «Дом» — один запрос OSRM.
    private func route(to place: SavedPlace, remember: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await CarPlayRouteRequest.run(env: env, to: place, remember: remember) {
            case .busy, .built:
                break
            case .noFix:
                // Без точного фикса маршрута нет. Сказать — голосом: у плитки
                // нет своих диалогов, а тап «Домой» без ответа читается как
                // поломка (аудит CarPlay, 12.10).
                Log.carplay.error("маршрут с приборной панели: нет точного фикса")
                env.alerts.speak(String(localized: "Не вижу точного положения — маршрут пока не построить"))
            case .failed(let error):
                Log.carplay.error("маршрут с приборной панели: \(error, privacy: .public)")
                env.alerts.speak(String(localized: "Маршрут не построился"))
            }
        }
    }
}

/// Плитка приборной панели: карта и маленький прибор поверх.
struct CarPlayDashboardView: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel
    /// Ширина плитки — меняется со сменой экрана, не тиком: по ней прибор
    /// решает, влезает ли прибытие (10.7).
    @State private var width: CGFloat = 0

    var body: some View {
        // Прибор справа: слева он сливался с подписями улиц и терялся (владелец, 09.11).
        ZStack(alignment: .bottomTrailing) {
            if model.isOnScreen {
                #if canImport(MapLibre)
                CarPlayEngineLayer(model: model, surface: .dashboard)
                #else
                Theme.background.ignoresSafeArea()
                #endif
            } else {
                Theme.background.ignoresSafeArea()
            }
            // Прибор — тоже только на экране (10.10): он читает скорость и
            // дистанцию каждого фикса, и плитка, которую никто не видит,
            // пересобиралась бы всю поездку.
            if model.isOnScreen {
                HStack(alignment: .bottom, spacing: 8) {
                    if CarPlaySurface.tileShowsStreet(width: width, arrivalShown: env.route.isActive) {
                        TileStreetSlot(model: model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    CarPlayDashboardGauge(width: width - 20)
                        .layoutPriority(1)
                }
                .padding(10)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.colorScheme, model.isDaylight ? .light : .dark)
        .onChange(of: env.sunIsUp, initial: true) { _, day in
            model.refreshDaylight(appearance: env.settings.mapAppearance, sunDay: day)
        }
        // Настройку сменили на телефоне — плитка не ждёт солнца.
        .onChange(of: env.settings.mapAppearance) { _, appearance in
            model.refreshDaylight(appearance: appearance, sunDay: env.sunIsUp)
        }
    }
}

/// Улица на широкой плитке: своя вью — имя читается только здесь.
private struct TileStreetSlot: View {
    let model: CarPlayMapModel
    var body: some View { StreetNamePill(name: model.streetName) }
}

/// Скорость, лимит, ближайшая камера и прибытие — одной плашкой. Отдельная
/// вью: пер-тиковые чтения пересобирают её, а не плитку с картой.
///
/// Камера — по тому же правилу, что основной док (`carPlayNearestCameraMeters`),
/// а не только в момент тревоги: на главном экране машины водитель смотрит
/// мельком, и «до камеры 128 м» в доке рядом с пустой плиткой читалось как
/// «плитка не видит камер» (12.10). Прибытие — при маршруте: системная плитка
/// инструкций рядом показывает его не всегда.
private struct CarPlayDashboardGauge: View {
    @Environment(AppEnvironment.self) private var env
    /// Сколько места у прибора. Плитка на узком экране машины — меньше
    /// 300 pt, и капсула со скоростью, знаком, камерой и прибытием вылезала
    /// за неё (10.7): прибытие там и так есть в соседней плитке инструкций,
    /// оно уходит первым.
    let width: CGFloat

    private var showsArrival: Bool { width <= 0 || width >= AppConfig.carPlayGaugeArrivalWidth }

    /// Минуты до показанного прибытия от минуты на часах — как «N min» в
    /// системной полосе рядом (ArrivalClock.minutesUntil): «20 мин 22:02»
    /// рядом с «22:01 · 20 min» читалось двумя разными прибытиями.
    private var remaining: TimeInterval {
        let route = env.route
        guard let arrival = route.arrival else { return route.remainingTime }
        let minutes = ArrivalClock.minutesUntil(arrival, now: Date())
        return minutes > 0 ? TimeInterval(minutes * 60) : route.remainingTime
    }

    private func straight(to camera: Camera) -> Double {
        guard let me = env.location.displayCoordinate ?? env.location.currentCoordinate else { return 0 }
        return GeoMath.fastDistance(me.latitude, me.longitude, camera.lat, camera.lon)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(Int(env.location.speedKmh.rounded()))")
                .font(.numeral(26, .heavy).monospacedDigit())
                .foregroundStyle(env.speedLimits.isOverspeeding ? Theme.danger : Theme.textPrimary)
                .liveNumber()
            if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 32, isAssumed: env.speedLimits.isCurrentLimitAssumed)
            }
            cameraCell
            if !showsArrival {
                EmptyView()
            } else if env.route.isActive {
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Formatting.duration(remaining))
                        .font(.rounded(16, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: env.route.arrivalText)
                        .font(.rounded(11, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let ghost = env.commuteLive.display {
                // Дорога на работу без маршрута (8.8.3б): время прибытия по
                // своим поездкам и хвост подписи — на плитке тесно для места.
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: Formatting.clock(ghost.arrival))
                        .font(.rounded(16, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: GhostText.tail(ghost))
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(GhostText.tint(ghost))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.background.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        .allowsHitTesting(false)
    }

    @ViewBuilder private var cameraCell: some View {
        let camera = env.location.displayNearestCamera
        let distance = camera == nil ? nil : env.location.displayDistanceToNearest
        switch CarPlayCameraCue.gaugeCamera(signalStale: env.location.isSignalStale, distance: distance,
                                            straight: camera.map(straight(to:)) ?? 0) {
        case .noSignal:
            Image(systemName: Icon.noGPSSignal)
                .font(.rounded(16, .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityLabel(Text("Нет сигнала GPS"))
        case .distance:
            if let camera, let distance {
                HStack(spacing: 4) {
                    CameraIcon(kind: camera.kind, side: 24)
                    Text(Formatting.distance(distance))
                        .font(.rounded(16, .bold).monospacedDigit())
                        .foregroundStyle(env.location.isApproachingCamera ? Theme.danger : Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .liveNumber()
                }
            }
        case .hidden:
            EmptyView()
        }
    }
}
