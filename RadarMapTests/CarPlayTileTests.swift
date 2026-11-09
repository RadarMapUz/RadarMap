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
                               frame(Cam.Clear(width: tile.w)), "\(tile)")
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
}
