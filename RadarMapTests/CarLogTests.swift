//
//  CarLogTests.swift
//  RadarMapTests
//
//  Автодневник за переключателем «Машина и расходы» (план 78): выключенный
//  прячет всё, кроме включённого режима водителя; перенос включает дневник
//  тем, у кого есть записи, и не решает «нет», пока журнал не прочитан.
//

import XCTest
@testable import RadarMap

final class CarLogTests: XCTestCase {

    func testEnabledShowsEverySurface() {
        let state = CarLog.State(enabled: true)
        for surface in CarLog.Surface.allCases {
            XCTAssertTrue(CarLog.shows(surface, state), "\(surface)")
        }
    }

    func testDisabledHidesEverySurface() {
        let state = CarLog.State(enabled: false)
        for surface in CarLog.Surface.allCases {
            XCTAssertFalse(CarLog.shows(surface, state), "\(surface)")
        }
    }

    /// Включённый режим водителя не прячется: иначе его не выключить.
    func testActiveWorkDriverStaysReachable() {
        let state = CarLog.State(enabled: false, workDriver: true)
        XCTAssertTrue(CarLog.shows(.workDriver, state))
        XCTAssertTrue(CarLog.shows(.shifts, state))
        for surface in [CarLog.Surface.expenses, .journal, .maintenance, .export] {
            XCTAssertFalse(CarLog.shows(surface, state), "\(surface)")
        }
    }

    /// Новая установка: журнал прочитан и пуст, записей нет — выключен.
    func testFreshInstallStaysOff() {
        XCTAssertEqual(CarLog.migrated(CarLog.Records(journalLoaded: true)), false)
    }

    /// Пустота до чтения журнала — не ответ: решение ждёт.
    func testWaitsForJournalBeforeSayingNo() {
        XCTAssertNil(CarLog.migrated(CarLog.Records()))
    }

    /// Любая запись включает сразу, даже до чтения журнала.
    func testAnyRecordTurnsItOn() {
        let cases = [CarLog.Records(journalEntries: 1, journalLoaded: true),
                     CarLog.Records(workShifts: 2),
                     CarLog.Records(workDriver: true),
                     CarLog.Records(maintenanceFilled: true),
                     CarLog.Records(fuelProfileFilled: true)]
        for records in cases {
            XCTAssertEqual(CarLog.migrated(records), true, "\(records)")
        }
    }
}
