//
//  ManeuverArrow.swift
//  RadarMap
//
//  Стрелка манёвра НА ЛИНИИ маршрута (29.G, как у Amap и Яндекса): белое
//  древко по линии от чуть до поворота до чуть после и наконечник по курсу
//  выезда. Подсвеченный отрезок линии у манёвра (route-maneuver) говорит
//  «здесь что-то будет», стрелка — «сюда».
//
//  Геометрия — раз на манёвр (не на тике): точки линии маршрута между
//  `along − back` и `along + ahead`, наконечник — в конце, курс — по
//  последним метрам древка. Короткий хвост линии (финиш сразу за поворотом)
//  укорачивает древко, а не тянет его за конец маршрута. Прибытие и «прямо»
//  стрелки не получают — поворота нет. Чистая логика, ManeuverArrowTests.
//

import CoreLocation
import Foundation
import MapKit

nonisolated enum ManeuverArrow {

    struct Shape: Equatable, Sendable {
        let shaft: [CLLocationCoordinate2D]
        let head: CLLocationCoordinate2D
        /// Курс наконечника, градусы от севера.
        let bearing: Double

        static func == (l: Shape, r: Shape) -> Bool {
            l.bearing == r.bearing && l.shaft.count == r.shaft.count
                && zip(l.shaft + [l.head], r.shaft + [r.head]).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    /// Стрелку рисуем только у настоящего поворота.
    static func draws(_ kind: ManeuverKind?) -> Bool {
        guard let kind else { return false }
        switch kind {
        case .arrive, .straight: return false
        default: return true
        }
    }

    static func shape(along: Double, kind: ManeuverKind?, route: [CLLocationCoordinate2D], cumulative: [Double],
                      back: Double = AppConfig.maneuverArrowBackMeters,
                      ahead: Double = AppConfig.maneuverArrowAheadMeters) -> Shape? {
        guard draws(kind), route.count >= 2, cumulative.count == route.count,
              let length = cumulative.last, along.isFinite, along > 0, along < length else { return nil }
        let start = max(0, along - back)
        let end = min(length, along + ahead)
        // Хвост короче трети нормы — наконечник лёг бы на сам поворот, и
        // стрелка смотрела бы туда, откуда едем.
        guard end - along >= ahead / 3 else { return nil }
        var shaft: [CLLocationCoordinate2D] = []
        if let a = ManeuverCallout.point(along: start, route: route, cumulative: cumulative) { shaft.append(a) }
        for i in route.indices where cumulative[i] > start && cumulative[i] < end { shaft.append(route[i]) }
        guard let head = ManeuverCallout.point(along: end, route: route, cumulative: cumulative),
              let tail = ManeuverCallout.point(along: max(along, end - AppConfig.maneuverArrowHeadBaseMeters),
                                               route: route, cumulative: cumulative) else { return nil }
        shaft.append(head)
        guard shaft.count >= 2 else { return nil }
        return Shape(shaft: shaft, head: head, bearing: GeoMath.bearing(from: tail, to: head))
    }

    /// Длины по линии — в той же мере, что прогресс маршрута
    /// (RouteService.cumulative: расстояния MKMapPoint).
    static func cumulative(_ route: [CLLocationCoordinate2D]) -> [Double] {
        RouteService.cumulative(of: route.map(MKMapPoint.init))
    }
}
