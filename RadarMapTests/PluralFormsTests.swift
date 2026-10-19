//
//  PluralFormsTests.swift
//  RadarMapTests
//
//  Формы числа берёт каталог (6.11) — но только если строка передаёт число
//  интерполяцией: `String(format:)` с той же строкой молча оставляет
//  «1 поездок». Тест ловит обе ошибки — пропавшую вариацию в каталоге и
//  вызов мимо неё.
//

import XCTest
@testable import RadarMap

final class PluralFormsTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(Bundle.main.preferredLocalizations.first == "ru",
                          "формы проверяются на русском каталоге")
    }

    func testTripsDaysPoints() {
        XCTAssertEqual(String(localized: "\(1) поездок"), "1 поездка")
        XCTAssertEqual(String(localized: "\(3) поездок"), "3 поездки")
        XCTAssertEqual(String(localized: "\(5) поездок"), "5 поездок")
        XCTAssertEqual(String(localized: "\(21) дней"), "21 день")
        XCTAssertEqual(String(localized: "\(2) баллов"), "2 балла")
    }

    func testBackupSummaryAgreesWithItsNumbers() {
        let backup = TripBackup(history: [], days: [])
        XCTAssertEqual(backup.summary, "0 поездок · 0 дней")
    }

    func testBaselineTitleOneWeek() {
        XCTAssertEqual(StatsPeriod.week.baselineTitle(periods: 21), "по 21 прошлой неделе")
        XCTAssertEqual(StatsPeriod.week.baselineTitle(periods: 4), "по 4 прошлым неделям")
    }
}
