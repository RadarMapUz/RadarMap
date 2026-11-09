//
//  ItogiPeriodChart.swift
//  RadarMap
//
//  График «Итогов»: нажатие на столбик показывает день наверху, цвет значит
//  назначение поездки, красная точка — день со штрафом. Штраф красит не весь
//  столбик: один проезд не делает плохими сорок километров.
//

import Charts
import SwiftUI

struct ItogiPeriodChart: View {
    let bars: [DayBar]
    var unit: ItogiBarUnit = .day
    var average: Double? = nil
    /// Шапка: «Всего за неделю», «258 км», сравнение.
    var title: String? = nil
    var value: String? = nil
    var delta: String? = nil
    /// Строка под графиком: «19 поездок · 15 ч за рулём».
    var footer: String? = nil
    var height: CGFloat = 150
    /// Выбранный день можно открыть; nil — у часов дня открывать нечего.
    var onOpenDay: ((Date) -> Void)? = nil

    @State private var raw: Date?
    @State private var selected: DayBar?
    @State private var grown = false

    private var peak: Double { max(bars.map(\.km).max() ?? 0, 1) }
    private var hasCommute: Bool { bars.contains { $0.commuteKm > 0 } }
    private var isCompact: Bool { title == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isCompact { header }
            chart
            if !isCompact, hasCommute { legend }
            if !isCompact { footerRow }
        }
        .sensoryFeedback(.selection, trigger: selected?.id)
        .task(id: bars) {
            selected = nil
            grown = false
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
            withMotion(.spring(response: 0.55, dampingFraction: 0.82)) { grown = true }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selected.map(caption) ?? title ?? "")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(selected.map { Formatting.distance($0.km * 1000) } ?? value ?? "")
                    .font(.numeral(30, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            if let selected {
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        withMotion(Motion.standard) { self.selected = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.rounded(20))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: Theme.controlSize, height: 28, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Text("Сбросить выбор"))
                    Text(detail(selected))
                        .font(.rounded(13, .medium))
                        .foregroundStyle(selected.hasOverspeed ? Theme.danger : Theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            } else if let delta {
                Text(delta)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .frame(minHeight: 62, alignment: .bottom)
    }

    private func caption(_ bar: DayBar) -> String {
        guard unit == .hour else { return Formatting.dayTitle(bar.day) }
        let hour = Calendar.current.component(.hour, from: bar.day)
        return String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
    }

    private func detail(_ bar: DayBar) -> String {
        var text = "\(bar.trips)\u{00A0}" + Formatting.tripsLabel(bar.trips)
        if bar.overPasses > 0 { text += " · " + ItogiWords.fines(bar.overPasses) }
        return text
    }

    // MARK: - График

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                marks(for: bar)
            }
            if let average, selected == nil, grown {
                RuleMark(y: .value("среднее", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(Theme.textTertiary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(String(format: String(localized: "ср. %@"), Formatting.distance(average * 1000)))
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                            .background(Theme.surface, in: Capsule())
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...peak * 1.28)
        .chartXAxis { xAxis }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.stroke)
                AxisValueLabel().font(.rounded(11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXSelection(value: $raw)
        .onChange(of: raw) { _, date in
            // Палец подняли — система обнуляет значение, а выбор остаётся.
            guard let date, let bar = bar(at: date) else { return }
            withMotion(Motion.quick) { selected = bar }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Километры по дням"))
    }

    @ChartContentBuilder private func marks(for bar: DayBar) -> some ChartContent {
        let grow = grown ? 1.0 : 0.02
        let dim = selected == nil || selected?.id == bar.id ? 1.0 : 0.28
        let commute = bar.commuteKm * grow
        let total = bar.km * grow
        let gap = unit != .day && commute > 0 && total > commute ? peak * 0.018 : 0
        let x = PlottableValue.value("время", bar.day, unit: unit == .hour ? .hour : .day)
        if commute > 0 {
            BarMark(x: x, yStart: .value("от", 0), yEnd: .value("км", commute), width: .ratio(0.62))
                .foregroundStyle(LinearGradient(colors: [Theme.Stats.commuteTop, Theme.Stats.commute],
                                                startPoint: .top, endPoint: .bottom))
                .cornerRadius(5)
                .opacity(dim)
        }
        if total > commute + gap {
            let tint = hasCommute ? [Theme.Stats.otherTop, Theme.Stats.other]
                                  : [Theme.Stats.commuteTop, Theme.Stats.commute]
            BarMark(x: x, yStart: .value("от", commute + gap), yEnd: .value("км", total), width: .ratio(0.62))
                .foregroundStyle(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom))
                .cornerRadius(5)
                .opacity(dim)
        }
        if bar.hasOverspeed, grown {
            PointMark(x: x, y: .value("штраф", bar.km + peak * 0.1))
                .symbol(.circle)
                .symbolSize(44)
                .foregroundStyle(Theme.danger)
                .opacity(dim)
        }
    }

    private func bar(at date: Date) -> DayBar? {
        let component: Calendar.Component = unit == .hour ? .hour : .day
        return bars.first { Calendar.current.isDate($0.day, equalTo: date, toGranularity: component) }
    }

    /// Окно задаётся явно: день без поездок не рисует столбика, и без этого
    /// ось сжималась бы до дней, в которые ездили.
    private var xDomain: ClosedRange<Date> {
        let first = bars.first?.day ?? Date()
        let last = bars.last?.day ?? first
        let end = Calendar.current.date(byAdding: unit == .hour ? .hour : .day, value: 1, to: last) ?? last
        return first...end
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: xValues) { value in
            AxisValueLabel(centered: unit == .weekday) {
                if let date = value.as(Date.self) {
                    Text(label(date))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var xValues: AxisMarkValues {
        switch unit {
        case .weekday: return .stride(by: .day, count: 1)
        case .day:     return .stride(by: .day, count: 5)
        case .hour:    return .stride(by: .hour, count: 6)
        }
    }

    private func label(_ date: Date) -> String {
        var calendar = Calendar.current
        calendar.locale = NumberFormat.locale
        switch unit {
        case .weekday: return calendar.veryShortStandaloneWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
        case .day:     return "\(calendar.component(.day, from: date))"
        case .hour:    return String(format: "%02d", calendar.component(.hour, from: date))
        }
    }

    // MARK: - Подписи

    private var legend: some View {
        let source = selected.map { [$0] } ?? bars
        let commute = source.reduce(0) { $0 + $1.commuteKm }
        let total = source.reduce(0) { $0 + $1.km }
        return HStack(alignment: .top, spacing: 12) {
            legendItem(String(localized: "Дом и работа"), commute, Theme.Stats.commuteText)
            legendItem(String(localized: "Другие поездки"), max(0, total - commute), Theme.Stats.otherText)
        }
    }

    private func legendItem(_ title: String, _ km: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.rounded(13, .semibold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.8)
            Text(Formatting.distance(km * 1000))
                .font(.numeral(16, .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var footerRow: some View {
        if let selected, let onOpenDay, selected.trips > 0 {
            Divider().overlay(Theme.stroke)
            Button { onOpenDay(selected.day) } label: {
                HStack {
                    Text("Открыть день").font(.rounded(15, .semibold)).foregroundStyle(Theme.accent)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(minHeight: Theme.controlSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(.row))
        } else if let footer {
            Divider().overlay(Theme.stroke)
            Text(footer)
                .font(.rounded(14, .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
