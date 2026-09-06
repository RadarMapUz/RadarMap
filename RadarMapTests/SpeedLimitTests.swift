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

    // MARK: - Формат 2: класс дороги (plan_drive_complaints.md, Ж2)

    /// Проспект и дублёр вдоль него: 70 по оси и 20 в пятнадцати метрах севернее.
    private var cityIndex: LimitIndex {
        let json = """
        {"version":1,"format":2,"segments":[
            [70,3,[41.3000,69.2000,41.3000,69.3000]],
            [20,7,[41.30014,69.2000,41.30014,69.3000]]
        ]}
        """
        guard let built = LimitIndex.build(from: Data(json.utf8)) else {
            fatalError("индекс формата 2 обязан собраться")
        }
        return built
    }

    func testFormatTwoIsParsed() {
        XCTAssertEqual(cityIndex.match(CLLocationCoordinate2D(latitude: 41.30001, longitude: 69.25),
                                       courseDegrees: 90), 70)
    }

    /// Ради чего всё: снос GPS в сторону дублёра больше не отдаёт его лимит.
    ///
    /// Точка в 11 метрах от оси проспекта и в 4,5 метрах от дублёра — по одной
    /// близости победил бы дублёр с двадцаткой, и законные 65 стали бы
    /// «превышением на 45».
    func testServiceRoadDoesNotStealTheAvenueLimit() {
        let onDrift = CLLocationCoordinate2D(latitude: 41.30010, longitude: 69.25)
        XCTAssertEqual(cityIndex.match(onDrift, courseDegrees: 90), 70)
    }

    /// Обратная ошибка не менее опасна: если мы правда едем по проезду,
    /// проспект в пятнадцати метрах забирать его лимит не вправе.
    func testAvenueDoesNotStealTheServiceRoadLimit() {
        let onService = CLLocationCoordinate2D(latitude: 41.30014, longitude: 69.25)
        XCTAssertEqual(cityIndex.match(onService, courseDegrees: 90), 20)
    }

    /// Формат 1 читается по-прежнему: он остаётся на сервере для старых сборок.
    func testFormatOneStillWorks() {
        XCTAssertEqual(index.match(CLLocationCoordinate2D(latitude: 41.30001, longitude: 69.25),
                                   courseDegrees: 90), 70)
    }

    /// «5 км/ч» — это парковочный проезд или мусор, но не дорога. В границах
    /// Ташкента таких сегментов 322, и любой из них давал вечное «превышение».
    func testImplausiblyLowLimitsAreRejected() {
        let junk = """
        {"version":1,"segments":[[5,[41.3000,69.2000,41.3000,69.3000]]]}
        """
        XCTAssertNil(LimitIndex.build(from: Data(junk.utf8)),
                     "сегмент отвергнут — индексу собираться не из чего")
        let yard = """
        {"version":1,"segments":[[20,[41.3000,69.2000,41.3000,69.3000]]]}
        """
        XCTAssertNotNil(LimitIndex.build(from: Data(yard.utf8)), "20 во дворе — законно")
    }
}
