//
//  DepartureReminderTests.swift
//  RadarMapTests
//
//  «Выезжайте раньше» (8.8.7): напоминание только когда есть что сказать —
//  выгодный выезд или срок; по будням (суббота — у шестидневки со сроком);
//  не в отпуске, не после сегодняшней поездки и не задним числом.
//

import XCTest
@testable import RadarMap

@MainActor
final class DepartureReminderTests: XCTestCase {
    private let calendar = Calendar.current

    /// Понедельник, 11 января 2027, в `hour:minute` по часам телефона.
    private func monday(_ hour: Int, _ minute: Int = 0, plusDays: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 11 + plusDays, hour: hour, minute: minute))!
    }

    private func summary(lastDeparture: Date, best: Bool = true) -> Commute.Summary {
        let trip = Commute.Trip(id: 1, direction: .toWork, departure: lastDeparture,
                                arrival: lastDeparture.addingTimeInterval(48 * 60), duration: 48 * 60,
                                distanceMeters: 11_800)
        return Commute.Summary(direction: .toWork, last: trip, usual: 48 * 60, usualDepartureMinute: 8 * 60 + 20,
                               lastDelay: 0,
                               best: best ? Commute.BestWindow(startMinute: 7 * 60 + 45, medianDuration: 37 * 60,
                                                               saving: 11 * 60, trips: 4) : nil,
                               trips: [trip])
    }

    func testBetterDepartureOnWeekdaysTenMinutesBefore() {
        let plan = DepartureReminder.plan(summary: summary(lastDeparture: monday(8, 20, plusDays: -3)),
                                          target: nil, now: monday(6), calendar: calendar)
        XCTAssertEqual(plan.count, 5, "пн–пт, без выходных")
        XCTAssertEqual(plan.first?.fire, monday(7, 35))
        XCTAssertTrue(plan.first?.body.contains("7:45") == true, plan.first?.body ?? "")
        XCTAssertTrue(plan.first?.body.contains("8:20") == true, plan.first?.body ?? "")
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count, "один день — одно напоминание")
    }

    /// Срок 9:00, в пути обычно 48 мин: выезд к 8:05 (9:00 − 48 − 5, вниз до 5 мин).
    func testTargetGivesTheLeaveByTime() {
        let target = ArrivalTarget(minute: 9 * 60)
        XCTAssertEqual(DepartureReminder.leaveBy(target: target, usual: 48 * 60), 8 * 60 + 5)
        let plan = DepartureReminder.plan(summary: summary(lastDeparture: monday(8, 20, plusDays: -3)),
                                          target: target, now: monday(6), calendar: calendar)
        XCTAssertEqual(plan.first?.fire, monday(7, 55))
        XCTAssertTrue(plan.first?.body.contains("8:05") == true, plan.first?.body ?? "")
        XCTAssertTrue(plan.first?.body.contains("9:00") == true, plan.first?.body ?? "")
    }

    func testSaturdayOnlyForASixDayWeek() {
        var six = ArrivalTarget(minute: 9 * 60)
        six.saturday = true
        let plan = DepartureReminder.plan(summary: summary(lastDeparture: monday(8, 20, plusDays: -3)),
                                          target: six, now: monday(6), calendar: calendar)
        XCTAssertEqual(plan.count, 6)
    }

    func testNothingToSayMeansNoReminder() {
        XCTAssertTrue(DepartureReminder.plan(summary: summary(lastDeparture: monday(8, 20, plusDays: -3), best: false),
                                             target: nil, now: monday(6), calendar: calendar).isEmpty,
                      "«пора ехать» в обычное время человек знает и без нас")
        XCTAssertTrue(DepartureReminder.plan(summary: nil, target: ArrivalTarget(minute: 540), now: monday(6),
                                             calendar: calendar).isEmpty)
    }

    func testVacationSilencesReminders() {
        XCTAssertTrue(DepartureReminder.plan(summary: summary(lastDeparture: monday(8, 20, plusDays: -12)),
                                             target: nil, now: monday(6), calendar: calendar).isEmpty)
    }

    func testNotTodayAfterDrivingOrPastTheTime() {
        let droveEarly = DepartureReminder.plan(summary: summary(lastDeparture: monday(5, 50)),
                                                target: nil, now: monday(6), calendar: calendar)
        XCTAssertEqual(droveEarly.count, 4, "сегодня уже ехали — сегодняшнего нет")
        XCTAssertFalse(droveEarly.contains { calendar.isDate($0.fire, inSameDayAs: monday(6)) })
        let late = DepartureReminder.plan(summary: summary(lastDeparture: monday(8, 20, plusDays: -3)),
                                          target: nil, now: monday(8), calendar: calendar)
        XCTAssertEqual(late.count, 4, "7:35 уже прошло — задним числом не ставим")
    }

    func testNightShiftTargetHasNoLeaveBy() {
        XCTAssertNil(DepartureReminder.leaveBy(target: ArrivalTarget(minute: 30), usual: 48 * 60))
    }
}
