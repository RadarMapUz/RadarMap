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

import CoreLocation
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
                    // Радиус — ЭФФЕКТИВНЫЙ, а не базовый из настроек. С базовым
                    // кольцо приближения показывало ноль, пока водитель не
                    // въедет в 400 м, хотя предупреждение уже прозвучало на
                    // 794 (130 км/ч). Одиннадцать секунд экран говорил «ещё
                    // далеко» про камеру, о которой уже сказал голос.
                    alertRadius: env.location.effectiveAlertRadius,
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
/// Что показать внизу экрана — ОДНО, а не всё сразу.
///
/// Плашки заводились по одной и каждая права по отдельности: ошибка маршрута,
/// «строим», подсказка о поездке, предложение назначения. Вместе они делят
/// внимание на четыре, и делят его за рулём — там, где на взгляд есть доля
/// секунды.
///
/// Правило простое и оно тут одно на всех: **то, что требует решения, старше
/// того, что сообщает**. Ошибка маршрута ждёт ответа, «строим» сообщает о
/// работе, подсказка о поездке предлагает, назначение — догадка.
nonisolated enum BottomHint: Equatable {
    case none
    case routeError(String)
    case building
    case driving
    case destinations

    /// `isProbablyDriving` — грубый флаг из LocationService, а не сырая
    /// скорость. Скорость пишется каждым фиксом, и её чтение в теле экрана
    /// делало пересборку главного экрана ежесекундной ради строки, которая
    /// меняется раз в поездку. Флаг уже учитывает и поездку, и гистерезис.
    static func choose(routeError: String?, isBuilding: Bool,
                       isProbablyDriving: Bool,
                       showsQuickDestinations: Bool) -> BottomHint {
        if let routeError, !routeError.isEmpty { return .routeError(routeError) }
        if isBuilding { return .building }
        if isProbablyDriving { return .driving }
        if showsQuickDestinations { return .destinations }
        return .none
    }
}

struct DrivingHintChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.location.isProbablyDriving {
            Text("Похоже, вы едете — включите оповещения")
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// «Радар ещё стоял?» на карте. Условие «накрыто» читает пер-тиковую
/// isApproachingCamera (внутри — дистанция и скорость, пишутся каждым фиксом):
/// вычисленное В BODY MapScreen оно делало весь экран с двумя сотнями
/// маркеров заложником тика — глазами читалось как булев флаг, а было
/// подпиской на каждый метр.
struct MobileConfirmGate: View {
    @Environment(AppEnvironment.self) private var env
    var dashboardShown: Bool

    var body: some View {
        MobileConfirmBar(isCovered: env.location.isApproachingCamera || dashboardShown)
    }
}

/// «Что это было?» на карте — та же дисциплина, что у MobileConfirmGate:
/// пер-тиковую isApproachingCamera читает гейт, а не body MapScreen.
struct ReportRefineGate: View {
    @Environment(AppEnvironment.self) private var env
    var dashboardShown: Bool

    var body: some View {
        ReportRefineBar(isCovered: env.location.isApproachingCamera || dashboardShown)
    }
}

/// Проезд чужой передвижной отметки → вопрос «ещё стоял?». Тик читается
/// здесь: onChange(locationTick) прямо в MapScreen был второй независимой
/// подпиской body на тик — с ним тишина follow ничего не давала.
struct MobilePassDriver: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: env.location.locationTick) {
                guard let coordinate = env.location.currentCoordinate else { return }
                withAnimation { env.mobile.trackPasses(from: coordinate) }
            }
    }
}



struct LocationFollowDriver: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState
    /// Карта накрыта приборкой: fullScreenCover прячет её только зрительно,
    /// а follow продолжал каждый тик анимировать камеру и грузить тайлы под
    /// крышкой — замер дал столько же CPU, сколько у открытой карты, и вся
    /// экономия приборки сводилась к яркости пикселей. На паузе не следим;
    /// снятие крышки догоняет позицию первым же тиком.
    var isCovered = false

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: env.location.locationTick) { _, _ in
                guard !isCovered else { return }
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
