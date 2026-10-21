//
//  ArrivalTailTests.swift
//  RadarMapTests
//
//  Прибытие на последних километрах (25.F): не оптимистичнее нашей средней
//  скорости за ~2 минуты — и никогда не раньше, чем обещает движок.
//

import XCTest
@testable import RadarMap

final class ArrivalTailTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pace(_ points: [(TimeInterval, Double)]) -> ArrivalTail.Pace {
        var pace = ArrivalTail.Pace()
        for (offset, kmh) in points { pace.add(speedKmh: kmh, at: t0.addingTimeInterval(offset)) }
        return pace
    }

    // MARK: - Средняя скорость

    func testAverageIsTimeWeightedAndCountsTheStopAtTheLight() throws {
        // Минута на 36 км/ч (10 м/с), затем минута стоим — фиксов на стоянке нет.
        let p = pace([(0, 36), (30, 36), (60, 0)])
        let average = try XCTUnwrap(p.average(now: t0.addingTimeInterval(120)))
        XCTAssertEqual(average, 5, accuracy: 0.01, "600 м за 120 с — стоянка в средней, хоть фиксов и не было")
    }

    func testOnlyTheLastTwoMinutesCount() throws {
        // Пять минут на 72 км/ч, последние две — 18 км/ч.
        var points: [(TimeInterval, Double)] = stride(from: 0, through: 180, by: 10).map { ($0, 72) }
        points += stride(from: 181, through: 300, by: 10).map { ($0, 18) }
        let average = try XCTUnwrap(pace(points).average(now: t0.addingTimeInterval(300)))
        XCTAssertEqual(average * 3.6, 18, accuracy: 0.8)
    }

    func testTooShortObservationIsNoPace() {
        XCTAssertNil(pace([(0, 30), (10, 30)]).average(now: t0.addingTimeInterval(20)))
        XCTAssertNil(ArrivalTail.Pace().average(now: t0))
    }

    // MARK: - Остаток

    func testFarFromTheEndEngineTimeStands() {
        XCTAssertEqual(ArrivalTail.remaining(engine: 300, remainingMeters: 5000, paceMps: 1), 300)
        XCTAssertEqual(ArrivalTail.remaining(engine: 300, remainingMeters: 2000, paceMps: 1), 300,
                       "на самой границе вес нулевой — прибытие не прыгает")
    }

    /// Снимок 63: 0,7 км, едем ~20 км/ч в среднем — движок обещает минуту,
    /// честно — две с лишним.
    func testLastKilometreIsNotFasterThanOurPace() {
        let engine: TimeInterval = 50
        let result = ArrivalTail.remaining(engine: engine, remainingMeters: 700, paceMps: 20 / 3.6)
        XCTAssertEqual(result, 700 / (20 / 3.6), accuracy: 0.5)
        XCTAssertGreaterThan(result, engine)
    }

    func testNeverEarlierThanTheEngine() {
        // Едем быстрее, чем считает граф, — прибытие не сдвигаем раньше.
        XCTAssertEqual(ArrivalTail.remaining(engine: 120, remainingMeters: 800, paceMps: 60 / 3.6), 120)
        // Темпа нет (только тронулись) — время движка.
        XCTAssertEqual(ArrivalTail.remaining(engine: 120, remainingMeters: 800, paceMps: nil), 120)
    }

    func testBlendGrowsSmoothlyBetweenTwoAndOneKilometre() {
        let pace = 20 / 3.6   // выше пола в 12 км/ч — считается сама средняя
        let a = ArrivalTail.remaining(engine: 100, remainingMeters: 1900, paceMps: pace)
        let b = ArrivalTail.remaining(engine: 100, remainingMeters: 1500, paceMps: pace)
        let c = ArrivalTail.remaining(engine: 100, remainingMeters: 1000, paceMps: pace)
        XCTAssertGreaterThan(a, 100)
        XCTAssertEqual(b, 100 + (1500 / pace - 100) * 0.5, accuracy: 0.5)
        XCTAssertEqual(c, 1000 / pace, accuracy: 0.5)
    }

    func testJamDoesNotTurnTheTailIntoAnHour() {
        // Две минуты стоим — средняя ~0; пол 12 км/ч держит 1 км в 5 минутах.
        let result = ArrivalTail.remaining(engine: 60, remainingMeters: 1000, paceMps: 0)
        XCTAssertEqual(result, 1000 / (AppConfig.arrivalTailPaceFloorKmh / 3.6), accuracy: 0.5)
    }
}
