//
//  WatchHUDView.swift
//  RadarWatch
//
//  HUD на запястье: скорость крупно + ближайшая камера. Тёмный стиль
//  «радар-детектора», цвет дистанции греется по мере приближения.
//

import SwiftUI

struct WatchHUDView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        Group {
            if session.isTripActive {
                tripHUD
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Поездка

    private var tripHUD: some View {
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(session.speedKmh)")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("км/ч")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let distance = session.distanceMeters {
                VStack(spacing: 2) {
                    Text(distanceText(distance))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(distanceColor)
                        .contentTransition(.numericText())
                    Text(session.cameraTitle ?? String(localized: "до камеры"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(distanceColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label {
                    Text("Камер рядом нет")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                }
                .foregroundStyle(.green)
            }
        }
        .animation(.easeOut(duration: 0.25), value: session.alertLevel)
    }

    // MARK: - Ожидание

    private var idleView: some View {
        VStack(spacing: 8) {
            Image(systemName: "car.fill")
                .font(.system(size: 30))
                .foregroundStyle(.cyan)
            Text("Поездка не идёт.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(session.isReachable
                 ? String(localized: "Начните поездку на iPhone — скорость и камеры появятся здесь.")
                 : String(localized: "Откройте RadarMap на iPhone."))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Помощники

    private var distanceColor: Color {
        switch session.alertLevel {
        case 3:  return .red
        case 2:  return .orange
        case 1:  return .yellow
        default: return .cyan
        }
    }

    private func distanceText(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.1f км", Double(meters) / 1000) : "\(meters) м"
    }
}
