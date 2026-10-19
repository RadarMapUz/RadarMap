//
//  CommuteGhostTests.swift
//  RadarMapTests
//
//  Призрак дороги на работу (8.8.1): медиана, а не рекорд; пол лимита;
//  сегодняшний темп действует рядом и затухает; стоянка сдвигает прибытие;
//  сход с дороги глушит прогноз; запас с гистерезисом — и никакого
//  «опоздаете» без цели.
//

import XCTest
@testable import RadarMap

final class CommuteGhostTests: XCTestCase {
    private typealias G = CommuteGhost
    private typealias Row = CommuteProfile.Row
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 20 участков по 200 м = 4 км.
    private let ends: [Float] = (1...20).map { Float($0 * 200) }

    private func row(_ seconds: UInt16, departureMinute: Int = 8 * 60, weekend: Bool = false,
                     id: Double = 1) -> Row {
        let departure = utc.date(from: DateComponents(year: 2027, month: 1, day: 11,
                                                      hour: departureMinute / 60,
                                                      minute: departureMinute % 60))!
        return Row(tripID: id, departure: departure, weekend: weekend, arrivalMinute: 0,
                   seconds: [UInt16](repeating: seconds, count: 20))
    }

    private func base(_ rows: [Row], limits: [UInt8] = []) -> G.Baseline {
        G.baseline(ends: ends, limitKmh: limits, rows: rows)!
    }

    // MARK: - База

    /// Медиана, а не лучшее: одна гонка не делает «обычно» быстрее.
    func testBaselineIsMedianNotRecord() {
        let b = base([row(20), row(20), row(20), row(10), row(40)])
        XCTAssertEqual(b.total, 20 * 20, accuracy: 0.5)
    }

    /// Пол лимита: на лимите 60 участок 200 м не быстрее 12 с.
    func testGhostNeverBeatsTheLimit() {
        let b = base([row(5), row(5), row(5)], limits: [UInt8](repeating: 60, count: 20))
        for m in b.median { XCTAssertGreaterThanOrEqual(m, 12 - 0.01) }
    }

    /// Выборка: тот же класс дня и близкий выезд; выходные не смешиваются с
    /// буднями; меньше трёх — призрака нет.
    func testRowSelection() {
        let rows = [row(20, departureMinute: 480), row(20, departureMinute: 490),
                    row(20, departureMinute: 500), row(30, departureMinute: 480, weekend: true)]
        XCTAssertEqual(G.selectRows(rows, weekend: false, departureMinute: 485, calendar: utc)?.count, 3)
        XCTAssertNil(G.selectRows(rows, weekend: true, departureMinute: 485, calendar: utc),
                     "одна субботняя поездка — не «обычно»")
        // Вечерний выезд: окна ±60 и ±120 пусты — берутся все будние.
        XCTAssertEqual(G.selectRows(rows, weekend: false, departureMinute: 18 * 60, calendar: utc)?.count, 3)
    }

    // MARK: - Прогноз

    func testOnScheduleArrivalIsUsualRemainder() {
        let b = base([row(20), row(20), row(20)])
        let f = G.forecast(b, along: 2000, elapsed: 200, rho: 1, now: now)
        XCTAssertEqual(f.remaining, 200, accuracy: 0.5, "половина пути — половина обычного")
        XCTAssertEqual(f.deltaMinutes, 0)
        XCTAssertEqual(f.arrival.timeIntervalSince(now), 200, accuracy: 0.5)
    }

    /// Пробка рядом: темп ρ = 1,5 удлиняет ближние участки, но затухает с
    /// расстоянием — остаток меньше, чем «всё оставшееся в полтора раза».
    func testTodaysPaceActsNearAndDecays() {
        let b = base([row(20), row(20), row(20)])
        let usual = G.forecast(b, along: 400, elapsed: 60, rho: 1, now: now).remaining
        let slow = G.forecast(b, along: 400, elapsed: 60, rho: 1.5, now: now).remaining
        XCTAssertGreaterThan(slow, usual)
        XCTAssertLessThan(slow, usual * 1.5, "пробка на первом километре — не пробка на четвёртом")
    }

    /// Стоим: пройденное не растёт, а время в пути — да; прибытие уходит
    /// позже ровно на время стоянки.
    func testStandingStillPushesArrival() {
        let b = base([row(20), row(20), row(20)])
        let before = G.forecast(b, along: 1000, elapsed: 100, rho: 1, now: now)
        let after = G.forecast(b, along: 1000, elapsed: 400, rho: 1,
                               now: now.addingTimeInterval(300))
        XCTAssertEqual(after.arrival.timeIntervalSince(before.arrival), 300, accuracy: 0.5)
        XCTAssertEqual(after.deltaMinutes - before.deltaMinutes, 5)
    }

    func testPaceNeedsThreeSegmentsAndIsClamped() {
        let two = [(seconds: 40.0, median: 20.0, length: 200.0), (40, 20, 200)]
        XCTAssertEqual(G.pace(live: two), 1, "меньше трёх участков — темп не известен")
        let jam = [(seconds: 200.0, median: 20.0, length: 200.0), (200, 20, 200), (200, 20, 200)]
        let rho = G.pace(live: jam)
        XCTAssertLessThanOrEqual(rho, AppConfig.commuteGhostPaceMax)
        XCTAssertGreaterThan(rho, 1, "сглажено к прежнему, но в сторону пробки")
    }

    func testForecastWaitsForOnePointFiveKilometres() {
        XCTAssertFalse(G.isConfirmed(along: 800), "заезд в магазин у дома — ещё не дорога на работу")
        XCTAssertTrue(G.isConfirmed(along: 1600))
    }

    // MARK: - Сход

    func testOffRouteNeedsThreeFarFixesAndReturnNeedsAStretch() {
        var track = G.Track()
        XCTAssertTrue(track.update(offset: 120, accuracy: 10, stepMeters: 100))
        XCTAssertTrue(track.update(offset: 120, accuracy: 10, stepMeters: 100))
        XCTAssertFalse(track.update(offset: 120, accuracy: 10, stepMeters: 100), "три фикса и 300 м — сошли")
        XCTAssertFalse(track.update(offset: 20, accuracy: 10, stepMeters: 100), "одно касание линии — не возврат")
        XCTAssertFalse(track.update(offset: 20, accuracy: 10, stepMeters: 100))
        XCTAssertTrue(track.update(offset: 20, accuracy: 10, stepMeters: 100), "300 м у линии — вернулись")
    }

    func testPoorAccuracyIsNotAnExit() {
        var track = G.Track()
        for _ in 0..<5 {
            XCTAssertTrue(track.update(offset: 80, accuracy: 70, stepMeters: 100),
                          "80 м при точности 70 — шум, а не другая дорога")
        }
    }

    // MARK: - Запас

    func testNoTargetMeansNeverLate() {
        var tracker = G.SlackTracker()
        XCTAssertNil(tracker.update(slackMinutes: nil, now: now))
    }

    func testSlackHysteresisAndHold() {
        var tracker = G.SlackTracker()
        XCTAssertEqual(tracker.update(slackMinutes: 6, now: now), .comfortable)
        // 4 мин — уже «впритык» по границе, но в пределах гистерезиса: держим.
        XCTAssertEqual(tracker.update(slackMinutes: 4, now: now.addingTimeInterval(30)), .comfortable)
        // 2 мин — новое состояние, но принимается только со второго пересчёта
        // не раньше чем через минуту.
        XCTAssertEqual(tracker.update(slackMinutes: 2, now: now.addingTimeInterval(60)), .comfortable)
        XCTAssertEqual(tracker.update(slackMinutes: 2, now: now.addingTimeInterval(90)), .comfortable)
        XCTAssertEqual(tracker.update(slackMinutes: 2, now: now.addingTimeInterval(130)), .tight)
        // В «опаздываю» — только ниже −1,5.
        XCTAssertEqual(tracker.update(slackMinutes: -1, now: now.addingTimeInterval(200)), .tight)
        XCTAssertEqual(tracker.update(slackMinutes: -1, now: now.addingTimeInterval(300)), .tight)
        XCTAssertEqual(tracker.update(slackMinutes: -3, now: now.addingTimeInterval(400)), .tight)
        XCTAssertEqual(tracker.update(slackMinutes: -3, now: now.addingTimeInterval(470)), .late)
    }

    // MARK: - Голос

    func testAnnouncerSpeaksFirstThenOnlyOnRealShifts() {
        var a = G.Announcer()
        XCTAssertTrue(a.shouldSpeak(deltaMinutes: 0, remainingMeters: 9000, now: now), "первая — сразу")
        XCTAssertFalse(a.shouldSpeak(deltaMinutes: 2, remainingMeters: 8000, now: now.addingTimeInterval(300)),
                       "сдвиг на 2 мин — не повод")
        XCTAssertFalse(a.shouldSpeak(deltaMinutes: 4, remainingMeters: 8000, now: now.addingTimeInterval(120)),
                       "чаще раза в 4 мин — нет")
        XCTAssertTrue(a.shouldSpeak(deltaMinutes: 4, remainingMeters: 8000, now: now.addingTimeInterval(300)))
        XCTAssertFalse(a.shouldSpeak(deltaMinutes: 9, remainingMeters: 1500, now: now.addingTimeInterval(700)),
                       "у финиша не говорим")
        XCTAssertTrue(a.shouldSpeak(deltaMinutes: 9, remainingMeters: 5000, now: now.addingTimeInterval(700)))
        XCTAssertFalse(a.shouldSpeak(deltaMinutes: 15, remainingMeters: 5000, now: now.addingTimeInterval(1200)),
                       "больше трёх фраз за поездку — нет")
    }

    /// Быстрее обычного — «как обычно»: никаких «вы быстрее на…».
    func testPhraseNeverBragsAboutBeingFaster() {
        let ahead = G.phrase(direction: .toWork, arrival: now, deltaMinutes: -3)
        let usual = G.phrase(direction: .toWork, arrival: now, deltaMinutes: 0)
        XCTAssertEqual(ahead, usual)
        XCTAssertFalse(ahead.contains("быстр"))
    }
}
