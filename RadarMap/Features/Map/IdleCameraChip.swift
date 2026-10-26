//
//  IdleCameraChip.swift
//  RadarMap
//
//  Ближайшая камера на стоянке — чип 44 pt слева сверху (этап 31, выбор
//  владельца 26.10). Прежде здесь стоял тот же HUD, что за рулём, — карточка
//  76 pt на всю ширину, «469 м до камеры», когда машина стоит у дома. Стоя
//  смотрят на карту, а не на прибор; поехали — и сверху снова полный HUD со
//  скоростью и лимитом (MapScreen.topPanels).
//
//  Ночью чип не приглушается прозрачностью: HUD с opacity ≈ 0,61 выглядел
//  выключенным, серые цифры на графите. Ночная тема и так графитовая.
//

import SwiftUI

struct IdleCameraChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let location = env.location
        content(location)
            .padding(.leading, 7).padding(.trailing, 14)
            .frame(minHeight: Theme.controlSize)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(_ location: LocationService) -> some View {
        if location.isSignalStale {
            HStack(spacing: 8) {
                Image(systemName: location.isAuthorized ? Icon.noGPSSignal : Icon.noLocationAccess)
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 30, height: 30)
                    .background(Theme.warning.opacity(0.18), in: Circle())
                (location.isAuthorized ? Text("Нет сигнала GPS") : Text("Оповещений нет"))
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
        } else if let camera = location.displayNearestCamera,
                  let distance = location.displayDistanceToNearest {
            let radius = location.effectiveAlertRadius
            HStack(spacing: 8) {
                CameraCoinView(glyph: camera.kind.glyph,
                               fill: SpeedHUDView.proximityTint(distance, camera, radius: radius),
                               ink: SpeedHUDView.proximityGlyph(distance, camera, radius: radius),
                               side: 30, shadow: false)
                Text(verbatim: Formatting.distance(distance))
                    .font(.rounded(17, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .liveNumber()
                SpeedHUDView.caption(for: camera, location: location)
                    .font(.rounded(12, .medium))
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Theme.success)
                Text("Камер рядом нет")
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.rounded(12, .semibold))
            .padding(.leading, 7)
        }
    }
}
