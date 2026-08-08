//
//  TickPacingTests.swift
//  RadarMapTests
//
//  Ритм анимации следования: длительность = прошлому интервалу фиксов,
//  зажатому в [0.35, 3.0]. Свой файл — раньше четыре ассерта жили внутри
//  RoadSketchTests и грепом по имени не находились.
//

import XCTest
@testable import RadarMap

final class TickPacingTests: XCTestCase {

    /// Первый тик без истории — секунда: лучшее слепое предсказание.
    func testNoHistoryDefaultsToOneSecond() {
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: nil), 1)
    }

    /// Ритм следует за реальным интервалом фиксов — не за константой.
    func testFollowsRealInterval() {
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 0.8), 0.8)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 2.2), 2.2)
    }

    /// Границы зажима — РОВНО 0.35 и 3.0: дрожание GPS не делает анимацию
    /// дёрганой, а провал фиксов — вечной.
    func testClampBoundsExactly() {
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 0.1), 0.35)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 0.35), 0.35)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 3.0), 3.0)
        XCTAssertEqual(TickPacing.animationDuration(sincePreviousTick: 30), 3.0)
    }
}
