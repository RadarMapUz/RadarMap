//
//  CarPlayTripSummaryTests.swift
//  RadarMapTests
//
//  Итог поездки в машине: главное — первой строкой, короткие варианты есть
//  всегда, рейтинга нет — его и не выдумываем.
//

import XCTest
@testable import RadarMap

final class CarPlayTripSummaryTests: XCTestCase {

    private func record(minutes: Double, km: Double, score: Double?) -> TripRecord {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var record = TripRecord(id: 1, startedAt: start, endedAt: start + minutes * 60,
                                distanceMeters: km * 1000, maxSpeedKmh: 70, passed: [])
        record.score = score
        return record
    }

    func testFullLineCarriesTheNumbers() {
        let lines = CarPlayTripSummary.lines(for: record(minutes: 25, km: 12.4, score: 95.6))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains(Formatting.duration(25 * 60)), lines[0])
        XCTAssertTrue(lines[0].contains(Formatting.distance(12_400)), lines[0])
        XCTAssertTrue(lines[0].contains(String(format: String(localized: "рейтинг %lld"), 96)), lines[0])
        XCTAssertEqual(lines.last, String(localized: "Поездка сохранена"))
    }

    func testNoScoreNoRating() {
        let lines = CarPlayTripSummary.lines(for: record(minutes: 5, km: 1.2, score: nil))
        XCTAssertFalse(lines[0].contains(String(format: String(localized: "рейтинг %lld"), 0)))
        XCTAssertFalse(lines.contains { $0.isEmpty })
    }
}
