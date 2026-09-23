import MapKit
import os

/// Геометрия отображения: не участвует в оповещениях и определении полосы машины.
nonisolated enum EngineMapPresentation {
    /// Индекс строится один раз на поколение маршрута, не на каждом GPS-тике.
    struct RouteIndex: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let cumulative: [Double]

        init(_ coordinates: [CLLocationCoordinate2D]) {
            self.coordinates = coordinates
            var distances = [Double]()
            distances.reserveCapacity(coordinates.count)
            var sum = 0.0
            for i in coordinates.indices {
                if i > 0 { sum += MKMapPoint(coordinates[i - 1]).distance(to: MKMapPoint(coordinates[i])) }
                distances.append(sum)
            }
            cumulative = distances
        }

        var length: Double { cumulative.last ?? 0 }

        func slice(from start: Double, to end: Double) -> [CLLocationCoordinate2D] {
            guard coordinates.count > 1, start.isFinite, end.isFinite else { return [] }
            let low = max(0, start), high = min(length, end)
            guard high > low else { return [] }
            func locate(_ distance: Double) -> (Int, CLLocationCoordinate2D) {
                var a = 1, b = cumulative.count - 1
                while a < b {
                    let mid = (a + b) / 2
                    if cumulative[mid] < distance { a = mid + 1 } else { b = mid }
                }
                let before = MKMapPoint(coordinates[a - 1]), after = MKMapPoint(coordinates[a])
                let span = cumulative[a] - cumulative[a - 1]
                let t = span > 0 ? (distance - cumulative[a - 1]) / span : 0
                return (a, MKMapPoint(x: before.x + (after.x - before.x) * t,
                                     y: before.y + (after.y - before.y) * t).coordinate)
            }
            let (first, a) = locate(low), (last, b) = locate(high)
            return [a] + Array(coordinates[first..<last]) + [b]
        }
    }

    struct RouteFrame: Sendable {
        let index: RouteIndex
        let traveled: [CLLocationCoordinate2D]
        let remaining: [CLLocationCoordinate2D]
        let maneuver: [CLLocationCoordinate2D]
    }

    @concurrent static func prepareRoute(_ coordinates: [CLLocationCoordinate2D],
                                         index: RouteIndex?, progress: Double, maneuver: Double?) async -> RouteFrame {
        let log = OSLog(subsystem: "uz.radarmap", category: "MapPerformance")
        os_signpost(.begin, log: log, name: "Route preparation")
        defer { os_signpost(.end, log: log, name: "Route preparation") }
        let indexed = index ?? RouteIndex(coordinates)
        let along = progress.isFinite ? max(0, min(indexed.length, progress)) : 0
        let turn: [CLLocationCoordinate2D]
        if let maneuver, maneuver >= along, maneuver - along <= AppConfig.engineManeuverApproachMeters {
            turn = indexed.slice(from: max(along, maneuver - AppConfig.engineManeuverHighlightMeters),
                                 to: maneuver + AppConfig.engineManeuverHighlightMeters)
        } else { turn = [] }
        return RouteFrame(index: indexed, traveled: indexed.slice(from: 0, to: along),
                          remaining: indexed.slice(from: along, to: indexed.length), maneuver: turn)
    }

    /// Запас области уменьшает частоту перестановки символов при скролле.
    static func contains(_ outer: MKCoordinateRegion, _ inner: MKCoordinateRegion) -> Bool {
        abs(outer.center.latitude - inner.center.latitude) + inner.span.latitudeDelta / 2 <= outer.span.latitudeDelta / 2
        && abs(outer.center.longitude - inner.center.longitude) + inner.span.longitudeDelta / 2 <= outer.span.longitudeDelta / 2
    }

    static func padded(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(center: region.center, span: MKCoordinateSpan(
            latitudeDelta: min(170, region.span.latitudeDelta * AppConfig.engineCameraViewportPadding),
            longitudeDelta: min(350, region.span.longitudeDelta * AppConfig.engineCameraViewportPadding)))
    }
    static func maneuver(_ coordinates: [CLLocationCoordinate2D], at distance: Double?, progress: Double)
        -> [CLLocationCoordinate2D] {
        guard let distance, distance >= progress,
              distance - progress <= AppConfig.engineManeuverApproachMeters else { return [] }
        let throughTurn = split(coordinates, at: distance + AppConfig.engineManeuverHighlightMeters).traveled
        return split(throughTurn, at: max(progress, distance - AppConfig.engineManeuverHighlightMeters)).remaining
    }
    static func span(speedKmh: Double, maneuverDistance: Double?, active: Bool) -> Double {
        guard active else { return AppConfig.engineOverviewSpan }
        let cruise = min(1_600, max(550, 550 + max(0, speedKmh - 30) * 11))
        guard let distance = maneuverDistance, distance.isFinite, distance >= 0 else { return cruise }
        let approach = min(1, max(0, distance / AppConfig.engineManeuverApproachMeters))
        return AppConfig.engineCloseSpan + (cruise - AppConfig.engineCloseSpan) * approach
    }

    /// Короткий путь через север: 359° → 1° не должен делать полный оборот.
    static func heading(_ target: Double, near previous: Double) -> Double {
        guard target.isFinite, target >= 0 else { return previous }
        let delta = (target - previous).truncatingRemainder(dividingBy: 360)
        return previous + (delta > 180 ? delta - 360 : delta < -180 ? delta + 360 : delta)
    }

    /// Обе части делят одну точку среза; петля не проецируется на соседнюю ветку.
    static func split(_ coordinates: [CLLocationCoordinate2D], at distance: Double)
        -> (traveled: [CLLocationCoordinate2D], remaining: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1, distance.isFinite, distance > 0 else { return ([], coordinates) }
        var accumulated = 0.0
        for index in 1..<coordinates.count {
            let a = MKMapPoint(coordinates[index - 1]), b = MKMapPoint(coordinates[index])
            let length = a.distance(to: b)
            if accumulated + length >= distance, length > 0 {
                let t = (distance - accumulated) / length
                let cut = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).coordinate
                return (Array(coordinates[..<index]) + [cut], [cut] + Array(coordinates[index...]))
            }
            accumulated += length
        }
        return (coordinates, [])
    }
}
