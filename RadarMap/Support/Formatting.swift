//
//  Formatting.swift
//  RadarMap
//

import Foundation
import CoreLocation

enum Formatting {
    /// Заголовок дня в истории: «Сегодня» / «Вчера» / дата.
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Сегодня") }
        if calendar.isDateInYesterday(day) { return String(localized: "Вчера") }
        return day.formatted(.dateTime.day().month(.wide))
    }

    /// «850 м» / «1.4 км» (uz: m/km — единицы тоже локализуются)
    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return String(format: String(localized: "%@ м"), String(Int(meters.rounded())))
        }
        let km = String(format: "%.1f", locale: .current, meters / 1000)
        return String(format: String(localized: "%@ км"), km)
    }

    /// «440 000 сум» / «1,2 млн сум» — суммы штрафов и экономии.
    static func money(_ sum: Double) -> String {
        if sum >= 1_000_000 {
            let millions = (sum / 100_000).rounded() / 10
            let text = millions == millions.rounded()
                ? String(Int(millions)) : String(format: "%.1f", locale: .current, millions)
            return String(format: String(localized: "%@ млн сум"), text)
        }
        let grouped = Self.groupedInt.string(from: NSNumber(value: Int(sum.rounded()))) ?? "\(Int(sum))"
        return String(format: String(localized: "%@ сум"), grouped)
    }

    private static let groupedInt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"   // узкий неразрывный пробел
        return f
    }()

    /// «5 мин» / «1 ч 23 мин» (uz: daq/soat)
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return String(format: String(localized: "%1$@ ч %2$@ мин"), String(h), String(m)) }
        if m > 0 { return String(format: String(localized: "%@ мин"), String(m)) }
        return String(format: String(localized: "%@ сек"), String(total))
    }
}
