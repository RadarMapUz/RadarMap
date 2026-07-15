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
    @State private var vm = MapViewModel()
    @State private var dismissedApproachID: Int?
    @State private var headingUp = false
    @State private var showRouteCameras = false

    var body: some View {
        @Bindable var vm = vm

        ZStack {
            mapLayer.ignoresSafeArea()

            if vm.isAddingCamera { crosshair }

            topLayer
            if !vm.isAddingCamera { controlColumn }
            bottomLayer
        }
        .task {
            vm.configure(env.cameras)
            vm.filter = env.settings.filter
            // Если карта уже отдала регион до конфигурации (статичный старт без геопозиции) —
            // пересчитываем принудительно, иначе аннотации не появятся до первого движения карты.
            vm.invalidateVisible()
        }
        .onChange(of: env.settings.filter) { _, newValue in
            vm.filter = newValue
            vm.invalidateVisible()
        }
        .onChange(of: env.cameras.revision) { _, _ in
            // Любое изменение данных (загрузка базы, свои камеры, скрытие) —
            // одна точка обновления карты и region-мониторинга.
            vm.invalidateVisible()
            env.location.refreshMonitoring()
        }
        .sheet(item: $vm.selectedCamera) { camera in
            CameraDetailSheet(camera: camera,
                              onRoute: env.location.currentCoordinate == nil ? nil : {
                                  buildRoute(to: camera.coordinate, name: camera.displayTitle)
                              })
        }
        .sheet(isPresented: $vm.showNearbySheet) {
            NearbyCamerasSheet(onSelect: { vm.focus(on: $0) })
        }
        .sheet(isPresented: $vm.showSearch) {
            SearchView(onSelect: { vm.move(to: $0) },
                       onRoute: { coord, name in buildRoute(to: coord, name: name) })
        }
        .sheet(isPresented: $showRouteCameras) {
            RouteCamerasSheet(onSelect: { vm.focus(on: $0) })
        }
        .sheet(isPresented: $vm.showSettings) { SettingsView() }
        .sheet(isPresented: $vm.showStats) {
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
        }
        .onChange(of: env.location.locationTick) { _, _ in
            // Прогресс маршрута (прибытие/манёвры/камеры) тикает в LocationService —
            // здесь только следование карты за курсом.
            if headingUp {
                vm.follow(coordinate: env.location.currentCoordinate, course: env.location.currentCourse, pitched: env.location.isTripActive)
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
        Map(position: $vm.position) {
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

            ForEach(vm.visibleCameras) { camera in
                Annotation(camera.displayTitle, coordinate: camera.coordinate, anchor: .center) {
                    CameraAnnotationView(camera: camera, selected: vm.highlightedID == camera.id)
                        .onTapGesture { vm.select(camera) }
                }
                .annotationTitles(.hidden)
            }
            ForEach(vm.clusters) { cluster in
                Annotation("\(cluster.count)", coordinate: cluster.coordinate, anchor: .center) {
                    ClusterAnnotationView(count: cluster.count)
                        .onTapGesture { vm.zoomInto(cluster) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .onMapCameraChange(frequency: .onEnd) { context in
            vm.updateVisible(for: context.region)
        }
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
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.3), value: env.route.nextStep?.distanceAlong)
    }

    // MARK: - Правая колонка навигации

    private var controlColumn: some View {
        VStack(spacing: 12) {
            CircleControl(systemName: headingUp ? "location.north.line.fill" : "location.north.line",
                          tint: headingUp ? Theme.accent : Theme.textPrimary) {
                headingUp.toggle()
                if headingUp {
                    vm.follow(coordinate: env.location.currentCoordinate, course: env.location.currentCourse, pitched: env.location.isTripActive)
                }
            }
            CircleControl(systemName: "location.fill", tint: Theme.accent) { recenter() }
            VStack(spacing: 1) {
                CircleControl(systemName: "plus") { vm.zoom(0.5) }
                CircleControl(systemName: "minus") { vm.zoom(2.0) }
            }
        }
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    // MARK: - Низ: панель действий / режим добавления

    private var bottomLayer: some View {
        VStack(spacing: 10) {
            Spacer()
            if vm.isAddingCamera {
                AddCameraBar(
                    onCancel: { vm.isAddingCamera = false },
                    onAdd: { kind, name in addCamera(kind: kind, name: name) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                permissionBanner
                HStack(alignment: .bottom) {
                    legend
                    Spacer()
                }
                if env.route.isActive {
                    RoutePanel(
                        onShowCameras: { showRouteCameras = true },
                        onTripToggle: { toggleTrip() }
                    )
                } else {
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
                actionBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.3), value: vm.isAddingCamera)
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
                withAnimation(.easeInOut(duration: 0.5)) {
                    vm.position = .rect(rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.18))
                }
            }
        }
    }

    private var tripButton: some View {
        Button {
            toggleTrip()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: env.location.isTripActive ? "stop.fill" : "play.fill")
                Text(env.location.isTripActive ? "Завершить поездку" : "Начать поездку")
            }
            .font(.rounded(17, .bold))
            .foregroundStyle(env.location.isTripActive ? .white : Theme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(env.location.isTripActive ? Theme.danger : Theme.success,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .shadow(color: (env.location.isTripActive ? Theme.danger : Theme.success).opacity(0.45),
                    radius: 12, y: 4)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            actionButton("Поиск", "magnifyingglass") { vm.showSearch = true }
            actionButton("Добавить", "plus.circle.fill", tint: Theme.accent) {
                withAnimation { vm.isAddingCamera = true }
            }
            actionButton("Рядом", "list.bullet") { vm.showNearbySheet = true }
            actionButton("Итоги", "chart.bar.fill") { vm.showStats = true }
            actionButton("Ещё", "gearshape.fill") { vm.showSettings = true }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
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

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            LegendChip(color: Theme.camera, symbol: "camera.fill", text: "Камера")
            LegendChip(color: Theme.radar, symbol: "speedometer", text: "Радар")
            LegendChip(color: Theme.intelligent, symbol: "camera.metering.matrix", text: "Интеллект.")
            LegendChip(color: Theme.mobile, symbol: "dot.radiowaves.left.and.right", text: "Передвижной")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
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
        guard let center = vm.mapCenter else {
            withAnimation { vm.isAddingCamera = false }
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
        withAnimation { vm.isAddingCamera = false }
    }

    private func recenter() {
        if headingUp {
            vm.follow(coordinate: env.location.currentCoordinate, course: env.location.currentCourse, pitched: env.location.isTripActive)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                vm.position = .userLocation(fallback: .region(AppConfig.uzbekistanRegion))
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
}
