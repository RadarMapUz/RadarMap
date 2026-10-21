//
//  CommuteAccuracyTests.swift
//  RadarMapTests
//
//  Журнал точности прибытия (24.1): точки прогноза в пути, ошибка и сдвиг,
//  что в журнал не идёт (другая дорога, магазин по пути), медленная и
//  ограниченная поправка сдвига, которая не раскачивается на своих же
//  поправках, и чтение файла прошлых форматов.
//

import XCTest
@testable import RadarMap

final class CommuteAccuracyTests: XCTestCase {
    private typealias A = CommuteAccuracy
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// Поездка 10 км за 30 мин: прогноз на 300 м, 1,5 км, середине; доехали.
    private func recorded(actualMinutes: Double = 33) -> A.Recorder {
        var r = A.Recorder(direction: .toWork, departure: t0)
        r.note(arrival: at(30 * 60), along: 300, length: 10_000, early: true, now: at(60))
        r.note(arrival: at(31 * 60), along: 1500, length: 10_000, early: false, now: at(300))
        r.note(arrival: at(32 * 60), along: 5200, length: 10_000, early: false, now: at(900))
        r.note(arrival: at(actualMinutes * 60), along: 9900, length: 10_000, early: false,
               now: at(actualMinutes * 60))
        return r
    }

    private func entry(_ id: Double, direction: Commute.Direction = .toWork, said: Double = 30,
                       real: Double, factor: Double? = nil, daysAgo: Double = 1) -> A.Entry {
        let departure = t0.addingTimeInterval(-daysAgo * 86_400)
        let point = A.Checkpoint(at: departure.addingTimeInterval(60),
                                 arrival: departure.addingTimeInterval(said * 60), factor: factor)
        return A.Entry(tripID: id, direction: direction, departure: departure,
                       arrival: departure.addingTimeInterval(real * 60), start: point, confirmed: point, middle: nil)
    }

    // MARK: - Запись

    func testRecorderKeepsThreePointsAndTheFact() throws {
        let e = try XCTUnwrap(recorded().entry(tripID: 1, endedAt: at(40 * 60), stops: []))
        XCTAssertEqual(e.start?.arrival, at(30 * 60), "первый показанный — на 300 м")
        XCTAssertEqual(e.confirmed?.arrival, at(31 * 60), "после 1,5 км")
        XCTAssertEqual(e.middle?.arrival, at(32 * 60), "середина линии")
        XCTAssertEqual(e.arrival, at(33 * 60), "доехали до конца линии, а не конец поездки (парковка)")
        XCTAssertEqual(e.error(try XCTUnwrap(e.headline)), 3 * 60, "«дал 8:30, приехал 8:33» — +3 мин")
    }

    func testOtherRoadAndShopStopAreNotForecastErrors() {
        var off = A.Recorder(direction: .toWork, departure: t0)
        off.note(arrival: at(30 * 60), along: 2000, length: 10_000, early: false, now: at(300))
        off.noteLeftLine()
        XCTAssertNil(off.entry(tripID: 1, endedAt: at(35 * 60), stops: []), "приехали другой дорогой")

        let shop = at(600)...at(1500)
        XCTAssertNil(recorded().entry(tripID: 1, endedAt: at(45 * 60), stops: [shop]),
                     "магазин по дороге — не ошибка прогноза")
        let before = at(-900)...at(-300)
        XCTAssertNotNil(recorded().entry(tripID: 1, endedAt: at(45 * 60), stops: [before]),
                        "стоянка до первого прогноза не мешает")
        XCTAssertNil(A.Recorder(direction: .toWork, departure: t0).entry(tripID: 1, endedAt: at(60), stops: []),
                     "прогноза не было — мерить нечего")
    }

    func testJournalReplacesSameTripAndForgetsOld() {
        var journal: [A.Entry] = []
        journal = A.appended(journal, entry(1, real: 30), now: t0)
        journal = A.appended(journal, entry(1, real: 35), now: t0)
        XCTAssertEqual(journal.count, 1, "склейка финиширует поездку второй раз — запись одна")
        XCTAssertEqual(journal.first?.arrival, entry(1, real: 35).arrival)
        journal = A.appended(journal, entry(2, real: 30, daysAgo: 90), now: t0)
        XCTAssertEqual(journal.map(\.tripID), [1], "старше 60 дней — вон")
        for i in 0..<100 { journal = A.appended(journal, entry(Double(10 + i), real: 30), now: t0) }
        XCTAssertEqual(journal.count, AppConfig.commuteAccuracyMaxEntries)
    }

    // MARK: - Статистика

    func testStatsMeanErrorAndBiasByDirectionAndHour() throws {
        let journal = [entry(1, real: 33), entry(2, real: 28), entry(3, real: 34),
                       entry(4, direction: .toHome, real: 30)]
        let work = try XCTUnwrap(A.stats(journal, direction: .toWork))
        XCTAssertEqual(work.trips, 3)
        XCTAssertEqual(work.meanAbsolute, 3 * 60, accuracy: 0.1, "|3| + |−2| + |4| = 9 → 3 мин")
        XCTAssertEqual(work.bias, 5.0 / 3 * 60, accuracy: 0.1, "чаще позже обещанного")
        XCTAssertEqual(work.meanMinutes, 3)
        let home = try XCTUnwrap(A.stats(journal, direction: .toHome))
        XCTAssertTrue(home.isExact)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let hour = utc.component(.hour, from: journal[0].departure)
        XCTAssertEqual(A.byHour(journal, direction: .toWork, calendar: utc)[hour]?.trips, 3)
        XCTAssertNil(A.stats(journal, direction: .toWork, hour: (hour + 3) % 24, calendar: utc))
    }

    func testLineNeedsFiveTrips() {
        let four = (0..<4).map { entry(Double($0), real: 33) }
        XCTAssertNil(A.shownStats(four, direction: .toWork), "четыре поездки — не «в среднем»")
        XCTAssertNotNil(A.shownStats(four + [entry(9, real: 31)], direction: .toWork))
    }

    // MARK: - Поправка сдвига

    func testBiasFactorIsSlowBoundedAndNeedsFiveTrips() {
        // Говорили 30 мин, ехали 33 — на 10 % дольше; поправка — половина.
        let late = (0..<6).map { entry(Double($0), said: 30, real: 33) }
        XCTAssertEqual(A.biasFactor(Array(late.prefix(4)), direction: .toWork), 1, "меньше пяти — без поправки")
        XCTAssertEqual(A.biasFactor(late, direction: .toWork), 1.05, accuracy: 0.002)
        XCTAssertEqual(A.biasFactor(late, direction: .toHome), 1, "чужое направление не учит")
        let awful = (0..<6).map { entry(Double($0), said: 30, real: 60) }
        XCTAssertEqual(A.biasFactor(awful, direction: .toWork), AppConfig.commuteAccuracyBiasMax,
                       "неделя ремонта не переучивает призрака")
    }

    /// Поправка не раскачивается: прогноз уже шёл с 1,05 и ошибся на 5 % —
    /// без своей поправки он ошибся бы на 10 %, и поправка остаётся 1,05, а
    /// не растёт до 1,075, 1,0875…
    func testBiasFactorLearnsFromUncorrectedError() {
        let corrected = (0..<6).map { entry(Double($0), said: 31.5, real: 33, factor: 1.05) }
        XCTAssertEqual(A.biasFactor(corrected, direction: .toWork), 1.05, accuracy: 0.003)
    }

    // MARK: - Файл

    /// Запись без необязательных полей (будущие версии добавят новые — правило
    /// 18) читается; пустой массив — тоже; профиль дороги прошлого формата
    /// журнал не трогает.
    func testOldAndPartialFilesDecode() throws {
        let json = #"[{"tripID":1,"direction":"toHome","departure":800000000,"arrival":800002000}]"#
        let entries = try JSONDecoder().decode([A.Entry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.direction, .toHome)
        XCTAssertNil(entries.first?.headline)
        let checkpoint = #"{"at":800000000,"arrival":800001000}"#
        XCTAssertNil(try JSONDecoder().decode(A.Checkpoint.self, from: Data(checkpoint.utf8)).factor)
        let book = #"{"version":1,"toWork":[],"toHome":[]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(CommuteProfile.Book.self, from: Data(book.utf8)))
        let roundTrip = try JSONDecoder().decode([A.Entry].self,
                                                 from: JSONEncoder().encode([entry(1, real: 31)]))
        XCTAssertEqual(roundTrip, [entry(1, real: 31)])
    }

    func testCSVHasNoCoordinatesOrTripID() {
        let csv = A.csv([entry(1_799_000_000, real: 33)], timeZone: TimeZone(identifier: "UTC")!)
        let lines = csv.split(separator: "\r\n")
        XCTAssertEqual(lines.first.map(String.init), A.csvHeader.joined(separator: ","))
        XCTAssertTrue(lines[1].hasPrefix("to_work,"))
        XCTAssertTrue(lines[1].hasSuffix(",3.0"))
        XCTAssertFalse(csv.contains("1799000000"), "номер поездки не выгружается")
    }
}
