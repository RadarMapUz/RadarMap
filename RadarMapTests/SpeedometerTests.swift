//
//  SpeedometerTests.swift
//  RadarMapTests
//
//  Цифра скорости в сборе (Speedometer = Standstill + SpeedSmoother +
//  SpeedBound) на сценариях жалобы 21.10 «спидометр при остановке работает
//  некорректно»: CarPlay у стоп-линии показывал 3 км/ч. Требования 25.C:
//  встали — ноль не позже ~2 с; тронулись — число через ≤ 1 с; без фиксов —
//  цифра гаснет, а не висит; шум на месте не даёт 3–8 км/ч; ползание в
//  пробке 5 км/ч не обнуляется.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class SpeedometerTests: XCTestCase {

    private let spot = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    /// Фильтр расстояния экрана, на который смотрят (CarPlay, открытый
    /// телефон): его нет ни на одной ступени лестницы.
    private let watchedFilter = GPSTiers.request(tier: 3, watched: true).distanceFilter

    /// Точка в `north` метрах к северу от `spot` (и `east` к востоку).
    private func at(_ north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: spot.latitude + north / 111_320,
                               longitude: spot.longitude + east / (111_320 * cos(spot.latitude * .pi / 180)))
    }

    /// Доплер стоящего приёмника в городе: 2–7 км/ч, без двух «быстрых»
    /// подряд (два подряд не медленнее 6 км/ч — это и вправду тронулись).
    private let noise: [Double] = [3, 4.5, 2, 6.5, 3.5, 5, 2.5, 7, 4, 3]
    /// Положение стоящего приёмника: дрожит в пределах полуметра.
    private func wobble(_ i: Int) -> (north: Double, east: Double) {
        (Double((i * 7) % 5) * 0.25 - 0.5, Double((i * 3) % 5) * 0.2 - 0.4)
    }

    // MARK: - Светофор: торможение → ноль → старт

    /// 40 км/ч, торможение 2 м/с² до полной остановки, 30 с у стоп-линии с
    /// доплеровским шумом, старт с 2 м/с². Фиксы раз в секунду (экран машины).
    func testTrafficLight() {
        for sigma in [-1.0, 1.0] {   // погрешность доплера неизвестна / 1 м/с стоя
            var meter = Speedometer()
            var t = 0.0, pos = -60.0, v = 40 / 3.6
            // Торможение: фикс раз в секунду.
            while v > 0 {
                meter.fix(at(pos), rawKmh: v * 3.6, speedAccuracyKmh: sigma < 0 ? -1 : 1.8,
                          accuracy: 5, course: 0, at: t0.addingTimeInterval(t))
                let dt = min(1, v / 2)
                pos += v * dt - dt * dt   // a = 2 м/с²
                v = max(0, v - 2 * dt)
                t += dt
            }
            let stoppedAt = t
            // Стоим: шум 2–7 км/ч, погрешность доплера стоя — 1 м/с (3,6 км/ч).
            var standing = 0
            while t < stoppedAt + 30 {
                t = (t + 1).rounded(.down)
                let w = wobble(standing)
                let shown = meter.fix(at(pos + w.north, east: w.east), rawKmh: noise[standing % noise.count],
                                      speedAccuracyKmh: sigma < 0 ? -1 : 3.6, accuracy: 6, course: -1,
                                      at: t0.addingTimeInterval(t))
                if t - stoppedAt > 2 {
                    XCTAssertEqual(shown, 0, "σ \(sigma): стоим \(t - stoppedAt) с — ноль")
                }
                standing += 1
            }
            XCTAssertTrue(meter.standstill.isStopped)
            // Старт: 2 м/с² — через секунду 7,2 км/ч, через две 14,4.
            let first = meter.fix(at(pos + 1), rawKmh: 7.2, speedAccuracyKmh: sigma < 0 ? -1 : 1.8,
                                  accuracy: 5, course: 0, at: t0.addingTimeInterval(t + 1))
            let second = meter.fix(at(pos + 4), rawKmh: 14.4, speedAccuracyKmh: sigma < 0 ? -1 : 1.8,
                                   accuracy: 5, course: 0, at: t0.addingTimeInterval(t + 2))
            if sigma > 0 {
                XCTAssertEqual(first, 7.2, accuracy: 0.01, "уверенный доплер — число через секунду после старта")
            } else {
                XCTAssertEqual(first, 0, "без погрешности один фикс может быть выбросом")
            }
            XCTAssertEqual(second, 14.4, accuracy: 0.01, "через две секунды — в любом случае")
        }
    }

    // MARK: - Шум на месте

    /// Стоим с самого начала, доплер 2–7 км/ч: после первых двух секунд — ни
    /// одного ненулевого показания за минуту, и стрелка не уходит.
    func testNoiseOnTheSpotReadsZero() {
        // Погрешность стоя: неизвестна, 3,6 и 2,5 км/ч (доплер ниже трёх
        // погрешностей — не «тронулись»).
        for sigma in [-1.0, 3.6, 2.5] {
            var meter = Speedometer()
            for i in 0..<60 {
                let w = wobble(i)
                let shown = meter.fix(at(w.north, east: w.east), rawKmh: noise[i % noise.count],
                                      speedAccuracyKmh: sigma, accuracy: 8, course: Double((i * 70) % 360),
                                      at: t0.addingTimeInterval(Double(i)))
                if i >= 3 { XCTAssertEqual(shown, 0, "σ \(sigma), t=\(i)") }
            }
            XCTAssertTrue(meter.standstill.isStopped, "σ \(sigma)")
        }
    }

    /// Доплер в пределах своей погрешности — ноль на экране сразу, ещё до
    /// того, как стоянка наберёт свои две секунды.
    func testDopplerWithinItsErrorShowsZero() {
        var meter = Speedometer()
        meter.fix(at(-10), rawKmh: 12, speedAccuracyKmh: 1.5, accuracy: 5, course: 0, at: t0)
        let shown = meter.fix(at(-8), rawKmh: 4, speedAccuracyKmh: 4.5, accuracy: 5, course: 0,
                              at: t0.addingTimeInterval(1))
        XCTAssertEqual(shown, 0)
    }

    /// Прежний вход в стоянку требовал КАЖДЫЙ фикс ниже 3,5 км/ч две секунды
    /// подряд. Шум выше порога через раз обнулял отсчёт — стоянка не
    /// наступала, и на экране висели «3–5 км/ч» (снимок CarPlay 21.10).
    func testNoiseStraddlingTheOldThresholdStillStops() {
        var s = Standstill()
        let kmh: [Double] = [3, 4.5, 3, 4.5, 3, 4.5, 3]
        for (i, v) in kmh.enumerated() {
            s.update(at(Double(i % 2) * 0.4), rawKmh: v, accuracy: 6, course: -1,
                     at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertTrue(s.isStopped)
    }

    // MARK: - Пропуск фиксов на стоянке

    /// Встали, и фиксы пропали на 10 с (паркинг, телефон в держателе
    /// развернуло): последняя цифра — шумные 5 км/ч. Без фильтра (экран
    /// машины), с фильтром в кармане и с CoreMotion — ноль, а не 5 до
    /// следующего фикса.
    func testTenSecondGapWhileParked() {
        for (filter, motion, zeroBy) in [(watchedFilter, false, 3.0), (30.0, false, 3.0), (30.0, true, 2.0)] {
            var meter = Speedometer()
            meter.fix(at(-20), rawKmh: 15, speedAccuracyKmh: 1.5, accuracy: 5, course: 0, at: t0)
            meter.fix(at(-17), rawKmh: 5, speedAccuracyKmh: 1.5, accuracy: 5, course: 0,
                      at: t0.addingTimeInterval(1))
            var zeroAt: Double?
            for second in 2...11 {
                let now = Double(second)
                let shown = meter.silence(at: t0.addingTimeInterval(now), distanceFilter: filter,
                                          accuracy: 5, motionStationary: motion)
                if shown == 0, zeroAt == nil { zeroAt = now - 1 }
            }
            XCTAssertNotNil(zeroAt, "фильтр \(filter), CoreMotion \(motion)")
            XCTAssertLessThanOrEqual(zeroAt ?? .infinity, zeroBy, "фильтр \(filter), CoreMotion \(motion)")
            XCTAssertTrue(meter.standstill.isStopped, "погасла — стоим: следующий шумный фикс стрелку не сдвинет")
        }
    }

    /// Фиксы идут, но без доплера (Wi-Fi стоя): цифра 6 км/ч не висит, пока
    /// они идут, — стоянка по положению и затухание по времени доплера.
    func testFixesWithoutSpeedWhileParked() {
        var meter = Speedometer()
        meter.fix(at(-3), rawKmh: 6, speedAccuracyKmh: 1.5, accuracy: 8, course: 0, at: t0)
        var shown = 6.0
        for second in 1...6 {
            let now = t0.addingTimeInterval(Double(second))
            meter.fix(at(Double(second % 2)), rawKmh: -1, accuracy: 15, course: -1, at: now)
            shown = meter.silence(at: now.addingTimeInterval(0.9), distanceFilter: watchedFilter, accuracy: 15)
        }
        XCTAssertEqual(shown, 0)
    }

    // MARK: - Ползание в пробке

    /// Пробка: 20 км/ч, потом минута ползком 5 км/ч с обычной на ходу
    /// погрешностью доплера и дрожью положения. Ни одного нуля — ползём.
    func testCrawlInAJamIsNotZeroed() {
        for sigma in [-1.0, 1.8] {
            var meter = Speedometer()
            var pos = -100.0
            meter.fix(at(pos), rawKmh: 20, speedAccuracyKmh: sigma, accuracy: 5, course: 0, at: t0)
            for i in 1...60 {
                pos += 5 / 3.6
                let w = wobble(i)
                let shown = meter.fix(at(pos + w.north * 0.6, east: w.east * 0.6), rawKmh: 5 + Double(i % 3 - 1) * 0.5,
                                      speedAccuracyKmh: sigma, accuracy: 6, course: 0,
                                      at: t0.addingTimeInterval(Double(i)))
                XCTAssertGreaterThan(shown, 3, "σ \(sigma), t=\(i): ползём, а не стоим")
                // Между фиксами (секунда) цифра тоже не гаснет.
                XCTAssertGreaterThan(meter.silence(at: t0.addingTimeInterval(Double(i) + 0.9),
                                                   distanceFilter: watchedFilter, accuracy: 6), 3)
            }
            XCTAssertFalse(meter.standstill.isStopped, "σ \(sigma)")
        }
    }

    /// Стояли, поползли 5 км/ч: стоянка отпускает по смещению за несколько
    /// секунд, а не только после 15 м.
    func testCrawlOffAStopShowsUp() {
        var meter = Speedometer()
        for i in 0..<5 {
            meter.fix(at(0), rawKmh: 1, speedAccuracyKmh: 1.8, accuracy: 5, course: -1,
                      at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertTrue(meter.standstill.isStopped)
        var shownAt: Int?
        for i in 1...15 {
            let shown = meter.fix(at(Double(i) * 5 / 3.6), rawKmh: 5, speedAccuracyKmh: 1.8, accuracy: 5,
                                  course: 0, at: t0.addingTimeInterval(Double(4 + i)))
            if shown > 0 { shownAt = i; break }
        }
        XCTAssertNotNil(shownAt)
        XCTAssertLessThanOrEqual(shownAt ?? .max, 6, "8 м ползком — уже не шум")
    }

    // MARK: - CarPlay без поездки

    /// Машина подключена, поездки нет: лестница точности та же, что в
    /// поездке, фильтра расстояния нет ни на одной ступени — спидометр живёт
    /// каждую секунду и стоя. Сигнал пропал: низкая скорость гаснет через
    /// 2,5 с, высокая держится до окна «нет сигнала» (радиус оповещения не
    /// сжимается от одного пропуска на трассе).
    func testCarPlayWithoutATrip() {
        for tier in 0...3 {
            XCTAssertLessThanOrEqual(GPSTiers.request(tier: tier, watched: true).distanceFilter, 0, "тир \(tier)")
        }
        var slow = Speedometer()
        slow.fix(at(0), rawKmh: 11, speedAccuracyKmh: 1.5, accuracy: 5, course: 0, at: t0)
        XCTAssertEqual(slow.silence(at: t0.addingTimeInterval(2), distanceFilter: watchedFilter, accuracy: 5), 11)
        XCTAssertEqual(slow.silence(at: t0.addingTimeInterval(3), distanceFilter: watchedFilter, accuracy: 5), 0)

        var fast = Speedometer()
        fast.fix(at(0), rawKmh: 90, speedAccuracyKmh: 1, accuracy: 5, course: 0, at: t0)
        XCTAssertEqual(fast.silence(at: t0.addingTimeInterval(7), distanceFilter: watchedFilter, accuracy: 5), 90)
        XCTAssertEqual(fast.silence(at: t0.addingTimeInterval(9), distanceFilter: watchedFilter, accuracy: 5), 0)
    }

    // MARK: - Оповещения и проезды не в худшую сторону

    /// На ходу Speedometer — ровно прежний SpeedSmoother: цифра, которую
    /// читают радиус оповещения, превышение и запись проезда, не меняется ни
    /// на одном фикс выше порога шума.
    func testDrivingNumbersMatchTheSmoother() {
        var meter = Speedometer()
        var smoother = SpeedSmoother()
        let speeds: [Double] = [62, 60, 61, 58, 72, 70, 45, 47, 30, 31, 55, 90, 88, 12, 9, 25]
        for (i, kmh) in speeds.enumerated() {
            let now = t0.addingTimeInterval(Double(i))
            let shown = meter.fix(at(Double(i) * 15), rawKmh: kmh, speedAccuracyKmh: 1.5, accuracy: 5,
                                  course: 0, at: now)
            XCTAssertEqual(shown, smoother.update(rawKmh: kmh, at: now), accuracy: 1e-9, "t=\(i)")
        }
    }
}
