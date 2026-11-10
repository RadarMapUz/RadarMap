//
//  AppleTurn.swift
//  RadarMap
//
//  Тип поворота шага Apple (76). MKRoute.Step отдаёт готовую фразу и линию,
//  но не тип манёвра — и все шаги Apple рисовались стрелкой «прямо», даже
//  «поверните налево». Тип выводим из угла между линией до манёвра и после:
//  курс по отрезку в `AppConfig.appleTurnProbeMeters` по обе стороны, чтобы
//  излом последнего метра не решал за перекрёсток. Модификаторы — те же, что
//  у OSRM: дальше их читает тот же ManeuverKind. Чистая логика,
//  AppleTurnTests.
//

import CoreLocation
import Foundation

nonisolated enum AppleTurn {

    /// Модификатор OSRM по линии до манёвра (`incoming`, кончается в точке
    /// манёвра) и после (`outgoing`, начинается в ней). nil — линии мало,
    /// угол не судим.
    static func modifier(incoming: [CLLocationCoordinate2D], outgoing: [CLLocationCoordinate2D],
                         probe: CLLocationDistance = AppConfig.appleTurnProbeMeters) -> String? {
        guard let junction = incoming.last,
              let back = point(walking: incoming.reversed(), from: junction, meters: probe),
              let start = outgoing.first,
              let ahead = point(walking: outgoing, from: start, meters: probe) else { return nil }
        let before = GeoMath.bearing(from: back, to: junction)
        let after = GeoMath.bearing(from: start, to: ahead)
        return modifier(turn: signedTurn(from: before, to: after))
    }

    /// Поворот от курса `before` к `after`: −180…180°, плюс — направо.
    static func signedTurn(from before: Double, to after: Double) -> Double {
        let raw = (after - before).truncatingRemainder(dividingBy: 360)
        let wrapped = raw > 180 ? raw - 360 : raw <= -180 ? raw + 360 : raw
        return wrapped
    }

    static func modifier(turn: Double) -> String {
        let angle = abs(turn)
        let side = turn > 0 ? "right" : "left"
        if angle < AppConfig.appleTurnStraightDegrees { return "straight" }
        if angle < AppConfig.appleTurnSlightDegrees { return "slight " + side }
        if angle < AppConfig.appleTurnSharpDegrees { return side }
        if angle < AppConfig.appleTurnUturnDegrees { return "sharp " + side }
        return "uturn"
    }

    /// Иконка как у манёвров OSRM (RouteService.maneuverStep).
    static func icon(modifier: String?) -> String {
        switch modifier {
        case "left", "sharp left":   "arrow.turn.up.left"
        case "right", "sharp right": "arrow.turn.up.right"
        case "slight left":          "arrow.up.left"
        case "slight right":         "arrow.up.right"
        case "uturn":                "arrow.uturn.left"
        default:                     "arrow.up"
        }
    }

    /// Первая точка линии не ближе `meters` от `origin`; линия короче — её
    /// конец, если он хоть на несколько метров в стороне; иначе nil.
    private static func point<S: Sequence>(walking points: S, from origin: CLLocationCoordinate2D,
                                           meters: CLLocationDistance) -> CLLocationCoordinate2D?
    where S.Element == CLLocationCoordinate2D {
        var last: (point: CLLocationCoordinate2D, distance: Double)?
        for candidate in points {
            let distance = GeoMath.fastDistance(origin.latitude, origin.longitude,
                                                candidate.latitude, candidate.longitude)
            if distance >= meters { return candidate }
            last = (candidate, distance)
        }
        guard let last, last.distance >= AppConfig.appleTurnMinProbeMeters else { return nil }
        return last.point
    }
}
