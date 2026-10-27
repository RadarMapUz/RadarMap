//
//  StatusBanner.swift
//  RadarMap
//
//  Одна форма баннера «почему не в полную силу» над картой (5.10): нет сети,
//  перегрев, лимиты, объявление сервера, доступ к геопозиции и уведомлениям.
//  Их было два вида — у баннера состояния крестик, свой кегль и обводка
//  цветом, у баннера доступа другой кегль, тень и серая обводка, — и рядом
//  они читались как два разных приложения.
//

import SwiftUI

struct StatusBanner: View {
    struct Action {
        let title: String
        var isBusy = false
        let perform: () -> Void
    }

    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var action: Action?
    /// Крестик — только у того, что можно отложить; доступ к геопозиции
    /// закрыть нельзя: без него приложение не делает главного.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.rounded(19, .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    // Кнопка, а не подпись: промах за рулём — второй взгляд.
                    Button(action: action.perform) {
                        Text(action.isBusy ? String(localized: "Загружаю…") : action.title)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Theme.controlSize)
                            .background(Theme.quietFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(action.isBusy)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .tapTarget()         // палец за рулём крупнее крестика
                }
                .accessibilityLabel(Text("Закрыть объявление"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .stroke(tint.opacity(0.35), lineWidth: 1))
    }
}
