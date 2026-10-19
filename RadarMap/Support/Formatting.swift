//
//  Formatting.swift
//  RadarMap
//

import Foundation
import CoreLocation

enum Formatting {
    /// Локаль чисел — по ЯЗЫКУ приложения, а не по региону телефона: одно
    /// правило с виджетами и часами (`Shared/NumberFormat`).
    nonisolated static var numberLocale: Locale { NumberFormat.locale }

    /// «1,3» — дробное с одним знаком (или `digits`) в локали приложения.
    nonisolated static func decimal(_ value: Double, digits: Int = 1,
                                    locale: Locale = NumberFormat.locale) -> String {
        NumberFormat.decimal(value, digits: digits, locale: locale)
    }

    /// Заголовок дня в истории: «Сегодня» / «Вчера» / дата.
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Сегодня") }
        if calendar.isDateInYesterday(day) { return String(localized: "Вчера") }
        return day.formatted(.dateTime.day().month(.wide))
    }

    /// Заголовок поездки: «Сегодня, 11:39», «Вчера, 16:23», «11 октября, 11:39»;
    /// год — только если не текущий. Было «11 окт. 2026г., 11:39»: сокращение,
    /// слипшийся год и дата там, где человек думает «сегодня».
    static func tripTitle(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? dayTitle(date, calendar: calendar)
            : date.formatted(.dateTime.day().month(.wide).year())
        return "\(day), \(time)"
    }

    /// Число не отрывается от единицы: «2,2 / млн сум» переносом на две строки
    /// читалось как два разных значения.
    nonisolated static func unbreakable(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// «850 м» / «1.4 км» (uz: m/km — единицы тоже локализуются)
    /// До сотни километров — с десятой (12,4 км читается точнее, чем 12),
    /// дальше без неё и с разделителем разрядов: «129,5 км» лезло из плитки, а
    /// «12400,0 км» выглядело сырым числом из отладки. Одно правило на всё
    /// приложение и виджет — раньше их было три, и цифры расходились.
    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return unbreakable(String(format: String(localized: "%@ м"), String(Int(meters.rounded()))))
        }
        let km = meters / 1000
        guard km < 100 else {
            return unbreakable(String(format: String(localized: "%@ км"),
                                      km.formatted(.number.precision(.fractionLength(0))
                                        .locale(numberLocale))))
        }
        return unbreakable(String(format: String(localized: "%@ км"), decimal(km)))
    }

    /// «440 000 сум» / «1,2 млн сум» — суммы штрафов и экономии.
    /// Баллы рейтинга: «−12,6», «0». Один формат на все блоки разбора —
    /// разложение должно читаться как одна таблица, а не как три разных.
    static func points(_ value: Double) -> String {
        value < 0.05 ? "0" : "−" + decimal(value)
    }

    static func money(_ sum: Double) -> String {
        if sum >= 1_000_000 {
            let millions = (sum / 100_000).rounded() / 10
            let text = millions == millions.rounded()
                ? String(Int(millions)) : decimal(millions)
            return unbreakable(String(format: String(localized: "%@ млн сум"), text))
        }
        let grouped = Self.groupedInt.string(from: NSNumber(value: Int(sum.rounded()))) ?? "\(Int(sum))"
        return unbreakable(String(format: String(localized: "%@ сум"), grouped))
    }

    private static let groupedInt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"   // узкий неразрывный пробел
        return f
    }()

    /// Время на часах: «8:22». Минуты от полуночи — для окон выезда
    /// (Commute), дата — для выезда и приезда.
    static func clock(minuteOfDay: Int, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: Date())
        return clock(day.addingTimeInterval(Double(minuteOfDay) * 60))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Разница с обычным временем в пути словами: «на 12 мин дольше обычного»,
    /// «на 6 мин быстрее обычного», «как обычно». Порог «заметно» — общий с
    /// карточкой (AppConfig.commuteNoticeableDelaySeconds).
    static func delayPhrase(_ delay: TimeInterval) -> String {
        let minutes = Int((abs(delay) / 60).rounded())
        if abs(delay) < AppConfig.commuteNoticeableDelaySeconds || minutes == 0 {
            return String(localized: "как обычно")
        }
        return unbreakable(delay > 0
            ? String(format: String(localized: "на %lld мин дольше обычного"), minutes)
            : String(format: String(localized: "на %lld мин быстрее обычного"), minutes))
    }

    /// «5 мин» / «1 ч 23 мин» (uz: daq/soat)
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        // «1 ч», а не «1 ч 0 мин»: ноль минут — не факт, а лишнее слово.
        if h > 0, m == 0 { return String(format: String(localized: "%@ ч"), String(h)) }
        if h > 0 { return String(format: String(localized: "%1$@ ч %2$@ мин"), String(h), String(m)) }
        if m > 0 { return String(format: String(localized: "%@ мин"), String(m)) }
        return String(format: String(localized: "%@ сек"), String(total))
    }
}
