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
        .motionAnimation(.easeInOut(duration: 0.25), value: env.location.isApproachingCamera)
        .allowsHitTesting(false)
    }
}

/// Полноэкранное предупреждение о камере (со своим «закрыть до следующей»).
struct ApproachOverlayGate: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var dismissedID: Int?
    var onCardEdge: (CGFloat?) -> Void = { _ in }
    var onTopCardEdge: (CGFloat?) -> Void = { _ in }

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
                    // То же правило, что у баннера манёвра (ManeuverBannerGate):
                    // карточка снизу — ровно когда манёвр на экране; при
                    // выборе маршрута — сверху, над «Поехали» (28.K).
                    layout: .current(isTripActive: env.location.isTripActive,
                                     hasRoute: env.route.isActive,
                                     isBuildingRoute: env.route.isBuilding),
                    onCardEdge: onCardEdge,
                    onTopCardEdge: onTopCardEdge,
                    onDismiss: { dismissedID = camera.id }
                )
                // Экран тревоги тёмный при любой теме: на полностью затемнённой
                // карте крупная цифра и цвет типа читаются за долю секунды, а
                // белая простыня посреди дня ослепляла бы.
                .environment(\.colorScheme, .dark)
            }
        }
        .motionAnimation(.easeInOut(duration: 0.25), value: env.location.isApproachingCamera)
    }
}

/// Баннер ближайшего манёвра: дистанция до него меняется каждый тик.
struct ManeuverBannerGate: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let mode = MapMode.current(isTripActive: env.location.isTripActive,
                                   hasRoute: env.route.isActive)
        ZStack {
            if mode.showsManeuver {
                VStack(spacing: 8) {
                    if let step = env.route.nextStep {
                        ManeuverBanner(step: step, distance: env.route.nextStepDistance,
                                       speedKmh: env.location.speedKmh, then: env.route.thenStep)
                    }
                    if let notice = env.route.laneNotice {
                        LaneNoticeBanner(lanes: notice.lanes, distance: env.route.laneNoticeDistance)
                    }
                }
            }
        }
        .motionAnimation(Motion.standard, value: env.route.nextStep?.distanceAlong)
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

/// Догадка «едем» вместе с самим действием. До 19.10 это была подпись
/// «включите оповещения» без кнопки — и она ВЫТЕСНЯЛА «Начать поездку»
/// (нижняя ветка одна: `.driving` вместо `.destinations`): приложение звало
/// включить оповещения ровно тогда, когда нажать было нечего.
struct DrivingHintChip: View {
    @Environment(AppEnvironment.self) private var env
    let onStart: () -> Void

    var body: some View {
        if env.location.isProbablyDriving {
            VStack(spacing: 8) {
                Text("Похоже, вы едете")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                PrimaryButton(title: "Начать поездку", systemImage: "play.fill", action: onStart)
                    .liftAccent()
            }
        }
    }
}

/// Подъехали к камере — плитки «Ещё» внизу закрываются (MapPopover.cameraAlert).
/// «Камера на подходе» читает пер-тиковые дистанцию и скорость — поэтому здесь.
struct CameraAlertWatch: View {
    @Environment(AppEnvironment.self) private var env
    let onApproach: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: env.location.isApproachingCamera) { _, approaching in
                if approaching { onApproach() }
            }
    }
}

struct LocationFollowDriver: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: env.location.locationTick) { _, _ in
                // Прогресс маршрута (прибытие/манёвры) тикает в LocationService,
                // ведение камеры — у движка (EngineMapView); здесь только первый
                // фикс и точка отсчёта важности маркеров.
                if let coordinate = env.location.currentCoordinate {
                    map.snapToUserOnce(coordinate)   // первый фикс после запуска → окрестности
                    // Точка отсчёта важности маркеров: сама себя троттлит.
                    map.updateFocus(coordinate)
                }
            }
    }
}
