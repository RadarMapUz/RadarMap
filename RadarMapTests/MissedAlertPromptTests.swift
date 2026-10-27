//
//  MissedAlertPromptTests.swift
//  RadarMapTests
//
//  «Не предупредила» на карточке «Поездка сохранена» (12.5): строка — только
//  про доказанную тишину, и ни про что другое.
//

import XCTest
@testable import RadarMap

final class MissedAlertPromptTests: XCTestCase {

    private func pass(_ silent: Bool?, at seconds: TimeInterval, id: Int = 1) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "radar", location: "ул. Тест",
                     speedKmh: 58, date: Date(timeIntervalSince1970: seconds), silent: silent)
    }

    func testOnlySilentPassesAreOffered() {
        let quiet = pass(true, at: 10, id: 1)
        let warned = pass(false, at: 20, id: 2)
        let legacy = pass(nil, at: 30, id: 3)
        XCTAssertEqual(MissedAlertPrompt.candidates(passes: [quiet, warned, legacy]).map(\.id), [quiet.id],
                       "оповещение было или запись старше поля — не спрашиваем")
    }

    func testNoSilenceNoRow() {
        XCTAssertTrue(MissedAlertPrompt.candidates(passes: [pass(false, at: 1), pass(nil, at: 2)]).isEmpty)
        XCTAssertTrue(MissedAlertPrompt.candidates(passes: []).isEmpty)
    }

    func testReportedOnesLeaveAndOrderIsByPass() {
        let late = pass(true, at: 50, id: 1)
        let early = pass(true, at: 5, id: 2)
        XCTAssertEqual(MissedAlertPrompt.candidates(passes: [late, early]).map(\.id), [early.id, late.id])
        XCTAssertEqual(MissedAlertPrompt.candidates(passes: [late, early], reported: [early.id]).map(\.id),
                       [late.id])
    }

    func testTitleDeclinesInPrepositional() {
        XCTAssertEqual(MissedAlertPrompt.title(count: 1), "Промолчала о камере")
        XCTAssertEqual(MissedAlertPrompt.title(count: 2), "Промолчала о 2 камерах")
        XCTAssertEqual(MissedAlertPrompt.title(count: 5), "Промолчала о 5 камерах")
        XCTAssertEqual(MissedAlertPrompt.title(count: 21), "Промолчала о 21 камере")
    }
}
