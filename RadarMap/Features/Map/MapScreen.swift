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
    @State private var legendExpanded = false
    @State private var legendCollapseTask: Task<Void, Never>?

    var body: some View {
        @Bindable var map = map

        ZStack {
            mapLayer.ignoresSafeArea()

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
        }
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
            SearchView(onSelect: { map.move(to: $0) },
                       onRoute: { coord, name in buildRoute(to: coord, name: name) })
        }
        .sheet(isPresented: $showRouteCameras) {
            RouteCamerasSheet(onSelect: { map.focus(on: $0) })
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

    private var mapLayer: some View {
        Map(position: $map.position) {
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
                    // Средний зум: точки; полный пин — у выбранной и ближайшей по курсу.
                    CameraAnnotationView(
                        camera: camera,
                        selected: map.highlightedID == camera.id,
                        compact: map.isDotZoom
                            && camera.id != env.location.nearestCamera?.id
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
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        // Системный компас вылезал под статус-бар в правом верхнем углу —
        // прячем, свой (по повороту карты) живёт в колонке контролов.
        .mapControls {}
        .onMapCameraChange(frequency: .onEnd) { context in
            map.updateVisible(for: context.region)
            map.currentHeading = context.camera.heading
        }
        // Любое касание карты будит спрятанные кнопки (не мешая тапам по маркерам).
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
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
            SpeedHUDView()
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
            CircleControl(systemName: "location.fill", tint: Theme.accent,
                          accessibilityLabel: "Моё местоположение") {
                recenter()
                revealControls()
            }
            // Свой компас: появляется, только когда карта повёрнута (как в Apple Maps),
            // тап — севером вверх. Системный вылезал под статус-бар.
            if !headingUp, abs(map.currentHeading) > 5 {
                Button {
                    map.resetNorth()
                    revealControls()
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.rounded(16, .bold))
                        .foregroundStyle(Theme.danger)
                        .rotationEffect(.degrees(-map.currentHeading))
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .accessibilityLabel(Text("Севером вверх"))
                .transition(.scale.combined(with: .opacity))
            }
            // Зум — щипком, как в Apple Maps: кнопки только занимали место.
        }
        .animation(.spring(duration: 0.3), value: env.location.isTripActive || env.route.isActive)
        .animation(.spring(duration: 0.3), value: abs(map.currentHeading) > 5)
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
                    tripButton
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
        .animation(.easeInOut(duration: 0.3), value: controlsHidden)
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

    /// Компактная капсула: при автостарте кнопка почти не нужна — не даём ей кричать.
    private var tripButton: some View {
        Button {
            toggleTrip()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Начать поездку")
            }
            .font(.rounded(15, .bold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(Theme.success.gradient, in: Capsule())
            .shadow(color: Theme.success.opacity(0.4), radius: 10, y: 3)
        }
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
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerLarge))
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
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                map.position = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))
            }
            // Целевой регион известен только когда есть геопозиция — подгружаем окрестности сами.
            if let coordinate = env.location.currentCoordinate {
                map.refreshVisible(around: coordinate, widthMeters: 3000)
            }
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
                }
            }
        }
    }
    #endif
}
