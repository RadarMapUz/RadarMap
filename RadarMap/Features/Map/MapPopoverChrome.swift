//
//  MapPopoverChrome.swift
//  RadarMap
//
//  Общее у меню на карте («Карта», «Оповещения», 20.10): рамка, от которой
//  меню открывается, шапка с крестиком, значок на кружке и поведение
//  карточки — VoiceOver и закрытие по простою. Состояние «что открыто» —
//  MapPopover (чистая логика), слой над экраном — MapScreen+Popovers.
//

import SwiftUI

/// Рамки, от которых открываются меню: кнопка слоёв, стопка верхних панелей.
///
/// Меню рисуется НЕ там, где его кнопка, а в слое над всем экраном — иначе
/// касание мимо попадало бы в карту и кнопки, лежащие в стопке выше него.
/// Рамка кнопки доходит до этого слоя предпочтением, и меню встаёт ровно
/// там, где стояло бы рядом с ней.
struct MapPopoverAnchors: PreferenceKey {
    static let defaultValue: [MapPopover: Anchor<CGRect>] = [:]

    static func reduce(value: inout [MapPopover: Anchor<CGRect>],
                       nextValue: () -> [MapPopover: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Шапка меню: название и крестик — одинаковые у обоих меню.
///
/// Крестик есть у обоих, хотя касание мимо закрывает меню и без него: до
/// 20.10 он был у одного «Оповещений», и «Карту» не понимали как закрыть.
/// Видимый крестик — подсказка, которая не требует знать жест; и он же —
/// путь для VoiceOver, где касания «мимо» не бывает.
struct MapPopoverHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.rounded(13, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.rounded(18))
                    .foregroundStyle(Theme.textTertiary)
                    .tapTarget()
            }
            .accessibilityLabel(Text("Закрыть"))
        }
    }
}

/// Значок пункта меню на кружке: синий с белым — включено, серый — нет.
/// Один облик у слоёв, звука и вибро: «включено» читается одинаково в обоих
/// меню, а не галочкой в одном и заливкой в другом.
struct MapPopoverGlyph: View {
    let systemName: String
    let isOn: Bool
    var size: CGFloat = 30
    var glyph: CGFloat = 14

    var body: some View {
        Image(systemName: systemName)
            // Кегль от кружка, а не от шкалы: кружок не растёт с крупным
            // шрифтом (растёт подпись рядом), и значок по шкале вылезал бы
            // из него при uz XXL.
            .font(.roundedFree(glyph, .semibold))
            // Белое на accentFill (палитра А, PaletteTests).
            .foregroundStyle(isOn ? Theme.onAccentFill : Theme.textSecondary)
            .frame(width: size, height: size)
            .background(isOn ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.background),
                        in: Circle())
            .accessibilityHidden(true)
    }
}

extension View {
    /// Поведение меню на карте: для VoiceOver — модальная группа с жестом
    /// «назад» (касания мимо у него нет), для всех — закрытие через
    /// `AppConfig.mapPopoverIdleSeconds` без касаний. `activity` — то, что
    /// меняется от касаний внутри (значения тумблеров): сменилось — отсчёт
    /// заново.
    func mapPopoverCard<Activity: Equatable>(activity: Activity,
                                             onClose: @escaping () -> Void) -> some View {
        modifier(MapPopoverCard(activity: activity, onClose: onClose))
    }
}

private struct MapPopoverCard<Activity: Equatable>: ViewModifier {
    let activity: Activity
    let onClose: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            // Карта и кнопки под меню закрыты ловушкой касаний — VoiceOver
            // не должен уводить фокус туда, где касание ничего не нажмёт.
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onClose)
            .task(id: activity) {
                // С VoiceOver меню читают дольше восьми секунд — не закрываем.
                guard !voiceOver else { return }
                await Task.pause(seconds: AppConfig.mapPopoverIdleSeconds)
                guard !Task.isCancelled else { return }
                onClose()
            }
    }
}
