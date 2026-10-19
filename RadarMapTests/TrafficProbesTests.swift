//
//  TrafficProbesTests.swift
//  RadarMapTests
//
//  Куски следа для пробок. Проверяется прежде всего то, чего НЕ должно уйти
//  на сервер: старт и финиш поездки, места у дома и работы, устройство и
//  время. Затем форма куска — ровно то, что принимает server/api.py.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TrafficProbesTests: XCTestCase {

    private let start = CLLocationCoordinate2D(latitude: 41.2800, longitude: 69.2400)
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    /// Прямо на север: `meters` за `seconds`, фикс раз в секунду.
    private func drive(_ probes: inout TrafficProbes, meters: Double, speed: Double = 15,
                       from origin: CLLocationCoordinate2D? = nil, startAt: Date? = nil) -> CLLocationCoordinate2D {
        let o = origin ?? start
        let begin = startAt ?? t0
        let steps = Int(meters / speed)
        var point = o
        for i in 0...steps {
            let d = Double(i) * speed
            point = CLLocationCoordinate2D(latitude: o.latitude + d / 111_320, longitude: o.longitude)
            probes.add(lat: point.latitude, lon: point.longitude, kmh: speed * 3.6,
                       at: begin.addingTimeInterval(Double(i)))
        }
        return point
    }

    private func meters(_ a: [Double], _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a[0], a[1], b.latitude, b.longitude)
    }

    func testTripEndsNeverLeaveThePhone() {
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [])
        let end = drive(&probes, meters: 5000)
        probes.finish()
        let pieces = probes.takeReady()
        XCTAssertFalse(pieces.isEmpty)
        let points = pieces.flatMap(\.p)
        for point in points {
            XCTAssertGreaterThanOrEqual(meters(point, start), AppConfig.trafficTrimMeters - 20, "старт")
            XCTAssertGreaterThanOrEqual(meters(point, end), AppConfig.trafficTrimMeters - 20, "финиш")
        }
    }

    func testNothingIsReleasedBeforeTheCarMovesOn() {
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [])
        _ = drive(&probes, meters: 1300)
        XCTAssertTrue(probes.takeReady().isEmpty,
                      "кусок мог кончиться финишем — держим, пока машина не отъедет на 400 м")
    }

    func testPrivacyZonesAreCutOut() {
        let zone = CLLocationCoordinate2D(latitude: start.latitude + 2500 / 111_320, longitude: start.longitude)
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [zone])
        _ = drive(&probes, meters: 6000)
        probes.finish()
        let points = probes.takeReady().flatMap(\.p)
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertGreaterThanOrEqual(meters(point, zone), AppConfig.trafficPrivacyRadiusMeters - 1)
        }
    }

    /// Ровно то, что принимает сервер: четыре числа, время от нуля строго по
    /// возрастанию, не дольше лимита, не меньше трёх точек.
    func testPieceShapeMatchesTheServerContract() throws {
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [])
        _ = drive(&probes, meters: 6000, speed: 50)   // 180 км/ч: округление секунд
        probes.finish()
        let pieces = probes.takeReady()
        XCTAssertFalse(pieces.isEmpty)
        for piece in pieces {
            XCTAssertGreaterThanOrEqual(piece.p.count, AppConfig.trafficPieceMinPoints)
            XCTAssertLessThanOrEqual(piece.p.count, AppConfig.trafficPieceMaxPoints)
            XCTAssertEqual(piece.p.first?[2], 0)
            for (a, b) in zip(piece.p, piece.p.dropFirst()) {
                XCTAssertEqual(a.count, 4)
                XCTAssertGreaterThan(b[2], a[2], "время строго возрастает")
            }
            XCTAssertLessThanOrEqual(piece.p.last![2], AppConfig.trafficPieceMaxSeconds + 1)
        }
        let json = String(decoding: try JSONEncoder().encode(pieces), as: UTF8.self)
        for leak in ["device", "trip", "time", "date", "id\""] {
            XCTAssertFalse(json.contains(leak), leak)
        }
    }

    func testPointsAreThinned() {
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [])
        _ = drive(&probes, meters: 5000, speed: 10)
        probes.finish()
        for piece in probes.takeReady() {
            for (a, b) in zip(piece.p, piece.p.dropFirst()) {
                let d = GeoMath.fastDistance(a[0], a[1], b[0], b[1])
                XCTAssertTrue(d >= AppConfig.trafficSampleMeters - 1 || b[2] - a[2] >= AppConfig.trafficSampleSeconds)
            }
        }
    }

    func testJumpBreaksThePiece() {
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [])
        let a = drive(&probes, meters: 2000)
        // Туннель: следующая точка через 3 км.
        let far = CLLocationCoordinate2D(latitude: a.latitude + 3000 / 111_320, longitude: a.longitude)
        _ = drive(&probes, meters: 3000, from: far, startAt: t0.addingTimeInterval(200))
        probes.finish()
        for piece in probes.takeReady() {
            for (p, q) in zip(piece.p, piece.p.dropFirst()) {
                XCTAssertLessThan(GeoMath.fastDistance(p[0], p[1], q[0], q[1]), AppConfig.trafficMaxStepMeters)
            }
        }
    }

    func testPieceLengthFloats() {
        func firstLength(_ r: Double) -> Double {
            var probes = TrafficProbes(random: { r })
            probes.begin(zones: [])
            _ = drive(&probes, meters: 6000)
            probes.finish()
            let p = probes.takeReady().first!.p
            return GeoMath.fastDistance(p.first![0], p.first![1], p.last![0], p.last![1])
        }
        XCTAssertLessThan(firstLength(0), firstLength(1) - 200, "длина плавает: по ней куски не склеить")
    }

    func testNothingCollectedOutsideATrip() {
        var probes = TrafficProbes(random: { 0.5 })
        _ = drive(&probes, meters: 3000)
        XCTAssertTrue(probes.takeReady().isEmpty)
    }

    /// Куски знают, когда кончились (только локально): офлайн-поездка не
    /// уходит часы спустя как «сейчас» (S21, 20.10).
    func testPiecesKeepTheirLocalEndTime() {
        var probes = TrafficProbes(random: { 0.5 })
        probes.begin(zones: [])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<400 {
            probes.add(lat: 41.30, lon: 69.20 + Double(i) * 0.0001, kmh: 40,
                       at: start.addingTimeInterval(Double(i)))
        }
        let stamped = probes.takeReadyStamped()
        XCTAssertFalse(stamped.isEmpty)
        for item in stamped {
            XCTAssertGreaterThan(item.endedAt, start)
            XCTAssertLessThan(item.endedAt, start.addingTimeInterval(400))
        }
    }
}
