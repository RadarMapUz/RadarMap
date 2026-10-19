//
//  ArrivalTargetTests.swift
//  RadarMapTests
//
//  «Быть на работе к 9:00» (8.8.5): срок действует по будням (и субботам —
//  по выбору), только для поездки, начатой до него и не раньше чем за 3 ч;
//  спрашиваем о сроке, только когда человек и правда приезжает «к девяти»;
//  позже срока — без «поторопитесь», голосом один раз и снова — только хуже
//  ещё на 5 мин.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ArrivalTargetTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 11 января 2027 — понедельник.
    private func date(day: Int = 11, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Когда срок действует

    func testWeekdaysAndOptionalSaturday() {
        let target = ArrivalTarget(minute: 540)
        XCTAssertTrue(target.applies(on: date(day: 11, 8), calendar: utc), "понедельник")
        XCTAssertTrue(target.applies(on: date(day: 15, 8), calendar: utc), "пятница")
        XCTAssertFalse(target.applies(on: date(day: 16, 8), calendar: utc), "суббота — не отмечена")
        XCTAssertFalse(target.applies(on: date(day: 17, 8), calendar: utc), "воскресенье")
        var six = target
        six.saturday = true
        XCTAssertTrue(six.applies(on: date(day: 16, 8), calendar: utc), "шестидневка")
        XCTAssertFalse(six.applies(on: date(day: 17, 8), calendar: utc))
    }

    func testDeadlineOnlyForATripBeforeIt() {
        let target = ArrivalTarget(minute: 540)
        XCTAssertEqual(target.deadline(forDeparture: date(8, 10), calendar: utc), date(9))
        XCTAssertNil(target.deadline(forDeparture: date(9, 10), calendar: utc), "выехали после срока")
        XCTAssertNil(target.deadline(forDeparture: date(5, 30), calendar: utc), "за 3,5 ч — другая поездка")
        XCTAssertNil(target.deadline(forDeparture: date(day: 17, 8), calendar: utc), "воскресенье")
    }

    // MARK: - Вопрос

    private func arrivals(_ minutes: [Int], firstDay: Int = 4) -> [Date] {
        // Будни подряд с понедельника 4 января, пропуская выходные.
        var days: [Int] = []
        var d = firstDay
        while days.count < minutes.count {
            let weekday = utc.component(.weekday, from: date(day: d, 12))
            if (2...6).contains(weekday) { days.append(d) }
            d += 1
        }
        return zip(days, minutes).map { date(day: $0, $1 / 60, $1 % 60) }
    }

    private var now: Date { date(day: 22, 20) }

    func testSuggestsTheRoundTimeTheDriverReallyKeeps() {
        let a = arrivals([520, 525, 530, 528, 533, 522, 536, 531, 527, 524])   // 8:40–8:56
        XCTAssertEqual(ArrivalTarget.suggestion(arrivals: a, now: now, calendar: utc), 540)
    }

    func testHalfHourTarget() {
        let a = arrivals([495, 500, 498, 502, 497, 499, 501, 496, 503, 500])   // около 8:20
        XCTAssertEqual(ArrivalTarget.suggestion(arrivals: a, now: now, calendar: utc), 510, "8:30")
    }

    func testNeedsEightWeekdays() {
        let a = arrivals([520, 525, 530, 528, 533, 522, 536])
        XCTAssertNil(ArrivalTarget.suggestion(arrivals: a, now: now, calendar: utc))
    }

    func testFlexibleHoursAreNotAsked() {
        let a = arrivals([450, 480, 600, 520, 570, 455, 590, 500, 610, 470])   // 7:30–10:10
        XCTAssertNil(ArrivalTarget.suggestion(arrivals: a, now: now, calendar: utc), "свободный график")
    }

    func testFarFromARoundTimeIsNotAsked() {
        let a = arrivals([480, 483, 485, 482, 484, 481, 486, 483, 485, 484])   // около 8:05
        XCTAssertNil(ArrivalTarget.suggestion(arrivals: a, now: now, calendar: utc),
                     "до 8:30 четверть часа с лишним — «к 8:30» это не про него")
    }

    func testFirstArrivalOfTheDayAndOnlyWeekdays() {
        var a = arrivals([520, 525, 530, 528, 533, 522, 536, 531, 527, 524])
        // Возврат с обеда — второе «прибытие» того же дня, и субботние поездки.
        a.append(date(day: 5, 14, 10))
        a.append(date(day: 9, 13, 0))
        a.append(date(day: 16, 13, 0))
        XCTAssertEqual(ArrivalTarget.suggestion(arrivals: a, now: now, calendar: utc), 540)
    }

    func testOldArrivalsAreForgotten() {
        let a = arrivals([520, 525, 530, 528, 533, 522, 536, 531, 527, 524])
        XCTAssertNil(ArrivalTarget.suggestion(arrivals: a, now: date(day: 28, 12).addingTimeInterval(40 * 86_400),
                                              calendar: utc), "старше 30 дней")
    }

    // MARK: - Слова

    func testSlackPhrasesNeverRush() {
        let arrival = date(9, 12)
        func phrase(_ state: CommuteGhost.Slack, _ minutes: Int) -> String {
            CommuteGhost.phrase(direction: .toWork, arrival: arrival, deltaMinutes: 0,
                                slack: .init(state: state, minutes: minutes, deadline: date(9)))
        }
        for text in [phrase(.comfortable, 9), phrase(.tight, 2), phrase(.late, -12)] {
            XCTAssertFalse(text.lowercased().contains("потороп"), text)
            XCTAssertFalse(text.contains("опоздаете"), text)
        }
        XCTAssertNotEqual(phrase(.late, -12), phrase(.tight, 2))
        XCTAssertTrue(phrase(.comfortable, 150).contains("больше часа"), "не «с запасом 150 минут»")
    }

    /// Гистерезис держит «позже» до +1,5 мин, но прогноз раньше срока словом
    /// «позже» не называется — это «впритык».
    func testHysteresisNeverSaysLateBeforeTheDeadline() {
        let held = CommuteGhost.TargetSlack(state: .late, minutes: 1, deadline: date(9))
        XCTAssertEqual(held.shown, .tight)
        XCTAssertEqual(CommuteGhost.TargetSlack(state: .late, minutes: 0, deadline: date(9)).shown, .tight)
        let late = CommuteGhost.TargetSlack(state: .late, minutes: -1, deadline: date(9))
        XCTAssertEqual(late.shown, .late)
        XCTAssertEqual(late.lateMinutes, 1)
    }

    /// Опоздание живёт в общем лимите фраз: после трёх — тишина.
    func testLateRespectsThePhraseCap() {
        var a = CommuteGhost.Announcer()
        let t = date(8)
        XCTAssertTrue(a.allowsLate(remainingMeters: 100, now: t), "первая фраза — где угодно")
        for i in 0..<3 { a.commit(deltaMinutes: i * 5, now: t.addingTimeInterval(Double(i) * 300)) }
        XCTAssertFalse(a.allowsLate(remainingMeters: 9000, now: t.addingTimeInterval(3600)))
        var b = CommuteGhost.Announcer()
        b.commit(deltaMinutes: 0, now: t)
        XCTAssertFalse(b.allowsLate(remainingMeters: 9000, now: t.addingTimeInterval(60)), "чаще раза в 4 мин")
        XCTAssertFalse(b.allowsLate(remainingMeters: 1500, now: t.addingTimeInterval(600)), "у финиша")
        XCTAssertTrue(b.allowsLate(remainingMeters: 5000, now: t.addingTimeInterval(600)))
    }

    func testLateIsRepeatedOnlyWhenFiveMinutesWorse() {
        var notice = CommuteGhost.LateNotice()
        XCTAssertTrue(notice.wants(lateMinutes: 3))
        notice.commit(lateMinutes: 3)
        XCTAssertFalse(notice.wants(lateMinutes: 6))
        XCTAssertFalse(notice.wants(lateMinutes: 2), "стало лучше — молчим")
        XCTAssertTrue(notice.wants(lateMinutes: 8))
    }

    // MARK: - На ходу

    /// Прямая 4 км, обычно 400 с; срок — через 300 с после выезда: позже
    /// срока. Голосом — один раз, хотя пересчётов десятки; постояли 6 мин —
    /// стало хуже ещё на 5+, и это говорится второй раз.
    @MainActor
    func testLiveLateIsSpokenOnceThenOnlyWhenWorse() {
        let lat = 41.30, lon0 = 69.20
        let k = 111_320 * cos(lat * .pi / 180)
        let start = date(8)
        var line: [Int32] = []
        for i in 0..<81 {
            line.append(Int32((lat * 1e5).rounded()))
            line.append(Int32(((lon0 + 50 * Double(i) / k) * 1e5).rounded()))
        }
        let rows = (0..<5).map { i in
            CommuteProfile.Row(tripID: Double(i), departure: start.addingTimeInterval(-Double(i + 3) * 86_400),
                               weekend: false, arrivalMinute: 0, seconds: [UInt16](repeating: 20, count: 20))
        }
        let variant = CommuteProfile.Variant(id: UUID(), line: line, ends: (1...20).map { Float($0 * 200) },
                                             limitKmh: [], rows: rows, lastUsed: start)
        let service = CommuteLiveService()
        var spoken: [String] = []
        service.onAnnounce = { spoken.append($0); return true }
        service.start(direction: .toWork, variants: [variant], departure: start,
                      deadline: start.addingTimeInterval(300), calendar: utc)
        var t = start
        func drive(through meters: Double, from: Double) {
            for s in stride(from: from, through: meters, by: 50) {
                service.note(CLLocationCoordinate2D(latitude: lat, longitude: lon0 + s / k), accuracy: 10, at: t)
                t = t.addingTimeInterval(5)
            }
        }
        drive(through: 1800, from: 0)
        XCTAssertEqual(service.display?.slack?.shown, .late)
        XCTAssertEqual(spoken.count, 1, "\(spoken)")
        XCTAssertTrue(spoken.first?.contains("позже срока") == true, "\(spoken)")
        // Стоим 6 минут на 1800-м метре.
        for _ in 0..<72 {
            service.note(CLLocationCoordinate2D(latitude: lat, longitude: lon0 + 1800 / k), accuracy: 10, at: t)
            t = t.addingTimeInterval(5)
        }
        XCTAssertEqual(spoken.count, 2, "хуже ещё на 6 мин — второй раз: \(spoken)")
        drive(through: 3500, from: 1850)
        XCTAssertEqual(spoken.count, 2, "без нового ухудшения — тишина: \(spoken)")
    }
}
