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
}
