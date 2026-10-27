//
//  TrafficArrivalGateTests.swift
//  RadarMapTests
//
//  Профиль часа недели и «обычно», пришедшие во время сборки маршрута, не
//  теряются (симуляция пробок 27.10: первый маршрут после запуска показывал
//  время без профиля): пришло во время сборки — пересчёт ровно один раз в её
//  конце; пришло без сборки — сразу; ничего не пришло — без пересчёта.
//

import XCTest
@testable import RadarMap

final class TrafficArrivalGateTests: XCTestCase {

    func testArrivalDuringBuildIsRecomputedOnceAtTheEnd() {
        var gate = TrafficArrivalGate()
        XCTAssertFalse(gate.arrived(whileBuilding: true), "во время сборки варианты старые — не сейчас")
        XCTAssertTrue(gate.pending)
        XCTAssertTrue(gate.buildFinished(), "в конце сборки — досчитать")
        XCTAssertFalse(gate.buildFinished(), "второй конец без новых данных — без пересчёта")
    }

    func testSeveralArrivalsDuringBuildGiveOneRecompute() {
        var gate = TrafficArrivalGate()
        _ = gate.arrived(whileBuilding: true)
        _ = gate.arrived(whileBuilding: true)
        XCTAssertTrue(gate.buildFinished())
        XCTAssertFalse(gate.pending)
    }

    func testArrivalWithoutBuildRecomputesAtOnce() {
        var gate = TrafficArrivalGate()
        XCTAssertTrue(gate.arrived(whileBuilding: false))
        XCTAssertFalse(gate.buildFinished(), "ничего не отложено — конец следующей сборки ничего не досчитывает")
    }

    func testBuildWithoutArrivalDoesNothing() {
        var gate = TrafficArrivalGate()
        XCTAssertFalse(gate.buildFinished())
    }
}

/// Остаток задержки сразу после выбора варианта (до первого фикса): прибытие
/// обязано совпасть со временем варианта, объезд мерится только живыми.
final class InitialRemainingDelayTests: XCTestCase {

    func testMixedDelayGoesToArrivalNotToDetourMeasure() {
        // 33C: живые на ближние 15 минут + профиль — смешанный источник.
        let split = RouteService.initialRemainingDelays(600, source: .mixed)
        XCTAssertEqual(split.live, 0, "объезд до фикса — без смешанного времени: выигрыш не выдумывается")
        XCTAssertEqual(split.typical, 600, "прибытие = время варианта, а не граф")
    }

    func testLiveAndTypicalKeepTheirSides() {
        XCTAssertEqual(RouteService.initialRemainingDelays(300, source: .live).live, 300)
        XCTAssertEqual(RouteService.initialRemainingDelays(300, source: .live).typical, 0)
        XCTAssertEqual(RouteService.initialRemainingDelays(300, source: .typical).typical, 300)
        XCTAssertEqual(RouteService.initialRemainingDelays(300, source: .typical).live, 0)
    }

    func testNoDataIsZero() {
        let split = RouteService.initialRemainingDelays(nil, source: nil)
        XCTAssertEqual(split.live, 0)
        XCTAssertEqual(split.typical, 0)
    }
}
