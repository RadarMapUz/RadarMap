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

                // Схема «где камера»: чертим сами, без карты и без сети.
                // Приборка — режим «телефон в держателе», она обязана быть самым
                // дешёвым экраном приложения, а не самым дорогим.
                if let layout = sketchLayout, !layout.isEmpty {
                    RoadSketchView(layout: layout, tint: alertColor)
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

                Spacer()

                Text("Нажмите, чтобы вернуться к карте")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden()
        // Приборка должна светиться всю поездку — не даём экрану погаснуть.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            // Закрыли спидометр в активной поездке — экран продолжает держать поездка.
            UIApplication.shared.isIdleTimerDisabled =
                env.location.isTripActive && env.settings.keepScreenOn
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Спидометр"))
        .accessibilityHint(Text("Нажмите, чтобы вернуться к карте"))
    }

    /// Курс живой или последний достоверный.
    ///
    /// Проверено на симуляции: на остановке курс становится −1, и раньше схема
    /// исчезала целиком вместе со стрелкой и словом стороной. На настоящей
    /// дороге это значило бы, что панель гаснет на каждом светофоре, а мигание
    /// водитель читает как поломку. Стоя мы никуда не повернули — прошлый курс
    /// остаётся честным описанием того, как машина стоит.
    private var sketchCourse: CLLocationDegrees {
        env.location.currentCourse >= 0
            ? env.location.currentCourse
            : env.location.lastTrustedCourse
    }

    /// Схема нарисована по устаревшему курсу — показываем приглушённо: «это
    /// последнее, что мы знали», а не «это происходит сейчас».
    private var sketchIsStale: Bool { env.location.currentCourse < 0 }

    /// Раскладка схемы. `nil` — курса не было ни разу (только запустились):
    /// повернуть схему наугад значило бы соврать направлением.
    private var sketchLayout: RoadSketch.Layout? {
        guard let me = env.location.currentCoordinate else { return nil }
        return RoadSketch.layout(camera: env.location.nearestCamera,
                                 // Дороги берём из индекса лимитов (под кэшем
                                 // окрестности): он уже на телефоне и несёт
                                 // настоящую геометрию. Когда появится свой
                                 // roads.json — меняется только эта строка
                                 // (см. RoadNetwork.swift).
                                 network: env.speedLimits.sketchNetwork,
                                 // Перегрев режет фоновую сеть, но не дорогу
                                 // камеры, не маршрут и не трек.
                                 networkBudget: env.thermal.mode.sketchNetworkBudget,
                                 route: env.route.routeCoordinates,
                                 track: env.trip.recentTrack(),
                                 from: me,
                                 courseDegrees: sketchCourse,
                                 aspect: 16.0 / 9.0)
    }

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
