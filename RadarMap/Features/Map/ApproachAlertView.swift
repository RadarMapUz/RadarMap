//
//  ApproachAlertView.swift
//  RadarMap
//
//  Полноэкранное предупреждение при приближении к камере — крупно, читается боковым зрением.
//

import SwiftUI

struct ApproachAlertView: View {
    let camera: Camera
    let distance: Double
    let speedKmh: Double
    let relativeBearing: Double?
    let alertRadius: Double
    let onDismiss: () -> Void

    @State private var pulse = false

    private var tint: Color { camera.kind.tint }
    /// 0…1 — насколько близко (для кольца прогресса).
    private var proximity: Double {
        max(0, min(1, 1 - distance / max(alertRadius, 1)))
    }

    var body: some View {
        ZStack {
            // Затемняем карту, подсвечиваем цветом типа камеры.
            LinearGradient(colors: [tint.opacity(0.28), Theme.background.opacity(0.96)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Иконка типа + название
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18)).frame(width: 130, height: 130)
                            .scaleEffect(pulse ? 1.12 : 0.92)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                        Circle()
                            .trim(from: 0, to: proximity)
                            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 118, height: 118)
                            .rotationEffect(.degrees(-90))
                        Image(systemName: camera.kind.symbolName)
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text(camera.kind.displayName)
                        .font(.rounded(20, .bold))
                        .foregroundStyle(.white)
                }

                // Расстояние — крупно
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(Int(distance.rounded()))")
                        .font(.system(size: 88, weight: .heavy, design: .rounded))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(value: distance))
                        .animation(.easeOut(duration: 0.3), value: Int(distance))
                    Text("м").font(.rounded(30, .bold)).foregroundStyle(Theme.textSecondary)
                }

                // Направление + скорость
                HStack(spacing: 22) {
                    if let rel = relativeBearing {
                        label(icon: "location.north.fill", value: directionText(rel), rotate: rel)
                    }
                    label(icon: "gauge.with.dots.needle.67percent",
                          value: String(format: String(localized: "%lld км/ч"), Int(speedKmh)),
                          rotate: nil)
                }

                if !camera.location.isEmpty {
                    Text(camera.location)
                        .font(.rounded(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Text("Нажмите, чтобы скрыть")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear { pulse = true }
        .transition(.opacity.combined(with: .scale(scale: 1.05)))
    }

    private func label(icon: String, value: String, rotate: Double?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.rounded(16, .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(rotate ?? 0))
            Text(value).font(.rounded(18, .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func directionText(_ rel: Double) -> String {
        switch rel {
        case ..<25, 335...: return String(localized: "прямо")
        case 25..<90:       return String(localized: "справа")
        case 90..<180:      return String(localized: "сзади справа")
        case 180..<270:     return String(localized: "сзади слева")
        default:            return String(localized: "слева")
        }
    }
}
