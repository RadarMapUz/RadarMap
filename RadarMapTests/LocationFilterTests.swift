//
//  LocationFilterTests.swift
//  RadarMapTests
//
//  Гейт качества GPS-фикса. Здесь проверяется именно то, из-за чего появлялись
//  ложные проезды камер и двойные алерты: кэшированный фикс со старого места,
//  погрешность в сотню метров, мгновенный перелёт координаты. И отдельно —
//  политика курса: недостоверный курс должен отключать направленные фильтры,
//  а не заглушать настоящую камеру.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class LocationFilterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)

    private func fix(_ coordinate: CLLocationCoordinate2D,
                     accuracy: Double = 8,
                     speed: CLLocationSpeed = 15,
                     speedAccuracy: Double = 1,
                     course: CLLocationDirection = 90,
                     courseAccuracy: Double = 5,
                     at offset: TimeInterval = 0) -> LocationFilter.Fix {
        LocationFilter.Fix(lat: coordinate.latitude, lon: coordinate.longitude,
                           horizontalAccuracy: accuracy, speed: speed,
                           speedAccuracy: speedAccuracy, course: course,
                           courseAccuracy: courseAccuracy,
                           timestamp: now.addingTimeInterval(offset))
    }

    private func moved(_ meters: Double, bearing: Double = 90) -> CLLocationCoordinate2D {
        GeoMath.destination(from: base, bearing: bearing, distanceMeters: meters)
    }

    private func accepted(_ outcome: LocationFilter.Outcome) -> LocationFilter.Accepted? {
        if case .accepted(let value) = outcome { return value }
        return nil
    }

    // MARK: - Точность и свежесть

    func testAcceptsGoodFix() {
        var filter = LocationFilter()
        XCTAssertNotNil(accepted(filter.accept(fix(base), now: now)))
    }

    func testRejectsCoarseAccuracy() {
        var filter = LocationFilter()
        let outcome = filter.accept(fix(base, accuracy: 150), now: now)
        XCTAssertEqual(outcome, .rejected(.accuracy), "фикс из подземного паркинга не наш")
    }

    func testRejectsNegativeAccuracy() {
        var filter = LocationFilter()
        // Отрицательная точность = система сама считает координату недостоверной.
        XCTAssertEqual(filter.accept(fix(base, accuracy: -1), now: now), .rejected(.accuracy))
    }

    func testAcceptsAccuracyAtBoundary() {
        var filter = LocationFilter()
        XCTAssertNotNil(accepted(filter.accept(
            fix(base, accuracy: AppConfig.maxHorizontalAccuracyMeters), now: now)))
    }

    /// Первый фикс после запуска или туннеля часто кэшированный со старого места —
    /// именно он «проезжал» камеру и записывал ложный проезд.
    func testRejectsStaleCachedFix() {
        var filter = LocationFilter()
        XCTAssertEqual(filter.accept(fix(base, at: -120), now: now), .rejected(.stale))
    }

    func testRejectsFixFromFuture() {
        var filter = LocationFilter()
        XCTAssertEqual(filter.accept(fix(base, at: 120), now: now), .rejected(.stale))
    }

    // MARK: - Перелёт координаты

    func testRejectsImpossibleJump() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base), now: now)
        // 500 м за секунду — 1800 км/ч.
        let outcome = filter.accept(fix(moved(500), at: 1), now: now.addingTimeInterval(1))
        XCTAssertEqual(outcome, .rejected(.jump))
    }

    func testAcceptsFastButRealisticMove() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base), now: now)
        // 33 м за секунду — 120 км/ч по трассе, законно.
        XCTAssertNotNil(accepted(filter.accept(fix(moved(33), at: 1),
                                               now: now.addingTimeInterval(1))))
    }

    /// После долгой паузы (стоянка, работа в фоне) большое смещение нормально —
    /// иначе после парковки первый фикс в новом районе всегда отбрасывался бы.
    func testAcceptsBigMoveAfterLongGap() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base), now: now)
        let later = now.addingTimeInterval(600)
        XCTAssertNotNil(accepted(filter.accept(fix(moved(20_000), at: 600), now: later)))
    }

    func testRejectsJumpWithSameTimestamp() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base), now: now)
        XCTAssertEqual(filter.accept(fix(moved(400)), now: now), .rejected(.jump))
    }

    // MARK: - Курс

    func testTrustsRawCourseWhenSystemIsConfident() {
        var filter = LocationFilter()
        let result = accepted(filter.accept(fix(base, course: 137, courseAccuracy: 4), now: now))
        XCTAssertEqual(result?.course ?? -1, 137, accuracy: 0.001)
    }

    /// Плохая точность курса + есть прошлая точка → курс по земле. Именно этот
    /// случай защищает гейт оси: сырому курсу верить нельзя, но и молчать нельзя.
    func testDerivesCourseFromGroundTrackWhenCourseAccuracyIsBad() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, courseAccuracy: 4), now: now)
        let result = accepted(filter.accept(
            fix(moved(30, bearing: 180), course: 15, courseAccuracy: 90, at: 2),
            now: now.addingTimeInterval(2)))
        XCTAssertEqual(result?.course ?? -1, 180, accuracy: 1.5,
                       "курс по земле — на юг, а не сырые 15°")
    }

    func testUntrustedCourseWithoutPreviousFixIsMinusOne() {
        var filter = LocationFilter()
        let result = accepted(filter.accept(fix(base, course: 90, courseAccuracy: -1), now: now))
        XCTAssertEqual(result?.course, -1,
                       "курса нет — направленные фильтры обязаны отключиться")
    }

    func testTinyMoveDoesNotProduceCourse() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, courseAccuracy: 4), now: now)
        // Сдвиг 3 м — это шум стоящей машины, а не направление.
        let result = accepted(filter.accept(fix(moved(3), courseAccuracy: -1, at: 1),
                                            now: now.addingTimeInterval(1)))
        XCTAssertEqual(result?.course, -1)
    }

    func testResetForgetsPreviousFix() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, courseAccuracy: 4), now: now)
        filter.reset()
        let result = accepted(filter.accept(fix(moved(30), courseAccuracy: -1, at: 2),
                                            now: now.addingTimeInterval(2)))
        XCTAssertEqual(result?.course, -1, "после сброса опоры для курса нет")
    }

    // MARK: - Скорость

    func testSpeedIsNilWhenUnknown() {
        var filter = LocationFilter()
        XCTAssertNil(accepted(filter.accept(fix(base, speed: -1), now: now))?.speed,
                     "в туннеле скорость держим прошлую, а не обнуляем")
    }

    func testSpeedIsNilWhenAccuracyIsBad() {
        var filter = LocationFilter()
        XCTAssertNil(accepted(filter.accept(fix(base, speed: 20, speedAccuracy: 40),
                                            now: now))?.speed)
    }

    /// Устройство может не оценивать точность скорости (−1) — сама скорость при
    /// этом обычно верна, иначе спидометр молчал бы на таких телефонах.
    func testSpeedIsKeptWhenAccuracyIsUnavailable() {
        var filter = LocationFilter()
        let result = accepted(filter.accept(fix(base, speed: 20, speedAccuracy: -1), now: now))
        XCTAssertEqual(result?.speed ?? 0, 20, accuracy: 0.001)
    }
}
