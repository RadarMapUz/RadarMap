//
//  SpeedLimitTests.swift
//  RadarMapTests
//
//  Матчинг лимитов скорости: дорога, курс, обе стороны движения, промахи.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class SpeedLimitTests: XCTestCase {

    /// Две дороги: «70» на восток вдоль 41.30 и «50» короткая на 41.40.
    private var index: LimitIndex {
        let json = """
        {"version":1,"segments":[
            [70,[41.3000,69.2000,41.3000,69.3000]],
            [50,[41.4000,69.2000,41.4000,69.2100]]
        ]}
        """
        guard let built = LimitIndex.build(from: Data(json.utf8)) else {
            fatalError("индекс из валидного JSON обязан собраться")
        }
        return built
    }

    func testMatchOnRoadWithAlignedCourse() {
        // Едем на восток по дороге 70.
        let limit = index.match(CLLocationCoordinate2D(latitude: 41.30001, longitude: 69.25),
                                courseDegrees: 90)
        XCTAssertEqual(limit, 70)
    }

    func testMatchAcceptsOppositeDirection() {
        // Обратная сторона той же дороги (на запад) — лимит тот же.
        let limit = index.match(CLLocationCoordinate2D(latitude: 41.30001, longitude: 69.25),
                                courseDegrees: 270)
        XCTAssertEqual(limit, 70)
    }

    func testMatchRejectsPerpendicularCourse() {
        // Пересекаем дорогу поперёк (на север) — её лимит не наш.
        let limit = index.match(CLLocationCoordinate2D(latitude: 41.30001, longitude: 69.25),
                                courseDegrees: 0)
        XCTAssertNil(limit)
    }

    func testMatchRejectsFarPoint() {
        // 500+ м от любой дороги.
        let limit = index.match(CLLocationCoordinate2D(latitude: 41.3050, longitude: 69.25),
                                courseDegrees: 90)
        XCTAssertNil(limit)
    }

    func testMatchPicksNearestRoad() {
        // Рядом с дорогой 50 (в 11 м), курс вдоль неё.
        let limit = index.match(CLLocationCoordinate2D(latitude: 41.4001, longitude: 69.205),
                                courseDegrees: 90)
        XCTAssertEqual(limit, 50)
    }

    func testBuildRejectsGarbage() {
        XCTAssertNil(LimitIndex.build(from: Data("not json".utf8)))
        XCTAssertNil(LimitIndex.build(from: Data("{\"segments\":[]}".utf8)))
    }
}
