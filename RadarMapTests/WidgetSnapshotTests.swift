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

    // MARK: - Состояния

    private func snapshot(trips: Int, days: [Double], usual: Double = 0,
                          access: Bool = true) -> SharedDefaults.Snapshot {
        SharedDefaults.Snapshot(weekStart: thisWeekStart,
                                weekDistance: days.reduce(0, +), weekTrips: trips,
                                dayDistances: days, usualWeekDistance: usual,
                                updatedAt: now, hasAccess: access)
    }

    func testNoAccessIsNotConfusedWithNoTrips() {
        // Самая дорогая ошибка виджета: «мне не дали данные» выглядело как
        // «вы не ездили», и человек шёл искать поездки вместо подписи.
        let blocked = snapshot(trips: 0, days: [0, 0, 0, 0, 0, 0, 0], access: false)
        XCTAssertEqual(WidgetWeek.state(blocked), .noAccess)
        XCTAssertEqual(WidgetWeek.state(snapshot(trips: 0, days: [0, 0, 0, 0, 0, 0, 0])), .empty)
    }

    func testOneDayIsFewNotFull() {
        // Один столбик и шесть прочерков — это не форма недели, а её отсутствие.
        let s = snapshot(trips: 1, days: [12_400, 0, 0, 0, 0, 0, 0], usual: 100_000)
        XCTAssertEqual(WidgetWeek.state(s), .few)
    }

    func testWeekWithoutNormIsFewEvenWithManyDays() {
        // Норма ещё не накопилась — сравнивать не с чем, значит ни кольца,
        // ни «в среднем» показывать нельзя.
        let s = snapshot(trips: 5, days: [10_000, 12_000, 8_000, 0, 0, 0, 0])
        XCTAssertEqual(WidgetWeek.state(s), .few)
    }

    func testTwoDaysWithNormIsFull() {
        let s = snapshot(trips: 3, days: [10_000, 12_000, 0, 0, 0, 0, 0], usual: 100_000)
        XCTAssertEqual(WidgetWeek.state(s), .full)
    }

    func testSingleDayIsNotPaintedRed() {
        // Единственный ездовой день красным превращает виджет в аварийный щит.
        XCTAssertFalse(WidgetWeek.marksOverspeedDays([12_400, 0, 0, 0, 0, 0, 0]))
        XCTAssertTrue(WidgetWeek.marksOverspeedDays([12_400, 8_000, 0, 0, 0, 0, 0]))
    }

    /// Столбики — с двух ездовых дней, даже без нормы: первая неделя после
    /// установки — это `.few` все семь дней, а форма недели уже есть.
    func testBarsShowFromTheSecondDrivingDayEvenWithoutANorm() {
        let week = SharedDefaults.Snapshot(weekStart: thisWeekStart, weekDistance: 30_000, weekTrips: 4,
                                           dayDistances: [10_000, 12_000, 8_000, 0, 0, 0, 0],
                                           updatedAt: now)
        XCTAssertEqual(WidgetWeek.state(week), .few, "нормы нет — состояние «мало данных»")
        XCTAssertTrue(WidgetWeek.showsBars(week.dayDistances))
        XCTAssertFalse(WidgetWeek.showsBars([12_400, 0, 0, 0, 0, 0, 0]))
    }

    func testLifetimeTileHiddenWhileItRepeatsTheMonth() {
        // У нового пользователя пожизненный счёт начался с установки: «всего»
        // равно месяцу и занимает место, ничего не добавляя.
        XCTAssertFalse(WidgetWeek.showsLifetime(month: 12_400, lifetime: 12_400))
        XCTAssertTrue(WidgetWeek.showsLifetime(month: 486_000, lifetime: 12_400_000))
    }

    func testActiveDayCount() {
        XCTAssertEqual(WidgetWeek.activeDayCount([1, 0, 2, 0, 0, 3, 0]), 3)
        XCTAssertEqual(WidgetWeek.activeDayCount([]), 0)
    }

    // MARK: - Контракт снимка

    func testDefaultSnapshotHasNoRatingAndSevenDays() {
        let snapshot = SharedDefaults.Snapshot()
        XCTAssertEqual(snapshot.weekRating, -1, "ноль здесь означал бы худшую езду, а не отсутствие поездок")
        XCTAssertNil(snapshot.weekStart)
        XCTAssertEqual(snapshot.dayDistances.count, 7)
        XCTAssertEqual(snapshot.dayOverspeed.count, 7)
    }

    // MARK: - Перезагрузка только по делу (аудит 11.10)

    private func snapshot(km: Double, updated: Date?) -> SharedDefaults.Snapshot {
        var s = SharedDefaults.Snapshot()
        s.weekDistance = km * 1000
        s.updatedAt = updated
        return s
    }

    /// Те же цифры — бюджет WidgetKit не тратим, сколько бы времени ни прошло.
    func testUnchangedSnapshotIsNotReloaded() {
        let old = snapshot(km: 42, updated: now.addingTimeInterval(-3 * 86400))
        XCTAssertFalse(WidgetWeek.needsRefresh(previous: old, next: snapshot(km: 42, updated: nil)))
    }

    /// Другие цифры — перезагрузка сразу (конец поездки).
    func testChangedNumbersReload() {
        let old = snapshot(km: 42, updated: now.addingTimeInterval(-60))
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: old, next: snapshot(km: 43, updated: nil)))
    }

    /// Снимка ещё не было (или нет доступа к группе) — пишем.
    func testMissingPreviousSnapshotReloads() {
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: snapshot(km: 0, updated: nil),
                                              next: snapshot(km: 0, updated: nil)))
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: SharedDefaults.Snapshot(hasAccess: false),
                                              next: snapshot(km: 0, updated: nil)))
    }

    /// Виджет сам просыпается раз в сутки — сразу после полуночи (смена дня
    /// и недели), а не каждый час (аудит энергии 19.10).
    func testWidgetWakesOnceADayRightAfterMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 30))!
        let next = WidgetWeek.nextRefresh(after: evening, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 0, minute: 1)))
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 0, minute: 0, second: 30))!
        XCTAssertEqual(WidgetWeek.nextRefresh(after: morning, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 1)))
    }

    // MARK: - Честные состояния (план 09.11)

    private func newWeek(history: Bool) -> SharedDefaults.Snapshot {
        var value = snapshot(trips: 0, days: [0, 0, 0, 0, 0, 0, 0])
        if history {
            value.previousWeekDistance = 165_000
            value.previousWeekRating = 72
            value.lifetimeDistance = 12_400_000
        }
        return value
    }

    /// Понедельник у водителя с годом поездок — не первый день в приложении.
    func testNewWeekWithHistoryIsNotAFirstRun() {
        XCTAssertEqual(WidgetWeek.state(newWeek(history: true)), .newWeek)
        XCTAssertEqual(WidgetWeek.state(newWeek(history: false)), .empty)
        var lastTripOnly = newWeek(history: false)
        lastTripOnly.lastTripAt = now.addingTimeInterval(-86400)
        XCTAssertEqual(WidgetWeek.state(lastTripOnly), .newWeek)
    }

    /// Идущая неделя не «меньше обычного»: она просто не кончилась.
    func testUsualLineNeverCallsARunningWeekBehind() {
        XCTAssertEqual(WidgetWeek.usualLine(distance: 118_000, usual: 165_000), .ofUsual(165_000))
        XCTAssertEqual(WidgetWeek.usualLine(distance: 160_000, usual: 165_000), .asUsual)
        XCTAssertEqual(WidgetWeek.usualLine(distance: 200_000, usual: 165_000), .above(percent: 21))
        XCTAssertEqual(WidgetWeek.usualLine(distance: 0, usual: 165_000), .none)
        XCTAssertEqual(WidgetWeek.usualLine(distance: 50_000, usual: 0), .none, "нормы нет")
    }

    func testDaysAgoIsCalendarDays() {
        let lateEvening = thisWeekStart.addingTimeInterval(4 * 86400 + 23 * 3600)   // пятница 23:00
        let earlyMorning = thisWeekStart.addingTimeInterval(4 * 86400 + 6 * 3600)
        XCTAssertEqual(WidgetWeek.daysAgo(earlyMorning, now: lateEvening, calendar: calendar), 0)
        XCTAssertEqual(WidgetWeek.daysAgo(lateEvening.addingTimeInterval(-86400), now: earlyMorning, calendar: calendar), 1,
                       "вчера вечером — это вчера, хоть и меньше суток назад")
    }

    func testDayRingsKeepSevenDaysAndAreHonest() {
        var value = snapshot(trips: 3, days: [20_000, 0, 30_000, 0, 0, 0, 0], usual: 100_000)
        value.dayScores = [80, -1, 40, -1, -1, -1, -1]
        value.dayRoad = [0.5, 0, 1.4, 0, 0, 0, 0]
        value.dayOverspeed = [false, false, true, false, false, false, false]
        value.dayPerfect = [true, false, false, false, false, false, false]
        let rings = WidgetWeek.dayRings(value)
        XCTAssertEqual(rings.count, 7)
        XCTAssertEqual(rings[0], .init(score: 80, road: 0.5, fine: false, perfect: true))
        XCTAssertNil(rings[1], "день без поездок — пустое кольцо, а не ноль")
        XCTAssertEqual(rings[2], .init(score: 40, road: 1, fine: true, perfect: false), "доля не больше одного круга")
        value.dayDistances = [20_000, 0, 0, 0, 0, 0, 0]
        value.dayOverspeed = [true, false, false, false, false, false, false]
        XCTAssertEqual(WidgetWeek.dayRings(value)[0]?.fine, false, "единственный день красным не красим")
    }

    func testDayDotsMarkTodayOnlyWhenDriven() {
        let dots = WidgetWeek.dayDots([20_000, 0, 30_000, 0, 0, 0, 0], today: 2)
        XCTAssertEqual(dots, [.driven, .none, .today, .none, .none, .none, .none])
        XCTAssertEqual(WidgetWeek.dayDots([20_000, 0, 0, 0, 0, 0, 0], today: 2)[2], .none)
    }

    func testSplitNeedsBothHalves() {
        var value = snapshot(trips: 5, days: [118_000, 0, 0, 0, 0, 0, 0], usual: 100_000)
        value.weekCommuteDistance = 73_000
        let split = WidgetWeek.split(value)
        XCTAssertEqual(split, .init(commute: 73_000, other: 45_000))
        XCTAssertEqual(split?.commuteShare ?? 0, 73.0 / 118, accuracy: 0.001)
        value.weekCommuteDistance = 118_000
        XCTAssertNil(WidgetWeek.split(value), "всё — дорога: сравнивать не с чем")
        value.weekCommuteDistance = 0
        XCTAssertNil(WidgetWeek.split(value))
    }

    /// Снимок читает и пишет числа: ни координат, ни адресов в нём нет.
    func testSnapshotCarriesNoCoordinates() {
        let names = Mirror(reflecting: SharedDefaults.Snapshot()).children.compactMap(\.label)
        for name in names {
            let lower = name.lowercased()
            XCTAssertFalse(lower.contains("lat") || lower.contains("lon") || lower.contains("coord")
                           || lower.contains("address"), name)
        }
    }

    // MARK: - Процент к прошлой неделе (31E)

    /// Одно правило с «Итогами»: идущая неделя процента не получает, крошечная
    /// прошлая и «в разы» — тоже; сопоставимые целые недели — да.
    func testDeltaPercentFollowsTheItogiRule() {
        XCTAssertNil(WidgetWeek.comparablePercent(distance: 40_000, previous: 100_000, periodComplete: false),
                     "среда против целой недели — «−60 %»")
        XCTAssertNil(WidgetWeek.comparablePercent(distance: 25_000, previous: 9_000, periodComplete: true),
                     "«+178 %» от девяти километров")
        XCTAssertNil(WidgetWeek.comparablePercent(distance: 350_000, previous: 100_000, periodComplete: true))
        XCTAssertEqual(WidgetWeek.comparablePercent(distance: 120_000, previous: 100_000, periodComplete: true), 20)
        var summary = PeriodSummary()
        summary.distance = 120_000
        summary.previousDistance = 100_000
        summary.periodComplete = true
        XCTAssertEqual(summary.distanceChange?.percent,
                       WidgetWeek.comparablePercent(distance: 120_000, previous: 100_000, periodComplete: true),
                       "виджет и «Итоги» разошлись в правиле")
    }
}
