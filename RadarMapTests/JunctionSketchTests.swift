//
//  JunctionSketchTests.swift
//  RadarMapTests
//
//  Схема развязки: подъезд снизу, съезд в свою сторону, окно вокруг узла.
//

import CoreGraphics
import CoreLocation
import XCTest
@testable import RadarMap

final class JunctionSketchTests: XCTestCase {

    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// На север 300 м, затем направо (на восток) 300 м; манёвр — в углу.
    private var rightTurn: [CLLocationCoordinate2D] { [c(41.3000, 69.2400), c(41.3027, 69.2400), c(41.3027, 69.2436)] }

    func testApproachFromBelowExitToTheRight() throws {
        let plan = try XCTUnwrap(JunctionSketch.plan(route: rightTurn, maneuverAlong: 300, roads: []))
        let anchor = CGPoint(x: plan.size.width * JunctionSketch.anchor.x,
                             y: plan.size.height * JunctionSketch.anchor.y)
        let first = try XCTUnwrap(plan.path.first), last = try XCTUnwrap(plan.path.last)
        XCTAssertGreaterThan(first.y, anchor.y + 20, "подъезд — снизу")
        XCTAssertEqual(first.x, anchor.x, accuracy: 2, "подъезд — по центру")
        XCTAssertGreaterThan(last.x, anchor.x + 20, "съезд — направо")
        XCTAssertEqual(last.y, anchor.y, accuracy: 3)
    }

    func testRotatesWithTheApproach() throws {
        // Тот же поворот, но едем на восток и поворачиваем направо (на юг):
        // на схеме подъезд всё равно снизу, съезд — вправо.
        let route = [c(41.3000, 69.2400), c(41.3000, 69.2436), c(41.2973, 69.2436)]
        let plan = try XCTUnwrap(JunctionSketch.plan(route: route, maneuverAlong: 300, roads: []))
        let anchor = CGPoint(x: plan.size.width * JunctionSketch.anchor.x,
                             y: plan.size.height * JunctionSketch.anchor.y)
        XCTAssertGreaterThan(try XCTUnwrap(plan.path.first).y, anchor.y + 20)
        XCTAssertGreaterThan(try XCTUnwrap(plan.path.last).x, anchor.x + 20)
    }

    func testOnlyRoadsAroundTheJunctionAreDrawn() throws {
        let crossing = [c(41.3027, 69.2380), c(41.3027, 69.2420)]   // поперечная у самого узла
        let far = [c(41.3200, 69.2500), c(41.3210, 69.2510)]        // за 2 км
        let plan = try XCTUnwrap(JunctionSketch.plan(route: rightTurn, maneuverAlong: 300,
                                                     roads: [crossing, far]))
        XCTAssertEqual(plan.roads.count, 1)
    }

    func testExitArrowStaysInsideTheImage() throws {
        // Прямой проезд: съезд вверх — стрелка не должна уехать за кадр.
        let straight = [c(41.3000, 69.2400), c(41.3060, 69.2400)]
        let plan = try XCTUnwrap(JunctionSketch.plan(route: straight, maneuverAlong: 300, roads: []))
        XCTAssertGreaterThan(try XCTUnwrap(plan.path.last).y, 5)
    }

    func testNoPlanWithoutARoute() {
        XCTAssertNil(JunctionSketch.plan(route: [c(41.3, 69.24)], maneuverAlong: 0, roads: []))
    }

    func testRenderedImageFitsTheCarPlayLimit() throws {
        let plan = try XCTUnwrap(JunctionSketch.plan(route: rightTurn, maneuverAlong: 300,
                                                     roads: [[c(41.3027, 69.2380), c(41.3027, 69.2420)]]))
        let image = CarPlayGuidance.junctionImage(plan, onDark: true)
        XCTAssertLessThanOrEqual(image.size.width, 140)
        XCTAssertLessThanOrEqual(image.size.height, 100)
        XCTAssertNotNil(image.cgImage)
    }
}
