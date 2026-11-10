//
//  CommuteChartCard.swift
//  RadarMap
//
//  «Когда выезжать» на экране дороги: точка — поездка (выезд × время в пути),
//  полоса — обычный разброс (половина поездок), пунктир — обычно, крупная
//  точка — последняя поездка, зелёная полоса — окно-совет. Подписи —
//  легендой под графиком: «обычно 52 мин» над линией лежало на вечерних
//  точках (разбор 10.11). На графике ровно та выборка, по которой считается
//  «обычно»; поездки в другое время — строкой под ним.
//

import Charts
import SwiftUI

struct CommuteChartCard: View {
    let summary: Commute.Summary

    var body: some View {
        let axis = Self.axis(summary)
        let start = Self.today(axis.domain.lowerBound), end = Self.today(axis.domain.upperBound)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: "clock.fill", tint: Theme.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Когда выезжать")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Точка — поездка: во сколько выехали и сколько ехали")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Chart {
                if let range = summary.range {
                    RectangleMark(xStart: .value("Выезд", start), xEnd: .value("Выезд", end),
                                  yStart: .value("Минут", range.lowerBound / 60),
                                  yEnd: .value("Минут", range.upperBound / 60))
                        .foregroundStyle(Theme.accent.opacity(0.10))
                }
                if let best = summary.best {
                    RectangleMark(
                        xStart: .value("Окно", Self.today(best.startMinute)),
                        xEnd: .value("Окно", Self.today(best.startMinute + AppConfig.commuteBucketMinutes)))
                        .foregroundStyle(Theme.success.opacity(0.16))
                }
                if let usual = summary.usual {
                    RuleMark(y: .value("Обычно", usual / 60))
                        .foregroundStyle(Theme.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                ForEach(summary.trips) { trip in
                    let isLast = trip.id == summary.last.id
                    PointMark(
                        x: .value("Выезд", Self.today(Commute.minuteOfDay(trip.departure))),
                        y: .value("Минут", trip.duration / 60))
                        .foregroundStyle(isLast ? Theme.accent : Theme.accent.opacity(0.35))
                        .symbolSize(isLast ? 120 : 45)
                }
            }
            // Ось — ровные часы по выборке и окну-совету; шаг подписей по
            // ширине (CommuteChartAxis): каждые полчаса через семь часов
            // подписи слипались в «11:3012:00…».
            .chartXScale(domain: start...end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: axis.stride)) { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    if let minutes = value.as(Double.self) {
                        AxisValueLabel(String(format: String(localized: "%lld мин"), Int(minutes)))
                    }
                }
            }
            .frame(height: 200)
            .accessibilityLabel(Text("График: время выезда и время в пути"))
            legend
            if !summary.other.isEmpty {
                Text(Self.otherLine(summary.other))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .statCard()
    }

    /// Легенда — строкой, пока влезает, иначе столбиком (SE, крупный шрифт).
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 6) { legendItems }
        }
    }

    @ViewBuilder private var legendItems: some View {
        LegendItem(text: CommuteCard.dayLine(summary.last.departure)) {
            Circle().fill(Theme.accent).frame(width: 10, height: 10)
        }
        if let usual = summary.usual {
            LegendItem(text: String(format: String(localized: "обычно %@"),
                                    Formatting.unbreakable(Formatting.duration(usual)))) {
                Rectangle().stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 14, height: 0.5)
            }
        }
        if summary.range != nil {
            LegendItem(text: String(localized: "половина поездок")) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.18)).frame(width: 14, height: 10)
            }
        }
        if summary.best != nil {
            LegendItem(text: String(localized: "лучшее время")) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.success.opacity(0.3)).frame(width: 14, height: 10)
            }
        }
    }

    private struct LegendItem<Swatch: View>: View {
        let text: String
        @ViewBuilder let swatch: () -> Swatch

        var body: some View {
            HStack(spacing: 5) {
                swatch()
                Text(text)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// «В другое время: 3 (11:44, 13:10, 13:13) — в «обычно» не входят»
    /// (до трёх времён).
    static func otherLine(_ trips: [Commute.Trip]) -> String {
        let times = trips.sorted { Commute.minuteOfDay($0.departure) < Commute.minuteOfDay($1.departure) }
            .prefix(3).map { Formatting.clock($0.departure) }
            .joined(separator: ", ") + (trips.count > 3 ? "…" : "")
        return String(format: String(localized: "В другое время: %1$lld (%2$@) — в «обычно» не входят"),
                      trips.count, times)
    }

    /// Ось — по всей выборке (она и так в своём окне времени) и окну-совету.
    static func axis(_ summary: Commute.Summary) -> CommuteChartAxis.Layout {
        let window = summary.best.map { $0.startMinute...($0.startMinute + AppConfig.commuteBucketMinutes) }
        return CommuteChartAxis.layout(departures: summary.trips.map { Commute.minuteOfDay($0.departure) },
                                       window: window, coreSpan: .max)
    }

    /// Минуты от полуночи — как сегодняшняя дата: ось графика — часы дня.
    static func today(_ minute: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minute) * 60)
    }
}
