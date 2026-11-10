//
//  AddPointTests.swift
//  RadarMapTests
//
//  Прицел на карте: своя камера остаётся на телефоне, тренога уходит
//  отметкой для всех — и только рядом с водителем.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class AddPointTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)

    private func point(metresEast: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: me.latitude,
                               longitude: me.longitude
                                   + metresEast / (111_320 * cos(me.latitude * .pi / 180)))
    }

    // MARK: - Куда уходит выбор

    func testCamerasStayOnPhone() {
        XCTAssertEqual(AddPointKind.speedCamera.route, .ownCamera(.stationaryRadar))
        XCTAssertEqual(AddPointKind.signalCamera.route, .ownCamera(.stationaryCamera))
        XCTAssertTrue(AddPointKind.speedCamera.isOwnCamera)
        XCTAssertTrue(AddPointKind.signalCamera.isOwnCamera)
    }

    func testTripodIsReportNotOwnCamera() {
        XCTAssertEqual(AddPointKind.tripod.route, .report(.tripod))
        XCTAssertFalse(AddPointKind.tripod.isOwnCamera, "тренога не должна ложиться в свои камеры")
        XCTAssertEqual(AddPointKind.tripod.cameraType, .tripod)
    }

    func testSpeedCameraIsDefaultAndWakesInRadarsOnlyMode() {
        XCTAssertEqual(AddPointKind.allCases.first, .speedCamera)
        let camera = Camera(id: 1_000_001, region: "", city: "", location: "", lat: me.latitude,
                            lon: me.longitude, type: AddPointKind.speedCamera.cameraType.sourceString,
                            violations: [], needsReview: nil)
        XCTAssertTrue(BackgroundAlertMode.radarsOnly.allows(camera))
    }

    // MARK: - Тренога: только рядом

    func testTripodNearbyAvailable() {
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 300), driver: me,
                                                reportsEnabled: true), .available)
        XCTAssertEqual(TripodAvailability.check(point: me, driver: me, reportsEnabled: true), .available)
    }

    func testTripodAtLimitAvailableBeyondRefused() {
        let limit = AppConfig.addTripodMaxDistanceMeters
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: limit - 20), driver: me,
                                                reportsEnabled: true), .available)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: limit + 50), driver: me,
                                                reportsEnabled: true), .tooFar)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 20_000), driver: me,
                                                reportsEnabled: true), .tooFar)
    }

    func testTripodWithoutPositionRefused() {
        XCTAssertEqual(TripodAvailability.check(point: me, driver: nil, reportsEnabled: true), .noPosition)
        XCTAssertEqual(TripodAvailability.check(point: me, driver: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                                reportsEnabled: true), .noPosition)
    }

    func testTripodWithoutMapCentreRefused() {
        XCTAssertFalse(TripodAvailability.check(point: nil, driver: me, reportsEnabled: true).isAvailable)
    }

    func testReportsOffWins() {
        XCTAssertEqual(TripodAvailability.check(point: me, driver: me, reportsEnabled: false), .reportsOff)
        XCTAssertEqual(TripodAvailability.check(point: me, driver: nil, reportsEnabled: false), .reportsOff)
    }

    func testCustomLimit() {
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 300), driver: me,
                                                reportsEnabled: true, maxMeters: 200), .tooFar)
    }
}

// MARK: - «Радар здесь» с долгого нажатия — то же правило

extension AddPointTests {

    func testLongPressReportFarFromDriverRefused() {
        // Точка долгого нажатия в 5 км — «с дивана»: ни один тип отметки не уходит.
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 5_000), driver: me,
                                                reportsEnabled: true), .tooFar)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 5_000), driver: nil,
                                                reportsEnabled: true), .noPosition)
    }

    func testLongPressReportNearDriverAllowed() {
        XCTAssertTrue(TripodAvailability.check(point: point(metresEast: 200), driver: me,
                                               reportsEnabled: true).isAvailable)
    }
}

// MARK: - Прицел — в середине видимой карты, не под панелью

extension AddPointTests {

    func testAimSitsBetweenPanels() {
        // iPhone 16 Pro: 402×874; сверху панели до 120 pt, нижняя панель с 600 pt.
        let insets = MapViewport.Insets(top: 120.0 / 874, bottom: (874.0 - 600) / 874)
        let aim = AddPointAim.point(width: 402, height: 874, insets: insets)
        XCTAssertEqual(aim.x, 201, accuracy: 0.001)
        XCTAssertEqual(aim.y, 360, accuracy: 0.001)
        XCTAssertLessThan(aim.y, 600 - 23, "прицел целиком над нижней панелью")
        XCTAssertGreaterThan(aim.y, 120 + 23, "и под верхней стопкой")
    }

    func testAimFollowsPanelHeight() {
        let low = AddPointAim.point(width: 402, height: 874,
                                    insets: MapViewport.Insets(top: 0.1, bottom: 0.3))
        let high = AddPointAim.point(width: 402, height: 874,
                                     insets: MapViewport.Insets(top: 0.1, bottom: 0.45))
        XCTAssertLessThan(high.y, low.y, "панель выросла — прицел поднялся")
    }

    func testAimWithoutMeasurementIsViewCentre() {
        let aim = AddPointAim.point(width: 402, height: 874, insets: .none)
        XCTAssertEqual(aim.y, 437, accuracy: 0.001)
    }

    func testAimSurvivesOverlappingPanels() {
        let aim = AddPointAim.point(width: 402, height: 874,
                                    insets: MapViewport.Insets(top: 0.7, bottom: 0.5))
        XCTAssertEqual(aim.y, 437, accuracy: 0.001, "панели сошлись — середина вида, не за краем")
        XCTAssertEqual(AddPointAim.point(width: 0, height: 874, insets: .none), .zero)
    }
}
