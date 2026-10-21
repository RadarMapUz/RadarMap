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

    /// Маршрут без сети (12б.10): подъезд к трассе — прямая через кварталы до
    /// трёх километров, и улицы к ней уходят от неё на сотни метров. С
    /// обычным порогом это перестраивало без конца — та же прямая от новой
    /// точки и «Маршрут перестроен» каждые полминуты (ревью 14.2). Свой порог
    /// пропускает улицы, но не другую трассу.
    func testOfflineRouteToleratesItsStraightApproach() {
        let limit = AppConfig.offlineRouteRerouteMeters
        let ticks = AppConfig.rerouteConfirmTicks
        var gate = RerouteGate()
        let streets = Array(repeating: 900.0, count: 3 * ticks)
        XCTAssertEqual(streets.enumerated().filter { index, deviation in
            gate.note(deviation: deviation, now: t0.addingTimeInterval(Double(index) * 30), limit: limit)
        }.count, 0, "в 900 м от прямой подъезда — ещё не съезд")
        XCTAssertEqual(gate.offRouteTicks, 0)
        var elsewhere = RerouteGate()
        let gone = Array(repeating: limit + 500, count: ticks)
        XCTAssertEqual(gone.enumerated().filter { index, deviation in
            elsewhere.note(deviation: deviation, now: t0.addingTimeInterval(Double(index)), limit: limit)
        }.map(\.offset), [ticks - 1], "ушли на другую трассу — перестраиваем")
        // Обычный маршрут — прежние 150 м.
        var regular = RerouteGate()
        XCTAssertFalse(run(&regular, Array(repeating: 900.0, count: ticks)).isEmpty)
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

    // MARK: - Устойчивый съезд (снимок CarPlay 21.10, 08:28)

    private func runDrift(_ gate: inout RerouteGate, _ deviations: [Double]) -> [Int] {
        deviations.enumerated().compactMap { index, deviation in
            gate.note(deviation: deviation, now: t0.addingTimeInterval(Double(index)),
                      drift: AppConfig.rerouteDriftMeters) ? index : nil
        }
    }

    /// Свернул мимо: отклонения из прогона в симуляторе (поворот направо
    /// вместо прямо, 31 км/ч). Проекция цепляется за попутный кусок маршрута
    /// впереди, и отклонение пляшет вокруг 150 м — три фикса подряд за ним
    /// не набирались, перестроение ждало 15 с. Устойчивые 50+ м — съезд.
    func testTurnOffWithDancingDeviationRebuildsEarly() {
        let recorded: [Double] = [0, 8, 12, 55, 56, 82, 122, 126, 72, 155, 133, 106, 96, 118, 152, 214, 167]
        var old = RerouteGate()
        XCTAssertEqual(run(&old, recorded), [16], "без правила — только на шестнадцатом фиксе")
        var gate = RerouteGate()
        XCTAssertEqual(runDrift(&gate, recorded), [6],
                       "четвёртый фикс подряд дальше \(AppConfig.rerouteDriftMeters) м")
    }

    /// Дублёр проспекта (15–40 м от оси) и шум — не съезд, сколько ни едь.
    func testServiceRoadAndNoiseDoNotRebuild() {
        var gate = RerouteGate()
        XCTAssertEqual(runDrift(&gate, Array(repeating: 40, count: 60)), [])
        var noisy = RerouteGate()
        let spikes = (0..<40).map { $0 % AppConfig.rerouteDriftTicks == 0 ? 10.0 : 90.0 }
        XCTAssertEqual(runDrift(&noisy, spikes), [], "выброс короче \(AppConfig.rerouteDriftTicks) фиксов")
        XCTAssertEqual(noisy.driftTicks, AppConfig.rerouteDriftTicks - 1)
    }

    /// Устойчивый съезд подчиняется той же паузе после перестроения.
    func testDriftRespectsTheCooldown() {
        var gate = RerouteGate()
        let ticks = AppConfig.rerouteDriftTicks
        XCTAssertEqual(runDrift(&gate, Array(repeating: 80, count: ticks)), [ticks - 1])
        let after = (0..<10).compactMap { index -> Int? in
            gate.note(deviation: 80, now: t0.addingTimeInterval(Double(ticks + index)),
                      drift: AppConfig.rerouteDriftMeters) ? index : nil
        }
        XCTAssertEqual(after, [], "в паузе \(AppConfig.rerouteCooldownSeconds) с — не перестраиваем")
        gate.resetTicks()
        XCTAssertEqual(gate.driftTicks, 0)
    }
}
