//
//  RerouteGateTests.swift
//  RadarMapTests
//
//  Сценарий A6 (12в): съезд с маршрута → перестроение; шум GPS и возврат
//  на линию — без лишнего перестроения; неудачи удваивают паузу.
//

import XCTest
@testable import RadarMap

final class RerouteGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let off = AppConfig.rerouteDeviationMeters + 50
    private let on = 10.0

    private func run(_ gate: inout RerouteGate, _ deviations: [Double], from start: TimeInterval = 0) -> [Int] {
        deviations.enumerated().compactMap { index, deviation in
            gate.note(deviation: deviation, now: t0.addingTimeInterval(start + Double(index))) ? index : nil
        }
    }

    func testRealDetourRebuildsAfterConfirmation() {
        var gate = RerouteGate()
        let ticks = AppConfig.rerouteConfirmTicks
        XCTAssertEqual(run(&gate, Array(repeating: on, count: 5) + Array(repeating: off, count: ticks)), [5 + ticks - 1])
    }

    func testNoiseAndReturnToTheLineDoNotRebuild() {
        var gate = RerouteGate()
        // Выброс на 2 фикса и обратно на линию — дважды подряд: счёт с нуля.
        XCTAssertEqual(run(&gate, [on, off, off, on, off, off, on, on]), [])
        XCTAssertEqual(gate.offRouteTicks, 0)
    }

    func testCooldownAfterARebuildAndBackoffOnFailures() {
        var gate = RerouteGate()
        let ticks = AppConfig.rerouteConfirmTicks
        XCTAssertFalse(run(&gate, Array(repeating: off, count: ticks)).isEmpty)
        // Ещё в объезде сразу после перестроения — пауза.
        XCTAssertEqual(run(&gate, Array(repeating: off, count: 10), from: Double(ticks)), [])
        // Неудача удваивает паузу: через обычные 20 с — рано, через 40+ — можно.
        gate.noteFailure()
        let base = AppConfig.rerouteCooldownSeconds
        XCTAssertEqual(run(&gate, Array(repeating: off, count: ticks), from: base + 5), [])
        XCTAssertFalse(run(&gate, Array(repeating: off, count: ticks), from: 2 * base + 10).isEmpty)
        gate.noteSuccess()
        XCTAssertEqual(gate.failures, 0)
    }
}
