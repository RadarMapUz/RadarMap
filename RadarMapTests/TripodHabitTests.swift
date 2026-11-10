//
//  TripodHabitTests.swift
//  RadarMapTests
//
//  Пункт 82: «Здесь вечером часто стоит тренога» — заранее, один раз, только
//  у сильного места в его время и только по ходу движения. Это догадка о
//  прошлом, поэтому тесты в основном о том, когда обязаны молчать.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class TripodHabitTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.3100, longitude: 69.2800)
    /// 20:00 по Ташкенту (UTC+5) — вечер, четверть 3.
    private let evening = Date(timeIntervalSince1970: 1_800_000_000
                               - (1_800_000_000 + 5 * 3600).truncatingRemainder(dividingBy: 86400) + 20 * 3600)

    private func spot(ahead meters: Double, side: Double = 0, peak: Int = 3,
                      src: Int? = 4, pdays: Int? = 4) -> TripodHotspots.Spot {
        TripodHotspots.Spot(lat: me.latitude + meters / 111_320.0,
                            lon: me.longitude + side / (111_320.0 * cos(me.latitude * .pi / 180)),
                            n: 8, days: 6, peak: peak, src: src, pdays: pdays)
    }

    private func situation(course: CLLocationDegrees = 0, speed: Double = 50, trip: Bool = true,
                           enabled: Bool = true, now: Date? = nil) -> TripodHabit.Situation {
        TripodHabit.Situation(coordinate: me, course: course, speedKmh: speed, isTripActive: trip,
                              isOverspeeding: false, enabled: enabled, now: now ?? evening)
    }

    func testQuarterFollowsTashkentTime() {
        XCTAssertEqual(TripodHabit.quarter(at: evening), 3)
        XCTAssertEqual(TripodHabit.quarter(at: evening.addingTimeInterval(-14 * 3600)), 1, "6:00 — утро")
        XCTAssertEqual(TripodHabit.quarter(at: evening.addingTimeInterval(5 * 3600)), 0, "1:00 — ночь")
    }

    func testStrongSpotAheadInItsTimeIsAnnounced() {
        let target = spot(ahead: 300)
        XCTAssertEqual(TripodHabit.spotToAnnounce(in: [target], situation: situation(), alreadyVoiced: []), target)
    }

    func testWeakSpotStaysSilent() {
        for weak in [spot(ahead: 300, src: 2), spot(ahead: 300, pdays: 2), spot(ahead: 300, peak: -1),
                     spot(ahead: 300, src: nil, pdays: nil)] {
            XCTAssertNil(TripodHabit.spotToAnnounce(in: [weak], situation: situation(), alreadyVoiced: []),
                         "мало людей, мало дней, нет перевеса или старый файл — молчим")
        }
    }

    func testOtherTimeOfDayStaysSilent() {
        let morning = evening.addingTimeInterval(-12 * 3600)
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [spot(ahead: 300)], situation: situation(now: morning),
                                                alreadyVoiced: []))
    }

    func testLeadBeforeThePeakQuarterBegins() {
        let beforeEvening = evening.addingTimeInterval(-2 * 3600 - 20 * 60)   // 17:40
        XCTAssertEqual(TripodHabit.quarter(at: beforeEvening), 2)
        XCTAssertNotNil(TripodHabit.spotToAnnounce(in: [spot(ahead: 300)], situation: situation(now: beforeEvening),
                                                   alreadyVoiced: []), "за 20 минут до вечера уже вечер")
    }

    func testBehindSidewaysUnknownCourseOrVoicedStaySilent() {
        let target = spot(ahead: 300)
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [spot(ahead: -300)], situation: situation(), alreadyVoiced: []))
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [spot(ahead: 300, side: 250)], situation: situation(),
                                                alreadyVoiced: []))
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [target], situation: situation(course: -1), alreadyVoiced: []))
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [target], situation: situation(), alreadyVoiced: [target.key]))
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [target], situation: situation(trip: false), alreadyVoiced: []))
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [target], situation: situation(enabled: false), alreadyVoiced: []))
    }

    func testWarnDistanceGrowsWithSpeedWithinBounds() {
        XCTAssertEqual(TripodHabit.warnMeters(speedKmh: 20), AppConfig.tripodHabitWarnMinMeters)
        XCTAssertEqual(TripodHabit.warnMeters(speedKmh: 90), 625, accuracy: 1)
        XCTAssertEqual(TripodHabit.warnMeters(speedKmh: 150), AppConfig.tripodHabitWarnMaxMeters)
        XCTAssertNil(TripodHabit.spotToAnnounce(in: [spot(ahead: 600)], situation: situation(speed: 30),
                                                alreadyVoiced: []), "в городе 600 м — рано")
        XCTAssertNotNil(TripodHabit.spotToAnnounce(in: [spot(ahead: 600)], situation: situation(speed: 100),
                                                   alreadyVoiced: []))
    }

    func testPhraseSaysOftenNeverIs() {
        let target = spot(ahead: 300)
        XCTAssertEqual(TripodHabit.phrase(for: target, slowDown: false), "Здесь вечером часто стоит тренога")
        XCTAssertEqual(TripodHabit.phrase(for: target, slowDown: true), "Здесь вечером часто стоит тренога, сбавьте")
        for peak in 0...3 {
            XCTAssertTrue(TripodHabit.phrase(for: spot(ahead: 1, peak: peak), slowDown: false).contains("часто"))
        }
        XCTAssertEqual(TripodHabit.mapLabel(peak: 3), "чаще вечером")
        XCTAssertNil(TripodHabit.mapLabel(peak: -1))
    }

    func testOldPayloadStillDecodes() throws {
        let old = #"{"version":1,"spots":[{"lat":41.3,"lon":69.2,"n":3,"days":2,"peak":1}]}"#
        let decoded = try JSONDecoder().decode(TripodHotspots.self, from: Data(old.utf8))
        XCTAssertNil(decoded.spots[0].src)
        let new = #"{"version":1,"spots":[{"lat":41.3,"lon":69.2,"n":3,"days":2,"peak":1,"src":3,"pdays":2}]}"#
        XCTAssertEqual(try JSONDecoder().decode(TripodHotspots.self, from: Data(new.utf8)).spots[0].pdays, 2)
    }
}
