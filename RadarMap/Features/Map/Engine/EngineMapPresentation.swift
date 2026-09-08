import MapKit

/// Геометрия отображения: не участвует в оповещениях и определении полосы машины.
nonisolated enum EngineMapPresentation {
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
