//
//  WidgetCommuteTests.swift
//  RadarMapTests
//
//  Виджет «Дорога на работу» (9.4): утром — на работу, с 14:00 — домой;
//  «выезжайте до» — только в день срока и до него; потом — совет окна или
//  обычный выезд; данные старше месяца — не «обычно».
//

import XCTest
@testable import RadarMap

final class WidgetCommuteTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Вторник, 20 октября 2026.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Обычно 42 мин, выезд около 8:20, окно 7:45 — 36 мин; домой 39 мин, около 18:30.
    private func data(leaveBy: Date? = nil, updated: Date? = nil) -> CommuteWidgetData {
        let work = CommuteWidgetData.Direction(usualSeconds: 2520, usualDepartureMinute: 500,
                                               bestStartMinute: 465, bestSeconds: 2160, leaveBy: leaveBy)
        let home = CommuteWidgetData.Direction(usualSeconds: 2340, usualDepartureMinute: 1110)
        let stamp: Date = updated ?? at(7)
        return CommuteWidgetData(toWork: work, toHome: home, updatedAt: stamp)
    }

    func testMorningIsWorkEveningIsHome() throws {
        XCTAssertEqual(try XCTUnwrap(WidgetCommute.line(data(), now: at(7), calendar: utc)).toWork, true)
        let evening = try XCTUnwrap(WidgetCommute.line(data(), now: at(17), calendar: utc))
        XCTAssertFalse(evening.toWork)
        XCTAssertEqual(evening.usualSeconds, 2340)
        XCTAssertEqual(evening.hint, .usualDeparture(minute: 1110))
    }

    /// «Выезжайте до 8:10» — только в день срока и до этого времени; после —
    /// совет окна, если оно ещё впереди, иначе обычный выезд.
    func testLeaveByOnlyOnItsDayAndBeforeIt() throws {
        let leave = at(8, 10)
        XCTAssertEqual(WidgetCommute.line(data(leaveBy: leave), now: at(7), calendar: utc)?.hint,
                       .leaveBy(minute: 490))
        XCTAssertEqual(WidgetCommute.line(data(leaveBy: leave), now: at(8, 30), calendar: utc)?.hint,
                       .usualDeparture(minute: 500), "срок прошёл, окно 7:45 тоже")
        XCTAssertEqual(WidgetCommute.line(data(leaveBy: at(8, 10, day: 21)), now: at(7), calendar: utc)?.hint,
                       .best(minute: 465, seconds: 2160), "срок завтра — сегодня совет окна")
    }

    func testOldOrMissingDataIsNoLine() {
        XCTAssertNil(WidgetCommute.line(nil, now: at(7), calendar: utc))
        XCTAssertNil(WidgetCommute.line(data(updated: at(7).addingTimeInterval(-31 * 86_400)), now: at(7),
                                        calendar: utc), "старше месяца — не «обычно»")
        let onlyHome = CommuteWidgetData(toWork: nil, toHome: CommuteWidgetData.Direction(usualSeconds: 2340),
                                         updatedAt: at(7))
        XCTAssertEqual(WidgetCommute.line(onlyHome, now: at(7), calendar: utc)?.toWork, false,
                       "утром без дороги на работу — показываем ту, что есть")
    }

    /// Перерисовка — на минуте подсказки, в 14:00 и в полночь, без часовых тиков.
    func testRefreshAtTheNextMeaningfulMinute() {
        let next = WidgetCommute.nextRefresh(after: at(7), data: data(leaveBy: at(8, 10)), calendar: utc)
        XCTAssertEqual(next, at(7, 46), "сразу после окна-совета 7:45")
        let afternoon = WidgetCommute.nextRefresh(after: at(9), data: data(), calendar: utc)
        XCTAssertEqual(afternoon, at(14), "к вечерней дороге")
    }

    func testSameNumbersIgnoresTimestamp() {
        XCTAssertTrue(WidgetCommute.sameNumbers(data(updated: at(7)), data(updated: at(9))))
        XCTAssertFalse(WidgetCommute.sameNumbers(data(), nil))
        XCTAssertTrue(WidgetCommute.sameNumbers(nil, nil))
    }
}
