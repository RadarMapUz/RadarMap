//
//  TripRewardTests.swift
//  RadarMapTests
//
//  Итог поездки (этап 45): не больше двух строк заработанного, при
//  штрафуемом превышении — факт без похвалы, о сообществе — только
//  подтверждения, которые знает сервер.
//

import XCTest
@testable import RadarMap

final class TripRewardTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var end: Date { start.addingTimeInterval(1_800) }

    private func pick(_ verdict: TripRecord.Verdict, passes: [TripReward.Pass] = [],
                      reports: [TripReward.OwnReport] = [], seen: Int? = nil) -> [TripReward.Line] {
        TripReward.pick(verdict: verdict, passes: passes, tripStart: start, tripEnd: end,
                        reports: reports, seenConfirmations: seen, reportGrace: 300)
    }

    private func report(_ offset: TimeInterval, confirmers: Int? = nil, confirmed: Bool = false,
                        kind: ReportKind = .tripod) -> TripReward.OwnReport {
        TripReward.OwnReport(kind: kind, at: start.addingTimeInterval(offset),
                             confirmers: confirmers, confirmed: confirmed)
    }

    /// Все камеры с известным лимитом в лимите — «Все N камер».
    func testAllCamerasClean() {
        let passes = [TripReward.Pass(speedKmh: 55, limitKmh: 60),
                      TripReward.Pass(speedKmh: 70, limitKmh: 70),
                      TripReward.Pass(speedKmh: 90, limitKmh: nil)]
        XCTAssertEqual(pick(.clean, passes: passes), [.camerasClean(clean: 2, total: 2)])
    }

    /// Лишнее, но не штрафуемое — «1 из 2», и это всё ещё не упрёк.
    func testSoftOverIsCountedButNotFined() {
        let passes = [TripReward.Pass(speedKmh: 55, limitKmh: 60),
                      TripReward.Pass(speedKmh: 64, limitKmh: 60)]
        let lines = pick(.clean, passes: passes)
        XCTAssertEqual(lines, [.camerasClean(clean: 1, total: 2)])
    }

    /// Штрафуемое превышение — без похвалы: только факт.
    func testFinedOverspeedHasNoPraise() {
        let risk = pick(.risk(340_000), reports: [report(60, confirmers: 2)])
        XCTAssertEqual(risk.first, .risk(340_000))
        XCTAssertFalse(risk.first?.isPraise ?? true)
        XCTAssertEqual(pick(.overspeed(2)), [.overspeed(2)])
        XCTAssertFalse(pick(.overspeed(2)).contains { $0.isDriving && $0.isPraise })
    }

    /// Без лимитов и без камер — строки о вождении нет: нехватка данных не заслуга.
    func testNoDrivingLineWithoutKnownLimits() {
        XCTAssertEqual(pick(.unknownLimits), [])
        XCTAssertEqual(pick(.noCameras), [])
    }

    /// Не больше двух строк: вождение, затем сообщество.
    func testAtMostTwoLinesDrivingFirst() {
        let lines = pick(.clean, passes: [TripReward.Pass(speedKmh: 50, limitKmh: 60)],
                         reports: [report(100, confirmers: 2), report(200)], seen: 0)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].isDriving)
        XCTAssertEqual(lines[1], .reportConfirmed(drivers: 2))
    }

    /// Своя отметка в момент стопа обычно без голосов — «скажу, когда подтвердят».
    func testOwnReportAwaitingConfirmation() {
        XCTAssertEqual(pick(.noCameras, reports: [report(900, kind: .post)]), [.reportAwaiting(.post)])
        // Живой список видел «подтверждена» — хотя бы один водитель.
        XCTAssertEqual(pick(.noCameras, reports: [report(900, confirmed: true)]), [.reportConfirmed(drivers: 1)])
        // Отметка у подъезда сразу после стопа — ещё этой поездки.
        XCTAssertEqual(pick(.noCameras, reports: [report(1_800 + 120)]), [.reportAwaiting(.tripod)])
    }

    /// Подтверждения прежних отметок — только пришедшие с прошлого итога.
    func testEarlierConfirmationsOnlyNewOnes() {
        let earlier = [report(-86_400, confirmers: 3), report(-3_600, confirmers: 1)]
        XCTAssertEqual(TripReward.earlierConfirmations(earlier, before: start), 4)
        XCTAssertEqual(pick(.noCameras, reports: earlier, seen: 1), [.earlierConfirmed(3)])
        XCTAssertEqual(pick(.noCameras, reports: earlier, seen: 4), [])
        // Первый итог задаёт отсчёт — старые подтверждения не выдаются за новые.
        XCTAssertEqual(pick(.noCameras, reports: earlier, seen: nil), [])
    }
}
