//
//  TrafficTimeTests.swift
//  RadarMapTests
//
//  Время в пробках (31E): ползли три минуты подряд — пробка; светофор —
//  нет; заезд в магазин (стоянка склейки) — нет; разрыв GPS — нет.
//

import XCTest
@testable import RadarMap

final class TrafficTimeTests: XCTestCase {
    private let t0 = 1_800_000_000.0

    /// Трек на север: точка каждые `step` м, время — по скоростям отрезков.
    private func track(_ segments: [(meters: Double, seconds: Double)])
        -> (points: [TrackPoint], times: [Double]) {
        var lat = 41.30, t = t0
        var points = [TrackPoint(lat: lat, lon: 69.28, speedKmh: 0)]
        var times = [t]
        for segment in segments {
            lat += segment.meters / 111_320
            t += segment.seconds
            points.append(TrackPoint(lat: lat, lon: 69.28, speedKmh: 0))
            times.append(t)
        }
        return (points, times)
    }

    func testCrawlForFourMinutesIsOneJam() {
        // 1 км бодро, потом 4 отрезка по 30 м за минуту (1,8 км/ч), снова бодро.
        let fast = (meters: 300.0, seconds: 20.0)
        let slow = (meters: 30.0, seconds: 60.0)
        let trip = track([fast, fast, fast, slow, slow, slow, slow, fast, fast])
        let jams = TrafficTime.jams(track: trip.points, times: trip.times, stops: [])
        XCTAssertEqual(jams.count, 1)
        XCTAssertEqual(jams[0].seconds, 240, accuracy: 0.1)
        XCTAssertEqual(jams[0].at.timeIntervalSince1970, t0 + 60, accuracy: 0.1)
        // Место — внутри медленного отрезка, а не в точке въезда в пробку.
        XCTAssertGreaterThan(jams[0].lat, 41.30 + 900 / 111_320)
    }

    func testTrafficLightIsNotAJam() {
        // Красный — 100 с стояния в одном отрезке: короче трёх минут.
        let trip = track([(300, 20), (30, 100), (300, 20)])
        XCTAssertEqual(TrafficTime.jams(track: trip.points, times: trip.times, stops: []), [])
    }

    func testShopStopIsNotAJam() {
        // Склейка: 20 минут «стоянки» в отрезке, который задевает TripStop.
        let trip = track([(300, 20), (30, 1200), (300, 20)])
        let stop = Date(timeIntervalSince1970: t0 + 30)...Date(timeIntervalSince1970: t0 + 1100)
        XCTAssertEqual(TrafficTime.jams(track: trip.points, times: trip.times, stops: [stop]), [],
                       "заезд в магазин посчитан пробкой")
        // Без стоянки это был бы разрыв (дольше 10 минут), тоже не пробка.
        XCTAssertEqual(TrafficTime.jams(track: trip.points, times: trip.times, stops: []), [])
    }

    func testUnknownTimesBreakTheRun() {
        // Склейка со старой записью: у первой ноги времени нет.
        var trip = track([(30, 60), (30, 60), (30, 60), (30, 60)])
        trip.times[2] = .nan
        XCTAssertEqual(TrafficTime.jams(track: trip.points, times: trip.times, stops: []), [],
                       "разрыв во времени склеил две половины в одну пробку")
    }

    func testMismatchedTimesMeanNoMeasurement() {
        let trip = track([(30, 60), (30, 60)])
        XCTAssertEqual(TrafficTime.jams(track: trip.points, times: Array(trip.times.dropLast()), stops: []), [])
    }

    func testCapKeepsLongestInTimeOrder() {
        var segments: [(meters: Double, seconds: Double)] = []
        for index in 0..<5 {
            segments += Array(repeating: (30, 60 + Double(index) * 10), count: 4)
            segments.append((500, 20))
        }
        let trip = track(segments)
        let jams = TrafficTime.jams(track: trip.points, times: trip.times, stops: [], maxCount: 2)
        XCTAssertEqual(jams.count, 2)
        XCTAssertLessThan(jams[0].at, jams[1].at)
        XCTAssertEqual(jams.map(\.seconds), [360, 400])
    }

    func testPeriodPlacesAndHours() {
        let calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()
        let morning = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400) + 8 * 3600)
        func record(_ jams: [TripJam]?) -> TripRecord {
            TripRecord(id: Double.random(in: 0...1e9), startedAt: morning, endedAt: morning + 3600,
                       distanceMeters: 10_000, maxSpeedKmh: 60, passed: [], jams: jams)
        }
        let here = TripJam(lat: 41.3100, lon: 69.2800, at: morning, seconds: 600)
        let nearby = TripJam(lat: 41.3105, lon: 69.2802, at: morning + 86_400, seconds: 300)
        let far = TripJam(lat: 41.40, lon: 69.40, at: morning + 10 * 3600, seconds: 200)
        let period = TrafficTime.period([record([here]), record([nearby, far]), record(nil), record([])],
                                        calendar: calendar)
        XCTAssertEqual(period.trips, 2, "поездки без пробок и без замера — не «поездки с пробками»")
        XCTAssertEqual(period.places.first?.times, 2)
        XCTAssertEqual(period.places.first?.seconds ?? 0, 900, accuracy: 0.1)
        XCTAssertEqual(period.places.count, 2)
        XCTAssertEqual(period.peakBlock?.index, 2, "08:00–12:00")
        XCTAssertEqual(period.peakBlock?.share ?? 0, 900.0 / 1100, accuracy: 0.001)
    }

    func testDayRollupFoldsAndUnfoldsJamsSymmetrically() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let measured = TripRecord(id: 1, startedAt: start, endedAt: start + 1800, distanceMeters: 5000,
                                  maxSpeedKmh: 60, passed: [],
                                  jams: [TripJam(lat: 41.3, lon: 69.2, at: start, seconds: 420)],
                                  overLimit: OverLimitTally(knownMeters: 4000, overMeters: 500))
        let old = TripRecord(id: 2, startedAt: start + 3600, endedAt: start + 5400, distanceMeters: 5000,
                             maxSpeedKmh: 60, passed: [])
        var days = TripDayBook.folded(old, into: [])
        XCTAssertNil(days[0].jamSeconds, "день до обновления — «не мерили», а не ноль")
        days = TripDayBook.folded(measured, into: days)
        XCTAssertEqual(days[0].jamSeconds ?? 0, 420, accuracy: 0.1)
        XCTAssertEqual(days[0].limitKnownMeters ?? 0, 4000, accuracy: 0.1)
        XCTAssertEqual(days[0].overLimitMeters ?? 0, 500, accuracy: 0.1)
        days = TripDayBook.unfolded(measured, from: days)
        XCTAssertEqual(days[0].jamSeconds ?? -1, 0, accuracy: 0.1)
        XCTAssertEqual(days[0].overLimitMeters ?? -1, 0, accuracy: 0.1)
        let interval = DateInterval(start: start - 86_400, duration: 3 * 86_400)
        XCTAssertEqual(TripDayBook.summary(TripDayBook.folded(measured, into: days), in: interval).jamSeconds ?? 0,
                       420, accuracy: 0.1)
        XCTAssertNil(TripDayBook.summary(TripDayBook.folded(old, into: []), in: interval).jamSeconds)
    }

    func testMergeAndSplitCarryJams() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TripRecord(id: 1, startedAt: start, endedAt: start + 1800, distanceMeters: 5000,
                               maxSpeedKmh: 60, passed: [], endLat: 41.302, endLon: 69.2,
                               track: [41.300, 69.2, 40, 41.301, 69.2, 40, 41.302, 69.2, 40],
                               jams: [TripJam(lat: 41.3, lon: 69.2, at: start + 600, seconds: 300)],
                               overLimit: OverLimitTally(knownMeters: 4000, overMeters: 400))
        let second = TripRecord(id: 2, startedAt: start + 2400, endedAt: start + 4200, distanceMeters: 5000,
                                maxSpeedKmh: 60, passed: [],
                                track: [41.302, 69.2, 40, 41.303, 69.2, 40, 41.304, 69.2, 40],
                                jams: [TripJam(lat: 41.4, lon: 69.3, at: start + 3000, seconds: 200)],
                                overLimit: OverLimitTally(knownMeters: 3000, overMeters: 0))
        let merged = TripMerge.merged(previous: first, next: second)
        XCTAssertEqual(merged.jamSeconds ?? 0, 500, accuracy: 0.1, "пауза между ногами стала пробкой или пропала")
        XCTAssertEqual(merged.overLimit?.knownMeters ?? 0, 7000, accuracy: 0.1)
        let oldLeg = TripRecord(id: 3, startedAt: start + 2400, endedAt: start + 4200, distanceMeters: 5000,
                                maxSpeedKmh: 60, passed: [])
        XCTAssertNil(TripMerge.merged(previous: first, next: oldLeg).jams,
                     "склейка с немерянной ногой — неполная сумма под видом полной")

        guard let stop = merged.stops?.first else { return XCTFail("нет стоянки склейки") }
        let legs = TripHistory.split(merged, at: stop)
        XCTAssertEqual(legs.count, 2)
        XCTAssertEqual(legs[1].jamSeconds ?? 0, 300, accuracy: 0.1)
        XCTAssertEqual(legs[0].jamSeconds ?? 0, 200, accuracy: 0.1)
    }
}
