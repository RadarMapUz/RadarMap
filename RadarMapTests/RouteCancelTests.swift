//
//  RouteCancelTests.swift
//  RadarMapTests
//
//  Отменённый запрос маршрута — не «нет связи» (76): без повтора без курса,
//  без своего графа трасс и без текста о сети.
//

import XCTest
@testable import RadarMap

final class RouteCancelTests: XCTestCase {

    func testCancelledRequestStaysCancelled() {
        XCTAssertTrue(RouteService.transportFailure(URLError(.cancelled)) is CancellationError)
        XCTAssertTrue(RouteService.transportFailure(CancellationError()) is CancellationError)
        XCTAssertEqual(RouteService.transportFailure(URLError(.timedOut)) as? RouteService.RouteError, .noConnection)
        XCTAssertEqual(RouteService.transportFailure(URLError(.notConnectedToInternet)) as? RouteService.RouteError,
                       .noConnection)
    }

    func testCancelledRequestIsNotRetriedWithoutHeading() {
        XCTAssertFalse(RouteService.retriesWithoutHeading(after: CancellationError()))
        XCTAssertFalse(RouteService.retriesWithoutHeading(after: URLError(.cancelled)))
        XCTAssertFalse(RouteService.retriesWithoutHeading(after: RouteService.RouteError.noConnection))
        XCTAssertTrue(RouteService.retriesWithoutHeading(after: RouteService.RouteError.noRoute))
    }

    func testCancelledRequestDoesNotStartTheOfflineGraph() {
        XCTAssertFalse(RouteService.fallsBackOffline(after: CancellationError(), taskCancelled: false))
        XCTAssertFalse(RouteService.fallsBackOffline(after: RouteService.RouteError.noConnection, taskCancelled: true))
        XCTAssertTrue(RouteService.fallsBackOffline(after: RouteService.RouteError.noConnection, taskCancelled: false))
        XCTAssertTrue(RouteService.fallsBackOffline(after: RouteService.RouteError.serverUnreachable,
                                                    taskCancelled: false))
    }
}
