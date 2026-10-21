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
        _ = filter.accept(fix(base, speed: 0.5, courseAccuracy: 4), now: now)
        // Сдвиг 3 м — это шум стоящей машины, а не направление.
        let result = accepted(filter.accept(fix(moved(3), speed: 0.5, courseAccuracy: -1, at: 1),
                                            now: now.addingTimeInterval(1)))
        XCTAssertEqual(result?.course, -1)
    }

    // MARK: - Курс по земле на городской скорости (прогон 13.3)

    /// 40 км/ч, фиксы раз в секунду, сырому курсу верить нельзя: соседние
    /// фиксы в 11 м друг от друга — меньше шага курса по земле. Раньше курса
    /// не было ВСЮ дорогу (гейты выключены, звучали камеры соседних улиц);
    /// теперь опора — позапрошлый фикс.
    func testCitySpeedDerivesCourseFromEarlierFix() {
        var filter = LocationFilter()
        var courses: [CLLocationDirection] = []
        for step in 0..<6 {
            let t = Double(step)
            let point = moved(11.1 * t, bearing: 200)
            courses.append(accepted(filter.accept(
                fix(point, speed: 11.1, course: 200, courseAccuracy: -1, at: t),
                now: now.addingTimeInterval(t)))?.course ?? -2)
        }
        XCTAssertEqual(courses[0], -1, "опоры ещё нет")
        XCTAssertEqual(courses[1], -1, "11 м — меньше шага, а старше опоры нет")
        for course in courses.dropFirst(2) {
            XCTAssertEqual(course, 200, accuracy: 1, "с третьего фикса курс есть: \(courses)")
        }
    }

    /// Стоящая машина: шум приёмника 3–4 м туда-сюда за пять секунд не
    /// набирает шага — курса нет, как и раньше.
    func testStandingNoiseNeverReachesTheStep() {
        var filter = LocationFilter()
        let wander: [(Double, Double)] = [(0, 0), (4, 90), (3, 250), (4, 10), (2, 180), (4, 300)]
        for (step, (meters, bearing)) in wander.enumerated() {
            let t = Double(step)
            let course = accepted(filter.accept(
                fix(moved(meters, bearing: bearing), speed: 0.4, course: -1, courseAccuracy: -1, at: t),
                now: now.addingTimeInterval(t)))?.course
            XCTAssertEqual(course, -1, "t=\(t)")
        }
    }

    /// Ползём 2 м/с: шаг набирается за 6 с — дольше окна, опора уже не
    /// годится, курса нет.
    func testAnchorOlderThanWindowIsIgnored() {
        var filter = LocationFilter()
        var last: CLLocationDirection?
        for step in 0..<8 {
            let t = Double(step)
            last = accepted(filter.accept(
                fix(moved(2 * t, bearing: 90), speed: 2, course: -1, courseAccuracy: -1, at: t),
                now: now.addingTimeInterval(t)))?.course
        }
        XCTAssertEqual(last, -1)
    }

    // MARK: - Курс по земле только между годными фиксами (14.13)

    /// Едем `speed` м/с на 200°, фикс раз в секунду с точностью `accuracy`
    /// (сырого курса нет, как в симуляторе) — курсы, которые отдал фильтр.
    private func groundCourses(speed: Double, accuracy: Double, count: Int = 7) -> [CLLocationDirection] {
        var filter = LocationFilter()
        return (0..<count).map { step in
            let t = Double(step)
            return accepted(filter.accept(
                fix(moved(speed * t, bearing: 200), accuracy: accuracy, speed: speed,
                    course: 200, courseAccuracy: -1, at: t),
                now: now.addingTimeInterval(t)))?.course ?? -2
        }
    }

    /// Фиксы уровня Wi-Fi (60 м): сдвиг в 30 м между ними — меньше их
    /// собственной погрешности, «курс» по ним — шум, а гейты ему верили и
    /// глушили камеру на нашей дороге по оси. Курса нет — гейты молчат.
    func testWiFiQualityFixesGiveNoGroundCourse() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, accuracy: 60, courseAccuracy: -1), now: now)
        let result = accepted(filter.accept(
            fix(moved(30, bearing: 180), accuracy: 60, course: -1, courseAccuracy: -1, at: 2),
            now: now.addingTimeInterval(2)))
        XCTAssertEqual(result?.course, -1, "курс по шуму — не курс")
        // И на скорости, где сдвиг за пять секунд вдвое больше погрешности
        // каждого: фикс хуже порога доказательством не бывает.
        XCTAssertEqual(groundCourses(speed: 25, accuracy: 60).filter { $0 >= 0 }, [])
        XCTAssertEqual(groundCourses(speed: 11.1, accuracy: AppConfig.courseProofMaxAccuracyMeters + 1)
            .filter { $0 >= 0 }, [])
    }

    /// Годный фикс после плохого: плохой — не опора. Опора — прошлый годный.
    /// Плохой фикс сам курса не получает, даже между двумя годными.
    func testPoorFixIsNeverAnAnchor() {
        var filter = LocationFilter()
        // 40 км/ч на 200°, годный GPS.
        for step in 0..<3 {
            let t = Double(step)
            _ = filter.accept(fix(moved(11.1 * t, bearing: 200), course: -1, courseAccuracy: -1, at: t),
                              now: now.addingTimeInterval(t))
        }
        // Wi-Fi-фикс в 40 м вбок от дороги.
        let aside = GeoMath.destination(from: moved(33.3, bearing: 200), bearing: 290, distanceMeters: 40)
        let poor = accepted(filter.accept(fix(aside, accuracy: 60, course: -1, courseAccuracy: -1, at: 3),
                                          now: now.addingTimeInterval(3)))
        XCTAssertEqual(poor?.course, -1, "плохой фикс курса не получает")
        let back = accepted(filter.accept(fix(moved(44.4, bearing: 200), course: -1, courseAccuracy: -1, at: 4),
                                          now: now.addingTimeInterval(4)))
        XCTAssertEqual(back?.course ?? -1, 200, accuracy: 1,
                       "курс — от прошлого годного, а не от плохого в 40 м вбок")
    }

    /// Сдвиг меньше суммарной погрешности двух фиксов — курса нет: на
    /// фиксах в 20 м на 40 км/ч опора нужна в 40 м, то есть за 4 секунды,
    /// а не за две, как на хорошем GPS.
    func testStepGrowsWithTheFixesOwnAccuracy() {
        let courses = groundCourses(speed: 11.1, accuracy: 20)
        XCTAssertEqual(Array(courses.prefix(4)), [-1, -1, -1, -1], "\(courses)")
        for course in courses.dropFirst(4) {
            XCTAssertEqual(course, 200, accuracy: 1, "с опорой в 44 м курс есть: \(courses)")
        }
        // Два фикса, ушедшие на всю погрешность поперёк пути в разные
        // стороны, не разворачивают курс за порог гейта оси.
        let worstTurn = atan(1 / AppConfig.derivedCourseAccuracyFactor) * 180 / .pi
        XCTAssertLessThan(worstTurn, AppConfig.cameraAxisMaxAngle)
    }

    /// Хороший GPS на городских 30–40 км/ч — как в 13.3: курс со второго-
    /// третьего фикса и дальше на каждом. Симулятор отдаёт 5 м, телефон под
    /// открытым небом — 3–10 м.
    func testGoodFixesKeepTheCityCourse() {
        for (speed, accuracy, warmUp) in [(8.33, 5.0, 2), (11.1, 5.0, 2), (11.1, 10.0, 2), (8.33, 10.0, 3)] {
            let courses = groundCourses(speed: speed, accuracy: accuracy)
            XCTAssertEqual(Array(courses.prefix(warmUp)), Array(repeating: -1, count: warmUp),
                           "\(speed) м/с, \(accuracy) м: \(courses)")
            for course in courses.dropFirst(warmUp) {
                XCTAssertEqual(course, 200, accuracy: 1, "\(speed) м/с, \(accuracy) м: \(courses)")
            }
        }
    }

    /// Сырой курс, в котором система сама уверена (доплер), — по-прежнему
    /// курс и на плохой координате: каньон портит позицию, а не скорость.
    func testConfidentRawCourseSurvivesAPoorPosition() {
        var filter = LocationFilter()
        let result = accepted(filter.accept(fix(base, accuracy: 50, course: 137, courseAccuracy: 8), now: now))
        XCTAssertEqual(result?.course ?? -1, 137, accuracy: 0.001)
    }

    // MARK: - Повторный фикс на ходу (прогон 20.10)

    /// iOS после перенастройки точности отдаёт тот же фикс ещё раз через
    /// 2 мс — без своего курса, и по земле его не посчитать (сдвиг ноль).
    /// −1 на один тик выключал гейты, и звучала камера соседней улицы.
    func testRepeatedFixOnTheMoveKeepsTheCourse() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, speed: 14, course: 2, courseAccuracy: 4), now: now)
        let repeated = accepted(filter.accept(fix(base, speed: 14, course: -1, courseAccuracy: -1, at: 0.002),
                                              now: now.addingTimeInterval(0.002)))
        XCTAssertEqual(repeated?.course, 2)
        // Симулятор на точке пути: секунда прошла, а сдвиг 2 м при 14 м/с —
        // тоже повтор, не измерение.
        let stalled = accepted(filter.accept(fix(moved(2, bearing: 2), speed: 14, course: -1,
                                                 courseAccuracy: -1, at: 1),
                                             now: now.addingTimeInterval(1)))
        XCTAssertEqual(stalled?.course, 2)
    }

    /// Настоящий фикс в повороте на 30 км/ч сдвигается на свои 8 м — меньше
    /// шага курса по земле, но это измерение, а не повтор: курса нет, гейты
    /// молчат, как и раньше.
    func testRealSlowFixIsNotARepeat() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, speed: 8.3, course: 90, courseAccuracy: 4), now: now)
        let turning = accepted(filter.accept(fix(moved(8, bearing: 150), speed: 8.3, course: -1,
                                                 courseAccuracy: -1, at: 1),
                                             now: now.addingTimeInterval(1)))
        XCTAssertEqual(turning?.course, -1)
    }

    /// Сырой курс повтора, пусть недоверенный, смотрит в другую сторону —
    /// это поворот (городской каньон отстаёт позицией), курс не держим.
    func testRawCourseFarFromHeldIsATurnNotARepeat() {
        var filter = LocationFilter()
        _ = filter.accept(fix(base, speed: 8, course: 90, courseAccuracy: 4), now: now)
        let turned = accepted(filter.accept(fix(moved(2, bearing: 170), speed: 8, course: 175,
                                                courseAccuracy: 40, at: 1),
                                            now: now.addingTimeInterval(1)))
        XCTAssertEqual(turned?.course, -1)
        let close = accepted(filter.accept(fix(moved(3, bearing: 95), speed: 8, course: 100,
                                               courseAccuracy: 40, at: 1.2),
                                           now: now.addingTimeInterval(1.2)))
        XCTAssertEqual(close?.course, 90, "рядом с удержанным — повтор, держим")
    }

    /// Стоя курс не держим, удержанный опору не продлевает, а дольше
    /// `courseHoldSeconds` курса нет.
    func testHoldIsShortAndOnlyOnTheMove() {
        var standing = LocationFilter()
        _ = standing.accept(fix(base, speed: 1, course: 90, courseAccuracy: 4), now: now)
        XCTAssertEqual(accepted(standing.accept(fix(base, speed: 1, course: -1, courseAccuracy: -1, at: 0.002),
                                                now: now.addingTimeInterval(0.002)))?.course, -1)

        var filter = LocationFilter()
        _ = filter.accept(fix(base, speed: 14, course: 90, courseAccuracy: 4), now: now)
        var t = 0.0
        var last: CLLocationDirection?
        // Цепочка «застывших» фиксов раз в секунду: держим, пока не истёк срок.
        for _ in 0..<4 {
            t += 1
            last = accepted(filter.accept(fix(base, speed: 14, course: -1, courseAccuracy: -1, at: t),
                                          now: now.addingTimeInterval(t)))?.course
            if t <= AppConfig.courseHoldSeconds { XCTAssertEqual(last, 90, "t=\(t)") }
        }
        XCTAssertEqual(last, -1, "удержание не продлевает само себя")
        filter.reset()
        XCTAssertEqual(accepted(filter.accept(fix(base, speed: 14, course: -1, courseAccuracy: -1, at: t + 0.002),
                                              now: now.addingTimeInterval(t + 0.002)))?.course, -1,
                       "после сброса держать нечего")
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
