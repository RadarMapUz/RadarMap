//
//  CarPlayMapScreen.swift
//  RadarMap
//
//  Экран CarPlay: тёмная карта с камерами и маршрутом + приборная панель.
//
//  Раньше данные жили тремя плашками в разных углах — взгляд метался по экрану.
//  Теперь всё, что нужно постоянно (скорость, лимит, ближайшая камера, прибытие),
//  собрано в одну полосу внизу слева фиксированной высоты: карта не прыгает,
//  а глаз всегда знает, куда смотреть. Сверху — только события: манёвр слева
//  и алерт приближения справа.
//

import SwiftUI
import MapKit

/// Сигналы от кнопок шаблона CarPlay к карте (счётчики — представление
/// обрабатывает дельту и не хранит состояния шаблона).
@MainActor
@Observable
final class CarPlayMapModel {
    var recenterRequests = 0
    var zoomInRequests = 0
    var zoomOutRequests = 0
    /// «Схема» вместо карты: MKMapView выгружается ЦЕЛИКОМ. Картинка в машину
    /// стримится с телефона, так что тайлы и аннотации греют именно телефон —
    /// схема снимает самый дорогой рендер, оставляя те же предупреждения.
    var showsSketch: Bool
    /// Режим выбран рукой водителя: автоматика жары его больше не трогает
    /// (та же иерархия, что у кнопки тишины: человек старше автоматики).
    @ObservationIgnored var userChoseView: Bool

    init() {
        showsSketch = Storage.bool(.carPlayShowsSketch)
        userChoseView = Storage.bool(.carPlayViewChosen)
        #if DEBUG
        // Скриншот-хук: -carplayPreview -carplaySketch открывает сразу схему.
        if ProcessInfo.processInfo.arguments.contains("-carplaySketch") {
            showsSketch = true
            userChoseView = true
        }
        #endif
    }

    /// Тумблер с кнопки шаблона: выбор запоминается между поездками.
    func toggleView() {
        showsSketch.toggle()
        userChoseView = true
        Storage.set(showsSketch, for: .carPlayShowsSketch)
        Storage.set(true, for: .carPlayViewChosen)
    }

    /// Автоматика жары: телефон греется — включаем схему, остыл — возвращаем
    /// карту. Только пока водитель не выбрал режим сам.
    func autoSwitch(for mode: PerformanceMode) {
        guard !userChoseView else { return }
        showsSketch = mode != .full
    }
}

struct CarPlayMapScreen: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        ZStack {
            if model.showsSketch {
                CarPlaySketchView()
            } else {
                CarPlayMapView(model: model,
                               repository: env.cameras,
                               route: env.route,
                               location: env.location,
                               speedLimits: env.speedLimits)
                    .ignoresSafeArea()
            }

            overlay
        }
        // Жара: схема сама, пока водитель не выбрал режим кнопкой. Проверка и
        // на подключении тоже — в машину можно сесть с уже горячим телефоном.
        .onAppear { model.autoSwitch(for: env.thermal.mode) }
        .onChange(of: env.thermal.mode) { _, mode in
            withAnimation(.easeInOut(duration: 0.3)) { model.autoSwitch(for: mode) }
        }
    }

    // MARK: - Раскладка

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if let step = env.route.nextStep {
                    maneuverBanner(step: step, distance: env.route.nextStepDistance)
                }
                Spacer(minLength: 0)
                if let camera = env.location.nearestCamera,
                   let distance = env.location.distanceToNearest,
                   env.location.isApproachingCamera {
                    approachBanner(camera: camera, distance: distance)
                }
            }
            // Жара: бюджеты уже урезаны (маркеры карты, сеть схемы) — но молча.
            // Тот же чип честности, что на приборке телефона.
            if env.thermal.mode != .full {
                HStack {
                    Label("Жарко — экономлю экран", systemImage: "thermometer.sun.fill")
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.background.opacity(0.88), in: Capsule())
                        .overlay(Capsule().stroke(Theme.warning.opacity(0.35), lineWidth: 1))
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                dock
                Spacer(minLength: 0)
            }
        }
        // Колонку своих кнопок CarPlay кладёт в safe area, и сторона зависит от
        // системы машины. Раньше здесь стоял отступ 76 pt справа — в машине с
        // кнопками слева панель уехала бы прямо под них.
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .safeAreaPadding(.horizontal)
        .animation(.spring(duration: 0.35), value: env.location.isApproachingCamera)
        .animation(.spring(duration: 0.35), value: env.route.isActive)
        // HUD — только показывает: жесты карты (тап, панорама, щипок) должны
        // проходить сквозь него в MKMapView.
        .allowsHitTesting(false)
    }

    // MARK: - Приборная панель

    /// Полоса внизу: скорость | ближайшая камера | прибытие. Высота фиксирована
    /// (AppConfig.carPlayDockHeight) — на эту же величину карта поджимает свои
    /// служебные подписи, чтобы «Правовые документы» не оказались под панелью.
    private var dock: some View {
        // Экраны в машинах разные — от узких 800×480 до широких. Прибытие
        // отваливается первым: без него панель остаётся полезной, а вот резать
        // скорость и камеру нельзя.
        ViewThatFits(in: .horizontal) {
            dockRow(showRoute: true)
            dockRow(showRoute: false)
        }
        .padding(.horizontal, 16)
        .frame(height: AppConfig.carPlayDockHeight)
        .background(Theme.background.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Кромка панели окрашивается по тревоге: боковым зрением видно, что
        // впереди камера, даже если смотришь на дорогу, а не на цифры.
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(dockEdge, lineWidth: alertTint == nil ? 1 : 2))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.3), value: env.location.alertLevel)
    }

    private func dockRow(showRoute: Bool) -> some View {
        HStack(spacing: 0) {
            speedCell
            cellDivider
            cameraCell
            if showRoute, env.route.isActive {
                cellDivider
                etaCell
            }
        }
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1, height: 46)
            .padding(.horizontal, 14)
    }

    /// Скорость крупно + знак лимита рядом: сравнение «еду / можно» одним взглядом.
    private var speedCell: some View {
        HStack(spacing: 12) {
            VStack(spacing: -1) {
                Text("\(Int(env.location.speedKmh.rounded()))")
                    .font(.rounded(38, .heavy).monospacedDigit())
                    .foregroundStyle(speedColor)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: Int(env.location.speedKmh.rounded()))
                Text("км/ч")
                    .font(.rounded(10, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minWidth: 58)

            if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 46,
                               isAssumed: env.speedLimits.isCurrentLimitAssumed)
                    .shadow(color: env.speedLimits.isOverspeeding ? Theme.danger.opacity(0.8) : .clear,
                            radius: 9)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: env.speedLimits.currentLimit)
    }

    /// Ближайшая камера — три честных состояния: нет сигнала, есть цель, чисто.
    @ViewBuilder
    private var cameraCell: some View {
        if env.location.isSignalStale {
            statusCell(symbol: "location.slash.fill", tint: Theme.warning,
                       title: String(localized: "Нет сигнала"),
                       subtitle: String(localized: "Ждём спутники"))
        } else if let camera = env.location.nearestCamera,
                  let distance = env.location.distanceToNearest,
                  distance <= AppConfig.carPlayNearestCameraMeters {
            nearestCameraCell(camera: camera, distance: distance)
        } else {
            statusCell(symbol: "checkmark.shield.fill", tint: Theme.success,
                       title: String(localized: "Чисто"),
                       subtitle: String(localized: "Камер рядом нет"))
        }
    }

    private func nearestCameraCell(camera: Camera, distance: CLLocationDistance) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: camera.kind.symbolName)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(proximityTint(distance, camera).gradient, in: Circle())

                // Стрелка направления на камеру относительно курса (вверх = прямо
                // по ходу): понятно, камера впереди или уводит в сторону.
                if let relative = env.location.relativeBearingToNearest {
                    let angle = CameraDirection.arrowAngle(relativeBearing: relative)
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(camera.kind.tint)
                        .offset(y: -26)
                        .rotationEffect(.degrees(angle))
                        .animation(.easeOut(duration: 0.3), value: Int(angle / 10))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(Formatting.distance(distance))
                    .font(.rounded(24, .heavy).monospacedDigit())
                    .foregroundStyle(env.location.isApproachingCamera ? Theme.danger : Theme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: Int(distance))
                Text(camera.kind.genitivePhrase)
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let progress = env.location.approachProgress {
                    approachBar(progress)
                }
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    private func statusCell(symbol: String, tint: Color,
                            title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.rounded(17, .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    /// Прибытие: во сколько будем, сколько осталось и сколько камер впереди
    /// по маршруту — три числа, которые спрашивают в дороге чаще всего.
    private var etaCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "flag.checkered")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.success)
                Text(env.route.arrivalDate.formatted(date: .omitted, time: .shortened))
                    .font(.rounded(22, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 8) {
                Text(Formatting.distance(env.route.remainingDistance))
                    .font(.rounded(12, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                if camerasAhead > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(camerasAhead)")
                            .font(.rounded(12, .semibold).monospacedDigit())
                    }
                    .foregroundStyle(Theme.Types.camera)
                }
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    /// Сколько камер маршрута ещё впереди (пройденные не считаем).
    private var camerasAhead: Int {
        let progress = env.route.progressAlong
        return env.route.camerasOnRoute.filter { $0.distanceAlong > progress }.count
    }

    // MARK: - Верхние баннеры

    /// Алерт приближения: цвет и размер растут по уровню тревоги (1→3), рядом —
    /// знак лимита на этой дороге, чтобы решение «тормозить или нет» было сразу.
    private func approachBanner(camera: Camera, distance: CLLocationDistance) -> some View {
        let tint = alertTint ?? Theme.warning
        return HStack(spacing: 12) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(20, .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.18), in: Circle())
                .symbolEffect(.pulse, options: .repeating)

            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(28, .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: Int(distance))
                Text(camera.kind.displayName)
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            if let limit = env.speedLimits.limit(near: camera.coordinate) {
                SpeedLimitSign(limit: limit, diameter: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.gradient,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: tint.opacity(0.55), radius: 16, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Манёвр: «через 300 м — направо на Амира Темура».
    private func maneuverBanner(step: RouteStep, distance: CLLocationDistance) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(22, .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 44, height: 44)
                .background(Theme.accent.gradient,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(20, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: Int(distance))
                Text(step.text)
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(Theme.background.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Цвета и мелочи

    /// Цвет тревоги по уровню эскалации: янтарь → оранжевый → красный.
    /// nil — тревоги нет, кромка панели остаётся нейтральной.
    private var alertTint: Color? {
        switch env.location.alertLevel {
        case 1:  return Theme.role(.attention)
        case 2:  return Theme.warning
        case 3...: return Theme.role(.alarm)
        default: return nil
        }
    }

    private var dockEdge: Color { alertTint ?? Theme.stroke }

    /// Цвет скорости: белый в рамках лимита, янтарный при превышении без штрафа,
    /// красный — когда превышение уже стоит денег.
    private var speedColor: Color {
        guard env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit else {
            return Theme.textPrimary
        }
        // Одно правило на всё приложение: одна ситуация — один цвет.
        switch Theme.speedLevel(speedKmh: env.location.speedKmh, limitKmh: limit,
                                tolerance: env.settings.overspeedTolerance) {
        case .normal, .neutral: return Theme.textPrimary
        case .attention:        return Theme.warning
        case .alarm:            return Theme.danger
        }
    }

    /// Цвет значка камеры по БЛИЗОСТИ, а не по типу: красный кружок при камере
    /// в трёх километрах читается как тревога, хотя ехать до неё минуты.
    private func proximityTint(_ distance: CLLocationDistance, _ camera: Camera) -> Color {
        let radius = env.settings.alertRadius
        if distance <= radius { return camera.kind.tint }
        if distance <= radius * 3 { return camera.kind.tint.opacity(0.55) }
        return Theme.textTertiary
    }

    /// Полоска приближения: заполняется к камере и «греется» — боковым зрением
    /// читается быстрее цифр.
    private func approachBar(_ progress: Double) -> some View {
        let tint = Theme.role(progress > 0.66 ? .alarm : progress > 0.33 ? .attention : .neutral)
        return Capsule()
            .fill(Theme.stroke)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(progress, 0.04), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(width: 120, height: 3)
            .padding(.top, 2)
            .animation(.easeOut(duration: 0.3), value: progress)
    }
}
