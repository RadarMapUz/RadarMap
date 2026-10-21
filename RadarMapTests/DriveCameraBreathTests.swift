//
//  DriveCameraBreathTests.swift
//  RadarMapTests
//
//  Камера поездки без «дыхания» (25.A, владелец 21.10: «карта в CarPlay то
//  уменьшается, то увеличивается»). Замер до правки на тех же синтетических
//  поездках (DriveCameraSim): в городе кадр машины уходил до z11,5 и за минуту
//  гулял на 5,9 уровня, направление менялось через 0,5 с. Причины — камера,
//  которую только что проехали (позади «я» до дока 50 точек), камера соседней
//  улицы у порога гейтов 10 км/ч и камера в 400 м на 10 км/ч, — плюс
//  сглаживание, которое повторяло каждый скачок цели.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class DriveCameraBreathTests: XCTestCase {

    private typealias Cam = DriveCamera
    private typealias Sim = DriveCameraSim
    private let screens = [Sim.car(), Sim.car(height: 382, width: 1015), Sim.phone]

    private func eachRun(_ check: (Sim.Trip, Sim.Screen, Sim.Metrics) -> Void) {
        for trip in Sim.trips {
            for screen in screens {
                check(trip, screen, Sim.metrics(Sim.run(trip, on: screen), on: screen))
            }
        }
    }

    // MARK: - Поездки

    func testZoomSwingPerMinuteIsBounded() {
        // До правки: машина в городе 5,9 уровня за минуту, телефон на
        // развороте 3,7. Теперь размах держат пределы — нижний у камеры
        // (z15,5 в городе) и верхний стоя (z18 телефона, z17,2 машины).
        eachRun { trip, screen, m in
            let limit = screen.kind == .car ? 1.8 : 2.5
            XCTAssertLessThanOrEqual(m.swingPerMinute, limit, "\(trip.name), \(screen.name)")
            XCTAssertGreaterThanOrEqual(m.minZoom, 15.3, "\(trip.name), \(screen.name): не вид района")
        }
    }

    func testZoomDirectionChangesAtMostOnceInEightSeconds() {
        eachRun { trip, screen, m in
            XCTAssertGreaterThanOrEqual(m.shortestReversalGap, AppConfig.driveZoomReversalLock - 0.25,
                                        "\(trip.name), \(screen.name): \(m.reversals) смен")
        }
    }

    func testZoomOutIsSlowAndZoomInFaster() {
        XCTAssertGreaterThan(AppConfig.driveZoomInLevelsPerSecond, AppConfig.driveZoomOutLevelsPerSecond)
        XCTAssertLessThanOrEqual(AppConfig.driveZoomOutLevelsPerSecond, 1.0 / 6, "не больше уровня за 6 с")
        eachRun { trip, screen, m in
            // Кадр округляется до 0,01 — запас на одно округление.
            XCTAssertLessThanOrEqual(m.fastestOut, AppConfig.driveZoomOutLevelsPerSecond + 0.011,
                                     "\(trip.name), \(screen.name)")
            XCTAssertLessThanOrEqual(m.fastestIn, AppConfig.driveZoomInLevelsPerSecond + 0.011,
                                     "\(trip.name), \(screen.name)")
        }
    }

    func testTurnIsInFrameAtTheManeuver() {
        eachRun { trip, screen, m in
            XCTAssertEqual(m.turnMissed, 0, "\(trip.name), \(screen.name)")
        }
    }

    func testFamiliarCameraTripStaysOnTheLanesScale() {
        // Снимок 63: своя камера в 403 м, 10 км/ч, разворот через 580 м —
        // кадр машины ушёл к виду района. Без неё карта машины на ходу не
        // мельче своего профиля.
        for screen in screens where screen.kind == .car {
            let m = Sim.metrics(Sim.run(Sim.uTurnFamiliar, on: screen), on: screen)
            XCTAssertGreaterThanOrEqual(m.minZoom, 16, screen.name)
            XCTAssertLessThanOrEqual(m.swingPerMinute, 1.0, screen.name)
        }
    }

    // MARK: - Удерживаемая камера

    private let car = Sim.car()

    private func carTarget(_ kmh: Double, keep: Cam.Keep?, turn: Double? = nil) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: true, maxPitch: 45,
                   screen: .car, keep: keep, viewHeight: car.height, latitude: Sim.latitude,
                   clear: car.clear, carY: car.carY)
    }

    func testFamiliarCameraIsNotKept() {
        let me = CLLocationCoordinate2D(latitude: Sim.latitude, longitude: 69.24)
        let ahead = CLLocationCoordinate2D(latitude: Sim.latitude + 403 / 111_320, longitude: 69.24)
        XCTAssertNil(Cam.keep(camera: 7, at: ahead, familiar: [7], from: me, bearing: 0))
        let foreign = Cam.keep(camera: 8, at: ahead, familiar: [7], from: me, bearing: 0)
        XCTAssertEqual(foreign?.forward ?? 0, 403, accuracy: 0.5)
        // Своя: кадр как без камеры — не мельче z15,5 (на деле — профиль машины).
        let own = carTarget(10, keep: Cam.keep(camera: 7, at: ahead, familiar: [7], from: me, bearing: 0))
        XCTAssertEqual(own, carTarget(10, keep: nil))
        XCTAssertGreaterThanOrEqual(own.zoom, 15.5)
        // Чужая — прежнее поведение в пределах нового ограничения.
        XCTAssertGreaterThanOrEqual(carTarget(10, keep: foreign).zoom, AppConfig.driveKeepMinZoomTown - 1e-9)
        XCTAssertLessThan(carTarget(10, keep: foreign).zoom, own.zoom)
    }

    func testForeignCameraNearbyIsStillInFrame() {
        // В пределах нового ограничения камера по-прежнему в кадре.
        for d in [80.0, 150, 250] {
            let f = carTarget(10, keep: Cam.Keep(forward: d, right: 0))
            let seen = Cam.visibleAhead(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: car.height,
                                        carY: car.carY(f.carShare), latitude: Sim.latitude,
                                        clearTop: car.clear.top)
            XCTAssertGreaterThanOrEqual(seen, d, "камера в \(d) м")
        }
    }

    func testKeptCameraNeverPullsBelowTheLimit() {
        let keeps = [Cam.Keep(forward: 480, right: 0), Cam.Keep(forward: -60, right: 0),
                     Cam.Keep(forward: 0, right: 300), Cam.Keep(forward: 300, right: 0, anyDirection: true)]
        for keep in keeps {
            for kmh in stride(from: 0.0, through: 30, by: 5) {
                XCTAssertGreaterThanOrEqual(carTarget(kmh, keep: keep).zoom, AppConfig.driveKeepMinZoomTown - 1e-9,
                                            "\(keep), \(kmh) км/ч")
            }
            for kmh in stride(from: 60.0, through: 130, by: 10) {
                XCTAssertGreaterThanOrEqual(carTarget(kmh, keep: keep).zoom, AppConfig.driveKeepMinZoomRoad - 1e-9,
                                            "\(keep), \(kmh) км/ч")
            }
        }
        XCTAssertEqual(Cam.keepMinZoom(speedKmh: 0), AppConfig.driveKeepMinZoomTown)
        XCTAssertEqual(Cam.keepMinZoom(speedKmh: 200), AppConfig.driveKeepMinZoomRoad)
    }

    func testPassedCameraDoesNotPullTheFrameWhileMoving() {
        // Город, 21.10: камера в 20–55 м позади оставалась «ближайшей» (допуск
        // маршрута 60 м), и кадр машины уходил к z10,6.
        for back in [5.0, 30, 55] {
            XCTAssertEqual(carTarget(35, keep: Cam.Keep(forward: -back, right: 0)), carTarget(35, keep: nil),
                           "позади \(back) м")
        }
        // Стоя — держится (курса нет, камера бывает сзади и сбоку, 12.10).
        XCTAssertLessThan(carTarget(0, keep: Cam.Keep(forward: -110, right: 0)).zoom,
                          carTarget(0, keep: nil).zoom)
    }

    func testSideStreetCameraIsNotKeptWhileMovingButIsStanding() {
        // Ниже 10 км/ч гейты выключены, и ближайшей становится камера соседней
        // улицы в 140 м сбоку.
        let side = Cam.Keep(forward: 70, right: 140)
        XCTAssertEqual(carTarget(8, keep: side), carTarget(8, keep: nil))
        XCTAssertLessThan(carTarget(0, keep: side).zoom, carTarget(0, keep: nil).zoom)
        // Камера впереди на изгибе своей дороги — держится.
        XCTAssertLessThan(carTarget(40, keep: Cam.Keep(forward: 450, right: 120)).zoom,
                          carTarget(40, keep: nil).zoom)
    }

    // MARK: - Сглаживание

    private let t0 = Date(timeIntervalSince1970: 5_000)

    private func frame(_ zoom: Double) -> Cam.Frame {
        Cam.Frame(zoom: zoom, pitchDegrees: 0, carShare: 0.66)
    }

    func testJitterAroundTheTargetDoesNotMoveTheFrame() {
        var smoother = Cam.Smoother()
        _ = smoother.step(toward: frame(16.5), at: t0)
        var previous = 16.5, direction = 0, reversals = 0
        for i in 1...240 {
            // ±0,12 уровня — смена ближайшей камеры, шум скорости.
            let noise = 0.12 * sin(Double(i) * 1.7)
            let zoom = smoother.step(toward: frame(16.5 + noise), at: t0 + Double(i) * 0.25).zoom
            XCTAssertEqual(zoom, 16.5, accuracy: 0.13, "кадр не уходит за шум")
            if abs(zoom - previous) > 0.005 {
                let now = zoom > previous ? 1 : -1
                if direction != 0, now != direction { reversals += 1 }
                direction = now
            }
            previous = zoom
        }
        XCTAssertLessThanOrEqual(reversals, 1, "за минуту шума кадр не качается")
    }

    func testSquareWaveTargetChangesDirectionAtMostOnceInEightSeconds() {
        // Пробка: цель прыгает 16 ↔ 17 каждые 3 с.
        var smoother = Cam.Smoother()
        var previous = smoother.step(toward: frame(17), at: t0).zoom
        var direction = 0
        var lastChange: Double?
        for i in 1...480 {
            let t = Double(i) * 0.25
            let wanted = Int(t / 3) % 2 == 0 ? 17.0 : 16.0
            let zoom = smoother.step(toward: frame(wanted), at: t0 + t).zoom
            if abs(zoom - previous) > 0.005 {
                let now = zoom > previous ? 1 : -1
                if direction != 0, now != direction {
                    if let last = lastChange {
                        XCTAssertGreaterThanOrEqual(t - last, AppConfig.driveZoomReversalLock - 0.25, "t = \(t)")
                    }
                    lastChange = t
                }
                direction = now
            }
            previous = zoom
        }
    }

    func testZoomInFollowsAfterTheDwellAndArrives() {
        // Остановились у светофора: цель крупнее — кадр подходит, но не сразу.
        var smoother = Cam.Smoother()
        _ = smoother.step(toward: frame(16), at: t0)
        _ = smoother.step(toward: frame(15.6), at: t0 + 1)   // последний ход — отъезд
        var zoom = 0.0
        for i in 1...4 {
            zoom = smoother.step(toward: frame(17), at: t0 + 1 + Double(i) * 0.5).zoom
        }
        XCTAssertLessThan(zoom, 16, "приближение ждёт выдержку и запрет частой смены")
        for i in 1...60 {
            zoom = smoother.step(toward: frame(17), at: t0 + 3 + Double(i) * 0.5).zoom
        }
        XCTAssertEqual(zoom, 17, accuracy: 1e-9, "и приходит ровно к цели")
    }

    func testSameDirectionFollowsAtOnce() {
        // Подъезд к развилке: цель растёт — кадр идёт следом без выдержки.
        var smoother = Cam.Smoother()
        _ = smoother.step(toward: frame(16), at: t0)
        let first = smoother.step(toward: frame(16.5), at: t0 + 1).zoom
        XCTAssertGreaterThan(first, 16, "первый ход — сразу")
        let next = smoother.step(toward: frame(16.8), at: t0 + 2).zoom
        XCTAssertGreaterThan(next, first, "в ту же сторону — сразу")
    }

    func testManyCallsPerSecondStillMove() {
        // Тело SwiftUI считается чаще фиксов: шаг за кадр меньше округления.
        var smoother = Cam.Smoother()
        _ = smoother.step(toward: frame(17), at: t0)
        var zoom = 17.0
        for i in 1...(60 * 4) {
            zoom = smoother.step(toward: frame(16), at: t0 + Double(i) / 60).zoom
        }
        XCTAssertLessThan(zoom, 16.6, "за 4 с отъезд идёт, а не стоит")
    }
}
