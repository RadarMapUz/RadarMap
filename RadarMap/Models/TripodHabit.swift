//
//  TripodHabit.swift
//  RadarMap
//
//  «Здесь вечером часто стоит тренога» — предупреждение заранее по памяти
//  места (пункт 82). Сильное место (разные люди в разные дни именно в эту
//  четверть суток) и типичное время сейчас — одна спокойная фраза за поездку
//  при подъезде по ходу движения. Это догадка о прошлом: «часто стоит»,
//  никогда «стоит»; при превышении — «сбавьте».
//
//  Слабые места и любое время суток по-прежнему решает HotspotAlert (голос
//  только при превышении).
//
//  Чистая логика, покрыто TripodHabitTests.
//

import CoreLocation
import Foundation

nonisolated enum TripodHabit {

    /// Местная четверть суток (Ташкент, UTC+5, без перевода часов): 0 ночь,
    /// 1 утро, 2 день, 3 вечер — как build_hotspots.quarter.
    static func quarter(at date: Date) -> Int {
        var seconds = (date.timeIntervalSince1970 + 5 * 3600).truncatingRemainder(dividingBy: 86400)
        if seconds < 0 { seconds += 86400 }
        return min(3, Int(seconds / 21600))
    }

    /// Разные люди и разные дни в типичной четверти; файл до 82 — не сильное.
    static func isStrong(_ spot: TripodHotspots.Spot) -> Bool {
        guard spot.peak >= 0, let src = spot.src, let pdays = spot.pdays else { return false }
        return src >= AppConfig.tripodHabitMinSources && pdays >= AppConfig.tripodHabitMinPeakDays
    }

    /// Сейчас типичное время места или оно начнётся в пределах упреждения.
    static func isPeakTime(_ spot: TripodHotspots.Spot, now: Date) -> Bool {
        quarter(at: now) == spot.peak
            || quarter(at: now.addingTimeInterval(AppConfig.tripodHabitLeadSeconds)) == spot.peak
    }

    /// Насколько заранее: секунды пути по скорости, в пределах метров.
    static func warnMeters(speedKmh: Double) -> CLLocationDistance {
        min(AppConfig.tripodHabitWarnMaxMeters,
            max(AppConfig.tripodHabitWarnMinMeters, speedKmh / 3.6 * AppConfig.tripodHabitLeadTravelSeconds))
    }

    struct Situation {
        let coordinate: CLLocationCoordinate2D
        /// < 0 — курс недоверенный: молчим (догадка не звучит наугад).
        let course: CLLocationDegrees
        let speedKmh: Double
        let isTripActive: Bool
        let isOverspeeding: Bool
        /// Настройка «Предупреждать о частых местах заранее».
        let enabled: Bool
        let now: Date
    }

    /// Место, о котором сказать сейчас; nil — молчим.
    static func spotToAnnounce(in spots: [TripodHotspots.Spot], situation: Situation,
                               alreadyVoiced: Set<Int64>) -> TripodHotspots.Spot? {
        guard situation.enabled, situation.isTripActive, situation.course >= 0 else { return nil }
        let within = warnMeters(speedKmh: situation.speedKmh)
        var best: TripodHotspots.Spot?
        var bestAlong = CLLocationDistance.greatestFiniteMagnitude
        for spot in spots where !alreadyVoiced.contains(spot.key)
            && isStrong(spot) && isPeakTime(spot, now: situation.now) {
            let fix = RoadCorridor.fix(from: situation.coordinate, course: situation.course, to: spot.coordinate)
            guard fix.along > 0, fix.along <= within, RoadCorridor.contains(fix, context: .city) else { continue }
            if fix.along < bestAlong {
                best = spot
                bestAlong = fix.along
            }
        }
        return best
    }

    /// «Здесь вечером часто стоит тренога[, сбавьте]».
    static func phrase(for spot: TripodHotspots.Spot, slowDown: Bool) -> String {
        switch (spot.peak, slowDown) {
        case (0, false): return String(localized: "Здесь ночью часто стоит тренога")
        case (0, true):  return String(localized: "Здесь ночью часто стоит тренога, сбавьте")
        case (1, false): return String(localized: "Здесь утром часто стоит тренога")
        case (1, true):  return String(localized: "Здесь утром часто стоит тренога, сбавьте")
        case (2, false): return String(localized: "Здесь днём часто стоит тренога")
        case (2, true):  return String(localized: "Здесь днём часто стоит тренога, сбавьте")
        case (_, false): return String(localized: "Здесь вечером часто стоит тренога")
        case (_, true):  return String(localized: "Здесь вечером часто стоит тренога, сбавьте")
        }
    }

    /// Подпись зоны на карте: «чаще вечером»; nil — перевеса нет.
    static func mapLabel(peak: Int) -> String? {
        switch peak {
        case 0:  return String(localized: "чаще ночью")
        case 1:  return String(localized: "чаще утром")
        case 2:  return String(localized: "чаще днём")
        case 3:  return String(localized: "чаще вечером")
        default: return nil
        }
    }
}
