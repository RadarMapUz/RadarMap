//
//  FineCheckTests.swift
//  RadarMapTests
//
//  «Проверить штрафы» (12б.8): номер распознаётся в любом наборе
//  (кириллица-двойник, пробелы, дефисы), чужое не принимается; оценка за
//  30 дней — по дневным сводкам и ровно за 30 календарных дней.
//

import XCTest
@testable import RadarMap

final class FineCheckTests: XCTestCase {
    func testPlateNormalization() {
        XCTAssertEqual(FineCheck.normalizedPlate("01 A 123 BC"), "01A123BC")
        XCTAssertEqual(FineCheck.normalizedPlate("01а123вс"), "01A123BC", "кириллица-двойник и строчные")
        XCTAssertEqual(FineCheck.normalizedPlate("10-777-ABC"), "10777ABC", "номер юрлица")
        XCTAssertNil(FineCheck.normalizedPlate("01 Б 123 ВС"), "Б латиницей не бывает")
        XCTAssertNil(FineCheck.normalizedPlate("A123BC"), "без региона")
        XCTAssertNil(FineCheck.normalizedPlate("01 A 12 BC"))
        XCTAssertNil(FineCheck.normalizedPlate(""))
        XCTAssertNil(FineCheck.normalizedPlate("01 A 123 BC 5"))
    }

    func testPlateDisplay() {
        XCTAssertEqual(FineCheck.displayPlate("01A123BC"), "01 A 123 BC")
        XCTAssertEqual(FineCheck.displayPlate("10777ABC"), "10 777 ABC")
    }

    func testEstimateCoversExactlyThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, risk: Double) -> TripDay {
            var value = TripDay(day: calendar.date(byAdding: .day, value: offset, to: today)!)
            value.fineRisk = risk
            return value
        }
        let days = [day(0, risk: 250_000), day(-29, risk: 375_000), day(-30, risk: 1_000_000)]
        XCTAssertEqual(FineCheck.estimate(days: days, now: now, calendar: calendar), 625_000,
                       "сегодня и 29 дней назад — в окне, 30 дней назад — уже нет")
        XCTAssertEqual(FineCheck.estimate(days: [], now: now, calendar: calendar), 0)
    }
}
