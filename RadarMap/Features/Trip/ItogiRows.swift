//
//  ItogiRows.swift
//  RadarMap
//
//  Одна строка раздела на все экраны «Итогов» (34b, вариант Г-A владельца):
//  значок в нейтральной плашке · заголовок · подпись · одно число · шеврон.
//  До 34 на главном листе жили пять видов карточек (герой, риск-карта,
//  compactRow, statCard с SectionHeader, широкая кнопка «Понятно») и три
//  кегля заголовков — теперь всё, что не карточка-ответ, — эта строка.
//
//  Значки — только из словаря `Icon`, одной толщины (IconBadge: .semibold),
//  в одной плашке (`Theme.quietFill`), цвет символа нейтральный
//  (`Theme.textSecondary`). Цвет — только там, где он что-то значит: камера
//  красная (тот же глиф, что на карте), штраф к оплате — красное число.
//

import SwiftUI

/// Строка раздела: модель, а не вью — группа сама расставляет разделители,
/// и пропущенная по условию строка не оставляет двойной линии.
struct ItogiRowItem: Identifiable {
    let id: String
    let symbol: String
    var tint: Color = Theme.textSecondary
    let title: String
    var caption: String? = nil
    var value: String? = nil
    var valueTint: Color = Theme.textPrimary
    /// nil — строка только сообщает (без шеврона и касания).
    var action: (() -> Void)? = nil
    var accessibilityHint: String? = nil
}

/// Группа строк одной карточкой с волосяными разделителями.
struct ItogiRowGroup: View {
    let items: [ItogiRowItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().overlay(Theme.stroke).padding(.leading, 56)
                }
                ItogiRow(item: item)
            }
        }
        .statCard(padding: 0, radius: Theme.cornerMedium)
    }
}

struct ItogiRow: View {
    let item: ItogiRowItem

    var body: some View {
        if let action = item.action {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: {
                content(chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(item.accessibilityHint ?? ""))
        } else {
            content(chevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: item.symbol, tint: item.tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value = item.value {
                Text(value)
                    .font(.rounded(15, .bold).monospacedDigit())
                    .foregroundStyle(item.valueTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(minHeight: Theme.controlSize)
        .contentShape(Rectangle())
    }
}

/// Заголовок группы на листе — подпись раздела, не крупнее заголовка строки.
struct ItogiGroupTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.rounded(13, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, -6)
            .accessibilityAddTraits(.isHeader)
    }
}
