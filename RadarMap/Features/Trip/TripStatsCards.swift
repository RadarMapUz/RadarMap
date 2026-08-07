//
//  TripStatsCards.swift
//  RadarMap
//
//  Бейдж достижения и шеринг-карточка «Мои итоги» — вспомогательные вью
//  экрана Итогов, вынесены из основного файла.
//

import SwiftUI
import UIKit

// MARK: - Бейдж достижения

/// Полученный — залит акцентом; будущий — серый с кольцом прогресса, видно, сколько осталось.
struct AchievementBadge: View {
    let badge: Achievement

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if badge.earned {
                    Circle().fill(Theme.accent.gradient)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 6)
                } else {
                    Circle().fill(Theme.surface)
                    Circle()
                        .trim(from: 0, to: badge.fraction)
                        .stroke(Theme.accent.opacity(0.55),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.5)
                }
                Image(systemName: badge.icon)
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(badge.earned ? Theme.background : Theme.textTertiary)
            }
            .frame(width: 56, height: 56)

            Text(badge.title)
                .font(.rounded(10, .medium))
                .foregroundStyle(badge.earned ? Theme.textPrimary : Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 82)
    }
}

// MARK: - Полоса KPI

/// Четыре цифры одной строкой вместо сетки 2×2 из разноцветных плиток.
/// Сетка занимала полэкрана и красила каждую цифру в свой цвет — цвет
/// переставал что-либо значить. Здесь цветом отмечено только состояние
/// (зона риска, рейтинг), а справочные числа спокойные.
struct KPIStrip: View {
    let summary: PeriodSummary
    /// «5 из 7» — считает экран: строке нужны период и якорь, а карточке нет.
    let activeDaysText: String

    var body: some View {
        HStack(spacing: 0) {
            // Именно ПРОЕЗДЫ: одна камера, пройденная дважды, — это два.
            // Легенда карты считает уникальные точки — слово должно отличаться.
            StatStripCell(value: "\(summary.cameras)", label: "проездов камер",
                          icon: "camera.metering.center.weighted")
            StatStripDivider()
            StatStripCell(value: activeDaysText, label: "дней за рулём", icon: "calendar")
            StatStripDivider()
            StatStripCell(value: "\(Int(summary.averageSpeedKmh))", label: "средняя км/ч",
                          icon: "gauge.with.dots.needle.33percent")
            StatStripDivider()
            StatStripCell(value: "\(Int(summary.maxSpeedKmh))", label: "макс. км/ч",
                          icon: "gauge.with.dots.needle.100percent")
        }
        .statCard(padding: 14)
    }

}

/// Ячейка полосы статистики: иконка, крупная цифра, подпись. Общая для
/// KPI периода и пожизненной полосы — цифры на них обязаны выглядеть одинаково.
struct StatStripCell: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.rounded(21, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value), ") + Text(label))
    }
}

struct StatStripDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 42)
    }
}

// MARK: - Когда рискуете

/// Превышения по времени суток. «Где» уже отвечает карта, а «когда» до этого
/// не отвечал никто — хотя вечерний час пик и пустая ночная дорога дают
/// совершенно разные привычки.
struct RiskHoursCard: View {
    let summary: PeriodSummary

    var body: some View {
        if summary.overPasses >= AppConfig.insightMinOverForHours,
           let peak = summary.peakBlock {
            let blocks = summary.overByBlock
            let top = max(blocks.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Когда рискуете")) {
                    Text(peak.title)
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.danger)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, count in
                        bar(count: count, peak: top, isPeak: index == peak.index,
                            hour: index * 4)
                    }
                }
            }
            .statCard()
        }
    }

    private func bar(count: Int, peak: Int, isPeak: Bool, hour: Int) -> some View {
        VStack(spacing: 6) {
            Text(count > 0 ? "\(count)" : " ")
                .font(.rounded(10, .bold).monospacedDigit())
                .foregroundStyle(isPeak ? Theme.danger : Theme.textTertiary)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isPeak ? Theme.danger.gradient : Theme.accent.opacity(0.35).gradient)
                // Пустой блок оставляет тонкую риску: полоса читается как шкала
                // суток, а не как случайный набор столбиков.
                .frame(height: max(3, 52 * Double(count) / Double(peak)))
            Text(String(format: "%02d", hour))
                .font(.rounded(10, .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "С %1$02d до %2$02d часов: превышений %3$lld"),
                                        hour, (hour + 4) % 24, count)))
    }
}
