//
//  CommuteChartAxisTests.swift
//  RadarMapTests
//
//  Ось графика выездов (34): выбросы не растягивают ось, подписи не слипаются,
//  окно-совет всегда на оси, разброс — не выброс.
//

import XCTest
@testable import RadarMap

final class CommuteChartAxisTests: XCTestCase {

    private func m(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

    /// Снимок владельца: сорок вечерних выездов 18:00–18:40 и два в 11:30 —
    /// ось была 11:30–18:30 с подписью каждые полчаса.
    func testOutliersDoNotStretchAxis() {
        var departures = (0..<40).map { m(18) + $0 % 40 }
        departures += [m(11, 32), m(11, 48)]
        let layout = CommuteChartAxis.layout(departures: departures)
        XCTAssertEqual(layout.domain.lowerBound, m(18))
        XCTAssertLessThanOrEqual(layout.domain.upperBound, m(19))
        XCTAssertEqual(layout.outside, [40, 41])
    }

    func testLabelsNeverExceedLimit() {
        let cases: [[Int]] = [
            [m(7), m(7, 20), m(8, 10)],
            [m(6), m(8), m(9), m(10)],
            [m(5), m(9), m(13), m(17), m(21)],
        ]
        for departures in cases {
            let layout = CommuteChartAxis.layout(departures: departures, maxLabels: 5)
            let labels = (layout.domain.upperBound - layout.domain.lowerBound) / layout.stride + 1
            XCTAssertLessThanOrEqual(labels, 5, "\(departures)")
            XCTAssertEqual(layout.domain.lowerBound % layout.stride, 0)
            XCTAssertEqual(layout.domain.upperBound % layout.stride, 0)
        }
    }

    /// Выезды и правда разбросаны (меньше половины рядом с медианой) — это
    /// не выбросы: ось по всем, никто не прячется.
    func testSpreadIsNotOutliers() {
        let departures = [m(6), m(9), m(12), m(15), m(18)]
        let layout = CommuteChartAxis.layout(departures: departures)
        XCTAssertTrue(layout.outside.isEmpty)
        XCTAssertTrue(layout.domain.contains(m(6)) && layout.domain.contains(m(18)))
    }

    func testAdviceWindowAlwaysOnAxis() {
        let departures = [m(8, 20), m(8, 25), m(8, 30), m(8, 35)]
        let layout = CommuteChartAxis.layout(departures: departures, window: m(7, 30)...m(7, 45))
        XCTAssertLessThanOrEqual(layout.domain.lowerBound, m(7, 30))
        XCTAssertGreaterThanOrEqual(layout.domain.upperBound, m(8, 35))
    }

    func testNarrowClusterKeepsHalfHourStep() {
        let layout = CommuteChartAxis.layout(departures: [m(18, 5), m(18, 10), m(18, 20)])
        XCTAssertEqual(layout.stride, 30)
        XCTAssertEqual(layout.domain, m(18)...m(18, 30))
    }

    func testEmptyIsSafe() {
        let layout = CommuteChartAxis.layout(departures: [])
        XCTAssertTrue(layout.outside.isEmpty)
        XCTAssertGreaterThan(layout.domain.upperBound, layout.domain.lowerBound)
    }
}
