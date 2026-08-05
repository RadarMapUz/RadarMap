//
//  DashboardView.swift
//  RadarMap
//
//  Режим «Спидометр» (тап по HUD): телефон в держателе — огромная скорость,
//  знак лимита и ближайшая камера на весь экран, как приборка радар-детектора.
//  Читается боковым зрением; экран не гаснет, пока режим открыт.
//

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

                // Ближайшая камера: дистанция крупно, цвет греется по уровню тревоги.
                if let camera = env.location.nearestCamera,
                   let distance = env.location.distanceToNearest {
                    VStack(spacing: 8) {
                        HStack(spacing: 14) {
                            Image(systemName: camera.kind.symbolName)
                                .font(.rounded(26, .bold))
                                .foregroundStyle(.white)
                                .frame(width: 54, height: 54)
                                .background(camera.kind.tint.gradient, in: Circle())
                            Text(Formatting.distance(distance))
                                .font(.system(size: 56, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(alertColor)
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.3), value: Int(distance))
                        }
                        Text(camera.kind.displayName)
                            .font(.rounded(15, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(alertColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 28)
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
        if distance <= radius * 0.3 { return Theme.danger }
        if distance <= radius * 0.6 { return Theme.role(.alarm) }
        if distance <= radius { return Theme.warning }
        return Theme.accent
    }
}
