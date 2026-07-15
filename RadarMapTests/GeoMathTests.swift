//
//  GeoMathTests.swift
//  RadarMapTests
//
//  Базовая геодезия — фундамент направленных оповещений и 3D-камеры.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class GeoMathTests: XCTestCase {

    func testBearingCardinalDirections() {
        let origin = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.25)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: 41.40, longitude: 69.25)),
                       0, accuracy: 0.5, "север")
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: 41.30, longitude: 69.35)),
                       90, accuracy: 0.5, "восток")
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: 41.20, longitude: 69.25)),
                       180, accuracy: 0.5, "юг")
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: 41.30, longitude: 69.15)),
                       270, accuracy: 0.5, "запад")
    }

    func testAngleDifferenceWrapsAroundNorth() {
        XCTAssertEqual(GeoMath.angleDifference(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(GeoMath.angleDifference(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(GeoMath.angleDifference(90, 270), 180, accuracy: 0.001)
        XCTAssertEqual(GeoMath.angleDifference(45, 45), 0, accuracy: 0.001)
    }

    func testFastDistanceMatchesHaversineWithinHalfPercent() {
        let pairs: [(Double, Double, Double, Double)] = [
            (41.311, 69.280, 41.326, 69.229),   // через Ташкент, ~4.6 км
            (41.300, 69.250, 41.302, 69.251),   // короткая, ~240 м
            (39.654, 66.975, 39.700, 67.100),   // Самарканд, ~12 км
        ]
        for (aLat, aLon, bLat, bLon) in pairs {
            let exact = CLLocation(latitude: aLat, longitude: aLon)
                .distance(from: CLLocation(latitude: bLat, longitude: bLon))
            let fast = GeoMath.fastDistance(aLat, aLon, bLat, bLon)
            XCTAssertLessThan(abs(exact - fast) / exact, 0.005,
                              "быстрая дистанция разошлась с точной больше чем на 0.5%")
        }
    }

    func testDestinationRoundTrip() {
        let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.25)
        let end = GeoMath.destination(from: start, bearing: 45, distanceMeters: 1000)
        let measured = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        XCTAssertEqual(measured, 1000, accuracy: 2)
        XCTAssertEqual(GeoMath.bearing(from: start, to: end), 45, accuracy: 0.5)
    }
}
