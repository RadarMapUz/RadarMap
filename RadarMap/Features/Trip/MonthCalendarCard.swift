//
//  MonthCalendarCard.swift
//  RadarMap
//
//  Календарь месяца в Итогах: день = клетка, месяц читается одним взглядом.
//
//  Столбики километров отвечают «сколько», но не отвечают «когда всё было
//  хорошо»: зелёная решётка с двумя красными клетками рассказывает месяц
//  быстрее любого графика. Цвет — про поведение, не про километры: зелёный —
//  в лимите, жёлтый — на грани (штрафа нет, балл снят), красный — было
//  штрафуемое превышение, пустая — не ездил. Три состояния — PassVerdict.
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

    /// «Пн Вт Ср…» в порядке календаря пользователя и на языке приложения
    /// (NumberFormat.locale), как у цели недели, — не на языке телефона.
    private var weekdayHeader: some View {
        var localized = calendar
        localized.locale = NumberFormat.locale
        let symbols = localized.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        // Без spacing — как у клеток: колонки обязаны совпасть по центрам.
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.rounded(12, .semibold))
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
                        if state.verdict == .over {
                            Circle()
                                .fill(PassVerdict.over.tint)
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
            .buttonStyle(PressableStyle(.choice))
            .accessibilityLabel(Text(Formatting.date(day, Date.FormatStyle(date: .abbreviated, time: .omitted))))
            .accessibilityValue(state.hasTrips
                ? Text(state.verdict?.word ?? String(localized: "без камер"))
                : Text("без поездок"))
        } else {
            // День соседнего месяца — пустое место, не клетка.
            Color.clear.frame(maxWidth: .infinity).frame(height: 34)
                .padding(Self.cellGap / 2)
        }
    }

    /// Состояние клетки. Красное — только штрафуемое превышение: клетка не
    /// имеет права быть строже, чем деньги; жёлтое — балл снят без штрафа.
    private struct CellState {
        let hasTrips: Bool
        let verdict: PassVerdict?

        init(_ day: TripDay?) {
            hasTrips = (day?.trips ?? 0) > 0
            verdict = day.flatMap {
                PassVerdict.day(clean: $0.cleanPasses - ($0.edgePasses ?? 0), edge: $0.edgePasses ?? 0,
                                over: $0.overPasses)
            }
        }

        var fill: Color {
            // Клетка с поездками — нейтральная плашка, состояние несёт цвет
            // числа (31D: без цветного текста на цветном фоне).
            hasTrips ? Theme.quietFill : Theme.surface.opacity(0.6)
        }

        var text: Color {
            guard hasTrips else { return Theme.textTertiary }
            // Поездки без камер с лимитом — нейтрально: «в лимите» не о чем.
            return verdict?.tint ?? Theme.textPrimary
        }
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ItogiVerdictLegend()
                Text("тап — день подробно")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                ItogiVerdictLegend()
                Text("тап — день подробно")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
