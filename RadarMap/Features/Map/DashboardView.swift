//
//  DashboardView.swift
//  RadarMap
//
//  Режим «Спидометр» (тап по HUD): телефон в держателе — огромная скорость,
//  знак лимита и ближайшая камера на весь экран, как приборка радар-детектора.
//  Читается боковым зрением; экран не гаснет, пока режим открыт.
//

import CoreLocation
import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Экранная модель схемы: сцена «север вверху» + анимированная точка
    /// зрения. Живёт, пока открыта приборка.
    @State private var sketch = SketchState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Скорость — главное, во весь экран.
                HStack(alignment: .center, spacing: 22) {
                    Text("\(Int(env.location.speedKmh.rounded()))")
                        .font(.system(size: 148, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(speedColor)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: Int(env.location.speedKmh))
                    if let limit = env.speedLimits.currentLimit {
                        SpeedLimitSign(limit: limit, diameter: 84)
                            .scaleEffect(env.speedLimits.isOverspeeding ? 1.08 : 1)
                            .animation(env.speedLimits.isOverspeeding
                                       ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                                       : .easeOut(duration: 0.25),
                                       value: env.speedLimits.isOverspeeding)
                    }
                }
                Text("км/ч")
                    .font(.rounded(18, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, -26)

                // Манёвр при активном маршруте. Голос и так говорит «через 300
                // метров направо», но приборка — экран поездки, и взгляд на неё
                // не должен оставлять вопрос «а поворот-то где?». Компактно:
                // иконка + дистанция, фраза одной строкой.
                if env.route.isActive, let step = env.route.nextStep {
                    HStack(spacing: 12) {
                        Image(systemName: step.icon)
                            .font(.rounded(26, .bold))
                            .foregroundStyle(Theme.accent)
                        Text(Formatting.distance(env.route.nextStepDistance))
                            .font(.rounded(30, .heavy))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                        Text(step.text)
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 28)
                }

                // Схема «где камера»: чертим сами, без карты и без сети.
                // Приборка — режим «телефон в держателе», она обязана быть самым
                // дешёвым экраном приложения, а не самым дорогим.
                if let scene = sketch.scene, sketch.hasCourse, !scene.isEmpty {
                    RoadSketchView(scene: scene, state: sketch, tint: alertColor)
                        .frame(height: 210)
                        .padding(.horizontal, 28)
                        .opacity(sketchIsStale ? 0.45 : 1)
                        .animation(.easeOut(duration: 0.4), value: sketchIsStale)
                }

                // Ближайшая камера: дистанция крупно, цвет греется по уровню тревоги.
                if let camera = env.location.nearestCamera,
                   let distance = env.location.distanceToNearest {
                    cameraBlock(camera: camera, distance: distance)
                } else {
                    Label("Камер рядом нет", systemImage: "checkmark.shield.fill")
                        .font(.rounded(18, .semibold))
                        .foregroundStyle(Theme.success)
                        .padding(.vertical, 24)
                }

                // Жара: троттлинг уже работает (бюджет сети схемы, буст GPS
                // погашен) — но молча. Молчаливая деградация читается как
                // поломка, одна строка честности дешевле жалобы «лагает».
                if env.thermal.mode != .full {
                    Label("Жарко — экономлю экран", systemImage: "thermometer.sun.fill")
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.warning)
                }

                Spacer()

                // «Радар ещё стоял?» — приборка перекрывает карту целиком, и
                // вопрос, нарисованный там, сгорал под ней невидимым: водитель
                // в держателе не видел его НИКОГДА. Здесь своя копия; на карте
                // плашка в это время ждёт (isCovered), таймер не двоится.
                MobileConfirmBar()
                    .padding(.horizontal, 28)

                if env.location.isTripActive {
                    tripRow
                        .padding(.horizontal, 28)
                }

                // Кнопка «Радар!» — крупная: приборка это режим «телефон в
                // держателе», и тап делается вслепую.
                ReportRadarButton(isLarge: true)
                    .padding(.bottom, 4)

                Text("Нажмите, чтобы вернуться к карте")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden()
        // Тик GPS → точка зрения схемы (и изредка пересборка её растра).
        .onChange(of: env.location.locationTick) { sketch.refresh(env) }
        // Приборка должна светиться всю поездку — не даём экрану погаснуть.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Пока водитель смотрит на схему, фиксы нужны чаще: крейсерские
            // 25 м — это рывок раз в 2–3 секунды. Буст снимается сам при
            // закрытии и не включается в перегрев (см. tuneAdaptiveAccuracy).
            env.location.setDashboardVisible(true)
            sketch.refresh(env)
        }
        .onDisappear {
            // Закрыли спидометр в активной поездке — экран продолжает держать поездка.
            UIApplication.shared.isIdleTimerDisabled =
                env.location.isTripActive && env.settings.keepScreenOn
            env.location.setDashboardVisible(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Спидометр"))
        .accessibilityHint(Text("Нажмите, чтобы вернуться к карте"))
    }

    /// Строка поездки: время · путь · камеры, заряд и «Стоп». Приборка — экран
    /// поездки, с неё не должно приходиться уходить: ни чтобы посмотреть,
    /// сколько едем, ни чтобы завершить.
    private var tripRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                if let started = env.trip.startedAt {
                    // Системный таймер: тикает сам, без пересборки body каждую секунду.
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.rounded(20, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.success)
                }
                HStack(spacing: 4) {
                    Text(Formatting.distance(env.trip.distanceMeters))
                        .contentTransition(.numericText())
                    Text("·")
                    Image(systemName: "camera.fill")
                        .font(.rounded(10, .semibold))
                    Text("\(env.trip.camerasPassed)")
                        .contentTransition(.numericText())
                }
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            BatteryChip()
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // Тот же путь, что стоп на карте; приборку закроет сам конец
                // поездки (MapScreen прячет её по isTripActive).
                env.location.endTrip()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.rounded(16, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.danger.gradient,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel(Text("Завершить поездку"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    /// Схема нарисована по устаревшему курсу (стоим, курса нет) — показываем
    /// приглушённо: «это последнее, что мы знали», а не «это происходит
    /// сейчас». Проверено на симуляции: раньше схема на остановке исчезала
    /// целиком, то есть панель гасла бы на каждом светофоре.
    private var sketchIsStale: Bool { env.location.currentCourse < 0 }

    /// Блок ближайшей камеры.
    ///
    /// Раньше здесь были только дистанция и КЛАСС устройства
    /// («Интеллектуальная камера + радар») — то есть экран не отвечал ни на
    /// один вопрос, который водитель задаёт первым: где она, какая именно,
    /// приближаюсь ли. Приборка при этом единственный экран, сделанный ровно
    /// для взгляда из держателя, и единственный, который не спрашивал у
    /// `CameraDirection` направление, хотя панель, плашка сближения и CarPlay
    /// давно спрашивают.
    @ViewBuilder
    private func cameraBlock(camera: Camera, distance: CLLocationDistance) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                // Иконка со стрелкой направления: вверх — прямо по ходу
                // движения, вбок — реальный азимут. Не компас: водителю нужно
                // «слева или справа от меня», а не «где север».
                ZStack {
                    Image(systemName: camera.kind.symbolName)
                        .font(.rounded(26, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(camera.kind.tint.gradient, in: Circle())
                    if let rel = env.location.displayBearingToNearest {
                        let angle = CameraDirection.arrowAngle(relativeBearing: rel)
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(alertColor)
                            .offset(y: -37)
                            .rotationEffect(.degrees(angle))
                            // Шаг в 10° — стрелка не дрожит от шума курса.
                            .animation(.easeOut(duration: 0.3), value: Int(angle / 10))
                    }
                }
                Text(Formatting.distance(distance))
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(alertColor)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: Int(distance))
                if let side = env.location.nearestSideWord {
                    Text(side)
                        .font(.rounded(20, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Адрес, а не класс железа: на вопрос «какая именно камера»
            // отвечает место. Тип уходит второй строкой — он и так виден
            // по иконке и цвету.
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    if env.location.isOnActiveRoute(camera) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    // Две строки, а не одна: адреса в базе длинные
                    // («4R21 Toshkent Aylanma Yo'li "Qozog'iston Gilamlari"
                    // Qarshisi»), и обрезанные многоточием они не отвечают
                    // на вопрос «какая именно камера» вообще.
                    Text(camera.displayTitle)
                        .font(.rounded(18, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                Text(camera.isApproximate
                     ? String(localized: "координата приблизительная")
                     : camera.kind.displayName)
                    .font(.rounded(13))
                    .foregroundStyle(camera.isApproximate ? Theme.warning : Theme.textTertiary)
            }
            .padding(.horizontal, 12)

            // Полосу показываем только внутри радиуса: снаружи она всё равно
            // пуста, а пустая шкала читается как сломанная.
            if distance <= AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                       baseRadius: env.settings.alertRadius) {
                approachBar(distance: distance)
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(alertColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 28)
    }

    /// Полоса сближения. Число говорит «сколько метров», полоса — «приближаюсь»:
    /// это разные сведения, и второе читается вообще без чтения.
    private func approachBar(distance: CLLocationDistance) -> some View {
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius)
        let progress = max(0, min(1, 1 - distance / max(radius, 1)))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(alertColor)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .animation(.easeOut(duration: 0.3), value: Int(progress * 50))
        .accessibilityHidden(true)   // цифру рядом VoiceOver уже читает
    }

    private var speedColor: Color {
        guard let limit = env.speedLimits.currentLimit else { return .white }
        let over = env.location.speedKmh - Double(limit)
        if over <= 2 { return .white }
        if FineSchedule.fine(overKmh: over) == 0 { return Theme.role(.attention) }
        return Theme.danger
    }

    private var alertColor: Color {
        guard let distance = env.location.distanceToNearest else { return Theme.accent }
        let radius = AlertEngine.effectiveRadius(speedKmh: env.location.speedKmh,
                                                 baseRadius: env.settings.alertRadius)
        // Три ступени: вплотную — опасность, в средней зоне — внимание,
        // в радиусе — нейтральный акцент. Раньше вторая ветка звала
        // Theme.role(.alarm) — тот же danger, и эскалация была двухступенчатой.
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.warning }
        if distance <= radius { return Theme.accent }
        return Theme.accent
    }
}

// MARK: - Заряд

/// Заряд телефона на приборке: % и молния на зарядке.
///
/// Телефон в держателе — единственный момент, когда водителю важен заряд
/// ИМЕННО в этом приложении: приборка строилась ради батареи, и её экран —
/// то место, где экономия должна быть видна, а не предполагаться.
///
/// Мониторинг батареи включается ТОЛЬКО пока чип на экране и выключается в
/// onDisappear: держать его постоянно — значит будить процесс уведомлениями
/// системы ради цифры, на которую никто не смотрит.
private struct BatteryChip: View {
    @State private var level: Float = -1
    @State private var isCharging = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isCharging ? "bolt.fill" : symbol)
                .font(.rounded(12, .semibold))
                .foregroundStyle(tint)
            if level >= 0 {
                Text("\(Int((level * 100).rounded())) %")
                    .font(.rounded(13, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level >= 0
            ? Text("Заряд \(Int((level * 100).rounded())) процентов")
            : Text("Заряд неизвестен"))
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        isCharging = state == .charging || state == .full
    }

    private var symbol: String {
        switch level {
        case ..<0:      return "battery.50percent"   // симулятор: уровень неизвестен
        case ..<0.2:    return "battery.25percent"
        case ..<0.6:    return "battery.50percent"
        case ..<0.85:   return "battery.75percent"
        default:        return "battery.100percent"
        }
    }

    private var tint: Color {
        if isCharging { return Theme.success }
        return level >= 0 && level < 0.2 ? Theme.danger : Theme.textTertiary
    }
}
