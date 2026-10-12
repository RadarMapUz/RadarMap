//
//  CarPlayTripPreviewTests.swift
//  RadarMapTests
//
//  Выбор маршрута в машине: тексты вариантов не пустые и говорят главное,
//  цвет времени не утверждает «пробок нет» без данных, на ходу выбора нет.
//

import MapKit
import XCTest
@testable import RadarMap

final class CarPlayTripPreviewTests: XCTestCase {

    private func variant(id: Int, minutes: Double, km: Double, cameras: Int = 0,
                         labels: [RouteChoice.Label] = [], traffic: TimeInterval? = nil) -> RouteService.Variant {
        let points = [MKMapPoint(CLLocationCoordinate2D(latitude: 41.31, longitude: 69.24)),
                      MKMapPoint(CLLocationCoordinate2D(latitude: 41.33, longitude: 69.26))]
        let camera = Camera(id: 1, region: "", city: "", location: "тест", lat: 41.32, lon: 69.25,
                            type: "Стационар радар", violations: [], needsReview: nil)
        var v = RouteService.Variant(
            id: id, points: points, polyline: MKPolyline(points: points, count: 2),
            distance: km * 1000, travelTime: minutes * 60,
            cameras: (0..<cameras).map { RouteService.RouteCamera(camera: camera, distanceAlong: Double($0) * 100) },
            steps: [])
        v.assessment.labels = labels
        v.trafficDelay = traffic
        return v
    }

    func testEveryLineHasAtLeastOneVariantAndNoneIsEmpty() {
        // CPRouteChoice: «You must provide at least one variant».
        let fast = variant(id: 0, minutes: 25, km: 12, cameras: 3, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, cameras: 1, labels: [.fewerCameras])
        for v in [fast, calm, variant(id: 2, minutes: 9, km: 4)] {
            let text = CarPlayTripPreview.text(for: v, among: [fast, calm])
            for line in [text.summary, text.additional, text.selection] {
                XCTAssertFalse(line.isEmpty)
                XCTAssertFalse(line.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
    }

    func testLabelLeadsAndTimeIsAlwaysThere() {
        let fast = variant(id: 0, minutes: 25, km: 12, cameras: 3, labels: [.fastest])
        let calm = variant(id: 1, minutes: 27, km: 13, cameras: 1, labels: [.fewerCameras])
        let text = CarPlayTripPreview.text(for: calm, among: [fast, calm])
        let title = RoutePanel.title(.fewerCameras, calm)
        XCTAssertTrue(text.summary[0].hasPrefix(title), text.summary[0])
        XCTAssertTrue(text.summary[0].contains(calm.etaText))
        XCTAssertEqual(text.summary.last, calm.etaText, "самый короткий вариант — время")
    }

    func testFactsCarryCamerasAndTraffic() {
        let jam = variant(id: 0, minutes: 25, km: 12, cameras: 2, traffic: 420)
        let text = CarPlayTripPreview.text(for: jam, among: [jam])
        let cameras = String(format: String(localized: "камер: %lld"), 2)
        XCTAssertTrue(text.additional[0].contains(cameras), text.additional[0])
        XCTAssertTrue(text.additional[0].contains(jam.trafficNote ?? "—"), text.additional[0])
        XCTAssertTrue(text.additional.last?.contains(cameras) ?? false)
    }

    func testTimeColorNeverClaimsFreeRoadWithoutData() {
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: nil), .standard)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 30), .green)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 300), .orange)
        XCTAssertEqual(CarPlayTripPreview.timeColor(trafficDelay: 900), .red)
    }

    func testNoChoiceWhileDriving() {
        XCTAssertTrue(CarPlayTripPreview.shouldPreview(speedKmh: 0))
        XCTAssertTrue(CarPlayTripPreview.shouldPreview(speedKmh: 6))
        XCTAssertFalse(CarPlayTripPreview.shouldPreview(speedKmh: 40))
    }

    func testMovingOffAcceptsTheChoiceOnlyWhenSustained() {
        var watch = CarPlayTripPreview.MovingWatch()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(watch.update(speedKmh: 30, at: t0))
        XCTAssertFalse(watch.update(speedKmh: 0, at: t0 + 1), "всплеск GPS не считается")
        XCTAssertFalse(watch.update(speedKmh: 20, at: t0 + 2))
        XCTAssertFalse(watch.update(speedKmh: 22, at: t0 + 4))
        XCTAssertTrue(watch.update(speedKmh: 25, at: t0 + 2 + AppConfig.carPlayPreviewAutoStartSeconds))
    }
}
