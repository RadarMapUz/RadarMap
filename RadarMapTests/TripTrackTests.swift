//
//  TripTrackTests.swift
//  RadarMapTests
//
//  Упрощение трека поездки (Дуглас-Пекер) и упаковка в запись.
//

import XCTest
@testable import RadarMap

final class TripTrackTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double, speed: Double = 60) -> TrackPoint {
        TrackPoint(lat: lat, lon: lon, speedKmh: speed)
    }

    func testSimplifyDropsCollinearPoints() {
        // Прямая из 100 точек — должны остаться только концы.
        let straight = (0..<100).map { point(41.30, 69.20 + Double($0) * 0.001) }
        let simplified = TripStats.simplify(straight, tolerance: 0.0002, maxPoints: 400)
        XCTAssertEqual(simplified.count, 2)
        XCTAssertEqual(simplified.first?.lon, 69.20)
        XCTAssertEqual(simplified.last?.lon ?? 0, 69.299, accuracy: 0.0001)
    }

    func testSimplifyKeepsCorner() {
        // Угол 90°: точка поворота обязана выжить.
        let leg1 = (0..<50).map { point(41.30, 69.20 + Double($0) * 0.001) }
        let leg2 = (1..<50).map { point(41.30 + Double($0) * 0.001, 69.249) }
        let simplified = TripStats.simplify(leg1 + leg2, tolerance: 0.0002, maxPoints: 400)
        XCTAssertTrue(simplified.contains {
            abs($0.lat - 41.30) < 0.0005 && abs($0.lon - 69.249) < 0.0005
        }, "вершина угла потеряна")
        XCTAssertLessThan(simplified.count, 10)
    }

    func testSimplifyRespectsMaxPoints() {
        // Зигзаг, который DP не сожмёт — сработает потолок точек.
        let zigzag = (0..<1000).map {
            point(41.30 + ($0 % 2 == 0 ? 0 : 0.01), 69.20 + Double($0) * 0.001)
        }
        let simplified = TripStats.simplify(zigzag, tolerance: 0.0002, maxPoints: 120)
        XCTAssertEqual(simplified.count, 120)
        XCTAssertEqual(simplified.first?.lon, 69.20)
    }

    func testTrackRoundTripThroughRecord() {
        let record = TripRecord(
            id: 1, startedAt: Date(), endedAt: Date().addingTimeInterval(600),
            distanceMeters: 5000, maxSpeedKmh: 90,
            passed: [], endLat: nil, endLon: nil,
            track: [41.3, 69.2, 60.0, 41.31, 69.21, 72.5, 41.32, 69.22, 55.0])
        let points = record.trackPoints
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[1].speedKmh, 72.5)
        XCTAssertEqual(points[2].lat, 41.32)
    }

    // MARK: - Заряд за поездку

    func testBatteryDropIsStartMinusEnd() {
        XCTAssertEqual(TripStats.batteryDrop(startPercent: 80, endPercent: 74), 6)
        // Ноль — валидный и лучший ответ: поездка не стоила ни процента.
        XCTAssertEqual(TripStats.batteryDrop(startPercent: 80, endPercent: 80), 0)
    }

    /// Заряжались в пути (конец выше старта) или заряд не читался — дельты нет:
    /// фиктивная «экономия» хуже отсутствия цифры.
    func testBatteryDropRefusesChargingAndUnknown() {
        XCTAssertNil(TripStats.batteryDrop(startPercent: 60, endPercent: 75))
        XCTAssertNil(TripStats.batteryDrop(startPercent: nil, endPercent: 75))
        XCTAssertNil(TripStats.batteryDrop(startPercent: 60, endPercent: nil))
    }

    /// Склейка: «заряд на старте» = текущий + расход первой ноги, тогда финальная
    /// дельта суммирует обе ноги. Расход первой ноги неизвестен — вся дельта
    /// неизвестна: «−2 %» за поездку, стоившую пять, хуже молчания.
    func testResumedStartPercentAccumulatesLegs() {
        XCTAssertEqual(TripStats.resumedStartPercent(previousDrop: 4, currentPercent: 70), 74)
        XCTAssertNil(TripStats.resumedStartPercent(previousDrop: nil, currentPercent: 70))
        XCTAssertNil(TripStats.resumedStartPercent(previousDrop: 4, currentPercent: nil))
        // Сквозной сценарий: нога 1 съела 4 %, нога 2 — ещё 3 %.
        let start = TripStats.resumedStartPercent(previousDrop: 4, currentPercent: 70)
        XCTAssertEqual(TripStats.batteryDrop(startPercent: start, endPercent: 67), 7)
    }
}
