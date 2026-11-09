//
//  TripMapFrameTests.swift
//  RadarMapTests
//
//  Рамка снимка карты для карточки: трек целиком внутри, пропорция кадра
//  точная, снизу запас под затемнение.
//

import MapKit
import XCTest
@testable import RadarMap

final class TripMapFrameTests: XCTestCase {

    private let points = [MKMapPoint(x: 1_000, y: 1_000), MKMapPoint(x: 5_000, y: 1_200)]

    func testKeepsTheTrackInsideAndTheAspect() {
        let rect = TripMapFrame.rect(points: points, aspect: 1.35)
        XCTAssertEqual(rect.size.width / rect.size.height, 1.35, accuracy: 1e-6)
        for point in points { XCTAssertTrue(rect.contains(point)) }
    }

    func testTrackSitsAboveTheBottomFade() {
        let rect = TripMapFrame.rect(points: points, aspect: 1.35)
        let trackBottom = points.map(\.y).max() ?? 0
        let share = (trackBottom - rect.minY) / rect.size.height
        XCTAssertLessThan(share, 1 - TripMapFrame.bottomReserve + 1e-6)
    }

    func testSinglePlaceStillGetsAVisibleArea() {
        let rect = TripMapFrame.rect(points: [MKMapPoint(x: 10, y: 10)], aspect: 1.35)
        XCTAssertGreaterThan(rect.size.height, 0)
        XCTAssertGreaterThan(rect.size.width, 0)
    }
}
