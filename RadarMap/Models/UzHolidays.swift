//
//  UzHolidays.swift
//  RadarMap
//
//  Праздничные нерабочие дни Узбекистана — выходной класс для «дороги на
//  работу» (план 19.10, 8.8.13). Поездка в Навруз или в Курбан хайит — это не
//  будни: без списка она ложилась в будничную медиану призрака и портила
//  «обычно» на неделю вперёд, срок «быть к 9:00» действовал в праздник, а
//  «Выезжайте раньше» звонило в первый день хайита.
//
//  Что здесь:
//    * постоянные праздники (Трудовой кодекс, ст. 132): 1 января, 8 марта,
//      21 марта (Навруз), 9 мая, 1 сентября, 1 октября, 8 декабря;
//    * Рамазан и Курбан хайит — по году: даты двигаются (≈ на 11 дней в год) и
//      объявляются постановлением Президента незадолго до праздника. 2026 —
//      объявленные (ПП-106 от 17.03.2026: Рамазан 20 марта; Курбан 27 мая и
//      дополнительные нерабочие 28–29 мая). 2027–2028 — астрономическая
//      оценка; сверить с постановлением года и поправить здесь;
//    * перенос: праздник в субботу или воскресенье даёт выходной в ближайший
//      рабочий день (для пятидневки) — так 2026 год получил 23 марта.
//
//  Ошибка в списке стоит немного: лишний день — будничная поездка уходит в
//  выходной класс, пропущенный — праздничная портит медиану. Год вне списка
//  — только постоянные праздники и перенос.
//
//  Чистая логика — UzHolidaysTests.
//

import Foundation

nonisolated enum UzHolidays {

    /// Постоянные праздники: (месяц, день).
    static let fixed: [(month: Int, day: Int)] = [(1, 1), (3, 8), (3, 21), (5, 9), (9, 1), (10, 1), (12, 8)]

    /// Хайиты и дополнительные нерабочие дни по годам: (месяц, день).
    static let moving: [Int: [(month: Int, day: Int)]] = [
        // Объявлено: ПП-106 от 17.03.2026 (Рамазан); Курбан и 28–29 мая —
        // постановление о Курбан хайите 2026.
        2026: [(3, 20), (5, 27), (5, 28), (5, 29)],
        // Оценка: Рамазан ≈ 9 марта, Курбан ≈ 16 мая (воскресенье → 17 мая).
        2027: [(3, 9), (5, 16)],
        // Оценка: Рамазан ≈ 26 февраля (суббота → 28-е), Курбан ≈ 5 мая.
        2028: [(2, 26), (5, 5)],
    ]

    /// Праздник (с переносом) — нерабочий день, кроме обычных выходных.
    static func isHoliday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }
        return days(of: year, calendar: calendar).contains(month * 100 + day)
    }

    /// Выходной класс: суббота, воскресенье или праздник.
    static func isDayOff(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDateInWeekend(date) || isHoliday(date, calendar: calendar)
    }

    /// Рабочий будний день: не выходной и не праздник.
    static func isWorkday(_ date: Date, calendar: Calendar = .current) -> Bool {
        !isDayOff(date, calendar: calendar)
    }

    /// Нерабочие праздничные дни года как `месяц × 100 + день`, с переносом.
    static func days(of year: Int, calendar: Calendar = .current) -> Set<Int> {
        let listed = fixed + (moving[year] ?? [])
        var result = Set(listed.map { $0.month * 100 + $0.day })
        // Перенос по порядку года: праздник в выходной даёт ближайший рабочий
        // день, который ещё не праздник и не занят прежним переносом.
        for holiday in listed.sorted(by: { ($0.month, $0.day) < ($1.month, $1.day) }) {
            guard let date = calendar.date(from: DateComponents(year: year, month: holiday.month,
                                                                day: holiday.day, hour: 12)),
                  calendar.isDateInWeekend(date) else { continue }
            var next = date
            for _ in 0..<10 {
                guard let candidate = calendar.date(byAdding: .day, value: 1, to: next) else { break }
                next = candidate
                let key = calendar.component(.month, from: next) * 100 + calendar.component(.day, from: next)
                if !calendar.isDateInWeekend(next), !result.contains(key),
                   calendar.component(.year, from: next) == year {
                    result.insert(key)
                    break
                }
            }
        }
        return result
    }
}
