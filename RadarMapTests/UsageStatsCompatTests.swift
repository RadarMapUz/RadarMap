//
//  UsageStatsCompatTests.swift
//  RadarMapTests
//
//  Файл счётчиков старой сборки (без полей, добавленных позже) читается, а
//  не выбрасывается целиком (сценарий S16, правило 18).
//

import XCTest
@testable import RadarMap

final class UsageStatsCompatTests: XCTestCase {
    func testOldFileWithoutNewFieldsIsRead() throws {
        let old = #"{"day":"2026-09-01","onboarded":true,"locationAuth":"always","notificationsAllowed":true,"trips":3,"kilometres":41.5,"alerts":12,"passes":9,"reports":1,"screens":{"map":4},"maneuvers":{},"tripsDropped":{}}"#
        let stats = try JSONDecoder().decode(UsageStats.self, from: Data(old.utf8))
        XCTAssertEqual(stats.trips, 3)
        XCTAssertEqual(stats.kilometres, 41.5)
        XCTAssertTrue(stats.limitSource.isEmpty, "нет поля — по умолчанию")
        XCTAssertEqual(stats.memoryWarnings, 0)
        // И обратно: новые поля пишутся, и прочитанное совпадает.
        let again = try JSONDecoder().decode(UsageStats.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(again, stats)
    }
}
