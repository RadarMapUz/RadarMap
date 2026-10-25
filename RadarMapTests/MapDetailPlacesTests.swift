//
//  MapDetailPlacesTests.swift
//  RadarMapTests
//
//  Значки «нужного сейчас» (29.H): парковки у цели — ближайшая первой и не
//  дальше радиуса; заправки — только впереди по маршруту и только топливо
//  машины; пунктир к цели — не хвостик и не через квартал; кадр у цели
//  держит её вместе с камерой.
//

import CoreLocation
import MapKit
import XCTest
@testable import RadarMap

final class MapDetailPlacesTests: XCTestCase {

    private let destination = CLLocationCoordinate2D(latitude: 41.3260, longitude: 69.2810)

    private func at(_ bearing: Double, _ meters: Double, from: CLLocationCoordinate2D? = nil) -> CLLocationCoordinate2D {
        GeoMath.destination(from: from ?? destination, bearing: bearing, distanceMeters: meters)
    }

    func testParkingsNearestFirstWithinRadius() {
        let venues = [
            Venue(kind: .parking, name: "far", point: at(0, 250)),
            Venue(kind: .parking, name: "near", point: at(90, 60)),
            Venue(kind: .parking, name: "outside", point: at(180, 420)),
            Venue(kind: .fuel, name: "fuel", point: at(270, 30)),
        ]
        let found = MapDetailPlaces.parkings(venues, destination: destination)
        XCTAssertEqual(found.map(\.name), ["near", "far"], "дальше 300 м и не парковки — нет")
    }

    func testFuelOnlyAheadAlongTheRouteAndOfTheCarKind() {
        // Маршрут строго на север, 3 км.
        let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)
        let route = stride(from: 0.0, through: 3_000, by: 100).map { MKMapPoint(at(0, $0, from: start)) }
        let venues = [
            Venue(kind: .fuel, name: "behind", point: at(0, 200, from: start)),
            Venue(kind: .fuel, name: "ahead", point: at(85, 120, from: at(0, 1_500, from: start))),
            Venue(kind: .fuel, name: "aside", point: at(90, 900, from: at(0, 1_200, from: start))),
            Venue(kind: .cng, name: "metan", point: at(270, 80, from: at(0, 2_000, from: start))),
        ]
        let petrol = MapDetailPlaces.fuelAhead(venues, kinds: [.fuel], route: route, progress: 600)
        XCTAssertEqual(petrol.map(\.name), ["ahead"], "позади и в стороне — нет; метан бензиновой машине — шум")
        let gas = MapDetailPlaces.fuelAhead(venues, kinds: [.cng, .fuel], route: route, progress: 600)
        XCTAssertEqual(gas.map(\.name), ["ahead", "metan"], "по порядку следования")
    }

    func testApproachOnlyBetweenTwentyMetersAndABlock() {
        XCTAssertNil(MapDetailPlaces.approach(routeEnd: at(0, 12), destination: destination),
                     "короткий хвостик у линии читается как ошибка")
        XCTAssertNotNil(MapDetailPlaces.approach(routeEnd: at(0, 45), destination: destination))
        XCTAssertNil(MapDetailPlaces.approach(routeEnd: at(0, 600), destination: destination),
                     "через квартал — это не «подойти от машины»")
        XCTAssertNil(MapDetailPlaces.approach(routeEnd: nil, destination: destination))
    }

    func testArrivalKeepZoomsOutToShowDestinationButNotPastCity() {
        func frame(_ also: [DriveCamera.Keep]) -> DriveCamera.Frame {
            DriveCamera.target(speedKmh: 30, maneuverDistance: nil, pitchAllowed: true, screen: .car,
                               alsoKeep: also, viewHeight: 382, latitude: 41.3, carY: { _ in 0.75 })
        }
        let free = frame([])
        let held = frame([DriveCamera.Keep(forward: 420, right: 60)])
        XCTAssertLessThan(held.zoom, free.zoom, "цель в 420 м — кадр отъезжает, чтобы её показать")
        XCTAssertGreaterThanOrEqual(held.zoom, DriveCamera.keepMinZoom(speedKmh: 30) - 1e-9)
        let far = frame([DriveCamera.Keep(forward: 900, right: 0)])
        XCTAssertEqual(far.zoom, free.zoom, accuracy: 1e-9, "дальше 500 м цель кадр не тянет")
    }
}
