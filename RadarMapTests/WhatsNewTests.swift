//
//  WhatsNewTests.swift
//  RadarMapTests
//
//  «Что нового» (7.6): только тому, кто уже ездил, один раз на выпуск, и
//  только если есть что сказать.
//

import XCTest
@testable import RadarMap

final class WhatsNewTests: XCTestCase {
    func testShownOnceToExistingDriversOnly() {
        XCTAssertTrue(WhatsNew.shouldShow(seenEdition: 0, onboarded: true))
        XCTAssertFalse(WhatsNew.shouldShow(seenEdition: WhatsNew.edition, onboarded: true), "уже видел")
        XCTAssertFalse(WhatsNew.shouldShow(seenEdition: 0, onboarded: false), "новому пользователю — онбординг")
        XCTAssertFalse(WhatsNew.shouldShow(seenEdition: 0, onboarded: true, items: []), "нечего сказать — экрана нет")
    }

    func testAtMostThreeItems() {
        XCTAssertLessThanOrEqual(WhatsNew.items.count, 3, "экран на секунду — не список изменений")
    }
}
