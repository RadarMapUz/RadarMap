//
//  SpeedHUDView.swift
//  RadarMap
//
//  Верхний HUD: текущая скорость + ближайшая камера и расстояние до неё.
//

import SwiftUI

struct SpeedHUDView: View {
    /// Второй план: на экране уже есть главный элемент (манёвр в навигации).
    /// Панель ужимается и приглушается — иерархия внимания важнее симметрии.
    var secondary = false
    @Environment(AppEnvironment.self) private var env

    /// Скорость и знак лимита — только когда едем (поездка или «похоже,
    /// едем»). Стоя «0 км/ч» — не факт, а пустое место в самом заметном углу
    /// экрана (5.7); остаётся ближайшая камера.
    nonisolated static func showsSpeed(isTripActive: Bool, isProbablyDriving: Bool) -> Bool {
        isTripActive || isProbablyDriving
    }

    var body: some View {
        let location = env.location
        let showsSpeed = Self.showsSpeed(isTripActive: location.isTripActive,
                                         isProbablyDriving: location.isProbablyDriving)
        // Сплошная, не стекло: под панелью едет карта (см. SolidPanel).
        SolidPanel(cornerRadius: Theme.cornerPanel) {
            HStack(spacing: 0) {
                if showsSpeed {
                    speedBlock(location.speedKmh)

                    // Знак лимита дороги, по которой едем (данные OSM с нашего сервера).
                    if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                        limitSign(limit)
                            .padding(.trailing, 6)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Rectangle()
                        .fill(Theme.stroke)
                        .frame(width: 1, height: secondary ? 30 : 44)
                        .padding(.horizontal, 4)
                }

                // «До камеры» — тот же облик, что у чипа на стоянке (33H3).
                NearestCameraReadout()
            }
            .padding(.horizontal, secondary ? 12 : 18)
            .padding(.vertical, secondary ? 8 : 12)
            // Ночью — без приглушения прозрачностью (этап 31, 26.10): при
            // opacity 0,72 (в навигации 0,61) цифры становились серыми, и
            // карточка выглядела выключенной. Ночь уже приглушает сама тема —
            // графитовая панель и светлый, а не белый текст.
        }
        .fixedSize(horizontal: false, vertical: true)
        // Синего значка «город/трасса» в углу больше нет: его смысла с дороги
        // никто не прочёл (docs/plan_drive_ux_2026-10-07.md, п. 5). Режим
        // по-прежнему виден и меняется в быстрых тумблерах (долгий тап по HUD).
        .motionAnimation(Motion.standard, value: env.speedLimits.currentLimit)
        .motionAnimation(Motion.standard, value: showsSpeedNow)
        // VoiceOver: весь HUD — одна связная фраза, а не россыпь цифр.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var showsSpeedNow: Bool {
        Self.showsSpeed(isTripActive: env.location.isTripActive,
                        isProbablyDriving: env.location.isProbablyDriving)
    }

    /// «Скорость 47 км/ч. Лимит 60. Радар через 360 метров» — для VoiceOver.
    private var accessibilitySummary: String {
        var parts: [String] = []
        if showsSpeedNow {
            parts.append(String(format: String(localized: "Скорость %lld км/ч"),
                                Int(env.location.speedKmh.rounded())))
            if env.settings.speedLimitsEnabled, let limit = env.speedLimits.currentLimit {
                parts.append(String(format: String(localized: "Лимит %lld"), limit))
            }
        }
        if env.location.isSignalStale {
            parts.append(String(localized: "Нет сигнала GPS"))
        } else if let camera = env.location.displayNearestCamera,
                  let distance = env.location.displayDistanceToNearest {
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
        return SpeedLimitSign(limit: limit,
                              isAssumed: env.speedLimits.isCurrentLimitAssumed,
                              glow: over ? Theme.danger.opacity(0.9) : .black.opacity(0.3),
                              glowRadius: over ? 10 : 3)
            .scaleEffect(over ? 1.08 : 1.0)
            // Шесть качков и стоп: «пока превышаешь» длится десятки минут, а
            // вечный пульс с тенью поверх живой карты — офскрин-проход GPU
            // каждый кадр. Красная тень остаётся — сигнал не исчезает.
            .motionAnimation(over ? .easeInOut(duration: 0.55).repeatCount(6, autoreverses: true)
                            : .easeOut(duration: 0.25),
                       value: over)
    }

    private func speedBlock(_ speed: Double) -> some View {
        VStack(spacing: 0) {
            // Крупно: за рулём HUD читается взглядом <1 сек. На втором плане
            // цифра меньше — но остаётся читаемой.
            Text("\(Int(speed.rounded()))")
                .font(.denseNumeral(secondary ? 26 : 34, .bold))
                .monospacedDigit()
                .foregroundStyle(env.speedLimits.isOverspeeding ? Theme.danger : Theme.textPrimary)
                .liveNumber()
            HStack(spacing: 3) {
                Text("км/ч")
                    .font(.dense(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                if env.location.isLowPowerMode {
                    // Энергосбережение iOS: точность GPS снижена (голос о камерах — как всегда).
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .frame(width: 74)
    }

    /// Цвет значка по БЛИЗОСТИ, а не по типу камеры. Красный кружок при камере в
    /// десяти километрах читается как тревога, хотя ехать до неё двадцать минут:
    /// далеко — спокойный серый, на подходе — приглушённый цвет типа, в зоне
    /// оповещения — полный цвет со свечением.
    /// Значок поверх `proximityTint`: на цвете типа — его glyphTint (тёмный на
    /// светлом радаре), на сером «далеко» — контрастный фону темы.
    /// Одно правило цвета на HUD и на чип камеры в навигации: камера не может
    /// быть «далёкой» в одном месте экрана и «тревожной» в другом.
    static func proximityGlyph(_ distance: Double, _ camera: Camera, radius: Double) -> Color {
        distance <= radius * 3 ? camera.kind.glyphTint : Theme.background
    }

    static func proximityTint(_ distance: Double, _ camera: Camera, radius: Double) -> Color {
        if distance <= radius { return camera.kind.tint }
        if distance <= radius * 3 { return camera.kind.tint.opacity(0.5) }
        return Theme.textTertiary
    }

    /// Подпись под расстоянием. Когда позиция грубая (кэш при запуске, слабый
    /// сигнал в помещении), честно говорим об этом: иначе цифра выглядит живой.
    @ViewBuilder
    static func caption(for camera: Camera, location: LocationService) -> some View {
        if location.isPositionCoarse {
            Text("уточняем положение")
                .foregroundStyle(Theme.warning)
        } else if location.familiarCameraIDs.contains(camera.id) {
            // «Своя» камера: голоса о ней не будет, и человек должен видеть
            // почему — иначе тишина читается как поломка. Коротко и с
            // галочкой: «своя камера — без голоса» на ширине HUD обрезалось
            // до «без голо…», то есть ровно до непонятного.
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .fontWeight(.bold)
                Text("без голоса")
            }
            .foregroundStyle(Theme.success)
        } else if location.isDirectionalFilteringActive {
            Text(String(format: String(localized: "%@ по курсу"), camera.kind.genitivePhrase))
                .foregroundStyle(Theme.textSecondary)
        } else {
            Text(camera.kind.genitivePhrase)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
