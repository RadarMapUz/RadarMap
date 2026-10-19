//
//  PassengerSessionTests.swift
//  RadarMapTests
//
//  «Я пассажир» переживает перезапуск системой посреди езды (S29), но не
//  дольше срока: забытая сессия не глушит автостарт завтра.
//

import XCTest
@testable import RadarMap

final class PassengerSessionTests: XCTestCase {
    func testRestoredOnlyWithinItsTerm() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(LocationService.passengerSessionRestored(until: now.addingTimeInterval(3600), now: now))
        XCTAssertFalse(LocationService.passengerSessionRestored(until: now.addingTimeInterval(-1), now: now),
                       "срок вышел")
        XCTAssertFalse(LocationService.passengerSessionRestored(until: nil, now: now))
        XCTAssertFalse(LocationService.passengerSessionRestored(until: now.addingTimeInterval(5 * 86_400), now: now),
                       "часы перевели назад — срок длиннее возможного не верим")
    }
}
