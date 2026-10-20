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

    // MARK: - 12б.2: «сейчас ~N», пробки, место, фон

    /// Окно ±90 мин от обычного выезда 8:20 по 15 минут: сегодня — только
    /// будущие окна, после окна — завтрашнее целиком.
    func testSlotStartsCoverNextDepartureWindow() {
        let morning = WidgetCommute.slotStarts(usualDepartureMinute: 500, now: at(6), calendar: utc)
        XCTAssertEqual(morning.first, at(6, 50))
        XCTAssertEqual(morning.last, at(9, 35))
        XCTAssertEqual(morning.count, 12, "180 мин / 15")
        let during = WidgetCommute.slotStarts(usualDepartureMinute: 500, now: at(8, 0), calendar: utc)
        XCTAssertEqual(during.first, at(7, 50), "окно, в котором «сейчас», остаётся")
        let after = WidgetCommute.slotStarts(usualDepartureMinute: 500, now: at(10), calendar: utc)
        XCTAssertEqual(after.first, at(6, 50, day: 21), "окно прошло — пишем завтрашнее")
        XCTAssertEqual(after.count, 12)
    }

    func testNowEstimateFromTheCoveringSlot() throws {
        var value = data()
        value.toWork?.slots = [CommuteWidgetData.Slot(start: at(7, 45), seconds: 2160),
                               CommuteWidgetData.Slot(start: at(8, 0), seconds: 2700)]
        XCTAssertEqual(WidgetCommute.line(value, now: at(7, 50), calendar: utc)?.nowSeconds, 2160)
        XCTAssertEqual(WidgetCommute.line(value, now: at(8, 14), calendar: utc)?.nowSeconds, 2700)
        XCTAssertNil(WidgetCommute.line(value, now: at(8, 15), calendar: utc)?.nowSeconds,
                     "окна нет — «сейчас» не обещаем, остаётся «обычно»")
        XCTAssertNil(WidgetCommute.line(data(), now: at(7, 50), calendar: utc)?.nowSeconds,
                     "профиля нет — нет и обещания")
        let line = try XCTUnwrap(WidgetCommute.line(value, now: at(8, 14), calendar: utc))
        XCTAssertEqual(line.usualSeconds, 2520, "«обычно» никуда не девается")
    }

    func testJamLivesThirtyMinutes() {
        var value = data()
        value.toWork?.jam = CommuteWidgetData.Jam(extraSeconds: 480, at: at(7, 22))
        XCTAssertEqual(WidgetCommute.line(value, now: at(7, 40), calendar: utc)?.jam?.extraSeconds, 480)
        XCTAssertNil(WidgetCommute.line(value, now: at(7, 53), calendar: utc)?.jam, "старше 30 мин — не сегодняшние")
        value.toWork?.jam = CommuteWidgetData.Jam(extraSeconds: 30, at: at(7, 22))
        XCTAssertNil(WidgetCommute.line(value, now: at(7, 30), calendar: utc)?.jam, "меньше минуты — не строка")
    }

    func testDirectionFollowsLastPlace() {
        var value = data()
        value.lastPlace = .home
        value.lastPlaceAt = at(14, 30)
        XCTAssertEqual(WidgetCommute.line(value, now: at(15), calendar: utc)?.toWork, true,
                       "днём у дома — едем на работу (вторая смена), а не домой")
        value.lastPlace = .work
        value.lastPlaceAt = at(10)
        XCTAssertEqual(WidgetCommute.line(value, now: at(11), calendar: utc)?.toWork, false,
                       "утром на работе — дальше дорога домой")
        XCTAssertEqual(WidgetCommute.line(value, now: at(23), calendar: utc)?.toWork, false)
        XCTAssertEqual(WidgetCommute.line(value, now: at(7, day: 21), calendar: utc)?.toWork, true,
                       "отметка старше 12 ч — снова по часам")
    }

    /// Фоновый подъём в 14:30 поднимает процесс без GPS: позиции нет, и
    /// отметка «дома в 13:00» обязана дожить до записи — иначе виджет в 15:00
    /// показывал «Домой» человеку, который едет на вторую смену (ревью 14.1).
    func testPlaceMarkSurvivesUnknownPosition() throws {
        var stored = data()
        stored.lastPlace = .home
        stored.lastPlaceAt = at(13)
        let kept = try XCTUnwrap(WidgetCommute.placeMark(current: nil, positionKnown: false,
                                                         previous: stored, now: at(14, 30)))
        XCTAssertEqual(kept.place, .home)
        XCTAssertEqual(kept.at, at(13), "время — своё: 12 часов от 13:00, а не от подъёма")
        var next = data(updated: at(14, 30))
        next.lastPlace = kept.place
        next.lastPlaceAt = kept.at
        XCTAssertEqual(WidgetCommute.line(next, now: at(15), calendar: utc)?.toWork, true)
        XCTAssertTrue(WidgetCommute.sameNumbers(stored, next), "та же отметка — перезагрузки нет")

        XCTAssertNil(WidgetCommute.placeMark(current: nil, positionKnown: true, previous: stored, now: at(14, 30)),
                     "позиция известна и не у дома — отметки нет")
        XCTAssertEqual(WidgetCommute.placeMark(current: .work, positionKnown: true, previous: stored,
                                               now: at(14, 30))?.place, .work)
        XCTAssertNil(WidgetCommute.placeMark(current: nil, positionKnown: false, previous: stored,
                                             now: at(13).addingTimeInterval(13 * 3600)),
                     "старше 12 ч — не тащим")
        XCTAssertNil(WidgetCommute.placeMark(current: nil, positionKnown: false, previous: nil, now: at(14, 30)))
    }

    /// Пробки пересчитываются каждые 2 минуты — виджет не перезагружается,
    /// пока минуты те же и отметка не старее 10 минут.
    func testJamRecountDoesNotBurnReloads() {
        var a = data(), b = data()
        a.toWork?.jam = CommuteWidgetData.Jam(extraSeconds: 480, at: at(7, 22))
        b.toWork?.jam = CommuteWidgetData.Jam(extraSeconds: 480, at: at(7, 24))
        XCTAssertTrue(WidgetCommute.sameNumbers(a, b))
        b.toWork?.jam = CommuteWidgetData.Jam(extraSeconds: 540, at: at(7, 24))
        XCTAssertFalse(WidgetCommute.sameNumbers(a, b), "минуты сменились")
        b.toWork?.jam = CommuteWidgetData.Jam(extraSeconds: 480, at: at(7, 33))
        XCTAssertFalse(WidgetCommute.sameNumbers(a, b), "отметку пора освежить, иначе строка погаснет при пробках")
        b.toWork?.jam = nil
        XCTAssertFalse(WidgetCommute.sameNumbers(a, b))
    }

    func testTimelineHasAnEntryPerSlot() {
        var value = data()
        value.toWork?.slots = [CommuteWidgetData.Slot(start: at(7, 45), seconds: 2160),
                               CommuteWidgetData.Slot(start: at(8, 0), seconds: 2700)]
        let dates = WidgetCommute.entryDates(after: at(7, 30), data: value, calendar: utc)
        XCTAssertEqual(dates, [at(7, 30), at(7, 45)], "до перерисовки на минуте совета (7:46)")
    }

    func testBackgroundWakeBeforeUsualDeparture() {
        let lead: TimeInterval = 1800
        XCTAssertEqual(WidgetCommute.nextBackgroundRefresh(data: data(), now: at(6), lead: lead, calendar: utc),
                       at(7, 50), "за 30 мин до выезда 8:20")
        XCTAssertEqual(WidgetCommute.nextBackgroundRefresh(data: data(), now: at(9), lead: lead, calendar: utc),
                       at(18), "утро прошло — к вечерней дороге (18:30)")
        XCTAssertEqual(WidgetCommute.nextBackgroundRefresh(data: data(), now: at(19), lead: lead, calendar: utc),
                       at(7, 50, day: 21))
        XCTAssertNil(WidgetCommute.nextBackgroundRefresh(data: nil, now: at(6), lead: lead, calendar: utc))
    }

    /// Старый снимок (до 12б.2) читается: новые поля необязательны.
    func testOldSnapshotStillDecodes() throws {
        let old = #"{"toWork":{"usualSeconds":2520,"usualDepartureMinute":500},"updatedAt":0}"#
        let decoded = try JSONDecoder().decode(CommuteWidgetData.self, from: Data(old.utf8))
        XCTAssertNil(decoded.toWork?.slots)
        XCTAssertNil(decoded.lastPlace)
    }
}
