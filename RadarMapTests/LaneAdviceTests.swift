//
//  LaneAdviceTests.swift
//  RadarMapTests
//
//  Ряд полос словами: говорим только однозначное.
//

import XCTest
@testable import RadarMap

final class LaneAdviceTests: XCTestCase {

    private func row(_ pattern: String) -> [LaneHint] {
        pattern.map { LaneHint(arrows: [.straight], isValid: $0 == "+") }
    }

    func testRunsFromTheLeftEdge() {
        XCTAssertEqual(LaneAdvice.phrase(row("+---")), String(localized: "Из левого ряда"))
        XCTAssertEqual(LaneAdvice.phrase(row("++--")), String(localized: "Из двух левых рядов"))
        XCTAssertEqual(LaneAdvice.phrase(row("+++--")), String(localized: "Из трёх левых рядов"))
        XCTAssertEqual(LaneAdvice.phrase(row("++++---")), String(localized: "Из левых рядов"))
    }

    func testRunsFromTheRightEdge() {
        XCTAssertEqual(LaneAdvice.phrase(row("---+")), String(localized: "Из правого ряда"))
        XCTAssertEqual(LaneAdvice.phrase(row("--++")), String(localized: "Из двух правых рядов"))
    }

    func testAllButOneEdgeSaysWhichToAvoid() {
        XCTAssertEqual(LaneAdvice.phrase(row("+++-")), String(localized: "Из любого ряда, кроме правого"))
        XCTAssertEqual(LaneAdvice.phrase(row("-+++")), String(localized: "Из любого ряда, кроме левого"))
        XCTAssertEqual(LaneAdvice.phrase(row("+-")), String(localized: "Из левого ряда"),
                       "из двух полос «кроме правого» — это просто левый")
    }

    func testMiddle() {
        XCTAssertEqual(LaneAdvice.phrase(row("-+-")), String(localized: "Из среднего ряда"))
        XCTAssertEqual(LaneAdvice.phrase(row("-++--")), String(localized: "Из средних рядов"))
    }

    func testNothingToSay() {
        XCTAssertNil(LaneAdvice.phrase(row("++++")), "подходят все — подсказка пустая")
        XCTAssertNil(LaneAdvice.phrase(row("----")))
        XCTAssertNil(LaneAdvice.phrase(row("+-+-")), "разрозненные — только стрелки")
        XCTAssertNil(LaneAdvice.phrase(row("+")))
        XCTAssertNil(LaneAdvice.phrase([]))
    }

    func testHighwayShowsTheRowEarlier() {
        XCTAssertEqual(LaneAdvice.showDistance(speedKmh: 40), AppConfig.engineManeuverApproachMeters)
        XCTAssertEqual(LaneAdvice.showDistance(speedKmh: 90), AppConfig.laneRowHighwayMeters)
        XCTAssertGreaterThan(AppConfig.laneRowHighwayMeters, AppConfig.engineManeuverApproachMeters)
    }
}
