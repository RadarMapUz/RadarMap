//
//  CommuteProfileTests.swift
//  RadarMapTests
//
//  Профиль дороги по участкам: одна поездка — одна строка на линии своего
//  варианта; тот же путь копит строки, другой заводит вариант; стоянка и
//  точки без времени — пропуски, а не догадки; призрак не быстрее лимита.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class CommuteProfileTests: XCTestCase {
    private typealias P = CommuteProfile
    private let now = Date(timeIntervalSince1970: 1_760_900_000)   // 19.10.2026
    private let lat0 = 41.30, lon0 = 69.20
    private var metersPerLon: Double { 111_320 * cos(lat0 * .pi / 180) }
    private let metersPerLat = 110_574.0

    /// Трек по ломаной из точек (метры на восток/север от начала) с шагом
    /// 30 м и скоростью `speed` м/с; `stopAt` — стоянка на этой дистанции.
    private func track(_ corners: [(Double, Double)], speed: Double, start: Double = 1_760_860_000,
                       stopAt: Double? = nil, stopSeconds: Double = 0) -> [P.TimedPoint] {
        var out: [P.TimedPoint] = []
        var walked = 0.0
        var t = start
        var stopped = false
        for (a, b) in zip(corners, corners.dropFirst()) {
            let dx = b.0 - a.0, dy = b.1 - a.1
            let length = (dx * dx + dy * dy).squareRoot()
            var s = 0.0
            while s < length {
                let x = a.0 + dx * s / length, y = a.1 + dy * s / length
                out.append(P.TimedPoint(lat: lat0 + y / metersPerLat, lon: lon0 + x / metersPerLon, t: t))
                if let stopAt, !stopped, walked + s >= stopAt { t += stopSeconds; stopped = true }
                s += 30
                t += 30 / speed
            }
            walked += length
        }
        let last = corners.last!
        out.append(P.TimedPoint(lat: lat0 + last.1 / metersPerLat, lon: lon0 + last.0 / metersPerLon, t: t))
        return out
    }

    private func fold(_ points: [P.TimedPoint], into book: P.Book = P.Book(), id: Double = 1,
                      stops: [ClosedRange<Double>] = [], limit: Int? = nil, at: Date? = nil) -> P.Book {
        P.fold(points, into: book, direction: .toWork, tripID: id,
               departure: Date(timeIntervalSince1970: points.first!.t),
               arrival: Date(timeIntervalSince1970: points.last!.t),
               stops: stops, limitAt: limit.map { value in { _ in value } }, now: at ?? now)
    }

    private let straight: [(Double, Double)] = [(0, 0), (3000, 0)]

    func testBoundariesMergeAShortTail() {
        XCTAssertEqual(P.boundaries(length: 1050), [200, 400, 600, 800, 1050])
        XCTAssertEqual(P.boundaries(length: 1120), [200, 400, 600, 800, 1000, 1120])
        XCTAssertEqual(P.boundaries(length: 0), [])
    }

    func testOneTripIsOneRowOfSegmentTimes() {
        let book = fold(track(straight, speed: 10))
        XCTAssertEqual(book.toWork.count, 1)
        let row = book.toWork[0].rows[0]
        XCTAssertEqual(row.seconds.count, 15)
        for s in row.seconds { XCTAssertEqual(Double(s), 20, accuracy: 1.5, "200 м на 10 м/с") }
        XCTAssertFalse(row.approx)
    }

    func testSamePathAddsRowsToTheSameVariant() {
        var book = fold(track(straight, speed: 10), id: 1)
        book = fold(track(straight, speed: 8, start: 1_760_946_400), into: book, id: 2)
        XCTAssertEqual(book.toWork.count, 1)
        XCTAssertEqual(book.toWork[0].rows.map(\.tripID), [2, 1], "новые первыми")
    }

    func testDifferentPathStartsAnotherVariant() {
        var book = fold(track(straight, speed: 10), id: 1)
        // Тот же старт и финиш, но через квартал севернее: 600 м в стороне.
        book = fold(track([(0, 0), (0, 600), (3000, 600), (3000, 0)], speed: 10), into: book, id: 2)
        XCTAssertEqual(book.toWork.count, 2)
    }

    func testStopInsideASegmentIsNotTraffic() {
        let start = 1_760_860_000.0
        let points = track(straight, speed: 10, start: start, stopAt: 1500, stopSeconds: 600)
        let stopFrom = points.first { $0.lon >= lon0 + 1500 / metersPerLon }!.t
        let book = fold(points, stops: [stopFrom...(stopFrom + 600)])
        let row = book.toWork[0].rows[0]
        XCTAssertEqual(row.seconds.filter { $0 == P.Row.noData }.count, 1, "одна стоянка — один пропуск")
        XCTAssertFalse(row.seconds.contains { $0 != P.Row.noData && $0 > 100 }, "стоянка не стала пробкой")
    }

    func testPointsWithoutTimeAreGapsAndAHalfEmptyRowIsDropped() {
        var points = track(straight, speed: 10)
        for i in 0..<(points.count * 2 / 3) {
            points[i] = P.TimedPoint(lat: points[i].lat, lon: points[i].lon, t: .nan)
        }
        let book = fold(points)
        XCTAssertEqual(book.toWork.count, 1, "путь запомнен")
        XCTAssertTrue(book.toWork[0].rows.isEmpty, "строка без половины участков не кладётся")
    }

    /// Не гонка: на лимите 60 участок 200 м не быстрее 12 с, сколько бы ни ехали.
    func testGhostNeverBeatsTheLimit() {
        let book = fold(track(straight, speed: 30), limit: 60)
        XCTAssertEqual(book.toWork[0].limitKmh.first, 60)
        for s in book.toWork[0].rows[0].seconds { XCTAssertGreaterThanOrEqual(s, 12) }
    }

    func testRowsAreCappedAndOldOnesForgotten() {
        var book = P.Book()
        for day in 0..<25 {
            book = fold(track(straight, speed: 10, start: 1_760_860_000 - Double(day) * 86_400),
                        into: book, id: Double(day))
        }
        XCTAssertEqual(book.toWork[0].rows.count, AppConfig.commuteProfileMaxRows)
        // Через 60 дней старые строки уходят при следующей поездке.
        let later = now.addingTimeInterval(60 * 86_400)
        book = fold(track(straight, speed: 10, start: later.timeIntervalSince1970 - 3600),
                    into: book, id: 999, at: later)
        XCTAssertEqual(book.toWork[0].rows.map(\.tripID), [999])
    }

    func testSecondFinishOfAMergedTripReplacesItsRow() {
        var book = fold(track(straight, speed: 10), id: 7)
        book = fold(track(straight, speed: 5), into: book, id: 7)
        XCTAssertEqual(book.toWork[0].rows.count, 1)
        XCTAssertEqual(Double(book.toWork[0].rows[0].seconds[3]), 40, accuracy: 2)
    }

    func testOldestVariantIsEvicted() {
        var book = P.Book()
        for (i, north) in [0.0, 1500, 3000, 4500].enumerated() {
            book = fold(track([(0, 0), (0, north), (3000, north), (3000, 0)], speed: 10),
                        into: book, id: Double(i), at: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(book.toWork.count, AppConfig.commuteProfileMaxVariants)
    }

    // MARK: - Журнал

    func testLedgerKeepsTripsTheHistoryAlreadyDropped() {
        struct Trip: CommuteTripSource {
            let id: Double
            var startedAt: Date { Date(timeIntervalSince1970: id) }
            var endedAt: Date { startedAt.addingTimeInterval(1800) }
            var movingDuration: TimeInterval { 1700 }
            var distanceMeters: Double { 12_000 }
            var startCoordinate: CLLocationCoordinate2D? { CLLocationCoordinate2D(latitude: 41.3, longitude: 69.2) }
            var endCoordinate: CLLocationCoordinate2D? { CLLocationCoordinate2D(latitude: 41.35, longitude: 69.3) }
        }
        let day = 86_400.0
        let old = CommuteLedger.updated([], with: [Trip(id: now.timeIntervalSince1970 - 20 * day)], now: now)
        // История уже без той поездки — журнал её помнит.
        let next = CommuteLedger.updated(old, with: [Trip(id: now.timeIntervalSince1970 - day)], now: now)
        XCTAssertEqual(next.count, 2)
        XCTAssertGreaterThan(next[0].startedAt, next[1].startedAt, "новые первыми")
        // Старше окна — забыты.
        let far = CommuteLedger.updated(next, with: [Trip](), now: now.addingTimeInterval(50 * day))
        XCTAssertTrue(far.isEmpty)
    }
}
