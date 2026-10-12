//
//  DrivingDeclutterTests.swift
//  RadarMapTests
//
//  На ходу — только дорога; встали надолго — окрестность возвращается; на
//  светофоре и в пробке карта слоями не мигает.
//

import XCTest
@testable import RadarMap

final class DrivingDeclutterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    func testStartsCalmWhileStanding() {
        var d = DrivingDeclutter()
        XCTAssertFalse(d.update(speedKmh: 0, at: t0), "на стоянке видно всё")
    }

    func testHidesOnTheMove() {
        var d = DrivingDeclutter()
        XCTAssertTrue(d.update(speedKmh: 40, at: t0))
    }

    func testShortStopKeepsTheRoadOnly() {
        // Светофор: две секунды стоя — слои не возвращаются.
        var d = DrivingDeclutter()
        d.update(speedKmh: 40, at: t0)
        XCTAssertTrue(d.update(speedKmh: 0, at: t0 + 1))
        XCTAssertTrue(d.update(speedKmh: 0, at: t0 + 3))
        XCTAssertFalse(d.update(speedKmh: 0, at: t0 + 1 + DrivingDeclutter.showAfter),
                       "постояли — окрестность снова видна")
    }

    func testCrawlInTrafficDoesNotFlicker() {
        // Пробка: 5–10 км/ч то и дело — между порогами ничего не меняется.
        var d = DrivingDeclutter()
        d.update(speedKmh: 40, at: t0)
        for (i, speed) in [8.0, 6, 10, 7, 9, 5].enumerated() {
            XCTAssertTrue(d.update(speedKmh: speed, at: t0 + Double(i * 3)), "\(speed) км/ч")
        }
        // Ползли и встали — отсчёт стоянки начинается с остановки.
        XCTAssertTrue(d.update(speedKmh: 0, at: t0 + 30))
        XCTAssertFalse(d.update(speedKmh: 0, at: t0 + 30 + DrivingDeclutter.showAfter))
    }

    func testMovingOffAgainHidesAtOnce() {
        var d = DrivingDeclutter()
        d.update(speedKmh: 40, at: t0)
        d.update(speedKmh: 0, at: t0 + 1)
        d.update(speedKmh: 0, at: t0 + 10)
        XCTAssertTrue(d.update(speedKmh: 15, at: t0 + 11))
    }

    func testBrokenSpeedIsStanding() {
        var d = DrivingDeclutter()
        XCTAssertFalse(d.update(speedKmh: .nan, at: t0))
        XCTAssertFalse(d.update(speedKmh: -1, at: t0))
    }
}
