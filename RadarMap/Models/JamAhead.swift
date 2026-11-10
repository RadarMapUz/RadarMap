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
//    * только связная цепочка рёбер от своего ребра вперёд — встречная
//      пробка и пробка на дублёре не наши; своего ребра нет — молчим;
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

    /// Пробка впереди или nil. Идём от СВОЕГО ребра (ближайшее по месту и
    /// направлению) вперёд по связной цепочке: конец ребра — начало
    /// следующего, на развилке — продолжение прямее; дыра в наблюдениях или
    /// свободное ребро внутри пробки терпятся до `jamGapMeters`. Своего ребра
    /// нет — молчим: прямая от курса складывала дублёр с проспектом и теряла
    /// пробку за изгибом.
    static func detect(in snapshot: TrafficSnapshot, position: CLLocationCoordinate2D,
                       course: CLLocationDirection) -> Jam? {
        guard course >= 0, course.isFinite,
              let own = snapshot.matchingIndex(at: position, course: course,
                                               within: AppConfig.jamOwnEdgeMeters) else { return nil }
        let edges = snapshot.edges
        var visited: Set<Int> = [own]
        var index = own
        // Остаток своего ребра — от машины до его конца.
        var piece = min(GeoMath.fastDistance(position.latitude, position.longitude,
                                             edges[own].b.latitude, edges[own].b.longitude),
                        GeoMath.fastDistance(edges[own].a.latitude, edges[own].a.longitude,
                                             edges[own].b.latitude, edges[own].b.longitude))
        var walked = 0.0, gap = 0.0
        var length: CLLocationDistance = 0
        var delay: TimeInterval = 0
        var begin: (along: Double, point: CLLocationCoordinate2D)?
        while true {
            let edge = edges[index]
            if edge.level >= 2 {
                if begin == nil { begin = (walked, index == own ? position : edge.a) }
                length += piece
                delay += max(0, piece / (max(3, edge.kmh) / 3.6) - piece / (max(5, edge.modelKmh) / 3.6))
                gap = 0
            } else if begin != nil {
                gap += piece
            }
            walked += piece
            guard gap <= AppConfig.jamGapMeters, walked < AppConfig.jamLookAheadMeters,
                  begin != nil || walked <= AppConfig.jamAnnounceWithinMeters else { break }
            if let next = straightest(after: index, in: snapshot, visited: visited) {
                index = next
            } else if let jump = acrossHole(after: index, in: snapshot, visited: visited) {
                if begin != nil { gap += jump.meters }
                walked += jump.meters
                guard gap <= AppConfig.jamGapMeters else { break }
                index = jump.index
            } else {
                break
            }
            visited.insert(index)
            piece = GeoMath.fastDistance(edges[index].a.latitude, edges[index].a.longitude,
                                         edges[index].b.latitude, edges[index].b.longitude)
        }
        guard let begin, length >= AppConfig.jamMinLengthMeters,
              delay >= AppConfig.jamMinDelaySeconds,
              begin.along <= AppConfig.jamAnnounceWithinMeters else { return nil }
        return Jam(startsIn: begin.along, length: length, delay: delay, start: begin.point)
    }

    /// Продолжение из конца ребра: то, что отклоняется меньше всех, и не
    /// круче `jamMaxTurnDegrees` — поворот на боковую улицу не «впереди».
    private static func straightest(after index: Int, in snapshot: TrafficSnapshot, visited: Set<Int>) -> Int? {
        let heading = snapshot.bearing(of: index)
        var best: (index: Int, turn: Double)?
        for next in snapshot.continuations(of: index) where !visited.contains(Int(next)) {
            let turn = GeoMath.angleDifference(snapshot.bearing(of: Int(next)), heading)
            guard turn <= AppConfig.jamMaxTurnDegrees else { continue }
            if best == nil || turn < best!.turn { best = (Int(next), turn) }
        }
        return best?.index
    }

    /// Следующее ребро за дырой в наблюдениях: начинается прямо по ходу не
    /// дальше `jamGapMeters` и не в стороне (дублёр лежит дальше допуска).
    private static func acrossHole(after index: Int, in snapshot: TrafficSnapshot,
                                   visited: Set<Int>) -> (index: Int, meters: Double)? {
        let end = snapshot.edges[index].b
        let heading = snapshot.bearing(of: index)
        let far = GeoMath.destination(from: end, bearing: heading, distanceMeters: AppConfig.jamGapMeters)
        var best: (index: Int, meters: Double)?
        for candidate in snapshot.candidates(end, far, course: heading) where !visited.contains(Int(candidate)) {
            let start = snapshot.edges[Int(candidate)].a
            let distance = GeoMath.fastDistance(end.latitude, end.longitude, start.latitude, start.longitude)
            guard distance > 1, distance <= AppConfig.jamGapMeters else { continue }
            let off = (GeoMath.bearing(from: end, to: start) - heading) * .pi / 180
            guard cos(off) > 0, abs(distance * sin(off)) <= AppConfig.jamGapSideMeters else { continue }
            if best == nil || distance < best!.meters { best = (Int(candidate), distance) }
        }
        return best
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
    /// Баннер в машине: «Пробка впереди: задержка 6 мин».
    var bannerTitle: String {
        String(format: String(localized: "Пробка впереди: задержка %@"),
               Formatting.unbreakable(Formatting.duration(delay)))
    }

    /// «длина около 1,2 км, начало через 300 м».
    var bannerSubtitle: String {
        String(format: String(localized: "длина около %1$@, начало через %2$@"),
               Formatting.distance((length / 100).rounded() * 100),
               Formatting.distance((startsIn / 50).rounded() * 50))
    }

    /// «Впереди пробка: около 1,2 км, плюс 6 мин».
    var spoken: String {
        String(format: String(localized: "Впереди пробка: около %1$@, плюс %2$@"),
               Formatting.distance((length / 100).rounded() * 100), Formatting.duration(delay))
    }
}
