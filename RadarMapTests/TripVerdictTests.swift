//
//  TripVerdictTests.swift
//  RadarMapTests
//
//  Вердикт поездки (карточка «Поездка сохранена» и карточка «поделиться»):
//  деньги — только ждущие ответа по достоверному лимиту, а «все в лимите» —
//  только без единого превышения и хоть с одним известным лимитом. Раньше
//  риск 0 читался как «Все камеры в лимите»: после превышения с предположенным
//  лимитом или после «штраф пришёл» такую карточку отправляли друзьям.
//  Плюс подписи «Итогов» (6.2–6.3): один счётчик проездов, метка рейтинга
//  со словами, серые точки там, где лимит неизвестен.
//

import XCTest
@testable import RadarMap

final class TripVerdictTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pass(_ id: Int, speed: Double, limit: Int?, assumed: Bool? = nil,
                      paid: Bool? = nil, dismissed: Bool? = nil) -> PassedCamera {
        var pass = PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                                location: "Юнусабад", speedKmh: speed, date: now,
                                lat: 41.31, lon: 69.28, limitKmh: limit)
        pass.limitAssumed = assumed
        pass.finePaid = paid
        pass.fineDismissed = dismissed
        return pass
    }

    private func record(_ passes: [PassedCamera]) -> TripRecord {
        TripRecord(id: now.timeIntervalSince1970, startedAt: now,
                   endedAt: now.addingTimeInterval(1800), distanceMeters: 12_000,
                   maxSpeedKmh: 95, passed: passes, score: 80)
    }

    func testPendingFineIsRisk() {
        let verdict = record([pass(1, speed: 88, limit: 60), pass(2, speed: 55, limit: 60)]).verdict
        XCTAssertEqual(verdict, .risk(FineSchedule.fine(overKmh: 28)))
    }

    /// Лимит предположен по классу дороги: суммы нет, но превышение было —
    /// рейтинг его видит, и карточка не смеет сказать «в лимите».
    func testAssumedLimitOverspeedIsNotClean() {
        XCTAssertEqual(record([pass(1, speed: 88, limit: 60, assumed: true)]).verdict, .overspeed(1))
    }

    /// «Пришёл» и «не пришёл» снимают сумму риска, но не поведение.
    func testAnsweredFinesStayOverspeed() {
        let passes = [pass(1, speed: 88, limit: 60, paid: true),
                      pass(2, speed: 90, limit: 60, dismissed: true),
                      pass(3, speed: 50, limit: 60)]
        XCTAssertEqual(record(passes).verdict, .overspeed(2))
    }

    func testCleanNeedsAKnownLimit() {
        XCTAssertEqual(record([pass(1, speed: 55, limit: 60), pass(2, speed: 70, limit: nil)]).verdict,
                       .clean, "одна камера без лимита не отменяет чистую поездку")
        XCTAssertEqual(record([pass(1, speed: 70, limit: nil), pass(2, speed: 90, limit: nil)]).verdict,
                       .unknownLimits, "ни одного лимита — «в лимите» не знаем")
        XCTAssertEqual(record([]).verdict, .noCameras)
    }

    /// Граница вердикта — ступень штрафа: допуск камеры (+5 км/ч) ещё не
    /// штрафуемое превышение, как во всех сводках. Но балл он снимает — и с
    /// 05.11 это не «чисто», а «на грани» (PassVerdict): «Все камеры — без
    /// превышения» рядом с баллом 92 водитель не мог объяснить.
    func testWithinToleranceIsEdge() {
        let edge = 60 + FineSchedule.toleranceKmh
        XCTAssertEqual(record([pass(1, speed: edge, limit: 60)]).verdict, .edge(1))
        XCTAssertEqual(record([pass(1, speed: edge + 1, limit: 60, assumed: true)]).verdict,
                       .overspeed(1))
    }

    // MARK: - Подписи Итогов

    /// Вывод героя о чистом периоде — без числа: «Камер в лимите: 31» считало
    /// проезды с известным лимитом, легенда карты — разные камеры, «Детали» —
    /// все проезды. Число проездов живёт в карточке денег.
    func testCleanInsightCarriesNoCounter() throws {
        var summary = PeriodSummary()
        summary.cameras = 34
        summary.cleanPasses = 31
        let insight = try XCTUnwrap(PeriodInsights.build(summary).first { $0.id == "clean" })
        XCTAssertFalse(insight.text.contains(where: \.isNumber), insight.text)
    }

    /// Судили одну камеру из сорока одной — «ни одного превышения» не
    /// говорим; говорим, что у большинства лимит неизвестен.
    func testMostlyUnknownLimitsAreSaidNotPraised() {
        var summary = PeriodSummary()
        summary.cameras = 41
        summary.cleanPasses = 1
        let ids = PeriodInsights.build(summary).map(\.id)
        XCTAssertFalse(ids.contains("clean"), "\(ids)")
        XCTAssertTrue(ids.contains("limits"), "\(ids)")
        // Половина судима — это уже период, о котором можно сказать «чисто».
        summary.cleanPasses = 21
        XCTAssertTrue(PeriodInsights.build(summary).map(\.id).contains("clean"))
    }

    /// Место в «Риск ≈ … · место» — у ждущего штрафа, а не у лидера по
    /// баллам, чей штраф отменён или лимит предположен.
    func testRiskPlaceIsThePendingFine() {
        var dismissed = pass(1, speed: 110, limit: 60, dismissed: true)
        dismissed.location = "Чиланзар"
        var assumed = pass(2, speed: 105, limit: 60, assumed: true)
        assumed.location = "Сергели"
        var pending = pass(3, speed: 80, limit: 60)
        pending.location = "Юнусабад"
        XCTAssertEqual(TripHistorySection.worstRiskPlace(record([dismissed, assumed, pending])), "Юнусабад")
        XCTAssertNil(TripHistorySection.worstRiskPlace(record([dismissed, assumed])))
    }

    /// Точка без лимита — нейтральная: ни зелёная, ни красная.
    func testMarkerWithoutLimitIsUnknown() {
        let unknown = PassMarker(cameraID: 1, lat: 41.3, lon: 69.2, location: "", times: 2,
                                 overTimes: 0, maxSpeedKmh: 70, limitKmh: nil)
        let known = PassMarker(cameraID: 2, lat: 41.3, lon: 69.2, location: "", times: 1,
                               overTimes: 0, maxSpeedKmh: 55, limitKmh: 60)
        XCTAssertTrue(unknown.limitUnknown)
        XCTAssertFalse(unknown.hasViolation)
        XCTAssertFalse(known.limitUnknown)
    }

    /// «−8 к прошлой»: типографский минус и слова, а не голое «-8».
    func testRatingDeltaTextHasWordsAndTrueMinus() throws {
        try XCTSkipUnless(Bundle.main.preferredLocalizations.first == "ru",
                          "фраза проверяется на русском каталоге")
        XCTAssertEqual(StatsPeriod.week.ratingDeltaText(6), "+6 к прошлой")
        XCTAssertEqual(StatsPeriod.week.ratingDeltaText(-8), "−8 к прошлой")
        XCTAssertEqual(StatsPeriod.month.ratingDeltaText(-12), "−12 к прошлому")
        XCTAssertFalse(StatsPeriod.day.ratingDeltaText(-3).contains("-"), "дефис вместо минуса")
    }

    func testSignedUsesTypographicMinus() {
        XCTAssertEqual(Formatting.signed(6), "+6")
        XCTAssertEqual(Formatting.signed(-8), "−8")
        XCTAssertEqual(Formatting.signed(0), "0")
    }
}
