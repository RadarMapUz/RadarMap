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
        /// Где кусок лежит на линии: метры от её начала (27.A — краска
        /// окна у машины берёт пробки по месту на линии, а не по точкам).
        var from: Double = 0
        var to: Double = 0

        static func == (l: Piece, r: Piece) -> Bool {
            l.level == r.level && l.coordinates.count == r.coordinates.count
                && zip(l.coordinates, r.coordinates).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    static let stepMeters = 25.0

    /// `cumulative` — пройденное по линии до каждой точки (длины
    /// EngineMapPresentation.RouteIndex): с ним `from`/`to` кусков — в той же
    /// мере, что и срез линии у машины; без него — своя быстрая оценка.
    /// `levels` — какие уровни собирать: линия маршрута — только «медленно»
    /// и «стоим» (свободно её не трогает); полоса хода маршрута (29.B) —
    /// и «свободно», чтобы отличить зелёное от «данных нет».
    static func pieces(along route: [CLLocationCoordinate2D], snapshot: TrafficSnapshot,
                       minMeters: Double = AppConfig.routeTrafficMinMeters,
                       cumulative: [Double]? = nil,
                       levels: ClosedRange<Int> = 2...3) -> [Piece] {
        guard route.count >= 2, !snapshot.edges.isEmpty else { return [] }
        let measured = cumulative.flatMap { $0.count == route.count ? $0 : nil }
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

        var walked = 0.0
        for (i, (p, q)) in zip(route, route.dropFirst()).enumerated() {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            let start = measured?[i] ?? walked
            let span = measured.map { $0[i + 1] - $0[i] } ?? length
            walked += length
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
                    .map(\.level).flatMap { levels.contains($0) ? $0 : nil }
                if level != current?.level { close() }
                guard let level else { continue }
                if current == nil {
                    current = Piece(level: level, coordinates: [at(t0)], from: start + span * t0)
                }
                current?.coordinates.append(at(t1))
                current?.to = start + span * t1
                currentLength += length / Double(steps)
            }
        }
        close()
        return out
    }
}
