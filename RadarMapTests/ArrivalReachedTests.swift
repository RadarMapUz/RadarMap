//
//  ArrivalReachedTests.swift
//  RadarMapTests
//
//  Прибытие к цели маршрута (76): близко по прямой — ещё не приехали, если
//  по линии до цели далеко (встречная сторона, петля развязки).
//

import XCTest
@testable import RadarMap

final class ArrivalReachedTests: XCTestCase {

    func testOppositeSideBeforeTheUTurnIsNotArrival() {
        // Цель через разделительную в 35 м, разворот через 600 м: по линии 1,2 км.
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 35, remainingAlong: 1235, deviation: 4))
        // Петля развязки проходит в 50 м от финиша, по линии ещё 900 м.
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 50, remainingAlong: 900, deviation: 8))
        // Ближний разворот: 200 м туда и 200 обратно — всё ещё не приехали.
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 30, remainingAlong: 430, deviation: 3))
    }

    func testOrdinaryApproachIsArrival() {
        XCTAssertTrue(ArrivalReached.isReached(destinationDistance: 55, remainingAlong: 58, deviation: 3))
        // Цель во дворе: по прямой 60 м, по линии вокруг дома — 250.
        XCTAssertTrue(ArrivalReached.isReached(destinationDistance: 60, remainingAlong: 250, deviation: 5))
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 61, remainingAlong: 100, deviation: 5))
    }

    func testGPSMissNearTheTargetIsArrival() {
        // Фикс лёг в 30 м от линии у самой цели.
        XCTAssertTrue(ArrivalReached.isReached(destinationDistance: 45, remainingAlong: 20, deviation: 30))
        // Финиш по линии пройден, парковка в стороне — вторая ветка прежняя.
        XCTAssertTrue(ArrivalReached.isReached(destinationDistance: 200, remainingAlong: 40, deviation: 60))
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 260, remainingAlong: 40, deviation: 60))
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 200, remainingAlong: 90, deviation: 60))
    }

    func testOffTheLineStraightDistanceIsEnough() {
        // Подъехали двором мимо линии: проекция застряла далеко, но мы у цели.
        XCTAssertTrue(ArrivalReached.isReached(destinationDistance: 40, remainingAlong: 800,
                                               deviation: AppConfig.rerouteDriftMeters + 1))
        XCTAssertFalse(ArrivalReached.isReached(destinationDistance: 40, remainingAlong: 800,
                                                deviation: AppConfig.rerouteDriftMeters))
    }

    func testThresholdSitsBetweenAYardLoopAndTheNearestUTurn() {
        XCTAssertGreaterThan(AppConfig.arrivalNearRemainingMeters, 250)
        XCTAssertLessThan(AppConfig.arrivalNearRemainingMeters, 400)
    }
}
