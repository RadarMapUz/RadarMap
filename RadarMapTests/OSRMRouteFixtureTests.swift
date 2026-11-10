//
//  OSRMRouteFixtureTests.swift
//  RadarMapTests
//
//  Полный ответ OSRM route v5 (76), составлен руками: два варианта, шаги с
//  maneuver/intersections, одно кольцо. Разбор целиком — шаги, позиции
//  манёвров по линии и остаток времени по длительностям шагов.
//

import MapKit
import XCTest
@testable import RadarMap

final class OSRMRouteFixtureTests: XCTestCase {

    /// Вариант 1: на восток по Амира Темура, налево на Навои, кольцо (2-й
    /// съезд), на север до цели. Вариант 2: на север, направо, до цели.
    /// Длины шагов чуть расходятся с линией — как у настоящего OSRM.
    private static let fixture = """
    {
      "code": "Ok",
      "routes": [
        {
          "distance": 2201.1,
          "duration": 170,
          "geometry": {
            "type": "LineString",
            "coordinates": [[69.24, 41.30], [69.245, 41.30], [69.25, 41.30], [69.25, 41.305], [69.25, 41.306],
                            [69.2505, 41.3065], [69.25, 41.307], [69.25, 41.312]]
          },
          "legs": [
            {
              "distance": 2201.1,
              "duration": 170,
              "steps": [
                {
                  "distance": 838.2, "duration": 60, "name": "Amir Temur shoh ko'chasi",
                  "maneuver": {"type": "depart", "location": [69.24, 41.30], "bearing_before": 0, "bearing_after": 90},
                  "intersections": [{"location": [69.24, 41.30], "bearings": [90], "entry": [true], "out": 0}]
                },
                {
                  "distance": 665.0, "duration": 50, "name": "Navoiy ko'chasi",
                  "maneuver": {"type": "turn", "modifier": "left", "location": [69.25, 41.30],
                               "bearing_before": 90, "bearing_after": 0},
                  "intersections": [{
                    "location": [69.25, 41.30], "bearings": [0, 90, 180, 270], "entry": [true, true, true, false],
                    "in": 3, "out": 0,
                    "lanes": [{"valid": true, "indications": ["left"]}, {"valid": false, "indications": ["straight"]},
                              {"valid": false, "indications": ["straight", "right"]}]
                  }]
                },
                {
                  "distance": 141.5, "duration": 20, "name": "",
                  "maneuver": {"type": "roundabout", "modifier": "straight", "exit": 2, "location": [69.25, 41.306],
                               "bearing_before": 0, "bearing_after": 35},
                  "intersections": [{"location": [69.25, 41.306], "bearings": [35, 180], "entry": [true, false],
                                     "in": 1, "out": 0}]
                },
                {
                  "distance": 556.4, "duration": 40, "name": "Navoiy ko'chasi",
                  "maneuver": {"type": "exit roundabout", "modifier": "straight", "exit": 2,
                               "location": [69.25, 41.307], "bearing_before": 325, "bearing_after": 0},
                  "intersections": [{"location": [69.25, 41.307], "bearings": [0, 145], "entry": [true, false],
                                     "in": 1, "out": 0}]
                },
                {
                  "distance": 0, "duration": 0, "name": "Navoiy ko'chasi",
                  "maneuver": {"type": "arrive", "location": [69.25, 41.312], "bearing_before": 0, "bearing_after": 0},
                  "intersections": [{"location": [69.25, 41.312], "bearings": [180], "entry": [true], "in": 0}]
                }
              ]
            }
          ]
        },
        {
          "distance": 2172.4,
          "duration": 175,
          "geometry": {
            "type": "LineString",
            "coordinates": [[69.24, 41.30], [69.24, 41.306], [69.24, 41.312], [69.245, 41.312], [69.25, 41.312]]
          },
          "legs": [
            {
              "distance": 2172.4,
              "duration": 175,
              "steps": [
                {
                  "distance": 1336.0, "duration": 100, "name": "Shota Rustaveli ko'chasi",
                  "maneuver": {"type": "depart", "location": [69.24, 41.30], "bearing_before": 0, "bearing_after": 0},
                  "intersections": [{"location": [69.24, 41.30], "bearings": [0], "entry": [true], "out": 0}]
                },
                {
                  "distance": 836.4, "duration": 75, "name": "Bobur ko'chasi",
                  "maneuver": {"type": "turn", "modifier": "right", "location": [69.24, 41.312],
                               "bearing_before": 0, "bearing_after": 90},
                  "intersections": [{"location": [69.24, 41.312], "bearings": [90, 180, 270], "entry": [true, false, true],
                                     "in": 1, "out": 0}]
                },
                {
                  "distance": 0, "duration": 0, "name": "Bobur ko'chasi",
                  "maneuver": {"type": "arrive", "location": [69.25, 41.312], "bearing_before": 90, "bearing_after": 0},
                  "intersections": [{"location": [69.25, 41.312], "bearings": [270], "entry": [true], "in": 0}]
                }
              ]
            }
          ]
        }
      ],
      "waypoints": [
        {"name": "Amir Temur shoh ko'chasi", "location": [69.24, 41.30]},
        {"name": "Navoiy ko'chasi", "location": [69.25, 41.312]}
      ]
    }
    """

    private func parsed() async throws -> [RouteService.BuiltVariant] {
        let data = try XCTUnwrap(Self.fixture.data(using: .utf8))
        let variants = await RouteService.parseOSRM(data, language: "ru", stopName: nil)
        return try XCTUnwrap(variants)
    }

    private func lineLength(_ variant: RouteService.BuiltVariant) -> CLLocationDistance {
        RouteService.cumulative(of: variant.points).last ?? 0
    }

    func testBothVariantsParsedWithTheirManeuvers() async throws {
        let variants = try await parsed()
        XCTAssertEqual(variants.count, 2)
        // depart и exit roundabout молчат: поворот, кольцо, прибытие.
        XCTAssertEqual(variants[0].steps.map(\.kind), [.left, .roundabout, .arrive])
        XCTAssertEqual(variants[0].steps[1].text, String(format: String(localized: "на кольце %lld-й съезд"), 2))
        XCTAssertEqual(variants[0].steps[0].lanes.count, 3, "полосы поворота дошли до шага")
        XCTAssertEqual(variants[1].steps.map(\.kind), [.right, .arrive])
        XCTAssertEqual(variants[0].travelTime, 170)
        XCTAssertEqual(variants[1].travelTime, 175)
    }

    func testManeuverPositionsAreMonotonicAndOnTheLine() async throws {
        for variant in try await parsed() {
            let length = lineLength(variant)
            let positions = variant.steps.map(\.distanceAlong)
            XCTAssertEqual(positions, positions.sorted(), "манёвры по порядку линии")
            for along in positions {
                XCTAssertGreaterThanOrEqual(along, 0)
                XCTAssertLessThanOrEqual(along, length + 0.5)
            }
            XCTAssertEqual(try XCTUnwrap(positions.last), length, accuracy: 1, "прибытие — конец линии")
        }
    }

    /// Поворот — на своей вершине линии, а не на сумме длин шагов (838,2 м).
    func testTurnSitsOnItsVertex() async throws {
        let first = try await parsed()[0]
        let cumulative = RouteService.cumulative(of: first.points)
        XCTAssertEqual(first.steps[0].distanceAlong, cumulative[2], accuracy: 0.5)
        XCTAssertEqual(first.steps[1].distanceAlong, cumulative[4], accuracy: 0.5)
    }

    func testRemainingTimeFollowsStepDurations() async throws {
        for variant in try await parsed() {
            let timeline = try XCTUnwrap(variant.timeline)
            let start = variant.travelTime * RouteTimeline.remainingShare(
                timeline, distance: variant.distance, remainingDistance: variant.distance)
            XCTAssertEqual(start, variant.travelTime, accuracy: 0.5, "на старте — всё время варианта")
            let end = variant.travelTime * RouteTimeline.remainingShare(
                timeline, distance: variant.distance, remainingDistance: 0)
            XCTAssertEqual(end, 0, accuracy: 0.5, "у цели — ноль")
        }
        // После первого шага (60 с из 170) осталось 110 с, а не доля расстояния.
        let first = try await parsed()[0]
        let timeline = try XCTUnwrap(first.timeline)
        let afterTurn = timeline.remainingShare(after: first.steps[0].distanceAlong) * first.travelTime
        XCTAssertEqual(afterTurn, 110, accuracy: 1)
    }
}
