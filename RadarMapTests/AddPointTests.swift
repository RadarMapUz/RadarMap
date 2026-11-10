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
