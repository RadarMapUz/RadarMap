//
//  MapDetailPlaces.swift
//  RadarMap
//
//  Наши значки «нужного сейчас» (29.H): заправки впереди по маршруту,
//  парковки у цели, ближайшие из «По пути» на дальней дороге и пунктир от
//  конца маршрута к цели. Сколько показать — решает MapDetailPolicy, что
//  именно — здесь. Данные — подписанные файлы заведений (VenueBook) и
//  коридор маршрута (CorridorVenues), не слой тайлов: у слоя нельзя
//  спросить «по пути ли» и «насколько близко к цели», а ближайшая к цели
//  парковка должна быть крупнее остальных.
//
//  Чистое — MapDetailPlacesTests.
//

import CoreLocation
import Foundation
import MapKit

nonisolated enum MapDetailPlaces {

    /// Что найдено для текущего маршрута (до урезания решением).
    struct Found: Equatable, Sendable {
        /// Заправки вида машины впереди по линии, по порядку следования.
        var fuelAhead: [Venue] = []
        /// Парковки у цели — ближайшая первой.
        var parkings: [Venue] = []
        /// Ближайшие впереди из «По пути» (топливо, кафе, гостиницы).
        var corridor: [Venue] = []

        static let empty = Found()
    }

    /// Значок на карте. `rank` 0 — главный (ближайшая к цели парковка):
    /// крупнее и не уступает место подписям.
    struct Mark: Equatable, Sendable {
        var kind: Venue.Kind
        var latitude: Double
        var longitude: Double
        var rank: Int

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    // MARK: - Отбор

    /// Значки, разрешённые решением, — по порядку важности.
    static func marks(_ decision: MapDetailPolicy.Decision, found: Found) -> [Mark] {
        var out: [Mark] = []
        for (i, venue) in found.parkings.prefix(decision.parking.destinationLimit).enumerated() {
            out.append(mark(venue, rank: i))
        }
        for venue in found.fuelAhead.prefix(decision.fuel.aheadLimit) {
            out.append(mark(venue, rank: 1))
        }
        if decision.corridor > 0 {
            let fuelGroup = found.corridor.filter {
                decision.corridorFood || CorridorVenues.group(of: $0.kind) == .fuel
            }
            for venue in fuelGroup.prefix(decision.corridor) { out.append(mark(venue, rank: 1)) }
        }
        return out
    }

    private static func mark(_ venue: Venue, rank: Int) -> Mark {
        Mark(kind: venue.kind, latitude: venue.point.latitude, longitude: venue.point.longitude, rank: rank)
    }

    // MARK: - Парковки у цели

    /// Парковки не дальше `radius` от цели, ближайшая первой. По прямой: у
    /// цели водитель уже выбирает, куда свернуть, и «200 м до входа»
    /// понятнее, чем «200 м по маршруту», которого к парковке нет.
    static func parkings(_ venues: [Venue], destination: CLLocationCoordinate2D,
                         radius: Double = AppConfig.mapDetailArrivalParkingMeters,
                         limit: Int = AppConfig.mapDetailParkingsKept) -> [Venue] {
        let scored = venues.compactMap { venue -> (Venue, Double)? in
            guard venue.kind == .parking else { return nil }
            let d = GeoMath.fastDistance(destination.latitude, destination.longitude,
                                         venue.point.latitude, venue.point.longitude)
            return d <= radius ? (venue, d) : nil
        }
        return Array(scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0))
    }

    // MARK: - Заправки по пути

    /// Заправки видов `kinds` (топливо машины) не дальше `corridor` от линии
    /// маршрута и не дальше `maxAhead` впереди `progress` — по порядку
    /// следования. Позади и за поворотом в другую сторону не нужны.
    static func fuelAhead(_ venues: [Venue], kinds: [Venue.Kind], route: [MKMapPoint], progress: Double,
                          corridor: Double = AppConfig.venueRouteCorridorMeters,
                          maxAhead: Double = AppConfig.mapDetailFuelAheadMeters,
                          limit: Int = AppConfig.mapDetailFuelKept) -> [Venue] {
        guard route.count >= 2, !kinds.isEmpty else { return [] }
        let book = VenueBook(venues: venues.filter { kinds.contains($0.kind) })
        var found: [(venue: Venue, ahead: Double)] = []
        for kind in Set(kinds) {
            found += book.alongRoute(kind, points: route, progress: progress, corridor: corridor,
                                     limit: limit).filter { $0.ahead <= maxAhead }
        }
        return Array(found.sorted { ($0.ahead, $0.venue.id) < ($1.ahead, $1.venue.id) }.prefix(limit).map(\.venue))
    }

    // MARK: - Пунктир к цели

    /// От конца маршрута (где машина остановится) до цели — если цель дальше
    /// `mapDetailApproachMinMeters`: короткий хвостик у самой линии читается
    /// как ошибка рисования. Дальше `mapDetailApproachMaxMeters` — тоже нет:
    /// это уже не «подойти от машины», а маршрут не туда, и пунктир через
    /// квартал сказал бы обратное.
    static func approach(routeEnd: CLLocationCoordinate2D?,
                         destination: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D]? {
        guard let routeEnd, let destination else { return nil }
        let d = GeoMath.fastDistance(routeEnd.latitude, routeEnd.longitude,
                                     destination.latitude, destination.longitude)
        guard d >= AppConfig.mapDetailApproachMinMeters, d <= AppConfig.mapDetailApproachMaxMeters else { return nil }
        return [routeEnd, destination]
    }
}
