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

    /// Те же цифры, свежий снимок — бюджет WidgetKit не тратим.
    func testUnchangedFreshSnapshotIsNotReloaded() {
        let old = snapshot(km: 42, updated: now.addingTimeInterval(-3600))
        XCTAssertFalse(WidgetWeek.needsRefresh(previous: old, next: snapshot(km: 42, updated: nil),
                                               now: now))
    }

    /// Другие цифры — перезагрузка сразу (конец поездки).
    func testChangedNumbersReload() {
        let old = snapshot(km: 42, updated: now.addingTimeInterval(-60))
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: old, next: snapshot(km: 43, updated: nil),
                                              now: now))
    }

    /// Неизменный снимок освежается раньше, чем виджет приглушит его как
    /// устаревший (24 ч).
    func testUnchangedSnapshotRefreshesBeforeItLooksStale() {
        let old = snapshot(km: 42, updated: now.addingTimeInterval(-13 * 3600))
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: old, next: snapshot(km: 42, updated: nil),
                                              now: now))
        XCTAssertLessThan(WidgetWeek.unchangedRefreshInterval, 24 * 3600)
    }

    /// Снимка ещё не было (или нет доступа к группе) — пишем.
    func testMissingPreviousSnapshotReloads() {
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: snapshot(km: 0, updated: nil),
                                              next: snapshot(km: 0, updated: nil), now: now))
        XCTAssertTrue(WidgetWeek.needsRefresh(previous: SharedDefaults.Snapshot(hasAccess: false),
                                              next: snapshot(km: 0, updated: nil), now: now))
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
        // Снимок станет «старым» раньше полуночи — проснуться тогда, чтобы
        // приглушить подпись.
        let snapshotAt = evening.addingTimeInterval(-WidgetWeek.staleAfter + 600)
        XCTAssertEqual(WidgetWeek.nextRefresh(after: evening, updatedAt: snapshotAt, calendar: calendar),
                       snapshotAt.addingTimeInterval(WidgetWeek.staleAfter + 60))
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
