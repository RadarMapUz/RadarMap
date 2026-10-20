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
                    // карточка — ровно когда манёвр на экране.
                    layout: .choose(navigating: MapMode.current(isTripActive: env.location.isTripActive,
                                                                hasRoute: env.route.isActive).showsManeuver),
                    onCardEdge: onCardEdge,
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
                                       speedKmh: env.location.speedKmh)
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

/// «Радар ещё стоял?» и «Ещё перекрыто?» на карте. Условие «накрыто» читает пер-тиковую
/// isApproachingCamera (внутри — дистанция и скорость, пишутся каждым фиксом):
/// вычисленное В BODY MapScreen оно делало весь экран с двумя сотнями
/// маркеров заложником тика — глазами читалось как булев флаг, а было
/// подпиской на каждый метр.
struct MobileConfirmGate: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let covered = env.location.isApproachingCamera
        // Один вопрос за раз: радар первым, «ещё перекрыто?» — когда о радаре
        // спрашивать нечего (MobileCameraService.passQuestion).
        Group {
            if env.mobile.pendingConfirm != nil {
                MobileConfirmBar(isCovered: covered)
            } else {
                RoadEventConfirmBar(isCovered: covered)
            }
        }
        .onAppear { env.mobile.expireStaleConfirm() }
        .motionAnimation(Motion.standard, value: env.mobile.passQuestion?.id)
    }
}

/// «Что это было?» на карте — та же дисциплина, что у MobileConfirmGate:
/// пер-тиковую isApproachingCamera читает гейт, а не body MapScreen.
struct ReportRefineGate: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ReportRefineBar(isCovered: env.location.isApproachingCamera)
    }
}



/// «Опаздываю — предупредить?» (8.8.14): пер-тиковые скорость и «накрыто
/// камерой» читает гейт, а не body MapScreen (та же дисциплина, что выше).
struct GhostLateGate: View {
    @Environment(AppEnvironment.self) private var env
    /// Лист «Поделиться» показывает экран карты, а не плашка: плашка уходит
    /// сразу после тапа, и лист, привязанный к ней, ушёл бы вместе с ней.
    let onShare: (String) -> Void

    var body: some View {
        let live = env.commuteLive
        if let ghost = live.display, let slack = ghost.slack,
           CommuteLiveService.showsLatePlaque(slack: slack.shown, done: live.latePlaqueDone,
                                              shown: live.latePlaqueShown,
                                              speedKmh: env.location.speedKmh,
                                              coveredByCamera: env.location.isApproachingCamera) {
            GhostLatePlaque(ghost: ghost,
                            onShare: { text in
                                live.dismissLatePlaque()
                                onShare(text)
                            },
                            onDone: { live.dismissLatePlaque() })
                .onAppear { live.markLatePlaqueShown() }
                .task {
                    // Не ответили — уходит сама: напоминать весь остаток пути незачем.
                    try? await Task.sleep(for: .seconds(AppConfig.commuteLatePromptSeconds))
                    guard !Task.isCancelled else { return }
                    live.dismissLatePlaque()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Плашка: «на 7 мин позже 9:00 — предупредить?» и лист «Поделиться» с
/// текстом прибытия. Ничего на сервер: это обычное сообщение от водителя.
struct GhostLatePlaque: View {
    let ghost: CommuteLiveService.Display
    let onShare: (String) -> Void
    let onDone: () -> Void

    /// Часы — по языку приложения, как в заголовке плашки (CommuteGhost.clock).
    private var message: String {
        let clock = CommuteGhost.clock(ghost.arrival)
        return String(localized: "Задерживаюсь: буду примерно в \(clock).")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.warning)
                .frame(width: 34, height: 34)
                .background(Theme.warning.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: GhostText.headline(ghost))
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Предупредить, что задерживаетесь?")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            // Значок «поделиться», а не слово: «Предупредить» в узкой кнопке
            // переносилось по слогам (снимок 20.10); смысл несёт строка слева.
            Button { onShare(message) } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.onAccentFill)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Предупредить"))
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.rounded(13, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Скрыть"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
    }
}

struct LocationFollowDriver: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState
    /// Камера карты Apple на экране. Когда подложка — движок, у него своё
    /// ведение; follow здесь двигал невидимую карту Apple и пересобирал её
    /// аннотации каждый тик (docs/perf_audit_2026-10-07.md).
    var drivesAppleCamera = true

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: env.location.locationTick) { _, _ in
                // Прогресс маршрута (прибытие/манёвры) тикает в LocationService —
                // здесь только следование карты за курсом. Вне поездки поворот
                // по компасу телефона делает сам MapKit (.userLocation
                // followsHeading), догонять его тиками не нужно.
                if drivesAppleCamera, map.orientation == .heading, env.location.isTripActive {
                    // Прижатые к дороге координата и курс: камера карты ведёт
                    // по полотну, а не по гуляющему вбок GPS. Скорость — для
                    // автозума (стоишь — ближе, летишь — шире).
                    map.follow(coordinate: env.location.displayCoordinate
                                   ?? env.location.currentCoordinate,
                               course: env.location.displayCourse >= 0
                                   ? env.location.displayCourse
                                   : env.location.currentCourse,
                               speedKmh: env.location.speedKmh,
                               pitched: map.prefers3D)
                }
                if let coordinate = env.location.currentCoordinate {
                    map.snapToUserOnce(coordinate)   // первый фикс после запуска → окрестности
                    // Точка отсчёта важности маркеров: сама себя троттлит.
                    map.updateFocus(coordinate)
                }
            }
    }
}
