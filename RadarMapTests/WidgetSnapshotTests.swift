//
//  WidgetSnapshotTests.swift
//  RadarMapTests
//
//  Виджет ничего не считает, но обязан правильно понимать присланное. Главное
//  здесь — он не должен выдавать прошлую неделю за текущую: снимок пишется
//  при уходе в фон и в конце поездки, поэтому «открыл в воскресенье, в
//  понедельник не открывал» — обычный, а не редкий случай.
//

import XCTest
@testable import RadarMap

final class WidgetSnapshotTests: XCTestCase {

    /// Понедельник, фиксированная точка — чтобы «неделя» не зависела от дня
    /// прогона. UTC-календарь с понедельником: тест про арифметику недель, а
    /// не про локаль машины.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // пятница

    private var thisWeekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: now)!.start
    }

    // MARK: - Чья это неделя

    func testCurrentWeekIsRecognised() {
        XCTAssertTrue(WidgetWeek.isCurrentWeek(thisWeekStart, now: now, calendar: calendar))
    }

    func testLastWeekIsNotPassedOffAsCurrent() {
        let lastWeek = thisWeekStart.addingTimeInterval(-7 * 86400)
        XCTAssertFalse(WidgetWeek.isCurrentWeek(lastWeek, now: now, calendar: calendar),
                       "прошлая неделя под словом «Неделя» — это враньё на домашнем экране")
    }

    func testMissingWeekStartIsNotCurrent() {
        // Снимок из версии, где поля ещё не было: лучше показать даты, чем
        // молча выдать неизвестно чьи цифры за эту неделю.
        XCTAssertFalse(WidgetWeek.isCurrentWeek(nil, now: now, calendar: calendar))
    }

    func testMidWeekTimestampStillCountsAsCurrentWeek() {
        // Снимок пишется в любой момент недели, не только в её начало.
        let wednesday = thisWeekStart.addingTimeInterval(2 * 86400 + 3600)
        XCTAssertTrue(WidgetWeek.isCurrentWeek(wednesday, now: now, calendar: calendar))
    }

    // MARK: - Свежесть

    func testFreshSnapshotIsNotStale() {
        XCTAssertFalse(WidgetWeek.isStale(now.addingTimeInterval(-3600), now: now))
    }

    func testDayOldSnapshotIsStale() {
        XCTAssertTrue(WidgetWeek.isStale(now.addingTimeInterval(-30 * 3600), now: now))
    }

    func testMissingTimestampIsStale() {
        XCTAssertTrue(WidgetWeek.isStale(nil, now: now))
    }

    // MARK: - Столбики

    func testBarsAreScaledToTheLongestDay() {
        let heights = WidgetWeek.barHeights([0, 10_000, 20_000, 0, 0, 0, 5_000])
        XCTAssertEqual(heights[2], 1, accuracy: 0.001)
        XCTAssertEqual(heights[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(heights[6], 0.25, accuracy: 0.001)
    }

    func testEmptyWeekHasNoBarsButKeepsSevenDays() {
        let heights = WidgetWeek.barHeights([0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(heights.count, 7, "день без поездок не исчезает — иначе неделя короче, чем была")
        XCTAssertTrue(heights.allSatisfy { $0 == 0 })
    }

    func testShortArrayFromOlderAppVersionIsPadded() {
        // Данные приходят из другого процесса и, возможно, из прошлой версии:
        // доверять их длине нельзя, иначе индекс за пределы массива уронит
        // виджет прямо на домашнем экране.
        XCTAssertEqual(WidgetWeek.barHeights([1_000, 2_000]).count, 7)
        XCTAssertEqual(WidgetWeek.padded([true, false]).count, 7)
        XCTAssertEqual(WidgetWeek.padded([1.0, 2, 3, 4, 5, 6, 7, 8, 9]).count, 7)
    }

    // MARK: - Сегодня

    func testTodayIndexPointsAtTheRightColumn() {
        // now — пятница, неделя с понедельника: индекс 4.
        XCTAssertEqual(WidgetWeek.todayIndex(thisWeekStart, now: now, calendar: calendar), 4)
    }

    func testTodayIsNotMarkedOnAnotherWeek() {
        let lastWeek = thisWeekStart.addingTimeInterval(-7 * 86400)
        XCTAssertNil(WidgetWeek.todayIndex(lastWeek, now: now, calendar: calendar),
                     "обводить «сегодня» на чужой неделе нечего")
    }

    // MARK: - Подписи дней

    func testDayLabelsFollowTheCalendarsFirstWeekday() {
        var monday = Calendar(identifier: .gregorian)
        monday.locale = Locale(identifier: "ru_RU")
        monday.firstWeekday = 2
        var sunday = monday
        sunday.firstWeekday = 1
        let mondayFirst = WidgetWeek.dayLabels(calendar: monday)
        let sundayFirst = WidgetWeek.dayLabels(calendar: sunday)
        XCTAssertEqual(mondayFirst.count, 7)
        XCTAssertEqual(sundayFirst.count, 7)
        XCTAssertNotEqual(mondayFirst.first, sundayFirst.first,
                          "порядок дней берётся из календаря пользователя, а не зашит")
        XCTAssertEqual(Set(mondayFirst), Set(sundayFirst))
    }

    // MARK: - Обычная неделя и километры

    func testUsualWeekIsMedianAndSurvivesOneHugeTrip() {
        // Четыре обычные недели и одна поездка в Самарканд: норма не должна
        // уехать, иначе все следующие недели выглядят провальными.
        let weeks = [100_000.0, 110_000, 120_000, 105_000, 900_000]
        XCTAssertEqual(WidgetWeek.median(weeks), 110_000, accuracy: 1)
        XCTAssertLessThan(WidgetWeek.median(weeks),
                          weeks.reduce(0, +) / Double(weeks.count),
                          "медиана обязана быть устойчивее среднего")
    }

    func testMedianOfEvenCountAveragesTheMiddle() {
        XCTAssertEqual(WidgetWeek.median([100, 200, 300, 400]), 250, accuracy: 0.001)
    }

    func testMedianIgnoresWeeksWithoutDriving() {
        XCTAssertEqual(WidgetWeek.median([0, 0, 120_000]), 120_000, accuracy: 1)
        XCTAssertEqual(WidgetWeek.median([]), 0, accuracy: 0.001)
    }

    func testRingDoesNotOverflowOnABigWeek() {
        // Полное кольцо значит «как обычно»; перепробег говорится словами, а
        // второй виток читался бы как ошибка отрисовки.
        XCTAssertEqual(WidgetWeek.usualWeekProgress(distance: 300_000, usual: 100_000), 1,
                       accuracy: 0.001)
        XCTAssertEqual(WidgetWeek.usualWeekProgress(distance: 50_000, usual: 100_000), 0.5,
                       accuracy: 0.001)
    }

    func testRingIsEmptyWhenThereIsNoNormYet() {
        XCTAssertEqual(WidgetWeek.usualWeekProgress(distance: 50_000, usual: 0), 0, accuracy: 0.001)
    }

    func testAverageCountsOnlyDaysWithDriving() {
        // Тот, кто ездит по будням, не должен видеть заниженную норму из-за
        // выходных: делим на дни с поездками, а не на семь.
        let week = [20_000.0, 20_000, 20_000, 20_000, 20_000, 0, 0]
        XCTAssertEqual(WidgetWeek.averagePerActiveDay(week), 20_000, accuracy: 1)
        XCTAssertEqual(WidgetWeek.averagePerActiveDay([0, 0, 0, 0, 0, 0, 0]), 0, accuracy: 0.001)
    }

    // MARK: - Контракт снимка

    func testDefaultSnapshotHasNoRatingAndSevenDays() {
        let snapshot = SharedDefaults.Snapshot()
        XCTAssertEqual(snapshot.weekRating, -1, "ноль здесь означал бы худшую езду, а не отсутствие поездок")
        XCTAssertNil(snapshot.weekStart)
        XCTAssertEqual(snapshot.dayDistances.count, 7)
        XCTAssertEqual(snapshot.dayOverspeed.count, 7)
    }
}
