//
//  TripArchive.swift
//  RadarMap
//
//  «Все поездки» — группировка по месяцам, фильтр «с превышениями» и куда
//  поездка приехала («→ Работа»), чистыми функциями (6.10): раньше группы
//  собирались в body на каждую пересборку списка.
//

import CoreLocation
import Foundation

nonisolated enum TripArchive {
    struct Month: Equatable, Sendable {
        let start: Date
        let records: [TripRecord]

        static func == (a: Month, b: Month) -> Bool {
            a.start == b.start && a.records.map(\.id) == b.records.map(\.id)
        }
    }

    /// Месяцы в порядке истории (от новых к старым); пустые после фильтра —
    /// не показываются.
    static func months(_ history: [TripRecord], onlyFined: Bool,
                       calendar: Calendar = .current) -> [Month] {
        var order: [Date] = []
        var byMonth: [Date: [TripRecord]] = [:]
        for record in history where !onlyFined || hasFinedPass(record) {
            let key = calendar.dateInterval(of: .month, for: record.startedAt)?.start
                ?? calendar.startOfDay(for: record.startedAt)
            if byMonth[key] == nil { order.append(key) }
            byMonth[key, default: []].append(record)
        }
        return order.map { Month(start: $0, records: byMonth[$0] ?? []) }
    }

    /// Хоть один проезд со ступенью штрафа — та же граница, что у денег.
    static func hasFinedPass(_ record: TripRecord) -> Bool {
        record.passed.contains { pass in
            guard let limit = pass.limitKmh else { return false }
            return FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0
        }
    }

    enum Finish: Equatable, Sendable { case home, work }

    /// Куда приехала поездка: финиш в радиусе места (как у «дороги на
    /// работу»), а если близко к обоим — к ближайшему. Нет места — nil.
    static func finish(_ end: CLLocationCoordinate2D?, home: CLLocationCoordinate2D?,
                       work: CLLocationCoordinate2D?,
                       radius: CLLocationDistance = AppConfig.commutePlaceRadiusMeters) -> Finish? {
        guard let end else { return nil }
        func distance(_ place: CLLocationCoordinate2D?) -> CLLocationDistance? {
            guard let place else { return nil }
            let d = GeoMath.fastDistance(end.latitude, end.longitude, place.latitude, place.longitude)
            return d <= radius ? d : nil
        }
        switch (distance(home), distance(work)) {
        case let (h?, w?): return h <= w ? .home : .work
        case (_?, nil):    return .home
        case (nil, _?):    return .work
        default:           return nil
        }
    }
}
