//
//  TrafficCityScore.swift
//  RadarMap
//
//  Балл пробок города (33H, как «9» у Яндекса): одно число 0–10 на весь
//  Ташкент. 0 — магистрали свободны, 10 — две трети магистралей стоят.
//
//  Формула. Берутся линии магистралей (класс 0, TrafficLines.tier) в рамке
//  Ташкента. Загруженность c = Σ длина × вес уровня / знаменатель, вес:
//  свободно 0, медленно 0,5, пробка и «стоят» 1. Балл = round(10 × min(1,
//  c / `trafficScoreFullShare`)).
//  • Живые: знаменатель — длина магистралей, по которым водители сейчас
//    дали данные (свободные тоже), не меньше `trafficScoreMinLiveKm` — иначе
//    три медленных проезда сделали бы «10 баллов» на весь город.
//  • Иначе — «обычно» (профиль 33G) с пометкой: профиль несёт только
//    медленные рёбра, поэтому знаменатель — вся сеть магистралей Ташкента
//    (`trafficScoreTashkentMajorKm`, замер OSM), иначе «обычно» всегда было
//    бы десяткой.
//  • Ни того, ни другого — балла нет (nil): чип не показывается.
//
//  Чистая логика, TrafficCityScoreTests.
//

import CoreLocation
import Foundation

nonisolated enum TrafficCityScore {

    struct Score: Equatable, Sendable {
        /// 0…10.
        let value: Int
        /// По «обычно в это время», а не по данным водителей сейчас.
        let usual: Bool

        /// Уровень цвета балла: 1 свободно (0–3), 2 медленно (4–6), 3 пробка (7–10).
        var level: Int { value <= 3 ? 1 : (value <= 6 ? 2 : 3) }
    }

    /// Ташкент (город с кольцевой) — рамка, по которой считается балл.
    static let tashkent = (minLat: 41.21, maxLat: 41.40, minLon: 69.13, maxLon: 69.40)

    static func weight(level: Int) -> Double {
        switch level {
        case 1: return 0
        case 2: return 0.5
        default: return 1
        }
    }

    static func score(_ lines: [TrafficLines.Line]) -> Score? {
        var liveTotal = 0.0, liveLoad = 0.0, usualLoad = 0.0
        for line in lines where line.tier == 0 && isInTashkent(line) {
            let load = line.length * weight(level: line.level)
            switch line.source {
            case .live:
                liveTotal += line.length
                liveLoad += load
            case .usual:
                usualLoad += load
            }
        }
        if liveTotal >= AppConfig.trafficScoreMinLiveKm * 1000 {
            return Score(value: value(load: liveLoad, total: liveTotal), usual: false)
        }
        guard usualLoad > 0 else { return nil }
        return Score(value: value(load: usualLoad, total: AppConfig.trafficScoreTashkentMajorKm * 1000), usual: true)
    }

    static func value(load: Double, total: Double) -> Int {
        guard total > 0 else { return 0 }
        let share = load / total
        return Int((10 * min(1, share / AppConfig.trafficScoreFullShare)).rounded())
    }

    /// Линия в рамке — по средней точке (линии улиц короткие, рамка большая).
    private static func isInTashkent(_ line: TrafficLines.Line) -> Bool {
        guard !line.coordinates.isEmpty else { return false }
        let middle = line.coordinates[line.coordinates.count / 2]
        return (tashkent.minLat...tashkent.maxLat).contains(middle.latitude)
            && (tashkent.minLon...tashkent.maxLon).contains(middle.longitude)
    }
}
