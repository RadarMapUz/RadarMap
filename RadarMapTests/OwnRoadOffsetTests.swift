//
//  OwnRoadOffsetTests.swift
//  RadarMapTests
//
//  «Своя дорога камеры» для нового подъезда (ревью S4): на куске — до
//  ломаной, за краем — до продолжения крайнего отрезка, без куска — до
//  прямой по оси; на кривой продолжение конца честнее прямой через камеру.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class OwnRoadOffsetTests: XCTestCase {
    private let lat0 = 41.30, lon0 = 69.20
    private var kx: Double { 111_320 * cos(lat0 * .pi / 180) }

    private func point(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat0 + y / 111_320, longitude: lon0 + x / kx)
    }

    /// Камера в (0, 0); кусок — точки (x, y) в метрах от неё.
    private func camera(piece: [(Double, Double)]?, axis: Int?) -> Camera {
        let road = piece?.flatMap { p -> [Int] in
            [Int((p.1 / 111_320 * 1e6).rounded()), Int((p.0 / kx * 1e6).rounded())]
        }
        return Camera(id: 1, region: "Т", city: "", location: "к", lat: lat0, lon: lon0,
                      type: "Стационар радар", violations: [], needsReview: false, axis: axis, dir: nil,
                      lanes: 3, cls: "primary", bridge: nil, road: road, split: true, twin: nil)
    }

    func testOnThePieceItIsTheDistanceToIt() throws {
        let cam = camera(piece: [(0, -100), (0, 0), (0, 100)], axis: 0)
        XCTAssertEqual(try XCTUnwrap(PassGeometry.ownRoadOffset(camera: cam, at: point(12, 50))), 12, accuracy: 0.5)
    }

    func testBeyondAStraightPieceItIsTheExtendedLine() throws {
        let cam = camera(piece: [(0, -100), (0, 0), (0, 100)], axis: 0)
        XCTAssertEqual(try XCTUnwrap(PassGeometry.ownRoadOffset(camera: cam, at: point(20, 400))), 20, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(PassGeometry.ownRoadOffset(camera: cam, at: point(-99, -300))), 99, accuracy: 0.5)
    }

    /// Дорога загибает к востоку: последний отрезок куска — под 10°. Точка на
    /// продолжении загиба в 300 м — на «своей дороге», хотя прямая через
    /// камеру по оси 0° от неё в 35+ м.
    func testOnACurveTheEndSegmentWins() throws {
        let bend = 10.0 * .pi / 180
        let cam = camera(piece: [(0, -100), (0, 0), (0, 50), (50 * sin(bend), 50 + 50 * cos(bend))], axis: 0)
        let far = point(50 * sin(bend) + 200 * sin(bend), 50 + 50 * cos(bend) + 200 * cos(bend))
        let offset = try XCTUnwrap(PassGeometry.ownRoadOffset(camera: cam, at: far))
        XCTAssertLessThan(offset, 1)
        XCTAssertGreaterThan(far.longitude - lon0, 0)
    }

    func testWithoutAPieceTheAxisLineThroughTheCamera() throws {
        let cam = camera(piece: nil, axis: 90)
        XCTAssertEqual(try XCTUnwrap(PassGeometry.ownRoadOffset(camera: cam, at: point(500, 30))), 30, accuracy: 0.5)
        XCTAssertNil(PassGeometry.ownRoadOffset(camera: camera(piece: nil, axis: nil), at: point(500, 30)))
    }
}
