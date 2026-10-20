//
//  OverspeedRunTests.swift
//  RadarMapTests
//
//  «Превышаем устойчиво» — от самой скорости, а не от момента, когда стал
//  известен лимит. Главный тест — первая фраза о камере на дороге без
//  maxspeed: 100 в зоне 70 обязана звучать срочно на ТОМ ЖЕ тике, на котором
//  запасной лимит появился (прогон трассы 13.3: выходила спокойной).
//

import XCTest
@testable import RadarMap

final class OverspeedRunTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - С известным лимитом — как раньше

    /// Превышение держится секунду — устойчиво; один тик в лимите
    /// обнуляет отсчёт.
    func testKnownLimitCountsLikeBefore() {
        var run = OverspeedRun()
        run.note(kmh: 80, over: true, at: at(0))
        XCTAssertFalse(run.isSustained(line: 65, seconds: 1, now: at(0)), "одного тика мало")
        run.note(kmh: 80, over: true, at: at(1))
        XCTAssertTrue(run.isSustained(line: 65, seconds: 1, now: at(1)))
        run.note(kmh: 60, over: false, at: at(2))
        run.note(kmh: 80, over: true, at: at(3))
        XCTAssertFalse(run.isSustained(line: 65, seconds: 1, now: at(3)), "отсчёт начался заново")
        XCTAssertEqual(run.since(line: 65), at(3))
    }

    /// Один шумный фикс над порогом — не превышение: ради этого отсчёт и есть.
    func testOneNoisyFixIsNotSustained() {
        var run = OverspeedRun()
        run.note(kmh: 58, over: false, at: at(0))
        run.note(kmh: 68, over: true, at: at(1))
        XCTAssertFalse(run.isSustained(line: 65, seconds: 1, now: at(1)))
    }

    /// Лимит прыгнул на тик (сегмент соседней улицы «40»): прошлые тики были в
    /// ИЗВЕСТНОМ лимите — отсчёт с нуля, защита от скачка лимита осталась.
    func testAJumpToALowerKnownLimitStillRestartsTheCount() {
        var run = OverspeedRun()
        for second in 0..<5 { run.note(kmh: 100, over: false, at: at(Double(second))) }   // лимит 100
        run.note(kmh: 100, over: true, at: at(5))                                           // лимит 40
        XCTAssertFalse(run.isSustained(line: 45, seconds: 1, now: at(5)))
    }

    /// Редкие фиксы (в кармане раз в 6 с): прошлый тик в окне есть всегда —
    /// окно по числу тиков, а не по времени.
    func testSparseFixesKeepThePreviousTick() {
        var run = OverspeedRun()
        run.note(kmh: 90, over: true, at: at(0))
        run.note(kmh: 90, over: true, at: at(6))
        XCTAssertTrue(run.isSustained(line: 75, seconds: AppConfig.overspeedSustainSeconds, now: at(6)))
    }

    /// Окно ограничено, а отсчёт длиннее окна упирается в старейший тик —
    /// для секундных порогов это «устойчиво».
    func testTheWindowIsBoundedButLongRunsStaySustained() {
        var run = OverspeedRun()
        for second in 0..<100 { run.note(kmh: 90, over: true, at: at(Double(second))) }
        XCTAssertEqual(run.samples.count, AppConfig.overspeedRunSamples)
        XCTAssertTrue(run.isSustained(line: 75, seconds: AppConfig.overspeedSustainSeconds, now: at(99)))
    }

    // MARK: - Тики без лимита

    /// Лимита не было — это «неизвестно», а не «в лимите»: когда он
    /// появился, скорость прошлых тиков судится им.
    func testUnknownLimitTicksCountOnceTheLimitAppears() {
        var run = OverspeedRun()
        for second in 0..<5 { run.note(kmh: 100, over: nil, at: at(Double(second))) }
        run.note(kmh: 100, over: true, at: at(5))
        XCTAssertTrue(run.isSustained(line: 72, seconds: AppConfig.overspeedSustainSecondsNearCamera,
                                      now: at(5)))
        XCTAssertEqual(run.since(line: 72), at(0))
    }

    /// …но только та скорость, что была выше нового порога.
    func testUnknownTicksBelowTheNewLineDoNotCount() {
        var run = OverspeedRun()
        for second in 0..<5 { run.note(kmh: 60, over: nil, at: at(Double(second))) }
        run.note(kmh: 80, over: true, at: at(5))
        XCTAssertFalse(run.isSustained(line: 72, seconds: 1, now: at(5)))
    }

    // MARK: - Сквозной тик: запасной лимит → порог → отсчёт → фраза

    /// Трасса без maxspeed, 100 км/ч: до камеры ближайшей нет — класса для
    /// догадки нет, лимита нет. На тике, где камера стала ближайшей (и
    /// звучит первое оповещение), лимит предположен по её классу (70 в
    /// населённом пункте) — и первая фраза срочная. Раньше отсчёт на этом
    /// тике только начинался, и фраза выходила спокойной.
    func testFirstPhraseOnARoadWithoutMaxspeedIsUrgent() throws {
        let speed = 100.0
        var run = OverspeedRun()
        // Тики без ближайшей камеры: класс .unknown — догадки нет.
        XCTAssertNil(RoadClass.unknown.assumedLimitKmh(inSettlement: true))
        for second in 0..<6 { run.note(kmh: speed, over: nil, at: at(Double(second))) }

        // Тик первого оповещения: ближайшая — камера на primary.
        let limit = try XCTUnwrap(RoadClass.primary.assumedLimitKmh(inSettlement: true))
        XCTAssertEqual(limit, 70)
        let threshold = OverspeedThreshold.kmh(cameraAhead: true, userTolerance: 5)
        let line = Double(limit) + threshold
        let now = at(6)
        run.note(kmh: speed, over: speed > line, at: now)
        let sustained = run.isSustained(line: line, seconds: AppConfig.overspeedSustainSecondsNearCamera,
                                        now: now)
        XCTAssertTrue(sustained)

        // То же, что собирает LocationService.situation(for:).
        let over: Double? = sustained ? speed - Double(limit) : nil
        let plan = VoiceDirector.decide(VoiceDirector.Situation(context: .highway, overKmh: over,
                                                                limitKmh: limit))
        XCTAssertEqual(plan.voice, .urgent, "100 в зоне 70 у камеры — срочно, с первой фразы")

        // Прежний отсчёт — с тика, где лимит появился: устойчивости нет.
        var fresh = OverspeedRun()
        fresh.note(kmh: speed, over: true, at: now)
        XCTAssertFalse(fresh.isSustained(line: line, seconds: AppConfig.overspeedSustainSecondsNearCamera,
                                         now: now))
        XCTAssertEqual(VoiceDirector.decide(VoiceDirector.Situation(context: .highway, overKmh: nil,
                                                                    limitKmh: limit)).voice, .calm,
                       "так было: спокойно")
    }
}
