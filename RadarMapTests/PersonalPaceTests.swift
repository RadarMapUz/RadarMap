//
//  PersonalPaceTests.swift
//  RadarMapTests
//
//  Личный темп (33E, docs/spec_traffic_33.md): мало данных → 1,0; обрезка
//  0,85…1,15; пробочные проезды исключены; класс дороги без своих данных →
//  общий коэффициент. Плюс сам сбор: проезд по варианту маршрута.
//

import XCTest
@testable import RadarMap

final class PersonalPaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_792_954_800)

    private func sample(_ ratio: Double, km: Double = 10, roadClass: PersonalPace.RoadClass = .city,
                        jam: Bool = false, daysAgo: Double = 1) -> PersonalPace.Sample {
        PersonalPace.Sample(date: now.addingTimeInterval(-daysAgo * 86400), roadClass: roadClass,
                            meters: km * 1000, ownSeconds: 600 * ratio, flowSeconds: 600, jam: jam)
    }

    func testTooLittleDataIsNeutral() {
        let few = (0..<4).map { _ in sample(0.9) }             // 40 км < 50
        XCTAssertEqual(PersonalPace.coefficients(few, now: now), .neutral)
        XCTAssertEqual(PersonalPace.coefficients([], now: now).factor(for: .city), 1)
    }

    func testMedianOfEnoughData() {
        let samples = [0.9, 0.92, 0.95, 0.94, 0.93, 2.5].map { sample($0) }   // 2,5 — заезд в магазин
        let got = PersonalPace.coefficients(samples, now: now)
        XCTAssertEqual(got.overall, 0.93, accuracy: 0.001, "медиана пяти разумных; стоянка по пути отброшена")
    }

    func testClippedToFifteenPercent() {
        let fast = (0..<6).map { _ in sample(0.6) }
        XCTAssertEqual(PersonalPace.coefficients(fast, now: now).overall, 0.85)
        let slow = (0..<6).map { _ in sample(1.6) }
        XCTAssertEqual(PersonalPace.coefficients(slow, now: now).overall, 1.15)
    }

    func testJamTripsAreExcluded() {
        let jams = (0..<6).map { _ in sample(1.5, jam: true) }
        XCTAssertEqual(PersonalPace.coefficients(jams, now: now), .neutral, "пробка — не манера езды")
        let mixed = jams + (0..<6).map { _ in sample(0.9) }
        XCTAssertEqual(PersonalPace.coefficients(mixed, now: now).overall, 0.9, accuracy: 0.001)
    }

    func testClassWithoutOwnDataFallsBackToOverall() {
        let city = (0..<6).map { _ in sample(0.9, roadClass: .city) }
        let highway = [sample(1.1, km: 20, roadClass: .highway)]   // 20 км трассы — мало
        let got = PersonalPace.coefficients(city + highway, now: now)
        XCTAssertEqual(got.factor(for: .city), 0.9, accuracy: 0.001)
        XCTAssertEqual(got.factor(for: .highway), got.overall, "своих 50 км трассы нет — общий")
        XCTAssertEqual(got.factor(for: nil), got.overall)
    }

    func testOldSamplesLeaveTheWindow() {
        let old = (0..<6).map { _ in sample(0.9, daysAgo: 31) }
        XCTAssertEqual(PersonalPace.coefficients(old, now: now), .neutral)
        let kept = PersonalPace.appending(sample(0.9), to: old, now: now)
        XCTAssertEqual(kept.count, 1, "в хранилище — только окно 30 дней")
    }

    func testRoadClassBySpeed() {
        XCTAssertEqual(PersonalPace.roadClass(distance: 10_000, travelTime: 900), .city)        // 40 км/ч
        XCTAssertEqual(PersonalPace.roadClass(distance: 100_000, travelTime: 4000), .highway)   // 90 км/ч
    }

    func testTrackerClosesOneSamplePerVariant() {
        var tracker = PersonalPace.Tracker()
        let first = PersonalPace.Tracker.Variant(id: 1, distance: 10_000, travelTime: 900, trafficDelay: 0)
        XCTAssertNil(tracker.note(first, along: 0, at: now))
        XCTAssertNil(tracker.note(first, along: 5_000, at: now.addingTimeInterval(400)))
        // Перестроение — новый вариант: прежний проезд закрыт наблюдением.
        let second = PersonalPace.Tracker.Variant(id: 2, distance: 6_000, travelTime: 500, trafficDelay: 120)
        let closed = tracker.note(second, along: 0, at: now.addingTimeInterval(410))
        let sample = try? XCTUnwrap(closed)
        XCTAssertEqual(sample?.meters, 5_000)
        XCTAssertEqual(sample?.ownSeconds, 400)
        XCTAssertEqual(sample?.flowSeconds ?? 0, 450, accuracy: 0.001)
        XCTAssertEqual(sample?.jam, false)
        XCTAssertNil(tracker.note(second, along: 3_000, at: now.addingTimeInterval(700)))
        let last = tracker.finish()
        XCTAssertEqual(last?.jam, true, "задержка 120 с на 500 с графа — пробка")
        XCTAssertNil(tracker.finish(), "закрыто — второй раз пусто")
    }

    func testShortRideIsNotASample() {
        var tracker = PersonalPace.Tracker()
        let variant = PersonalPace.Tracker.Variant(id: 1, distance: 10_000, travelTime: 900, trafficDelay: nil)
        _ = tracker.note(variant, along: 0, at: now)
        _ = tracker.note(variant, along: 1_500, at: now.addingTimeInterval(120))
        XCTAssertNil(tracker.finish(), "1,5 км — светофоры решают больше манеры")
    }
}
