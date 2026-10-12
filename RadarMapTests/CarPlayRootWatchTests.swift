//
//  CarPlayRootWatchTests.swift
//  RadarMapTests
//
//  Корень на экране машины: система не обязана сообщать templateDidAppear,
//  и без него не должны пропадать навигационная сессия и разрешение.
//

import XCTest
@testable import RadarMap

final class CarPlayRootWatchTests: XCTestCase {

    private typealias Watch = CarPlayRootWatch

    func testConfirmedRootIsShownWithoutTemplateDidAppear() {
        // Ровно случай carplay10: установка подтверждена, вызова нет — сессия
        // обязана начаться, а не ждать до отключения машины.
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: true, retried: false, timedOut: false), .markShown)
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: true, retried: false, timedOut: true), .markShown)
    }

    func testConfirmedRootIsNeverSetAgain() {
        // Повторная установка подтверждённого корня сбрасывала всё поверх
        // него — каждые 3 с после возврата в приложение.
        for retried in [false, true] {
            for timedOut in [false, true] {
                XCTAssertNotEqual(Watch.action(rootShown: false, rootSet: true, retried: retried, timedOut: timedOut),
                                  .setAgain)
            }
        }
    }

    func testShownRootNeedsNothing() {
        for rootSet in [nil, true, false] as [Bool?] {
            XCTAssertEqual(Watch.action(rootShown: true, rootSet: rootSet, retried: false, timedOut: true), .none)
        }
    }

    func testUnconfirmedRootWaitsForTheTimeout() {
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: nil, retried: false, timedOut: false), .none)
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: false, retried: false, timedOut: false), .none)
    }

    func testLostRootIsSetAgainOnceAfterTheTimeout() {
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: nil, retried: false, timedOut: true), .setAgain)
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: false, retried: false, timedOut: true), .setAgain)
        // Второй раз подряд — нет: бесконечные повторы мигали бы экраном.
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: nil, retried: true, timedOut: true), .none)
        XCTAssertEqual(Watch.action(rootShown: false, rootSet: false, retried: true, timedOut: true), .none)
    }
}
