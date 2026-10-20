//
//  MaintenanceRemindersTests.swift
//  RadarMapTests
//
//  Напоминания об обслуживании (18.3): одно на пункт и порог за цикл, на
//  ходу не приходят (поставленное снимается на старте поездки), после
//  стоянки — днём сразу, ночью — в 9:00, при открытии — в 9:00; выключатель
//  снимает всё; то, что человек сам правил на экране, не напоминается;
//  второй пересчёт с теми же данными не делает ничего.
//

import XCTest
@testable import RadarMap

final class MaintenanceRemindersTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    private func state(_ kind: MaintenanceKind, _ status: Maintenance.Status,
                       cycle: String = "c1") -> Maintenance.State {
        Maintenance.State(kind: kind, status: status, intervalKm: nil, intervalMonths: nil,
                          remainingKm: nil, dueDate: nil, daysLeft: nil, progress: nil, cycle: cycle)
    }

    private func plan(_ states: [Maintenance.State], ledger: [String: Date] = [:], enabled: Bool = true,
                      trip: Bool = false, moment: MaintenanceReminders.Moment = .parked, now: Date,
                      acknowledged: Set<MaintenanceKind> = []) -> MaintenanceReminders.Plan {
        MaintenanceReminders.plan(states: states, ledger: ledger, enabled: enabled, tripActive: trip,
                                  moment: moment, now: now, acknowledged: acknowledged, calendar: calendar)
    }

    private func id(_ kind: MaintenanceKind, _ threshold: MaintenanceReminders.Threshold,
                    _ cycle: String = "c1") -> String {
        MaintenanceReminders.id(kind, threshold, cycle: cycle)
    }

    func testOncePerThresholdAndIdempotent() {
        let now = date(20, 18)
        let first = plan([state(.oil, .soon), state(.osago, .ok), state(.sparkPlugs, .unknown)], now: now)
        XCTAssertEqual(first.schedule.map(\.id), [id(.oil, .soon)])
        XCTAssertEqual(first.schedule.first?.fire, now.addingTimeInterval(AppConfig.maintenanceParkedDelaySeconds),
                       "машина встала днём — через пару минут")
        let again = plan([state(.oil, .soon)], ledger: first.ledger, now: now.addingTimeInterval(10))
        XCTAssertTrue(again.schedule.isEmpty, "поставленное не ставится второй раз")
        XCTAssertTrue(again.cancel.isEmpty)
        let shown = plan([state(.oil, .soon)], ledger: first.ledger, moment: .opened, now: date(22, 10))
        XCTAssertTrue(shown.schedule.isEmpty, "показанное «скоро» не повторяется")
        XCTAssertEqual(shown.ledger, first.ledger)
    }

    func testDueAfterSoonAndOverdueIsDue() {
        let delivered = [id(.oil, .soon): date(18, 9)]
        let due = plan([state(.oil, .due)], ledger: delivered, now: date(20, 18))
        XCTAssertEqual(due.schedule.map(\.id), [id(.oil, .due)])
        let overdue = plan([state(.oil, .overdue)], ledger: due.ledger, now: date(25, 18))
        XCTAssertTrue(overdue.schedule.isEmpty, "«просрочено» — тот же порог «пора»: каждый день не пинаем")
    }

    func testDueSupersedesPendingSoon() {
        let pending = [id(.oil, .soon): date(21, 9)]
        let result = plan([state(.oil, .due)], ledger: pending, now: date(20, 18))
        XCTAssertEqual(result.cancel, [id(.oil, .soon)])
        XCTAssertEqual(result.schedule.map(\.id), [id(.oil, .due)])
        XCTAssertNil(result.ledger[id(.oil, .soon)])
    }

    func testNeverDuringTrip() {
        let now = date(21, 8, 50)
        let pending = [id(.oil, .soon): date(21, 9), id(.osago, .due): date(19, 9)]
        let driving = plan([state(.oil, .soon), state(.osago, .due)], ledger: pending, trip: true, now: now)
        XCTAssertTrue(driving.schedule.isEmpty, "на ходу не ставим ничего")
        XCTAssertEqual(driving.cancel, [id(.oil, .soon)], "поставленное на 9:00 снято до того, как придёт в дороге")
        XCTAssertEqual(driving.ledger, [id(.osago, .due): date(19, 9)], "показанное раньше помним")
        // Приехали в 9:30 — после стоянки.
        let parked = plan([state(.oil, .soon), state(.osago, .due)], ledger: driving.ledger, now: date(21, 9, 30))
        XCTAssertEqual(parked.schedule.map(\.id), [id(.oil, .soon)])
        XCTAssertEqual(parked.schedule.first?.fire, date(21, 9, 32))
    }

    func testNightAndMorningTimes() {
        XCTAssertEqual(MaintenanceReminders.fireTime(moment: .parked, now: date(20, 22, 30), calendar: calendar),
                       date(21, 9), "приехали ночью — утром")
        XCTAssertEqual(MaintenanceReminders.fireTime(moment: .parked, now: date(20, 7), calendar: calendar),
                       date(20, 9), "приехали рано — в девять того же дня")
        XCTAssertEqual(MaintenanceReminders.fireTime(moment: .parked, now: date(20, 20, 59), calendar: calendar),
                       date(20, 21, 1))
        XCTAssertEqual(MaintenanceReminders.fireTime(moment: .opened, now: date(20, 10), calendar: calendar),
                       date(21, 9), "открыли днём — завтра утром, а не сейчас поверх экрана")
        XCTAssertEqual(MaintenanceReminders.fireTime(moment: .opened, now: date(20, 8), calendar: calendar),
                       date(20, 9))
    }

    func testSwitchOffCancelsEverything() {
        let ledger = [id(.oil, .soon): date(21, 9), id(.osago, .due): date(19, 9)]
        let off = plan([state(.oil, .soon), state(.osago, .due)], ledger: ledger, enabled: false, now: date(20, 12))
        XCTAssertTrue(off.schedule.isEmpty)
        XCTAssertEqual(off.cancel, [id(.oil, .soon)])
        XCTAssertEqual(off.ledger, [id(.osago, .due): date(19, 9)],
                       "включат снова — показанное второй раз не придёт")
    }

    func testNewCycleAfterDone() {
        let ledger = [id(.oil, .soon): date(10, 9), id(.oil, .due): date(15, 9)]
        // «Сделано сегодня» — новый цикл: старый журнал больше не нужен.
        let done = plan([state(.oil, .ok, cycle: "c2")], ledger: ledger, now: date(20, 12))
        XCTAssertTrue(done.ledger.isEmpty)
        XCTAssertTrue(done.cancel.isEmpty, "показанное снимать незачем")
        let later = plan([state(.oil, .soon, cycle: "c2")], ledger: done.ledger, now: date(28, 18))
        XCTAssertEqual(later.schedule.map(\.id), [id(.oil, .soon, "c2")])
    }

    func testDoneBeforeReminderFiredCancelsIt() {
        let pending = [id(.oil, .due): date(21, 9)]
        let done = plan([state(.oil, .ok, cycle: "c2")], ledger: pending, moment: .opened, now: date(20, 19))
        XCTAssertEqual(done.cancel, [id(.oil, .due)], "заменили масло вечером — утром «пора» не приходит")
        XCTAssertTrue(done.schedule.isEmpty)
    }

    func testSeenOnScreenIsNotReminded() {
        let now = date(20, 12)
        let edited = plan([state(.oil, .due), state(.osago, .soon)], moment: .opened, now: now, acknowledged: [.oil])
        XCTAssertEqual(edited.schedule.map(\.id), [id(.osago, .soon)])
        XCTAssertEqual(edited.ledger[id(.oil, .due)], now, "своё «пора» человек только что видел")
        let pending = [id(.osago, .soon): date(21, 9)]
        let looked = plan([state(.osago, .soon)], ledger: pending, moment: .opened, now: now, acknowledged: [.osago])
        XCTAssertEqual(looked.cancel, [id(.osago, .soon)])
        XCTAssertEqual(looked.ledger[id(.osago, .soon)], now)
    }
}
