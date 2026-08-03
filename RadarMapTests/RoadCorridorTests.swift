//
//  RoadCorridorTests.swift
//  RadarMapTests
//
//  Коридор дороги: главный тест — камера с параллельной улицы не наша,
//  а камера на своей полосе остаётся нашей на всех дистанциях.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class RoadCorridorTests: XCTestCase {

    /// Едем строго на север из точки в Ташкенте.
    private let origin = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private let north: CLLocationDegrees = 0

    /// Точка в `metersAhead` по курсу и `metersRight` вбок от него.
    private func point(ahead metersAhead: Double, right metersRight: Double,
                       course: CLLocationDegrees = 0) -> CLLocationCoordinate2D {
        let forward = GeoMath.destination(from: origin, bearing: course,
                                          distanceMeters: metersAhead)
        guard metersRight != 0 else { return forward }
        let side = (course + (metersRight > 0 ? 90 : 270)).truncatingRemainder(dividingBy: 360)
        return GeoMath.destination(from: forward, bearing: side,
                                   distanceMeters: abs(metersRight))
    }

    // MARK: - Разложение вектора

    func testFixSplitsAlongAndAcross() {
        let fix = RoadCorridor.fix(from: origin, course: north,
                                   to: point(ahead: 300, right: 40))
        XCTAssertEqual(fix.along, 300, accuracy: 6)
        XCTAssertEqual(fix.across, 40, accuracy: 6)
    }

    func testFixIsSignedAlongCourseAndUnsignedAcross() {
        let behind = RoadCorridor.fix(from: origin, course: north,
                                      to: point(ahead: -200, right: -30))
        XCTAssertLessThan(behind.along, 0, "камера позади — продольная составляющая отрицательна")
        XCTAssertGreaterThan(behind.across, 0, "боковое отклонение всегда положительно")
        XCTAssertEqual(behind.across, 30, accuracy: 6)
    }

    // MARK: - Ширина коридора

    func testCorridorIsFlatInsideNearFieldAndGrowsBeyond() {
        let near = RoadCorridor.allowedAcross(along: 100, context: .city)
        let edge = RoadCorridor.allowedAcross(along: AppConfig.corridorNearFieldMeters,
                                              context: .city)
        let far = RoadCorridor.allowedAcross(along: 400, context: .city)
        XCTAssertEqual(near, AppConfig.corridorCityMeters, accuracy: 0.001)
        XCTAssertEqual(edge, AppConfig.corridorCityMeters, accuracy: 0.001)
        XCTAssertGreaterThan(far, near, "за ближней зоной коридор расширяется конусом")
    }

    func testHighwayCorridorIsWiderThanCity() {
        XCTAssertGreaterThan(RoadCorridor.allowedAcross(along: 300, context: .highway),
                             RoadCorridor.allowedAcross(along: 300, context: .city))
    }

    /// Ключевая гарантия против прежнего углового фильтра: конус ±70° принимал на
    /// дистанции 400 м камеру в 400·sin70° ≈ 375 м вбок. Коридор обязан быть
    /// кардинально строже — иначе вся правка бессмысленна.
    func testFarCorridorIsMuchTighterThanOldAngularFilter() {
        let oldAngularAcross = 400 * sin(70 * Double.pi / 180)   // ≈ 375 м
        let corridor = RoadCorridor.allowedAcross(along: 400, context: .highway)
        XCTAssertLessThan(corridor, 100)
        XCTAssertLessThan(corridor, oldAngularAcross / 4)
    }

    // MARK: - Решение «наша дорога»

    func testCameraOnOurLaneIsOursAtEveryDistance() {
        for distance in [50.0, 150, 300, 600, 900] {
            let camera = point(ahead: distance, right: 8)   // смещение в пределах полосы
            XCTAssertTrue(RoadCorridor.contains(camera: camera, from: origin,
                                                course: north, context: .city),
                          "камера на нашей полосе в \(Int(distance)) м должна быть нашей")
        }
    }

    /// Тот самый кейс из жалобы: камера на параллельной улице в 70 м вбок.
    func testParallelStreetCameraIsRejectedInCity() {
        let camera = point(ahead: 200, right: 70)
        XCTAssertFalse(RoadCorridor.contains(camera: camera, from: origin,
                                             course: north, context: .city))
    }

    /// Перпендикулярная улица: камера сбоку почти без продольного смещения.
    func testCrossStreetCameraIsRejected() {
        let camera = point(ahead: 30, right: 120)
        XCTAssertFalse(RoadCorridor.contains(camera: camera, from: origin,
                                             course: north, context: .city))
    }

    func testCameraBehindIsRejectedBeyondTolerance() {
        let camera = point(ahead: -120, right: 5)
        XCTAssertFalse(RoadCorridor.contains(camera: camera, from: origin,
                                             course: north, context: .city))
    }

    /// На самом траверзе продольная составляющая шумит вокруг нуля — предупреждение
    /// не должно гаснуть за мгновение до камеры.
    func testCameraJustBehindAtTraverseStaysOurs() {
        let camera = point(ahead: -10, right: 5)
        XCTAssertTrue(RoadCorridor.contains(camera: camera, from: origin,
                                            course: north, context: .city))
    }

    /// Дублёр в 60 м на дальней дистанции коридор пропускает (дорога могла
    /// повернуть), но по мере приближения допуск сужается и камера выпадает —
    /// эскалация до крика не доходит.
    func testDivergingCameraFallsOutOfCorridorAsWeApproach() {
        let side = 60.0
        XCTAssertTrue(RoadCorridor.contains(RoadCorridor.Fix(along: 500, across: side),
                                            context: .city),
                      "вдали допуск щедрый — дорога может повернуть")
        XCTAssertFalse(RoadCorridor.contains(RoadCorridor.Fix(along: 120, across: side),
                                             context: .city),
                       "вблизи коридор узкий — камера не наша")
    }

    func testWorksOnAnyCourseNotJustNorth() {
        for course in [45.0, 135, 220, 310] {
            let ours = point(ahead: 250, right: 10, course: course)
            let parallel = point(ahead: 250, right: 90, course: course)
            XCTAssertTrue(RoadCorridor.contains(camera: ours, from: origin,
                                                course: course, context: .city),
                          "курс \(Int(course))°: своя полоса")
            XCTAssertFalse(RoadCorridor.contains(camera: parallel, from: origin,
                                                 course: course, context: .city),
                           "курс \(Int(course))°: параллельная улица")
        }
    }
}
