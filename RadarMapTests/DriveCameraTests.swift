//
//  DriveCameraTests.swift
//  RadarMapTests
//
//  Камера поездки: полосы видны там, где они решают, на любом экране;
//  впереди видно нужные секунды пути; развилка не уходит из кадра; плавно.
//

import XCTest
@testable import RadarMap

final class DriveCameraTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let tashkent = 41.31
    /// Высоты вида: CarPlay 1920×720 (382 pt), CarPlay 800×480, телефон.
    private let heights: [Double] = [382, 480, 760, 900]
    private let maxPitch = 45.0

    private func frame(_ kmh: Double, turn: Double? = nil, height: Double,
                       carY: Double = 0.7, pitch: Bool = true) -> Cam.Frame {
        Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: pitch, maxPitch: maxPitch,
                   viewHeight: height, latitude: tashkent, carY: { _ in carY })
    }

    private func ahead(_ f: Cam.Frame, height: Double, carY: Double = 0.7) -> Double {
        Cam.visibleAhead(zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: height,
                         carY: carY, latitude: tashkent)
    }

    // MARK: - Полосы

    func testLanesAreVisibleStandingAndInTownOnEveryScreen() {
        // Владелец, 12.10: «полосы делали — не видны». Разметка в стиле — с 17.
        for height in heights {
            for kmh in stride(from: 0.0, through: 70, by: 5) {
                XCTAssertGreaterThanOrEqual(frame(kmh, height: height).zoom, Cam.laneZoom,
                                            "\(kmh) км/ч, экран \(height) pt")
            }
        }
    }

    func testBiggerScreenShowsMoreNotBigger() {
        // Масштаб не падает с ростом экрана: полоса не мельчает, а дороги больше.
        for kmh in stride(from: 0.0, through: 130, by: 10) {
            let small = frame(kmh, height: 382), big = frame(kmh, height: 900)
            XCTAssertGreaterThanOrEqual(big.zoom, small.zoom - 1e-9, "\(kmh) км/ч")
            XCTAssertGreaterThan(ahead(big, height: 900), ahead(small, height: 382) - 1e-6, "\(kmh) км/ч")
        }
    }

    // MARK: - Обзор и наклон

    func testStandingIsTopDown() {
        for kmh in [0.0, 5, 10, 15] {
            XCTAssertEqual(frame(kmh, height: 382).pitchDegrees, 0, "\(kmh) км/ч — сверху")
        }
    }

    func testPitchGrowsWithSpeedAndNeverPassesTheEngineLimit() {
        var previous = -1.0
        for kmh in stride(from: 0.0, through: 200, by: 5) {
            let pitch = frame(kmh, height: 760).pitchDegrees
            XCTAssertGreaterThanOrEqual(pitch, previous, "\(kmh) км/ч")
            XCTAssertLessThanOrEqual(pitch, maxPitch, "предел перегрева движка")
            previous = pitch
        }
        XCTAssertGreaterThan(frame(100, height: 760).pitchDegrees, 30)
    }

    func testLookaheadSecondsAreVisibleUnlessTheFloorHolds() {
        for height in heights {
            for kmh in stride(from: 20.0, through: 130, by: 10) {
                let f = frame(kmh, height: height)
                let profile = Cam.profile(speedKmh: kmh, pitchAllowed: true, maxPitch: maxPitch)
                let needed = max(Cam.minLookaheadMeters, kmh / 3.6 * profile.lookaheadSeconds)
                let atFloor = abs(f.zoom - profile.minZoom) < 1e-9
                XCTAssertTrue(ahead(f, height: height) >= needed * 0.99 || atFloor,
                              "\(kmh) км/ч, экран \(height): видно \(Int(ahead(f, height: height))) из \(Int(needed)) м")
            }
        }
    }

    func testFlatModeHasNoPitchAndStillSeesAhead() {
        for kmh in stride(from: 0.0, through: 130, by: 10) {
            let f = frame(kmh, height: 760, pitch: false)
            XCTAssertEqual(f.pitchDegrees, 0)
            if kmh >= 40 {
                XCTAssertGreaterThan(ahead(f, height: 760), kmh / 3.6 * 8, "\(kmh) км/ч плоско")
            }
        }
    }

    // MARK: - Развилка

    func testTurnStaysInFrameAllTheWayIn() {
        // Прежняя камера стягивала охват, пока развилка была ЗА краем экрана.
        for height in heights {
            for kmh in stride(from: 30.0, through: 130, by: 10) {
                let window = min(Cam.maneuverWindowMax, max(Cam.maneuverWindowMin, kmh / 3.6 * Cam.maneuverLeadSeconds))
                for d in stride(from: 0.0, to: window, by: 10) {
                    let f = frame(kmh, turn: d, height: height)
                    XCTAssertGreaterThanOrEqual(ahead(f, height: height), d,
                                                "\(kmh) км/ч, развилка в \(d) м, экран \(height)")
                }
            }
        }
    }

    func testAtTheTurnLaneArrowsAreVisible() {
        for height in heights {
            for kmh in stride(from: 20.0, through: 130, by: 10) {
                for d in [0.0, 40, 80] {
                    let f = frame(kmh, turn: d, height: height)
                    XCTAssertGreaterThanOrEqual(f.zoom, Cam.laneZoom, "\(kmh) км/ч, \(d) м, экран \(height)")
                    XCTAssertLessThanOrEqual(f.pitchDegrees, Cam.maneuverPitch + 1e-9)
                }
            }
        }
    }

    func testFarTurnDoesNotTouchTheView() {
        XCTAssertEqual(frame(90, turn: 2_000, height: 760), frame(90, height: 760))
        XCTAssertEqual(frame(50, turn: 600, height: 382), frame(50, height: 382))
    }

    // MARK: - Геометрия

    func testTopDownGeometryIsThePlainFormula() {
        let span = 300.0
        XCTAssertEqual(Cam.centreAhead(spanMeters: span, anchorY: 0.7, pitchDegrees: 0), span * 0.2, accuracy: 1e-6)
        let zoom = 17.0
        let full = Cam.span(zoom: zoom, viewHeight: 382, latitude: tashkent)
        XCTAssertEqual(Cam.visibleAhead(zoom: zoom, pitchDegrees: 0, viewHeight: 382, carY: 0.7, latitude: tashkent),
                       full * 0.7, accuracy: 1e-6)
        // z17 на 382 pt в Ташкенте — около 171 м по высоте.
        XCTAssertEqual(full, 171, accuracy: 2)
    }

    func testPitchedCarNeedsMoreGroundToSitWhereIntended() {
        // Формула вида сверху на наклоне ставила машину выше задуманного:
        // чтобы она стояла на anchorY, центр уходит дальше вперёд.
        let flat = Cam.centreAhead(spanMeters: 300, anchorY: 0.72, pitchDegrees: 0)
        let pitched = Cam.centreAhead(spanMeters: 300, anchorY: 0.72, pitchDegrees: 45)
        XCTAssertGreaterThan(pitched, flat * 1.15)
        XCTAssertEqual(Cam.centreAhead(spanMeters: 300, anchorY: 0.5, pitchDegrees: 45), 0, accuracy: 1e-6)
    }

    func testZoomShowingInvertsVisibleAhead() {
        for pitch in [0.0, 30, 45] {
            let z = Cam.zoomShowing(250, pitchDegrees: pitch, viewHeight: 480, carY: 0.7, latitude: tashkent)
            XCTAssertEqual(Cam.visibleAhead(zoom: z, pitchDegrees: pitch, viewHeight: 480, carY: 0.7,
                                            latitude: tashkent), 250, accuracy: 0.5)
        }
    }

    // MARK: - Плавность

    func testSmootherGlidesWithoutOvershootAndArrives() {
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let start = Cam.Frame(zoom: 18, pitchDegrees: 0, carShare: 0.62)
        let goal = Cam.Frame(zoom: 17, pitchDegrees: 40, carShare: 0.72)
        XCTAssertEqual(smoother.step(toward: start, at: t0), start, "первый кадр — сразу")
        var previous = start
        for second in 1...15 {
            let f = smoother.step(toward: goal, at: t0 + Double(second))
            XCTAssertLessThanOrEqual(f.zoom, previous.zoom)
            XCTAssertGreaterThanOrEqual(f.zoom, goal.zoom, "без перелёта")
            XCTAssertGreaterThanOrEqual(f.pitchDegrees, previous.pitchDegrees)
            XCTAssertLessThanOrEqual(f.pitchDegrees, goal.pitchDegrees)
            if second == 1 {
                XCTAssertLessThan(f.zoom, 17.8, "движется сразу")
                XCTAssertGreaterThan(f.zoom, 17.4, "но не прыжком")
            }
            previous = f
        }
        XCTAssertEqual(previous, goal, "доходит ровно до цели")
    }

    func testSteadyTargetDoesNotDrift() {
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 0)
        let goal = Cam.Frame(zoom: 17.23, pitchDegrees: 36.5, carShare: 0.7)
        _ = smoother.step(toward: goal, at: t0)
        for second in 1...30 {
            XCTAssertEqual(smoother.step(toward: goal, at: t0 + Double(second)), goal)
        }
    }

    func testLongPauseJumpsStraightToTarget() {
        var smoother = Cam.Smoother()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = smoother.step(toward: Cam.Frame(zoom: 18, pitchDegrees: 0, carShare: 0.62), at: t0)
        let goal = Cam.Frame(zoom: 16.5, pitchDegrees: 45, carShare: 0.75)
        XCTAssertEqual(smoother.step(toward: goal, at: t0 + 60), goal)
    }
}
