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

    /// Насколько приглушить док.
    ///
    /// Ночью на схеме не должно быть ничего ярче камеры — а док скорости
    /// бывал ярче неё. Это не про красоту: ночью зрачок раскрыт, и самое
    /// светлое пятно на экране забирает взгляд себе. Камера — единственное,
    /// ради чего приложение существует, и забирать взгляд должна она.
    ///
    /// Но когда камера УЖЕ говорит, приглушать нечего: тревога поднимает всё
    /// вместе, иначе водитель увидит предупреждение и не увидит, с какой
    /// скоростью едет.
    static func dimming(secondary: Bool, night: Bool, alertLevel: Int) -> Double {
        if alertLevel >= 1 { return 1 }
        let base = secondary ? 0.85 : 1.0
        return night ? base * 0.72 : base
    }

    var body: some View {
        let location = env.location
        GlassCard(cornerRadius: Theme.cornerPanel) {
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
                    .frame(width: 1, height: secondary ? 30 : 44)
                    .padding(.horizontal, 4)

                nearestBlock(camera: location.nearestCamera,
                             distance: location.distanceToNearest)
            }
            .padding(.horizontal, secondary ? 12 : 18)
            .padding(.vertical, secondary ? 8 : 12)
        }
        // День или ночь спрашиваем у НАСТРОЙКИ, а не у флага палитры схемы.
        //
        // Флаг пишется только внутри SketchState.refresh, то есть лишь когда
        // на экране своя схема или спидометр. На карте Apple он оставался
        // ложью по умолчанию — приложение считало, что ночь, и приглушало
        // карточку до 0,72 (в навигации до 0,61) ровно в том сценарии, ради
        // которого она и сделана: телефон в держателе на солнце.
        .opacity(SpeedHUDView.dimming(
            secondary: secondary,
            night: !env.settings.mapAppearance.isDaylight(at: env.location.currentCoordinate),
            alertLevel: env.location.alertLevel))
        .fixedSize(horizontal: false, vertical: true)
        // Синего значка «город/трасса» в углу больше нет: его смысла с дороги
        // никто не прочёл (docs/plan_drive_ux_2026-10-07.md, п. 5). Режим
        // по-прежнему виден и меняется в быстрых тумблерах (долгий тап по HUD).
        .motionAnimation(.spring(duration: 0.3), value: env.speedLimits.currentLimit)
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
        return SpeedLimitSign(limit: limit,
                              isAssumed: env.speedLimits.isCurrentLimitAssumed)
            .shadow(color: over ? Theme.danger.opacity(0.9) : .black.opacity(0.3),
                    radius: over ? 10 : 3)
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
                .font(.rounded(secondary ? 26 : 34, .bold))
                .monospacedDigit()
                .foregroundStyle(env.speedLimits.isOverspeeding ? Theme.danger : Theme.textPrimary)
                .contentTransition(.numericText(value: speed))
                .motionAnimation(.easeOut(duration: 0.3), value: Int(speed.rounded()))
            HStack(spacing: 3) {
                Text("км/ч")
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                if env.location.isLowPowerMode {
                    // Энергосбережение iOS: точность GPS снижена, голос отключён.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning)
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
                    .foregroundStyle(Theme.warning)
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
            // Тот же радиус, по которому поднимается тревога: с базовым
            // значок на трассе оставался «далёким» уже после того, как
            // голос о камере сказал.
            let near = distance <= env.location.effectiveAlertRadius
            HStack(spacing: 12) {
                ZStack {
                    Image(systemName: camera.kind.symbolName)
                        .font(.rounded(16, .bold))
                        .foregroundStyle(proximityGlyph(distance, camera))
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
                            .motionAnimation(.easeOut(duration: 0.3), value: Int(angle / 10))
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
                        .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
                    Self.caption(for: camera, location: env.location)
                        .font(.rounded(11, .medium))
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
    /// Значок поверх `proximityTint`: на цвете типа — его glyphTint (тёмный на
    /// светлом радаре), на сером «далеко» — контрастный фону темы.
    private func proximityGlyph(_ distance: Double, _ camera: Camera) -> Color {
        Self.proximityGlyph(distance, camera, radius: env.location.effectiveAlertRadius)
    }

    private func proximityTint(_ distance: Double, _ camera: Camera) -> Color {
        Self.proximityTint(distance, camera, radius: env.location.effectiveAlertRadius)
    }

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

    private func approachBar(_ progress: Double) -> some View {
        // Полоска приближения «греется» по состоянию, а не произвольными
        // системными цветами: те же три роли, что и везде.
        let tint = Theme.role(progress > 0.66 ? .alarm : progress > 0.33 ? .attention : .neutral)
        return Capsule()
            .fill(Theme.stroke)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(progress, 0.04), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: 3)
            .padding(.top, 4)
            .motionAnimation(.easeOut(duration: 0.3), value: progress)
    }
}
