//
//  MonthCalendarCard.swift
//  RadarMap
//
//  Календарь месяца в Итогах: день = клетка, месяц читается одним взглядом.
//
//  Столбики километров отвечают «сколько», но не отвечают «когда всё было
//  хорошо»: зелёная решётка с двумя красными клетками рассказывает месяц
//  быстрее любого графика. Цвет — про поведение, не про километры: зелёный —
//  ездил чисто, красный — было штрафуемое превышение, пустая — не ездил.
//
//  Данные — дневные агрегаты (TripDay): они хранятся вечно, поэтому календарь
//  честен и для месяцев, чьи полные записи давно вычищены. Раскладка —
//  чистая MonthGrid (покрыта тестами), тап по дню открывает его в периоде
//  «День»: клетка — это дверь, а не просто пиксель статистики.
//

import SwiftUI

struct MonthCalendarCard: View {
    /// Все дневные агрегаты — фильтруем по месяцу сами.
    let days: [TripDay]
    /// Любая дата внутри показываемого месяца.
    let anchor: Date
    var onSelectDay: (Date) -> Void

    private let calendar = Calendar.current
    /// Видимый зазор между клетками; кладётся полями внутрь клетки.
    private static let cellGap: CGFloat = 5

    var body: some View {
        let byDay = dayIndex
        let weeks = MonthGrid.weeks(containing: anchor, calendar: calendar)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Календарь месяца"))
            weekdayHeader
            // Зазоры между клетками — не spacing, а поля внутри каждой клетки
            // (cellGap): на глаз сетка та же, а мишень дня занимает весь шаг
            // сетки — ~43×39 pt на SE вместо 38×34. До 44 по высоте не
            // дотянуть, не залезая в соседнюю неделю: шаг строки 39 pt.
            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            cell(day, byDay: byDay)
                        }
                    }
                }
            }
            legend
        }
        .statCard()
    }

    /// Словарь «начало дня → агрегат» — один проход по месяцу вместо поиска
    /// по массиву на каждую клетку.
    private var dayIndex: [Date: TripDay] {
        guard let month = calendar.dateInterval(of: .month, for: anchor) else { return [:] }
        var result: [Date: TripDay] = [:]
        for day in days where day.day >= month.start && day.day < month.end {
            result[day.day] = day
        }
        return result
    }

    /// «Пн Вт Ср…» в порядке календаря пользователя.
    private var weekdayHeader: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        // Без spacing — как у клеток: колонки обязаны совпасть по центрам.
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.rounded(10, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date?, byDay: [Date: TripDay]) -> some View {
        if let day {
            let record = byDay[day]
            let state = CellState(record)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelectDay(day)
            } label: {
                Text("\(calendar.component(.day, from: day))")
                    .font(.rounded(12, state.hasTrips ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(state.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(state.fill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        // День с превышением помечен ещё и точкой: цвет один
                        // при дальтонизме и на солнце в держателе неотличим,
                        // а разница между «чисто» и «штраф» — весь смысл сетки.
                        if state.hasOverspeed {
                            Circle()
                                .fill(Theme.danger)
                                .frame(width: 4, height: 4)
                                .padding(.bottom, 3)
                        }
                    }
                    .overlay {
                        // Сегодня — кольцо акцента: точка отсчёта видна всегда,
                        // даже если сегодня ещё не ездили.
                        if calendar.isDateInToday(day) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.accent, lineWidth: 1.5)
                        }
                    }
                    .padding(Self.cellGap / 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Formatting.date(day, Date.FormatStyle(date: .abbreviated, time: .omitted))))
            .accessibilityValue(state.hasTrips
                ? (state.hasOverspeed ? Text("превышения") : Text("чисто"))
                : Text("без поездок"))
        } else {
            // День соседнего месяца — пустое место, не клетка.
            Color.clear.frame(maxWidth: .infinity).frame(height: 34)
                .padding(Self.cellGap / 2)
        }
    }

    /// Три состояния клетки. Красное — только штрафуемое превышение: клетка
    /// не имеет права быть строже, чем деньги и рейтинг.
    private struct CellState {
        let hasTrips: Bool
        let hasOverspeed: Bool

        init(_ day: TripDay?) {
            hasTrips = (day?.trips ?? 0) > 0
            hasOverspeed = (day?.overPasses ?? 0) > 0
        }

        var fill: Color {
            guard hasTrips else { return Theme.surface.opacity(0.6) }
            return hasOverspeed ? Theme.danger.opacity(0.22) : Theme.success.opacity(0.16)
        }

        var text: Color {
            guard hasTrips else { return Theme.textTertiary }
            return hasOverspeed ? Theme.danger : Theme.success
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Theme.success, String(localized: "чисто"))
            legendItem(Theme.danger, String(localized: "с превышением"))
            Spacer(minLength: 0)
            Text("тап — день подробно")
                .font(.rounded(10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(0.25))
                .frame(width: 12, height: 12)
            Text(title).font(.rounded(10)).foregroundStyle(Theme.textTertiary)
        }
    }
}
