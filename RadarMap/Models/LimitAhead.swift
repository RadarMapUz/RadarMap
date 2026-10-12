//
//  LimitAhead.swift
//  RadarMap
//
//  «Ограничение 40 через 200 метров» — смена лимита впереди.
//
//  Голос «Превышение скорости» звучит, когда лимит уже сменился и машина
//  уже едет быстрее, — то есть ровно тогда, когда камера на въезде в
//  сороковую зону уже щёлкнула. Здесь предупреждение заранее: на дороге
//  впереди лимит НИЖЕ текущего, и с нашей скоростью мы его превысим.
//
//  Правила — чтобы не ворчать и не врать:
//    * только снижение лимита: о повышении говорить незачем;
//    * только если мы едем быстрее нового лимита с допуском — едущему 35 в
//      сороковую зону сказать нечего;
//    * лимит подтверждают две пробы подряд (≥ 50 м новой дороги): одна точка
//      на перекрёстке со съездом — шум данных;
//    * одна фраза на одну смену (место и значение), не чаще раза в минуту.
//  Пробы берёт SpeedLimitService: по линии маршрута или — без маршрута —
//  прямо по оси текущей дороги, и тогда только пока ось рядом (на изгибе
//  молчим: проба ушла бы на соседнюю улицу).
//
//  Чистая логика, время — параметром; покрыто LimitAheadTests.
//

import CoreLocation
import Foundation

nonisolated enum LimitAhead {

    struct Probe: Equatable, Sendable {
        /// Метров впереди по пути.
        let along: CLLocationDistance
        /// Лимит дороги в этой точке; nil — дорога не найдена.
        let limit: Int?
        let coordinate: CLLocationCoordinate2D

        static func == (a: Probe, b: Probe) -> Bool {
            a.along == b.along && a.limit == b.limit
                && a.coordinate.latitude == b.coordinate.latitude
                && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    struct Notice: Equatable, Sendable {
        let limit: Int
        /// Метров до смены.
        let distance: CLLocationDistance
        let at: CLLocationCoordinate2D

        static func == (a: Notice, b: Notice) -> Bool {
            a.limit == b.limit && a.distance == b.distance
                && a.at.latitude == b.at.latitude && a.at.longitude == b.at.longitude
        }
    }

    /// Смена лимита впереди, о которой стоит сказать, или nil.
    static func notice(current: Int?, speedKmh: Double, tolerance: Double,
                       probes: [Probe]) -> Notice? {
        guard let current, speedKmh.isFinite else { return nil }
        for (index, probe) in probes.enumerated() {
            guard let limit = probe.limit else { continue }
            if limit >= current {
                // Дорога впереди с тем же или большим лимитом — смена, если
                // будет, дальше; ищем следующую.
                continue
            }
            guard index + 1 < probes.count, probes[index + 1].limit == limit,
                  probe.along >= AppConfig.limitAheadMinMeters,
                  probe.along <= AppConfig.limitAheadMaxMeters,
                  speedKmh > Double(limit) + tolerance else { return nil }
            return Notice(limit: limit, distance: probe.along, at: probe.coordinate)
        }
        return nil
    }

    /// Одна фраза на одну смену лимита.
    struct Announcer: Equatable, Sendable {
        private var last: Notice?
        private var lastAt: Date?

        mutating func shouldAnnounce(_ notice: Notice, at now: Date) -> Bool {
            if let lastAt, now.timeIntervalSince(lastAt) < AppConfig.limitAheadGapSeconds { return false }
            if let last, last.limit == notice.limit,
               GeoMath.fastDistance(last.at.latitude, last.at.longitude,
                                    notice.at.latitude, notice.at.longitude) < AppConfig.limitAheadSameMeters {
                return false
            }
            last = notice
            lastAt = now
            return true
        }
    }
}

/// Фраза — на главном потоке: Formatting знает язык приложения.
extension LimitAhead.Notice {
    /// «Ограничение 40 через 200 м».
    var spoken: String {
        String(format: String(localized: "Ограничение %1$lld через %2$@"),
               limit, Formatting.distance((distance / 50).rounded() * 50))
    }
}
