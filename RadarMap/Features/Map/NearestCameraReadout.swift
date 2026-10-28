//
//  NearestCameraReadout.swift
//  RadarMap
//
//  «До камеры» — ОДИН облик на трёх местах (33H3, 28.10, выбор владельца):
//  чип на стоянке (IdleCameraChip), блок HUD в поездке (SpeedHUDView) и чип
//  под карточкой манёвра (NavigationHUD). До этого один и тот же факт был
//  нарисован трижды по-разному: стоя — чёрное число 17 pt в строку, в
//  поездке — число 23 pt, красное, с полосой, в навигации — SF Pro 17 в
//  строку и без полосы. Водитель видел три прибора там, где прибор один.
//
//  Правило цвета одно: красная цифра и полоса близости — только пока идёт
//  оповещение, по тому же признаку, что и раньше красил HUD (камера в радиусе
//  оповещения и позиция живая, не грубый фикс). Вне оповещения — обычная
//  цифра без полосы, где бы чип ни стоял. Пороги и логика оповещения здесь
//  не решаются — только читаются (LocationService).
//

import SwiftUI

struct NearestCameraReadout: View {
    /// Чип (стоянка, навигация): значок 30, цифра 17. Иначе — блок HUD:
    /// значок 38 со стрелкой на камеру, цифра 23, на всю ширину панели.
    var compact = false
    @Environment(AppEnvironment.self) private var env

    /// Идёт ли оповещение — тот же признак, что красил цифру HUD до 33H3:
    /// камера в радиусе оповещения, и позиция не грубая (цифра от кэша при
    /// запуске на красный права не имеет).
    nonisolated static func isAlerting(distance: Double, radius: Double, positionCoarse: Bool) -> Bool {
        distance <= radius && !positionCoarse
    }

    var body: some View {
        let location = env.location
        if location.isSignalStale {
            stale(location)
        } else if let camera = location.displayNearestCamera,
                  let distance = location.displayDistanceToNearest {
            readout(camera: camera, distance: distance, location: location)
        } else {
            clear
        }
    }

    // MARK: - Камера

    private func readout(camera: Camera, distance: Double, location: LocationService) -> some View {
        let radius = location.effectiveAlertRadius
        let alerting = Self.isAlerting(distance: distance, radius: radius,
                                       positionCoarse: location.isPositionCoarse)
        return HStack(spacing: compact ? 8 : 12) {
            ZStack {
                CameraCoinView(glyph: camera.kind.glyph,
                               fill: SpeedHUDView.proximityTint(distance, camera, radius: radius),
                               ink: SpeedHUDView.proximityGlyph(distance, camera, radius: radius),
                               side: compact ? 30 : 38, shadow: !compact && alerting)
                // Стрелка направления на камеру относительно курса (вверх =
                // прямо по ходу) — в HUD, где есть место над значком.
                // Мёртвая зона: почти по курсу — строго вверх, без дрожи.
                if !compact, let rel = location.relativeBearingToNearest {
                    let angle = CameraDirection.arrowAngle(relativeBearing: rel)
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(camera.kind.tint)
                        .offset(y: -27)
                        .rotationEffect(.degrees(angle))
                        .motionAnimation(.easeOut(duration: 0.3), value: Int(angle / 10))
                }
            }
            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                Text(Formatting.distance(distance))
                    .font(.numeral(compact ? 17 : 23, .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(alerting ? Theme.danger : Theme.textPrimary)
                    .liveNumber()
                SpeedHUDView.caption(for: camera, location: location)
                    .font(.rounded(11, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Полоса близости — только в оповещении: заполняется к камере
                // и «греется», боковым зрением читается быстрее цифр.
                if alerting, let progress = location.approachProgress {
                    approachBar(progress)
                }
            }
            if !compact { Spacer(minLength: 0) }
        }
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
    }

    private func approachBar(_ progress: Double) -> some View {
        // «Греется» по состоянию, а не произвольными системными цветами: те
        // же три роли, что и везде.
        let tint = Theme.role(progress > 0.66 ? .alarm : progress > 0.33 ? .attention : .neutral)
        return Capsule()
            .fill(Theme.stroke)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(progress, 0.04), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(width: compact ? 72 : nil, height: 3)
            .padding(.top, compact ? 3 : 4)
            .motionAnimation(.easeOut(duration: 0.3), value: progress)
    }

    // MARK: - Нет сигнала

    @ViewBuilder
    private func stale(_ location: LocationService) -> some View {
        // Фиксов нет: показывать старое расстояние как живое — врать водителю.
        // Антенна без сигнала — в кружке на месте значка камеры, как клетка
        // статуса в CarPlay; без ДОСТУПА к геопозиции — свой значок.
        HStack(spacing: compact ? 8 : 12) {
            Image(systemName: location.isAuthorized ? Icon.noGPSSignal : Icon.noLocationAccess)
                .font(.rounded(compact ? 13 : 16, .semibold))
                .foregroundStyle(Theme.warning)
                .symbolEffect(.pulse, options: .repeating, isActive: !compact)
                .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                .background(Theme.quietFill, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                // Причину и кнопку уже показывает баннер над картой — здесь
                // то, что работает и без позиции (12в A10).
                (location.isAuthorized ? Text("Нет сигнала GPS") : Text("Оповещений нет"))
                    .font(.rounded(compact ? 15 : 14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !compact {
                    (location.isAuthorized ? Text("Оповещения ждут спутники")
                                           : Text("Камеры на карте видны и без позиции"))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !compact { Spacer(minLength: 0) }
        }
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .padding(.leading, compact ? 0 : 6)
    }

    // MARK: - Камер нет

    private var clear: some View {
        HStack(spacing: compact ? 6 : 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.rounded(compact ? 13 : 16, .semibold))
                .foregroundStyle(Theme.success)
            Text("Камер рядом нет")
                .font(.rounded(compact ? 13 : 15, .medium))
                .foregroundStyle(Theme.textSecondary)
            if !compact { Spacer(minLength: 0) }
        }
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .padding(.leading, compact ? 7 : 6)
    }
}
