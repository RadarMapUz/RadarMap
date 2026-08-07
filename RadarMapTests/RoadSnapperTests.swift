//
//  RoadSnapperTests.swift
//  RadarMapTests
//
//  Прижим картинки к дороге: гистерезис против мигания и честный отрыв на
//  съезде. Отдельно закреплена граница применения — снап питает только
//  отображение; сырой фикс для гейтов эти тесты не трогают, потому что
//  снап туда просто не подключён (см. RoadSnapper — граница в комментарии,
//  подключение в LocationService.handleLocationBody после гейтов).
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RoadSnapperTests: XCTestCase {

    private func hit(distance: Double, bearing: Double = 90,
                     limit: Int = 60) -> LimitIndex.RoadHit {
        LimitIndex.RoadHit(limit: limit,
                           coordinate: CLLocationCoordinate2D(latitude: 41.31,
                                                              longitude: 69.25),
                           bearingDegrees: bearing, distanceMeters: distance)
    }

    func testEngagesOnlyCloseToRoad() {
        var snapper = RoadSnapper()
        // 30 м от оси — ещё не «на дороге»: прилипание с такого расстояния
        // тащило бы на проспект машину, едущую по дублёру.
        XCTAssertNil(snapper.update(course: 90, hit: hit(distance: 30)))
        XCTAssertNotNil(snapper.update(course: 90, hit: hit(distance: 10)))
    }

    /// Сердце гистерезиса: прилипли на 10 м — держимся и на 30, но не на 40.
    /// Без этого точка на границе мигала бы «на дороге/рядом» от шума GPS.
    func testHoldsThroughNoiseButReleasesOnDeparture() {
        var snapper = RoadSnapper()
        XCTAssertNotNil(snapper.update(course: 90, hit: hit(distance: 10)))
        XCTAssertNotNil(snapper.update(course: 90, hit: hit(distance: 30)),
                        "внутри удержания шум не отрывает")
        XCTAssertNil(snapper.update(course: 90, hit: hit(distance: 40)),
                     "съезд во двор рвёт снап честно")
        XCTAssertNil(snapper.update(course: 90, hit: hit(distance: 30)),
                     "после отрыва прилипание снова только с ближней зоны")
    }

    func testNoRoadMeansRawPicture() {
        var snapper = RoadSnapper()
        _ = snapper.update(course: 90, hit: hit(distance: 10))
        XCTAssertNil(snapper.update(course: 90, hit: nil))
        XCTAssertFalse(snapper.isSnapped)
    }

    // MARK: - Курс дороги

    func testCourseSnapsToNearestAxisDirection() {
        var snapper = RoadSnapper()
        // Ось 90°, едем на 275° — ближняя сторона оси 270°: курс дороги её и берёт.
        let snapped = snapper.update(course: 275, hit: hit(distance: 10, bearing: 90))
        XCTAssertEqual(snapped?.courseDegrees, 270)
    }

    /// В манёвре (расходимся с осью сильнее допуска) курс дороги — враньё:
    /// перестраиваемся или поворачиваем, стрелка обязана идти по нашему курсу.
    func testCourseNotReplacedDuringManeuver() {
        var snapper = RoadSnapper()
        let snapped = snapper.update(course: 130, hit: hit(distance: 10, bearing: 90))
        XCTAssertNotNil(snapped, "позиция прижата")
        XCTAssertNil(snapped?.courseDegrees, "но курс — наш, не дороги")
    }

    func testNoCourseMeansNoCourseSubstitution() {
        var snapper = RoadSnapper()
        let snapped = snapper.update(course: -1, hit: hit(distance: 10))
        XCTAssertNotNil(snapped)
        XCTAssertNil(snapped?.courseDegrees)
    }

    func testResetForgetsStickiness() {
        var snapper = RoadSnapper()
        _ = snapper.update(course: 90, hit: hit(distance: 10))
        snapper.reset()
        XCTAssertNil(snapper.update(course: 90, hit: hit(distance: 30)),
                     "после сброса зона удержания не действует")
    }
}
