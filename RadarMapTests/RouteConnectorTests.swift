//
//  RouteConnectorTests.swift
//  RadarMapTests
//
//  Пунктир от машины до начала линии: только пока машина не на линии.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RouteConnectorTests: XCTestCase {
    private let start = CLLocationCoordinate2D(latitude: 41.342, longitude: 69.337)

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: start.latitude + meters / 110_540, longitude: start.longitude)
    }

    func testDrawnFromCarToLineWhenOffRoad() {
        let line = RouteConnector.line(car: north(28), target: start, cut: 0)
        XCTAssertEqual(line?.count, 2)
        XCTAssertEqual(line?.first?.latitude, north(28).latitude)
    }

    func testHiddenOnTheLineAndWhenFarOrUnderway() {
        XCTAssertNil(RouteConnector.line(car: north(4), target: start, cut: 0), "под значком")
        XCTAssertNil(RouteConnector.line(car: north(800), target: start, cut: 0), "другое место")
        XCTAssertNil(RouteConnector.line(car: north(30), target: start, cut: 200), "уже в пути")
    }

    func testStandstillNoiseDoesNotRewriteSource() {
        let written = [north(28), start]
        XCTAssertFalse(RouteConnector.needsWrite(written: written, wanted: [north(29), start]))
        XCTAssertTrue(RouteConnector.needsWrite(written: written, wanted: [north(40), start]))
        XCTAssertTrue(RouteConnector.needsWrite(written: written, wanted: nil))
        XCTAssertFalse(RouteConnector.needsWrite(written: nil, wanted: nil))
    }
}
