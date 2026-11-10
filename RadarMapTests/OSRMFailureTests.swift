//
//  OSRMFailureTests.swift
//  RadarMapTests
//
//  Сбои запроса к OSRM через APIClient (76): отмена — молча, не дошёл —
//  «нет связи», NoRoute/NoSegment — «маршрут не найден», прочее — сбой
//  сервера.
//

import XCTest
@testable import RadarMap

final class OSRMFailureTests: XCTestCase {

    private func body(_ code: String) -> Data {
        Data("{\"code\":\"\(code)\",\"message\":\"x\"}".utf8)
    }

    func testNoRouteAndNoSegmentAreNotServerFailures() {
        XCTAssertEqual(OSRMQuery.refusal(status: 400, data: body("NoRoute")), .noRoute)
        XCTAssertEqual(OSRMQuery.refusal(status: 400, data: body("NoSegment")), .noRoute)
    }

    func testOtherRefusalsAreServerFailures() {
        XCTAssertEqual(OSRMQuery.refusal(status: 400, data: body("InvalidQuery")), .server)
        XCTAssertEqual(OSRMQuery.refusal(status: 502, data: Data("<html>Bad Gateway</html>".utf8)), .server)
        XCTAssertEqual(OSRMQuery.refusal(status: 500, data: Data()), .server)
    }

    func testSuccessIsNoRefusal() {
        XCTAssertNil(OSRMQuery.refusal(status: 200, data: body("Ok")))
    }

    func testTransportFailuresThroughAPIClient() {
        let cancelled = APIClient.Failure.transport(URLError(.cancelled))
        XCTAssertTrue(RouteService.isCancellation(cancelled))
        XCTAssertTrue(RouteService.transportFailure(cancelled) is CancellationError)
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .networkConnectionLost] {
            XCTAssertEqual(RouteService.transportFailure(APIClient.Failure.transport(URLError(code)))
                as? RouteService.RouteError, .noConnection, "\(code)")
        }
    }

    /// Сервер ответил «пути нет» — граф трасс без сети знает не больше.
    func testServerNoRouteDoesNotStartTheOfflineGraph() {
        XCTAssertFalse(RouteService.fallsBackOffline(after: RouteService.RouteError.noRoute, taskCancelled: false))
        XCTAssertTrue(RouteService.fallsBackOffline(after: RouteService.RouteError.serverFailed, taskCancelled: false))
    }

    func testServerFailureRetriedWithoutHeadingButNotCancellation() {
        XCTAssertTrue(RouteService.retriesWithoutHeading(after: RouteService.RouteError.serverFailed))
        XCTAssertFalse(RouteService.retriesWithoutHeading(after: APIClient.Failure.transport(URLError(.cancelled))))
    }
}
