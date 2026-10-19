//
//  TripArchiveTests.swift
//  RadarMapTests
//
//  «Все поездки» (6.10): месяцы в порядке истории, фильтр превышений
//  выкидывает пустые месяцы, финиш «→ Работа» — по радиусу места.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TripArchiveTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func record(_ day: Int, month: Int, over: Bool) -> TripRecord {
        let start = utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
        let pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "Юнусабад",
                                speedKmh: over ? 95 : 55, date: start, lat: 41.3, lon: 69.2, limitKmh: 60)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1800), distanceMeters: 10_000,
                          maxSpeedKmh: 90, passed: [pass])
    }

    func testMonthsKeepHistoryOrderAndFilterDropsEmptyMonths() {
        let history = [record(19, month: 10, over: false), record(3, month: 10, over: true),
                       record(20, month: 9, over: false)]
        let all = TripArchive.months(history, onlyFined: false, calendar: utc)
        XCTAssertEqual(all.map(\.records.count), [2, 1])
        let fined = TripArchive.months(history, onlyFined: true, calendar: utc)
        XCTAssertEqual(fined.count, 1, "в сентябре превышений не было — месяца нет")
        XCTAssertEqual(fined.first?.records.count, 1)
    }

    func testFinishNamesTheNearestPlaceWithinRadius() {
        let home = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2000)
        let work = CLLocationCoordinate2D(latitude: 41.3500, longitude: 69.3000)
        let nearWork = CLLocationCoordinate2D(latitude: 41.3510, longitude: 69.3005)
        XCTAssertEqual(TripArchive.finish(nearWork, home: home, work: work), .work)
        XCTAssertEqual(TripArchive.finish(home, home: home, work: work), .home)
        let elsewhere = CLLocationCoordinate2D(latitude: 41.25, longitude: 69.25)
        XCTAssertNil(TripArchive.finish(elsewhere, home: home, work: work))
        XCTAssertNil(TripArchive.finish(nil, home: home, work: work))
    }
}
