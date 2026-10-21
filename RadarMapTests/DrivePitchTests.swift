//
//  DrivePitchTests.swift
//  RadarMapTests
//
//  Наклон камеры поездки (25.D, 21.10): «у Яндекса богато под наклоном».
//  Сверху — только стоя и ползком и близко у развилки; в городе на 10–40
//  км/ч — наклон; потолок — AppConfig.engineMapPitchDegrees, а горячий
//  телефон — плоско, как раньше. Масштаб здесь не проверяется (его ведёт
//  DriveCameraTests и 25.A) — кроме того, что узел «ползком» его не сдвинул.
//

import XCTest
@testable import RadarMap

final class DrivePitchTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let tashkent = 41.31

    private func frame(_ kmh: Double, turn: Double? = nil, screen: Cam.Screen,
                       pitch: Bool = true) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: pitch, screen: screen,
                   viewHeight: screen == .car ? 382 : 760, latitude: tashkent, carY: { _ in 0.7 })
    }

    func testStandingAndCrawlingAreTopDown() {
        for screen in [Cam.Screen.phone, .car] {
            for kmh in [0.0, 2, 4, 6] {
                XCTAssertEqual(frame(kmh, screen: screen).pitchDegrees, 0, "\(screen) \(kmh) км/ч")
            }
        }
    }

    func testTownSpeedsArePitched() {
        // Город на 10–40 км/ч — не чертёж сверху (снимки владельца 21.10).
        for screen in [Cam.Screen.phone, .car] {
            for kmh in stride(from: 10.0, through: 40, by: 5) {
                XCTAssertGreaterThanOrEqual(frame(kmh, screen: screen).pitchDegrees, 20,
                                            "\(screen) \(kmh) км/ч")
            }
            XCTAssertGreaterThanOrEqual(frame(30, screen: screen).pitchDegrees, 45, "\(screen) 30 км/ч")
        }
    }

    func testPitchGrowsWithSpeedUpToTheCeiling() {
        for screen in [Cam.Screen.phone, .car] {
            var previous = -1.0
            for kmh in stride(from: 0.0, through: 200, by: 2.5) {
                let pitch = frame(kmh, screen: screen).pitchDegrees
                XCTAssertGreaterThanOrEqual(pitch, previous, "\(screen) \(kmh) км/ч")
                XCTAssertLessThanOrEqual(pitch, AppConfig.engineMapPitchDegrees + 1e-9)
                previous = pitch
            }
            XCTAssertGreaterThanOrEqual(previous, 55, "на трассе — как у Яндекса, 55–60°")
        }
    }

    func testCeilingStaysBelowTheEngineLimit() {
        // 60° — предел MapLibre; выше 58 верх телефона уходит к горизонту.
        XCTAssertGreaterThanOrEqual(AppConfig.engineMapPitchDegrees, 55)
        XCTAssertLessThan(AppConfig.engineMapPitchDegrees, 60)
        XCTAssertLessThanOrEqual(AppConfig.engineOverviewPitchDegrees, AppConfig.engineMapPitchDegrees)
    }

    func testHotPhoneStaysFlat() {
        // Откат: горячий телефон (thermal ≠ .full) — плоская таблица, как до 25.D.
        for screen in [Cam.Screen.phone, .car] {
            for kmh in stride(from: 0.0, through: 130, by: 10) {
                XCTAssertEqual(frame(kmh, screen: screen, pitch: false).pitchDegrees, 0)
            }
        }
    }

    func testCloseToTheTurnPitchDropsToTheJunctionView() {
        for screen in [Cam.Screen.phone, .car] {
            for kmh in [20.0, 40, 60] {
                for d in [0.0, 40, 80] {
                    XCTAssertLessThanOrEqual(frame(kmh, turn: d, screen: screen).pitchDegrees,
                                             Cam.maneuverPitch + 1e-9, "\(screen) \(kmh) км/ч, \(d) м")
                }
            }
        }
    }

    func testCrawlKnotDoesNotMoveZoomOrCar() {
        // Узел 6 км/ч добавлен ради наклона: остальные столбцы на нём лежат
        // на прямой 0…15, и масштаб, обзор и место машины не меняются.
        for screen in [Cam.Screen.phone, .car] {
            let a = Cam.profile(speedKmh: 0, pitchAllowed: true, screen: screen)
            let b = Cam.profile(speedKmh: 15, pitchAllowed: true, screen: screen)
            for kmh in [3.0, 6, 9, 12] {
                let p = Cam.profile(speedKmh: kmh, pitchAllowed: true, screen: screen)
                let t = kmh / 15
                XCTAssertEqual(p.lookaheadSeconds, a.lookaheadSeconds + (b.lookaheadSeconds - a.lookaheadSeconds) * t,
                               accuracy: 1e-9, "\(screen) \(kmh)")
                XCTAssertEqual(p.minZoom, a.minZoom + (b.minZoom - a.minZoom) * t, accuracy: 1e-9)
                XCTAssertEqual(p.maxZoom, a.maxZoom + (b.maxZoom - a.maxZoom) * t, accuracy: 1e-9)
                XCTAssertEqual(p.carShare, a.carShare + (b.carShare - a.carShare) * t, accuracy: 1e-9)
            }
        }
    }
}
