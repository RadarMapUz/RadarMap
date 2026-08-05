//
//  PeriodInsightsTests.swift
//  RadarMapTests
//
//  Разбор периода: нормировка на 100 км, порог «тренд, а не шум», часы риска,
//  приоритет выводов и честная оговорка про неизвестные лимиты.
//

import XCTest
@testable import RadarMap

final class PeriodInsightsTests: XCTestCase {

    /// Фиксированное «сейчас» и календарь UTC: часы проездов не должны зависеть
    /// от того, в какой зоне запускают тесты.
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

    private func record(daysAgo: Double, km: Double, score: Double? = nil,
                        passes: [PassedCamera] = []) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * day)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1800),
                          distanceMeters: km * 1000, maxSpeedKmh: 90,
                          passed: passes, score: score)
    }

    /// Точное время суток: полночь UTC нужного дня + часы.
    private func time(daysAgo: Double, hour: Int) -> Date {
        utc.startOfDay(for: now.addingTimeInterval(-daysAgo * day))
            .addingTimeInterval(Double(hour) * 3600)
    }

    // MARK: - Нормировка и производные сводки

    func testOverPer100kmNormalizesByDistance() {
        var summary = PeriodSummary()
        summary.distance = 200_000
        summary.overPasses = 4
        XCTAssertEqual(summary.overPer100km ?? 0, 2.0, accuracy: 0.001)
    }

    func testOverPer100kmIsNilOnTinyDistance() {
        var summary = PeriodSummary()
        summary.distance = 4_000
        summary.overPasses = 1
        XCTAssertNil(summary.overPer100km, "на четырёх километрах нормировать нечего")
    }

    func testPeakBlockFindsBusiestQuarterOfDay() {
        var summary = PeriodSummary()
        summary.overByHour[9] = 1
        summary.overByHour[19] = 3
        summary.overByHour[20] = 2
        let peak = summary.peakBlock
        XCTAssertEqual(peak?.index, 4)              // 16:00–20:00
        XCTAssertEqual(peak?.count, 3)
        XCTAssertEqual(peak?.share ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(peak?.title, "16:00–20:00")
    }

    func testSummaryCollectsHoursTopLocationAndPreviousWindow() {
        let history = [
            record(daysAgo: 1, km: 100, score: 80, passes: [
                pass(1, speed: 100, limit: 60, at: time(daysAgo: 1, hour: 19)),
                pass(2, speed: 100, limit: 60, at: time(daysAgo: 1, hour: 20)),
                pass(3, speed: 55, limit: 60, at: time(daysAgo: 1, hour: 8)),
            ]),
            record(daysAgo: 9, km: 100, score: 60, passes: [
                pass(4, speed: 100, limit: 60, at: time(daysAgo: 9, hour: 9)),
            ]),
        ]
        let summary = TripHistory.summary(history, period: .week, calendar: utc, now: now)

        XCTAssertEqual(summary.overPasses, 2)
        XCTAssertEqual(summary.cleanPasses, 1)
        XCTAssertEqual(summary.overByHour[19], 1)
        XCTAssertEqual(summary.overByHour[20], 1)
        XCTAssertEqual(summary.topOverLocation, "Юнусабад")
        XCTAssertEqual(summary.topOverCount, 2)
        // Прошлая неделя: одна поездка на 100 км с одним штрафуемым проездом.
        XCTAssertEqual(summary.previousOverPasses, 1)
        XCTAssertEqual(summary.previousDistance, 100_000, accuracy: 1)
        XCTAssertEqual(summary.previousRating, 60)
        XCTAssertEqual(summary.ratingDelta, 20)
    }

    // MARK: - Правила разбора

    func testTrendSaysBetterWhenNormalizedRateDrops() {
        var summary = PeriodSummary()
        summary.distance = 100_000
        summary.overPasses = 1
        summary.previousDistance = 100_000
        summary.previousOverPasses = 4

        let insight = PeriodInsights.build(summary).first
        XCTAssertEqual(insight?.id, "trend.better")
        XCTAssertEqual(insight?.kind, .good)
    }

    func testTrendSaysWorseWhenNormalizedRateGrows() {
        var summary = PeriodSummary()
        summary.distance = 100_000
        summary.overPasses = 4
        summary.previousDistance = 100_000
        summary.previousOverPasses = 1

        let insight = PeriodInsights.build(summary).first
        XCTAssertEqual(insight?.id, "trend.worse")
        XCTAssertEqual(insight?.kind, .bad)
    }

    /// Рост «в полтора раза» с 0,2 до 0,3 на 100 км — арифметика, а не поведение.
    func testTrendIgnoresNoiseBelowAbsoluteStep() {
        var summary = PeriodSummary()
        summary.distance = 1_000_000      // 1000 км
        summary.overPasses = 3            // 0,3 на 100 км
        summary.previousDistance = 1_000_000
        summary.previousOverPasses = 2    // 0,2 на 100 км

        XCTAssertFalse(PeriodInsights.build(summary).contains { $0.id.hasPrefix("trend") })
    }

    /// Больше километров при том же числе превышений — это «стали ездить чище».
    func testTrendUsesRateNotRawCount() {
        var summary = PeriodSummary()
        summary.distance = 400_000        // 4 превышения на 400 км = 1,0
        summary.overPasses = 4
        summary.previousDistance = 100_000 // 4 на 100 км = 4,0
        summary.previousOverPasses = 4

        XCTAssertEqual(PeriodInsights.build(summary).first?.id, "trend.better")
    }

    func testCleanPeriodInsight() {
        var summary = PeriodSummary()
        summary.cleanPasses = 12
        let insights = PeriodInsights.build(summary)
        XCTAssertEqual(insights.first?.id, "clean")
        XCTAssertEqual(insights.first?.kind, .good)
    }

    func testPlaceInsightNeedsRepeatedViolations() {
        var single = PeriodSummary()
        single.overPasses = 1
        single.topOverLocation = "Юнусабад"
        single.topOverCount = 1
        XCTAssertFalse(PeriodInsights.build(single).contains { $0.id == "place" },
                       "один раз — случайность, а не привычка")

        var repeated = single
        repeated.overPasses = 3
        repeated.topOverCount = 2
        XCTAssertTrue(PeriodInsights.build(repeated).contains { $0.id == "place" })
    }

    func testHoursInsightNeedsEnoughViolationsAndShare() {
        var scattered = PeriodSummary()
        scattered.overPasses = 4
        scattered.overByHour[2] = 1
        scattered.overByHour[9] = 1
        scattered.overByHour[14] = 1
        scattered.overByHour[22] = 1
        XCTAssertFalse(PeriodInsights.build(scattered).contains { $0.id == "hours" },
                       "равномерный разброс — не «часы риска»")

        var evening = PeriodSummary()
        evening.overPasses = 4
        evening.overByHour[19] = 3
        evening.overByHour[9] = 1
        XCTAssertTrue(PeriodInsights.build(evening).contains { $0.id == "hours" })
    }

    func testRatingInsightOnlyOnNoticeableMove() {
        var noise = PeriodSummary()
        noise.rating = 82
        noise.previousRating = 80
        XCTAssertFalse(PeriodInsights.build(noise).contains { $0.id.hasPrefix("rating") })

        var grew = PeriodSummary()
        grew.rating = 86
        grew.previousRating = 74
        XCTAssertTrue(PeriodInsights.build(grew).contains { $0.id == "rating.up" })

        var fell = PeriodSummary()
        fell.rating = 61
        fell.previousRating = 78
        XCTAssertTrue(PeriodInsights.build(fell).contains { $0.id == "rating.down" })
    }

    /// Камеры были, но лимитов у них нет — «ноль превышений» тут не заслуга.
    func testLimitsCaveatWhenNoLimitedPasses() {
        var summary = PeriodSummary()
        summary.cameras = 5
        XCTAssertTrue(PeriodInsights.build(summary).contains { $0.id == "limits" })
    }

    func testNeverMoreThanThreeInsights() {
        var summary = PeriodSummary()
        summary.distance = 100_000
        summary.overPasses = 5
        summary.previousDistance = 100_000
        summary.previousOverPasses = 1
        summary.topOverLocation = "Юнусабад"
        summary.topOverCount = 3
        summary.overByHour[19] = 4
        summary.overByHour[9] = 1
        summary.rating = 55
        summary.previousRating = 80

        let insights = PeriodInsights.build(summary)
        XCTAssertEqual(insights.count, AppConfig.insightsMaxCount)
        // Первым идёт то, что важнее всего: динамика.
        XCTAssertEqual(insights.first?.id, "trend.worse")
        XCTAssertEqual(Set(insights.map(\.id)).count, insights.count)
    }

    // MARK: - Ближайшее достижение

    func testNextAchievementIsClosestUnearned() {
        var stats = LifetimeStats()
        stats.distanceMeters = 950_000      // 950 км из 1000 — почти
        stats.camerasInLimit = 60           // 50 закрыто, до 500 далеко
        stats.bestStreak = 5                // закрыт «5 подряд»

        let next = Achievements.next(for: stats)
        XCTAssertEqual(next?.id, "km1000")
        XCTAssertEqual(next?.progressText, "950 / 1000")
        XCTAssertFalse(next?.earned ?? true)
    }
}
