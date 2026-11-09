//
//  RouteBuildFlowTests.swift
//  RadarMapTests
//
//  Построение маршрута: одна попытка за раз, второе касание — не второй
//  запрос, смена цели и отмена не дают опоздавшему ответу ничего изменить.
//

import XCTest
@testable import RadarMap

final class RouteBuildFlowTests: XCTestCase {
    private typealias Flow = RouteBuildFlow

    private let home = RouteBuildFlow.Target(name: "Дом", latitude: 41.3, longitude: 69.24)
    private let work = RouteBuildFlow.Target(name: "Работа", latitude: 41.35, longitude: 69.3)

    private func attempt(_ begin: Flow.Begin) -> Int {
        switch begin {
        case .started(let attempt), .replaced(let attempt): return attempt
        case .duplicate:
            XCTFail("ожидалась новая попытка")
            return -1
        }
    }

    func testTapAnswersBeforeGPSAndNetwork() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        XCTAssertEqual(flow.state, .working(home, .locating, slow: false))
        XCTAssertTrue(flow.isCurrent(first))
        XCTAssertFalse(flow.isCalculating, "пока ждём GPS, прогресс прежнего маршрута не замораживаем")
        flow.advance(first, to: .calculating)
        XCTAssertTrue(flow.isCalculating)
    }

    func testDoubleTapIsNotASecondBuild() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        let near = Flow.Target(name: "Дом", latitude: 41.3001, longitude: 69.24)
        XCTAssertEqual(flow.begin(near), .duplicate)
        XCTAssertTrue(flow.isCurrent(first), "первая попытка продолжается")
        XCTAssertEqual(flow.attempt, first)
    }

    func testAnotherPurposeToTheSamePlaceIsNotADuplicate() {
        var flow = Flow()
        _ = flow.begin(home)
        var stop = home
        stop.purpose = .addStop
        guard case .replaced = flow.begin(stop) else { return XCTFail("заезд — другое действие") }
    }

    func testNewDestinationReplacesAndTheLateAnswerChangesNothing() {
        var flow = Flow()
        let old = attempt(flow.begin(home))
        flow.advance(old, to: .calculating)
        let new = attempt(flow.begin(work))
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(flow.state, .working(work, .locating, slow: false), "индикатор сразу про новую цель")
        XCTAssertFalse(flow.fail(old, .network), "ошибка старой попытки экран не трогает")
        XCTAssertFalse(flow.finish(old), "и её конец не гасит индикатор новой")
        flow.markSlow(old)
        XCTAssertEqual(flow.state, .working(work, .locating, slow: false))
    }

    func testCancelReportsStageAndClosesTheAttempt() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        XCTAssertEqual(flow.cancel(), .locating)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertFalse(flow.isCurrent(first), "GPS вернулся — строить нечего")
        XCTAssertFalse(flow.fail(first, .noFix))
        XCTAssertEqual(flow.state, .idle)
        XCTAssertNil(flow.cancel(), "отменять больше нечего")
    }

    func testCancelWhileCalculatingIsReportedAsSuch() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        flow.advance(first, to: .comparing)
        XCTAssertEqual(flow.cancel(), .comparing)
    }

    func testStagesOnlyGoForward() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        flow.advance(first, to: .comparing)
        flow.advance(first, to: .calculating)
        XCTAssertEqual(flow.state, .working(home, .comparing, slow: false))
    }

    func testSlowNetworkIsVisibleAndKeepsTheStage() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        flow.advance(first, to: .calculating)
        flow.markSlow(first)
        XCTAssertEqual(flow.state, .working(home, .calculating, slow: true))
        flow.advance(first, to: .comparing)
        XCTAssertEqual(flow.state, .working(home, .comparing, slow: true))
    }

    func testFailureOffersRetryOnlyWhereItCanHelp() {
        XCTAssertTrue(Flow.canRetry(home, .network))
        XCTAssertTrue(Flow.canRetry(home, .noFix))
        XCTAssertFalse(Flow.canRetry(home, .noRoute))
        XCTAssertFalse(Flow.canRetry(home, .unavailable), "пульт выключил маршруты — ждём починки")
        var stop = home
        stop.purpose = .addStop
        XCTAssertFalse(Flow.canRetry(stop, .network), "заезд не добавлен, маршрут прежний")
    }

    func testRetryAfterFailureStartsANewAttempt() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        XCTAssertTrue(flow.fail(first, .network))
        XCTAssertEqual(flow.state, .failed(home, .network))
        XCTAssertFalse(flow.isWorking)
        let retry = attempt(flow.begin(home))
        XCTAssertNotEqual(first, retry, "та же цель после ошибки — не дубль")
        XCTAssertEqual(flow.state, .working(home, .locating, slow: false))
    }

    func testFinishKeepsTheFailureOnScreen() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        flow.fail(first, .noRoute)
        XCTAssertFalse(flow.finish(first))
        XCTAssertEqual(flow.state, .failed(home, .noRoute))
    }

    func testDismissClosesOnlyTheFailure() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        flow.dismissFailure()
        XCTAssertTrue(flow.isCurrent(first), "закрытие старого сообщения не трогает идущую попытку")
        flow.fail(first, .network)
        flow.dismissFailure()
        XCTAssertEqual(flow.state, .idle)
    }

    func testClearingTheRouteClosesTheAttempt() {
        var flow = Flow()
        let first = attempt(flow.begin(home))
        flow.reset()
        XCTAssertEqual(flow.state, .idle)
        XCTAssertFalse(flow.isCurrent(first))
    }
}
