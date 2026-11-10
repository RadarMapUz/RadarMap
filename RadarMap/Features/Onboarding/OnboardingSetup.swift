//
//  OnboardingSetup.swift
//  RadarMap
//
//  Третий экран знакомства — два выбора с готовыми значениями, и показ окон
//  iOS на экране разрешений. Пройти можно одним нажатием.
//

import SwiftUI

extension View {
    /// Блоки входят снизу по очереди; при «Уменьшении движения» просто появляются.
    func onboardingEntrance(index: Int, shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .motionAnimation(.easeOut(duration: 0.4).delay(0.08 + Double(index) * 0.09), value: shown)
    }
}

// MARK: - Переключатель

/// Варианты с общей подвижной капсулой: выбранная плашка переезжает, а не
/// вспыхивает на новом месте.
struct OnboardingSegment<Option: Hashable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> LocalizedStringKey
    var symbol: ((Option) -> String)? = nil
    let pick: (Option) -> Void

    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selected
                Button {
                    withMotion(Motion.standard) { pick(option) }
                } label: {
                    HStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol(option)).font(.dense(13, .semibold)) }
                        Text(title(option))
                            .font(.dense(15, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(isOn ? Color.white : Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                    .background {
                        if isOn {
                            Capsule().fill(Theme.accentFill).matchedGeometryEffect(id: "on", in: capsule)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.quietFill, in: Capsule())
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - Настройки

struct OnboardingSetupPage: View {
    /// Экран виден: волна голоса не считает кадры за кадром, блоки входят по очереди.
    var playing = true
    @Environment(AppEnvironment.self) private var env

    private enum TripStart: Hashable { case itself, button }

    var body: some View {
        let settings = env.settings
        let start: TripStart = settings.tripStartMode == .manual ? .button : .itself
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Как вам удобнее")
                    .font(.rounded(26, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Уже выбрано лучшее. Поменять можно в любой момент в Настройках.")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Голос").font(.rounded(15, .semibold)).foregroundStyle(Theme.textPrimary)
                OnboardingSegment(options: [VoiceMode.smart, .always, .off], selected: settings.voiceMode,
                                  title: Self.title) { settings.voiceMode = $0 }
                OnboardingVoicePreview(mode: settings.voiceMode, playing: playing)
                note(Self.note(settings.voiceMode)).id(settings.voiceMode)
                    .transition(.opacity)
            }
            .onboardingEntrance(index: 0, shown: playing)

            VStack(alignment: .leading, spacing: 10) {
                Text("Начало поездки").font(.rounded(15, .semibold)).foregroundStyle(Theme.textPrimary)
                OnboardingSegment(options: [TripStart.itself, .button], selected: start,
                                  title: { $0 == .itself ? "Сама" : "Кнопкой" },
                                  symbol: { $0 == .itself ? "wand.and.stars" : "hand.tap.fill" }) {
                    let mode: TripStartMode = $0 == .itself ? .smart : .manual
                    settings.tripStartMode = mode
                    env.setTripStartMode(mode)
                }
                note(start == .itself ? "В своей машине начнётся сама, в чужой спросит."
                                      : "Только когда нажмёте кнопку на карте.")
                    .id(start)
                    .transition(.opacity)
            }
            .onboardingEntrance(index: 1, shown: playing)

            if Bundle.main.preferredLocalizations.first != settings.appLanguage.mapCode {
                Text("Язык применяется полностью после перезапуска приложения.")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.rounded(13))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func title(_ mode: VoiceMode) -> LocalizedStringKey {
        switch mode {
        case .smart:  return "Умно"
        case .always: return "Обо всех"
        case .off:    return "Молча"
        }
    }

    private static func note(_ mode: VoiceMode) -> LocalizedStringKey {
        switch mode {
        case .smart:  return "Молчит, пока вы едете в лимите. Скажет при превышении и о внезапном радаре."
        case .always: return "Скажет о каждой камере."
        case .off:    return "Камеру покажет панель, предупредит вибрация."
        }
    }
}

/// Что услышит водитель: фраза выбранного режима и волна голоса.
private struct OnboardingVoicePreview: View {
    let mode: VoiceMode
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode == .off ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.rounded(17, .semibold))
                .foregroundStyle(mode == .off ? Theme.textSecondary : Theme.accent)
                .frame(width: 26)
            Text(phrase)
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(mode)
                .transition(.opacity.combined(with: .offset(y: 6)))
            if mode != .off {
                OnboardingVoiceBars(playing: playing && !reduceMotion)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var phrase: LocalizedStringKey {
        switch mode {
        case .smart:  return "«Превышение. Камера, 300 метров»"
        case .always: return "«Камера, 300 метров»"
        case .off:    return "Только панель и вибрация"
        }
    }
}

/// Столбики голоса — по времени, а не из случайных чисел: одинаковы на каждом кадре.
struct OnboardingVoiceBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { context in
            let t = playing ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 6 + 14 * abs(sin(t * 4.2 + Double(index) * 0.9)))
                }
            }
            .frame(height: 22)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Показ окон iOS

/// Картинка окон iOS с указателем на нужный пункт: первое окно и второе по
/// очереди. Подписи повторяют подсказку под картинкой, чтобы текст и
/// рисунок говорили одно и то же.
struct OnboardingDialogGuide: View {
    var playing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stageSeconds = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { context in
            let moving = playing && !reduceMotion
            let raw = moving ? context.date.timeIntervalSinceReferenceDate / Self.stageSeconds : 0
            let stage = Int(raw.rounded(.down)) % 2
            let phase = raw - raw.rounded(.down)
            let fade = moving ? min(1, min(phase, 1 - phase) * 8) : 1
            let pulse = moving ? 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 5) : 0.6
            card(stage: stage, pulse: pulse).opacity(fade)
        }
        .frame(height: 148)
        .frame(maxWidth: .infinity)
        .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .accessibilityHidden(true)
    }

    private func card(stage: Int, pulse: Double) -> some View {
        VStack(spacing: 0) {
            Text(stage == 0 ? "Окно 1 из 2" : "Окно 2 из 2")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 7)
            Divider()
            if stage == 0 {
                option("При использовании", highlighted: true, pulse: pulse)
                Divider()
                option("Один раз", highlighted: false, pulse: pulse)
                Divider()
                option("Запретить", highlighted: false, pulse: pulse)
            } else {
                option("Всегда", highlighted: true, pulse: pulse)
                Divider()
                option("Оставить как есть", highlighted: false, pulse: pulse)
            }
        }
        .frame(width: 236)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private func option(_ title: LocalizedStringKey, highlighted: Bool, pulse: Double) -> some View {
        ZStack(alignment: .trailing) {
            Text(title)
                .font(.rounded(14, highlighted ? .bold : .regular))
                .foregroundStyle(highlighted ? Theme.accent : Theme.textSecondary)
                .frame(maxWidth: .infinity)
            if highlighted {
                ZStack {
                    Circle().stroke(Theme.accent.opacity(0.5 * (1 - pulse)), lineWidth: 2)
                        .frame(width: 18 + 12 * pulse, height: 18 + 12 * pulse)
                    Circle().fill(Theme.accent).frame(width: 14, height: 14)
                }
                .padding(.trailing, 14)
            }
        }
        .frame(height: 36)
    }
}
