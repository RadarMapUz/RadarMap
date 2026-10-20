//
//  WhatsNewSheet.swift
//  RadarMap
//
//  Экран «Что нового» — см. WhatsNew. Три строки и одна кнопка: его
//  закрывают за секунду, и больше он не появится.
//

import SwiftUI

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Прокрутка, а не голый столбец: на SE с крупным шрифтом три пункта
        // выпуска 2 по-узбекски заняли экран почти до кнопки (снимок 14.6),
        // и любой следующий выпуск подлиннее уже обрезался бы. Кнопка — под
        // прокруткой, всегда на виду.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Что нового")
                    .font(.rounded(28, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 28)
                ForEach(WhatsNew.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        IconBadge(symbol: item.symbol, tint: Theme.accent, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.rounded(16, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.text)
                                .font(.rounded(14))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Понятно", systemImage: "checkmark") { dismiss() }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                // Сплошной цвет края градиента, а не сам градиент: радиальный
                // фон начался бы заново от верха полосы и лёг светлой ступенью.
                .background(Theme.background)
        }
        .background(Theme.screenBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
