//
//  LaneNoticeTests.swift
//  RadarMapTests
//
//  Ограничения полос на проездах прямо: «крайний правый — только направо».
//

import XCTest
@testable import RadarMap

final class LaneNoticeTests: XCTestCase {

    private typealias R = RouteService.OSRMResponse

    private func lane(_ indications: [String], valid: Bool) -> R.Lane {
        R.Lane(valid: valid, indications: indications)
    }

    /// Шаг из (41.30, 69.25) на север: перекрёсток в ~111 м на (41.301, 69.25).
    private func step(type: String = "new name", first: [R.Lane]?, second: [R.Lane]?) -> R.Step {
        R.Step(distance: 500, name: "",
               maneuver: R.Maneuver(type: type, modifier: nil, exit: nil, location: [69.25, 41.30]),
               intersections: [R.Intersection(lanes: first, location: [69.25, 41.30]),
                               R.Intersection(lanes: second, location: [69.25, 41.301])])
    }

    private let rightTurnOnly = [
        RouteService.OSRMResponse.Lane(valid: true, indications: ["straight"]),
        RouteService.OSRMResponse.Lane(valid: true, indications: ["straight"]),
        RouteService.OSRMResponse.Lane(valid: false, indications: ["right"]),
    ]

    func testThroughIntersectionWithTurnOnlyLaneIsANotice() {
        let notices = RouteService.laneNotices(step(first: nil, second: rightTurnOnly), at: 1000,
                                               isManeuver: true)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].distanceAlong, 1111, accuracy: 3)
        XCTAssertEqual(LaneAdvice.phrase(notices[0].lanes), String(localized: "Из любого ряда, кроме правого"))
    }

    func testFirstIntersectionOfAManeuverStepIsTheManeuverItself() {
        let notices = RouteService.laneNotices(step(type: "turn", first: rightTurnOnly, second: nil),
                                               at: 0, isManeuver: true)
        XCTAssertTrue(notices.isEmpty, "ряд манёвра уже в RouteStep")
        let passing = RouteService.laneNotices(step(first: rightTurnOnly, second: nil), at: 0, isManeuver: false)
        XCTAssertEqual(passing.count, 1, "у шага без манёвра первый перекрёсток — тоже проезд")
    }

    func testRowWhereEveryLaneFitsSaysNothing() {
        let all = [lane(["straight"], valid: true), lane(["straight", "right"], valid: true)]
        XCTAssertTrue(RouteService.laneNotices(step(first: nil, second: all), at: 0, isManeuver: true).isEmpty)
    }

    func testIncompleteRowIsDroppedNotGuessed() {
        let broken = [lane(["straight"], valid: true), lane(["чушь"], valid: false)]
        XCTAssertTrue(RouteService.laneNotices(step(first: nil, second: broken), at: 0, isManeuver: true).isEmpty)
    }

    func testNoticeNeverLiesBeyondItsStep() {
        var far = step(first: nil, second: rightTurnOnly)
        far = R.Step(distance: 50, name: "", maneuver: far.maneuver, intersections: far.intersections)
        let notices = RouteService.laneNotices(far, at: 0, isManeuver: true)
        XCTAssertEqual(notices.first?.distanceAlong ?? 0, 50, accuracy: 0.001)
    }
}
