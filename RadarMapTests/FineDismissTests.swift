//
//  FineDismissTests.swift
//  RadarMapTests
//
//  «Штраф не пришёл»: пометка убирает проезд из ДЕНЕГ (fineRisk записи, сводки
//  периода, дневного агрегата), но не из ПОВЕДЕНИЯ (overPasses, рейтинг).
//  Дневной агрегат чинится парой unfolded/folded — сумма обязана сойтись
//  копейка в копейку, иначе шапка Итогов и экран штрафов разъедутся.
//

import XCTest
@testable import RadarMap

final class FineDismissTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86400 }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func pass(_ id: Int, speed: Double, limit: Int?, at date: Date) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                     location: "Юнусабад", speedKmh: speed, date: date,
                     lat: 41.31, lon: 69.28, limitKmh: limit)
    }

    private func record(daysAgo: Double, passes: [PassedCamera]) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * day)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1800),
                          distanceMeters: 12_000, maxSpeedKmh: 95,
                          passed: passes, score: 80)
    }

    /// Пометка ложится ровно на выбранный проезд; снятие возвращает nil,
    /// а не false — непомеченная запись не должна раздуваться полем.
    func testSettingFineDismissedMarksOnlyThatPass() {
        let over = pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day))
        let other = pass(2, speed: 92, limit: 60, at: now.addingTimeInterval(-day))
        let original = record(daysAgo: 1, passes: [over, other])

        let dismissed = TripHistory.settingFineDismissed(original, passID: over.id,
                                                         dismissed: true)
        XCTAssertEqual(dismissed?.passed.first { $0.id == over.id }?.fineDismissed, true)
        XCTAssertNil(dismissed?.passed.first { $0.id == other.id }?.fineDismissed)

        let restored = TripHistory.settingFineDismissed(dismissed!, passID: over.id,
                                                        dismissed: false)
        XCTAssertNil(restored?.passed.first { $0.id == over.id }?.fineDismissed)
    }

    /// Чистый проезд и чужой id отклоняются: отменять на них нечего, и молчаливое
    /// «успешно» скрывало бы рассинхрон экрана с данными.
    func testSettingFineDismissedRefusesCleanPassAndUnknownID() {
        let clean = pass(1, speed: 55, limit: 60, at: now.addingTimeInterval(-day))
        let original = record(daysAgo: 1, passes: [clean])
        XCTAssertNil(TripHistory.settingFineDismissed(original, passID: clean.id,
                                                      dismissed: true))
        XCTAssertNil(TripHistory.settingFineDismissed(original, passID: UUID(),
                                                      dismissed: true))
    }

    /// fineRisk записи падает ровно на сумму отменённого проезда.
    func testFineRiskSkipsDismissed() {
        let over = pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day))
        let other = pass(2, speed: 92, limit: 60, at: now.addingTimeInterval(-day))
        let original = record(daysAgo: 1, passes: [over, other])
        let fine = FineSchedule.fine(overKmh: 88 - 60)
        XCTAssertGreaterThan(fine, 0)

        let before = TripHistory.fineRisk(of: original.passed)
        let updated = TripHistory.settingFineDismissed(original, passID: over.id,
                                                       dismissed: true)!
        XCTAssertEqual(TripHistory.fineRisk(of: updated.passed), before - fine,
                       accuracy: 0.01)
    }

    /// Сводка периода: деньги уходят, поведение остаётся — превышение было,
    /// и рейтинг с зоной риска обязаны его видеть.
    func testSummaryExcludesDismissedFromMoneyButKeepsBehavior() {
        let over = pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day))
        let original = record(daysAgo: 1, passes: [over])
        let updated = TripHistory.settingFineDismissed(original, passID: over.id,
                                                       dismissed: true)!

        let before = TripHistory.summary([original], period: .week, calendar: utc, now: now)
        let after = TripHistory.summary([updated], period: .week, calendar: utc, now: now)

        XCTAssertEqual(after.fineRisk, 0, accuracy: 0.01)
        XCTAssertEqual(after.overPasses, before.overPasses)
        XCTAssertEqual(after.cleanPasses, before.cleanPasses)
        XCTAssertEqual(after.rating, before.rating)
        XCTAssertEqual(after.overByHour, before.overByHour)
    }

    /// Починка дня «снять старую запись, положить новую»: сумма падает ровно на
    /// штраф, всё остальное в агрегате не шевелится, и сводка по дням снова
    /// совпадает со сводкой по записям (главный инвариант TripDayTests).
    func testDayRepairAfterDismissKeepsRollupInvariant() {
        let over = pass(1, speed: 88, limit: 60, at: now.addingTimeInterval(-day))
        let clean = pass(2, speed: 50, limit: 60, at: now.addingTimeInterval(-day))
        let original = record(daysAgo: 1, passes: [over, clean])
        let fine = FineSchedule.fine(overKmh: 88 - 60)
        var days = TripDayBook.rebuilt(from: [original], calendar: utc)

        let updated = TripHistory.settingFineDismissed(original, passID: over.id,
                                                       dismissed: true)!
        days = TripDayBook.unfolded(original, from: days, calendar: utc)
        days = TripDayBook.folded(updated, into: days, calendar: utc)

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].fineRisk, 0, accuracy: 0.01)
        XCTAssertEqual(days[0].trips, 1)
        XCTAssertEqual(days[0].overPasses, 1)
        XCTAssertEqual(days[0].cleanPasses, 1)

        let byDays = TripHistory.summary(days: days, history: [updated], period: .week,
                                         anchor: now, calendar: utc)
        let byRecords = TripHistory.summary([updated], period: .week, calendar: utc, now: now)
        XCTAssertEqual(byDays.fineRisk, byRecords.fineRisk, accuracy: 0.01)
        XCTAssertEqual(byDays.overPasses, byRecords.overPasses)

        // Обратный ход: «Вернуть» восстанавливает сумму той же парой.
        let restored = TripHistory.settingFineDismissed(updated, passID: over.id,
                                                        dismissed: false)!
        days = TripDayBook.unfolded(updated, from: days, calendar: utc)
        days = TripDayBook.folded(restored, into: days, calendar: utc)
        XCTAssertEqual(days[0].fineRisk, fine, accuracy: 0.01)
    }
}
