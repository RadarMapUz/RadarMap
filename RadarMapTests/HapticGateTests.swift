//
//  HapticGateTests.swift
//  RadarMapTests
//
//  Чем трясти сейчас (HapticGate): сигнал никогда не ждёт запуск движка —
//  не готов, значит системный отклик немедленно (отчёт качества 22.10, п. 1).
//

import XCTest
@testable import RadarMap

final class HapticGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSignalNeverWaitsForTheEngine() {
        // Каждое состояние, кроме «запущен», отвечает системным откликом
        // сразу — синхронного запуска движка на пути сигнала нет вовсе.
        for state in [HapticGate.Engine.absent, .stopped, .starting] {
            XCTAssertEqual(HapticGate(engine: state).feel(enabled: true), .system, "\(state)")
        }
        XCTAssertEqual(HapticGate(engine: .running).feel(enabled: true), .engine)
    }

    func testDisabledHapticsStaySilentInAnyState() {
        for state in [HapticGate.Engine.absent, .stopped, .starting, .running] {
            XCTAssertEqual(HapticGate(engine: state).feel(enabled: false), .none, "\(state)")
        }
    }

    func testStartIsAsyncAndThrottledAfterFailure() {
        var gate = HapticGate(engine: .stopped)
        XCTAssertTrue(gate.shouldStart(now: t0))
        gate.startRequested(at: t0)
        XCTAssertEqual(gate.engine, .starting)
        XCTAssertFalse(gate.shouldStart(now: t0), "запуск уже в пути")
        XCTAssertEqual(gate.feel(enabled: true), .system, "пока запускается — системный отклик")
        // Фоновое пробуждение: CoreHaptics отказал — не просить старт каждый фикс.
        gate.startFinished(ok: false)
        XCTAssertEqual(gate.engine, .stopped)
        XCTAssertFalse(gate.shouldStart(now: t0.addingTimeInterval(AppConfig.hapticEngineRetrySeconds - 1)))
        XCTAssertTrue(gate.shouldStart(now: t0.addingTimeInterval(AppConfig.hapticEngineRetrySeconds)))
        gate.startRequested(at: t0.addingTimeInterval(AppConfig.hapticEngineRetrySeconds))
        gate.startFinished(ok: true)
        XCTAssertEqual(gate.feel(enabled: true), .engine)
    }

    func testIdleShutdownKeepsEngineAndOtherStopsRestart() {
        var gate = HapticGate(engine: .running)
        gate.stopped(idleTimeout: true)
        XCTAssertEqual(gate.engine, .running, "простой autoShutdown: железо поднимется само")
        gate.playFailed()
        XCTAssertEqual(gate.engine, .stopped, "не поднялось — к запуску")
        gate.startRequested(at: t0)
        gate.startFinished(ok: true)
        gate.stopped(idleTimeout: false)   // звонок, прерывание сессии
        XCTAssertEqual(gate.engine, .stopped)
        XCTAssertFalse(gate.shouldStart(now: t0.addingTimeInterval(1)), "пауза повтора")
        gate.reset()                       // сброс сервера — запускать сразу
        XCTAssertTrue(gate.shouldStart(now: t0.addingTimeInterval(1)))
    }

    func testAbsentEngineNeverStarts() {
        var gate = HapticGate(engine: .absent)
        XCTAssertFalse(gate.shouldStart(now: t0))
        gate.startRequested(at: t0)
        gate.startFinished(ok: true)
        gate.stopped(idleTimeout: true)
        gate.reset()
        XCTAssertEqual(gate.engine, .absent)
        XCTAssertEqual(gate.feel(enabled: true), .system)
    }

    func testWarmsOnApproachBeforeTheAlertRadius() {
        XCTAssertTrue(HapticGate.shouldWarm(distance: 400, radius: 400), "в радиусе оповещения")
        XCTAssertTrue(HapticGate.shouldWarm(distance: 590, radius: 400), "заранее, до первого сигнала")
        XCTAssertFalse(HapticGate.shouldWarm(distance: 900, radius: 400), "далеко — движок не будим")
    }
}
