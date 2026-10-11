//
//  MetricsCard.swift
//  RadarMap
//
//  Карточка метрик поездки и метрика шеринг-карточки.
//

import SwiftUI

/// Метрики поездки одной карточкой: две колонки «значок · число · подпись»,
/// строки разделены волосяной линией. Заменила сетку плиток StatTile: у каждой
/// плитки был крупный значок своего цвета, хотя цвет ничего не значил, а
/// четыре числа занимали полэкрана. Значки — одного цвета (`Theme.accent`):
/// цветом в приложении говорит состояние, а здесь состояния нет.
struct MetricsCard: View {
    struct Item: Identifiable {
        let value: String
        let label: String
        let icon: String
        var id: String { label }
    }

    let items: [Item]

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 2).map { index in
            Array(items[index..<min(index + 2, items.count)])
        }
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(Theme.stroke) }
                HStack(alignment: .top, spacing: 12) {
                    cell(row[0])
                    if row.count > 1 { cell(row[1]) } else { Color.clear.frame(maxWidth: .infinity) }
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.vertical, -4)
        .statCard(padding: 16, radius: Theme.cornerMedium)
    }

    private func cell(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.icon)
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.value)
                    .font(.rounded(20, .bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(item.label)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // VoiceOver: «64,3 км, пройдено пути» одной фразой.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.value), \(item.label)"))
    }
}

/// Метрика для шеринг-карточек (белый текст на тёмном фоне) + разделитель.
struct ShareMetric: View {
    let value: String
    let label: String
    /// Иконка над числом — метрика читается без чтения подписи.
    var icon: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        VStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

struct ShareMetricDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 44)
    }
}
