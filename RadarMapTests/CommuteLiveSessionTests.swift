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
    /// `turnAt` — с этого метра линия уходит на север (второй путь).
    private func variant(points: Int = 81, seconds: UInt16 = 20, turnAt: Double? = nil,
                         trips: Int = 5) -> CommuteProfile.Variant {
        var line: [Int32] = []
        for i in 0..<points {
            let s = 4000.0 * Double(i) / Double(points - 1)
            let (la, lo) = turnAt.map { s > $0 ? coordinate($0, north: s - $0) : coordinate(s) }
                ?? coordinate(s)
            line.append(Int32((la * 1e5).rounded()))
            line.append(Int32((lo * 1e5).rounded()))
        }
        let rows = (0..<trips).map { i in
            CommuteProfile.Row(tripID: Double(i), departure: start.addingTimeInterval(-Double(i + 1) * 86_400),
                               weekend: false, arrivalMinute: 0,
                               seconds: [UInt16](repeating: seconds, count: 20))
        }
        return CommuteProfile.Variant(id: UUID(), line: line, ends: (1...20).map { Float($0 * 200) },
                                      limitKmh: [], rows: rows, lastUsed: start)
    }

    private func coordinate(_ x: Double, north: Double = 0) -> (Double, Double) {
        (lat + north / 111_320, lon0 + x / metersPerLon)
    }

    private func drive(_ session: inout CommuteLiveSession, speed: Double, until meters: Double,
                       from: Double = 0, north: Double = 0, turnAt: Double? = nil) -> CommuteLiveSession.Output? {
        var last: CommuteLiveSession.Output?
        var s = from
        var t = start
        while s <= meters {
            let (la, lo) = turnAt.map { s > $0 ? coordinate($0, north: s - $0) : coordinate(s, north: north) }
                ?? coordinate(s, north: north)
            let out = session.note(lat: la, lon: lo, accuracy: 10, at: t)
            if out.forecast != nil || out.isOff { last = out }
            s += 50
            t = t.addingTimeInterval(50 / speed)
        }
        return last
    }

    /// Рёбра пробки 10 км/ч по ходу на отрезке [from, to] линии.
    private func jam(from: Double, to: Double, generated: Date) -> TrafficSnapshot {
        var edges: [TrafficEdge] = []
        var x = from
        while x < to {
            let (la, lo) = coordinate(x), (lb, lb2) = coordinate(x + 100)
            edges.append(TrafficEdge(a: CLLocationCoordinate2D(latitude: la, longitude: lo),
                                     b: CLLocationCoordinate2D(latitude: lb, longitude: lb2),
                                     level: 3, kmh: 10, modelKmh: 50))
            x += 100
        }
        return TrafficSnapshot(generated: generated, edges: edges)
    }

    /// Пробка дальше 2 км впереди по своему пути (8.8.10): участок берёт время
    /// пробки сверх обычного — 72 с вместо 20 на двух последних участках.
    /// Ближе 2 км её уже несёт темп ρ — не прибавляем; файл старше 10 мин —
    /// данных нет.
    func testJamFarAheadAddsOnlyBeyondTwoKilometers() throws {
        func session() throws -> CommuteLiveSession {
            try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false, departure: start, calendar: utc))
        }
        var free = try session()
        let usual = try XCTUnwrap(drive(&free, speed: 10, until: 1600)?.forecast)

        var far = try session()
        far.setTraffic(jam(from: 3600, to: 4000, generated: start), now: start)
        let ahead = try XCTUnwrap(drive(&far, speed: 10, until: 1600)?.forecast)
        XCTAssertEqual(ahead.remaining - usual.remaining, 2 * (200 / (10 / 3.6) - 20), accuracy: 8)
        XCTAssertEqual(ahead.arrival.timeIntervalSince(usual.arrival), ahead.remaining - usual.remaining,
                       accuracy: 1)

        var near = try session()
        near.setTraffic(jam(from: 2000, to: 3000, generated: start), now: start)
        let close = try XCTUnwrap(drive(&near, speed: 10, until: 1600)?.forecast)
        XCTAssertEqual(close.remaining, usual.remaining, accuracy: 1, "ближе 2 км — уже темп, не файл")

        var stale = try session()
        stale.setTraffic(jam(from: 3600, to: 4000, generated: start.addingTimeInterval(-11 * 60)), now: start)
        let old = try XCTUnwrap(drive(&stale, speed: 10, until: 1600)?.forecast)
        XCTAssertEqual(old.remaining, usual.remaining, accuracy: 1, "файл старше 10 мин — данных нет")
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
        // 2,5 км за 500 с вместо 250 (+4 мин 10 с) и остаток медленнее рядом,
        // с затуханием: около +6 мин.
        XCTAssertTrue((5...7).contains(out.deltaMinutes), "вдвое медленнее: \(out.deltaMinutes) мин")
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

    /// Автостарт поймал поездку на 800-м метре: Δ — от точки входа, не от дома.
    func testLateStartComparesFromTheJoinPoint() throws {
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false,
                                                        departure: start, calendar: utc))
        let out = try XCTUnwrap(drive(&session, speed: 10, until: 2500, from: 800)?.forecast)
        XCTAssertEqual(out.deltaMinutes, 0, "по графику с 800 м — как обычно, не «на 1 минуту быстрее»")
        XCTAssertEqual(out.remaining, 150, accuracy: 15)
    }

    /// Два знакомых пути, общие первые 2 км: призрак ведёт тот, по которому
    /// едем на самом деле, и его темп не испорчен пересечениями по чужой линии.
    func testTwoVariantsFollowTheOneDriven() throws {
        let straight = variant()
        let turn = variant(seconds: 30, turnAt: 2000)   // второй путь медленнее: 6,7 м/с
        for order in [[straight, turn], [turn, straight]] {
            var session = try XCTUnwrap(CommuteLiveSession(variants: order, weekend: false,
                                                            departure: start, calendar: utc))
            let out = try XCTUnwrap(drive(&session, speed: 200.0 / 30, until: 3800, turnAt: 2000))
            let forecast = try XCTUnwrap(out.forecast)
            XCTAssertFalse(out.isOff)
            XCTAssertTrue(out.hasLead)
            XCTAssertEqual(forecast.deltaMinutes, 0, "по второму пути в его обычном темпе — как обычно")
            // Последний пересчёт — на границе или по 30-секундному таймеру
            // (≤ 200 м назад); по первому пути остаток застрял бы на ~2 км.
            XCTAssertLessThan(out.remainingMeters, 450, "остаток — по линии второго пути")
        }
    }

    /// Ведущий сошёл, второй путь своих 1,5 км не прошёл — прогноз прячется
    /// (а не висит старым).
    func testLosingTheLeadHidesTheForecast() throws {
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant()], weekend: false,
                                                        departure: start, calendar: utc))
        XCTAssertNotNil(drive(&session, speed: 10, until: 2000)?.forecast)
        var t = start.addingTimeInterval(200)
        var out: CommuteLiveSession.Output?
        for k in 1...10 {
            let (la, lo) = coordinate(2000, north: Double(k) * 50)
            t = t.addingTimeInterval(5)
            out = session.note(lat: la, lon: lo, accuracy: 10, at: t)
        }
        XCTAssertEqual(out?.hasLead, false)
        XCTAssertNil(out?.forecast)
    }

    func testNoGhostWithoutHistoryForThisDay() {
        XCTAssertNil(CommuteLiveSession(variants: [variant()], weekend: true, departure: start, calendar: utc),
                     "будничная история не говорит про субботу")
    }

    /// Фраза под оповещением о камере не теряется: не сказанная — не
    /// засчитана, и прозвучит на следующем пересчёте.
    @MainActor
    func testDeferredPhraseIsSpokenLater() {
        let service = CommuteLiveService()
        var busy = true
        var spoken: [String] = []
        service.onAnnounce = { phrase in
            guard !busy else { return false }
            spoken.append(phrase)
            return true
        }
        service.start(direction: .toWork, variants: [variant()], departure: start, calendar: utc)
        var t = start
        for s in stride(from: 0.0, through: 3000, by: 50) {
            if s >= 2000 { busy = false }
            let (la, lo) = coordinate(s)
            service.note(CLLocationCoordinate2D(latitude: la, longitude: lo), accuracy: 10, at: t)
            t = t.addingTimeInterval(5)
        }
        XCTAssertEqual(spoken.count, 1, "одна фраза — после того как голос освободился")
        XCTAssertNotNil(service.display)
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
