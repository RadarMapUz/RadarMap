//
//  PassVerdictTests.swift
//  RadarMapTests
//
//  Три состояния проезда (аудит 05.11): слово на экране не смеет разойтись
//  ни с баллом (DrivingScore.penaltyPoints), ни с суммой штрафов
//  (FineSchedule.fine). «На грани» — ровно тот случай, когда балл снят, а
//  штрафа нет: до него поездка с −8 читалась «все камеры без превышения».
//

import XCTest
@testable import RadarMap

final class PassVerdictTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func pass(_ speed: Double, limit: Int?, camera: Int = 1, at offset: TimeInterval = 0) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: camera, typeRaw: "Стационар радар", location: "Юнусабад",
                     speedKmh: speed, date: day.addingTimeInterval(offset), lat: 41.3, lon: 69.2,
                     limitKmh: limit)
    }

    private func record(_ passes: [PassedCamera], at offset: TimeInterval = 3_600) -> TripRecord {
        let start = day.addingTimeInterval(offset)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1_800), distanceMeters: 12_000,
                          maxSpeedKmh: 90, passed: passes, score: 90)
    }

    /// Границы — у движков: штрафная ступень и лестница баллов.
    func testBoundariesFollowFineAndPenalty() {
        XCTAssertEqual(PassVerdict.of(speedKmh: 60, limitKmh: 60), .clean)
        XCTAssertEqual(PassVerdict.of(speedKmh: 61.9, limitKmh: 60), .clean, "до +2 балл не снят")
        XCTAssertEqual(PassVerdict.of(speedKmh: 62, limitKmh: 60), .edge, "+2 — балл снят")
        XCTAssertEqual(PassVerdict.of(speedKmh: 65, limitKmh: 60), .edge, "+5 — штрафа ещё нет")
        XCTAssertEqual(PassVerdict.of(speedKmh: 65.5, limitKmh: 60), .over)
        XCTAssertEqual(PassVerdict.of(speedKmh: 120, limitKmh: nil), .unknown)
    }

    /// Каждое состояние совпадает с тем, что считают движки: «на грани» —
    /// балл снят и штрафа нет, «в лимите» — не снят ничего.
    func testVerdictMatchesEnginesOnEveryKmh() {
        for over in stride(from: -5.0, through: 45, by: 0.5) {
            let verdict = PassVerdict.of(speedKmh: 60 + over, limitKmh: 60)
            let fine = FineSchedule.fine(overKmh: over)
            let points = DrivingScore.penaltyPoints(overKmh: over)
            switch verdict {
            case .over:  XCTAssertGreaterThan(fine, 0, "\(over)")
            case .edge:  XCTAssertEqual(fine, 0, "\(over)"); XCTAssertGreaterThan(points, 0, "\(over)")
            case .clean: XCTAssertEqual(points, 0, "\(over)")
            case .unknown: XCTFail("лимит известен")
            }
        }
    }

    func testTallyAndWorst() {
        let tally = PassVerdict.tally([pass(55, limit: 60), pass(64, limit: 60),
                                       pass(90, limit: 60), pass(70, limit: nil)])
        XCTAssertEqual(tally, PassVerdict.Tally(clean: 1, edge: 1, over: 1, unknown: 1))
        XCTAssertEqual(tally.judged, 3)
        XCTAssertEqual(tally.worst, .over)
        XCTAssertNil(PassVerdict.Tally(unknown: 2).worst, "без лимитов судить не по чему")
        XCTAssertEqual(PassVerdict.day(clean: 3, edge: 1, over: 0), .edge)
    }

    // MARK: - Вердикт поездки

    /// Поездка с +5 у камеры — не «все камеры в лимите», а «на грани».
    func testTripWithEdgePassIsNotClean() {
        XCTAssertEqual(record([pass(65, limit: 60), pass(50, limit: 60)]).verdict, .edge(1))
        XCTAssertEqual(record([pass(61, limit: 60)]).verdict, .clean, "+1 — балл не снят")
        XCTAssertEqual(record([pass(65, limit: 60), pass(90, limit: 60, camera: 2)]).verdict,
                       .risk(FineSchedule.fine(overKmh: 30)), "штраф важнее «на грани»")
    }

    /// Итог поездки называет «на грани» строкой без похвалы.
    func testRewardLineForEdge() {
        let passes = [TripReward.Pass(speedKmh: 55, limitKmh: 60), TripReward.Pass(speedKmh: 64, limitKmh: 60)]
        let lines = TripReward.pick(verdict: .edge(1), passes: passes, tripStart: day,
                                    tripEnd: day.addingTimeInterval(1_800), reports: [],
                                    seenConfirmations: nil, reportGrace: 300)
        XCTAssertEqual(lines, [.camerasEdge(clean: 1, edge: 1)])
        XCTAssertFalse(lines[0].isPraise)
        XCTAssertTrue(lines[0].isDriving)
    }

    // MARK: - Дневные строки

    /// «На грани» складывается в день и вычитается из него зеркально.
    func testDayFoldAndUnfoldEdge() {
        let trip = record([pass(64, limit: 60), pass(63, limit: 60, camera: 2), pass(90, limit: 60, camera: 3)])
        let folded = TripDayBook.folded(trip, into: [])
        XCTAssertEqual(folded.first?.edgePasses, 2)
        XCTAssertEqual(folded.first?.cleanPasses, 2, "на грани — часть чистых: штрафа нет")
        XCTAssertEqual(folded.first?.overPasses, 1)
        let other = record([pass(50, limit: 60)], at: 7_200)
        let both = TripDayBook.folded(other, into: folded)
        let back = TripDayBook.unfolded(trip, from: both)
        XCTAssertEqual(back.first?.edgePasses, 0)
        XCTAssertEqual(TripDayBook.summary(folded, in: DateInterval(start: day, duration: 86_400)).edgePasses, 2)
    }

    /// Строка до обновления (nil) не получает «на грани» от одной новой
    /// поездки — иначе старые поездки того же дня выпали бы из счёта.
    func testLegacyRowWaitsForBackfill() {
        let old = record([pass(64, limit: 60)])
        var legacy = TripDayBook.folded(old, into: [])
        legacy[0].edgePasses = nil
        let fresh = record([pass(63, limit: 60)], at: 7_200)
        let after = TripDayBook.folded(fresh, into: legacy)
        XCTAssertNil(after.first?.edgePasses)

        let filled = TripDayBook.backfillingEdge(after, history: [fresh, old])
        XCTAssertEqual(filled.first?.edgePasses, 2, "все записи дня целы — дописали обе")
        XCTAssertEqual(filled.first?.trips, after.first?.trips, "остальное не трогаем")
    }

    /// Записи дня вычищены — дописывать не из чего, строка остаётся nil.
    func testBackfillSkipsPrunedDays() {
        let a = record([pass(64, limit: 60)])
        let b = record([pass(64, limit: 60)], at: 7_200)
        var rows = TripDayBook.folded(b, into: TripDayBook.folded(a, into: []))
        rows[0].edgePasses = nil
        XCTAssertNil(TripDayBook.backfillingEdge(rows, history: [b]).first?.edgePasses)
    }
}
