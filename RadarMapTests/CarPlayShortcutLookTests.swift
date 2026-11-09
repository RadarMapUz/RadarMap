//
//  CarPlayShortcutLookTests.swift
//  RadarMapTests
//
//  Кнопки «Дом»/«Работа» плитки: нажатие видно сразу, причина отказа названа,
//  второе нажатие и уже идущий маршрут не запускают построение.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CarPlayShortcutLookTests: XCTestCase {
    private typealias Look = CarPlayShortcutLook
    private typealias Flow = RouteBuildFlow

    private let home = RouteBuildFlow.Target(name: "Дом", latitude: 41.3, longitude: 69.24)
    private let work = RouteBuildFlow.Target(name: "Работа", latitude: 41.35, longitude: 69.3)

    private func status(_ place: RouteBuildFlow.Target, _ flow: Flow) -> Look.Status {
        Look.status(latitude: place.latitude, longitude: place.longitude, state: flow.state)
    }

    /// Нажатие — стоя и на ходу одинаково: подпись меняется ещё до GPS и сети.
    func testPressShowsBuildingOnThatButtonOnly() {
        var flow = Flow()
        XCTAssertEqual(status(home, flow), .idle)
        _ = flow.begin(home)
        XCTAssertEqual(status(home, flow), .building(slow: false))
        XCTAssertEqual(status(work, flow), .idle, "другая кнопка подпись не меняет")
    }

    func testDoublePressStaysOneBuild() {
        var flow = Flow()
        guard case .started(let first) = flow.begin(home) else { return XCTFail() }
        XCTAssertEqual(flow.begin(home), .duplicate)
        XCTAssertEqual(flow.attempt, first)
        XCTAssertEqual(status(home, flow), .building(slow: false))
    }

    func testNoNetworkNamesTheReasonOnTheButton() {
        var flow = Flow()
        guard case .started(let attempt) = flow.begin(home) else { return XCTFail() }
        flow.fail(attempt, .network)
        XCTAssertEqual(status(home, flow), .failed(.network))
        guard case .started = flow.begin(home) else { return XCTFail("повторное нажатие после ошибки — новая попытка") }
        XCTAssertEqual(status(home, flow), .building(slow: false))
    }

    func testSlowNetworkIsShown() {
        var flow = Flow()
        guard case .started(let attempt) = flow.begin(home) else { return XCTFail() }
        flow.markSlow(attempt)
        XCTAssertEqual(status(home, flow), .building(slow: true))
    }

    func testStopNearHomeDoesNotTouchTheHomeButton() {
        var flow = Flow()
        var stop = home
        stop.purpose = .addStop
        _ = flow.begin(stop)
        XCTAssertEqual(status(home, flow), .idle)
    }

    func testAlreadyGuidingHereIsNotASecondBuild() {
        let place = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.24)
        let near = CLLocationCoordinate2D(latitude: 41.3001, longitude: 69.24)
        let far = CLLocationCoordinate2D(latitude: 41.35, longitude: 69.3)
        XCTAssertTrue(Look.isAlreadyGuiding(tripActive: true, destination: near, place: place))
        XCTAssertFalse(Look.isAlreadyGuiding(tripActive: false, destination: near, place: place),
                       "маршрут без поездки — выбор, не ведение")
        XCTAssertFalse(Look.isAlreadyGuiding(tripActive: true, destination: far, place: place), "ведём в другое место")
        XCTAssertFalse(Look.isAlreadyGuiding(tripActive: true, destination: nil, place: place))
    }
}
