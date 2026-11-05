//
//  ItogiRatingTests.swift
//  RadarMapTests
//
//  Как «Итоги» говорят о рейтинге (аудит 05.11): уровень одним словом,
//  сдвиг словами, «за что сняли» складывается ровно в 100 − рейтинг, мало
//  данных — без кольца, подменённое окно подписано.
//

import XCTest
@testable import RadarMap

final class ItogiRatingTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Понедельник 2 ноября 2026, 09:00 по Ташкенту.
    private var monday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
    }

    private func hotspot(_ id: Int, _ points: Double, limit: Int? = 60) -> RatingHotspot {
        RatingHotspot(id: id, location: "Камера \(id)", times: 2, points: points, worstSpeedKmh: 80,
                      worstDate: monday, limitKmh: limit, lat: nil, lon: nil)
    }

    func testLevelsOnTheSameThresholds() {
        XCTAssertEqual(ItogiRating.Level(rating: 95), .excellent)
        XCTAssertEqual(ItogiRating.Level(rating: 90), .excellent)
        XCTAssertEqual(ItogiRating.Level(rating: 89), .careful)
        XCTAssertEqual(ItogiRating.Level(rating: 65), .risk)
        XCTAssertEqual(ItogiRating.Level(rating: 59), .risky)
        for rating in 0...100 {
            XCTAssertTrue(ItogiRating.Level(rating: rating).range.contains(rating), "\(rating)")
        }
        XCTAssertEqual(ItogiRating.Level.risk.next(from: 65)?.points, 10)
        XCTAssertNil(ItogiRating.Level.excellent.next(from: 95))
    }

    /// Сдвиг меньше шага — шум, о нём молчим; иначе — словами, без знака.
    func testDeltaWords() {
        XCTAssertNil(ItogiRating.deltaWords(2, period: .week, step: 3))
        XCTAssertNil(ItogiRating.deltaWords(nil, period: .week, step: 3))
        let down = ItogiRating.deltaWords(-8, period: .week, step: 3) ?? ""
        XCTAssertTrue(down.contains("8"))
        XCTAssertFalse(down.contains("−"), "словами, а не «−8 к прошлой»")
        XCTAssertNotEqual(down, ItogiRating.deltaWords(8, period: .week, step: 3))
    }

    /// Мало поездок или километров — без кольца; у дня рейтинга нет.
    func testAvailability() {
        var summary = PeriodSummary()
        XCTAssertEqual(ItogiRating.availability(summary, period: .week), .none)
        summary.trips = 1
        summary.distance = 30_000
        summary.rating = 97
        XCTAssertEqual(ItogiRating.availability(summary, period: .week, minTrips: 2, minMeters: 20_000), .tooFew)
        summary.trips = 3
        summary.distance = 12_000
        XCTAssertEqual(ItogiRating.availability(summary, period: .week, minTrips: 2, minMeters: 20_000), .tooFew)
        summary.distance = 25_000
        XCTAssertEqual(ItogiRating.availability(summary, period: .week, minTrips: 2, minMeters: 20_000), .shown(97))
        XCTAssertEqual(ItogiRating.availability(summary, period: .day, minTrips: 2, minMeters: 20_000), .notForPeriod)
        summary.rating = nil
        XCTAssertEqual(ItogiRating.availability(summary, period: .month), .none)
    }

    /// «Сняли 35: камеры −15, резкая езда −20» — части складываются в итог.
    func testTakenSumsToDeficit() throws {
        let sources = RatingSources(cameras: [hotspot(1, 9.6), hotspot(2, 5.3)], smoothness: 20.1)
        let taken = try XCTUnwrap(ItogiRating.taken(rating: 65, sources: sources))
        XCTAssertEqual(taken.total, 35)
        XCTAssertEqual(taken.cameras + taken.smoothness, 35)
        XCTAssertEqual(taken.cameras, 15)
        XCTAssertEqual(taken.smoothness, 20)
        XCTAssertEqual(taken.cameraCount, 2)
        XCTAssertEqual(taken.topCamera, "Камера 1")
        XCTAssertNil(ItogiRating.taken(rating: 100, sources: sources), "снимать нечего")
        XCTAssertNil(ItogiRating.taken(rating: 70, sources: RatingSources()), "записи вычищены — не выдумываем")
    }

    /// Советов не больше двух, первым — тот, что возвращает больше.
    func testTipsOrderedByGain() {
        let sources = RatingSources(cameras: [hotspot(1, 15)], smoothness: 20)
        let tips = ItogiRating.tips(rating: 65, sources: sources, cameraRating: 80)
        XCTAssertEqual(tips, [.smoothness(rating: 85, beatsCameras: true),
                              .camera(location: "Камера 1", limitKmh: 60, rating: 80)])
        XCTAssertEqual(ItogiRating.tips(rating: 65, sources: RatingSources(cameras: [hotspot(1, 15)], smoothness: 0),
                                        cameraRating: 80),
                       [.camera(location: "Камера 1", limitKmh: 60, rating: 80)])
        XCTAssertTrue(ItogiRating.tips(rating: 65, sources: RatingSources(cameras: [hotspot(1, 15)]),
                                       cameraRating: nil).isEmpty, "без «что было бы» совета нет")
    }

    /// «Будь так всю неделю» — все проезды камеры в лимите, балл — от
    /// сохранённого, другие камеры и потолок учтены.
    func testRatingIfCameraClean() throws {
        func pass(_ camera: Int, _ speed: Double) -> PassedCamera {
            PassedCamera(id: UUID(), cameraID: camera, typeRaw: "Стационар радар", location: "К\(camera)",
                         speedKmh: speed, date: monday, lat: nil, lon: nil, limitKmh: 60)
        }
        func trip(_ hours: Double, _ passes: [PassedCamera], score: Double) -> TripRecord {
            let start = monday.addingTimeInterval(hours * 3_600)
            return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1_800), distanceMeters: 10_000,
                              maxSpeedKmh: 90, passed: passes, score: score)
        }
        // −14 (К1) и −8 (К2) → 78; вторая поездка −14 (К1) → 86.
        let a = trip(1, [pass(1, 75), pass(2, 66)], score: 78)
        let b = trip(3, [pass(1, 75)], score: 86)
        let days = TripDayBook.rebuilt(from: [b, a], calendar: calendar)
        let week = StatsPeriod.week.interval(containing: monday, calendar: calendar)
        XCTAssertEqual(TripDayBook.summary(days, in: week).rating, 82)
        let clean = try XCTUnwrap(ItogiRating.ratingIfCameraClean(cameraID: 1, records: [b, a], days: days, in: week))
        XCTAssertEqual(clean, 96, "(92 + 100) / 2")
        XCTAssertNil(ItogiRating.ratingIfCameraClean(cameraID: 9, records: [b, a], days: days, in: week))
    }

    /// «Больше всего — в поездке пт, 18:34»: остаток недобора сверх камер.
    func testRoughestTrip() {
        func trip(_ hours: Double, score: Double, over: Double?) -> TripRecord {
            let start = monday.addingTimeInterval(hours * 3_600)
            let passes = over.map {
                [PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "К",
                              speedKmh: 60 + $0, date: start, lat: nil, lon: nil, limitKmh: 60)]
            } ?? []
            return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1_800), distanceMeters: 10_000,
                              maxSpeedKmh: 90, passed: passes, score: score)
        }
        let camerasOnly = trip(1, score: 75, over: 25)     // −25 камеры, плавность 0
        let rough = trip(2, score: 82, over: nil)          // −18 плавность
        let mixed = trip(3, score: 80, over: 15)           // −14 камеры, −6 плавность
        let week = StatsPeriod.week.interval(containing: monday, calendar: calendar)
        XCTAssertEqual(ItogiRating.roughestTrip(records: [camerasOnly, rough, mixed], in: week)?.id, rough.id)
        XCTAssertNil(ItogiRating.roughestTrip(records: [camerasOnly], in: week))
    }

    func testBaselineWords() {
        let baseline = RatingBaseline(median: 71, low: 66, high: 76, periods: 5)
        XCTAssertNil(ItogiRating.baselineWords(nil, rating: 65, period: .week))
        let below = ItogiRating.baselineWords(baseline, rating: 65, period: .week) ?? ""
        let inside = ItogiRating.baselineWords(baseline, rating: 70, period: .week) ?? ""
        XCTAssertTrue(below.contains("66–76"))
        XCTAssertNotEqual(below, inside)
    }

    // MARK: - Окно

    /// Понедельник утром неделя пуста — открываем прошлую и говорим об этом.
    func testOpeningAnchorAndNotice() throws {
        let lastFriday = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: monday))!
        var row = TripDay(day: lastFriday)
        row.trips = 2
        row.distanceMeters = 30_000
        let anchor = try XCTUnwrap(ItogiWindow.openingAnchor(days: [row], period: .week, now: monday,
                                                             calendar: calendar))
        XCTAssertEqual(anchor, lastFriday)
        let notice = ItogiWindow.notice(period: .week, shown: anchor, now: monday, calendar: calendar)
        XCTAssertEqual(notice, String(localized: "На этой неделе поездок ещё нет — показана прошлая"))
        XCTAssertNil(ItogiWindow.notice(period: .week, shown: monday, now: monday, calendar: calendar),
                     "идущее окно подписи не требует")

        var today = TripDay(day: calendar.startOfDay(for: monday))
        today.trips = 1
        XCTAssertNil(ItogiWindow.openingAnchor(days: [today, row], period: .week, now: monday, calendar: calendar),
                     "в идущей неделе есть поездка — открываем её")
    }
}
