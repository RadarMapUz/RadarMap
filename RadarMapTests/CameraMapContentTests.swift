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

    // MARK: - Важность маркера

    /// Камера в 400 метрах по курсу и камера в трёх километрах за спиной
    /// обязаны выглядеть по-разному — иначе полсотни точек читаются как сыпь.
    private func camera(_ id: Int, metersEast: Double) -> Camera {
        // ~0.0000120° долготы на метр в широтах Ташкента.
        Camera(id: id, region: "Т", city: "", location: "к\(id)",
               lat: center.latitude,
               lon: center.longitude + metersEast * 0.0000120,
               type: "Стационар радар", violations: [], needsReview: false)
    }

    func testNearestCameraIsTheOnlyTarget() {
        let near = camera(1, metersEast: 300)
        let far = camera(2, metersEast: 500)
        XCTAssertEqual(CameraMapContent.tier(camera: near, focus: center,
                                             targetID: 1, routeIDs: []), .target)
        XCTAssertEqual(CameraMapContent.tier(camera: far, focus: center,
                                             targetID: 1, routeIDs: []), .near)
    }

    func testDistantCameraFallsToBackground() {
        let far = camera(3, metersEast: 6000)
        XCTAssertEqual(CameraMapContent.tier(camera: far, focus: center,
                                             targetID: nil, routeIDs: []), .background)
    }

    /// Камера маршрута — «моя» на любом расстоянии: иначе на длинной трассе
    /// весь маршрут уходил бы в фон.
    func testRouteCameraStaysNearAtAnyDistance() {
        let far = camera(4, metersEast: 40_000)
        XCTAssertEqual(CameraMapContent.tier(camera: far, focus: center,
                                             targetID: nil, routeIDs: [4]), .near)
    }

    /// Позиции нет — приглушать не от чего. Показываем всё в полную силу:
    /// пропавшая камера хуже лишней.
    func testWithoutFocusNothingIsDimmed() {
        let far = camera(5, metersEast: 40_000)
        XCTAssertEqual(CameraMapContent.tier(camera: far, focus: nil,
                                             targetID: nil, routeIDs: []), .near)
    }

    /// Клин направления рисуется только там, где направление доказано.
    func testDirectionConeOnlyWhenProven() {
        func made(dir: Int?, twin: Bool?, split: Bool?, cls: String?) -> Camera {
            Camera(id: 7, region: "Т", city: "", location: "к",
                   lat: center.latitude, lon: center.longitude,
                   type: "Стационар радар", violations: [], needsReview: false,
                   dir: dir, cls: cls, split: split, twin: twin)
        }
        // Парная камера обратного направления — стороны доказанно поделены.
        XCTAssertEqual(made(dir: 90, twin: true, split: nil, cls: "primary").markerDirection, 90)
        // Дорога заведомо не разделена — обратной проезжей части нет.
        XCTAssertEqual(made(dir: 90, twin: nil, split: false, cls: "primary").markerDirection, 90)
        // Доказательства нет — камера может снимать обе стороны, клин был бы ложью.
        XCTAssertNil(made(dir: 90, twin: nil, split: nil, cls: "primary").markerDirection)
        // Снап сел на тротуар — профилю дороги верить нельзя.
        XCTAssertNil(made(dir: 90, twin: true, split: nil, cls: "footway").markerDirection)
        // Направления просто нет.
        XCTAssertNil(made(dir: nil, twin: true, split: nil, cls: "primary").markerDirection)
    }
}
