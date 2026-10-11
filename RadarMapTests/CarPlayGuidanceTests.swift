//
//  CarPlayGuidanceTests.swift
//  RadarMapTests
//
//  Перевод маршрута в навигационную сессию CarPlay: полосы, тип манёвра,
//  оценки. Сама сессия живёт только в машине — здесь проверяется то, что
//  ей отдаётся.
//

import CarPlay
import XCTest
@testable import RadarMap

final class CarPlayGuidanceTests: XCTestCase {

    func testLanesHighlightOnlyTheWayWeGo() {
        // «налево на Шарафа Рашидова»: [налево ✓, прямо+налево ✓, прямо ✗, направо ✗]
        let hints = [LaneHint(arrows: [.left], isValid: true),
                     LaneHint(arrows: [.straight, .left], isValid: true),
                     LaneHint(arrows: [.straight], isValid: false),
                     LaneHint(arrows: [.right], isValid: false)]
        let lanes = CarPlayGuidanceMapping.lanes(hints, kind: .left)
        XCTAssertEqual(lanes[0], .init(angles: [], highlighted: -90))
        XCTAssertEqual(lanes[1], .init(angles: [0], highlighted: -90),
                       "на «прямо и налево» подсвечено налево — туда, куда манёвр")
        XCTAssertEqual(lanes[2], .init(angles: [0], highlighted: nil))
        XCTAssertEqual(lanes[3], .init(angles: [90], highlighted: nil))
        XCTAssertTrue(CarPlayGuidanceMapping.isUseful(lanes))
    }

    func testHighlightedAngleIsNeverRepeatedInAngles() {
        let lanes = CarPlayGuidanceMapping.lanes([LaneHint(arrows: [.right, .right, .straight], isValid: true)],
                                                 kind: .right)
        XCTAssertEqual(lanes, [.init(angles: [0], highlighted: 90)], "так требует CPLane")
    }

    func testRowWithNothingToChooseIsNotShown() {
        let allGood = CarPlayGuidanceMapping.lanes([LaneHint(arrows: [.straight], isValid: true),
                                                    LaneHint(arrows: [.straight], isValid: true)], kind: .straight)
        XCTAssertFalse(CarPlayGuidanceMapping.isUseful(allGood))
        XCTAssertFalse(CarPlayGuidanceMapping.isUseful([]))
    }

    func testLeftIsNegativeRightIsPositive() {
        for arrow in [LaneArrow.slightLeft, .left, .sharpLeft, .uturn, .mergeToLeft] {
            XCTAssertLessThan(CarPlayGuidanceMapping.laneAngle(arrow), 0, "\(arrow)")
        }
        for arrow in [LaneArrow.slightRight, .right, .sharpRight, .mergeToRight] {
            XCTAssertGreaterThan(CarPlayGuidanceMapping.laneAngle(arrow), 0, "\(arrow)")
        }
        XCTAssertEqual(CarPlayGuidanceMapping.laneAngle(.straight), 0)
    }

    func testManeuverTypes() {
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.left), .leftTurn)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.slightRight), .slightRightTurn)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.roundabout), .enterRoundabout)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.arrive), .arriveAtDestination)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(nil), .noTurn,
                       "MKDirections типа не сообщает — не выдумываем")
    }

    func testTimeToManeuverIsShareOfRemainingTime() {
        XCTAssertEqual(CarPlayGuidanceMapping.timeToManeuver(stepDistance: 500, remainingDistance: 2000,
                                                             remainingTime: 400), 100)
        XCTAssertEqual(CarPlayGuidanceMapping.timeToManeuver(stepDistance: 5000, remainingDistance: 2000,
                                                             remainingTime: 400), 400, "не дольше всего пути")
        XCTAssertEqual(CarPlayGuidanceMapping.timeToManeuver(stepDistance: 500, remainingDistance: 0,
                                                             remainingTime: 400), 0)
    }

    func testEstimatesAreSentOnlyWhenTheNumberChanges() {
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: nil, current: 300, elapsed: 0))
        XCTAssertFalse(CarPlayGuidanceMapping.shouldUpdate(previous: 300, current: 295, elapsed: 1))
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: 300, current: 284, elapsed: 1))
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: 80, current: 69, elapsed: 1), "вблизи — шаг 10 м")
        XCTAssertFalse(CarPlayGuidanceMapping.shouldUpdate(previous: 20_000, current: 19_500, elapsed: 1),
                       "вдали — шаг 5 %")
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: 300, current: 300,
                                                          elapsed: AppConfig.carPlayEstimateMaxInterval),
                      "на стоянке цифра всё равно освежается")
    }

    /// «12,834 meter» на панели прибытия: система печатает в той единице, в
    /// какой дали. От километра — километры с десятой, ближе — метры по 10.
    func testDistanceGoesToTheCarInReadableUnits() {
        let far = CarPlayGuidanceMapping.distance(meters: 12_834)
        XCTAssertEqual(far.unit, UnitLength.kilometers)
        XCTAssertEqual(far.value, 12.8, accuracy: 0.001)
        let near = CarPlayGuidanceMapping.distance(meters: 347)
        XCTAssertEqual(near.unit, UnitLength.meters)
        XCTAssertEqual(near.value, 350, accuracy: 0.001)
        XCTAssertEqual(CarPlayGuidanceMapping.distance(meters: 154_300).value, 154, accuracy: 0.001)
        XCTAssertEqual(CarPlayGuidanceMapping.distance(meters: -5).value, 0, accuracy: 0.001)
    }
}
