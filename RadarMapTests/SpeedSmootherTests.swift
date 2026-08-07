//
//  SpeedSmootherTests.swift
//  RadarMapTests
//
//  Спидометр: сгладить шум, не пряча динамику. Родился из реальной поездки —
//  прежние константные веса (0.6 старого) на редких тиках адаптивного GPS
//  растягивали хвост торможения на 5+ секунд, и цифра «ехала», когда водитель
//  уже стоял на педали.
//

import XCTest
@testable import RadarMap

final class SpeedSmootherTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Крейсерский шум ±2–3 км/ч сглаживается: выход спокойнее входа.
    func testCruiseNoiseIsSmoothed() {
        var smoother = SpeedSmoother()
        _ = smoother.update(rawKmh: 69, at: t0)
        let a = smoother.update(rawKmh: 71, at: t0.addingTimeInterval(1))
        let b = smoother.update(rawKmh: 68, at: t0.addingTimeInterval(2))
        // Не прыгаем на сырое значение целиком…
        XCTAssertLessThan(a, 71)
        XCTAssertGreaterThan(b, 68)
        // …но и не отстаём заметно.
        XCTAssertGreaterThan(a, 69.5)
    }

    /// Настоящее торможение — не шум: перепад больше порога показывается
    /// сразу. По этой цифре принимают решение у камеры.
    func testBrakingSnapsImmediately() {
        var smoother = SpeedSmoother()
        _ = smoother.update(rawKmh: 60, at: t0)
        XCTAssertEqual(smoother.update(rawKmh: 45, at: t0.addingTimeInterval(1)), 45)
        XCTAssertEqual(smoother.update(rawKmh: 28, at: t0.addingTimeInterval(2)), 28)
    }

    /// Редкий тик почти не сглаживает: за три секунды сглаживать уже нечего,
    /// старая скорость — устаревшее знание.
    func testRareTicksFollowRawClosely() {
        var smoother = SpeedSmoother()
        _ = smoother.update(rawKmh: 60, at: t0)
        // +5 км/ч (ниже порога снапа) через 3 секунды: почти всё расстояние
        // до сырого должно быть пройдено (α = 1 − exp(−3/0.7) ≈ 0.99).
        let out = smoother.update(rawKmh: 65, at: t0.addingTimeInterval(3))
        XCTAssertGreaterThan(out, 64.5)
    }

    /// Частые тики сглаживают сильнее редких — вес по времени, не по номеру.
    func testSmoothingDependsOnTimeNotTickCount() {
        var fast = SpeedSmoother()
        _ = fast.update(rawKmh: 60, at: t0)
        let after02 = fast.update(rawKmh: 65, at: t0.addingTimeInterval(0.2))

        var slow = SpeedSmoother()
        _ = slow.update(rawKmh: 60, at: t0)
        let after2 = slow.update(rawKmh: 65, at: t0.addingTimeInterval(2))

        XCTAssertLessThan(after02, after2, "короткий интервал должен сглаживать сильнее")
    }

    /// После паузы (туннель) прошлое значение устарело — берём сырое.
    func testStaleGapResetsToRaw() {
        var smoother = SpeedSmoother()
        _ = smoother.update(rawKmh: 60, at: t0)
        XCTAssertEqual(smoother.update(rawKmh: 62, at: t0.addingTimeInterval(10)), 62)
    }

    /// Дрожь стоящего GPS не читается как «ползу»: ниже 1 км/ч — ноль.
    func testStandingShowsZero() {
        var smoother = SpeedSmoother()
        XCTAssertEqual(smoother.update(rawKmh: 0.6, at: t0), 0)
        XCTAssertEqual(smoother.update(rawKmh: 0.8, at: t0.addingTimeInterval(1)), 0)
    }

    /// Сброс: первое значение после смены режима — сырое, без сглаживания
    /// со скоростью из прошлой жизни.
    func testResetForgetsHistory() {
        var smoother = SpeedSmoother()
        _ = smoother.update(rawKmh: 60, at: t0)
        smoother.reset()
        XCTAssertEqual(smoother.update(rawKmh: 62, at: t0.addingTimeInterval(1)), 62)
    }
}
