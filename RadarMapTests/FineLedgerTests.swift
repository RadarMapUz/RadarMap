//
//  FineLedgerTests.swift
//  RadarMapTests
//
//  Экран «Штрафы» (этап 17.3): сроки оплаты и льготный срок (👤 правила —
//  константы AppConfig), ОДНО напоминание на штраф, ожидаемые и пришедшие
//  суммы. Тесты держат то, чего быть не должно: второго напоминания,
//  ожидаемого по догадке о лимите, суммы «к оплате» с выдуманными числами.
//

import XCTest
@testable import RadarMap

final class FineLedgerTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func fine(violation: Date? = nil, issued: Date? = nil, due: Date? = nil,
                      amount: Double? = 412_000, paid: Date? = nil) -> ReceivedFine {
        var fine = ReceivedFine(addedAt: day(10, 1))
        fine.violationAt = violation
        fine.issuedAt = issued
        fine.dueAt = due
        fine.amount = amount
        fine.paidAt = paid
        return fine
    }

    // MARK: - Сроки

    /// Срок и льгота — от даты постановления; без неё — от даты нарушения
    /// (раньше настоящего — безопасная сторона).
    func testTermsFromIssuedOrViolation() throws {
        let issued = try XCTUnwrap(FineDeadline.terms(for: fine(violation: day(10, 1, hour: 18), issued: day(10, 3)),
                                                      calendar: calendar))
        XCTAssertEqual(issued.due, calendar.date(byAdding: .day, value: AppConfig.finePaymentDays, to: day(10, 3)))
        XCTAssertEqual(issued.discountUntil,
                       calendar.date(byAdding: .day, value: AppConfig.fineDiscountDays, to: day(10, 3)))
        XCTAssertEqual(issued.discounted ?? 0, (412_000 * (1 - AppConfig.fineDiscountShare)).rounded(),
                       accuracy: 0.5)
        XCTAssertFalse(issued.dueIsOfficial)

        let byViolation = try XCTUnwrap(FineDeadline.terms(for: fine(violation: day(10, 1, hour: 18)),
                                                           calendar: calendar))
        XCTAssertEqual(byViolation.due, calendar.date(byAdding: .day, value: AppConfig.finePaymentDays, to: day(10, 1)))
        XCTAssertNil(FineDeadline.terms(for: fine(), calendar: calendar), "считать не от чего")
    }

    /// Срок из постановления главнее нашего; льгота, кончающаяся позже него, не показывается.
    func testOfficialDueWins() throws {
        let terms = try XCTUnwrap(FineDeadline.terms(for: fine(violation: day(10, 1), due: day(10, 10)),
                                                     calendar: calendar))
        XCTAssertEqual(terms.due, day(10, 10))
        XCTAssertTrue(terms.dueIsOfficial)
        XCTAssertNil(terms.discountUntil)
        XCTAssertNil(terms.discounted)
    }

    /// Без суммы льготной суммы нет — только срок.
    func testNoAmountNoDiscountedSum() throws {
        let terms = try XCTUnwrap(FineDeadline.terms(for: fine(violation: day(10, 1), amount: nil), calendar: calendar))
        XCTAssertNotNil(terms.discountUntil)
        XCTAssertNil(terms.discounted)
    }

    /// Льготный → обычный → прошёл; оплаченный — всегда «оплачен».
    func testStatusTimeline() {
        let item = fine(violation: day(10, 1))
        let discountEnd = calendar.date(byAdding: .day, value: AppConfig.fineDiscountDays, to: day(10, 1))!
        let due = calendar.date(byAdding: .day, value: AppConfig.finePaymentDays, to: day(10, 1))!
        XCTAssertEqual(FineDeadline.status(for: item, now: day(10, 2), calendar: calendar),
                       .discount(until: discountEnd))
        XCTAssertEqual(FineDeadline.status(for: item, now: discountEnd.addingTimeInterval(20 * 3600),
                                           calendar: calendar), .discount(until: discountEnd),
                       "последний день льготы — включительно")
        XCTAssertEqual(FineDeadline.status(for: item, now: discountEnd.addingTimeInterval(86400), calendar: calendar),
                       .due(until: due))
        XCTAssertEqual(FineDeadline.status(for: item, now: due.addingTimeInterval(86400), calendar: calendar),
                       .overdue(since: due))
        XCTAssertEqual(FineDeadline.status(for: fine(violation: day(10, 1), paid: day(10, 5)), now: day(12, 1),
                                           calendar: calendar), .paid)
        XCTAssertEqual(FineDeadline.status(for: fine(), now: day(10, 2), calendar: calendar), .unknown)
    }

    // MARK: - Напоминание: одно

    /// Пока льгота впереди с запасом — напомнить о ней, в назначенный час.
    func testReminderBeforeDiscountEnd() throws {
        let plan = try XCTUnwrap(FineReminder.plan(for: fine(violation: day(10, 1)), now: day(10, 2),
                                                   calendar: calendar))
        let discountEnd = calendar.date(byAdding: .day, value: AppConfig.fineDiscountDays, to: day(10, 1))!
        XCTAssertTrue(plan.isDiscount)
        XCTAssertEqual(plan.deadline, discountEnd)
        let fireDay = calendar.date(byAdding: .day, value: -AppConfig.fineReminderLeadDays, to: discountEnd)!
        XCTAssertEqual(plan.fire, calendar.date(bySettingHour: AppConfig.fineReminderHour, minute: 0,
                                                second: 0, of: fireDay))
    }

    /// Льгота уже близко или прошла — напоминание о главном сроке; до него
    /// меньше запаса — не напоминаем вовсе (человек сейчас смотрит на штраф).
    func testReminderFallsBackToDueThenNone() throws {
        let item = fine(violation: day(10, 1))
        let discountEnd = calendar.date(byAdding: .day, value: AppConfig.fineDiscountDays, to: day(10, 1))!
        let due = calendar.date(byAdding: .day, value: AppConfig.finePaymentDays, to: day(10, 1))!
        let late = try XCTUnwrap(FineReminder.plan(for: item, now: discountEnd, calendar: calendar))
        XCTAssertFalse(late.isDiscount)
        XCTAssertEqual(late.deadline, due)
        XCTAssertNil(FineReminder.plan(for: item, now: due.addingTimeInterval(-86400), calendar: calendar))
        XCTAssertNil(FineReminder.plan(for: fine(violation: day(10, 1), paid: day(10, 2)), now: day(10, 2),
                                       calendar: calendar))
    }

    /// Одно напоминание: поставленное и наступившее — пришло, второго нет,
    /// даже если по сроку можно было бы поставить ещё одно.
    func testReminderComesOnce() throws {
        var item = fine(violation: day(10, 1))
        guard case .schedule(let plan) = FineReminder.action(for: item, now: day(10, 2), calendar: calendar)
        else { return XCTFail("первое напоминание должно ставиться") }
        item.reminderAt = plan.fire
        XCTAssertEqual(FineReminder.action(for: item, now: day(10, 2), calendar: calendar), .none, "уже стоит")
        XCTAssertEqual(FineReminder.action(for: item, now: plan.fire.addingTimeInterval(60), calendar: calendar),
                       .none, "пришло — больше никогда")
    }

    /// Не пришедшее можно переставить (сменили срок) или снять (оплатил).
    func testPendingReminderMovesOrCancels() {
        var item = fine(violation: day(10, 1))
        item.reminderAt = day(10, 13, hour: 10)
        item.dueAt = day(10, 12)   // раньше конца льготы — льгота снимается, срок другой
        if case .schedule(let plan) = FineReminder.action(for: item, now: day(10, 2), calendar: calendar) {
            XCTAssertNotEqual(plan.fire, item.reminderAt)
        } else {
            XCTFail("сменили срок — напоминание переставляется")
        }
        item.paidAt = day(10, 3)
        XCTAssertEqual(FineReminder.action(for: item, now: day(10, 3), calendar: calendar), .cancel)
    }

    // MARK: - Экран

    private func pass(speed: Double, limit: Int?, at date: Date, assumed: Bool? = nil) -> PassedCamera {
        var pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "Юнусабад",
                                speedKmh: speed, date: date, lat: 41.31, lon: 69.28, limitKmh: limit)
        pass.limitAssumed = assumed
        return pass
    }

    private func record(_ passes: [PassedCamera]) -> TripRecord {
        let start = passes.first?.date.addingTimeInterval(-300) ?? day(10, 1)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start, endedAt: start.addingTimeInterval(900),
                          distanceMeters: 8000, maxSpeedKmh: 90, passed: passes, score: 80)
    }

    /// Ожидаемые: только «ожидается», достоверный лимит, ступень штрафа и не
    /// старше срока, после которого обычно не приходит. Сверенные — в
    /// пришедших, «пришёл» кнопкой — отдельным списком «внести постановление».
    func testExpectedAndMarked() throws {
        let now = day(10, 20)
        let pending = pass(speed: 88, limit: 60, at: day(10, 18))
        let clean = pass(speed: 58, limit: 60, at: day(10, 18))
        let guessed = pass(speed: 88, limit: 60, at: day(10, 18), assumed: true)
        let ancient = pass(speed: 88, limit: 60,
                           at: now.addingTimeInterval(-Double(AppConfig.fineExpiresDays + 1) * 86400))
        let toDismiss = pass(speed: 88, limit: 60, at: day(10, 17))
        let dismissed = try XCTUnwrap(TripHistory.settingFineOutcome(record([toDismiss]), passID: toDismiss.id,
                                                                     outcome: .dismissed))
        var paidByButton = pass(speed: 80, limit: 60, at: day(10, 16))
        paidByButton.finePaid = true
        var linked = pass(speed: 90, limit: 60, at: day(10, 15))
        linked.finePaid = true
        linked.fineReceiptID = UUID()
        let history = [record([pending, clean, guessed]), record([ancient]), dismissed,
                       record([paidByButton]), record([linked])]

        let ledger = FineLedger.build(fines: [], history: history, now: now, calendar: calendar)
        XCTAssertEqual(ledger.expected.map(\.pass.id), [pending.id])
        XCTAssertEqual(ledger.marked.map(\.pass.id), [paidByButton.id])
        XCTAssertEqual(ledger.expectedSum, 5 * FineSchedule.brv, accuracy: 0.01)
        // Шапка и вкладка «Пришли» считают одинаково: отмеченный «пришёл» тоже пришёл.
        XCTAssertEqual(ledger.arrivedCount, ledger.received.count + 1)
    }

    /// «К оплате» — только неоплаченные с известной суммой; без суммы —
    /// отдельным счётчиком, оплаченные — своей суммой.
    func testTotals() {
        let now = day(10, 20)
        let fines = [fine(violation: day(10, 10), amount: 412_000),
                     fine(violation: day(10, 11), amount: nil),
                     fine(violation: day(10, 12), amount: 2_200_000, paid: day(10, 15))]
        let ledger = FineLedger.build(fines: fines, history: [], now: now, calendar: calendar)
        XCTAssertEqual(ledger.toPay, 412_000, accuracy: 0.01)
        XCTAssertEqual(ledger.toPayCount, 1)
        XCTAssertEqual(ledger.unknownAmountCount, 1)
        XCTAssertEqual(ledger.paidTotal, 2_200_000, accuracy: 0.01)
        XCTAssertEqual(ledger.received.last?.fine.isPaid, true, "оплаченные — в конце")
    }

    /// Порядок: просроченный — первым, дальше по ближайшему сроку, без сроков — в конце.
    func testReceivedOrderByUrgency() {
        let now = day(11, 20)
        let overdue = fine(violation: day(10, 1))
        let soon = fine(violation: day(11, 10))
        let later = fine(violation: day(11, 18))
        let undated = fine()
        let ledger = FineLedger.build(fines: [undated, later, soon, overdue], history: [], now: now,
                                      calendar: calendar)
        XCTAssertEqual(ledger.received.map(\.fine.id), [overdue.id, soon.id, later.id, undated.id])
    }

    /// Сверка, чья запись вычищена, честно говорит об этом.
    func testLinkStates() {
        let kept = pass(speed: 88, limit: 60, at: day(10, 18))
        var linked = fine(violation: day(10, 18))
        linked.link = .pass(tripID: 1, passID: kept.id)
        var gone = fine(violation: day(10, 17))
        gone.link = .pass(tripID: 2, passID: UUID())
        var byDay = fine(violation: day(9, 1))
        byDay.link = .day(day(9, 1), riskMoved: 0, paidAdded: 0)
        let ledger = FineLedger.build(fines: [linked, gone, byDay, fine(violation: day(10, 1))],
                                      history: [record([kept])], now: day(10, 20), calendar: calendar)
        func state(_ id: UUID) -> String {
            switch ledger.received.first(where: { $0.fine.id == id })?.link {
            case .pass?: "pass"
            case .passGone?: "gone"
            case .day?: "day"
            case .none?: "none"
            case nil: "missing"
            }
        }
        XCTAssertEqual(state(linked.id), "pass")
        XCTAssertEqual(state(gone.id), "gone")
        XCTAssertEqual(state(byDay.id), "day")
    }

    /// Строка Итогов — по самим штрафам: к оплате и ближайший срок.
    func testDues() {
        let now = day(10, 20)
        let dues = FineLedger.dues([fine(violation: day(10, 10), amount: 412_000),
                                    fine(violation: day(8, 1), amount: 100_000),
                                    fine(violation: day(10, 12), amount: 50_000, paid: day(10, 13))],
                                   now: now, calendar: calendar)
        XCTAssertEqual(dues.unpaid, 2)
        XCTAssertEqual(dues.toPay, 512_000, accuracy: 0.01)
        XCTAssertEqual(dues.overdue, 1)
        XCTAssertEqual(dues.nextDeadline,
                       calendar.date(byAdding: .day, value: AppConfig.fineDiscountDays, to: day(10, 10)))
    }
}
