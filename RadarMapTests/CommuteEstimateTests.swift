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
    /// (медиана 20, q75 22); вечер — вдвое дольше. `only` — свои строки вместо этих.
    private func variant(only: [(hour: Int, minute: Int, seconds: Int)]? = nil,
                         lastUsed: Date? = nil) -> CommuteProfile.Variant {
        var line: [Int32] = []
        for i in 0..<81 {
            let p = point(50 * Double(i))
            line.append(Int32((p.latitude * 1e5).rounded()))
            line.append(Int32((p.longitude * 1e5).rounded()))
        }
        var rows: [CommuteProfile.Row] = []
        if let only {
            for (i, r) in only.enumerated() {
                rows.append(CommuteProfile.Row(tripID: Double(i), departure: at(r.hour, r.minute, day: 4 + i % 5),
                                               weekend: false, arrivalMinute: 0,
                                               seconds: [UInt16](repeating: UInt16(r.seconds), count: 20)))
            }
        } else {
            for (i, s) in [18, 20, 20, 22, 25].enumerated() {
                for (hour, scale) in [(8, 1), (18, 2)] {
                    rows.append(CommuteProfile.Row(tripID: Double(i * 10 + hour),
                                                   departure: at(hour, day: 4 + i),
                                                   weekend: false, arrivalMinute: 0,
                                                   seconds: [UInt16](repeating: UInt16(s * scale), count: 20)))
                }
            }
        }
        return CommuteProfile.Variant(id: UUID(), line: line, ends: (1...20).map { Float($0 * 200) },
                                      limitKmh: [], rows: rows, lastUsed: lastUsed ?? at(8))
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
        // В целых минутах: 400 с → 7 мин, 800 с → 13 мин.
        XCTAssertEqual(morning.seconds, 7 * 60, "утром — утренняя медиана")
        XCTAssertEqual(evening.seconds, 13 * 60, "вечером — вечерняя, а не общая за месяц")
        XCTAssertEqual(morning.jamSeconds, 0)
    }

    /// 1 км пробки 10 км/ч: 72 с на участок вместо 20 — +52 с на каждом из
    /// пяти, 260 с — в целых минутах 4; сумма сходится с тем, что видно.
    func testJamWorseThanUsualAdds() throws {
        let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(
            variants: [variant()], now: at(8, 5), snapshot: snapshot(from: 1000, to: 2000, kmh: 10), calendar: utc))
        XCTAssertEqual(e.jamSeconds, 4 * 60)
        XCTAssertEqual(e.seconds, 7 * 60 + 4 * 60, "обычные 7 + пробки 4 — как на строке")
        let base = try XCTUnwrap(CommuteGhost.baseline(ends: variant().ends, limitKmh: [],
                                                       rows: try XCTUnwrap(CommuteGhost.selectRows(
                                                           variant().rows, weekend: false, departureMinute: 485,
                                                           calendar: utc))))
        let crowd = CommuteEstimate.crowdSeconds(line: variant().coordinates, base: base,
                                                 snapshot: snapshot(from: 1000, to: 2000, kmh: 10))
        XCTAssertEqual(CommuteEstimate.jamExtra(base, crowd: crowd), 5 * 52, accuracy: 3)
        XCTAssertNil(crowd[4], "соседний участок не задет: шаг за концом ребра — не пробка")
        XCTAssertNil(crowd[10])
    }

    /// 34 км/ч — 21 с на участок: медленнее медианы (20), но не хуже q75 (22) —
    /// это обычная утренняя пробка, она уже в медиане. Ни прибавки, ни «быстрее».
    func testUsualTrafficIsNotCountedTwice() throws {
        let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(
            variants: [variant()], now: at(8, 5), snapshot: snapshot(from: 1000, to: 2000, kmh: 34), calendar: utc))
        XCTAssertEqual(e.jamSeconds, 0)
        XCTAssertEqual(e.seconds, 7 * 60)
    }

    /// Пробка на половине участка: пробочная половина по скорости рёбер,
    /// остальное — по медиане водителя.
    func testHalfASegmentBlendsJamAndUsual() throws {
        let v = variant()
        let rows = try XCTUnwrap(CommuteGhost.selectRows(v.rows, weekend: false, departureMinute: 485, calendar: utc))
        let base = try XCTUnwrap(CommuteGhost.baseline(ends: v.ends, limitKmh: v.limitKmh, rows: rows))
        let crowd = CommuteEstimate.crowdSeconds(line: v.coordinates, base: base,
                                                 snapshot: snapshot(from: 1000, to: 1100, kmh: 10))
        XCTAssertEqual(try XCTUnwrap(crowd[5]), 100 / (10 / 3.6) + 10, accuracy: 2)
    }

    /// Ближе к этому часу — лучше богаче: 4 поездки в 8:00 честнее, чем 8 в
    /// полдень или 5 в 9:40, для выезда в 8:05.
    func testTheVariantOfThisHourWins() throws {
        let morning = variant(only: (0..<4).map { _ in (8, 0, 25) })
        let midday = variant(only: (0..<8).map { _ in (11, 30, 20) }, lastUsed: at(9))
        let later = variant(only: (0..<5).map { _ in (9, 40, 30) }, lastUsed: at(9))
        for order in [[morning, midday, later], [later, midday, morning]] {
            let e = try XCTUnwrap(CommuteEstimate.beforeDeparture(variants: order, now: at(8, 5),
                                                                  snapshot: nil, calendar: utc))
            XCTAssertEqual(e.seconds, 8 * 60, "500 с утреннего варианта, в минутах")
        }
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

    /// Одно ребро у края участка (четверть длины) — не пробка участка, хотя
    /// допуск по месту и продлевает ребро за концы.
    func testACornerIsNotASegmentJam() throws {
        let v = variant()
        let base = try XCTUnwrap(CommuteGhost.baseline(ends: v.ends, limitKmh: v.limitKmh, rows: v.rows))
        let corner = TrafficSnapshot(generated: at(8), edges: [
            TrafficEdge(a: point(1150), b: point(1200), level: 3, kmh: 5, modelKmh: 50)])
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

    /// В 13:00 в окне ±2 ч нет ни утренних, ни вечерних выездов: медиана
    /// всего дня — не «сейчас», оценки нет (строка остаётся при «обычно»).
    /// В выходной будничная история тоже молчит.
    func testNoEstimateOutsideTheHoursDrivenOrOnWeekend() {
        XCTAssertNil(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(13), snapshot: nil,
                                                     calendar: utc))
        XCTAssertNil(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(3), snapshot: nil,
                                                     calendar: utc))
        XCTAssertNil(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(8, day: 16),
                                                     snapshot: nil, calendar: utc))
        XCTAssertNotNil(CommuteEstimate.beforeDeparture(variants: [variant()], now: at(9, 50), snapshot: nil,
                                                        calendar: utc), "±2 ч от 8:00 — ещё «этот час»")
    }
}
