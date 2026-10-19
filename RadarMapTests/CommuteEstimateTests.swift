//
//  CommuteEstimateTests.swift
//  RadarMapTests
//
//  «Сейчас на работу ~44 мин» (8.8.6) и пробки на своём пути (8.8.10):
//  медиана на этот час, пробка — только хуже q75 водителя, встречная полоса
//  и устаревший файл ничего не меняют, угол одного ребра — не пробка участка.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CommuteEstimateTests: XCTestCase {
    private let lat = 41.30, lon0 = 69.20
    private var k: Double { 111_320 * cos(lat * .pi / 180) }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Понедельник, 11 января 2027.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    private func point(_ x: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon0 + x / k)
    }

    /// Прямая 4 км на восток, 20 участков по 200 м. Утро: 18–25 с на участок
    /// (медиана 20, q75 22); вечер — вдвое дольше.
    private func variant() -> CommuteProfile.Variant {
        var line: [Int32] = []
        for i in 0..<81 {
            let p = point(50 * Double(i))
            line.append(Int32((p.latitude * 1e5).rounded()))
            line.append(Int32((p.longitude * 1e5).rounded()))
        }
        var rows: [CommuteProfile.Row] = []
        for (i, s) in [18, 20, 20, 22, 25].enumerated() {
            for (hour, scale) in [(8, 1), (18, 2)] {
                rows.append(CommuteProfile.Row(tripID: Double(i * 10 + hour),
                                               departure: at(hour, day: 4 + i),
                                               weekend: false, arrivalMinute: 0,
                                               seconds: [UInt16](repeating: UInt16(s * scale), count: 20)))
            }
        }
        return CommuteProfile.Variant(id: UUID(), line: line, ends: (1...20).map { Float($0 * 200) },
                                      limitKmh: [], rows: rows, lastUsed: at(8))
    }

    /// Рёбра по 100 м на отрезке [from, to] линии; `westbound` — встречная полоса.
    private func snapshot(from: Double, to: Double, kmh: Double, westbound: Bool = false,
                          generated: Date? = nil) -> TrafficSnapshot {
        var edges: [TrafficEdge] = []
        var x = from
        while x < to {
            let (a, b) = westbound ? (point(x + 100), point(x)) : (point(x), point(x + 100))
            edges.append(TrafficEdge(a: a, b: b, level: 3, kmh: kmh, modelKmh: 50))
            x += 100
        }
        return TrafficSnapshot(generated: generated ?? at(8), edges: edges)
    }

    func testBeforeDepartureUsesThisHour() throws {
        let morning = try XCTUnwrap(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(8, 5),
                                                                    snapshot: nil, calendar: utc))
        let evening = try XCTUnwrap(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(18, 5),
                                                                    snapshot: nil, calendar: utc))
        XCTAssertEqual(morning.seconds, 400, accuracy: 1, "утром — утренняя медиана")
        XCTAssertEqual(evening.seconds, 800, accuracy: 1, "вечером — вечерняя, а не общая за месяц")
        XCTAssertEqual(morning.jamSeconds, 0)
    }

    /// 1 км пробки 10 км/ч: 72 с на участок вместо 20 — +52 с на каждом из пяти.
    func testJamWorseThanUsualAdds() throws {
        let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(
            variants: [variant()], now: at(8, 5), snapshot: snapshot(from: 1000, to: 2000, kmh: 10), calendar: utc))
        XCTAssertEqual(e.jamSeconds, 5 * 52, accuracy: 15)
        XCTAssertEqual(e.seconds, 400 + e.jamSeconds, accuracy: 0.5)
    }

    /// 40 км/ч — 18 с на участок: не хуже обычной утренней пробки, которая уже
    /// в медиане водителя. Ни прибавки, ни «сегодня быстрее».
    func testUsualTrafficIsNotCountedTwice() throws {
        let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(
            variants: [variant()], now: at(8, 5), snapshot: snapshot(from: 1000, to: 2000, kmh: 40), calendar: utc))
        XCTAssertEqual(e.jamSeconds, 0)
        XCTAssertEqual(e.seconds, 400, accuracy: 1)
    }

    func testOncomingJamDoesNotSlowUs() throws {
        let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(
            variants: [variant()], now: at(8, 5),
            snapshot: snapshot(from: 1000, to: 2000, kmh: 5, westbound: true), calendar: utc))
        XCTAssertEqual(e.jamSeconds, 0, "пробка на встречке — не наша")
    }

    func testStaleTrafficIsNoData() throws {
        let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(
            variants: [variant()], now: at(8, 5),
            snapshot: snapshot(from: 1000, to: 2000, kmh: 5, generated: at(7, 40)), calendar: utc))
        XCTAssertEqual(e.jamSeconds, 0, "файл 25-минутной давности — данных нет")
    }

    /// Одно ребро у края участка (меньше трети длины) — не пробка участка.
    func testACornerIsNotASegmentJam() throws {
        let v = variant()
        let base = try XCTUnwrap(CommuteGhost.baseline(ends: v.ends, limitKmh: v.limitKmh, rows: v.rows))
        let corner = TrafficSnapshot(generated: at(8), edges: [
            TrafficEdge(a: point(1160), b: point(1200), level: 3, kmh: 5, modelKmh: 50)])
        let crowd = CommuteEstimate.crowdSeconds(line: v.coordinates, base: base, snapshot: corner)
        XCTAssertNil(crowd[5])
        XCTAssertEqual(crowd.compactMap(\.self).count, 0)
    }

    /// Пробка позади — уже не добавка к остатку.
    func testJamBehindIsNotAhead() throws {
        let v = variant()
        let rows = try XCTUnwrap(CommuteGhost.selectRows(v.rows, weekend: false, departureMinute: 485, calendar: utc))
        let base = try XCTUnwrap(CommuteGhost.baseline(ends: v.ends, limitKmh: v.limitKmh, rows: rows))
        let crowd = CommuteEstimate.crowdSeconds(line: v.coordinates, base: base,
                                                 snapshot: snapshot(from: 1000, to: 2000, kmh: 10))
        XCTAssertGreaterThan(CommuteEstimate.jamExtra(base, crowd: crowd, from: 0), 200)
        XCTAssertEqual(CommuteEstimate.jamExtra(base, crowd: crowd, from: 10), 0)
    }

    /// В 13:00 рядом нет ни утренних, ни вечерних выездов — берутся все
    /// будние (медиана десяти); в выходной будничная история молчит.
    func testMiddayAndWeekend() throws {
        let midday = try XCTUnwrap(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(13),
                                                                   snapshot: nil, calendar: utc))
        XCTAssertEqual(midday.seconds, 20 * 30.5, accuracy: 1)
        XCTAssertNil(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(8, day: 16),
                                                     snapshot: nil, calendar: utc))
    }
}
