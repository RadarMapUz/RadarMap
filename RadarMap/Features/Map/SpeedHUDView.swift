//
//  SpeedHUDView.swift
//  RadarMap
//
//  Верхний HUD: текущая скорость + ближайшая камера и расстояние до неё.
//

import SwiftUI

struct SpeedHUDView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let location = env.location
        GlassCard(cornerRadius: 22) {
            HStack(spacing: 0) {
                speedBlock(location.speedKmh)

                // Знак лимита дороги, по которой едем (данные OSM с нашего сервера).
                if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                    limitSign(limit)
                        .padding(.trailing, 6)
                        .transition(.scale.combined(with: .opacity))
                }

                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: 1, height: 44)
                    .padding(.horizontal, 4)

                nearestBlock(camera: location.nearestCamera,
                             distance: location.distanceToNearest)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Чип режима оповещений: видно, почему тихо (город) или голосисто (трасса).
        .overlay(alignment: .topTrailing) {
            if env.location.isTripActive { modeChip }
        }
        .animation(.spring(duration: 0.3), value: env.speedLimits.currentLimit)
        // VoiceOver: весь HUD — одна связная фраза, а не россыпь цифр.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// «Скорость 47 км/ч. Лимит 60. Радар через 360 метров» — для VoiceOver.
    private var accessibilitySummary: String {
        var parts = [String(format: String(localized: "Скорость %lld км/ч"),
                            Int(env.location.speedKmh.rounded()))]
        if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
            parts.append(String(format: String(localized: "Лимит %lld"), limit))
        }
        if env.location.isSignalStale {
            parts.append(String(localized: "Нет сигнала GPS"))
        } else if let camera = env.location.nearestCamera,
                  let distance = env.location.distanceToNearest {
            parts.append("\(camera.kind.displayName) — \(Formatting.distance(distance))")
            if env.location.isPositionCoarse {
                parts.append(String(localized: "уточняем положение"))
            }
        } else {
            parts.append(String(localized: "Камер рядом нет"))
        }
        return parts.joined(separator: ". ")
    }

    /// Круглый знак «ограничение скорости»; при превышении пульсирует красным.
    private func limitSign(_ limit: Int) -> some View {
        let over = env.speedLimits.isOverspeeding
        return SpeedLimitSign(limit: limit)
            .shadow(color: over ? Theme.danger.opacity(0.9) : .black.opacity(0.3),
                    radius: over ? 10 : 3)
            .scaleEffect(over ? 1.08 : 1.0)
            .animation(over ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.25),
                       value: over)
    }

    private func speedBlock(_ speed: Double) -> some View {
        VStack(spacing: 0) {
            // Крупно: за рулём HUD читается взглядом <1 сек.
            Text("\(Int(speed.rounded()))")
                .font(.rounded(34, .bold))
                .monospacedDigit()
                .foregroundStyle(env.speedLimits.isOverspeeding ? Theme.danger : Theme.textPrimary)
                .contentTransition(.numericText(value: speed))
                .animation(.easeOut(duration: 0.3), value: Int(speed.rounded()))
            HStack(spacing: 3) {
                Text("км/ч")
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                if env.location.isLowPowerMode {
                    // Энергосбережение iOS: точность GPS снижена, голос отключён.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
            }
        }
        .frame(width: 74)
    }

    @ViewBuilder
    private func nearestBlock(camera: Camera?, distance: Double?) -> some View {
        if env.location.isSignalStale {
            // Фиксов нет: показывать старое расстояние как живое — врать водителю.
            HStack(spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .font(.rounded(16, .semibold))
                    .foregroundStyle(Theme.radar)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Нет сигнала GPS")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Оповещения ждут спутники")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
        } else if let camera, let distance {
            let near = distance <= env.settings.alertRadius
            HStack(spacing: 12) {
                ZStack {
                    Image(systemName: camera.kind.symbolName)
                        .font(.rounded(16, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(proximityTint(distance, camera).gradient, in: Circle())
                        .shadow(color: near ? camera.kind.tint.opacity(0.6) : .clear, radius: 6)

                    // Стрелка направления на камеру относительно курса (вверх = прямо по ходу).
                    // Мёртвая зона: почти по курсу — строго вверх, без дрожи.
                    if let rel = env.location.relativeBearingToNearest {
                        let angle = CameraDirection.arrowAngle(relativeBearing: rel)
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(camera.kind.tint)
                            .offset(y: -27)
                            .rotationEffect(.degrees(angle))
                            .animation(.easeOut(duration: 0.3), value: Int(angle / 10))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatting.distance(distance))
                        .font(.rounded(23, .bold))
                        .monospacedDigit()
                        // Красным — только в зоне оповещения и только по живой
                        // позиции: цифра от грубого фикса на красный не имеет права.
                        .foregroundStyle(near && !env.location.isPositionCoarse
                                         ? Theme.danger : Theme.textPrimary)
                        .contentTransition(.numericText(value: distance))
                        .animation(.easeOut(duration: 0.3), value: Int(distance))
                    Text(caption(for: camera))
                        .font(.rounded(11, .medium))
                        .foregroundStyle(env.location.isPositionCoarse
                                         ? Theme.radar : Theme.textSecondary)
                        .lineLimit(1)
                    // Полоска приближения: заполняется к камере и «греется» —
                    // боковым зрением читается быстрее цифр.
                    if let progress = env.location.approachProgress {
                        approachBar(progress)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.rounded(16, .semibold))
                    .foregroundStyle(Theme.success)
                Text("Камер рядом нет")
                    .font(.rounded(15, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
        }
    }

    /// Цвет значка по БЛИЗОСТИ, а не по типу камеры. Красный кружок при камере в
    /// десяти километрах читается как тревога, хотя ехать до неё двадцать минут:
    /// далеко — спокойный серый, на подходе — приглушённый цвет типа, в зоне
    /// оповещения — полный цвет со свечением.
    private func proximityTint(_ distance: Double, _ camera: Camera) -> Color {
        let radius = env.settings.alertRadius
        if distance <= radius { return camera.kind.tint }
        if distance <= radius * 3 { return camera.kind.tint.opacity(0.5) }
        return Theme.textTertiary
    }

    /// Подпись под расстоянием. Когда позиция грубая (кэш при запуске, слабый
    /// сигнал в помещении), честно говорим об этом: иначе цифра выглядит живой.
    private func caption(for camera: Camera) -> String {
        if env.location.isPositionCoarse {
            return String(localized: "уточняем положение")
        }
        if env.location.isDirectionalFilteringActive {
            return String(format: String(localized: "%@ по курсу"), camera.kind.genitivePhrase)
        }
        return camera.kind.genitivePhrase
    }

    /// Эффективный режим: при «Авто» — что определил детектор.
    private var modeChip: some View {
        let mode = env.settings.alertMode
        let symbol = mode == .auto
            ? (env.location.alertContext == .highway ? AlertMode.highway.symbol : AlertMode.city.symbol)
            : mode.symbol
        return Image(systemName: symbol)
            .font(.rounded(10, .bold))
            .foregroundStyle(Theme.accent)
            .padding(5)
            .background(Theme.surface.opacity(0.85), in: Circle())
            .padding(6)
            .allowsHitTesting(false)
    }

    private func approachBar(_ progress: Double) -> some View {
        let tint: Color = progress > 0.66 ? Theme.danger
                        : progress > 0.33 ? .orange : .yellow
        return Capsule()
            .fill(Theme.stroke)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(progress, 0.04), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: 3)
            .padding(.top, 3)
            .animation(.easeOut(duration: 0.3), value: progress)
    }
}
