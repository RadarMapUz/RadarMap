//
//  QuickTogglesBar.swift
//  RadarMap
//
//  Быстрые тумблеры по тапу на HUD: заглушить голос на время разговора
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
            // Пояснение — абзац для чтения: на ходу его не читают, а панель
            // от него на треть выше (5.5). Стоя — показываем.
            if env.location.speedKmh < AppConfig.speakSpeedThresholdKmh {
                Text(settings.voiceMode.detail)
                    .font(.rounded(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                        // Внутри сплошной панели — заливка фона: surface на
                        // surface растворял кнопку (ревью 4.2).
                        .background(Theme.background, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        // Сплошная панель, не стекло: над картой, которая едет, стекло
        // пересчитывает размытие каждый её кадр (правило 13.10, 4.2).
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).strokeBorder(Theme.edgePanel, lineWidth: 1))
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
                    // Белое на accentFill (палитра А, PaletteTests): тёмный
                    // фон поверх светлого ночного accent читался хуже (4.4).
                    .foregroundStyle(isOn.wrappedValue ? Theme.onAccentFill : Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(isOn.wrappedValue ? AnyShapeStyle(Theme.accentFill)
                                                  : AnyShapeStyle(Theme.background), in: Circle())
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

    /// Чип режима голоса — та же форма, что была у города/трассы.
    private func voiceChip(_ mode: VoiceMode, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.rounded(11, .semibold))
                Text(mode.title).font(.rounded(12, .semibold))
            }
            .foregroundStyle(selected ? Theme.onAccentFill : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
            .background(selected ? AnyShapeStyle(Theme.accentFill)
                                 : AnyShapeStyle(Theme.background), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        // Выбранный режим виден только цветом — VoiceOver должен его слышать.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}
