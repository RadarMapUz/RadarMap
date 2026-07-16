//
//  CarPlayMapScreen.swift
//  RadarMap
//
//  Экран CarPlay: тёмная карта с камерами и маршрутом + HUD в фирменном
//  стиле — скорость против лимита, ближайшая камера, манёвр, алерт приближения.
//  Всё читается с водительского места с одного взгляда.
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
}

struct CarPlayMapScreen: View {
    @Environment(AppEnvironment.self) private var env
    let model: CarPlayMapModel

    var body: some View {
        ZStack {
            CarPlayMapView(model: model,
                           repository: env.cameras,
                           route: env.route,
                           location: env.location)
                .ignoresSafeArea()

            overlay
        }
    }

    // MARK: HUD

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if let step = env.route.nextStep {
                    maneuverBanner(step: step, distance: env.route.nextStepDistance)
                }
                Spacer(minLength: 0)
                if env.location.isApproachingCamera, let camera = env.location.nearestCamera,
                   let distance = env.location.distanceToNearest {
                    approachBanner(camera: camera, distance: distance)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                speedPanel
                Spacer(minLength: 0)
                if env.route.isActive {
                    etaChip
                }
            }
        }
        .padding(12)
    }

    /// Скорость + знак лимита + ближайшая камера — главный приборный блок.
    private var speedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text("\(Int(env.location.speedKmh))")
                        .font(.rounded(34, .heavy).monospacedDigit())
                        .foregroundStyle(speedColor)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: Int(env.location.speedKmh))
                    Text("км/ч")
                        .font(.rounded(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let limit = env.speedLimits.currentLimit {
                    limitSign(limit)
                }
            }
            if !env.location.isApproachingCamera,
               let camera = env.location.nearestCamera,
               let distance = env.location.distanceToNearest, distance <= 3000 {
                nearestCameraRow(camera: camera, distance: distance)
            }
        }
        .padding(14)
        .background(Theme.background.opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }

    private var speedColor: Color {
        guard let limit = env.speedLimits.currentLimit else { return Theme.textPrimary }
        let over = env.location.speedKmh - Double(limit)
        if over <= 2 { return Theme.textPrimary }
        if FineSchedule.fine(overKmh: over) == 0 { return Theme.radar }
        return Theme.danger
    }

    private func limitSign(_ limit: Int) -> some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(Color(red: 0.85, green: 0.05, blue: 0.1), lineWidth: 4)
            Text("\(limit)")
                .font(.system(size: limit >= 100 ? 14 : 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
        }
        .frame(width: 46, height: 46)
    }

    private func nearestCameraRow(camera: Camera, distance: CLLocationDistance) -> some View {
        HStack(spacing: 8) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(11, .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(camera.kind.tint.gradient, in: Circle())
            Text(Formatting.distance(distance))
                .font(.rounded(15, .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(camera.kind.displayName)
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    /// Красный алерт приближения — крупно, пульс, не спутаешь ни с чем.
    private func approachBanner(camera: Camera, distance: CLLocationDistance) -> some View {
        HStack(spacing: 10) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(18, .bold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(22, .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(camera.kind.displayName)
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.danger.gradient,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.danger.opacity(0.5), radius: 14, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(duration: 0.35), value: env.location.isApproachingCamera)
    }

    /// Манёвр: «через 300 м — направо».
    private func maneuverBanner(step: RouteStep, distance: CLLocationDistance) -> some View {
        HStack(spacing: 10) {
            Image(systemName: step.icon)
                .font(.rounded(20, .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 40, height: 40)
                .background(Theme.accent.gradient,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(18, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(step.text)
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.background.opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }

    private var etaChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.success)
            Text(env.route.etaText)
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(Formatting.distance(env.route.remainingDistance))
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.background.opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }
}
