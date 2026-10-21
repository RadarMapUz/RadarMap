//
//  CommuteAccuracyCard.swift
//  RadarMap
//
//  «Точность прогноза» в «Дороге на работу» (этап 24.1): насколько призрак
//  ошибался с прибытием по последним поездкам. Появляется с пятой поездки —
//  средняя по двум не «в среднем». Цифры готовые (CommuteAccuracy.Stats),
//  вьюха не считает.
//

import SwiftUI

struct CommuteAccuracyCard: View {
    let stats: CommuteAccuracy.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconBadge(symbol: "scope", tint: Theme.accent, size: 28)
                Text("Точность прогноза")
                    .font(.rounded(14, .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(Self.mainLine(stats))
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let bias = Self.biasLine(stats) {
                Text(bias)
                    .font(.rounded(13))
                    .foregroundStyle(stats.biasMinutes > 0 ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(format: String(localized: "По последним %lld поездкам. Прогноз понемногу подстраивается под свою ошибку."),
                        stats.trips))
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
        .accessibilityElement(children: .combine)
    }

    /// «Прогноз прибытия ошибался в среднем на 3 мин» / «…точен до минуты».
    static func mainLine(_ stats: CommuteAccuracy.Stats) -> String {
        stats.isExact
            ? String(localized: "Прогноз прибытия точен до минуты")
            : String(format: String(localized: "Прогноз прибытия ошибался в среднем на %lld мин"),
                     stats.meanMinutes)
    }

    /// Сдвиг в одну сторону — от минуты: «в среднем приезжали на 2 мин позже».
    static func biasLine(_ stats: CommuteAccuracy.Stats) -> String? {
        let minutes = stats.biasMinutes
        if minutes >= 1 {
            return String(format: String(localized: "В среднем приезжали на %lld мин позже прогноза"), minutes)
        }
        if minutes <= -1 {
            return String(format: String(localized: "В среднем приезжали на %lld мин раньше прогноза"), -minutes)
        }
        return nil
    }
}
