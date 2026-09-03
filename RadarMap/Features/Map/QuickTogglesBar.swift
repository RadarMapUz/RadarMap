//
//  QuickTogglesBar.swift
//  RadarMap
//
//  Быстрые тумблеры по долгому тапу на HUD: заглушить голос на время разговора
//  или сменить режим оповещений — не отрывая глаз от дороги и не лазая в Настройки.
//

import SwiftUI

struct QuickTogglesBar: View {
    @Environment(AppEnvironment.self) private var env
    let onClose: () -> Void

    var body: some View {
        @Bindable var settings = env.settings
        VStack(spacing: 12) {
            HStack {
                Text("Оповещения")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.rounded(18))
                        .foregroundStyle(Theme.textTertiary)
                        .tapTarget()
                }
                .accessibilityLabel(Text("Закрыть"))
            }

            HStack(spacing: 10) {
                toggle("Звук", "speaker.wave.2.fill", isOn: $settings.soundEnabled)
                toggle("Вибро", "iphone.gen3.radiowaves.left.and.right",
                       isOn: $settings.hapticsEnabled)
            }

            // Голос — одна шкала «молча → умно → обо всех». Переключают её
            // именно в дороге («хватит болтать»), поэтому место ей здесь.
            HStack(spacing: 6) {
                ForEach(VoiceMode.allCases) { mode in
                    voiceChip(mode, selected: settings.voiceMode == mode) {
                        settings.voiceMode = mode
                    }
                }
            }
            Text(settings.voiceMode.detail)
                .font(.rounded(10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Сели пассажиром, а поездка уже стартовала — выход в один тап.
            if env.location.isTripActive {
                Button {
                    env.location.markPassenger()
                    onClose()
                } label: {
                    Label("Я пассажир — завершить без записи", systemImage: "figure.seated.seatbelt")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerLarge))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func toggle(_ title: LocalizedStringKey, _ icon: String,
                        isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.rounded(17, .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Theme.background : Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(isOn.wrappedValue ? AnyShapeStyle(Theme.accent.gradient)
                                                  : AnyShapeStyle(Theme.surface), in: Circle())
                Text(title)
                    .font(.rounded(11, .medium))
                    .foregroundStyle(isOn.wrappedValue ? Theme.textPrimary : Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        // Состояние тумблера закодировано только цветом: без .isSelected
        // VoiceOver называет его «кнопка Звук» и включённый неотличим от
        // выключенного.
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .accessibilityValue(isOn.wrappedValue ? Text("включено") : Text("выключено"))
    }

    /// Строка-галочка на всю ширину: для тумблеров, чьё название не влезает в круг.
    private func checkRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textTertiary)
                Text(title)
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .accessibilityValue(isOn.wrappedValue ? Text("включено") : Text("выключено"))
    }

    /// Чип режима голоса — та же форма, что была у города/трассы.
    private func voiceChip(_ mode: VoiceMode, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.rounded(11, .semibold))
                Text(mode.title).font(.rounded(12, .semibold))
            }
            .foregroundStyle(selected ? Theme.background : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(Theme.accent.gradient)
                                 : AnyShapeStyle(Theme.surface), in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func modeChip(_ mode: AlertMode, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.rounded(11, .semibold))
                Text(mode.title).font(.rounded(12, .semibold))
            }
            .foregroundStyle(selected ? Theme.background : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(Theme.accent.gradient)
                                 : AnyShapeStyle(Theme.surface), in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
