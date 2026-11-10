//
//  RouteRaceTests.swift
//  RadarMapTests
//
//  Apple или свой OSRM (76): готовый свой ответ ждёт Apple только до срока.
//

import XCTest
@testable import RadarMap

final class RouteRaceTests: XCTestCase {

    private typealias Race = RouteRace<String>
    private struct Boom: Error {}

    private func taken(_ decision: Race.Decision) -> String? {
        if case .take(let value) = decision { return value }
        return nil
    }

    private func isWaiting(_ decision: Race.Decision) -> Bool {
        if case .wait = decision { return true }
        return false
    }

    func testAppleWinsWhenItAnswersInTime() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.own(.success("osrm"), weak: false))))
        XCTAssertEqual(taken(race.note(.apple("apple"))), "apple")
    }

    func testReadyOwnAnswerTakenAtDeadline() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.own(.success("osrm"), weak: false))))
        XCTAssertEqual(taken(race.note(.deadline)), "osrm")
    }

    func testOwnAnswerAfterDeadlineTakenAtOnce() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.deadline)))
        XCTAssertEqual(taken(race.note(.own(.success("osrm"), weak: false))), "osrm")
    }

    func testAppleRefusalReleasesOwnAnswerBeforeDeadline() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.own(.success("osrm"), weak: false))))
        XCTAssertEqual(taken(race.note(.apple(nil))), "osrm")
    }

    func testOwnFailureWaitsForPendingApple() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.own(.failure(Boom()), weak: false))))
        XCTAssertTrue(isWaiting(race.note(.deadline)))
        XCTAssertEqual(taken(race.note(.apple("apple"))), "apple")
    }

    func testBothFailedReportsOwnError() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.apple(nil))))
        guard case .fail(let error) = race.note(.own(.failure(Boom()), weak: false)) else {
            return XCTFail("оба отказали — ошибка своего")
        }
        XCTAssertTrue(error is Boom)
    }

    /// Приблизительный маршрут без сети не перебивает Apple, который ещё в пути.
    func testWeakOwnAnswerWaitsForAppleEvenPastDeadline() {
        var race = Race()
        XCTAssertTrue(isWaiting(race.note(.own(.success("offline"), weak: true))))
        XCTAssertTrue(isWaiting(race.note(.deadline)))
        XCTAssertEqual(taken(race.note(.apple(nil))), "offline")
    }
}
