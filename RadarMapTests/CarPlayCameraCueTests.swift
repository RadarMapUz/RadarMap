//
//  CarPlayCameraCueTests.swift
//  RadarMapTests
//
//  Камера впереди в машине (25.F): док — только скорость; баннер, подпись
//  «400 м» на карте и строка в оценках — у чужой камеры в тревоге; своя
//  камера — только значок с галочкой.
//

import CoreLocation
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

    /// Прибор плитки (снимок 05.11): маршрут держит проеханную камеру «0 м» до
    /// 60 м за ней. Светофор в 50 м за камерой — на плитке не должно быть «0 м»
    /// про камеру за спиной; ноль на самом траверзе показывается.
    func testGaugeHidesTheZeroOfACameraBehindUs() {
        XCTAssertFalse(CarPlayCameraCue.gaugeShows(distance: 0, straight: 50), "стоим за камерой на светофоре")
        XCTAssertFalse(CarPlayCameraCue.gaugeShows(distance: 0, straight: 67), "за стартом, координата не доказывает")
        XCTAssertTrue(CarPlayCameraCue.gaugeShows(distance: 0, straight: 12), "проезжаем — у камеры")
        XCTAssertTrue(CarPlayCameraCue.gaugeShows(distance: 380, straight: 360))
        XCTAssertTrue(CarPlayCameraCue.gaugeShows(distance: AppConfig.carPlayGaugeZeroMeters, straight: 900))
    }

    // MARK: - «0 м» проехавшей камеры в баннере и подписи

    private let me = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.24)

    /// Камера в `north` метрах севернее нас и `east` восточнее.
    private func camera(north: Double, east: Double = 0) -> Camera {
        var at = GeoMath.destination(from: me, bearing: 0, distanceMeters: north)
        at = GeoMath.destination(from: at, bearing: 90, distanceMeters: east)
        return Camera(id: 7, region: "Т", city: "", location: "к", lat: at.latitude, lon: at.longitude,
                      type: "Стационар радар", violations: [], needsReview: false, lanes: 2, cls: "primary")
    }

    private func situation(course: Double = 0, speed: Double = 50, accuracy: Double = 8) -> LocationGates.Situation {
        LocationGates.Situation(coordinate: me, course: course, speedKmh: speed, horizontalAccuracy: accuracy,
                                context: .city)
    }

    private func isPassed(_ camera: Camera, distance: Double = 0, course: Double = 0, speed: Double = 50,
                          accuracy: Double = 8, coarse: Bool = false) -> Bool {
        CarPlayCameraCue.isProvenPassedZero(distance: distance, camera: camera,
                                            in: situation(course: course, speed: speed, accuracy: accuracy),
                                            positionCoarse: coarse)
    }

    func testZeroOfACameraProvenBehindIsNotShown() {
        XCTAssertTrue(isPassed(camera(north: -50)), "50 м за спиной по курсу")
        XCTAssertTrue(isPassed(camera(north: -59), distance: 4), "до конца допуска маршрута")
    }

    /// Рядом с камерой и сбоку от неё ноль — настоящий траверз.
    func testZeroRightAtTheCameraStaysShown() {
        XCTAssertFalse(isPassed(camera(north: 0)))
        XCTAssertFalse(isPassed(camera(north: -20)), "20 м — шум продольной составляющей")
        XCTAssertFalse(isPassed(camera(north: -AppConfig.alertPassedBehindMeters + 1)))
        XCTAssertFalse(isPassed(camera(north: 0, east: 60)), "сбоку на широком проспекте: не позади")
    }

    func testCameraAheadIsNeverPassedEvenWithZeroDistance() {
        XCTAssertFalse(isPassed(camera(north: 50)), "маршрут дал ноль, а камера впереди")
    }

    func testUnknownCourseShowsAsBefore() {
        XCTAssertFalse(isPassed(camera(north: -50), course: -1))
    }

    func testBadPositionShowsAsBefore() {
        XCTAssertFalse(isPassed(camera(north: -50), coarse: true), "грубая позиция")
        XCTAssertFalse(isPassed(camera(north: -50), accuracy: AppConfig.courseProofMaxAccuracyMeters + 1))
        XCTAssertFalse(isPassed(camera(north: -50), accuracy: -1), "точность неизвестна")
        XCTAssertFalse(isPassed(camera(north: -50), speed: AppConfig.directionalMinSpeedKmh - 1), "стоим — курсу веры нет")
    }

    /// Ненулевое расстояние — не проезд: петля маршрута, камера за спиной по
    /// прямой, а по дороге до неё ещё ехать.
    func testRealDistanceIsAlwaysShown() {
        XCTAssertFalse(isPassed(camera(north: -50), distance: AppConfig.carPlayGaugeZeroMeters))
        XCTAssertFalse(isPassed(camera(north: -50), distance: 300))
    }

    func testPassedZeroHoldSurvivesAMomentWithoutCourse() {
        var hold = CarPlayCameraCue.PassedZeroHold()
        XCTAssertFalse(hold.update(cameraID: 7, distance: 0, straight: 30, proven: false), "доказательства ещё не было")
        XCTAssertTrue(hold.update(cameraID: 7, distance: 0, straight: 45, proven: true))
        XCTAssertTrue(hold.update(cameraID: 7, distance: 0, straight: 50, proven: false), "миг без курса")
        XCTAssertFalse(hold.update(cameraID: 8, distance: 0, straight: 300, proven: false), "другая камера")
    }

    func testPassedZeroHoldReleasesForANewApproach() {
        var hold = CarPlayCameraCue.PassedZeroHold()
        XCTAssertTrue(hold.update(cameraID: 7, distance: 0, straight: 45, proven: true))
        XCTAssertFalse(hold.update(cameraID: 7, distance: 250, straight: 240, proven: false), "настоящее расстояние")
        XCTAssertTrue(hold.update(cameraID: 7, distance: 0, straight: 45, proven: true))
        XCTAssertFalse(hold.update(cameraID: 7, distance: 0, straight: 10, proven: false), "снова у камеры")
    }

    /// Показ не меняет решения: баннер, облик и подпись считает только
    /// `decide` от гейтов, и ей нечего сказать о проезде.
    func testAlertDecisionDoesNotKnowAboutThePass() {
        let cue = CarPlayCameraCue.decide(cameraID: 7, approaching: true, familiar: false)
        XCTAssertEqual(cue, CarPlayCameraCue.Cue(banner: true, mapAlertID: 7, distanceLabel: true))
        XCTAssertTrue(LocationService.isApproaching(distance: 0, speedKmh: 50, radius: 400, signalStale: false))
    }
}
