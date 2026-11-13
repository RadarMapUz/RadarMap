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

// MARK: - Тренога из дома: там, где сам проезжал за последние 3 часа

extension AddPointTests {

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    /// Проезд с запада на восток по широте `me` + `metresNorth`, через точку
    /// в `metresEast` от `me`; середина — `minutesAgo` назад, 60 км/ч.
    private func drive(metresEast: Double, metresNorth: Double, minutesAgo: Double) -> RecentPath {
        let middle = now.timeIntervalSince1970 - minutesAgo * 60
        let lat = me.latitude + metresNorth / 111_320
        let leg = [-2_000.0, 2_000.0].map { offset -> RecentPath.Point in
            let east = metresEast + offset
            return RecentPath.Point(lat: lat, lon: point(metresEast: east).longitude,
                                    time: middle + offset / (60 / 3.6))
        }
        return RecentPath(legs: [leg])
    }

    func testHomeFarButPassedHourAgoAllowed() {
        let target = point(metresEast: 8_000)
        let path = drive(metresEast: 8_000, metresNorth: 100, minutesAgo: 60)
        let result = TripodAvailability.check(point: target, driver: me, reportsEnabled: true,
                                              path: path, now: now)
        XCTAssertTrue(result.isAvailable, "видел по дороге час назад — отмечаю дома")
        let passed = try? XCTUnwrap(result.observedAt)
        XCTAssertEqual(passed?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 - 3_600, accuracy: 5,
                       "время проезда — у ближайшего подхода, оно уйдёт на сервер возрастом")
    }

    func testPassedFourHoursAgoRefused() {
        let path = drive(metresEast: 8_000, metresNorth: 100, minutesAgo: 240)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 8_000), driver: me,
                                                reportsEnabled: true, path: path, now: now), .tooFar)
    }

    func testThreeHundredMetresFromTrackRefused() {
        let path = drive(metresEast: 8_000, metresNorth: 300, minutesAgo: 60)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 8_000), driver: me,
                                                reportsEnabled: true, path: path, now: now), .tooFar)
    }

    func testNearbyStillAllowedWithoutPath() {
        let result = TripodAvailability.check(point: point(metresEast: 300), driver: me,
                                              reportsEnabled: true, path: .empty, now: now)
        XCTAssertEqual(result, .available)
        XCTAssertNil(result.observedAt, "рядом — отметка «сейчас», без возраста")
    }

    func testPassedWithoutPositionAllowed() {
        let path = drive(metresEast: 8_000, metresNorth: 50, minutesAgo: 30)
        XCTAssertTrue(TripodAvailability.check(point: point(metresEast: 8_000), driver: nil,
                                               reportsEnabled: true, path: path, now: now).isAvailable)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 20_000), driver: nil,
                                                reportsEnabled: true, path: path, now: now), .noPosition)
    }

    func testReportsOffBeatsPath() {
        let path = drive(metresEast: 8_000, metresNorth: 0, minutesAgo: 10)
        XCTAssertEqual(TripodAvailability.check(point: point(metresEast: 8_000), driver: me,
                                                reportsEnabled: false, path: path, now: now), .reportsOff)
    }

    func testSegmentNotOnlyVerticesCounts() {
        // Упрощённый трек: две точки в 4 км, цель — посередине, в 100 м сбоку.
        let path = drive(metresEast: 8_000, metresNorth: 100, minutesAgo: 20)
        XCTAssertNotNil(path.passage(near: point(metresEast: 8_000), now: now))
    }

    func testOnlyFreshPartOfLegCounts() {
        // Отрезок, начатый 3 ч 3 мин назад, в окно не входит целиком.
        let path = drive(metresEast: 8_000, metresNorth: 0, minutesAgo: 181)
        XCTAssertNil(path.passage(near: point(metresEast: 8_000), now: now))
    }

    func testTrackWithoutTimesTakesTripStart() {
        let start = now.addingTimeInterval(-2 * 3_600)
        let track = [TrackPoint(lat: 41.3, lon: 69.2, speedKmh: 50),
                     TrackPoint(lat: 41.31, lon: 69.21, speedKmh: 50)]
        let leg = RecentPath.leg(track: track, times: nil, startedAt: start)
        XCTAssertEqual(leg.map(\.time), [start.timeIntervalSince1970, start.timeIntervalSince1970])
        let partial = RecentPath.leg(track: track, times: [.nan, 1_799_999_000], startedAt: start)
        XCTAssertEqual(partial.map(\.time), [start.timeIntervalSince1970, 1_799_999_000])
    }

    func testRefusalTextNamesTheWindow() {
        XCTAssertEqual(AppConfig.addTripodTrackWindowSeconds, 3 * 3_600,
                       "строки отказа называют «3 часа» словами — сменили окно, смените и их")
        XCTAssertEqual(AppConfig.addTripodTrackMaxMeters, 150)
    }

    // MARK: - Центр под прицел (92: на наклонной карте вы вставали в 40 м под прицел)

    func testCentrePutsTargetUnderAimByTheViewsOwnOffset() {
        // Под прицелом сейчас точка в 300 м севернее середины (наклон сжал её
        // в меньшее число точек экрана) — центр уходит на те же 300 м южнее цели.
        let target = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)
        let centre = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)
        let under = CLLocationCoordinate2D(latitude: 41.3127, longitude: 69.2503)
        let placed = AddPointAim.centre(placing: target, under: under, viewCentre: centre, scale: 1)
        XCTAssertEqual(placed.latitude, 41.30 - 0.0027, accuracy: 1e-9)
        XCTAssertEqual(placed.longitude, 69.28 - 0.0003, accuracy: 1e-9)
    }

    func testCentreScalesOffsetWithZoom() {
        // Приближение на один шаг — тот же сдвиг экрана вдвое короче на земле.
        let target = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)
        let centre = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)
        let under = CLLocationCoordinate2D(latitude: 41.312, longitude: 69.25)
        let placed = AddPointAim.centre(placing: target, under: under, viewCentre: centre, scale: 0.5)
        XCTAssertEqual(placed.latitude, 41.299, accuracy: 1e-9)
        XCTAssertEqual(placed.longitude, 69.28, accuracy: 1e-9)
    }

    func testAimAtCentreLeavesTargetAsCentre() {
        let target = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)
        let centre = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)
        let placed = AddPointAim.centre(placing: target, under: centre, viewCentre: centre, scale: 2)
        XCTAssertEqual(placed.latitude, target.latitude, accuracy: 1e-12)
        XCTAssertEqual(placed.longitude, target.longitude, accuracy: 1e-12)
    }

    func testMissIsWhatTheEyeSees() {
        let aim = CGPoint(x: 220, y: 400)
        XCTAssertFalse(AddPointAim.misses(CGPoint(x: 222, y: 402), aim: aim))
        XCTAssertTrue(AddPointAim.misses(CGPoint(x: 220, y: 438), aim: aim), "38 pt — снимок 92")
    }
}
