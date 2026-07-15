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
