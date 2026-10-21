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
    /// Пояснение режима голоса — по скорости в момент ОТКРЫТИЯ: на каждом
    /// фиксе в пробке 18–22 км/ч панель прыгала бы по высоте (ревью 19.10).
    @State private var showsDetail = true

    var body: some View {
        @Bindable var settings = env.settings
        VStack(spacing: 12) {
            MapPopoverHeader(title: "Оповещения", onClose: onClose)

            // «Звук» — сигнал у камеры (писк), голос — шкалой ниже. Колокол,
            // а не динамик: динамиками нарисована шкала голоса, и два
            // одинаковых динамика в одной карточке читались как одно и то же.
            HStack(spacing: 10) {
                toggle("Звук", Icon.alertSignal, isOn: $settings.soundEnabled)
                toggle("Вибро", Icon.vibration, isOn: $settings.hapticsEnabled)
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
            .fixedSize(horizontal: false, vertical: true)
            // Пояснение — абзац для чтения: на ходу его не читают, а панель
            // от него на треть выше (5.5). Стоя — показываем.
            if showsDetail {
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
        .onAppear { showsDetail = env.location.speedKmh < AppConfig.speakSpeedThresholdKmh }
        // Сплошная панель, не стекло: над картой, которая едет, стекло
        // пересчитывает размытие каждый её кадр (правило 13.10, 4.2).
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).strokeBorder(Theme.edgePanel, lineWidth: 1))
        // Таймер простоя — от любого переключения внутри (MapPopoverCard).
        .mapPopoverCard(activity: Activity(sound: settings.soundEnabled, haptics: settings.hapticsEnabled,
                                           voice: settings.voiceMode),
                        onClose: onClose)
    }

    /// То, что меняют касания внутри карточки: сменилось — отсчёт простоя заново.
    private struct Activity: Equatable {
        let sound: Bool
        let haptics: Bool
        let voice: VoiceMode
    }

    private func toggle(_ title: LocalizedStringKey, _ icon: String,
                        isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 5) {
                // Тот же кружок, что у слоёв «Карты» (MapPopoverGlyph): белое
                // на accentFill — включено (палитра А, PaletteTests, 4.4).
                MapPopoverGlyph(systemName: icon, isOn: isOn.wrappedValue, size: 44, glyph: 19)
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
            // Строкой, пока влезает; не влезает (uz крупным шрифтом на SE —
            // «Barchasi haqida» рвалось посреди слова) — значок над подписью,
            // а подпись переносится по словам.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: mode.symbol).font(.rounded(11, .semibold))
                    Text(mode.title).font(.rounded(12, .semibold)).lineLimit(1)
                }
                VStack(spacing: 2) {
                    Image(systemName: mode.symbol).font(.rounded(11, .semibold))
                    Text(mode.title).font(.rounded(12, .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
            .foregroundStyle(selected ? Theme.onAccentFill : Theme.textSecondary)
            .padding(.horizontal, 12)
            // Высота ряда — по самому высокому чипу: перенёсся один — растут все.
            .frame(maxWidth: .infinity, minHeight: Theme.controlSize, maxHeight: .infinity)
            .background(selected ? AnyShapeStyle(Theme.accentFill)
                                 : AnyShapeStyle(Theme.background),
                        in: RoundedRectangle(cornerRadius: Theme.controlSize / 2, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        // Выбранный режим виден только цветом — VoiceOver должен его слышать.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}
