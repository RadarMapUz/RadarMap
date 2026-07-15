//
//  DrivingScoreTests.swift
//  RadarMapTests
//
//  Рейтинг вождения, штрафная арифметика ст. 128-3 КоАО и пожизненные счётчики.
//

import XCTest
@testable import RadarMap

final class DrivingScoreTests: XCTestCase {

    // MARK: - Штрафные ступени

    func testFineTiers() {
        // В допуске — штрафа нет.
        XCTAssertEqual(FineSchedule.fine(overKmh: -10), 0)
        XCTAssertEqual(FineSchedule.fine(overKmh: 0), 0)
        XCTAssertEqual(FineSchedule.fine(overKmh: 5), 0)
        // до +20 → 1 БРВ
        XCTAssertEqual(FineSchedule.fine(overKmh: 6), FineSchedule.brv)
        XCTAssertEqual(FineSchedule.fine(overKmh: 20), FineSchedule.brv)
        // +20…40 → 5 БРВ
        XCTAssertEqual(FineSchedule.fine(overKmh: 21), 5 * FineSchedule.brv)
        XCTAssertEqual(FineSchedule.fine(overKmh: 40), 5 * FineSchedule.brv)
        // свыше 40 → 9 БРВ
        XCTAssertEqual(FineSchedule.fine(overKmh: 41), 9 * FineSchedule.brv)
    }

    // MARK: - Балл поездки

    private func smoothSpeeds(_ count: Int = 60) -> [Double] {
        (0..<count).map { 60 + Double($0 % 3) }   // перепады ~1 км/ч
    }

    func testPerfectTripScores100() {
        let passes = [DrivingScore.Pass(speedKmh: 58, limitKmh: 60),
                      DrivingScore.Pass(speedKmh: 61, limitKmh: 60)]
        let score = DrivingScore.tripScore(passes: passes, trackSpeeds: smoothSpeeds())
        XCTAssertEqual(score ?? 0, 100, accuracy: 0.5)
    }

    func testHeavyOverspeedTanksScore() {
        let passes = [DrivingScore.Pass(speedKmh: 115, limitKmh: 60),   // > +40: -40
                      DrivingScore.Pass(speedKmh: 90, limitKmh: 60)]    // +30: -25
        let score = DrivingScore.tripScore(passes: passes, trackSpeeds: smoothSpeeds())
        XCTAssertNotNil(score)
        XCTAssertLessThanOrEqual(score!, 40)
    }

    func testHarshDrivingPenalized() {
        // Рваный темп: перепады по 12 км/ч на каждом шаге.
        let jerky = (0..<60).map { $0 % 2 == 0 ? 48.0 : 60.0 }
        let smooth = DrivingScore.tripScore(passes: [], trackSpeeds: smoothSpeeds())!
        let harsh = DrivingScore.tripScore(passes: [], trackSpeeds: jerky)!
        XCTAssertGreaterThan(smooth, harsh)
        XCTAssertEqual(smooth, 100, accuracy: 0.5)
    }

    func testNoDataGivesNil() {
        XCTAssertNil(DrivingScore.tripScore(passes: [], trackSpeeds: []))
        // Проезды без лимитов и короткий трек — тоже нет вердикта.
        let passes = [DrivingScore.Pass(speedKmh: 90, limitKmh: nil)]
        XCTAssertNil(DrivingScore.tripScore(passes: passes, trackSpeeds: [50, 51]))
    }

    // MARK: - Пожизненные счётчики и серия

    func testLifetimeAccumulationAndSavings() {
        var stats = LifetimeStats()
        let passes = [DrivingScore.Pass(speedKmh: 58, limitKmh: 60),    // чисто → экономия
                      DrivingScore.Pass(speedKmh: 75, limitKmh: 60),    // +15 → 1 БРВ риска
                      DrivingScore.Pass(speedKmh: 80, limitKmh: nil)]   // без лимита — не считается
        stats = LifetimeStats.updated(stats, passes: passes, distanceMeters: 12_000)

        XCTAssertEqual(stats.trips, 1)
        XCTAssertEqual(stats.distanceMeters, 12_000)
        XCTAssertEqual(stats.camerasPassed, 3)
        XCTAssertEqual(stats.camerasInLimit, 1)
        XCTAssertEqual(stats.savedFinesSum, FineSchedule.minimumFine)
        XCTAssertEqual(stats.riskFinesSum, FineSchedule.brv)
        XCTAssertEqual(stats.cleanStreak, 0)   // был штрафной проезд — серия сброшена
    }

    func testCleanStreakGrowsAndResets() {
        var stats = LifetimeStats()
        let clean = [DrivingScore.Pass(speedKmh: 55, limitKmh: 60)]
        let dirty = [DrivingScore.Pass(speedKmh: 90, limitKmh: 60)]
        let noData: [DrivingScore.Pass] = []

        stats = LifetimeStats.updated(stats, passes: clean, distanceMeters: 1000)
        stats = LifetimeStats.updated(stats, passes: clean, distanceMeters: 1000)
        XCTAssertEqual(stats.cleanStreak, 2)

        // Поездка без лимитных камер серию не трогает.
        stats = LifetimeStats.updated(stats, passes: noData, distanceMeters: 1000)
        XCTAssertEqual(stats.cleanStreak, 2)

        stats = LifetimeStats.updated(stats, passes: dirty, distanceMeters: 1000)
        XCTAssertEqual(stats.cleanStreak, 0)
        XCTAssertEqual(stats.bestStreak, 2)
    }

    // MARK: - Достижения

    func testAchievementsProgress() {
        var stats = LifetimeStats()
        stats.distanceMeters = 150_000   // 150 км
        stats.camerasInLimit = 60
        stats.bestStreak = 3

        let badges = Achievements.all(for: stats)
        XCTAssertEqual(badges.count, 9)
        XCTAssertTrue(badges.first { $0.id == "km100" }!.earned)
        XCTAssertFalse(badges.first { $0.id == "km1000" }!.earned)
        XCTAssertTrue(badges.first { $0.id == "clean50" }!.earned)
        XCTAssertFalse(badges.first { $0.id == "streak5" }!.earned)
        XCTAssertEqual(badges.first { $0.id == "streak5" }!.fraction, 0.6, accuracy: 0.01)
    }
}

// MARK: - Чистка истории

final class HistoryPruneTests: XCTestCase {
    private func record(daysAgo: Double, withTrack: Bool = true) -> TripRecord {
        TripRecord(id: daysAgo, startedAt: Date().addingTimeInterval(-daysAgo * 86400),
                   endedAt: Date().addingTimeInterval(-daysAgo * 86400 + 600),
                   distanceMeters: 5000, maxSpeedKmh: 70, passed: [],
                   endLat: 41, endLon: 69,
                   track: withTrack ? [41, 69, 50, 41.01, 69.01, 55] : nil,
                   score: 90)
    }

    func testPruneKeepsSevenFullThenStripsTracksAndDropsOld() {
        // 12 поездок: 10 свежих + 2 старше месяца.
        var history = (0..<10).map { record(daysAgo: Double($0)) }
        history.append(record(daysAgo: 35))
        history.append(record(daysAgo: 40))

        let pruned = TripStats.pruned(history)

        // Старше 30 дней — удалены (кроме случаев в первой семёрке).
        XCTAssertEqual(pruned.count, 10)
        // Первые 7 — с треками (для просмотра).
        for i in 0..<7 { XCTAssertNotNil(pruned[i].track, "поездка \(i) должна сохранить трек") }
        // Дальше — только цифры для статистики.
        for i in 7..<pruned.count { XCTAssertNil(pruned[i].track, "поездка \(i) должна потерять трек") }
        // Баллы и дистанции не тронуты.
        XCTAssertEqual(pruned[8].score, 90)
        XCTAssertEqual(pruned[8].distanceMeters, 5000)
    }

    func testPruneKeepsRecentSevenEvenIfOld() {
        // Все поездки древние — но первые 7 остаются целиком (список не пустеет).
        let history = (0..<9).map { record(daysAgo: Double(40 + $0)) }
        let pruned = TripStats.pruned(history)
        XCTAssertEqual(pruned.count, 7)
        XCTAssertNotNil(pruned[0].track)
    }
}
