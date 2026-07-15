//
//  Formatting.swift
//  RadarMap
//

import Foundation
import CoreLocation

enum Formatting {
    /// «850 м» / «1.4 км»
    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) м"
        }
        return String(format: "%.1f км", meters / 1000)
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

    /// «5 мин» / «1 ч 23 мин»
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(total) сек"
    }
}
