//
//  CarPlayCameraTests.swift
//  RadarMapTests
//
//  Динамическая камера в машине: стоя — близко и сверху, на скорости —
//  дальше и с наклоном, у развилки — снова сверху; ступенями, без дрожи.
//

import XCTest
@testable import RadarMap

final class CarPlayCameraTests: XCTestCase {

    func testStandingAndCityAreTopDownAndClose() {
        let stopped = CarPlayCamera.frame(speedKmh: 0, maneuverDistance: nil)
        XCTAssertEqual(stopped.pitchDegrees, 0, "стоя — строго сверху")
        XCTAssertLessThanOrEqual(stopped.spanMeters, 240, "видны полосы и разметка")
        XCTAssertEqual(CarPlayCamera.frame(speedKmh: 15, maneuverDistance: nil).pitchDegrees, 0)
    }

    func testFasterMeansFartherTiltedAndLower() {
        let city = CarPlayCamera.frame(speedKmh: 50, maneuverDistance: nil)
        let highway = CarPlayCamera.frame(speedKmh: 110, maneuverDistance: nil)
        XCTAssertGreaterThan(highway.spanMeters, city.spanMeters * 1.8)
        XCTAssertGreaterThan(highway.pitchDegrees, city.pitchDegrees)
        XCTAssertGreaterThan(highway.carShare, city.carShare, "на трассе машина ниже на экране")
        XCTAssertLessThanOrEqual(highway.pitchDegrees, 45)
    }

    func testMonotonicWithSpeed() {
        var previous = CarPlayCamera.frame(speedKmh: 0, maneuverDistance: nil)
        for v in stride(from: 5.0, through: 160, by: 5) {
            let frame = CarPlayCamera.frame(speedKmh: v, maneuverDistance: nil)
            XCTAssertGreaterThanOrEqual(frame.spanMeters, previous.spanMeters, "охват на \(v)")
            XCTAssertGreaterThanOrEqual(frame.pitchDegrees, previous.pitchDegrees, "наклон на \(v)")
            previous = frame
        }
    }

    func testManeuverPullsToTopDownJunction() {
        let cruising = CarPlayCamera.frame(speedKmh: 90, maneuverDistance: nil)
        let atTurn = CarPlayCamera.frame(speedKmh: 90, maneuverDistance: 20)
        XCTAssertLessThan(atTurn.spanMeters, cruising.spanMeters / 2)
        XCTAssertEqual(atTurn.pitchDegrees, 0, "развилку видно сверху")
        let halfway = CarPlayCamera.frame(speedKmh: 90, maneuverDistance: 250)
        XCTAssertTrue(atTurn.spanMeters < halfway.spanMeters && halfway.spanMeters < cruising.spanMeters,
                      "стягивается плавно, а не прыжком")
        XCTAssertEqual(CarPlayCamera.frame(speedKmh: 90, maneuverDistance: 900), cruising,
                       "дальний манёвр вид не трогает")
    }

    /// Ступени: дрожь скорости на 1 км/ч не двигает камеру.
    func testSmallSpeedJitterKeepsTheFrame() {
        XCTAssertEqual(CarPlayCamera.frame(speedKmh: 47, maneuverDistance: nil),
                       CarPlayCamera.frame(speedKmh: 48, maneuverDistance: nil))
    }
}
