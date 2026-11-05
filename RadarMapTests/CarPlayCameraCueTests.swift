//
//  CarPlayCameraCueTests.swift
//  RadarMapTests
//
//  Камера впереди в машине (25.F): док — только скорость; баннер, подпись
//  «400 м» на карте и строка в оценках — у чужой камеры в тревоге; своя
//  камера — только значок с галочкой.
//

import XCTest
@testable import RadarMap

final class CarPlayCameraCueTests: XCTestCase {

    // MARK: - Баннер, облик на карте, подпись

    func testForeignCameraInAlertGetsBannerMapAlertAndLabel() {
        let cue = CarPlayCameraCue.decide(cameraID: 42, approaching: true, familiar: false)
        XCTAssertTrue(cue.banner)
        XCTAssertEqual(cue.mapAlertID, 42)
        XCTAssertTrue(cue.distanceLabel)
    }

    /// Своя камера: голоса о ней нет — и баннера нет; на карте она не
    /// тревожная (иначе пропала бы галочка), и цифры у неё нет.
    func testFamiliarCameraIsOnlyAnIconWithACheck() {
        XCTAssertEqual(CarPlayCameraCue.decide(cameraID: 42, approaching: true, familiar: true), .none)
        let look = CameraMarkerLook.tier(id: 42, alert: CarPlayCameraCue.decide(cameraID: 42, approaching: true,
                                                                                familiar: true).mapAlertID,
                                         path: [42])
        XCTAssertEqual(CameraMarkerLook.badge(tier: look, unconfirmed: false, familiar: true),
                       CameraMarkerLook.ownBadge)
    }

    func testNoAlertNoCue() {
        XCTAssertEqual(CarPlayCameraCue.decide(cameraID: 42, approaching: false, familiar: false), .none)
        XCTAssertEqual(CarPlayCameraCue.decide(cameraID: nil, approaching: true, familiar: false), .none)
    }

    /// Баннер идёт на любом уровне тревоги ≥ 1 при скорости от
    /// directionalMinSpeedKmh: «подъезжаем» гейтов — ровно это условие.
    func testApproachingMatchesAnyAlertLevelAtDrivingSpeed() {
        let radius = 400.0
        let speed = AppConfig.directionalMinSpeedKmh
        for distance in [radius, radius * AppConfig.alertLevel2Share, radius * AppConfig.alertLevel3Share, 10] {
            XCTAssertGreaterThanOrEqual(AlertEngine.level(distance: distance, radius: radius), 1)
            XCTAssertTrue(LocationService.isApproaching(distance: distance, speedKmh: speed, radius: radius,
                                                        signalStale: false), "\(distance) м")
        }
        XCTAssertEqual(AlertEngine.level(distance: radius + 1, radius: radius), 0)
        XCTAssertFalse(LocationService.isApproaching(distance: radius + 1, speedKmh: 60, radius: radius,
                                                     signalStale: false))
        // Стоим (ниже directionalMinSpeedKmh) — тревоги и баннера нет.
        XCTAssertFalse(LocationService.isApproaching(distance: 100, speedKmh: speed - 1, radius: radius,
                                                     signalStale: false))
    }

    // MARK: - Док

    func testDockNeverHoldsACamera() {
        for own in [false, true] {
            for route in [false, true] {
                for ghost in [false, true] {
                    for fits in [false, true] {
                        let items = CarPlayCameraCue.dock(ownArrival: own, hasRoute: route, hasGhost: ghost,
                                                          fitsSecond: fits)
                        XCTAssertEqual(items.last, .speed, "скорость со знаком — всегда, справа")
                        XCTAssertLessThanOrEqual(items.count, 2)
                    }
                }
            }
        }
        XCTAssertEqual(CarPlayCameraCue.dock(ownArrival: false, hasRoute: true, hasGhost: true, fitsSecond: true),
                       [.speed], "ведёт машина — прибытие в её карточке, призрака при маршруте нет")
        XCTAssertEqual(CarPlayCameraCue.dock(ownArrival: true, hasRoute: true, hasGhost: false, fitsSecond: true),
                       [.arrival, .speed])
        XCTAssertEqual(CarPlayCameraCue.dock(ownArrival: false, hasRoute: false, hasGhost: true, fitsSecond: true),
                       [.ghost, .speed])
        XCTAssertEqual(CarPlayCameraCue.dock(ownArrival: true, hasRoute: true, hasGhost: false, fitsSecond: false),
                       [.speed], "узкий экран — только скорость")
    }

    // MARK: - Подпись на карте не чаще раза в секунду

    private func label(_ id: Int, _ text: String) -> CarPlayCameraCue.Label {
        CarPlayCameraCue.Label(id: id, latitude: 41.3, longitude: 69.2, text: text)
    }

    func testLabelRefreshIsThrottledButCameraChangeIsImmediate() {
        let shown = label(1, "400 м")
        XCTAssertFalse(CarPlayCameraCue.shouldRefreshLabel(shown: shown, new: shown, sinceLast: 10))
        XCTAssertFalse(CarPlayCameraCue.shouldRefreshLabel(shown: shown, new: label(1, "390 м"), sinceLast: 0.4))
        XCTAssertTrue(CarPlayCameraCue.shouldRefreshLabel(shown: shown, new: label(1, "390 м"), sinceLast: 1))
        XCTAssertTrue(CarPlayCameraCue.shouldRefreshLabel(shown: shown, new: label(2, "800 м"), sinceLast: 0.1))
        XCTAssertTrue(CarPlayCameraCue.shouldRefreshLabel(shown: shown, new: nil, sinceLast: 0.1),
                      "проехали — подпись уходит сразу")
        XCTAssertTrue(CarPlayCameraCue.shouldRefreshLabel(shown: nil, new: shown, sinceLast: 0))
    }

    /// Прибор плитки (снимок 05.11): своя камера позади старта маршрута, у
    /// которой маршрут дал «0 м», а по прямой — 67 м, не показывается; ноль на
    /// траверзе настоящего проезда — показывается.
    func testGaugeHidesTheZeroOfACameraBehindTheRouteStart() {
        XCTAssertFalse(CarPlayCameraCue.gaugeShows(distance: 0, straight: 67), "позади старта, прижата к нулю")
        XCTAssertTrue(CarPlayCameraCue.gaugeShows(distance: 0, straight: 12), "проезжаем — у камеры")
        XCTAssertTrue(CarPlayCameraCue.gaugeShows(distance: 380, straight: 360))
        XCTAssertTrue(CarPlayCameraCue.gaugeShows(distance: AppConfig.carPlayGaugeZeroMeters, straight: 900))
    }
}
