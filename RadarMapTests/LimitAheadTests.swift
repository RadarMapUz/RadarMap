//
//  LimitAheadTests.swift
//  RadarMapTests
//
//  «Ограничение 40 через 200 м»: только снижение, только если мы быстрее,
//  только подтверждённое двумя пробами, одна фраза на смену.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LimitAheadTests: XCTestCase {

    private func probes(_ limits: [Int?], step: Double = 50) -> [LimitAhead.Probe] {
        limits.enumerated().map { index, limit in
            let along = Double(index + 1) * step
            return LimitAhead.Probe(along: along, limit: limit,
                                    coordinate: CLLocationCoordinate2D(latitude: 41.30 + along / 111_000,
                                                                       longitude: 69.24))
        }
    }

    func testWarnsBeforeALowerLimit() throws {
        // 70 → 40 через 200 м, едем 65.
        let notice = try XCTUnwrap(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0,
                                                     probes: probes([70, 70, 70, 40, 40, 40])))
        XCTAssertEqual(notice.limit, 40)
        XCTAssertEqual(notice.distance, 200)
    }

    func testSilentWhenAlreadySlowEnough() {
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 38, tolerance: 0,
                                       probes: probes([70, 70, 40, 40])))
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 48, tolerance: 10,
                                       probes: probes([70, 70, 40, 40])), "в пределах допуска")
    }

    func testRaisingLimitIsNotNews() {
        XCTAssertNil(LimitAhead.notice(current: 60, speedKmh: 60, tolerance: 0,
                                       probes: probes([60, 60, 80, 80])))
    }

    func testSingleProbeIsNoise() {
        // Одна точка на съезде — не смена лимита дороги.
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0,
                                       probes: probes([70, 70, 40, 70, 70])))
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0,
                                       probes: probes([70, 70, 70, 70, 70, 70, 70, 40])),
                     "последняя проба без подтверждения")
    }

    func testTooCloseOrTooFar() {
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0, probes: probes([40, 40])),
                     "50 м — поздно, скажет «превышение»")
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0,
                                       probes: probes([70, 70, 70, 70, 70, 70, 70, 70, 40, 40])),
                     "450 м — рано")
    }

    func testUnknownLimitAheadIsSkippedNotAssumed() throws {
        let notice = try XCTUnwrap(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0,
                                                     probes: probes([nil, 70, 40, 40])))
        XCTAssertEqual(notice.distance, 150)
        XCTAssertNil(LimitAhead.notice(current: nil, speedKmh: 65, tolerance: 0, probes: probes([40, 40, 40])))
    }

    func testOnePhrasePerChange() throws {
        var announcer = LimitAhead.Announcer()
        let first = try XCTUnwrap(LimitAhead.notice(current: 70, speedKmh: 65, tolerance: 0,
                                                    probes: probes([70, 70, 70, 40, 40])))
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(announcer.shouldAnnounce(first, at: t0))
        // Та же смена, на 50 м ближе через 70 с — не повторяем.
        let closer = LimitAhead.Notice(limit: 40, distance: 150, at: first.at)
        XCTAssertFalse(announcer.shouldAnnounce(closer, at: t0 + 70))
        let next = LimitAhead.Notice(limit: 30, distance: 200,
                                     at: CLLocationCoordinate2D(latitude: 41.32, longitude: 69.24))
        XCTAssertFalse(announcer.shouldAnnounce(next, at: t0 + 30), "не чаще раза в минуту")
        XCTAssertTrue(announcer.shouldAnnounce(next, at: t0 + 90))
    }
}
