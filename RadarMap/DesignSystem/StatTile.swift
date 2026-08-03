//
//  StatTile.swift
//  RadarMap
//
//  Плитка метрики (иконка + число + подпись) и метрика шеринг-карточки.
//  Общий вид статистики в Итогах и деталке поездки.
//

import SwiftUI

/// Плитка «иконка сверху, крупное число, подпись» — сетка метрик поездки.
struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color
    var animatesValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.rounded(18, .bold)).foregroundStyle(color)
            Text(value)
                .font(.rounded(28, .bold))
                .foregroundStyle(Theme.textPrimary)
                .modifier(NumericTransition(active: animatesValue, value: value))
                .lineLimit(1)               // «5 из 7» и узбекские подписи длиннее
                .minimumScaleFactor(0.6)    // русских — плитка не должна ломаться
            Text(label)
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard(radius: Theme.cornerMedium)
        // VoiceOver: «128 км, дистанция» одной фразой, а не три отдельных элемента.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value), ") + Text(label))
    }
}

private struct NumericTransition: ViewModifier {
    let active: Bool
    let value: String
    func body(content: Content) -> some View {
        if active {
            content.contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: value)
        } else {
            content
        }
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
