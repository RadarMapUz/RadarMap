//
//  RouteTimelineTests.swift
//  RadarMapTests
//
//  Остаток времени — по длительностям шагов OSRM, а не долей расстояния
//  (76). Что проверяется: трасса + город — в городском хвосте остаток больше
//  линейной доли, на трассе меньше; на старте — ровно время варианта; без
//  длительностей — прежняя линейная доля.
//

import MapKit
import XCTest
@testable import RadarMap

@MainActor
final class RouteTimelineTests: XCTestCase {

    /// 90 км трассы за 54 мин (100 км/ч) и 10 км города за 20 мин (30 км/ч).
    private let highwayCity = RouteTimeline(starts: [0, 90_000, 100_000], durations: [3240, 1200, 0],
                                            length: 100_000)

    private func variant(timeline: RouteTimeline?, pace: Double = 1) -> RouteService.Variant {
        let points = [MKMapPoint(CLLocationCoordinate2D(latitude: 41.0, longitude: 69.0)),
                      MKMapPoint(CLLocationCoordinate2D(latitude: 41.9, longitude: 69.0))]
        var v = RouteService.Variant(id: 0, points: points, polyline: MKPolyline(points: points, count: 2),
                                     distance: 100_000, travelTime: 4440, cameras: [], steps: [])
        v.timeline = timeline
        v.paceFactor = pace
        return v
    }

    func testCityTailIsLongerThanItsShareOfDistance() throws {
        let timeline = try XCTUnwrap(highwayCity)
        // Въехали в город: осталось 10 % пути, но 20 минут из 74.
        XCTAssertEqual(timeline.remainingShare(after: 90_000) * 4440, 1200, accuracy: 0.001)
        XCTAssertGreaterThan(timeline.remainingShare(after: 90_000), 0.1 * 2.5)
        // Середина города — половина городского времени.
        XCTAssertEqual(timeline.remainingShare(after: 95_000) * 4440, 600, accuracy: 0.001)
        // Середина трассы: линейная доля дала бы 37 мин, по шагам — 47.
        XCTAssertEqual(timeline.remainingShare(after: 45_000) * 4440, 1620 + 1200, accuracy: 0.001)
        XCTAssertEqual(timeline.remainingShare(after: 100_000), 0)
        XCTAssertEqual(timeline.remainingShare(after: 150_000), 0, "за концом линии — ноль, не минус")
    }

    func testStartIsExactlyTheVariantTime() {
        let v = variant(timeline: highwayCity, pace: 1.12)
        XCTAssertEqual(RouteService.remainingEstimate(v, remainingDistance: v.distance, liveDelay: 120,
                                                      typicalDelay: 60),
                       v.travelTime * 1.12 + 180)
        XCTAssertEqual(highwayCity?.remainingShare(after: 0), 1)
        XCTAssertEqual(highwayCity?.remainingShare(after: -50), 1)
    }

    func testRemainingEstimateUsesStepTimesWithPaceAndDelays() {
        let v = variant(timeline: highwayCity, pace: 1.1)
        let tail = RouteService.remainingEstimate(v, remainingDistance: 10_000, liveDelay: 90, typicalDelay: 30)
        XCTAssertEqual(tail, 1200 * 1.1 + 120, accuracy: 0.001)
        let linear = RouteService.remainingEstimate(variant(timeline: nil, pace: 1.1), remainingDistance: 10_000,
                                                    liveDelay: 90, typicalDelay: 30)
        XCTAssertEqual(linear, 444 * 1.1 + 120, accuracy: 0.001, "без длительностей — прежняя доля расстояния")
        XCTAssertGreaterThan(tail, linear)
    }

    func testNoDurationsMeansNoTimeline() {
        XCTAssertNil(RouteTimeline(starts: [0, 500], durations: [60, nil], length: 1000))
        XCTAssertNil(RouteTimeline(starts: [0, 500], durations: [0, 0], length: 1000), "нулевое время — нечего делить")
        XCTAssertNil(RouteTimeline(starts: [], durations: [], length: 1000))
        XCTAssertNil(RouteTimeline(starts: [0], durations: [60], length: 0))
        XCTAssertNil(RouteTimeline(starts: [0, 500], durations: [60, -5], length: 1000))
        XCTAssertEqual(RouteTimeline.remainingShare(nil, distance: 1000, remainingDistance: 250), 0.25)
        XCTAssertEqual(RouteTimeline.remainingShare(nil, distance: 0, remainingDistance: 250), 0)
    }

    func testBrokenStartsStayMonotonic() throws {
        // Начало шага раньше предыдущего и за концом линии — узлы не убывают.
        let timeline = try XCTUnwrap(RouteTimeline(starts: [0, 600, 400, 5000], durations: [60, 60, 60, 0],
                                                   length: 1000))
        XCTAssertEqual(timeline.along, [0, 600, 600, 1000, 1000])
        var previous = 1.0
        for meters in stride(from: 0.0, through: 1000, by: 50) {
            let share = timeline.remainingShare(after: meters)
            XCTAssertLessThanOrEqual(share, previous)
            previous = share
        }
    }

    func testStepDurationIsDecoded() throws {
        let json = #"{"distance": 120.5, "duration": 14.2, "name": "A", "maneuver": {"type": "turn", "modifier": "left"}}"#
        let step = try JSONDecoder().decode(RouteService.OSRMResponse.Step.self, from: Data(json.utf8))
        XCTAssertEqual(step.duration, 14.2)
        let bare = #"{"distance": 120.5, "name": "A", "maneuver": {"type": "turn"}}"#
        XCTAssertNil(try JSONDecoder().decode(RouteService.OSRMResponse.Step.self, from: Data(bare.utf8)).duration)
    }
}
