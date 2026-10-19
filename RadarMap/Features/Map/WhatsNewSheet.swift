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
        VStack(alignment: .leading, spacing: 22) {
            Text("Что нового")
                .font(.rounded(28, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 28)
            ForEach(WhatsNew.items) { item in
                HStack(alignment: .top, spacing: 14) {
                    IconBadge(symbol: item.symbol, tint: Theme.accent, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.rounded(16, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(item.text)
                            .font(.rounded(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            PrimaryButton(title: "Понятно", systemImage: "checkmark") { dismiss() }
        }
        .padding(24)
        .background(Theme.screenBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
