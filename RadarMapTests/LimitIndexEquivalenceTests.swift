//
//  LimitIndexEquivalenceTests.swift
//  RadarMapTests
//
//  Пакет памяти 2.19: индекс лимитов переехал на плоские буферы и разбор
//  без NSNumber. Ответы обязаны совпасть с прежними до бита — на случайной
//  сети с классами, битыми записями и тысячами точек и курсов.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LimitIndexEquivalenceTests: XCTestCase {
    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Сеть: улицы кусками по 4–12 точек со случайным изгибом, лимиты и
    /// классы вперемешку, плюс записи, которые оба обязаны отвергнуть.
    private func network(seed: UInt64) -> Data {
        var rng = Rng(state: seed)
        var segments: [Any] = []
        let limits = [20, 40, 50, 60, 70, 80, 100, 5, 300]
        for _ in 0..<1500 {
            var lat = 41.28 + rng.next() * 0.06, lon = 69.20 + rng.next() * 0.06
            let heading = rng.next() * 2 * .pi
            var flat: [Double] = []
            for _ in 0..<(4 + Int(rng.next() * 9)) {
                flat.append(lat); flat.append(lon)
                lat += cos(heading + (rng.next() - 0.5) * 0.4) * 0.0003
                lon += sin(heading + (rng.next() - 0.5) * 0.4) * 0.0004
            }
            let limit = limits[Int(rng.next() * Double(limits.count))]
            if rng.next() < 0.5 {
                segments.append([limit, flat])
            } else {
                segments.append([limit, Int(rng.next() * 9), flat])
            }
        }
        // Битые записи: не тот размер, строка вместо лимита, геометрия короче
        // двух точек. (Запись — не массив — прежний разбор отвергал ВЕСЬ файл;
        // новый — только её, см. testNonArrayEntryCostsOnlyItself.)
        segments.append([60])
        segments.append(["60", [41.3, 69.2, 41.31, 69.21]])
        segments.append([60, [41.3, 69.2]])
        return try! JSONSerialization.data(withJSONObject: ["segments": segments])
    }

    func testMatchingIsBitForBitTheSame() throws {
        for seed in [1, 7, 42] as [UInt64] {
            let data = network(seed: seed)
            let fresh = try XCTUnwrap(LimitIndex.build(from: data))
            let legacy = try XCTUnwrap(LegacyLimitIndex.build(from: data))
            XCTAssertEqual(fresh.segments.count, legacy.segments.count)
            var rng = Rng(state: seed &+ 99)
            var hits = 0, mismatches: [String] = []
            for _ in 0..<1000 {
                let point = CLLocationCoordinate2D(latitude: 41.28 + rng.next() * 0.06,
                                                   longitude: 69.20 + rng.next() * 0.06)
                let course = rng.next() * 360
                let a = fresh.matchHit(point, courseDegrees: course)
                let b = legacy.matchHit(point, courseDegrees: course)
                let same = a?.limit == b?.limit && a?.cls == b?.cls
                    && a?.coordinate.latitude == b?.coordinate.latitude
                    && a?.coordinate.longitude == b?.coordinate.longitude
                    && a?.bearingDegrees == b?.bearingDegrees && a?.distanceMeters == b?.distanceMeters
                    && fresh.limit(near: point) == legacy.limit(near: point)
                if !same { mismatches.append("\(point.latitude),\(point.longitude) @\(Int(course))") }
                if a != nil { hits += 1 }
            }
            XCTAssertEqual(mismatches, [], "seed \(seed)")
            XCTAssertGreaterThan(hits, 30, "сеть достаточно густая, чтобы сравнение что-то значило")
        }
    }

    func testRoadsNearAreTheSame() throws {
        let data = network(seed: 5)
        let fresh = try XCTUnwrap(LimitIndex.build(from: data))
        let legacy = try XCTUnwrap(LegacyLimitIndex.build(from: data))
        var rng = Rng(state: 11)
        for _ in 0..<50 {
            let point = CLLocationCoordinate2D(latitude: 41.28 + rng.next() * 0.06,
                                               longitude: 69.20 + rng.next() * 0.06)
            func key(_ lines: [RoadLine]) -> [String] {
                lines.map { $0.points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";") }.sorted()
            }
            XCTAssertEqual(key(fresh.roads(near: point, radius: 600)), key(legacy.roads(near: point, radius: 600)))
        }
    }

    /// Прежний разбор отвергал весь файл из-за одной записи не того вида —
    /// двадцать тысяч честных лимитов вместе с ней.
    func testNonArrayEntryCostsOnlyItself() {
        let data = Data(#"{"segments":[42,[60,[41.3,69.2,41.31,69.21]]]}"#.utf8)
        XCTAssertNil(LegacyLimitIndex.build(from: data))
        XCTAssertEqual(LimitIndex.build(from: data)?.segments.count, 1)
    }

    func testAbsurdNumbersAreRejectedWithoutACrash() {
        let junk = #"{"segments":[[1e300,[41.3,69.2,41.31,69.21]],[60,1e300,[41.3,69.2,41.31,69.21]],[60,[1e300,69.2,41.31,69.21]],[60,[41.3,69.2,41.31,69.21]]]}"#
        let index = LimitIndex.build(from: Data(junk.utf8))
        XCTAssertEqual(index?.segments.count, 2, "лимит 1e300 и широта 1e300 — долой, класс 1e300 — неизвестен")
    }
}
