//
//  JamAhead.swift
//  RadarMap
//
//  «Впереди пробка, около километра, плюс 6 минут» — без маршрута.
//
//  Большинство водителей едет без маршрута, только с камерами. Для них
//  пробки были лишь цветом на карте, на которую за рулём не смотрят. Здесь —
//  одна спокойная фраза, когда на дороге ПО ХОДУ движения стоит пробка,
//  подтверждённая другими водителями (TrafficSnapshot: только медленные
//  рёбра, ≥ 2 независимых куска за 15 минут).
//
//  Тон — как у треног (TripodHotspots), а не как у камер: это данные о том,
//  что было пару минут назад, и сказанное уверенно о неточном стоит доверия.
//  Поэтому:
//    * без курса — молчим (не знаем, куда едем);
//    * только рёбра в узком коридоре впереди и в нашем направлении — встречная
//      пробка не наша;
//    * короткая медленная вставка (< 300 м или < 1 мин) — не пробка;
//    * одна фраза на пробку; повтор — только о другой пробке и не чаще раза
//      в `jamAnnounceGapSeconds`.
//
//  Чистая логика; покрыто JamAheadTests.
//

import CoreLocation
import Foundation

nonisolated enum JamAhead {

    struct Jam: Equatable, Sendable {
        /// Метров до начала пробки по ходу.
        let startsIn: CLLocationDistance
        /// Сколько метров медленных рёбер впереди.
        let length: CLLocationDistance
        /// Сколько секунд добавляют.
        let delay: TimeInterval
        /// Где начинается — чтобы не сказать о той же пробке дважды.
        let start: CLLocationCoordinate2D

        static func == (a: Jam, b: Jam) -> Bool {
            a.startsIn == b.startsIn && a.length == b.length && a.delay == b.delay
                && a.start.latitude == b.start.latitude && a.start.longitude == b.start.longitude
        }
    }

    /// Пробка впереди или nil.
    static func detect(edges: [TrafficEdge], position: CLLocationCoordinate2D,
                       course: CLLocationDirection) -> Jam? {
        guard course >= 0, course.isFinite else { return nil }
        var length: CLLocationDistance = 0
        var delay: TimeInterval = 0
        var nearest: (along: Double, point: CLLocationCoordinate2D)?
        for edge in edges where edge.level >= 2 {
            let mid = CLLocationCoordinate2D(latitude: (edge.a.latitude + edge.b.latitude) / 2,
                                             longitude: (edge.a.longitude + edge.b.longitude) / 2)
            let distance = GeoMath.fastDistance(position.latitude, position.longitude, mid.latitude, mid.longitude)
            guard distance <= AppConfig.jamLookAheadMeters + 100 else { continue }
            let bearing = GeoMath.bearing(from: position, to: mid)
            let off = (bearing - course) * .pi / 180
            let along = distance * cos(off)
            let lateral = abs(distance * sin(off))
            guard along >= AppConfig.jamMinAheadMeters, along <= AppConfig.jamLookAheadMeters,
                  lateral <= AppConfig.jamCorridorMeters + along * AppConfig.jamCorridorSlope,
                  GeoMath.angleDifference(GeoMath.bearing(from: edge.a, to: edge.b), course)
                    <= AppConfig.trafficMatchDegrees else { continue }
            let edgeLength = GeoMath.fastDistance(edge.a.latitude, edge.a.longitude,
                                                  edge.b.latitude, edge.b.longitude)
            length += edgeLength
            delay += max(0, edgeLength / (max(3, edge.kmh) / 3.6) - edgeLength / (max(5, edge.modelKmh) / 3.6))
            if nearest == nil || along < nearest!.along { nearest = (along, edge.a) }
        }
        guard let nearest, length >= AppConfig.jamMinLengthMeters,
              delay >= AppConfig.jamMinDelaySeconds,
              nearest.along <= AppConfig.jamAnnounceWithinMeters else { return nil }
        return Jam(startsIn: nearest.along, length: length, delay: delay, start: nearest.point)
    }

    /// Не сказать о той же пробке дважды и не говорить слишком часто.
    struct Announcer: Equatable, Sendable {
        private var lastAt: Date?
        private var lastStart: CLLocationCoordinate2D?

        static func == (a: Announcer, b: Announcer) -> Bool {
            a.lastAt == b.lastAt && a.lastStart?.latitude == b.lastStart?.latitude
                && a.lastStart?.longitude == b.lastStart?.longitude
        }

        mutating func shouldAnnounce(_ jam: Jam, at now: Date) -> Bool {
            if let lastAt, now.timeIntervalSince(lastAt) < AppConfig.jamAnnounceGapSeconds { return false }
            if let lastStart, let lastAt,
               now.timeIntervalSince(lastAt) < AppConfig.jamSameJamSeconds,
               GeoMath.fastDistance(lastStart.latitude, lastStart.longitude,
                                    jam.start.latitude, jam.start.longitude) < AppConfig.jamSameJamMeters {
                return false
            }
            lastAt = now
            lastStart = jam.start
            return true
        }
    }
}

extension JamAhead {
    /// Пробка впереди для экрана машины (27.E): тот же JamAhead, что голос,
    /// баннером в общей очереди CarPlay (CarPlayBanners, ниже камеры и
    /// объезда). Живёт `carPlayJamBannerSeconds`; вытесненная камерой
    /// вернётся, пока не истекла, — закрытая водителем или истёкшая нет.
    struct Notice: Equatable, Sendable {
        let id: Int
        let jam: Jam
        let until: Date

        /// Показывать ли сейчас: осталось меньше пары секунд — нет,
        /// мелькнувший баннер за рулём хуже никакого (голос уже сказал).
        func isShowable(now: Date) -> Bool {
            until.timeIntervalSince(now) >= AppConfig.carPlayJamMinSeconds
        }
    }
}

/// Фраза — на главном потоке: Formatting знает язык приложения.
extension JamAhead.Jam {
    /// Баннер в машине: «Впереди пробка: +6 мин».
    var bannerTitle: String {
        String(format: String(localized: "Впереди пробка: +%@"),
               Formatting.unbreakable(Formatting.duration(delay)))
    }

    /// «около 1,2 км, через 300 м».
    var bannerSubtitle: String {
        String(format: String(localized: "около %1$@, через %2$@"),
               Formatting.distance((length / 100).rounded() * 100),
               Formatting.distance((startsIn / 50).rounded() * 50))
    }

    /// «Впереди пробка: около 1,2 км, плюс 6 мин».
    var spoken: String {
        String(format: String(localized: "Впереди пробка: около %1$@, плюс %2$@"),
               Formatting.distance((length / 100).rounded() * 100), Formatting.duration(delay))
    }
}
