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

    /// Строка обязана объяснять сама себя: недобор × доля = вклад.
    /// Именно это показано на экране, и расхождение здесь означает, что
    /// водителю показали арифметику, которая не сходится.
    func testContributionExplainsItself() {
        let history = [record(daysAgo: 1, km: 30, score: 55),
                       record(daysAgo: 2, km: 10, score: 80)]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let items = RatingBreakdown.contributions(records: history, days: days,
                                                  in: month, calendar: utc)

        XCTAssertEqual(items.reduce(0) { $0 + $1.weightShare }, 1, accuracy: 0.001,
                       "доли веса обязаны складываться в единицу")
        for item in items {
            XCTAssertEqual(item.points, item.weightShare * Double(item.deficit),
                           accuracy: 0.05, "вклад = недобор × доля")
        }
        // 30 км против 10: длинная поездка весит втрое больше.
        XCTAssertEqual(items.first?.weightShare ?? 0, 0.75, accuracy: 0.001)
    }

    // MARK: - Куда ушли баллы

    /// Разложение по камерам обязано сходиться с разложением по поездкам,
    /// а оно — с самим рейтингом. Иначе экран показывает два разных ответа
    /// на один вопрос — ровно то, от чего эти блоки и защищают.
    func testSourcesSumToContributions() {
        let history = [
            record(daysAgo: 1, km: 30, score: 67, passes: [
                pass(1, speed: 88, limit: 60, location: "Юнусабад"),   // +28 → 25
                pass(2, speed: 66, limit: 60, location: "Чиланзар"),   // +6  → 8
            ]),
            record(daysAgo: 2, km: 10, score: 92, passes: [
                pass(1, speed: 68, limit: 60, location: "Юнусабад", daysAgo: 2),  // +8 → 8
            ]),
            // Поездка вообще без камер: её недобор — рваная езда.
            record(daysAgo: 3, km: 10, score: 85),
        ]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let summary = TripHistory.summary(days: days, history: history, period: .month,
                                          anchor: now, calendar: utc)
        let sources = RatingBreakdown.sources(records: history, days: days, in: month)

        XCTAssertEqual(sources.total, 100 - Double(summary.rating ?? 0), accuracy: 0.5,
                       "камеры + плавность обязаны дать весь недобор рейтинга")
        XCTAssertGreaterThan(sources.smoothness, 0, "поездка без камер уходит в плавность")

        // Повторные проезды одной камеры — одна строка, а не две.
        let top = sources.cameras.first
        XCTAssertEqual(top?.location, "Юнусабад")
        XCTAssertEqual(top?.times, 2)
        XCTAssertEqual(top?.worstSpeedKmh, 88)
        XCTAssertGreaterThan(top?.points ?? 0, sources.cameras.last?.points ?? .infinity)
    }

    // MARK: - Причины в целых

    /// «−20,0» и «−7,2» под итогом «вместе −27» (38C): строки обязаны быть
    /// целыми и складываться ровно в показанный итог.
    func testWholePointsSumToTotal() {
        XCTAssertEqual(RatingBreakdown.wholePoints([20.0, 7.2], total: 27), [20, 7])
        // Каждая строка округляется вверх — сумма убежала бы в −28.
        XCTAssertEqual(RatingBreakdown.wholePoints([13.5, 13.5], total: 27), [14, 13])
        // Три по трети — недостающий балл получает одна строка, а не все.
        XCTAssertEqual(RatingBreakdown.wholePoints([3.4, 3.3, 3.3], total: 10), [4, 3, 3])
        // Части расходятся с итогом (рейтинг округлён) — делится итог.
        XCTAssertEqual(RatingBreakdown.wholePoints([20.0, 7.2], total: 28).reduce(0, +), 28)
        XCTAssertEqual(RatingBreakdown.wholePoints([0.3, 0.3, 0.4], total: 1), [0, 0, 1])
        XCTAssertEqual(RatingBreakdown.wholePoints([], total: 5), [])
        XCTAssertEqual(RatingBreakdown.wholePoints([0, 0], total: 5), [0, 0])
        XCTAssertEqual(RatingBreakdown.wholePoints([4, 2], total: 0), [0, 0])
        XCTAssertEqual(RatingBreakdown.wholePoints([-1, 6], total: 6), [0, 6])
    }

    /// Порядок по величине не переворачивается: бо́льшая часть никогда не
    /// получает меньше баллов, чем меньшая, а сумма всегда сходится.
    func testWholePointsKeepOrderAndSum() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let parts = (0..<Int.random(in: 1...7, using: &generator))
                .map { _ in Double.random(in: 0...30, using: &generator) }
            let total = Int.random(in: 0...60, using: &generator)
            let whole = RatingBreakdown.wholePoints(parts, total: total)
            XCTAssertEqual(whole.reduce(0, +), parts.reduce(0, +) > 0 ? total : 0)
            for a in parts.indices { for b in parts.indices where parts[a] > parts[b] {
                XCTAssertGreaterThanOrEqual(whole[a], whole[b], "\(parts) → \(whole)")
            } }
        }
    }

    /// Строки блока: видимые камеры и плавность по величине, остальные камеры
    /// одной строкой в конце, сумма — итог; плавность, округлившаяся в ноль,
    /// не показывается.
    func testSourceLinesAreWholeAndSumToTotal() {
        func camera(_ id: Int, _ points: Double) -> RatingHotspot {
            RatingHotspot(id: id, location: "К\(id)", times: 1, points: points, worstSpeedKmh: 80,
                          worstDate: now, limitKmh: 60, lat: nil, lon: nil)
        }
        let sources = RatingSources(cameras: [camera(1, 7.2), camera(2, 3.1), camera(3, 0.4)],
                                    smoothness: 16.3)
        let lines = sources.lines(visible: 2, total: 27)
        XCTAssertEqual(lines.map(\.id), [-1, 1, 2, -2])
        XCTAssertEqual(lines.map(\.points).reduce(0, +), 27)
        XCTAssertEqual(lines.map(\.points), [16, 7, 3, 1])
        XCTAssertEqual(lines.last?.kind, .rest(count: 1))

        let quiet = RatingSources(cameras: [camera(1, 12.8)], smoothness: 0.2)
        let quietLines = quiet.lines(visible: 4, total: 13)
        XCTAssertEqual(quietLines.map(\.id), [1])
        XCTAssertEqual(quietLines.first?.points, 13)
    }

    /// Записи вычищены — названий камер взять неоткуда, и выдумывать их нельзя.
    func testSourcesEmptyWhenRecordsPruned() {
        let history = (1...10).map { record(daysAgo: Double($0), km: 10, score: 70) }
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let sources = RatingBreakdown.sources(records: Array(history.prefix(2)),
                                              days: days, in: month)
        XCTAssertTrue(sources.isEmpty)
    }

    // MARK: - «А если бы в лимите»

    func testRatingIfCleanRaisesRating() {
        let violation = pass(1, speed: 88, limit: 60)      // +28 → −25 балла
        let trip = record(daysAgo: 1, km: 20, score: 75, passes: [violation])
        let days = TripDayBook.rebuilt(from: [trip], calendar: utc)

        let improved = RatingBreakdown.ratingIfClean(pass: violation, record: trip,
                                                     days: days, in: month)
        XCTAssertEqual(improved, 100, "единственное нарушение — рейтинг стал бы идеальным")
    }

    /// Чистый проезд ничего не меняет — предлагать «а если бы» нечего.
    func testRatingIfCleanNilForCleanPass() {
        let clean = pass(1, speed: 61, limit: 60)
        let trip = record(daysAgo: 1, km: 20, score: 100, passes: [clean])
        let days = TripDayBook.rebuilt(from: [trip], calendar: utc)
        XCTAssertNil(RatingBreakdown.ratingIfClean(pass: clean, record: trip,
                                                   days: days, in: month))
    }

    /// Улучшение одной поездки не может опустить рейтинг периода.
    func testRatingIfCleanNeverLowersRating() {
        let violation = pass(1, speed: 105, limit: 60)
        let bad = record(daysAgo: 1, km: 30, score: 60, passes: [violation])
        let good = record(daysAgo: 2, km: 10, score: 95)
        let days = TripDayBook.rebuilt(from: [bad, good], calendar: utc)
        let summary = TripHistory.summary(days: days, history: [bad, good], period: .month,
                                          anchor: now, calendar: utc)
        let improved = RatingBreakdown.ratingIfClean(pass: violation, record: bad,
                                                     days: days, in: month)
        XCTAssertGreaterThanOrEqual(improved ?? 0, summary.rating ?? 0)
    }

    // MARK: - Ваша норма

    func testBaselineMedianAndRange() {
        // По одной поездке в каждую из четырёх прошлых недель.
        let history = [record(daysAgo: 7, km: 10, score: 60),
                       record(daysAgo: 14, km: 10, score: 70),
                       record(daysAgo: 21, km: 10, score: 80),
                       record(daysAgo: 28, km: 10, score: 90)]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let baseline = RatingBreakdown.baseline(days: days, period: .week, anchor: now,
                                                calendar: utc)
        XCTAssertEqual(baseline?.periods, 4)
        XCTAssertEqual(baseline?.median, 80)
        XCTAssertEqual(baseline?.low, 70)
        XCTAssertEqual(baseline?.high, 80)
        XCTAssertTrue(baseline?.contains(75) ?? false)
        XCTAssertEqual(baseline?.delta(from: 73) ?? 0, -7)
    }

    /// Двух недель для «нормы» мало — лучше молчать, чем выдавать шум за норму.
    func testBaselineNeedsEnoughPeriods() {
        let history = [record(daysAgo: 7, km: 10, score: 60),
                       record(daysAgo: 14, km: 10, score: 70)]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        XCTAssertNil(RatingBreakdown.baseline(days: days, period: .week, anchor: now,
                                              calendar: utc))
    }

    /// Норма считается по ПРОШЛЫМ окнам: текущее не должно объяснять само себя.
    func testBaselineIgnoresCurrentPeriod() {
        let history = [record(daysAgo: 0, km: 100, score: 10),   // провал прямо сейчас
                       record(daysAgo: 7, km: 10, score: 80),
                       record(daysAgo: 14, km: 10, score: 80),
                       record(daysAgo: 21, km: 10, score: 80)]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        XCTAssertEqual(RatingBreakdown.baseline(days: days, period: .week, anchor: now,
                                                calendar: utc)?.median, 80)
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

    /// «Откуда сумма» по тем же правилам, что дневные сводки: «не пришёл» и
    /// предположенный лимит денег не дают (ревью 19.10 — шапка показывала
    /// «0 штрафов», а строки ниже — суммы).
    func testFineSourcesSkipDismissedAndAssumedLimits() {
        var dismissed = pass(1, speed: 92, limit: 60, location: "Юнусабад")
        dismissed.fineDismissed = true
        var assumed = pass(2, speed: 92, limit: 60, location: "Чиланзар")
        assumed.limitAssumed = true
        let history = [record(daysAgo: 1, km: 10, score: 60, passes: [dismissed, assumed])]
        let days = TripDayBook.rebuilt(from: history, calendar: utc)
        let summary = TripHistory.summary(days: days, history: history, period: .month,
                                          anchor: now, calendar: utc)
        let sources = RatingBreakdown.fineSources(records: history, in: month)
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(summary.fineRisk, 0)
    }
}
