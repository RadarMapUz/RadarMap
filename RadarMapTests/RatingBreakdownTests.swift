//
//  RatingBreakdownTests.swift
//  RadarMapTests
//
//  Разложение рейтинга и суммы штрафов: сумма строк ОБЯЗАНА сходиться с
//  показанной цифрой. Именно такая арифметика тихо разъезжается при правке
//  весов, и заметить это на глаз невозможно.
//

import XCTest
@testable import RadarMap

final class RatingBreakdownTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86400 }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    private var month: DateInterval { StatsPeriod.month.interval(containing: now, calendar: utc) }

    private func pass(_ id: Int, speed: Double, limit: Int?, location: String = "Юнусабад",
                      daysAgo: Double = 1) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                     location: location, speedKmh: speed,
                     date: now.addingTimeInterval(-daysAgo * day),
                     lat: 41.31, lon: 69.28, limitKmh: limit)
    }

    private func record(daysAgo: Double, km: Double, score: Double?,
                        passes: [PassedCamera] = []) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * day)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1800),
                          distanceMeters: km * 1000, maxSpeedKmh: 90,
                          passed: passes, score: score)
    }

    // MARK: - Рейтинг

    /// Главный инвариант: Σ вкладов == 100 − рейтинг.
    func testContributionsSumToRatingGap() {
        let history = [
            record(daysAgo: 1, km: 31, score: 68),
            record(daysAgo: 2, km: 12, score: 74),
            record(daysAgo: 3, km: 8, score: 96),
            record(daysAgo: 5, km: 20, score: 100),
        ]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let summary = TripHistory.summary(days: days, history: history, period: .month,
                                          anchor: now, calendar: utc)
        let items = RatingBreakdown.contributions(records: history, days: days,
                                                  in: month, calendar: utc)

        let rating = try? XCTUnwrap(summary.rating)
        XCTAssertEqual(items.reduce(0) { $0 + $1.points },
                       100 - Double(rating ?? 0), accuracy: 0.5,
                       "разложение обязано сходиться с показанным рейтингом")
        // Самая длинная плохая поездка стоит дороже всех.
        XCTAssertEqual(items.first?.score, 68)
        XCTAssertTrue(items.first?.isTrip ?? false)
        // Идеальная поездка ничего не отняла.
        XCTAssertEqual(items.first { $0.score == 100 }?.points ?? -1, 0, accuracy: 0.001)
    }

    /// Записи вычищены — раскладываем по дням, а не показываем пустоту.
    func testFallsBackToDaysWhenRecordsPruned() {
        let history = (1...10).map { record(daysAgo: Double($0), km: 10, score: 70) }
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let pruned = Array(history.prefix(2))   // жёсткая чистка

        let items = RatingBreakdown.contributions(records: pruned, days: days,
                                                  in: month, calendar: utc)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.isTrip }, "строки должны стать дневными")
        let summary = TripHistory.summary(days: days, history: pruned, period: .month,
                                          anchor: now, calendar: utc)
        XCTAssertEqual(items.reduce(0) { $0 + $1.points },
                       100 - Double(summary.rating ?? 0), accuracy: 0.5)
    }

    func testUnratedTripsCounted() {
        let history = [record(daysAgo: 1, km: 10, score: 80),
                       record(daysAgo: 2, km: 5, score: nil),
                       record(daysAgo: 3, km: 5, score: nil)]
        XCTAssertEqual(RatingBreakdown.unratedTrips(records: history, in: month), 2)
    }

    func testDailyRatingsAreSortedAndSkipEmptyDays() {
        let history = [record(daysAgo: 1, km: 10, score: 80),
                       record(daysAgo: 3, km: 10, score: 60)]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let points = RatingBreakdown.dailyRatings(days: days, in: month)
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points[0].day < points[1].day, "от старых к новым — как рисуется график")
        XCTAssertEqual(points.last?.rating, 80)
    }

    func testNextLevelThresholds() {
        XCTAssertEqual(DrivingScore.nextLevel(for: 87)?.threshold, 90)
        XCTAssertEqual(DrivingScore.nextLevel(for: 61)?.threshold, 75)
        XCTAssertEqual(DrivingScore.nextLevel(for: 20)?.threshold, 60)
        XCTAssertNil(DrivingScore.nextLevel(for: 95), "выше идеального уровня нет")
    }

    // MARK: - Штрафы

    /// Сумма камер-источников == общий риск за то же окно.
    func testFineSourcesSumToPeriodRisk() {
        let history = [
            record(daysAgo: 1, km: 10, score: 60, passes: [
                pass(1, speed: 88, limit: 60, location: "Юнусабад"),
                pass(1, speed: 92, limit: 60, location: "Юнусабад"),
                pass(2, speed: 64, limit: 60, location: "Чиланзар"),   // +4 — в допуске
            ]),
            record(daysAgo: 2, km: 10, score: 60, passes: [
                pass(3, speed: 115, limit: 60, location: "Мирзо-Улугбек", daysAgo: 2),
            ]),
        ]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let summary = TripHistory.summary(days: days, history: history, period: .month,
                                          anchor: now, calendar: utc)
        let sources = RatingBreakdown.fineSources(records: history, in: month)

        XCTAssertEqual(sources.reduce(0) { $0 + $1.sum }, summary.fineRisk, accuracy: 0.5)
        // Самая дорогая камера — первой. Два проезда по 5 БРВ (+28 и +32)
        // дороже одного на 9 БРВ (+55): сортировка по СУММЕ, а не по тяжести.
        XCTAssertEqual(sources.first?.location, "Юнусабад")
        XCTAssertEqual(sources.first?.times, 2, "повторные проезды одной камеры — одна строка")
        XCTAssertEqual(sources.first?.sum ?? 0, 10 * FineSchedule.brv, accuracy: 1)
        XCTAssertEqual(sources.last?.location, "Мирзо-Улугбек")
        // Проезд в допуске строки не создаёт.
        XCTAssertNil(sources.first { $0.location == "Чиланзар" })
    }
}
