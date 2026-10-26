//
//  WeeklyGoalTests.swift
//  RadarMapTests
//
//  Цель недели «без превышений у камер» (31E): серия по завершённым неделям,
//  неделя без камер серию не рвёт, превышение рвёт, идущая неделя в серию
//  не входит.
//

import XCTest
@testable import RadarMap

final class WeeklyGoalTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    /// Пятница, 15.01.2027 (UTC); неделя — с понедельника 11.01.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ daysAgo: Int, clean: Int, over: Int) -> TripDay {
        let date = utc.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        var item = TripDay(day: date)
        item.trips = 1
        item.cleanPasses = clean
        item.overPasses = over
        item.cameraPasses = clean + over
        return item
    }

    func testStreakCountsCompletedCleanWeeks() throws {
        // Эта неделя (пн 11.01 — сегодня): чисто; три прошлых — чисто, четвёртая — превышение.
        let days = [day(1, clean: 3, over: 0), day(7, clean: 2, over: 0), day(14, clean: 4, over: 0),
                    day(21, clean: 1, over: 0), day(28, clean: 1, over: 2)]
        let goal = try XCTUnwrap(WeeklyGoal.build(days: days, now: now, calendar: utc))
        XCTAssertEqual(goal.state, .onTrack(passes: 3))
        XCTAssertEqual(goal.streak, 3, "идущая неделя вошла в серию или превышение не порвало её")
    }

    func testWeekWithoutCamerasNeitherBreaksNorExtends() throws {
        // Неделю назад — только поездка без камер (судить нечего).
        let days = [day(7, clean: 0, over: 0), day(14, clean: 2, over: 0), day(21, clean: 1, over: 1)]
        let goal = try XCTUnwrap(WeeklyGoal.build(days: days, now: now, calendar: utc))
        XCTAssertEqual(goal.state, .waiting)
        XCTAssertEqual(goal.streak, 1)
    }

    func testMissedThisWeek() throws {
        let goal = try XCTUnwrap(WeeklyGoal.build(days: [day(0, clean: 1, over: 2)], now: now, calendar: utc))
        XCTAssertEqual(goal.state, .missed(over: 2))
        XCTAssertEqual(goal.streak, 0)
    }

    func testNoJudgedPassesMeansNoGoal() {
        XCTAssertNil(WeeklyGoal.build(days: [day(2, clean: 0, over: 0)], now: now, calendar: utc),
                     "цель «без превышений у камер» тому, кто у камер не ездит")
    }

    func testMarksFollowTheCalendarWeek() throws {
        // Вт (3 дня назад) — превышение, чт (вчера) — чисто, пт — сегодня без камер.
        let goal = try XCTUnwrap(WeeklyGoal.build(days: [day(3, clean: 0, over: 1), day(1, clean: 2, over: 0)],
                                                  now: now, calendar: utc))
        XCTAssertEqual(goal.marks, [.none, .over, .none, .clean, .none, .future, .future])
    }
}
