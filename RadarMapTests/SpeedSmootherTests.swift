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

    /// Молчание с фильтром расстояния — верхняя граница: за t секунд машина
    /// проехала меньше фильтра. 40 км/ч при фильтре 25 м: фикс раз в 2,25 с,
    /// через 3 с молчания — не больше 30 км/ч, через 40 с — ноль.
    func testSilenceBoundsTheSpeed() {
        XCTAssertEqual(SpeedBound.capped(40, distanceFilter: 25, secondsSinceFix: 1), 40, "обычный интервал")
        XCTAssertEqual(SpeedBound.capped(40, distanceFilter: 25, secondsSinceFix: 3), 30, accuracy: 0.01)
        XCTAssertEqual(SpeedBound.capped(40, distanceFilter: 25, secondsSinceFix: 40), 0)
    }

    /// Стоим у светофора: последний фикс торможения — 13 км/ч, дальше фиксов
    /// нет (distanceFilter 6 м). Прежняя граница держала 7,2 км/ч на 3-й
    /// секунде и 3 км/ч на 7-й; низкая скорость и молчание дольше полутора
    /// интервалов фиксов — это остановка: ноль (25.C).
    func testLowSpeedSilenceWithAFilterIsAStop() {
        XCTAssertEqual(SpeedBound.capped(13, distanceFilter: 6, secondsSinceFix: 1), 13, "обычный интервал")
        XCTAssertEqual(SpeedBound.capped(13, distanceFilter: 6, secondsSinceFix: 3), 0)
        // 12 км/ч при фильтре 25: фикс раз в 7,5 с — до 11,25 с честная
        // граница, дольше — ноль.
        XCTAssertEqual(SpeedBound.capped(12, distanceFilter: 25, secondsSinceFix: 10), 9, accuracy: 0.01)
        XCTAssertEqual(SpeedBound.capped(12, distanceFilter: 25, secondsSinceFix: 12), 0)
        // Ниже порога шума цифра сама могла быть шумом: ноль через 2,5 с
        // молчания при любом фильтре.
        XCTAssertEqual(SpeedBound.capped(5, distanceFilter: 30, secondsSinceFix: 2), 5)
        XCTAssertEqual(SpeedBound.capped(5, distanceFilter: 30, secondsSinceFix: 3), 0)
    }

    /// CoreMotion уверен, что стоим, — на низкой скорости ноль сразу после
    /// обычного интервала; на ходу его мнение цифру не трогает.
    func testMotionStationaryZeroesOnlyALowSpeed() {
        XCTAssertEqual(SpeedBound.capped(9, distanceFilter: -1, secondsSinceFix: 2, motionStationary: true), 0)
        XCTAssertEqual(SpeedBound.capped(9, distanceFilter: -1, secondsSinceFix: 1, motionStationary: true), 9)
        XCTAssertEqual(SpeedBound.capped(60, distanceFilter: -1, secondsSinceFix: 2, motionStationary: true), 60)
    }

    /// Без фильтра (экран, CarPlay) низкая скорость без фиксов — ноль через
    /// 2,5 с, а не через 8 (окно «нет сигнала» для высокой).
    func testNoFilterLowSpeedSilenceIsAStop() {
        XCTAssertEqual(SpeedBound.capped(9, distanceFilter: -1, secondsSinceFix: 2), 9)
        XCTAssertEqual(SpeedBound.capped(9, distanceFilter: -1, secondsSinceFix: 3), 0)
        XCTAssertEqual(SpeedBound.capped(30, distanceFilter: -1, secondsSinceFix: 3), 30, "на ходу — окно «нет сигнала»")
    }

    /// Фиксы без доплера идут, а скорость — нет: стоя (точка на месте) цифра
    /// гаснет по времени последнего доплера; если точка уходит — едем без
    /// доплера, цифру держим.
    func testFixesWithoutSpeedDoNotHoldACrawl() {
        XCTAssertEqual(SpeedBound.capped(8, distanceFilter: -1, secondsSinceFix: 0.5,
                                         secondsSinceSpeed: 3, movedSinceSpeed: 4, accuracy: 10), 0)
        XCTAssertEqual(SpeedBound.capped(8, distanceFilter: -1, secondsSinceFix: 0.5,
                                         secondsSinceSpeed: 3, movedSinceSpeed: 25, accuracy: 10), 8)
    }

    /// На ходу граница ничего не отнимает: 60 км/ч при фильтре 25 м — фикс
    /// раз в 1,5 с, и за 2 с молчания граница 45 км/ч не опровергает быструю
    /// трассу сильнее, чем позволяет физика.
    func testBoundNeverRaisesSpeed() {
        XCTAssertEqual(SpeedBound.capped(5, distanceFilter: 30, secondsSinceFix: 2), 5)
        XCTAssertEqual(SpeedBound.capped(0, distanceFilter: 6, secondsSinceFix: 20), 0)
    }

    /// Экран открыт или CarPlay — фильтра нет: молчание GPS — потеря
    /// сигнала, а не «проехали меньше фильтра». На 90 км/ч пропущенный фикс
    /// (2 с) и даже 7 с под эстакадой — цифра та же; дольше окна «нет
    /// сигнала» — ноль, а не вечные 15 под землёй (сценарий S8, ревью 20.10).
    func testNoFilterSilenceHoldsThenZero() {
        XCTAssertEqual(SpeedBound.capped(90, distanceFilter: -1, secondsSinceFix: 2), 90)
        XCTAssertEqual(SpeedBound.capped(90, distanceFilter: -1, secondsSinceFix: 7), 90)
        XCTAssertEqual(SpeedBound.capped(90, distanceFilter: -1, secondsSinceFix: 9), 0)
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
