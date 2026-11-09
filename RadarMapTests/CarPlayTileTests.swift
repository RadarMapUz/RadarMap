//
//  CarPlayTileTests.swift
//  RadarMapTests
//
//  Плитка главного экрана машины: что на ней показывается и где. Прибор с
//  09.11 стоит справа внизу, и «держать камеру в кадре» обязан это знать.
//

import XCTest
@testable import RadarMap

final class CarPlayTileTests: XCTestCase {

    private typealias Cam = DriveCamera
    private let latitude = 41.31
    private let meY = AppConfig.carPlayDashboardMeY
    /// Плитки разной формы: узкая высокая, узкая низкая, обычные и широкая.
    private let tiles: [(w: Double, h: Double)] = [(280, 380), (320, 300), (375, 420), (480, 400)]
    private let standing = StopView.State(standing: true, maneuverWindow: AppConfig.stopViewManeuverMeters)

    /// Строка центра камеры на плитке, точки сверху.
    private func row(of keep: Cam.Keep, speedKmh: Double, stop: StopView.State,
                     clear: Cam.Clear, height: Double) -> Double {
        let frame = Cam.target(speedKmh: speedKmh, maneuverDistance: nil, pitchAllowed: true,
                               maxPitch: AppConfig.carPlayDashboard3DMaxPitch, screen: .car, keep: keep,
                               stop: stop, viewHeight: height, latitude: latitude, clear: clear,
                               carY: { _ in self.meY })
        let share = Cam.rowShare(forward: keep.forward, zoom: frame.zoom, pitchDegrees: frame.pitchDegrees,
                                 viewHeight: height, carY: meY, latitude: latitude)
        return (0.5 + share) * height
    }

    /// Верхняя кромка прибора (отступ 10, высота до 49 — стенд на ImageRenderer).
    private func gaugeTop(_ height: Double) -> Double { height - 59 }

    func testCameraBehindWhileStandingStaysAboveTheGauge() {
        for tile in tiles {
            let clear = CarPlaySurface.dashboardClear(width: tile.w, height: tile.h)
            for keep in [Cam.Keep(forward: -40, right: 0), Cam.Keep(forward: -20, right: 4)] {
                XCTAssertLessThanOrEqual(row(of: keep, speedKmh: 0, stop: standing, clear: clear, height: tile.h),
                                         gaugeTop(tile.h), "\(tile), \(keep)")
            }
        }
    }

    /// Без запаса камера в 40 м позади вставала под прибор: это и есть дефект.
    func testWithoutTheReserveTheCameraWouldBeUnderTheGauge() {
        let tile = (w: 320.0, h: 300.0)
        let y = row(of: Cam.Keep(forward: -40, right: 0), speedKmh: 0, stop: standing,
                    clear: Cam.Clear(width: tile.w), height: tile.h)
        XCTAssertGreaterThan(y, gaugeTop(tile.h))
    }

    func testCameraAheadDoesNotPayForTheGauge() {
        for tile in tiles {
            for (keep, kmh) in [(Cam.Keep(forward: 300, right: 0), 60.0), (Cam.Keep(forward: 150, right: 5), 40)] {
                let frame = { (clear: Cam.Clear) in
                    Cam.target(speedKmh: kmh, maneuverDistance: nil, pitchAllowed: true, maxPitch: 45,
                               screen: .car, keep: keep, viewHeight: tile.h, latitude: self.latitude,
                               clear: clear, carY: { _ in self.meY })
                }
                XCTAssertEqual(frame(CarPlaySurface.dashboardClear(width: tile.w, height: tile.h)),
                               frame(Cam.Clear(width: tile.w, topKeepPoints: Cam.keepMarginPoints)), "\(tile)")
            }
        }
    }

    func testCarStaysAboveTheGauge() {
        // Значок «я» — до 44 точек; 22 ниже своей строки.
        for tile in tiles {
            XCTAssertLessThanOrEqual(tile.h * meY + 22, gaugeTop(tile.h), "\(tile)")
        }
    }

    func testNoSignalReplacesTheFrozenDistance() {
        typealias Cue = CarPlayCameraCue
        XCTAssertEqual(Cue.gaugeCamera(signalStale: true, distance: 250, straight: 240), .noSignal)
        XCTAssertEqual(Cue.gaugeCamera(signalStale: true, distance: nil, straight: 0), .noSignal)
        XCTAssertEqual(Cue.gaugeCamera(signalStale: false, distance: 250, straight: 240), .distance)
        XCTAssertEqual(Cue.gaugeCamera(signalStale: false, distance: nil, straight: 0), .hidden)
        XCTAssertEqual(Cue.gaugeCamera(signalStale: false, distance: 0, straight: 50), .hidden, "камера за спиной")
        XCTAssertEqual(Cue.gaugeCamera(signalStale: false, distance: AppConfig.carPlayNearestCameraMeters + 1,
                                       straight: 4000), .hidden)
    }

    func testAttributionLeavesTheGaugeCorner() {
        XCTAssertTrue(CarPlaySurface.dashboard.attributionOnTop)
        XCTAssertFalse(CarPlaySurface.car.attributionOnTop)
    }

    func testStreetOnlyOnAWideTile() {
        XCTAssertFalse(CarPlaySurface.tileShowsStreet(width: 280, arrivalShown: false))
        XCTAssertFalse(CarPlaySurface.tileShowsStreet(width: 375, arrivalShown: false))
        XCTAssertTrue(CarPlaySurface.tileShowsStreet(width: 480, arrivalShown: false))
        XCTAssertFalse(CarPlaySurface.tileShowsStreet(width: 480, arrivalShown: true), "прибор с прибытием шире")
        XCTAssertTrue(CarPlaySurface.tileShowsStreet(width: 640, arrivalShown: true))
    }

    func testArrivalNeedsRoomForItsLongestText() {
        // Прибор «120 · знак · 1,2 км · 1 ч 20 мин» — 329 pt при крупном тексте.
        XCTAssertGreaterThanOrEqual(AppConfig.carPlayGaugeArrivalWidth, 329)
    }

    func testFuelOnTheTileOnlyWithoutARoute() {
        func decide(_ surface: MapDetailPolicy.Surface, route: Bool) -> MapDetailPolicy.Decision {
            MapDetailPolicy.decide(MapDetailPolicy.Context(surface: surface, tripActive: true, standing: false,
                                                           hasRoute: route))
        }
        XCTAssertEqual(decide(.dashboard, route: false).fuel, .nearby)
        XCTAssertEqual(decide(.dashboard, route: true).fuel, .hidden)
        XCTAssertEqual(decide(.cluster, route: false).fuel, .hidden)
    }

    func testTileAloneMeansTheCarIsConnected() {
        var presence = CarPlayPresence()
        XCTAssertFalse(presence.isConnected)
        presence.dashboardChanged(connected: true)
        XCTAssertTrue(presence.isConnected, "плитка без основной сцены — машина подключена")
        presence.setMain(true)
        presence.setMain(false)
        XCTAssertTrue(presence.isConnected, "основная ушла, плитка осталась")
        presence.dashboardChanged(connected: false)
        XCTAssertFalse(presence.isConnected)
    }

    func testLateDisconnectOfAnOldTileDoesNotDropTheLiveOne() {
        var presence = CarPlayPresence()
        presence.dashboardChanged(connected: true)
        presence.dashboardChanged(connected: true)
        presence.dashboardChanged(connected: false)
        XCTAssertTrue(presence.isConnected)
    }

    // MARK: - Камера у верхней кромки (09.11)

    private struct KeepScreen {
        let name: String
        let height: Double
        let clear: Cam.Clear
        let maxPitch: Double
        let carY: (Double) -> Double
    }

    /// Половина значка тревоги: 38 точек.
    private let iconHalf = 19.0

    private func carScreen(_ width: Double, _ height: Double) -> KeepScreen {
        let top = 50.0
        return KeepScreen(name: "машина \(Int(width))×\(Int(height))", height: height,
                          clear: CarPlaySurface.carClear(width: width, height: height, safeTop: top, safeBottom: 0,
                                                         side: 60),
                          maxPitch: AppConfig.engineMapPitchDegrees,
                          carY: { share in (top + 12 + (height - top - 24) * share) / height })
    }

    private func tileScreen(_ width: Double, _ height: Double) -> KeepScreen {
        KeepScreen(name: "плитка \(Int(width))×\(Int(height))", height: height,
                   clear: CarPlaySurface.dashboardClear(width: width, height: height),
                   maxPitch: AppConfig.carPlayDashboard3DMaxPitch, carY: { [meY] _ in meY })
    }

    private var keepScreens: [KeepScreen] {
        [carScreen(800, 480), carScreen(940, 471), carScreen(1000, 382),
         tileScreen(280, 380), tileScreen(375, 420), tileScreen(480, 400), tileScreen(320, 300)]
    }

    private func keepFrame(_ s: KeepScreen, kmh: Double, forward: Double, turn: Double? = nil,
                           margin: Bool = true) -> Cam.Frame {
        var clear = s.clear
        if !margin { clear.topKeepPoints = 0 }
        return Cam.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: true, maxPitch: s.maxPitch, screen: .car,
                          keep: Cam.Keep(forward: forward, right: 0), viewHeight: s.height, latitude: latitude,
                          clear: clear, carY: s.carY)
    }

    /// Запас от кромки до центра значка, точки экрана.
    private func topGap(_ s: KeepScreen, _ f: Cam.Frame, forward: Double) -> Double {
        let row = Cam.rowShare(forward: forward, zoom: f.zoom, pitchDegrees: f.pitchDegrees, viewHeight: s.height,
                               carY: s.carY(f.carShare), latitude: latitude)
        return (0.5 + row - s.clear.top) * s.height
    }

    func testCameraIconIsWholeUnderTheBarOnEveryRealScreen() {
        for s in keepScreens {
            for kmh in [40.0, 50, 60, 80, 100] {
                for forward in stride(from: 150.0, through: 480, by: 30) {
                    let f = keepFrame(s, kmh: kmh, forward: forward)
                    let atFloor = f.zoom <= Cam.keepMinZoom(speedKmh: kmh) + 1e-9
                    guard !atFloor else { continue }
                    XCTAssertGreaterThanOrEqual(topGap(s, f, forward: forward), iconHalf,
                                                "\(s.name), \(kmh) км/ч, камера в \(forward) м")
                }
            }
        }
    }

    /// Дефект, из-за которого всё это: метровый запас на наклоне давал 7–9
    /// точек, и значок стоял наполовину под баром.
    func testWithoutPointMarginTheIconWasHalfUnderTheBar() {
        let s = carScreen(940, 471)
        let before = topGap(s, keepFrame(s, kmh: 60, forward: 450, margin: false), forward: 450)
        XCTAssertLessThan(before, iconHalf)
        XCTAssertEqual(topGap(s, keepFrame(s, kmh: 60, forward: 450), forward: 450), Cam.keepMarginPoints, accuracy: 0.5)
    }

    func testTopMarginNeverWorseThanBefore() {
        for s in keepScreens {
            for kmh in [15.0, 30, 40, 60, 90] {
                for forward in stride(from: 60.0, through: 495, by: 15) {
                    XCTAssertGreaterThanOrEqual(topGap(s, keepFrame(s, kmh: kmh, forward: forward), forward: forward) + 1e-6,
                                                topGap(s, keepFrame(s, kmh: kmh, forward: forward, margin: false),
                                                       forward: forward),
                                                "\(s.name), \(kmh) км/ч, \(forward) м")
                }
            }
        }
    }

    func testZoomDoesNotJumpAsTheCameraApproaches() {
        for s in keepScreens {
            for kmh in stride(from: 0.0, through: 110, by: 10) {
                var previous: Double?
                for forward in stride(from: 495.0, through: 40, by: -5) {
                    let f = keepFrame(s, kmh: kmh, forward: forward)
                    if let previous {
                        XCTAssertLessThanOrEqual(abs(f.zoom - previous), 0.15,
                                                 "\(s.name), \(kmh) км/ч, \(forward) м")
                    }
                    previous = f.zoom
                    let before = keepFrame(s, kmh: kmh, forward: forward, margin: false)
                    XCTAssertLessThanOrEqual(before.zoom - f.zoom, 0.3, "запас стоит доли уровня: \(s.name)")
                }
            }
        }
    }

    func testLanesAtAManeuverAreNotLost() {
        for s in keepScreens.prefix(3) {
            for kmh in [10.0, 20, 30, 40, 50, 60] {
                let window = min(Cam.maneuverWindowMax, max(Cam.maneuverWindowMin, kmh / 3.6 * Cam.maneuverLeadSeconds))
                for turn in stride(from: 40.0, to: window, by: 10) {
                    for forward in stride(from: 40.0, through: 480, by: 10) {
                        let before = keepFrame(s, kmh: kmh, forward: forward, turn: turn, margin: false)
                        let after = keepFrame(s, kmh: kmh, forward: forward, turn: turn)
                        XCTAssertGreaterThanOrEqual(after.zoom + 1e-9, min(before.zoom, Cam.laneZoom),
                                                    "\(s.name), \(kmh) км/ч, поворот \(turn), камера \(forward)")
                    }
                }
            }
        }
    }

    /// Телефон и приборка не меняются: запас в точках включают только
    /// экран машины и плитка.
    func testOtherSurfacesKeepTheOldMargin() {
        XCTAssertEqual(Cam.Clear().topKeepPoints, 0)
        XCTAssertEqual(CarPlaySurface.dashboardClear(width: 320, height: 300).topKeepPoints, Cam.keepMarginPoints)
        XCTAssertEqual(CarPlaySurface.carClear(width: 800, height: 480, safeTop: 50, safeBottom: 0, side: 60).topKeepPoints,
                       Cam.keepMarginPoints)
    }
}
