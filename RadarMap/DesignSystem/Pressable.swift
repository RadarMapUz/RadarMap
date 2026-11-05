//
//  Pressable.swift
//  RadarMap
//
//  Единый отклик касания (задача 41): пружинное сжатие и вибрация по роли
//  кнопки (`TouchRole`, правило — Models/TouchFeedback.swift). Один стиль на
//  всё касаемое — второй не заводить.
//
//  Только касание: ни анимаций, ни вибраций на тиках GPS. Вибрация
//  оповещения о камере (`AlertPlayer.haptic(level:)`) идёт своим путём, и
//  экран оповещения держит свой отклик (`.ownFeedback`).
//

import SwiftUI

/// Стиль нажатия для любой кнопки приложения.
///
/// Примитивный стиль поверх настоящей `Button`: так вибрация звучит, когда
/// кнопка сработала, а прокрутка, VoiceOver и `.disabled` остаются системными.
struct PressableStyle: PrimitiveButtonStyle {
    var role: TouchRole = .regular

    init(_ role: TouchRole = .regular) {
        self.role = role
    }

    func makeBody(configuration: Configuration) -> some View {
        PressableButton(configuration: configuration,
                        role: TouchRole.resolve(role, isCancelButton: configuration.role == .cancel))
    }
}

private struct PressableButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let role: TouchRole

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0

    var body: some View {
        let response = TouchResponse.of(role, reduceMotion: reduceMotion)
        Button(role: configuration.role) {
            if response.haptic != .none { taps &+= 1 }
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(PressFace(response: response))
        .sensoryFeedback(trigger: taps) { _, _ in response.haptic.sensory }
    }
}

private struct PressFace: ButtonStyle {
    let response: TouchResponse

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed ? response.pressedScale : 1)
            .opacity(pressed ? response.pressedOpacity : 1)
            .motionAnimation(pressed ? Motion.pressIn : Motion.release, value: pressed)
    }
}

extension TouchHaptic {
    var sensory: SensoryFeedback? {
        switch self {
        case .none:      nil
        case .selection: .selection
        case .light:     .impact(weight: .light)
        case .medium:    .impact(weight: .medium)
        case .soft:      .impact(flexibility: .soft, intensity: 0.6)
        }
    }
}
