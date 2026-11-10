//
//  ManeuverAnchor.swift
//  RadarMap
//
//  Где манёвр на линии маршрута (76). Прогресс машины меряется по длине
//  линии, а позиция манёвра считалась суммой `step.distance` OSRM: две мерки
//  расходятся на доли процента, и на трассе к сотому километру «через 300
//  метров» звучало на сотни метров раньше или позже поворота.
//
//  Точка манёвра OSRM (`maneuver.location`) — вершина линии. Ищем её рядом с
//  ожидаемым местом (сумма длин + накопленная поправка) и берём длину линии
//  до неё. Не нашли — прежняя сумма с последней поправкой, не раньше
//  предыдущего манёвра. Окно поиска — чтобы петля, дважды проходящая один
//  узел, не привязала манёвр к чужому проходу. Чистая логика,
//  ManeuverAnchorTests.
//

import CoreLocation
import Foundation

nonisolated enum ManeuverAnchor {

    struct Position: Equatable, Sendable {
        /// Метры от старта по линии.
        let along: CLLocationDistance
        /// Вершина линии под манёвром; nil — не нашли, позиция по сумме длин.
        let vertex: Int?
    }

    /// Позиции шагов по порядку. `locations` — [lon, lat] начала шага,
    /// `distances` — длины шагов, `cumulative[i]` — длина линии до вершины i.
    static func positions(locations: [[Double]?], distances: [CLLocationDistance],
                          path: [CLLocationCoordinate2D],
                          cumulative: [CLLocationDistance]) -> [Position] {
        let usable = path.count >= 2 && cumulative.count == path.count
        let length = cumulative.last ?? 0
        var out: [Position] = []
        out.reserveCapacity(distances.count)
        var sum: CLLocationDistance = 0, drift: CLLocationDistance = 0
        var last: CLLocationDistance = 0, previous: CLLocationDistance = 0
        var vertex = 0
        for index in distances.indices {
            let expected = sum + drift
            let slack = max(AppConfig.maneuverAnchorSlackMeters, previous * AppConfig.maneuverAnchorSlackShare)
            var found: Int?
            if usable, locations.indices.contains(index), let at = locations[index] {
                let start = max(vertex, lowerBound(cumulative, expected - slack))
                found = vertexIndex(of: at, in: path, from: start,
                                    while: { cumulative[$0] <= expected + slack })
            }
            if let found {
                last = cumulative[found]
                drift = last - sum
                vertex = found
            } else {
                last = max(last, usable ? min(expected, length) : expected)
            }
            out.append(Position(along: last, vertex: found))
            previous = distances[index]
            sum += distances[index]
        }
        return out
    }

    /// Вершина линии, совпадающая с точкой ([lon, lat]), начиная с `start`,
    /// пока `allowed` пускает дальше. nil — не нашли.
    static func vertexIndex(of location: [Double], in path: [CLLocationCoordinate2D], from start: Int,
                            while allowed: (Int) -> Bool = { _ in true }) -> Int? {
        guard location.count == 2 else { return nil }
        let tolerance = 1e-6
        var index = max(0, start)
        while index < path.count, allowed(index) {
            if abs(path[index].longitude - location[0]) < tolerance,
               abs(path[index].latitude - location[1]) < tolerance { return index }
            index += 1
        }
        return nil
    }

    private static func lowerBound(_ cumulative: [CLLocationDistance], _ value: CLLocationDistance) -> Int {
        var lo = 0, hi = cumulative.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
