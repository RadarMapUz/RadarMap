//
//  DeadlineTests.swift
//  RadarMapTests
//
//  Отсчёт «Отметить»: молчание три секунды отправляет треногу. Отправка
//  первым делом снимает таймер выбора — и раньше этим отменяла собственный
//  запрос (он шёл в задаче таймера): тренога уходила в очередь с «нет связи»
//  при полной антенне (92). Дело к сроку должно переживать снятие срока.
//

import XCTest
@testable import RadarMap

@MainActor
final class DeadlineTests: XCTestCase {

    func testActionSurvivesCancellingItsOwnDeadline() async {
        let deadline = Deadline()
        let done = expectation(description: "дело доведено")
        deadline.arm(Date().addingTimeInterval(0.05)) {
            deadline.cancel()   // как perform(.send) снимает таймер выбора
            await Task.yield()
            XCTAssertFalse(Task.isCancelled, "отмена срока оборвала бы запрос отметки")
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testCancelBeforeDeadlineSkipsAction() async {
        let deadline = Deadline()
        let skipped = expectation(description: "дело не случилось")
        skipped.isInverted = true
        deadline.arm(Date().addingTimeInterval(0.1)) { skipped.fulfill() }
        deadline.cancel()
        XCTAssertFalse(deadline.isArmed)
        await fulfillment(of: [skipped], timeout: 0.4)
    }

    func testRearmReplacesEarlierDeadline() async {
        let deadline = Deadline()
        let first = expectation(description: "первый срок снят")
        first.isInverted = true
        let second = expectation(description: "второй срок")
        deadline.arm(Date().addingTimeInterval(0.05)) { first.fulfill() }
        deadline.arm(Date().addingTimeInterval(0.1)) { second.fulfill() }
        await fulfillment(of: [first, second], timeout: 1)
    }

    func testDisarmedOnceFired() async {
        let deadline = Deadline()
        let fired = expectation(description: "сработал")
        deadline.arm(Date().addingTimeInterval(0.02)) { fired.fulfill() }
        XCTAssertTrue(deadline.isArmed)
        await fulfillment(of: [fired], timeout: 1)
        XCTAssertFalse(deadline.isArmed)
    }
}
