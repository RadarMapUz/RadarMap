//
//  TripDayTests.swift
//  RadarMapTests
//
//  Дневные агрегаты: сводка по ним обязана совпадать со сводкой по записям,
//  вычитание — точно отменять сложение, а чистка истории не должна ронять
//  цифры за месяц.
//

import XCTest
@testable import RadarMap

final class TripDayTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86400 }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func pass(_ id: Int, speed: Double, limit: Int?, at date: Date,
                      location: String = "Юнусабад") -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                     location: location, speedKmh: speed, date: date,
                     lat: 41.31, lon: 69.28, limitKmh: limit)
    }

    private func record(daysAgo: Double, km: Double, minutes: Double = 30,
                        maxSpeed: Double = 90, score: Double? = 80,
                        passes: [PassedCamera] = []) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * day)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(minutes * 60),
                          distanceMeters: km * 1000, maxSpeedKmh: maxSpeed,
                          passed: passes, score: score)
    }

    /// Главный инвариант: агрегаты и записи дают одну и ту же сводку.
    func testRollupSummaryMatchesRecordSummary() {
        let history = [
            record(daysAgo: 1, km: 12, score: 90, passes: [
                pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day)),
                pass(2, speed: 55, limit: 60, at: now.addingTimeInterval(-day)),
            ]),
            record(daysAgo: 3, km: 30, score: 70, passes: [
                pass(3, speed: 100, limit: 60, at: now.addingTimeInterval(-3 * day)),
            ]),
            record(daysAgo: 5, km: 8, score: 95),
        ]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)

        let byRecords = TripHistory.summary(history, period: .week, calendar: utc, now: now)
        let byDays = TripHistory.summary(days: days, history: history, period: .week,
                                         anchor: now, calendar: utc)

        XCTAssertEqual(byDays.trips, byRecords.trips)
        XCTAssertEqual(byDays.distance, byRecords.distance, accuracy: 0.1)
        XCTAssertEqual(byDays.movingDuration, byRecords.movingDuration, accuracy: 0.1)
        XCTAssertEqual(byDays.cameras, byRecords.cameras)
        XCTAssertEqual(byDays.cleanPasses, byRecords.cleanPasses)
        XCTAssertEqual(byDays.overPasses, byRecords.overPasses)
        XCTAssertEqual(byDays.fineRisk, byRecords.fineRisk, accuracy: 0.1)
        XCTAssertEqual(byDays.maxSpeedKmh, byRecords.maxSpeedKmh, accuracy: 0.1)
        XCTAssertEqual(byDays.activeDays, byRecords.activeDays)
        XCTAssertEqual(byDays.rating, byRecords.rating)
        XCTAssertEqual(byDays.overByHour, byRecords.overByHour)
        // Зона риска считается по записям и в обоих случаях одинаковая.
        XCTAssertEqual(byDays.topOverLocation, byRecords.topOverLocation)
        XCTAssertEqual(byDays.topOverCount, byRecords.topOverCount)
    }

    /// Ради чего всё затевалось: записи вычистили, месяц остался честным.
    func testMonthSurvivesHistoryPruning() {
        let history = (1...20).map { index in
            record(daysAgo: Double(index), km: 10, score: 80,
                   passes: [pass(index, speed: 88, limit: 60,
                                 at: now.addingTimeInterval(-Double(index) * day))])
        }
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        // Жёсткая чистка: осталась только пара последних записей.
        let pruned = Array(history.prefix(2))

        let full = TripHistory.summary(days: days, history: history, period: .month,
                                       anchor: now, calendar: utc)
        let afterPrune = TripHistory.summary(days: days, history: pruned, period: .month,
                                             anchor: now, calendar: utc)

        // Календарный месяц: в окно попадают не все 20 записей, но важно другое —
        // после чистки цифры НЕ изменились, потому что считаются по агрегатам.
        let january = StatsPeriod.month.interval(containing: now, calendar: utc)
        let inMonth = history.filter { january.contains($0.startedAt) }.count
        XCTAssertEqual(afterPrune.distance, full.distance, accuracy: 0.1)
        XCTAssertEqual(afterPrune.overPasses, full.overPasses)
        XCTAssertEqual(afterPrune.trips, inMonth)
        XCTAssertGreaterThan(inMonth, 2)
        // А по записям после чистки месяц «похудел» бы до двух — вот вся разница.
        let byRecords = TripHistory.summary(pruned, period: .month, calendar: utc, now: now)
        XCTAssertEqual(byRecords.trips, 2)
    }

    /// Вычитание точно отменяет сложение — иначе resume/удаление ломают цифры.
    func testUnfoldedIsExactInverseOfFolded() {
        let first = record(daysAgo: 1, km: 12, score: 90, passes: [
            pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day)),
            pass(2, speed: 55, limit: 60, at: now.addingTimeInterval(-day)),
        ])
        let second = record(daysAgo: 1, km: 5, score: 60, passes: [
            pass(3, speed: 100, limit: 60, at: now.addingTimeInterval(-day)),
        ])

        let base = TripDayBook.folded(first, into: [], calendar: utc)
        let both = TripDayBook.folded(second, into: base, calendar: utc)
        let back = TripDayBook.unfolded(second, from: both, calendar: utc)

        XCTAssertEqual(back.count, 1)
        let restored = back[0]
        let original = base[0]
        XCTAssertEqual(restored.trips, original.trips)
        XCTAssertEqual(restored.distanceMeters, original.distanceMeters, accuracy: 0.1)
        XCTAssertEqual(restored.cameraPasses, original.cameraPasses)
        XCTAssertEqual(restored.overPasses, original.overPasses)
        XCTAssertEqual(restored.cleanPasses, original.cleanPasses)
        XCTAssertEqual(restored.fineRisk, original.fineRisk, accuracy: 0.1)
        XCTAssertEqual(restored.rating, original.rating)
        XCTAssertEqual(restored.overByHour, original.overByHour)
    }

    /// Опустевший день не остаётся строкой-призраком.
    func testUnfoldingLastTripRemovesDay() {
        let only = record(daysAgo: 1, km: 12)
        let days = TripDayBook.folded(only, into: [], calendar: utc)
        XCTAssertEqual(days.count, 1)
        XCTAssertTrue(TripDayBook.unfolded(only, from: days, calendar: utc).isEmpty)
    }

    /// Рейтинг дня взвешен по дистанции — как weightedRating по записям.
    func testDayRatingIsDistanceWeighted() {
        let long = record(daysAgo: 1, km: 100, score: 60)
        let short = record(daysAgo: 1, km: 1, score: 100)
        var days = TripDayBook.folded(long, into: [], calendar: utc)
        days = TripDayBook.folded(short, into: days, calendar: utc)
        // Длинная поездка весит стократ больше — среднее почти её балл.
        XCTAssertEqual(days[0].rating ?? 0, 60, accuracy: 1)
    }

    func testDaysRoundTripThroughJSON() throws {
        let days = TripDayBook.rebuilt(from: [record(daysAgo: 1, km: 12, passes: [
            pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day)),
        ])], calendar: utc)
        let data = try JSONEncoder().encode(days)
        let decoded = try JSONDecoder().decode([TripDay].self, from: data)
        XCTAssertEqual(decoded, days)
    }
    // MARK: - Динамика по неделям (RatingTrend)

    /// Недельный тренд: взвешенная средняя каждой недели, пустая неделя — nil,
    /// порядок старые → новые, количество колонок ровно как запрошено.
    func testWeeklyTrendAggregatesByCalendarWeek() {
        let history = [
            record(daysAgo: 0.5, km: 10, score: 90),
            record(daysAgo: 1.0, km: 30, score: 70),
            // −9 дней — прошлая календарная неделя при любом её начале.
            record(daysAgo: 9, km: 20, score: 100),
        ]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let weeks = RatingTrend.weekly(days: days, count: 4, calendar: utc, now: now)

        XCTAssertEqual(weeks.count, 4)
        XCTAssertTrue(weeks.map(\.start) == weeks.map(\.start).sorted(),
                      "порядок обязан быть старые → новые")
        // Текущая неделя: (90·10к + 70·30к) / 40к = 75.
        XCTAssertEqual(weeks.last?.rating, 75)
        XCTAssertEqual(weeks.last?.distanceMeters ?? 0, 40_000, accuracy: 1)
        // Прошлая неделя — одна поездка сотней.
        XCTAssertEqual(weeks[weeks.count - 2].rating, 100)
        // Недели без поездок — честный nil, не ноль.
        XCTAssertNil(weeks[0].rating)
        XCTAssertNil(weeks[1].rating)
    }

    /// Понедельник не двоится: день, равный началу следующей недели, не должен
    /// попасть в предыдущую (DateInterval.contains включает конец — тренд
    /// фильтрует полуинтервалом).
    func testWeeklyTrendDoesNotDoubleCountWeekBoundary() {
        guard let week = utc.dateInterval(of: .weekOfYear, for: now) else {
            return XCTFail("не построился интервал недели")
        }
        // Поездка ровно в начале ТЕКУЩЕЙ недели.
        let start = week.start.addingTimeInterval(3600)
        let boundary = TripRecord(id: 1, startedAt: start,
                                  endedAt: start.addingTimeInterval(1800),
                                  distanceMeters: 10_000, maxSpeedKmh: 90, passed: [],
                                  score: 80)
        let days = TripDayBook.rebuilt(from: [boundary], calendar: utc)
        let weeks = RatingTrend.weekly(days: days, count: 2, calendar: utc, now: now)
        XCTAssertNil(weeks[0].rating, "поездка начала недели утекла в предыдущую")
        XCTAssertEqual(weeks[1].rating, 80)
    }

    // MARK: - Сетка месяца (MonthGrid)

    /// Все дни месяца присутствуют ровно по разу, строки по 7 клеток,
    /// выравнивание по первому дню недели календаря.
    func testMonthGridLaysOutAllDaysOnce() {
        let weeks = MonthGrid.weeks(containing: now, calendar: utc)
        XCTAssertFalse(weeks.isEmpty)
        for week in weeks {
            XCTAssertEqual(week.count, 7, "ряд календаря обязан быть из 7 клеток")
        }
        let daysInGrid = weeks.flatMap { $0 }.compactMap { $0 }
        guard let month = utc.dateInterval(of: .month, for: now) else {
            return XCTFail("не построился интервал месяца")
        }
        let expected = utc.dateComponents([.day], from: month.start, to: month.end).day ?? 0
        XCTAssertEqual(daysInGrid.count, expected, "дней в сетке не столько, сколько в месяце")
        XCTAssertEqual(Set(daysInGrid).count, expected, "день не имеет права повторяться")
        // Первая непустая клетка — первое число, выровненное по дню недели.
        let leading = weeks[0].prefix(while: { $0 == nil }).count
        let weekday = utc.component(.weekday, from: month.start)
        XCTAssertEqual(leading, (weekday - utc.firstWeekday + 7) % 7)
    }

}
