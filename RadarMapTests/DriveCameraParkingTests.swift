//
//  DriveCameraParkingTests.swift
//  RadarMapTests
//
//  Кадр на стоянке (85, «при остановке болтается»): минута шума GPS не
//  двигает ни масштаб, ни наклон, ни машину на экране, ни поворот карты;
//  старт с места отпускает кадр за ≤ 1,5 с.
//

import XCTest
@testable import RadarMap

final class DriveCameraParkingTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let latitude = 41.31
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private struct Screen {
        let name: String
        let kind: Cam.Screen
        let height: Double
        let clear: Cam.Clear
        let carY: (Double) -> Double
    }

    private let screens: [Screen] = [
        Screen(name: "машина 940×471", kind: .car, height: 471,
               clear: CarPlaySurface.carClear(width: 940, height: 471, safeTop: 50, safeBottom: 0, side: 60),
               carY: { CarPlaySurface.carMeY(height: 471, safeTop: 50, safeBottom: 0, share: $0) }),
        Screen(name: "машина 1015×382", kind: .car, height: 382,
               clear: CarPlaySurface.carClear(width: 1015, height: 382, safeTop: 50, safeBottom: 0, side: 60),
               carY: { CarPlaySurface.carMeY(height: 382, safeTop: 50, safeBottom: 0, share: $0) }),
        Screen(name: "телефон", kind: .phone, height: 760,
               clear: Cam.Clear(top: 0.17, bottom: 0.12, width: 402, side: 60), carY: { _ in 0.724 }),
    ]

    private struct Noise {
        var x: UInt64
        mutating func next() -> Double {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return Double(x % 1_000_000) / 1_000_000
        }
    }

    private struct Run {
        var zooms: [Double] = []
        var pitches: [Double] = []
        /// Машина и точка взгляда на экране, точки.
        var rows: [Double] = []
        var headings: [Double] = []
        /// Секунд от первого фикса на ходу до отпуска кадра.
        var release: Double?

        func span(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
    }

    /// Подъезд 30 км/ч, стоим у светофора `standSeconds` с шумом (позиция ±9 м,
    /// доплер 0–`kmhNoise`, курс — какой угодно), затем разгон 2 м/с².
    /// Развилка в ~100 м, ближайшая камера сбоку в 136 м. Мерки — минута стоянки
    /// после того, как кадр устоялся.
    private func run(_ s: Screen, parking: Bool, kmhNoise: Double = 4, seed: UInt64) -> Run {
        var noise = Noise(x: seed)
        var tracker = StopView.Tracker()
        var smoother = Cam.Smoother()
        var park = Cam.Parking()
        var result = Run()
        var firstMove: Double?
        let standSeconds = 120.0
        var along = -60.0
        var t = 0.0
        while t <= standSeconds + 20 {
            let real = t < 6 ? 30 * (1 - t / 6) : t < standSeconds ? 0 : min(40, (t - standSeconds) * 7.2)
            along += real / 3.6
            let standing = t >= 6 && t < standSeconds
            let dx = standing ? (noise.next() * 2 - 1) * 9 : 0
            let dy = standing ? (noise.next() * 2 - 1) * 9 : 0
            let kmh = standing ? noise.next() * kmhNoise : real
            let rawCourse = standing ? noise.next() * 360 : 90
            if t >= standSeconds, kmh > AppConfig.driveParkEnterKmh, firstMove == nil { firstMove = t }
            let now = t0 + t
            let stop = tracker.update(speedKmh: kmh, maneuverDistance: 70 - along - dx, active: true, at: now)
            var heading = rawCourse
            var live = Cam.Parking.Inputs(speedKmh: kmh, maneuverDistance: 70 - along - dx, keep: nil)
            if parking {
                park.update(speedKmh: kmh, course: rawCourse, at: now)
                heading = park.course(rawCourse)
            }
            // Смещение камеры — в осях карты: поворот карты поворачивает и его.
            let a = (heading - 90) * .pi / 180
            let f = 30 - along - dx, r = 136 - dy
            live.keep = Cam.Keep(forward: f * cos(a) + r * sin(a), right: -f * sin(a) + r * cos(a))
            let inputs = parking ? park.inputs(live, at: now) : live
            if parking, let go = firstMove, result.release == nil, !park.parked { result.release = t - go }
            let target = Cam.target(speedKmh: inputs.speedKmh, maneuverDistance: inputs.maneuverDistance,
                                    pitchAllowed: true, screen: s.kind, keep: inputs.keep, stop: stop,
                                    viewHeight: s.height, latitude: latitude, clear: s.clear, carY: s.carY)
            let frame = smoother.step(toward: target, at: now)
            if t >= 55, t <= 115 {
                result.zooms.append(frame.zoom)
                result.pitches.append(frame.pitchDegrees)
                let y = s.carY(frame.carShare)
                let span = Cam.span(zoom: frame.zoom, viewHeight: s.height, latitude: latitude)
                let ahead = Cam.centreAhead(spanMeters: span, anchorY: y, pitchDegrees: frame.pitchDegrees)
                result.rows.append(ahead / Cam.metersPerPoint(zoom: frame.zoom, latitude: latitude) + y * s.height)
                result.headings.append(heading)
            }
            t += 1
        }
        return result
    }

    private let seeds: [UInt64] = [0x9E37_79B9_7F4A_7C15, 0x1234_5678, 0xDEAD_BEEF, 0xC0FFEE, 0xABCD_EF01]

    func testMinuteOfNoiseFreezesTheFrame() {
        for s in screens {
            for seed in seeds {
                let r = run(s, parking: true, seed: seed)
                XCTAssertLessThan(r.span(r.zooms), 0.05, "\(s.name): масштаб")
                XCTAssertLessThan(r.span(r.pitches), 0.5, "\(s.name): наклон")
                XCTAssertLessThan(r.span(r.rows), 3, "\(s.name): машина и центр на экране")
                XCTAssertEqual(r.span(r.headings), 0, "\(s.name): поворот карты")
            }
        }
    }

    /// Причина: развилка по сырому прогрессу маршрута качала наклон спуска к
    /// ней, курс без движения крутил карту, а с ним — смещение камеры сбоку.
    func testWithoutParkingTheSameNoiseRocksTheFrame() {
        for s in screens {
            let r = run(s, parking: false, seed: seeds[0])
            XCTAssertGreaterThan(r.span(r.pitches), 1, "\(s.name): наклон гулял")
            XCTAssertGreaterThan(r.span(r.headings), 90, "\(s.name): карта крутилась")
        }
    }

    func testDopplerNoiseNeverReleasesTheFrame() {
        for s in screens {
            let r = run(s, parking: true, kmhNoise: 8, seed: seeds[1])
            XCTAssertLessThan(r.span(r.zooms), 0.05, s.name)
            XCTAssertEqual(r.span(r.headings), 0, s.name)
        }
    }

    func testStartReleasesTheFrameWithinASecondAndAHalf() {
        for s in screens {
            let r = run(s, parking: true, seed: seeds[2])
            XCTAssertNotNil(r.release, s.name)
            XCTAssertLessThanOrEqual(r.release ?? .infinity, 1.5, s.name)
        }
        // Мягкий разгон 1 м/с²: фиксы 3,6 — 7,2 — 10,8 — 14,4 км/ч.
        var park = parked()
        for (i, kmh) in [3.6, 7.2, 10.8, 14.4].enumerated() {
            park.update(speedKmh: kmh, course: 90, at: t0 + 100 + Double(i))
            if kmh >= AppConfig.driveParkExitFastKmh { XCTAssertFalse(park.parked, "разгон отпускает кадр") }
        }
        XCTAssertFalse(park.parked)
    }

    // MARK: - Удержание входов

    private func parked(course: Double = 75) -> Cam.Parking {
        var park = Cam.Parking()
        park.update(speedKmh: 20, course: course, at: t0)
        park.update(speedKmh: 0, course: 200, at: t0 + 1)
        park.update(speedKmh: 0, course: 310, at: t0 + 2)
        return park
    }

    func testCourseIsTheLastOneBeforeTheStop() {
        let park = parked(course: 75)
        XCTAssertTrue(park.parked)
        XCTAssertEqual(park.course(123), 75, "стоя курс шума карту не крутит")
        var moving = Cam.Parking()
        moving.update(speedKmh: 40, course: 10, at: t0)
        XCTAssertEqual(moving.course(123), 123, "на ходу — живой курс")
    }

    func testMovingPassesInputsThrough() {
        var park = Cam.Parking()
        park.update(speedKmh: 30, course: 0, at: t0)
        let live = Cam.Parking.Inputs(speedKmh: 30, maneuverDistance: 80, keep: Cam.Keep(forward: 50, right: 0))
        XCTAssertEqual(park.inputs(live, at: t0), live)
    }

    func testParkedHoldsNoiseButTakesARouteChangeAtOnce() {
        var park = parked()
        let first = park.inputs(.init(speedKmh: 3, maneuverDistance: 120, keep: Cam.Keep(forward: 30, right: 136)),
                                at: t0 + 3)
        XCTAssertEqual(first.speedKmh, 0, "стоя скорость — ноль: шум доплера не снимает камеру сбоку")
        let noisy = park.inputs(.init(speedKmh: 4, maneuverDistance: 110, keep: Cam.Keep(forward: 21, right: 129)),
                                at: t0 + 4)
        XCTAssertEqual(noisy, first, "шум держится")
        let rerouted = park.inputs(.init(speedKmh: 0, maneuverDistance: 400, keep: nil), at: t0 + 5)
        XCTAssertEqual(rerouted.maneuverDistance, 400, "другой маршрут — сразу")
        XCTAssertNil(rerouted.keep, "камера ушла — сразу")
    }

    func testParkedTakesARealShiftOnceItHolds() {
        var park = parked()
        _ = park.inputs(.init(speedKmh: 0, maneuverDistance: 120), at: t0 + 3)
        let early = park.inputs(.init(speedKmh: 0, maneuverDistance: 85), at: t0 + 4)
        XCTAssertEqual(early.maneuverDistance, 120, "дальше шума, но ещё не держится")
        let late = park.inputs(.init(speedKmh: 0, maneuverDistance: 85),
                               at: t0 + 4 + AppConfig.driveParkConfirmSeconds)
        XCTAssertEqual(late.maneuverDistance, 85, "держится — принято")
    }

    func testNoiseConstantsSitAboveTheNoise() {
        XCTAssertGreaterThan(AppConfig.driveParkEnterKmh, 4, "шум доплера стоя после Standstill")
        XCTAssertGreaterThan(AppConfig.driveParkExitKmh, AppConfig.standstillNoiseMaxKmh)
        XCTAssertGreaterThan(AppConfig.driveParkManeuverSlackMeters, 2 * 10, "шум позиции ±10 м")
    }
}
