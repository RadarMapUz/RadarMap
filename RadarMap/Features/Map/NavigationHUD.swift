//
//  NavigationHUD.swift
//  RadarMap
//
//  HUD в навигации: скорость внизу слева, камера — чипом под манёвром.
//
//  В навигации сверху стояли две крупные карточки: манёвр и под ним HUD
//  скорости и камеры. Вместе — треть экрана, и обе спорили за взгляд. У
//  навигаторов верх отдан ОДНОМУ — повороту; скорость с лимитом — круг у
//  нижнего края, его читают боковым зрением; камера всплывает отдельной
//  строкой, только когда она близко (docs/plan_drive_ux_2026-10-07.md, п. 5).
//
//  Обе вью читают пер-тиковые свойства (скорость, дистанция) — поэтому они
//  маленькие и отдельные (ARCHITECTURE.md, правило 13): пересобираются они, а
//  не MapScreen с картой.
//

import SwiftUI

/// Скорость и знак лимита в левом нижнем углу — как у навигаторов.
struct TripSpeedCluster: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let speed = Int(env.location.speedKmh.rounded())
        let over = env.speedLimits.isOverspeeding
        HStack(spacing: 8) {
            VStack(spacing: -2) {
                Text("\(speed)")
                    .font(.rounded(24, .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(over ? Color.white : Theme.textPrimary)
                    .liveNumber()
                HStack(spacing: 2) {
                    Text("км/ч")
                        .lineLimit(1)
                    if env.location.isLowPowerMode {
                        // Энергосбережение iOS: точность GPS снижена (голос о камерах — как всегда).
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .font(.rounded(10, .medium))
                .minimumScaleFactor(0.7)
                .foregroundStyle(over ? Color.white.opacity(0.85) : Theme.textSecondary)
            }
            .padding(6)
            .frame(width: 62, height: 62)
            .liftedBackground(over ? AnyShapeStyle(Theme.danger.gradient) : AnyShapeStyle(Theme.surface),
                              in: Circle())
            .overlay(Circle().strokeBorder(Theme.edgeControl, lineWidth: 1))

            if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                SpeedLimitSign(limit: limit, diameter: 46,
                               isAssumed: env.speedLimits.isCurrentLimitAssumed,
                               glow: over ? Theme.danger.opacity(0.9) : .black.opacity(0.3),
                               glowRadius: over ? 10 : 3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .motionAnimation(Motion.standard, value: env.speedLimits.currentLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [String(format: String(localized: "Скорость %lld км/ч"),
                            Int(env.location.speedKmh.rounded()))]
        if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
            parts.append(String(format: String(localized: "Лимит %lld"), limit))
        }
        return parts.joined(separator: ". ")
    }
}

/// Камера впереди — компактным чипом под карточкой манёвра: только на подходе
/// (`AppConfig.tripCameraChipMeters`) или пока камера говорит. Дальше камера
/// живёт капсулой в нижней панели. Правило — в `TripScreenLayout`.
struct TripCameraChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let location = env.location
        let camera = location.nearestCamera
        let distance = camera == nil ? nil : location.distanceToNearest
        let shown = TripScreenLayout.showsCameraChip(distance: distance,
                                                     isAlerting: location.alertLevel >= 1,
                                                     isSignalStale: location.isSignalStale)
        ZStack {
            if shown {
                chip(camera: camera, distance: distance)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motionAnimation(Motion.standard, value: shown)
    }

    private func chip(camera: Camera?, distance: Double?) -> some View {
        let location = env.location
        return HStack(spacing: 8) {
            if location.isSignalStale {
                // Фиксов нет: старое расстояние как живое — враньё водителю.
                Image(systemName: "location.slash.fill")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 28, height: 28)
                Text(location.isAuthorized ? "Нет сигнала GPS" : "Нет доступа к геопозиции")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            } else if let camera, let distance {
                let radius = location.effectiveAlertRadius
                let near = distance <= radius
                Image(systemName: camera.kind.symbolName)
                    .font(.rounded(13, .bold))
                    .foregroundStyle(SpeedHUDView.proximityGlyph(distance, camera, radius: radius))
                    .frame(width: 28, height: 28)
                    .background(SpeedHUDView.proximityTint(distance, camera, radius: radius).gradient,
                                in: Circle())
                Text(Formatting.distance(distance))
                    .font(.rounded(17, .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(near && !location.isPositionCoarse
                                     ? Theme.danger : Theme.textPrimary)
                    .liveNumber()
                SpeedHUDView.caption(for: camera, location: location)
                    .font(.rounded(12, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
        .liftedBackground(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
