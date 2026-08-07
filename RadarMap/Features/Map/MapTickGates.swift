//
//  MapTickGates.swift
//  RadarMap
//
//  Изоляторы пер-тиковых чтений главного экрана.
//
//  Эти вью существуют ради одного: они ЕДИНСТВЕННЫЕ на экране карты читают
//  свойства, которые LocationService/RouteService обновляют каждый GPS-тик
//  (скорость, дистанции). Пока такие чтения жили в body MapScreen, каждый фикс
//  пересобирал весь экран вместе с картой и двумя сотнями маркеров — это и был
//  главный лаг приложения.
//
//  Правило, которое охраняет этот файл: новое чтение пер-тикового свойства на
//  экране карты добавляется СЮДА, отдельной маленькой вью, — а не в body
//  MapScreen. Пересборка маленькой вью стоит ничего; пересборка MapScreen
//  стоит карты целиком.
//

import SwiftUI

/// Красное свечение по краям при превышении у камеры.
struct OverspeedVignetteGate: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            if env.location.isApproachingCamera && env.speedLimits.isOverspeeding {
                OverspeedVignette()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.location.isApproachingCamera)
        .allowsHitTesting(false)
    }
}

/// Полноэкранное предупреждение о камере (со своим «закрыть до следующей»).
struct ApproachOverlayGate: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var dismissedID: Int?

    var body: some View {
        ZStack {
            if env.location.isApproachingCamera,
               let camera = env.location.nearestCamera,
               let distance = env.location.distanceToNearest,
               dismissedID != camera.id {
                ApproachAlertView(
                    camera: camera,
                    distance: distance,
                    speedKmh: env.location.speedKmh,
                    relativeBearing: env.location.relativeBearingToNearest,
                    alertRadius: env.settings.alertRadius,
                    onDismiss: { dismissedID = camera.id }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.location.isApproachingCamera)
    }
}

/// Баннер ближайшего манёвра: дистанция до него меняется каждый тик.
struct ManeuverBannerGate: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let mode = MapMode.current(isTripActive: env.location.isTripActive,
                                   hasRoute: env.route.isActive)
        ZStack {
            if mode.showsManeuver, let step = env.route.nextStep {
                ManeuverBanner(step: step, distance: env.route.nextStepDistance)
            }
        }
        .animation(.spring(duration: 0.3), value: env.route.nextStep?.distanceAlong)
    }
}

/// «Похоже, вы едете» — подсказка включить оповещения; условие читает скорость.
struct DrivingHintChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if !env.location.isTripActive
            && env.location.speedKmh >= AppConfig.speakSpeedThresholdKmh {
            Text("Похоже, вы едете — включите оповещения")
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Следование карты за GPS: единственный подписчик locationTick.
struct LocationFollowDriver: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: env.location.locationTick) { _, _ in
                // Прогресс маршрута (прибытие/манёвры) тикает в LocationService —
                // здесь только следование карты за курсом. Вне поездки поворот
                // по компасу телефона делает сам MapKit (.userLocation
                // followsHeading), догонять его тиками не нужно.
                if map.orientation == .heading, env.location.isTripActive {
                    // Прижатые к дороге координата и курс: камера карты ведёт
                    // по полотну, а не по гуляющему вбок GPS. Скорость — для
                    // автозума (стоишь — ближе, летишь — шире).
                    map.follow(coordinate: env.location.displayCoordinate
                                   ?? env.location.currentCoordinate,
                               course: env.location.displayCourse >= 0
                                   ? env.location.displayCourse
                                   : env.location.currentCourse,
                               speedKmh: env.location.speedKmh,
                               pitched: true)
                }
                if let coordinate = env.location.currentCoordinate {
                    map.snapToUserOnce(coordinate)   // первый фикс после запуска → окрестности
                    // Точка отсчёта важности маркеров: сама себя троттлит.
                    map.updateFocus(coordinate)
                }
            }
    }
}
