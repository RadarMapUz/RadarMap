//
//  PeriodSummaryTests.swift
//  RadarMapTests
//
//  Сводка за период: цифры отчёта, дельта к прошлому периоду, маркеры карты
//  и главное — что трек за неделю переживает чистку истории.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class PeriodSummaryTests: XCTestCase {

    /// Фиксированное «сейчас»: тесты не должны зависеть от часов.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86400 }
    /// Календарь UTC: границы календарных периодов не должны зависеть от того,
    /// в какой зоне запускают тесты.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2   // неделя с понедельника
        return calendar
    }

    private func pass(_ id: Int, speed: Double, limit: Int?, at date: Date,
                      location: String = "Юнусабад") -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                     location: location, speedKmh: speed, date: date,
                     lat: 41.31 + Double(id) / 1000, lon: 69.28, limitKmh: limit)
    }

    private func record(daysAgo: Double, km: Double, minutes: Double = 30,
                        maxSpeed: Double = 80, passes: [PassedCamera] = [],
                        stops: [TripStop]? = nil, track: [Double]? = nil) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * day)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(minutes * 60),
                          distanceMeters: km * 1000, maxSpeedKmh: maxSpeed,
                          passed: passes, track: track, stops: stops)
    }

    // MARK: - Базовые цифры

    func testWeekSummaryCountsOnlyCurrentCalendarWeek() {
        // Календарная неделя, а не «последние 168 часов»: now — четверг 15.01.2027,
        // поэтому в окно попадают поездки не старше начала этой недели.
        let history = [record(daysAgo: 1, km: 10), record(daysAgo: 3, km: 20),
                       record(daysAgo: 10, km: 100)]
        let week = TripHistory.summary(history, period: .week, calendar: utc, now: now)
        XCTAssertEqual(week.trips, 2)
        XCTAssertEqual(week.distance, 30_000, accuracy: 1)
        // Месяц шире — в него попадают все три.
        let month = TripHistory.summary(history, period: .month, calendar: utc, now: now)
        XCTAssertEqual(month.trips, 3)
        XCTAssertEqual(month.distance, 130_000, accuracy: 1)
    }

    func testEmptyPeriodIsEmpty() {
        let summary = TripHistory.summary([record(daysAgo: 20, km: 50)],
                                          period: .week, now: now)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.trips, 0)
        XCTAssertNil(summary.distanceDeltaPercent)
    }

    /// Средняя за период — по времени в движении, стоянки склеенных поездок мимо.
    func testAverageSpeedUsesMovingTimeOnly() {
        let start = now.addingTimeInterval(-day)
        let stop = TripStop(id: UUID(), lat: 41.31, lon: 69.28,
                            from: start.addingTimeInterval(600),
                            to: start.addingTimeInterval(600 + 1800))   // 30 мин
        let history = [record(daysAgo: 1, km: 30, minutes: 60, stops: [stop])]
        let week = TripHistory.summary(history, period: .week, now: now)
        XCTAssertEqual(week.movingDuration, 1800, accuracy: 1)
        XCTAssertEqual(week.averageSpeedKmh, 60, accuracy: 0.5,
                       "30 км за 30 минут движения, а не за час с магазином")
    }

    func testMaxSpeedIsPeriodMaximum() {
        let history = [record(daysAgo: 1, km: 10, maxSpeed: 70),
                       record(daysAgo: 2, km: 10, maxSpeed: 118),
                       record(daysAgo: 20, km: 10, maxSpeed: 140)]
        XCTAssertEqual(TripHistory.summary(history, period: .week, now: now).maxSpeedKmh, 118)
    }

    // MARK: - Проезды и риск

    func testCleanAndOverPassesSplit() {
        let date = now.addingTimeInterval(-day)
        let history = [record(daysAgo: 1, km: 10, passes: [
            pass(1, speed: 58, limit: 60, at: date),          // в лимите
            pass(2, speed: 95, limit: 60, at: date),          // штрафуемое
            pass(3, speed: 200, limit: nil, at: date),        // лимит неизвестен — не судим
        ])]
        let week = TripHistory.summary(history, period: .week, now: now)
        XCTAssertEqual(week.cameras, 3, "камер пройдено считаем все")
        XCTAssertEqual(week.cleanPasses, 1)
        XCTAssertEqual(week.overPasses, 1)
        XCTAssertGreaterThan(week.fineRisk, 0)
        XCTAssertEqual(week.cleanShare, 0.5)
    }

    func testTopOverLocationIsMostFrequentViolation() {
        let date = now.addingTimeInterval(-day)
        let history = [record(daysAgo: 1, km: 10, passes: [
            pass(1, speed: 95, limit: 60, at: date, location: "Чиланзар"),
            pass(2, speed: 95, limit: 60, at: date, location: "Юнусабад"),
            pass(3, speed: 95, limit: 60, at: date, location: "Юнусабад"),
        ])]
        XCTAssertEqual(TripHistory.summary(history, period: .week, now: now).topOverLocation,
                       "Юнусабад")
    }

    // MARK: - Дельта и активный день

    func testDeltaComparesWithPreviousWindow() {
        // Эта неделя 100 км, прошлая 50 км → +100%.
        let history = [record(daysAgo: 1, km: 100), record(daysAgo: 9, km: 50)]
        let week = TripHistory.summary(history, period: .week, now: now)
        XCTAssertEqual(week.previousDistance, 50_000, accuracy: 1)
        XCTAssertEqual(week.distanceDeltaPercent, 100)
    }

    func testDeltaIsNilWithoutPreviousData() {
        let week = TripHistory.summary([record(daysAgo: 1, km: 100)],
                                        period: .week, now: now)
        XCTAssertNil(week.distanceDeltaPercent, "первую неделю сравнивать не с чем")
    }

    func testBusiestDay() {
        let history = [record(daysAgo: 1, km: 10), record(daysAgo: 2, km: 40),
                       record(daysAgo: 2, km: 30)]
        let week = TripHistory.summary(history, period: .week, now: now)
        XCTAssertEqual(week.busiestDayKm, 70, accuracy: 0.1, "два выезда одного дня складываются")
    }

    // MARK: - График по дням

    func testDailyKmHasFixedLengthAndIncludesZeroDays() {
        let daily = TripHistory.dailyKm([record(daysAgo: 2, km: 15)], days: 7, now: now)
        XCTAssertEqual(daily.count, 7)
        XCTAssertEqual(daily.map(\.km).reduce(0, +), 15, accuracy: 0.1)
        XCTAssertEqual(daily.filter { $0.km == 0 }.count, 6, "пустые дни не выпадают из графика")
        XCTAssertTrue(daily[0].day < daily[6].day, "от старых к новым — как рисуется график")
    }

    /// Красный столбик графика: день помечается по штрафуемому превышению, а не
    /// по любому проезду камеры и не по превышению без известного лимита.
    func testDailyKmFlagsDaysWithFinableOverspeed() {
        let overDay = now.addingTimeInterval(-2 * day)
        let cleanDay = now.addingTimeInterval(-1 * day)
        let history = [
            record(daysAgo: 1, km: 10, passes: [pass(1, speed: 58, limit: 60, at: cleanDay)]),
            record(daysAgo: 2, km: 12, passes: [pass(2, speed: 95, limit: 60, at: overDay),
                                                pass(3, speed: 61, limit: 60, at: overDay)]),
            record(daysAgo: 3, km: 8, passes: [pass(4, speed: 140, limit: nil, at: now)]),
        ]
        let daily = TripHistory.dailyKm(history, days: 7, now: now)

        XCTAssertEqual(daily.filter(\.hasOverspeed).count, 1, "красный только день превышения")
        XCTAssertEqual(daily[4].overPasses, 1,
                       "+1 км/ч в допуске (5) штрафа не даёт — этот проезд не считается")
        XCTAssertFalse(daily[3].hasOverspeed, "без известного лимита нарушений не выдумываем")
        XCTAssertFalse(daily[5].hasOverspeed, "58 при лимите 60 — чистый день")
    }

    // MARK: - Список поездок подчиняется фильтру

    func testHistoryListFollowsPeriod() {
        let history = [record(daysAgo: 1, km: 10), record(daysAgo: 3, km: 20),
                       record(daysAgo: 10, km: 30), record(daysAgo: 40, km: 40)]
        XCTAssertEqual(TripHistory.historyList(history, period: .week,
                                               anchor: now, calendar: utc).count, 2)
        XCTAssertEqual(TripHistory.historyList(history, period: .month,
                                               anchor: now, calendar: utc).count, 3)
        // День — только сегодняшние: список подчиняется тому же окну, что цифры.
        XCTAssertEqual(TripHistory.historyList(history, period: .day,
                                               anchor: now, calendar: utc).count, 0)
    }

    /// Листание назад показывает именно прошлое окно, а не «последние N дней».
    func testAnchorSelectsPastWindow() {
        let history = [record(daysAgo: 1, km: 10), record(daysAgo: 10, km: 30)]
        let previousWeek = StatsPeriod.week.shifted(now, by: -1, calendar: utc)
        let list = TripHistory.historyList(history, period: .week,
                                           anchor: previousWeek, calendar: utc)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.distanceMeters ?? 0, 30_000, accuracy: 1)
    }

    // MARK: - Дни за рулём

    func testActiveDaysCountsCalendarDaysNotTrips() {
        let history = [record(daysAgo: 1, km: 10), record(daysAgo: 1, km: 5),
                       record(daysAgo: 4, km: 20)]
        let week = TripHistory.summary(history, period: .week, now: now)
        XCTAssertEqual(week.trips, 3)
        XCTAssertEqual(week.activeDays, 2, "два выезда одного дня — один день за рулём")
    }

    func testActiveDaysIsZeroWithoutTrips() {
        XCTAssertEqual(TripHistory.summary([], period: .week, now: now).activeDays, 0)
    }

    // MARK: - Маркеры карты

    func testPassMarkersGroupByCameraAndFlagViolations() {
        let d1 = now.addingTimeInterval(-day)
        let d2 = now.addingTimeInterval(-2 * day)
        let history = [
            record(daysAgo: 1, km: 10, passes: [pass(7, speed: 95, limit: 60, at: d1)]),
            record(daysAgo: 2, km: 10, passes: [pass(7, speed: 55, limit: 60, at: d2),
                                                pass(8, speed: 55, limit: 60, at: d2)]),
        ]
        let markers = TripHistory.passMarkers(history, period: .week, anchor: now, calendar: utc)
        XCTAssertEqual(markers.count, 2)
        let seven = markers.first { $0.cameraID == 7 }
        XCTAssertEqual(seven?.times, 2, "одна камера — один маркер, проезды складываются")
        XCTAssertEqual(seven?.overTimes, 1)
        XCTAssertEqual(seven?.hasViolation, true)
        XCTAssertEqual(markers.first { $0.cameraID == 8 }?.hasViolation, false)
        XCTAssertEqual(markers.first?.cameraID, 7, "сортировка по числу проездов")
    }

    func testPassMarkersSkipPassesWithoutCoordinates() {
        var noCoords = pass(1, speed: 55, limit: 60, at: now.addingTimeInterval(-day))
        noCoords.lat = nil
        noCoords.lon = nil
        let markers = TripHistory.passMarkers([record(daysAgo: 1, km: 10, passes: [noCoords])],
                                              period: .week, anchor: now, calendar: utc)
        XCTAssertTrue(markers.isEmpty, "старые записи без координат на карту не поставить")
    }

    // MARK: - Чистка истории не должна ломать карту недели

    /// Регресс, из-за которого карта недели врала бы: pruned выбрасывал трек у
    /// всех записей, кроме семи последних, а активная неделя — это легко 15 поездок.
    func testPrunedKeepsTracksForEveryTripOfTheLastWeek() {
        let track: [Double] = [41.31, 69.28, 50, 41.32, 69.28, 50]
        // 15 поездок за последние 5 дней — больше, чем visibleHistory.
        let history = (0..<15).map { i in
            record(daysAgo: Double(i) * 0.3, km: 10, track: track)
        }
        let pruned = TripHistory.pruned(history, now: now)
        XCTAssertEqual(pruned.count, 15)
        XCTAssertEqual(pruned.filter { $0.track != nil }.count, 15,
                       "все треки недели должны выжить — иначе карта отчёта неполная")
        XCTAssertEqual(TripHistory.tracks(pruned, period: .week, anchor: now, calendar: utc).count, 15)
    }

    func testPrunedStripsTracksOlderThanWeekButKeepsNumbers() {
        let track: [Double] = [41.31, 69.28, 50, 41.32, 69.28, 50]
        // Свежие семь + старые: у старых трек не нужен, цифры нужны.
        let recent = (0..<7).map { i in record(daysAgo: Double(i) * 0.5, km: 10, track: track) }
        let old = (0..<5).map { i in record(daysAgo: 12 + Double(i), km: 10, track: track) }
        let pruned = TripHistory.pruned(recent + old, now: now)
        XCTAssertEqual(pruned.count, 12, "записи за 30 дней остаются в истории")
        XCTAssertEqual(pruned.prefix(7).filter { $0.track != nil }.count, 7)
        XCTAssertEqual(pruned.suffix(5).filter { $0.track == nil }.count, 5,
                       "трек старше недели выброшен")
        // Месяц теперь КАЛЕНДАРНЫЙ: часть старых записей уезжает в прошлый
        // месяц — считаем ожидание по тем же границам, а не «последние 30 дней».
        let january = StatsPeriod.month.interval(containing: now, calendar: utc)
        let inMonth = pruned.filter { january.contains($0.startedAt) }.count
        XCTAssertEqual(TripHistory.summary(pruned, period: .month, calendar: utc, now: now).trips,
                       inMonth, "цифры месяца не пострадали")
    }

    func testPrunedDropsRecordsOlderThanMonth() {
        let history = (0..<10).map { i in record(daysAgo: 40 + Double(i), km: 10) }
        let pruned = TripHistory.pruned(history, now: now)
        XCTAssertEqual(pruned.count, TripHistory.visibleHistory,
                       "старше 30 дней держим только видимый список")
    }
}
