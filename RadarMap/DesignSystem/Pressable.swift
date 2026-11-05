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
import UIKit

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

    var body: some View {
        let response = TouchResponse.of(role, reduceMotion: reduceMotion)
        let generator = response.haptic.generator
        Button(role: configuration.role) {
            // До действия: кнопка, которая им убирает себя с экрана, иначе
            // осталась бы без вибрации.
            TouchHaptics.play(generator)
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(PressFace(response: response) { TouchHaptics.prepare(generator) })
    }
}

private struct PressFace: ButtonStyle {
    let response: TouchResponse
    let onPressDown: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        PressFaceBody(configuration: configuration, response: response, onPressDown: onPressDown)
    }
}

private struct PressFaceBody: View {
    let configuration: ButtonStyleConfiguration
    let response: TouchResponse
    let onPressDown: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed ? response.pressedScale : 1)
            .opacity(isEnabled ? (pressed ? response.pressedOpacity : 1) : TouchResponse.disabledOpacity)
            .motionAnimation(pressed ? Motion.pressIn : Motion.release, value: pressed)
            .onChange(of: pressed) { _, now in
                if now { onPressDown() }
            }
    }
}

/// Генераторы UIKit по одному на силу: подготовленный на касании вниз,
/// удар звучит без задержки на отпускании. Системные вибрации выключены —
/// генераторы молчат сами.
enum TouchHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let selection = UISelectionFeedbackGenerator()

    static func prepare(_ generator: TouchGenerator) {
        switch generator {
        case .none:                       break
        case .selection:                  selection.prepare()
        case .impact(let weight, _):      impact(weight).prepare()
        }
    }

    static func play(_ generator: TouchGenerator) {
        switch generator {
        case .none:
            break
        case .selection:
            selection.selectionChanged()
        case .impact(let weight, let intensity):
            impact(weight).impactOccurred(intensity: intensity)
        }
    }

    private static func impact(_ weight: TouchGenerator.Weight) -> UIImpactFeedbackGenerator {
        switch weight {
        case .light:  light
        case .medium: medium
        case .soft:   soft
        }
    }
}
