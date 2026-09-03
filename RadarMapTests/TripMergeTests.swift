//
//  TripMergeTests.swift
//  RadarMapTests
//
//  Склейка поездок: заезд по пути — та же поездка, приезд домой — новая.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class TripMergeTests: XCTestCase {

    /// Типичный заезд: автостоп, стоим у случайного места, поездка была получасовая.
    private func context(stop: TimeInterval = 5 * 60,
                         meters: CLLocationDistance = 20,
                         manual: Bool = false,
                         nearSaved: Bool = false,
                         crossesDay: Bool = false,
                         stops: Int = 0,
                         previous: TimeInterval = 30 * 60) -> TripMerge.Context {
        TripMerge.Context(stopDuration: stop, metersFromPreviousEnd: meters,
                          endedManually: manual, stopNearSavedPlace: nearSaved,
                          crossesDay: crossesDay, existingStops: stops,
                          previousDuration: previous)
    }

    // MARK: - Склеиваем

    func testShortStopIsMerged() {
        XCTAssertTrue(TripMerge.shouldMerge(context(stop: 6 * 60)),
                      "шесть минут в магазине — та же поездка")
    }

    func testVeryShortStopNearHomeIsStillMerged() {
        // Забрал человека у дома и поехал дальше: короткая пауза сильнее места.
        XCTAssertTrue(TripMerge.shouldMerge(context(stop: 3 * 60, nearSaved: true)))
    }

    /// Ровно тот кейс, ради которого окно расширили с 10 минут до часа.
    func testHalfHourAtRandomPlaceIsMerged() {
        XCTAssertTrue(TripMerge.shouldMerge(context(stop: 35 * 60)),
                      "полчаса в случайном месте по пути — обед, поездка продолжается")
    }

    // MARK: - Не склеиваем

    func testManualEndIsNeverMerged() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 60, manual: true)),
                       "нажал «Завершить» — намерение сильнее любой геометрии")
    }

    func testStartFarFromPreviousEndIsNewTrip() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 60, meters: 900)),
                       "телефон приехал сюда не за рулём этой машины")
    }

    func testHalfHourAtHomeIsNewTrip() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 35 * 60, nearSaved: true)),
                       "полчаса у дома — приехал, дело сделано")
    }

    func testStopLongerThanHourIsNewTrip() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 75 * 60)))
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 75 * 60, nearSaved: false)),
                       "больше часа — новая поездка независимо от места")
    }

    func testCrossingMidnightIsNewTrip() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 60, crossesDay: true)))
    }

    func testTooManyStopsStopsMerging() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 60, stops: AppConfig.tripMergeMaxStops)),
                       "не даём поездке стать «весь день катался»")
    }

    func testTooLongTotalStopsMerging() {
        XCTAssertFalse(TripMerge.shouldMerge(context(stop: 60, previous: 13 * 3600)))
    }

    // MARK: - Близость к сохранённым местам

    func testIsNearSavedPlace() {
        let home = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let atHome = GeoMath.destination(from: home, bearing: 0, distanceMeters: 80)
        let away = GeoMath.destination(from: home, bearing: 0, distanceMeters: 900)
        XCTAssertTrue(TripMerge.isNearSavedPlace(atHome, places: [home]))
        XCTAssertFalse(TripMerge.isNearSavedPlace(away, places: [home]))
        XCTAssertFalse(TripMerge.isNearSavedPlace(atHome, places: []),
                       "мест не сохранено — «рядом с домом» неоткуда взяться")
    }

    // MARK: - Время в движении

    func testMovingDurationExcludesStops() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = TripStop(id: UUID(), lat: 41.31, lon: 69.28,
                            from: start.addingTimeInterval(600),
                            to: start.addingTimeInterval(600 + 1200))   // 20 мин стоянки
        let record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(3600),
                                distanceMeters: 20_000, maxSpeedKmh: 90, passed: [],
                                stops: [stop])
        XCTAssertEqual(record.duration, 3600, accuracy: 1, "по часам поездка заняла час")
        XCTAssertEqual(record.stoppedDuration, 1200, accuracy: 1)
        XCTAssertEqual(record.movingDuration, 2400, accuracy: 1)
        // 20 км за 40 минут движения = 30 км/ч, а не 20 как было бы по общему времени.
        XCTAssertEqual(record.averageSpeedKmh, 30, accuracy: 0.5)
    }

    func testMovingDurationEqualsDurationWithoutStops() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(1800),
                                distanceMeters: 15_000, maxSpeedKmh: 80, passed: [])
        XCTAssertEqual(record.movingDuration, record.duration, accuracy: 0.001)
        XCTAssertEqual(record.averageSpeedKmh, 30, accuracy: 0.5)
    }

    // MARK: - Ручное разделение

    func testSplitProducesTwoLegsAndKeepsTotals() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Прямой трек на север, точка каждые ~100 м.
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let points = (0..<11).map { i -> Double in Double(i) }.flatMap { i -> [Double] in
            let p = GeoMath.destination(from: base, bearing: 0, distanceMeters: i * 100)
            return [p.latitude, p.longitude, 50]
        }
        let stopAt = GeoMath.destination(from: base, bearing: 0, distanceMeters: 500)
        let stop = TripStop(id: UUID(), lat: stopAt.latitude, lon: stopAt.longitude,
                            from: start.addingTimeInterval(600),
                            to: start.addingTimeInterval(1200))
        let passBefore = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                                      location: "до", speedKmh: 55,
                                      date: start.addingTimeInterval(300), limitKmh: 60)
        let passAfter = PassedCamera(id: UUID(), cameraID: 2, typeRaw: "Стационар радар",
                                     location: "после", speedKmh: 70,
                                     date: start.addingTimeInterval(1500), limitKmh: 60)
        let record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(2000),
                                distanceMeters: 1000, maxSpeedKmh: 60,
                                passed: [passBefore, passAfter],
                                track: points, stops: [stop])

        let legs = TripHistory.split(record, at: stop)
        XCTAssertEqual(legs.count, 2)
        // История идёт от новых к старым: сначала вторая нога.
        let (second, first) = (legs[0], legs[1])
        XCTAssertEqual(first.startedAt, record.startedAt)
        XCTAssertEqual(second.endedAt, record.endedAt)
        XCTAssertEqual(first.distanceMeters + second.distanceMeters,
                       record.distanceMeters, accuracy: 1,
                       "сумма дистанций не должна разъезжаться с накопленной по GPS")
        XCTAssertEqual(first.passed.map(\.cameraID), [1])
        XCTAssertEqual(second.passed.map(\.cameraID), [2])
        XCTAssertNil(first.stops, "остановка была одна — после разделения её нет")
        XCTAssertNil(second.stops)
    }

    func testSplitOfTooShortTrackIsNoop() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = TripStop(id: UUID(), lat: 41.31, lon: 69.28,
                            from: start, to: start.addingTimeInterval(60))
        let record = TripRecord(id: 1, startedAt: start, endedAt: start.addingTimeInterval(600),
                                distanceMeters: 500, maxSpeedKmh: 40, passed: [],
                                track: [41.31, 69.28, 40], stops: [stop])
        XCTAssertEqual(TripHistory.split(record, at: stop).count, 1,
                       "делить нечего — возвращаем запись как есть")
    }

    /// Расход заряда при разделении делится, а не теряется.
    ///
    /// `TripMerge.merged` при склейке расходы СКЛАДЫВАЕТ, значит разделение
    /// обязано быть обратной операцией — иначе «разделить и снова объединить»
    /// стирает честно измеренную цифру. Делим по времени, а не по километрам:
    /// батарея садится за часы, а в пробке километров нет вообще.
    func testSplitDividesBatteryDropExactly() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let points = (0..<11).map { Double($0) }.flatMap { i -> [Double] in
            let p = GeoMath.destination(from: base, bearing: 0, distanceMeters: i * 100)
            return [p.latitude, p.longitude, 50]
        }
        let stopAt = GeoMath.destination(from: base, bearing: 0, distanceMeters: 500)
        // Едем 600 с, стоим 600 с, едем ещё 800 с — доля первой ноги 600/1400.
        let stop = TripStop(id: UUID(), lat: stopAt.latitude, lon: stopAt.longitude,
                            from: start.addingTimeInterval(600),
                            to: start.addingTimeInterval(1200))
        let record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(2000),
                                distanceMeters: 1000, maxSpeedKmh: 60, passed: [],
                                track: points, stops: [stop],
                                batteryDropPercent: 10)

        let legs = TripHistory.split(record, at: stop)
        XCTAssertEqual(legs.count, 2)
        let (second, first) = (legs[0], legs[1])
        let head = try? XCTUnwrap(first.batteryDropPercent)
        let tail = try? XCTUnwrap(second.batteryDropPercent)
        XCTAssertNotNil(head, "первая нога потеряла расход заряда")
        XCTAssertNotNil(tail, "вторая нога потеряла расход заряда")
        XCTAssertEqual((head ?? 0) + (tail ?? 0), 10,
                       "сумма половин обязана равняться исходной цифре ровно")
        XCTAssertLessThan(head ?? 0, tail ?? 0,
                          "первая нога короче по времени — и доля у неё меньше")
    }

    /// Неизвестный расход остаётся неизвестным у обеих ног: «−0 %» за поездку,
    /// стоившую пять, хуже, чем промолчать (та же логика, что у mergedBatteryDrop).
    func testSplitKeepsUnknownBatteryDropUnknown() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let points = (0..<11).map { Double($0) }.flatMap { i -> [Double] in
            let p = GeoMath.destination(from: base, bearing: 0, distanceMeters: i * 100)
            return [p.latitude, p.longitude, 50]
        }
        let stopAt = GeoMath.destination(from: base, bearing: 0, distanceMeters: 500)
        let stop = TripStop(id: UUID(), lat: stopAt.latitude, lon: stopAt.longitude,
                            from: start.addingTimeInterval(600),
                            to: start.addingTimeInterval(1200))
        let record = TripRecord(id: 1, startedAt: start,
                                endedAt: start.addingTimeInterval(2000),
                                distanceMeters: 1000, maxSpeedKmh: 60, passed: [],
                                track: points, stops: [stop])

        for leg in TripHistory.split(record, at: stop) {
            XCTAssertNil(leg.batteryDropPercent)
        }
    }

    /// Ретро-чистка выбрасывает ложные проезды камер — и НЕ должна попутно
    /// стирать расход заряда: поле с дефолтом nil, а запись пересобиралась
    /// вручную по полям, поэтому цифра исчезала при обновлении приложения.
    func testSanitizeKeepsBatteryDrop() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let points = (0..<11).map { Double($0) }.flatMap { i -> [Double] in
            let p = GeoMath.destination(from: base, bearing: 0, distanceMeters: i * 100)
            return [p.latitude, p.longitude, 50]
        }
        // Камера в пяти километрах в сторону: трек к ней не подходил, значит
        // это ложный проезд и чистка обязана его убрать.
        let far = GeoMath.destination(from: base, bearing: 90, distanceMeters: 5000)
        let ghost = PassedCamera(id: UUID(), cameraID: 9, typeRaw: "Стационар радар",
                                 location: "мимо", speedKmh: 80,
                                 date: start.addingTimeInterval(300),
                                 lat: far.latitude, lon: far.longitude, limitKmh: 60)
        let record = TripRecord(id: 1, startedAt: start,
                                endedAt: start.addingTimeInterval(2000),
                                distanceMeters: 1000, maxSpeedKmh: 80, passed: [ghost],
                                track: points, batteryDropPercent: 7)

        let (cleaned, changed) = TripHistory.sanitized([record])
        XCTAssertTrue(changed, "ложный проезд обязан быть убран — иначе тест не о том")
        XCTAssertEqual(cleaned.first?.passed.count, 0)
        XCTAssertEqual(cleaned.first?.batteryDropPercent, 7,
                       "чистка проездов стёрла расход заряда")
    }

    // MARK: - Ручное объединение записей

    private let base = Date(timeIntervalSince1970: 1_800_000_000)   // 08:00 UTC
    private let origin = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Запись с прямым треком на север от `from` — конец трека и endLat совпадают.
    private func record(start: Date, minutes: Double, km: Double,
                        from: CLLocationCoordinate2D, manual: Bool = false,
                        battery: Int? = nil, passes: [PassedCamera] = []) -> TripRecord {
        let points = stride(from: 0.0, through: km * 1000, by: 200).flatMap { meters -> [Double] in
            let p = GeoMath.destination(from: from, bearing: 0, distanceMeters: meters)
            return [p.latitude, p.longitude, 55]
        }
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(minutes * 60),
                          distanceMeters: km * 1000, maxSpeedKmh: 80,
                          passed: passes,
                          endLat: points[points.count - 3], endLon: points[points.count - 2],
                          track: points, score: 90,
                          endedManually: manual, batteryDropPercent: battery)
    }

    private func mergePass(_ id: Int, speed: Double, at date: Date) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар",
                     location: "Юнусабад", speedKmh: speed, date: date,
                     lat: 41.32, lon: 69.28, limitKmh: 60)
    }

    func testManualMergeAllowedForAdjacentSameDayPair() {
        let previous = record(start: base, minutes: 30, km: 6, from: origin, manual: true)
        let next = record(start: base.addingTimeInterval(50 * 60), minutes: 15, km: 4,
                          from: previous.endCoordinate!)
        XCTAssertTrue(TripMerge.manualMergeAllowed(previous: previous, next: next,
                                                   calendar: utc),
                      "20 минут стоянки на месте финиша — объединять можно")
    }

    func testManualMergeRefusesLongGapAndMidnight() {
        let previous = record(start: base, minutes: 30, km: 6, from: origin, manual: true)
        let late = record(start: base.addingTimeInterval((30 + 90) * 60), minutes: 15,
                          km: 4, from: previous.endCoordinate!)
        XCTAssertFalse(TripMerge.manualMergeAllowed(previous: previous, next: late,
                                                    calendar: utc),
                       "полтора часа — новая поездка, как и у автосклейки")

        // 23:30 → 00:10: пауза короткая, но календарный день уже другой.
        let evening = record(start: base.addingTimeInterval(15 * 3600), minutes: 30,
                             km: 6, from: origin, manual: true)
        let pastMidnight = record(start: evening.endedAt.addingTimeInterval(40 * 60),
                                  minutes: 15, km: 4, from: evening.endCoordinate!)
        XCTAssertFalse(TripMerge.manualMergeAllowed(previous: evening, next: pastMidnight,
                                                    calendar: utc))
    }

    func testManualMergeRefusesFarStart() {
        let previous = record(start: base, minutes: 30, km: 6, from: origin, manual: true)
        let farPoint = GeoMath.destination(from: previous.endCoordinate!,
                                           bearing: 90, distanceMeters: 900)
        let far = record(start: base.addingTimeInterval(45 * 60), minutes: 15, km: 4,
                         from: farPoint)
        XCTAssertFalse(TripMerge.manualMergeAllowed(previous: previous, next: far,
                                                    calendar: utc),
                       "старт в 900 м от финиша — телефон приехал туда не этой машиной")
    }

    func testMergedKeepsTotalsAndGapBecomesStop() {
        let passA = mergePass(1, speed: 55, at: base.addingTimeInterval(10 * 60))
        let previous = record(start: base, minutes: 30, km: 6, from: origin,
                              manual: true, battery: 3, passes: [passA])
        let passB = mergePass(2, speed: 88, at: base.addingTimeInterval(55 * 60))
        let next = record(start: base.addingTimeInterval(50 * 60), minutes: 15, km: 4,
                          from: previous.endCoordinate!, battery: 2, passes: [passB])

        let merged = TripMerge.merged(previous: previous, next: next)
        XCTAssertEqual(merged.id, previous.id, "id остаётся старым — как у resume()")
        XCTAssertEqual(merged.startedAt, previous.startedAt)
        XCTAssertEqual(merged.endedAt, next.endedAt)
        XCTAssertEqual(merged.distanceMeters, 10_000, accuracy: 0.1)
        XCTAssertEqual(merged.maxSpeedKmh, 80, accuracy: 0.1)
        XCTAssertEqual(merged.passed.map(\.cameraID), [1, 2])
        XCTAssertEqual(merged.endLat!, next.endLat!, accuracy: 1e-9)
        XCTAssertEqual(merged.batteryDropPercent, 5, "дельты заряда складываются")

        // Пауза стала остановкой в пути ровно на её интервал.
        XCTAssertEqual(merged.stops?.count, 1)
        XCTAssertEqual(merged.stops![0].from, previous.endedAt)
        XCTAssertEqual(merged.stops![0].to, next.startedAt)
        XCTAssertEqual(merged.movingDuration,
                       merged.duration - 20 * 60, accuracy: 1)

        // Балл — той же арифметикой, что у неразрезанной поездки.
        let direct = DrivingScore.tripScore(
            passes: merged.passed.map {
                DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh)
            },
            trackSpeeds: merged.trackPoints.map(\.speedKmh))
        XCTAssertEqual(merged.score, direct)
    }

    func testMergedBatteryUnknownWhenLegUnknown() {
        let previous = record(start: base, minutes: 30, km: 6, from: origin,
                              manual: true, battery: nil)
        let next = record(start: base.addingTimeInterval(50 * 60), minutes: 15, km: 4,
                          from: previous.endCoordinate!, battery: 2)
        XCTAssertNil(TripMerge.merged(previous: previous, next: next).batteryDropPercent,
                     "неизвестна одна нога — неизвестна вся дельта, «−2 %» была бы ложью")
    }

    /// Карточка «Объединить?» появляется только там, где склейку заблокировало
    /// РУЧНОЕ «Завершить»; остальные отказы автоматики — по делу, не пристаём.
    func testSuggestsMergeOnlyWhenManualStopWasBlocker() {
        let auto = record(start: base, minutes: 30, km: 6, from: origin, manual: false)
        let previous = record(start: base, minutes: 30, km: 6, from: origin, manual: true)
        let next = record(start: base.addingTimeInterval(50 * 60), minutes: 15, km: 4,
                          from: previous.endCoordinate!)

        XCTAssertFalse(TripMerge.suggestsMerge(previous: auto, next: next,
                                               savedPlaces: [], calendar: utc),
                       "автостоп не склеил — значит, отказала не кнопка, а геометрия")
        XCTAssertTrue(TripMerge.suggestsMerge(previous: previous, next: next,
                                              savedPlaces: [], calendar: utc))

        // Двадцать минут у дома — «приехал»; та же пауза у магазина — заезд.
        let home = previous.endCoordinate!
        XCTAssertFalse(TripMerge.suggestsMerge(previous: previous, next: next,
                                               savedPlaces: [home], calendar: utc))
        let quick = record(start: previous.endedAt.addingTimeInterval(10 * 60),
                           minutes: 15, km: 4, from: home)
        XCTAssertTrue(TripMerge.suggestsMerge(previous: previous, next: quick,
                                              savedPlaces: [home], calendar: utc),
                      "короткая пауза сильнее места — как у автосклейки")
    }

    /// Починка дня «снять обе ноги, положить склейку»: сводка по дням снова
    /// совпадает со сводкой по записям (главный инвариант TripDayTests).
    func testMergedDayRepairKeepsRollupInvariant() {
        let passA = mergePass(1, speed: 88, at: base.addingTimeInterval(10 * 60))
        let previous = record(start: base, minutes: 30, km: 6, from: origin,
                              manual: true, passes: [passA])
        let next = record(start: base.addingTimeInterval(50 * 60), minutes: 15, km: 4,
                          from: previous.endCoordinate!)
        var days = TripDayBook.rebuilt(from: [next, previous], calendar: utc)

        let merged = TripMerge.merged(previous: previous, next: next)
        days = TripDayBook.unfolded(previous, from: days, calendar: utc)
        days = TripDayBook.unfolded(next, from: days, calendar: utc)
        days = TripDayBook.folded(merged, into: days, calendar: utc)

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].trips, 1, "две записи стали одной поездкой")

        let byDays = TripHistory.summary(days: days, history: [merged], period: .week,
                                         anchor: base, calendar: utc)
        let byRecords = TripHistory.summary([merged], period: .week,
                                            calendar: utc, now: base)
        XCTAssertEqual(byDays.trips, byRecords.trips)
        XCTAssertEqual(byDays.distance, byRecords.distance, accuracy: 0.1)
        XCTAssertEqual(byDays.movingDuration, byRecords.movingDuration, accuracy: 0.1)
        XCTAssertEqual(byDays.overPasses, byRecords.overPasses)
        XCTAssertEqual(byDays.fineRisk, byRecords.fineRisk, accuracy: 0.1)
        XCTAssertEqual(byDays.rating, byRecords.rating)
    }
}
