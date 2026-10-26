//
//  OverLimitTests.swift
//  RadarMapTests
//
//  Выше лимита вне камер (31E): путь у камеры не считается, неизвестный
//  лимит — не «в лимите», короткий разгон идёт в долю, но не в места.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class OverLimitTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    func testShareCountsOnlyKnownLimitAwayFromCameras() {
        var meter = OverLimitMeter()
        // 1 км в лимите, 300 м на 15 выше, 200 м без лимита, 500 м выше у камеры.
        for _ in 0..<10 { meter.step(meters: 100, speedKmh: 55, limitKmh: 60, atCamera: false, coordinate: here, at: t) }
        for _ in 0..<3 { meter.step(meters: 100, speedKmh: 75, limitKmh: 60, atCamera: false, coordinate: here, at: t) }
        for _ in 0..<2 { meter.step(meters: 100, speedKmh: 90, limitKmh: nil, atCamera: false, coordinate: here, at: t) }
        for _ in 0..<5 { meter.step(meters: 100, speedKmh: 95, limitKmh: 60, atCamera: true, coordinate: here, at: t) }
        let tally = meter.finish()
        XCTAssertEqual(tally.knownMeters, 1300, accuracy: 0.1, "путь у камеры или без лимита попал в знаменатель")
        XCTAssertEqual(tally.overMeters, 300, accuracy: 0.1)
        XCTAssertEqual(tally.runs.count, 1)
        XCTAssertEqual(tally.runs[0].meters, 300, accuracy: 0.1)
        XCTAssertEqual(tally.runs[0].limitKmh, 60)
        XCTAssertEqual(tally.runs[0].maxKmh, 75)
    }

    func testMarginIsTenKmh() {
        var meter = OverLimitMeter()
        meter.step(meters: 500, speedKmh: 69, limitKmh: 60, atCamera: false, coordinate: here, at: t)
        XCTAssertEqual(meter.finish().overMeters, 0, "+9 км/ч — шум спидометра и знака, не превышение")
    }

    func testShortBurstGoesToShareButNotToPlaces() {
        var meter = OverLimitMeter()
        meter.step(meters: 60, speedKmh: 90, limitKmh: 60, atCamera: false, coordinate: here, at: t)
        meter.step(meters: 500, speedKmh: 50, limitKmh: 60, atCamera: false, coordinate: here, at: t)
        let tally = meter.finish()
        XCTAssertEqual(tally.overMeters, 60, accuracy: 0.1)
        XCTAssertEqual(tally.runs, [], "обгон в 60 м стал «местом»")
    }

    func testLimitChangeStartsNewRun() {
        var meter = OverLimitMeter()
        meter.step(meters: 200, speedKmh: 80, limitKmh: 60, atCamera: false, coordinate: here, at: t)
        meter.step(meters: 200, speedKmh: 60, limitKmh: 40, atCamera: false, coordinate: here, at: t + 10)
        XCTAssertEqual(meter.finish().runs.map(\.limitKmh), [60, 40])
    }

    func testResumeContinuesTheTally() {
        let base = OverLimitTally(knownMeters: 1000, overMeters: 200,
                                  runs: [OverLimitRun(lat: 41.3, lon: 69.2, at: t, meters: 200, limitKmh: 60, maxKmh: 80)])
        var meter = OverLimitMeter(resuming: base)
        meter.step(meters: 100, speedKmh: 50, limitKmh: 60, atCamera: false, coordinate: here, at: t + 600)
        let tally = meter.finish()
        XCTAssertEqual(tally.knownMeters, 1100, accuracy: 0.1)
        XCTAssertEqual(tally.runs.count, 1, "склейка потеряла участки первой ноги")
    }

    func testShareNeedsEnoughKnownRoad() {
        XCTAssertNil(OverLimit.share(over: 100, known: 1000), "1 км с лимитом — не доля пути")
        XCTAssertEqual(OverLimit.share(over: 600, known: 10_000) ?? 0, 0.06, accuracy: 0.0001)
    }

    func testPlacesRankByTimesThenMeters() {
        func record(_ runs: [OverLimitRun]) -> TripRecord {
            TripRecord(id: Double.random(in: 0...1e9), startedAt: t, endedAt: t + 1800, distanceMeters: 10_000,
                       maxSpeedKmh: 80, passed: [], overLimit: OverLimitTally(knownMeters: 9000, overMeters: 1000, runs: runs))
        }
        let daily = OverLimitRun(lat: 41.3100, lon: 69.2800, at: t, meters: 150, limitKmh: 60, maxKmh: 78)
        let highway = OverLimitRun(lat: 41.50, lon: 69.60, at: t, meters: 4000, limitKmh: 100, maxKmh: 125)
        let places = OverLimit.places([record([daily, highway]), record([daily]), record([daily])])
        XCTAssertEqual(places.first?.times, 3, "одна длинная трасса важнее ежедневной улицы")
        XCTAssertEqual(places.first?.limitKmh, 60)
        XCTAssertEqual(places.count, 2)
    }

    func testLegSplitsRunsByTime() {
        let tally = OverLimitTally(knownMeters: 2000, overMeters: 700, runs: [
            OverLimitRun(lat: 41.3, lon: 69.2, at: t, meters: 300, limitKmh: 60, maxKmh: 80),
            OverLimitRun(lat: 41.4, lon: 69.3, at: t + 3000, meters: 200, limitKmh: 60, maxKmh: 80),
        ])
        let head = tally.leg(share: 0.5) { $0 < t + 1000 }
        let tail = tally.leg(share: 0.5) { $0 >= t + 1000 }
        XCTAssertEqual(head.runs.count, 1)
        XCTAssertEqual(head.overMeters + tail.overMeters, 700, accuracy: 0.1, "разделение потеряло метры")
        XCTAssertEqual(head.knownMeters + tail.knownMeters, 2000, accuracy: 0.1)
    }
}
