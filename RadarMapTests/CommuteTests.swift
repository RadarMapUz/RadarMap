//
//  CommuteTests.swift
//  RadarMapTests
//
//  Дорога на работу и домой: какая поездка куда, что такое «обычно» и когда
//  выезжать. Главное, что нельзя сломать: случайная поездка по кварталу не
//  становится «дорогой на работу», совет не появляется без данных, а заезд в
//  магазин по пути не выдаётся за пробку.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CommuteTests: XCTestCase {

    private let home = CLLocationCoordinate2D(latitude: 41.3400, longitude: 69.2100)
    private let work = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return c
    }
    /// Пятница, 12:00 по Ташкенту.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))! }

    private func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func record(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D,
                        start: Date, minutes: Double, stopMinutes: Double = 0) -> TripRecord {
        let stops: [TripStop]? = stopMinutes > 0 ? [TripStop(
            id: UUID(), lat: to.latitude, lon: to.longitude,
            from: start.addingTimeInterval(600),
            to: start.addingTimeInterval(600 + stopMinutes * 60))] : nil
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval((minutes + stopMinutes) * 60),
                          distanceMeters: 12_000, maxSpeedKmh: 70, passed: [],
                          endLat: to.latitude, endLon: to.longitude, stops: stops,
                          startLat: from?.latitude, startLon: from?.longitude)
    }

    // MARK: - Направление

    func testTripsAreClassifiedByBothEnds() {
        let history = [
            record(from: home, to: work, start: at(daysAgo: 1, 8, 20), minutes: 50),
            record(from: work, to: home, start: at(daysAgo: 1, 18, 30), minutes: 40),
            record(from: home, to: CLLocationCoordinate2D(latitude: 41.36, longitude: 69.30),
                   start: at(daysAgo: 2, 11, 0), minutes: 20),
        ]
        let trips = Commute.trips(history: history, home: home, work: work)
        XCTAssertEqual(trips.map(\.direction), [.toHome, .toWork], "новые первыми; поездка в магазин — не дорога")
        XCTAssertEqual(trips.first?.duration, 40 * 60)
    }

    /// Автостарт поймал поездку в 800 м от дома (в кармане, уже на ходу) —
    /// это всё ещё дорога на работу; конец — по-прежнему строго у работы
    /// (сценарий S20, 20.10).
    func testLateAutoStartStillCountsAsCommute() {
        let lateStart = CLLocationCoordinate2D(latitude: home.latitude - 0.0072, longitude: home.longitude)  // ~800 м
        let nearWork = CLLocationCoordinate2D(latitude: work.latitude - 0.0072, longitude: work.longitude)
        let history = [
            record(from: lateStart, to: work, start: at(daysAgo: 1, 8, 20), minutes: 48),
            record(from: home, to: nearWork, start: at(daysAgo: 2, 8, 20), minutes: 48),
        ]
        let trips = Commute.trips(history: history, home: home, work: work)
        XCTAssertEqual(trips.count, 1, "конец в 800 м от работы — не дорога на работу")
        XCTAssertEqual(trips.first?.direction, .toWork)
    }

    /// Старая запись без точки старта и без трека: старт — конец предыдущей
    /// поездки, если машина простояла ночь, а не неделю.
    func testChainedStartForOldRecords() {
        let evening = record(from: work, to: home, start: at(daysAgo: 2, 18, 0), minutes: 40)
        let morning = record(from: nil, to: work, start: at(daysAgo: 1, 8, 0), minutes: 45)
        let trips = Commute.trips(history: [morning, evening], home: home, work: work)
        XCTAssertEqual(trips.first?.direction, .toWork)

        let weekLater = record(from: nil, to: work, start: at(daysAgo: 1, 8, 0), minutes: 45)
        let longAgo = record(from: work, to: home, start: at(daysAgo: 9, 18, 0), minutes: 40)
        XCTAssertEqual(Commute.trips(history: [weekLater, longAgo], home: home, work: work).count, 1,
                       "после недели стоянки старт не угадываем — остаётся только та, где он известен")
    }

    func testTooCloseHomeAndWorkGiveNoCommute() {
        let near = CLLocationCoordinate2D(latitude: home.latitude + 0.003, longitude: home.longitude)
        let history = [record(from: home, to: near, start: at(daysAgo: 1, 8, 0), minutes: 5)]
        XCTAssertTrue(Commute.trips(history: history, home: home, work: near).isEmpty)
    }

    /// Заезд в магазин по дороге домой — не пробка: в пути считается без
    /// стоянки склейки.
    func testMergedStopIsNotCountedAsTravel() {
        let history = [record(from: work, to: home, start: at(daysAgo: 1, 18, 0),
                              minutes: 40, stopMinutes: 25)]
        let trips = Commute.trips(history: history, home: home, work: work)
        XCTAssertEqual(trips.first?.duration, 40 * 60)
    }

    // MARK: - «Обычно» и совет

    private func weekOfMornings(_ plan: [(daysAgo: Int, h: Int, m: Int, minutes: Double)]) -> [Commute.Trip] {
        let history = plan.map { record(from: home, to: work, start: at(daysAgo: $0.daysAgo, $0.h, $0.m),
                                        minutes: $0.minutes) }
        return Commute.trips(history: history, home: home, work: work)
    }

    func testUsualNeedsThreeTrips() {
        let two = weekOfMornings([(1, 8, 20, 50), (2, 8, 25, 52)])
        let summary = Commute.summary(.toWork, trips: two, now: now, calendar: calendar)
        XCTAssertNotNil(summary, "последняя поездка показывается и одна")
        XCTAssertNil(summary?.usual, "по двум поездкам «обычно» не говорим")
        XCTAssertNil(summary?.best)
    }

    func testUsualIsMedianAndDelayIsAgainstIt() {
        let trips = weekOfMornings([(1, 8, 22, 55), (2, 8, 20, 43), (3, 8, 25, 41), (4, 8, 18, 45), (5, 8, 30, 44)])
        let summary = Commute.summary(.toWork, trips: trips, now: now, calendar: calendar)!
        XCTAssertEqual(summary.usual, 44 * 60, "медиана, а не среднее: одна пробка не сдвигает норму")
        XCTAssertEqual(summary.last.duration, 55 * 60)
        XCTAssertEqual(summary.lastDelay, 11 * 60)
        XCTAssertTrue(summary.lastIsSlower)
        XCTAssertEqual(summary.usualDepartureMinute, 8 * 60 + 22)
    }

    /// Неделя дороги (8.8.15): медиана за 7 суток против медианы месяца.
    /// Обычно 44 мин, половина поездок — 44–47; на этой неделе 50, 47 и 53 —
    /// обычно 50, вне разброса.
    func testWeekMedianAgainstUsual() throws {
        let trips = weekOfMornings([(1, 8, 20, 50), (2, 8, 25, 47), (3, 8, 22, 53),
                                    (9, 8, 20, 44), (10, 8, 18, 43), (11, 8, 25, 44), (12, 8, 30, 45),
                                    (15, 8, 20, 42), (16, 8, 22, 44)])
        let summary = try XCTUnwrap(Commute.summary(.toWork, trips: trips, now: now, calendar: calendar))
        let week = try XCTUnwrap(summary.week)
        XCTAssertEqual(week.trips, 3)
        XCTAssertEqual(week.median, 50 * 60, accuracy: 1)
        XCTAssertEqual(week.delta, week.median - (summary.usual ?? 0), accuracy: 1)
        XCTAssertTrue(week.isNoticeable)
    }

    /// Меньше двух поездок за неделю или без «обычно» — недели нет; разница
    /// меньше 2 мин — строка «как обычно» ничего не добавляет.
    func testWeekNeedsTwoTripsAndAnUsual() {
        let one = weekOfMornings([(1, 8, 20, 50), (9, 8, 20, 44), (10, 8, 18, 43), (11, 8, 25, 44)])
        XCTAssertNil(Commute.summary(.toWork, trips: one, now: now, calendar: calendar)?.week)
        XCTAssertNil(Commute.week(one, usual: nil, now: now))
        let calm = weekOfMornings([(1, 8, 20, 45), (2, 8, 25, 44), (9, 8, 20, 44), (10, 8, 18, 43)])
        XCTAssertEqual(Commute.summary(.toWork, trips: calm, now: now, calendar: calendar)?.week?.isNoticeable, false)
    }

    func testBestWindowAdvisesEarlierDeparture() {
        let trips = weekOfMornings([
            (1, 8, 22, 55), (2, 8, 20, 52), (3, 8, 25, 50), (6, 8, 21, 54),
            (4, 7, 46, 36), (5, 7, 50, 38),
        ])
        let summary = Commute.summary(.toWork, trips: trips, now: now, calendar: calendar)!
        let best = try! XCTUnwrap(summary.best)
        XCTAssertEqual(best.startMinute, 7 * 60 + 45)
        XCTAssertEqual(best.medianDuration, 37 * 60)
        XCTAssertGreaterThanOrEqual(best.saving, AppConfig.commuteMinSavingSeconds)
    }

    func testNoAdviceWithoutRealSaving() {
        let trips = weekOfMornings([(1, 8, 22, 45), (2, 8, 20, 44), (3, 7, 46, 43), (4, 7, 50, 42)])
        XCTAssertNil(Commute.summary(.toWork, trips: trips, now: now, calendar: calendar)?.best,
                     "две минуты разницы — не совет")
    }

    func testNoAdviceFarFromUsualDeparture() {
        let trips = weekOfMornings([(1, 8, 22, 55), (2, 8, 20, 52), (3, 8, 25, 50),
                                    (4, 5, 30, 25), (5, 5, 40, 26)])
        XCTAssertNil(Commute.summary(.toWork, trips: trips, now: now, calendar: calendar)?.best,
                     "«выезжайте в 5 утра» — не совет")
    }

    /// Совет — по устойчивому окну: в 7:45 одна удачная поездка (30 мин) и
    /// одна обычная (52) — медиана 41 «экономит», но закономерности нет.
    func testNoAdviceFromOneLuckyDay() {
        let trips = weekOfMornings([(1, 8, 22, 52), (2, 8, 20, 53), (3, 8, 25, 51), (6, 8, 21, 52),
                                    (4, 7, 46, 30), (5, 7, 50, 52)])
        XCTAssertNil(Commute.summary(.toWork, trips: trips, now: now, calendar: calendar)?.best)
    }

    // MARK: - Своё окно времени (разбор 10.11)

    private func evenings(_ plan: [(daysAgo: Int, h: Int, m: Int, minutes: Double)]) -> [Commute.Trip] {
        let history = plan.map { record(from: work, to: home, start: at(daysAgo: $0.daysAgo, $0.h, $0.m),
                                        minutes: $0.minutes) }
        return Commute.trips(history: history, home: home, work: work)
    }

    /// Выезды домой в 11:44, 13:10, 13:13 (обед, поручение) — дорога домой,
    /// но не та, что вечером: в «обычно», неделю и «последнюю» не входят,
    /// а называются отдельно. Последняя поездка — вчерашняя вечерняя, хотя
    /// дневная была позже.
    func testOffHoursTripsHomeStayOutOfTheSample() throws {
        let trips = evenings([(1, 18, 35, 58), (2, 18, 20, 50), (3, 18, 40, 52), (4, 18, 10, 49),
                              (7, 18, 30, 55), (8, 18, 45, 53),
                              (0, 11, 44, 25), (2, 13, 10, 22), (6, 13, 13, 24)])
        let s = try XCTUnwrap(Commute.summary(.toHome, trips: trips, now: now, calendar: calendar))
        XCTAssertEqual(s.other.count, 3)
        XCTAssertEqual(s.trips.count, 6)
        XCTAssertEqual(s.last.duration, 58 * 60, "последняя — из своего окна")
        XCTAssertEqual(s.usual, 52.5 * 60, "медиана вечерних, без обеденных 22–25 мин")
        XCTAssertEqual(Set(s.other.map { Commute.minuteOfDay($0.departure, calendar: calendar) }),
                       [11 * 60 + 44, 13 * 60 + 10, 13 * 60 + 13])
    }

    /// Окна нет, если «основная масса» — не больше половины: выезды и правда
    /// разбросаны (сменный график), и прятать нечего.
    func testScatteredDeparturesKeepEveryTrip() {
        let trips = evenings([(1, 8, 0, 40), (2, 13, 0, 30), (3, 18, 0, 45), (4, 22, 30, 35)])
        let split = Commute.routine(trips, calendar: calendar)
        XCTAssertEqual(split.routine.count, 4)
        XCTAssertTrue(split.other.isEmpty)
    }

    /// Ночная смена: выезды в 23:50 и в 0:10 — соседи, полночь окно не рвёт.
    func testRoutineWindowWrapsAroundMidnight() {
        let trips = evenings([(1, 23, 50, 30), (2, 0, 10, 28), (3, 23, 40, 31), (4, 0, 20, 29),
                              (5, 15, 0, 40)])
        let split = Commute.routine(trips, calendar: calendar)
        XCTAssertEqual(split.routine.count, 4)
        XCTAssertEqual(split.other.map { Commute.minuteOfDay($0.departure, calendar: calendar) }, [15 * 60])
    }

    // MARK: - Разброс, вердикт и цифры, которые складываются

    /// Неделя — медиана, как «обычно»: на ровно таких же поездках со
    /// скошенным вправо временем (одна пробка в 70 мин) среднее было бы
    /// «дольше обычного» по построению.
    func testWeekOfOrdinaryTripsIsNotSlower() throws {
        let trips = evenings([(1, 18, 30, 50), (2, 18, 30, 70), (3, 18, 30, 51),
                              (9, 18, 30, 50), (10, 18, 30, 52), (11, 18, 30, 49), (12, 18, 30, 70),
                              (15, 18, 30, 51)])
        let s = try XCTUnwrap(Commute.summary(.toHome, trips: trips, now: now, calendar: calendar))
        let week = try XCTUnwrap(s.week)
        XCTAssertEqual(week.median, 51 * 60)
        XCTAssertFalse(week.isNoticeable, "среднее недели 57 — «на 6 мин дольше», медиана 51 — обычно")
    }

    /// «Дольше обычного» — только вне разброса: половина поездок 47,5–55,5 мин,
    /// поездка в 55 на 5 мин дольше медианы, но в пределах обычного; 62 — вне.
    func testVerdictFollowsTheUsualSpread() throws {
        let plan: [(Int, Int, Int, Double)] = [(2, 18, 30, 46), (3, 18, 30, 56), (4, 18, 30, 50),
                                               (5, 18, 30, 44), (8, 18, 30, 58), (9, 18, 30, 49)]
        let inside = evenings([(1, 18, 30, 55)] + plan)
        let s1 = try XCTUnwrap(Commute.summary(.toHome, trips: inside, now: now, calendar: calendar))
        let range = try XCTUnwrap(s1.range)
        XCTAssertTrue(range.contains(55 * 60), "\(range)")
        XCTAssertEqual(s1.verdict, .usual)

        let outside = evenings([(1, 18, 30, 62)] + plan)
        XCTAssertEqual(Commute.summary(.toHome, trips: outside, now: now, calendar: calendar)?.verdict, .slower)
        XCTAssertEqual(Commute.verdict(30 * 60, usual: 50 * 60, range: range), .faster)
    }

    /// Пока разброса нет (меньше пяти поездок) — по порогу 3 мин.
    func testVerdictWithoutSpreadUsesTheThreshold() {
        XCTAssertNil(Commute.summary(.toHome, trips: evenings([(1, 18, 30, 50), (2, 18, 30, 44),
                                                               (3, 18, 30, 45)]),
                                     now: now, calendar: calendar)?.range)
        XCTAssertEqual(Commute.verdict(50 * 60, usual: 45 * 60, range: nil), .slower)
        XCTAssertEqual(Commute.verdict(47 * 60, usual: 45 * 60, range: nil), .usual)
        XCTAssertEqual(Commute.verdict(47 * 60, usual: nil, range: nil), .usual)
    }

    /// Цифры на экране складываются: «58 мин» и «обычно 52» — «на 6 мин»,
    /// хотя разница в секундах (6:40) округлилась бы до семи.
    func testShownDelayAddsUpWithShownMinutes() {
        XCTAssertEqual(Commute.shownDelta(58 * 60 + 50, 52 * 60 + 10), 6)
        XCTAssertEqual(Formatting.duration(58 * 60 + 50), Formatting.duration(58 * 60))
        XCTAssertEqual(Commute.wholeMinutes(65 * 60 + 59), 65)
        XCTAssertEqual(Commute.quantile([10, 20, 30, 40, 50], 0.25), 20)
        XCTAssertEqual(Commute.quantile([10, 20], 0.75), 17.5)
    }

    func testOldTripsLeaveTheWindow() {
        let trips = weekOfMornings([(40, 8, 20, 50), (41, 8, 20, 50), (42, 8, 20, 50)])
        XCTAssertNil(Commute.summary(.toWork, trips: trips, now: now, calendar: calendar))
    }

    func testSummariesOrderFollowsTimeOfDay() {
        let history = [
            record(from: home, to: work, start: at(daysAgo: 1, 8, 20), minutes: 50),
            record(from: work, to: home, start: at(daysAgo: 1, 18, 30), minutes: 40),
        ]
        let trips = Commute.trips(history: history, home: home, work: work)
        let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        let evening = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now)!
        XCTAssertEqual(Commute.summaries(trips: trips, now: morning, calendar: calendar).first?.direction, .toWork)
        XCTAssertEqual(Commute.summaries(trips: trips, now: evening, calendar: calendar).first?.direction, .toHome)
    }
}
