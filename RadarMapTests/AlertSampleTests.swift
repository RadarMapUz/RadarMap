//
//  AlertSampleTests.swift
//  RadarMapTests
//

import XCTest
@testable import RadarMap

final class AlertSampleTests: XCTestCase {

    func testShownOnlyOutsideATripAndARealAlert() {
        XCTAssertTrue(AlertSample.canShow(isTripActive: false, isApproachingCamera: false))
        XCTAssertFalse(AlertSample.canShow(isTripActive: true, isApproachingCamera: false))
        XCTAssertFalse(AlertSample.canShow(isTripActive: false, isApproachingCamera: true))
        XCTAssertFalse(AlertSample.canShow(isTripActive: true, isApproachingCamera: true))
    }

    /// Выдуманная камера не совпадает ни с одной настоящей: id из базы
    /// положительные, а по id живут история проездов и скрытые камеры.
    func testTheSampleCameraIsNotFromTheDatabase() {
        XCTAssertLessThan(AlertSample.camera.id, 0)
        XCTAssertEqual(AlertSample.camera.kind, .stationaryCamera)
    }

    /// Картинка не противоречит фразе и сама себе: не превышение, полоса
    /// приближения не пустая и не полная.
    func testTheSceneIsConsistent() {
        XCTAssertLessThan(AlertSample.speedKmh, Double(AlertSample.limitKmh))
        XCTAssertLessThan(AlertSample.meters, AlertSample.alertRadius)
        XCTAssertGreaterThan(AlertSample.meters, 0)
        XCTAssertGreaterThan(AppConfig.alertSampleSeconds, 2)
    }
}
