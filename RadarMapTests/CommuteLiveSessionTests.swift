//
//  CommuteLiveSessionTests.swift
//  RadarMapTests
//
//  Сессия призрака на ходу (8.8.2): по графику — прибытие как обычно;
//  медленнее — отклонение растёт; до 1,5 км и на чужой дороге — молчит;
//  направление поездки — по месту старта.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CommuteLiveSessionTests: XCTestCase {
    private let lat = 41.30, lon0 = 69.20
    private var metersPerLon: Double { 111_320 * cos(lat * .pi / 180) }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)   // пятница, 08:00 UTC
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Прямая 4 км на восток, 20 участков по 200 м, обычно 20 с на участок.
    private func variant(points: Int = 81) -> CommuteProfile.Variant {
        var line: [Int32] = []
        for i in 0..<points {
            let x = 4000.0 * Double(i) / Double(points - 1)
            line.append(Int32((lat * 1e5).rounded()))
            line.append(Int32(((lon0 + x / metersPerLon) * 1e5).rounded()))
        }
        let rows = (0..<5).map { i in
            CommuteProfile.Row(tripID: Double(i), departure: start.addingTimeInterval(-Double(i + 1) * 86_400),
                               weekend: false, arrivalMinute: 0,
                               seconds: [UInt16](repeating: 20, count: 20))
        }
        return CommuteProfile.Variant(id: UUID(), line: line, ends: (1...20).map { Float($0 * 200) },
                                      limitKmh: [], rows: rows, lastUsed: start)
    }

    private func coordinate(_ x: Double, north: Double = 0) -> (Double, Double) {
        (lat + north / 111_320, lon0 + x / metersPerLon)
    }

    private func drive(_ session: inout CommuteLiveSession, speed: Double, until meters: Double,
                       north: Double = 0) -> CommuteLiveSession.Output? {
        var last: CommuteLiveSession.Output?
        var x = 0.0
        var t = start
        while x <= meters {
            let (la, lo) = coordinate(x, north: north)
            let out = session.note(lat: la, lon: lo, accuracy: 10, at: t)
            if out.forecast != nil || out.isOff { last = out }
            x += 50
            t = t.addingTimeInterval(50 / speed)
        }
        return last
    }

    func testOnScheduleIsUsual() throws {
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false,
                                                        departure: start, calendar: utc))
        let out = try XCTUnwrap(drive(&session, speed: 10, until: 2500)?.forecast)
        XCTAssertEqual(out.deltaMinutes, 0)
        XCTAssertEqual(out.arrival.timeIntervalSince(start), 400, accuracy: 30, "4 км по 10 м/с")
    }

    func testSlowerTodayShowsLater() throws {
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false,
                                                        departure: start, calendar: utc))
        let out = try XCTUnwrap(drive(&session, speed: 5, until: 2500)?.forecast)
        XCTAssertGreaterThanOrEqual(out.deltaMinutes, 3, "вдвое медленнее на 2,5 км — минимум +4 мин")
    }

    func testSilentBeforeOnePointFiveKilometres() throws {
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false,
                                                        departure: start, calendar: utc))
        XCTAssertNil(drive(&session, speed: 10, until: 1200)?.forecast)
    }

    func testOtherRoadSilencesTheGhost() throws {
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false,
                                                        departure: start, calendar: utc))
        let out = try XCTUnwrap(drive(&session, speed: 10, until: 2500, north: 300))
        XCTAssertTrue(out.isOff)
        XCTAssertNil(out.forecast)
    }

    func testNoGhostWithoutHistoryForThisDay() {
        XCTAssertNil(CommuteLiveSession(variants: [variant()], weekend: true, departure: start, calendar: utc),
                     "будничная история не говорит про субботу")
    }

    func testDirectionFromStartPoint() {
        let home = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20)
        let work = CLLocationCoordinate2D(latitude: 41.35, longitude: 69.30)
        let nearHome = CLLocationCoordinate2D(latitude: 41.303, longitude: 69.20)
        XCTAssertEqual(CommuteLiveService.direction(start: nearHome, home: home, work: work), .toWork)
        XCTAssertEqual(CommuteLiveService.direction(start: work, home: home, work: work), .toHome)
        XCTAssertNil(CommuteLiveService.direction(start: CLLocationCoordinate2D(latitude: 41.2, longitude: 69.1),
                                                  home: home, work: work))
    }
}
