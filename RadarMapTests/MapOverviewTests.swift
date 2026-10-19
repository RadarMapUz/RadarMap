//
//  MapOverviewTests.swift
//  RadarMapTests
//
//  Покрытие тайлами дорог: охват, порядок закачки. Тесты осмотра, охвата
//  и бюджетов схемы дороги ушли вместе с ней (19.10).
//

import CoreLocation
import XCTest
@testable import RadarMap

final class MapOverviewTests: XCTestCase {

    // MARK: - Покрытие тайлами

    func testCoverageFollowsTheSpanInsteadOfAFixedThreeByThree() {
        // 3×3 тайла по 0,05° — это ±5,5 км: под ближний план с запасом, а на
        // обзорном охвате пятно данных в середине пустого экрана.
        let near = RoadTiles.steps(forRadius: 300, tileDegrees: 0.05, latitude: 41.3)
        let wide = RoadTiles.steps(forRadius: 18_000, tileDegrees: 0.05, latitude: 41.3)
        XCTAssertEqual(near, 1, "ближний план обходится своим тайлом и соседями")
        XCTAssertGreaterThan(wide, near)
        // Потолок обязан быть: тайлов в окрестности (2n+1)².
        let absurd = RoadTiles.steps(forRadius: 4_000_000, tileDegrees: 0.05,
                                     latitude: 41.3)
        XCTAssertLessThanOrEqual(absurd, 4)
    }

    func testCoverageAsksForTheTileUnderTheCarFirst() {
        // Порядок ключей — он же порядок закачки. Пока он был построчным,
        // первым качался левый верхний угол окрестности, то есть угол экрана.
        let me = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.240)
        let keys = RoadTiles.coverage(of: me, tileDegrees: 0.05, steps: 2)
        XCTAssertEqual(keys.count, 25)
        XCTAssertEqual(keys.first,
                       RoadTiles.tileKey(latitude: me.latitude,
                                         longitude: me.longitude, tileDegrees: 0.05),
                       "первым обязан ехать тайл, на котором стоит машина")
        XCTAssertEqual(Swift.Set(keys).count, keys.count, "дублей в окрестности нет")
        XCTAssertEqual(Swift.Set(RoadTiles.neighborhood(of: me, tileDegrees: 0.05)),
                       Swift.Set(RoadTiles.coverage(of: me, tileDegrees: 0.05, steps: 1)),
                       "прежняя окрестность 3×3 — частный случай нового покрытия")
    }

    func testDownloadQueuePutsTheSkeletonBeforeTheHouses() {
        // Очереди не было вовсе: все недостающие файлы уходили в сеть одним
        // залпом, и первым приезжал тот, кому повезло.
        XCTAssertLessThan(RoadTiles.Set.far.loadRank, RoadTiles.Set.houses.loadRank)
        XCTAssertLessThan(RoadTiles.Set.streets.loadRank, RoadTiles.Set.surface.loadRank)
        XCTAssertEqual(Swift.Set(RoadTiles.Set.allCases.map(\.loadRank)).count,
                       RoadTiles.Set.allCases.count, "очередь без ничьих")
    }

}
