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

    // MARK: - Знак у машины на карте (29.B)

    func testBadgeShowsALowerLimitEvenWhenAlreadySlow() throws {
        // Голос молчит (едем 35 в сороковую), а знак — сведение, он есть.
        XCTAssertNil(LimitAhead.notice(current: 70, speedKmh: 35, tolerance: 0, probes: probes([70, 70, 40, 40])))
        let cue = try XCTUnwrap(LimitAhead.visual(current: 70, probes: probes([70, 70, 40, 40])))
        XCTAssertEqual(cue.limit, 40)
        XCTAssertEqual(cue.distance, 150)
    }

    func testBadgeNeedsADecreaseConfirmedByTwoProbes() {
        XCTAssertNil(LimitAhead.visual(current: 40, probes: probes([40, 60, 60])), "повышение — не знак")
        XCTAssertNil(LimitAhead.visual(current: 70, probes: probes([70, 40, 70])), "одна проба — шум")
        XCTAssertNil(LimitAhead.visual(current: nil, probes: probes([40, 40])))
        XCTAssertNil(LimitAhead.visual(current: 70, probes: probes([70, 70, 70, 70, 70, 70, 70, 70, 40, 40])),
                     "дальше limitAheadMaxMeters — рано")
    }

    func testBadgeMetersRoundToReadableSteps() {
        XCTAssertEqual(LimitAhead.badgeMeters(87), 90)
        XCTAssertEqual(LimitAhead.badgeMeters(212), 200)
        XCTAssertEqual(LimitAhead.badgeMeters(238), 250)
        XCTAssertEqual(LimitAhead.badgeMeters(-1), 0)
    }

    func testBadgeGoesAwayOncePassed() {
        let at = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.24)
        let cue = LimitAhead.Notice(limit: 40, distance: 200, at: at)
        var badge = LimitAhead.Badge()
        XCTAssertEqual(badge.meters(for: cue, distance: 200), 200)
        XCTAssertEqual(badge.meters(for: cue, distance: 120), 100)
        XCTAssertEqual(badge.meters(for: cue, distance: 40), 40)
        // GPS дрогнул на пару метров назад — знак остаётся.
        XCTAssertEqual(badge.meters(for: cue, distance: 45), 50)
        // У самой точки смены — уже проехали.
        XCTAssertNil(badge.meters(for: cue, distance: 8))
        // Удаляемся от точки — проехали, даже если служба ещё держит смену.
        XCTAssertNil(badge.meters(for: cue, distance: 60))
        // Новая смена в другом месте — знак снова.
        let next = LimitAhead.Notice(limit: 30, distance: 300,
                                     at: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.24))
        XCTAssertEqual(badge.meters(for: next, distance: 300), 300)
        XCTAssertNil(badge.meters(for: nil, distance: 0))
    }
}
