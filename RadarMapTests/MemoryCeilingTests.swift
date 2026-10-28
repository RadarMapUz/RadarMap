//
//  MemoryCeilingTests.swift
//  RadarMapTests
//
//  Потолок памяти в поездке (36A): чистка выше потолка и не чаще интервала —
//  иначе рабочий набор выше потолка перечитывал бы тайлы с диска на каждой
//  проверке. Повод «фон» не отдаёт то, что нужно видимому экрану машины.
//

import XCTest
@testable import RadarMap

final class MemoryCeilingTests: XCTestCase {
    private let ceiling: UInt64 = 200 * 1024 * 1024

    func testBelowCeilingNeverTrims() {
        XCTAssertFalse(MemoryPressure.shouldTrim(footprint: ceiling - 1, ceiling: ceiling, lastTrim: nil, now: 0))
        XCTAssertFalse(MemoryPressure.shouldTrim(footprint: ceiling, ceiling: ceiling, lastTrim: nil, now: 0))
    }

    func testAboveCeilingTrimsOnceAndThenWaits() {
        let over = ceiling + 50 * 1024 * 1024
        XCTAssertTrue(MemoryPressure.shouldTrim(footprint: over, ceiling: ceiling, lastTrim: nil, now: 100))
        XCTAssertFalse(MemoryPressure.shouldTrim(footprint: over, ceiling: ceiling, lastTrim: 100,
                                                 now: 100 + AppConfig.engineMemoryCheckSeconds),
                       "следующая проверка через 15 с — рано")
        XCTAssertTrue(MemoryPressure.shouldTrim(footprint: over, ceiling: ceiling, lastTrim: 100,
                                                now: 100 + AppConfig.engineMemoryTrimIntervalSeconds))
    }

    func testIntervalIsLongerThanTheCheck() {
        XCTAssertGreaterThan(AppConfig.engineMemoryTrimIntervalSeconds, AppConfig.engineMemoryCheckSeconds * 4)
    }

    /// Уход телефона в фон — не тесная память: книги поиска машины остаются.
    func testBackgroundIsNotTight() {
        XCTAssertFalse(MemoryPressure.Reason.background.isTight)
        XCTAssertTrue(MemoryPressure.Reason.warning.isTight)
        XCTAssertTrue(MemoryPressure.Reason.ceiling.isTight)
    }

    func testFootprintIsReadable() {
        let bytes = MemoryPressure.footprintBytes()
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1024 * 1024)
    }
}
