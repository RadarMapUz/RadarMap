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

    // MARK: - Без фиксов (SpeedBound)

    /// Стоим у светофора: последний фикс торможения — 13 км/ч, дальше фиксов
    /// нет (distanceFilter 6 м). Через 3 с машина проехала меньше 6 м —
    /// скорость не больше 7,2 км/ч; через 10 с — ноль, а не вечные 13.
    func testSilenceBoundsTheSpeed() {
        XCTAssertEqual(SpeedBound.capped(13, distanceFilter: 6, secondsSinceFix: 1), 13, "обычный интервал")
        XCTAssertEqual(SpeedBound.capped(13, distanceFilter: 6, secondsSinceFix: 3), 7.2, accuracy: 0.01)
        XCTAssertEqual(SpeedBound.capped(13, distanceFilter: 6, secondsSinceFix: 10), 0)
    }

    /// На ходу граница ничего не отнимает: 60 км/ч при фильтре 25 м — фикс
    /// раз в 1,5 с, и за 2 с молчания граница 45 км/ч не опровергает быструю
    /// трассу сильнее, чем позволяет физика.
    func testBoundNeverRaisesSpeed() {
        XCTAssertEqual(SpeedBound.capped(5, distanceFilter: 30, secondsSinceFix: 2), 5)
        XCTAssertEqual(SpeedBound.capped(0, distanceFilter: 6, secondsSinceFix: 20), 0)
    }

    /// Экран открыт или CarPlay — фильтра нет, фиксы раз в секунду и стоя.
    /// Подземный паркинг на 15 км/ч: через 5 с молчания цифра уже не 15, через
    /// 20 с — ноль (сценарий S8, 20.10; раньше она застывала навсегда).
    func testNoFilterSilenceStillBoundsTheSpeed() {
        XCTAssertEqual(SpeedBound.capped(15, distanceFilter: -1, secondsSinceFix: 1), 15, "обычный интервал")
        XCTAssertEqual(SpeedBound.capped(15, distanceFilter: -1, secondsSinceFix: 5), 7.2, accuracy: 0.01)
        XCTAssertEqual(SpeedBound.capped(15, distanceFilter: -1, secondsSinceFix: 20), 0)
    }

    /// Сторож «нет сигнала»: на ходу — всегда; стоя — только когда фиксы
    /// обязаны идти и стоя (фильтра нет).
    func testStaleWatchdogArmsAtAnySpeedWithoutAFilter() {
        XCTAssertTrue(LocationService.watchdogArms(speedKmh: 50, distanceFilter: 25))
        XCTAssertFalse(LocationService.watchdogArms(speedKmh: 15, distanceFilter: 25), "в кармане стоя фиксов нет из-за фильтра")
        XCTAssertTrue(LocationService.watchdogArms(speedKmh: 15, distanceFilter: -1))
        XCTAssertTrue(LocationService.watchdogArms(speedKmh: 0, distanceFilter: -1))
    }
}
