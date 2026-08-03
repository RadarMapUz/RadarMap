//
//  CameraMapContentTests.swift
//  RadarMapTests
//
//  Слой карты: точки или кластеры. Главный инвариант — НИ ОДНА камера области не
//  теряется: раньше сверх лимита 220 лишние молча отбрасывались и карта
//  выглядела недогруженной.
//

import XCTest
import MapKit
@testable import RadarMap

final class CameraMapContentTests: XCTestCase {

    private let center = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)

    private func region(spanDegrees: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center,
                           span: MKCoordinateSpan(latitudeDelta: spanDegrees,
                                                  longitudeDelta: spanDegrees))
    }

    /// Сетка camera-точек внутри области: `side`×`side` штук.
    private func grid(side: Int, spanDegrees: Double,
                      type: CameraType = .stationaryRadar) -> [Camera] {
        var result: [Camera] = []
        let step = spanDegrees / Double(side + 1)
        for row in 1...side {
            for column in 1...side {
                result.append(Camera(
                    id: row * 1000 + column, region: "Т", city: "",
                    location: "к\(row)-\(column)",
                    lat: center.latitude - spanDegrees / 2 + step * Double(row),
                    lon: center.longitude - spanDegrees / 2 + step * Double(column),
                    type: type == .stationaryRadar ? "Стационар радар" : "Стационар камера",
                    violations: [], needsReview: false))
            }
        }
        return result
    }

    func testFewCamerasStayIndividualPoints() async {
        let cameras = grid(side: 5, spanDegrees: 0.05)   // 25 камер
        let layer = await CameraMapContent.layer(cameras: cameras, region: region(spanDegrees: 0.05),
                                                 filter: .all, budget: 220)
        XCTAssertFalse(layer.isClustered)
        XCTAssertEqual(layer.cameras.count, 25)
        XCTAssertTrue(layer.clusters.isEmpty)
    }

    /// Камер больше бюджета → кластеризуем, и в сумме кластеров и одиночек лежат
    /// ВСЕ камеры области. Ничего не пропадает — это и было симптомом «не загрузились».
    func testCamerasOverBudgetAreClusteredWithoutLoss() async {
        let cameras = grid(side: 20, spanDegrees: 0.4)   // 400 камер
        let layer = await CameraMapContent.layer(cameras: cameras, region: region(spanDegrees: 0.4),
                                                 filter: .all, budget: 220)
        XCTAssertTrue(layer.isClustered)
        let total = layer.clusters.reduce(0) { $0 + $1.count } + layer.cameras.count
        XCTAssertEqual(total, 400, "все камеры области либо точка, либо часть кластера")
        XCTAssertLessThanOrEqual(layer.cameras.count, 220)
    }

    func testClustersCarryPlausibleCentroids() async {
        let cameras = grid(side: 20, spanDegrees: 0.4)
        let area = region(spanDegrees: 0.4)
        let layer = await CameraMapContent.layer(cameras: cameras, region: area,
                                                 filter: .all, budget: 220)
        for cluster in layer.clusters {
            XCTAssertTrue(abs(cluster.coordinate.latitude - area.center.latitude)
                          <= area.span.latitudeDelta, "центроид внутри области")
            XCTAssertGreaterThan(cluster.count, 1, "кластер из одной камеры — это точка")
        }
    }

    func testCamerasOutsideRegionAreIgnored() async {
        var cameras = grid(side: 3, spanDegrees: 0.05)
        cameras.append(Camera(id: 9999, region: "С", city: "", location: "далеко",
                              lat: 39.65, lon: 66.95,   // Самарканд
                              type: "Стационар радар",
                              violations: [], needsReview: false))
        let layer = await CameraMapContent.layer(cameras: cameras, region: region(spanDegrees: 0.05),
                                                 filter: .all, budget: 220)
        XCTAssertEqual(layer.cameras.count, 9)
        XCTAssertFalse(layer.cameras.contains { $0.id == 9999 })
    }

    func testFilterIsApplied() async {
        let radars = grid(side: 3, spanDegrees: 0.05, type: .stationaryRadar)
        let layer = await CameraMapContent.layer(cameras: radars, region: region(spanDegrees: 0.05),
                                                 filter: .cameras, budget: 220)
        XCTAssertTrue(layer.cameras.isEmpty, "фильтр «Камеры» не пускает радары")
    }

    func testEmptyInputGivesEmptyLayer() async {
        let layer = await CameraMapContent.layer(cameras: [], region: region(spanDegrees: 0.5),
                                                 filter: .all, budget: 220)
        XCTAssertEqual(layer, CameraMapContent.Layer())
    }
}
