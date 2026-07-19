//
//  MapScreen.swift
//  RadarMap
//
//  Главный экран: тёмная карта с камерами, HUD, контролы, добавление, поиск, список, статистика.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

struct MapScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var map = MapState()
    @State private var dismissedApproachID: Int?
    @State private var headingUp = false
    @State private var showRouteCameras = false
    // Умные кнопки: в поездке через 5 с бездействия интерфейс прячется, тап по карте возвращает.
    @State private var controlsHidden = false
    @State private var hideControlsTask: Task<Void, Never>?
    /// Режим «Спидометр» — тап по HUD (телефон в держателе).
    @State private var showDashboard = false
    @State private var legendExpanded = false
    @State private var legendCollapseTask: Task<Void, Never>?
    /// Чип «Задать Дом и Работу» → поиск сразу в режиме назначения слота.
    @State private var assignSlot: PlaceSlot?
    /// Быстрые тумблеры оповещений (долгий тап по HUD).
    @State private var showQuickToggles = false
    /// Связывает карту с внешним MapCompass: системный компас, но в нашей колонке
    /// контролов, а не под статус-баром.
    @Namespace private var mapScope

    var body: some View {
        @Bindable var map = map

        ZStack {
            // Тема только у карты: интерфейс остаётся тёмным «радар-детектором»,
            // а подложка днём может быть светлой (тёмная на солнце бликует).
            mapLayer
                .ignoresSafeArea()
                .environment(\.colorScheme, mapColorScheme)

            // Затемнение под статус-баром: часы и батарея не тонут в карте.
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.background.opacity(0.7), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            if map.isAddingCamera { crosshair }

            topLayer
            bottomLayer

            // Превышение у камеры: мягкое красное свечение по краям — видно
            // периферийным зрением, на телефон смотреть не нужно.
            if env.location.isApproachingCamera && env.speedLimits.isOverspeeding {
                OverspeedVignette()
            }
        }
        .mapScope(mapScope)
        .fullScreenCover(isPresented: $showDashboard) { DashboardView() }
        .task {
            map.configure(env.cameras)
            map.filter = env.settings.filter
            // Если карта уже отдала регион до конфигурации (статичный старт без геопозиции) —
            // пересчитываем принудительно, иначе аннотации не появятся до первого движения карты.
            map.invalidateVisible()
            if let coordinate = env.location.currentCoordinate {
                map.snapToUserOnce(coordinate)   // геопозиция уже известна — сразу к своим камерам
            }
            #if DEBUG
            openScreenFromLaunchArguments()
            #endif
        }
        .onChange(of: env.settings.filter) { _, newValue in
            map.filter = newValue
            map.invalidateVisible()
        }
        .onChange(of: env.cameras.revision) { _, _ in
            // Любое изменение данных (загрузка базы, свои камеры, скрытие) —
            // одна точка обновления карты и region-мониторинга.
            map.invalidateVisible()
            env.location.refreshMonitoring()
        }
        .sheet(item: $map.selectedCamera) { camera in
            CameraDetailSheet(camera: camera,
                              onRoute: env.location.currentCoordinate == nil ? nil : {
                                  buildRoute(to: camera.coordinate, name: camera.displayTitle)
                              })
        }
        .sheet(isPresented: $map.showNearbySheet) {
            NearbyCamerasSheet(onSelect: { map.focus(on: $0) })
        }
        .sheet(isPresented: $map.showSearch) {
            // Без геопозиции кнопки маршрута прячем, как в соседних шитах:
            // мёртвая кнопка, молча закрывающая поиск, хуже её отсутствия.
            SearchView(onSelect: { map.move(to: $0) },
                       onRoute: env.location.currentCoordinate == nil ? nil
                           : { coord, name in buildRoute(to: coord, name: name) })
        }
        .sheet(isPresented: $showRouteCameras) {
            RouteCamerasSheet(onSelect: { map.focus(on: $0) })
        }
        .sheet(item: $assignSlot) { slot in
            SearchView(initialAssign: slot)
        }
        .sheet(isPresented: $map.showSettings) { SettingsView() }
        .sheet(isPresented: $map.showStats) {
            TripStatsSheet(onRoute: env.location.currentCoordinate == nil ? nil : { coord, name in
                buildRoute(to: coord, name: name)
            })
        }
        .overlay { loadErrorOverlay }
        .overlay { approachOverlay }
        .overlay { arrivalOverlay }
        .onChange(of: env.location.nearestCamera?.id) { _, _ in
            dismissedApproachID = nil   // новая ближайшая камера — снова показываем предупреждение
        }
        .onChange(of: env.location.isTripActive) { _, active in
            headingUp = active   // в поездке карта сама встаёт «по ходу движения»
            if active {
                scheduleControlsHide()
            } else {
                revealControls()
            }
        }
        .onChange(of: env.location.locationTick) { _, _ in
            // Прогресс маршрута (прибытие/манёвры/камеры) тикает в LocationService —
            // здесь только следование карты за курсом.
            if headingUp {
                map.follow(coordinate: env.location.currentCoordinate, course: env.location.currentCourse, pitched: env.location.isTripActive)
            }
            if let coordinate = env.location.currentCoordinate {
                map.snapToUserOnce(coordinate)   // первый фикс после запуска → окрестности
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.location.isApproachingCamera)
    }

    @ViewBuilder private var arrivalOverlay: some View {
        if let arrival = env.route.lastArrival {
            ArrivalCardView(arrival: arrival, onDismiss: { env.route.dismissArrival() })
                .transition(.opacity)
        }
    }

    @ViewBuilder private var approachOverlay: some View {
        if env.location.isApproachingCamera,
           let camera = env.location.nearestCamera,
           let distance = env.location.distanceToNearest,
           dismissedApproachID != camera.id {
            ApproachAlertView(
                camera: camera,
                distance: distance,
                speedKmh: env.location.speedKmh,
                relativeBearing: env.location.relativeBearingToNearest,
                alertRadius: env.settings.alertRadius,
                onDismiss: { dismissedApproachID = camera.id }
            )
        }
    }

    // MARK: - Карта

    /// Тема подложки: авто — светлая днём (6–19), тёмная ночью.
    private var mapColorScheme: ColorScheme {
        switch env.settings.mapAppearance {
        case .dark:  return .dark
        case .light: return .light
        case .auto:
            let hour = Calendar.current.component(.hour, from: Date())
            return (6..<19).contains(hour) ? .light : .dark
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            mapContent
                // Долгий тап → точка с баром действий. Sequenced-хак: LongPress
                // не отдаёт координату, добираем её нулевым DragGesture.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            guard case .second(true, let drag) = value,
                                  let location = drag?.location,
                                  let coordinate = proxy.convert(location, from: .local) else { return }
                            selectPoint(at: coordinate)
                        }
                )
        }
    }

    private var mapContent: some View {
        Map(position: $map.position, scope: mapScope) {
            UserAnnotation()

            // Маршрут: сперва тусклые альтернативы, поверх — выбранный вариант
            // (тёмная подложка + неоновая линия, читается на любом фоне).
            if !env.location.isTripActive {
                ForEach(env.route.variants) { variant in
                    if variant.id != env.route.selectedID {
                        MapPolyline(variant.polyline)
                            .stroke(Theme.textTertiary,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            if let polyline = env.route.polyline {
                MapPolyline(polyline)
                    .stroke(Theme.background.opacity(0.85),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(polyline)
                    .stroke(LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                // Пройденная часть тускнеет — видно, сколько осталось.
                if env.location.isTripActive, let traveled = env.route.traveledPolyline {
                    MapPolyline(traveled)
                        .stroke(Theme.textTertiary.opacity(0.7),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            if let dest = env.route.destinationCoordinate {
                Annotation(env.route.destinationName, coordinate: dest, anchor: .center) {
                    Image(systemName: "flag.checkered")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent.gradient, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }

            ForEach(map.visibleCameras) { camera in
                Annotation(camera.displayTitle, coordinate: camera.coordinate, anchor: .center) {
                    // Средний зум: точки; близкий — мини-знак лимита («60»);
                    // полный пин — у выбранной и ближайшей по курсу.
                    CameraAnnotationView(
                        camera: camera,
                        selected: map.highlightedID == camera.id,
                        compact: map.isDotZoom
                            && camera.id != env.location.nearestCamera?.id,
                        limit: map.isDotZoom ? nil
                             : env.speedLimits.limit(near: camera.coordinate)
                    )
                    .onTapGesture { map.select(camera) }
                }
                .annotationTitles(.hidden)
            }
            ForEach(map.clusters) { cluster in
                Annotation("\(cluster.count)", coordinate: cluster.coordinate, anchor: .center) {
                    ClusterAnnotationView(count: cluster.count)
                        .onTapGesture { map.zoomInto(cluster) }
                }
                .annotationTitles(.hidden)
            }

            // Точка долгого тапа — пульсирующий маркер, пока открыт бар действий.
            if let point = map.pressedPoint {
                Annotation("", coordinate: point.coordinate, anchor: .center) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.rounded(26, .bold))
                        .foregroundStyle(Theme.background, Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        // Системный компас вылезал под статус-бар в правом верхнем углу —
        // прячем, свой (по повороту карты) живёт в колонке контролов.
        .mapControls {}
        .onMapCameraChange(frequency: .onEnd) { context in
            map.updateVisible(for: context.region)
            // Потянул карту рукой — слежение за компасом устройства снимается.
            if !map.position.followsUserLocation { map.followsDeviceHeading = false }
        }
        // Любое касание карты будит спрятанные кнопки (не мешая тапам по маркерам)
        // и закрывает бар точки долгого тапа.
        .simultaneousGesture(TapGesture().onEnded {
            revealControls()
            if map.pressedPoint != nil {
                withAnimation(.spring(duration: 0.3)) { map.pressedPoint = nil }
            }
        })
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in revealControls() })
    }

    // MARK: - Умные кнопки

    /// В поездке интерфейс не нужен постоянно: прячем всё, кроме HUD, манёвра и панели.
    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard env.location.isTripActive else { return }
        hideControlsTask = Task {
            await Task.pause(seconds: 5)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { controlsHidden = true }
        }
    }

    private func revealControls() {
        hideControlsTask?.cancel()
        if controlsHidden {
            withAnimation(.easeOut(duration: 0.25)) { controlsHidden = false }
        }
        scheduleControlsHide()
    }

    private var crosshair: some View {
        Image(systemName: "scope")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(Theme.accent)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .allowsHitTesting(false)
    }

    // MARK: - Верх: HUD + подсказка

    private var topLayer: some View {
        VStack(spacing: 10) {
            // Тап по HUD — «Спидометр»; долгий тап — быстрые тумблеры оповещений.
            SpeedHUDView()
                .onTapGesture { showDashboard = true }
                .onLongPressGesture(minimumDuration: 0.4) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(duration: 0.3)) { showQuickToggles.toggle() }
                }
            if showQuickToggles {
                QuickTogglesBar {
                    withAnimation(.spring(duration: 0.3)) { showQuickToggles = false }
                }
            }
            // Turn-by-turn: ближайший манёвр — в поездке по маршруту.
            if env.location.isTripActive, let step = env.route.nextStep {
                ManeuverBanner(step: step, distance: env.route.nextStepDistance)
            }
            // Кнопки навигации — сразу под HUD справа; в поездке сами прячутся.
            if !map.isAddingCamera && !controlsHidden {
                HStack {
                    Spacer()
                    controlColumn
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            // Компас — ВНЕ прячущейся колонки (та удаляется из иерархии по таймауту,
            // и компас пропадал вместе с ней). Виден всегда: «появляется при повороте»
            // оказалось неочевидным — кнопку, которую нужно знать, не находят.
            if !map.isAddingCamera {
                HStack {
                    Spacer()
                    MapCompass(scope: mapScope)
                        .mapControlVisibility(.visible)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.3), value: env.route.nextStep?.distanceAlong)
        .animation(.easeInOut(duration: 0.3), value: controlsHidden)
    }

    // MARK: - Колонка навигации (компас, локация, зум)

    private var controlColumn: some View {
        VStack(spacing: 12) {
            // Тумблер «по ходу движения» нужен только в движении: вне поездки/маршрута
            // он висел в углу без дела и налезал на маркеры камер.
            if env.location.isTripActive || env.route.isActive {
                CircleControl(systemName: headingUp ? "location.north.line.fill" : "location.north.line",
                              tint: headingUp ? Theme.accent : Theme.textPrimary,
                              accessibilityLabel: "Карта по ходу движения") {
                    headingUp.toggle()
                    if headingUp {
                        map.follow(coordinate: env.location.currentCoordinate, course: env.location.currentCourse, pitched: env.location.isTripActive)
                    }
                    revealControls()
                }
                .transition(.scale.combined(with: .opacity))
            }
            CircleControl(systemName: map.followsDeviceHeading ? "location.north.circle.fill"
                                                              : "location.fill",
                          tint: Theme.accent,
                          accessibilityLabel: "Моё местоположение") {
                recenter()
                revealControls()
            }
            // В поездке: «Радар здесь!» одним тапом — отметить передвижной радар
            // для других водителей (то же самое умеет Siri голосом).
            if env.location.isTripActive {
                CircleControl(systemName: "dot.radiowaves.left.and.right", tint: Theme.radar,
                              accessibilityLabel: "Радар здесь") {
                    guard let coordinate = env.location.currentCoordinate else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Task { await env.mobile.report(at: coordinate) }
                    revealControls()
                }
            }
            // Зум — щипком, как в Apple Maps: кнопки только занимали место.
        }
        .animation(.spring(duration: 0.3), value: env.location.isTripActive || env.route.isActive)
    }

    // MARK: - Низ: панель действий / режим добавления

    private var bottomLayer: some View {
        VStack(spacing: 10) {
            Spacer()
            if map.isAddingCamera {
                AddCameraBar(
                    onCancel: { map.isAddingCamera = false },
                    onAdd: { kind, name in addCamera(kind: kind, name: name) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let point = map.pressedPoint {
                MapPointBar(
                    onRoute: env.location.currentCoordinate == nil ? nil : {
                        buildRoute(to: point.coordinate, name: String(localized: "Точка на карте"))
                        withAnimation { map.pressedPoint = nil }
                    },
                    onRadar: {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        Task { await env.mobile.report(at: point.coordinate) }
                        withAnimation { map.pressedPoint = nil }
                    },
                    onOwnCamera: {
                        // Крестик режима добавления встаёт на выбранную точку —
                        // пользователь при желании доводит позицию вручную.
                        withAnimation {
                            map.pressedPoint = nil
                            map.position = .region(MKCoordinateRegion(
                                center: point.coordinate,
                                latitudinalMeters: 500, longitudinalMeters: 500))
                            map.isAddingCamera = true
                        }
                    },
                    onCancel: {
                        withAnimation { map.pressedPoint = nil }
                    }
                )
            } else {
                permissionBanner
                if !controlsHidden {
                    HStack(alignment: .bottom) {
                        smartLegend
                        Spacer()
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if env.location.isTripActive {
                    // В поездке: компактная строка (прибытие · остаток · камера · стоп) —
                    // максимум экрана отдан карте, и она не прячется вместе с кнопками.
                    TripLiveBar(
                        onShowCameras: { showRouteCameras = true },
                        onStop: { toggleTrip() }
                    )
                } else if env.route.isActive {
                    RoutePanel(
                        onShowCameras: { showRouteCameras = true },
                        onTripToggle: { toggleTrip() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !controlsHidden {
                    if env.route.isBuilding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Строим маршрут…")
                                .font(.rounded(12, .medium)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let error = env.route.errorMessage {
                        Text(error)
                            .font(.rounded(12, .medium)).foregroundStyle(Theme.danger)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .onTapGesture { env.route.clear() }
                    }
                    if !env.location.isTripActive && env.location.speedKmh >= AppConfig.speakSpeedThresholdKmh {
                        Text("Похоже, вы едете — включите оповещения")
                            .font(.rounded(12, .medium))
                            .foregroundStyle(Theme.success)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    // Одна линия: Дом и Работа компактной парой слева,
                    // «Начать поездку» занимает остальную ширину справа.
                    HStack(spacing: 10) {
                        PlaceCircle(slot: .home,
                                    onRoute: { coordinate, name in buildRoute(to: coordinate, name: name) },
                                    onAssign: { assignSlot = $0 })
                        PlaceCircle(slot: .work,
                                    onRoute: { coordinate, name in buildRoute(to: coordinate, name: name) },
                                    onAssign: { assignSlot = $0 })
                        tripButton
                    }
                }
                if !controlsHidden {
                    actionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.3), value: map.isAddingCamera)
        .animation(.spring(duration: 0.3), value: map.pressedPoint)
        .animation(.easeInOut(duration: 0.3), value: controlsHidden)
    }

    /// Долгий тап: маркер + бар действий (кроме режима прицела добавления камеры).
    private func selectPoint(at coordinate: CLLocationCoordinate2D) {
        guard !map.isAddingCamera else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(duration: 0.3)) {
            map.pressedPoint = MapPoint(coordinate: coordinate)
        }
        revealControls()
    }

    private func toggleTrip() {
        if env.location.isTripActive {
            env.location.endTrip()
        } else {
            env.location.startTrip()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Построить авто-маршрут от текущей позиции и показать все варианты целиком.
    private func buildRoute(to coordinate: CLLocationCoordinate2D, name: String) {
        guard let from = env.location.currentCoordinate else { return }
        Task {
            await env.route.build(from: from, to: coordinate, name: name,
                                  cameras: env.cameras.cameras,
                                  alternatives: env.settings.routeAlternatives)
            guard env.route.isActive else { return }
            env.settings.addRecent(title: name, lat: coordinate.latitude, lon: coordinate.longitude)
            // Охватываем ВСЕ варианты, чтобы выбор был виден сразу.
            var rect = MKMapRect.null
            for variant in env.route.variants { rect = rect.union(variant.polyline.boundingMapRect) }
            if !rect.isNull {
                headingUp = false
                let padded = rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.18)
                withAnimation(.easeInOut(duration: 0.5)) {
                    map.position = .rect(padded)
                }
                map.updateVisible(for: MKCoordinateRegion(padded))
            }
        }
    }

    /// CTA: градиент со световой кромкой сверху и двойной тенью — премиальный
    /// объём, высота 52 в линию с кругами Дом/Работа.
    private var tripButton: some View {
        Button {
            toggleTrip()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Начать поездку")
            }
            .font(.rounded(16, .bold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(colors: [Theme.success.opacity(0.98), Theme.success.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .shadow(color: Theme.success.opacity(0.35), radius: 14, y: 5)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            actionButton("Поиск", "magnifyingglass") { map.showSearch = true }
            actionButton("Добавить", "plus.circle.fill") {
                withAnimation { map.isAddingCamera = true }
            }
            actionButton("Рядом", "list.bullet") { map.showNearbySheet = true }
            actionButton("Итоги", "chart.bar.fill") { map.showStats = true }
            actionButton("Ещё", "gearshape.fill") { map.showSettings = true }
        }
        .padding(8)
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerLarge))
    }

    private func actionButton(_ title: LocalizedStringKey, _ icon: String, tint: Color = Theme.textPrimary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.rounded(18, .semibold))
                Text(title).font(.rounded(10, .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    /// Легенда-кнопка: свёрнута в компактный кружок, тап раскрывает на 6 секунд.
    @ViewBuilder private var smartLegend: some View {
        if legendExpanded {
            VStack(alignment: .leading, spacing: 8) {
                LegendChip(color: Theme.camera, symbol: "camera.fill", text: "Камера")
                LegendChip(color: Theme.radar, symbol: "speedometer", text: "Радар")
                LegendChip(color: Theme.intelligent, symbol: "camera.metering.matrix", text: "Интеллект.")
                LegendChip(color: Theme.mobile, symbol: "dot.radiowaves.left.and.right", text: "Передвижной")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .onTapGesture { toggleLegend() }
            .transition(.scale(scale: 0.7, anchor: .bottomLeading).combined(with: .opacity))
        } else {
            Button {
                toggleLegend()
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.rounded(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .transition(.scale(scale: 0.7, anchor: .bottomLeading).combined(with: .opacity))
        }
    }

    private func toggleLegend() {
        legendCollapseTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { legendExpanded.toggle() }
        if legendExpanded {
            legendCollapseTask = Task {
                await Task.pause(seconds: 6)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.35)) { legendExpanded = false }
            }
        }
    }

    @ViewBuilder private var permissionBanner: some View {
        if let banner = bannerInfo {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.radar)
                Text(banner.message).font(.rounded(12)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(banner.button, action: banner.action)
                    .font(.rounded(12, .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        }
    }

    @ViewBuilder private var loadErrorOverlay: some View {
        if let error = env.loadError {
            ContentUnavailableView("Не удалось загрузить камеры",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        }
    }

    // MARK: - Действия

    private func addCamera(kind: AddKind, name: String) {
        guard let center = map.mapCenter else {
            withAnimation { map.isAddingCamera = false }
            return
        }
        switch kind {
        case .camera, .radar:
            let type: CameraType = kind == .radar ? .stationaryRadar : .stationaryCamera
            env.cameras.addCamera(at: center, type: type, label: name)   // revision → onChange обновит карту
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .mobile:
            Task {
                let result = await env.mobile.report(at: center)
                UINotificationFeedbackGenerator()
                    .notificationOccurred(result == .failed ? .error : .success)
            }
        }
        withAnimation { map.isAddingCamera = false }
    }

    private func recenter() {
        if headingUp {
            map.follow(coordinate: env.location.currentCoordinate, course: env.location.currentCourse, pitched: env.location.isTripActive)
            return
        }
        // Как в Apple Maps: первый тап — центр на себе; второй — карта крутится
        // сама за компасом устройства (куда повернул телефон, туда и карта).
        if map.position.followsUserLocation && !map.followsDeviceHeading {
            map.followsDeviceHeading = true
            withAnimation(.easeInOut(duration: 0.35)) {
                map.position = .userLocation(followsHeading: true,
                                             fallback: .region(AppConfig.uzbekistanRegion))
            }
        } else {
            map.followsDeviceHeading = false
            withAnimation(.easeInOut(duration: 0.35)) {
                map.position = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))
            }
        }
        // Целевой регион известен только когда есть геопозиция — подгружаем окрестности сами.
        if let coordinate = env.location.currentCoordinate {
            map.refreshVisible(around: coordinate, widthMeters: 3000)
        }
    }

    private var bannerInfo: (message: String, button: String, action: () -> Void)? {
        switch env.location.authorizationStatus {
        case .denied, .restricted:
            return (String(localized: "Геолокация выключена. Включите «Всегда» для оповещений о камерах."),
                    String(localized: "Настройки"), openSettings)
        case .authorizedWhenInUse:
            return (String(localized: "Для фоновых оповещений выберите доступ «Всегда»."),
                    String(localized: "Настройки"), openSettings)
        default:
            break
        }
        if env.location.isAuthorized && !env.location.hasFullAccuracy {
            return (String(localized: "Включена приблизительная геолокация — оповещения о камерах будут неточными."),
                    String(localized: "Включить точную"), { env.location.requestPreciseLocation() })
        }
        if env.notifications.authorizationStatus == .denied {
            return (String(localized: "Уведомления выключены — вы не услышите сигнал о камере."),
                    String(localized: "Настройки"), openSettings)
        }
        return nil
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    #if DEBUG
    /// Скриншот-автоматизация (симулятор): `simctl launch <app> -showStats | -showSettings |
    /// -showCameraDetail` открывает нужный экран без тапов. В релизную сборку не попадает.
    private func openScreenFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-showStats") { map.showStats = true }
        if args.contains("-showSettings") { map.showSettings = true }
        if args.contains("-showCameraDetail") {
            Task {
                await Task.pause(seconds: 1.5)
                if let coordinate = env.location.currentCoordinate,
                   let camera = env.cameras.nearest(to: coordinate, limit: 1).first {
                    map.select(camera)
                }
            }
        }
        // Детерминированный тест навигации: строим маршрут к фиксированной точке
        // Ташкента (просп. Амира Темура) от текущей позиции. С -driveDemo сразу
        // стартуем поездку (как «Поехали») — для прогонки движения по маршруту.
        // Повернуть карту (компас должен появиться): жестов у simctl нет.
        if args.contains("-rotateMap") {
            Task {
                // После snapToUserOnce (тот перебил бы позицию своим регионом).
                await Task.pause(seconds: 6)
                guard let center = env.location.currentCoordinate else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    map.position = .camera(MapCamera(centerCoordinate: center,
                                                     distance: 1200, heading: 45))
                }
            }
        }
        // Шеринг-карточки в PNG (Documents) — визуальная проверка без share-шита.
        if args.contains("-dumpShareCards") {
            Task {
                await Task.pause(seconds: 2)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let last = env.trip.fallbackRecord(isTripActive: env.location.isTripActive)
                    ?? env.trip.history.first
                let map = await TripMapSnapshot.render(track: last?.trackPoints ?? [],
                                                       passes: last?.passed ?? [],
                                                       size: CGSize(width: 1032, height: 420))
                let stats = ImageRenderer(content: StatsShareCard(trip: env.trip, mapImage: map))
                stats.scale = 2
                stats.proposedSize = ProposedViewSize(width: 540, height: 675)
                try? stats.uiImage?.pngData()?.write(to: docs.appendingPathComponent("share_stats.png"))
                if let record = last {
                    let tripMap = await TripMapSnapshot.render(track: record.trackPoints,
                                                               passes: record.passed,
                                                               size: CGSize(width: 1032, height: 840))
                    let card = ImageRenderer(content: TripShareCard(record: record, mapImage: tripMap))
                    card.scale = 2
                    card.proposedSize = ProposedViewSize(width: 540, height: 675)
                    try? card.uiImage?.pngData()?.write(to: docs.appendingPathComponent("share_trip.png"))
                }
            }
        }
        // Бар точки долгого тапа: жест на симуляторе из CLI не сымитировать.
        if args.contains("-mapMenu") {
            Task {
                await Task.pause(seconds: 3)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    selectPoint(at: center)
                }
            }
        }
        if args.contains("-demoRoute") {
            Task {
                await Task.pause(seconds: 2)
                buildRoute(to: CLLocationCoordinate2D(latitude: 41.3260, longitude: 69.2810),
                           name: "Демо-маршрут")
                if args.contains("-driveDemo") {
                    await Task.pause(seconds: 3)
                    if env.route.isActive {
                        headingUp = true
                        env.location.startTrip()
                    }
                    // Автозавершение поездки через N секунд: на симуляторе нет
                    // CoreMotion (автостоп не сработает) и нет тапов — а для
                    // проверки Итогов/шеринга нужна завершённая запись в истории.
                    if let idx = args.firstIndex(of: "-endTripAfter"),
                       let seconds = args.dropFirst(idx + 1).first.flatMap(Double.init) {
                        await Task.pause(seconds: seconds)
                        env.location.endTrip()
                        headingUp = false
                    }
                }
            }
        }
    }
    #endif
}
