//
//  CarPlayManeuverLimitTests.swift
//  RadarMapTests
//
//  Знак лимита в тексте манёвра (25.H1, iOS 27): только когда лимит после
//  поворота известен, подтверждён двумя пробами и отличается от лимита до
//  него.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CarPlayManeuverLimitTests: XCTestCase {

    /// Прямая на восток вдоль широты, 1000 м, поворот на 500 м.
    private let origin = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.2)
    private var path: [CLLocationCoordinate2D] {
        [origin, GeoMath.destination(from: origin, bearing: 90, distanceMeters: 1000)]
    }

    /// Лимит по расстоянию от начала: до `turn` — `before`, после — `after`.
    private func limits(before: Int?, after: Int?, turn: Double = 500,
                        crossStreetAt: ClosedRange<Double>? = nil, cross: Int? = nil)
        -> (CLLocationCoordinate2D, Double) -> Int? {
        let origin = origin
        return { point, _ in
            let along = GeoMath.fastDistance(origin.latitude, origin.longitude, point.latitude, point.longitude)
            if let crossStreetAt, crossStreetAt.contains(along) { return cross }
            return along < turn ? before : after
        }
    }

    private func sign(current: Int? = nil, kind: ManeuverKind? = .right,
                      _ limit: @escaping (CLLocationCoordinate2D, Double) -> Int?) -> Int? {
        CarPlayManeuverLimit.sign(along: 500, kind: kind, path: path, current: current, limit: limit)
    }

    func testNewLimitAfterTheTurnIsShown() {
        XCTAssertEqual(sign(limits(before: 60, after: 40)), 40)
        XCTAssertEqual(sign(limits(before: 60, after: 80)), 80)
    }

    /// Везде 60 — знак на каждой карточке был бы шумом.
    func testSameLimitIsNotShown() {
        XCTAssertNil(sign(limits(before: 60, after: 60)))
    }

    func testUnknownAfterIsNotShown() {
        XCTAssertNil(sign(limits(before: 60, after: nil)))
    }

    /// «Отличается» не доказано: до поворота лимита нет ни в пробе, ни под
    /// машиной.
    func testUnknownBeforeIsNotShown() {
        XCTAssertNil(sign(limits(before: nil, after: 40)))
    }

    /// Проба до поворота молчит — сравниваем с текущим лимитом дороги.
    func testCurrentLimitIsTheFallbackBefore() {
        XCTAssertEqual(sign(current: 60, limits(before: nil, after: 40)), 40)
        XCTAssertNil(sign(current: 40, limits(before: nil, after: 40)))
    }

    /// Ближняя проба легла на поперечную улицу — пробы не сходятся, знака нет.
    func testProbesMustAgree() {
        XCTAssertNil(sign(limits(before: 60, after: 40, crossStreetAt: 540...560, cross: 70)))
        XCTAssertNil(sign(limits(before: 60, after: 40, crossStreetAt: 540...560, cross: nil)))
    }

    func testNoSignOnArrival() {
        XCTAssertNil(sign(kind: .arrive, limits(before: 60, after: 40)))
    }

    /// Проба за концом маршрута ничего не говорит о дороге.
    func testProbeBeyondTheRouteEndGivesNothing() {
        XCTAssertNil(CarPlayManeuverLimit.sign(along: 950, kind: .right, path: path, current: 60,
                                               limit: limits(before: 60, after: 40)))
        XCTAssertNil(CarPlayManeuverLimit.point(along: 1010, path: path))
        XCTAssertNil(CarPlayManeuverLimit.point(along: -1, path: path))
    }

    func testPointWalksTheLine() {
        let corner = GeoMath.destination(from: origin, bearing: 90, distanceMeters: 300)
        let line = [origin, corner, GeoMath.destination(from: corner, bearing: 0, distanceMeters: 300)]
        let east = CarPlayManeuverLimit.point(along: 150, path: line)
        XCTAssertEqual(GeoMath.angleDifference(east?.bearing ?? -90, 90), 0, accuracy: 1)
        let north = CarPlayManeuverLimit.point(along: 450, path: line)
        XCTAssertEqual(GeoMath.angleDifference(north?.bearing ?? 180, 0), 0, accuracy: 1)
        let travelled = north.map { GeoMath.fastDistance(corner.latitude, corner.longitude,
                                                         $0.coordinate.latitude, $0.coordinate.longitude) }
        XCTAssertEqual(travelled ?? 0, 150, accuracy: 1)
    }
}
