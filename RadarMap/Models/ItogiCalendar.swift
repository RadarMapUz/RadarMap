//
//  ItogiCalendar.swift
//  RadarMap
//
//  Календарь колец «Итогов»: на каждый день внешнее кольцо — аккуратность,
//  внутреннее — пробег относительно обычного дня водителя. Здесь же мелкие
//  правила графика: среднее за день и короткое имя места.
//
//  Чистая логика, время — параметром; покрыто ItogiCalendarTests.
//

import Foundation

nonisolated enum ItogiCalendar {

    struct Ring: Equatable {
        /// nil — поездки были, но оценки у дня нет.
        let score: Int?
        /// Доля обычного дня, 0…1.
        let road: Double
        let fine: Bool
        let perfect: Bool
    }

    struct Cell: Identifiable, Equatable {
        let day: Date
        let ring: Ring?
        let isFuture: Bool
        var id: Date { day }
    }

    struct Month: Identifiable, Equatable {
        let start: Date
        /// Пустых клеток перед первым числом.
        let leading: Int
        let cells: [Cell]
        var id: Date { start }
    }

    /// Обычный день — медиана дней с поездками: один рейс в Самарканд не
    /// должен делать все остальные дни пустыми.
    static func usualKm(_ days: [TripDay]) -> Double {
        let values = days.filter { $0.trips > 0 }.map { $0.distanceMeters / 1000 }.sorted()
        guard !values.isEmpty else { return 1 }
        let mid = values.count / 2
        let median = values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
        return max(median, 1)
    }

    static func ring(_ day: TripDay, usualKm: Double) -> Ring {
        let clean = day.overPasses == 0 && (day.edgePasses ?? 0) == 0
        return Ring(score: day.rating,
                    road: min(1, day.distanceMeters / 1000 / usualKm),
                    fine: day.overPasses > 0,
                    perfect: clean && (day.rating ?? 0) >= AppConfig.itogiPerfectDayScore)
    }

    /// Месяцы от первой поездки до текущего, неделя с понедельника.
    static func months(days: [TripDay], now: Date, calendar source: Calendar = .current) -> [Month] {
        var calendar = source
        calendar.firstWeekday = 2
        let usual = usualKm(days)
        var byDay: [Date: TripDay] = [:]
        for day in days where day.trips > 0 { byDay[calendar.startOfDay(for: day.day)] = day }
        let today = calendar.startOfDay(for: now)
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let first = byDay.keys.min().flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? thisMonth

        var result: [Month] = []
        var cursor = min(first, thisMonth)
        while cursor <= thisMonth {
            guard let range = calendar.range(of: .day, in: .month, for: cursor) else { break }
            let weekday = calendar.component(.weekday, from: cursor)
            let leading = (weekday - calendar.firstWeekday + 7) % 7
            let cells = range.compactMap { number -> Cell? in
                guard let day = calendar.date(byAdding: .day, value: number - 1, to: cursor) else { return nil }
                return Cell(day: day, ring: byDay[day].map { ring($0, usualKm: usual) }, isFuture: day > today)
            }
            result.append(Month(start: cursor, leading: leading, cells: cells))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Среднее за прошедшие дни окна: у идущей недели завтрашние нули не считаются.
    static func averageKm(bars: [DayBar], now: Date) -> Double? {
        let elapsed = bars.filter { $0.day <= now }
        let total = elapsed.reduce(0) { $0 + $1.km }
        guard !elapsed.isEmpty, total > 0 else { return nil }
        return total / Double(elapsed.count)
    }

    /// Имя камеры из реестра длинное: «Улица Остановка, Другая улица Въезд».
    /// Водителю хватает части до запятой.
    static func shortPlace(_ location: String) -> String {
        let head = location.split(separator: ",", maxSplits: 1).first.map(String.init) ?? location
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? location : trimmed
    }
}
