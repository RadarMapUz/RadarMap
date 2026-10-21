//
//  RouteTraffic.swift
//  RadarMap
//
//  Пробки НА ЛИНИИ маршрута (25.D, 21.10): участки «медленно» и «стоим»
//  перекрашивают саму линию, как у навигаторов, а не лежат рядом тонкой
//  ниткой. Совпадение — то же, что у времени в пути (TrafficSnapshot.delay):
//  место ≤ 18 м и направление ≤ 35°, поэтому пробка на встречной полосе
//  проспекта нашу линию не красит. Свободное ребро линию не трогает: маршрут
//  остаётся синим (Theme.route), а зелёный — «в норме», не «твой путь».
//
//  Шаг — 25 м, как у задержки; участок короче `minMeters` отбрасывается —
//  одиночное медленное ребро на перекрёстке мигало бы пятном.
//
//  Только картинка: ни предупреждения, ни ETA отсюда не читаются.
//  Чистая логика, покрыта RouteTrafficTests.
//

import CoreLocation
import Foundation

nonisolated enum RouteTraffic {

    /// Кусок линии с уровнем: 2 — медленно, 3 — пробка.
    struct Piece: Equatable, Sendable {
        let level: Int
        var coordinates: [CLLocationCoordinate2D]

        static func == (l: Piece, r: Piece) -> Bool {
            l.level == r.level && l.coordinates.count == r.coordinates.count
                && zip(l.coordinates, r.coordinates).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    static let stepMeters = 25.0

    static func pieces(along route: [CLLocationCoordinate2D], snapshot: TrafficSnapshot,
                       minMeters: Double = AppConfig.routeTrafficMinMeters) -> [Piece] {
        guard route.count >= 2, !snapshot.edges.isEmpty else { return [] }
        var out: [Piece] = []
        var current: Piece?
        var currentLength = 0.0

        func close() {
            if let piece = current, piece.coordinates.count >= 2, currentLength >= minMeters {
                out.append(piece)
            }
            current = nil
            currentLength = 0
        }

        for (p, q) in zip(route, route.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard length > 0.5 else { continue }
            let course = GeoMath.bearing(from: p, to: q)
            let steps = max(1, Int((length / stepMeters).rounded(.up)))
            func at(_ t: Double) -> CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                       longitude: p.longitude + (q.longitude - p.longitude) * t)
            }
            for s in 0..<steps {
                let t0 = Double(s) / Double(steps), t1 = Double(s + 1) / Double(steps)
                let level = snapshot.matchingEdge(at: at((t0 + t1) / 2), course: course)
                    .map(\.level).flatMap { $0 >= 2 ? $0 : nil }
                if level != current?.level { close() }
                guard let level else { continue }
                if current == nil { current = Piece(level: level, coordinates: [at(t0)]) }
                current?.coordinates.append(at(t1))
                currentLength += length / Double(steps)
            }
        }
        close()
        return out
    }
}
