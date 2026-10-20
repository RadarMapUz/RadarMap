//
//  TwinCheckTests.swift
//  RadarMapTests
//
//  «Парная» — доказательство для гейта направления, только если пара есть в
//  наборе (11.2): признак без камеры обратного направления рядом, пара
//  дальше 100 м или скрытая модератором — не доказательство.
//

import XCTest
@testable import RadarMap

final class TwinCheckTests: XCTestCase {
    private func camera(_ id: Int, lat: Double = 41.3100, lon: Double = 69.2800, dir: Int?,
                        twin: Bool? = true) -> Camera {
        Camera(id: id, region: "Ташкент", city: "Ташкент", location: "Улица \(id)", lat: lat, lon: lon,
               type: "Стационар радар", violations: [], needsReview: nil, axis: dir.map { $0 % 180 },
               dir: dir, cls: "primary", split: true, twin: twin)
    }

    func testRealPairStaysProven() {
        let (cameras, dropped) = TwinCheck.verified([camera(1, dir: 90), camera(2, lat: 41.3101, dir: 270)])
        XCTAssertEqual(dropped, 0)
        XCTAssertTrue(cameras.allSatisfy { $0.twin == true && $0.sidesAreProven })
    }

    func testFlagWithoutPartnerIsDropped() {
        // Обе смотрят в одну сторону, обратной рядом нет — как 2009/2010 в v11.
        let (cameras, dropped) = TwinCheck.verified([camera(1, dir: 90), camera(2, lat: 41.3101, dir: 95)])
        XCTAssertEqual(dropped, 2)
        XCTAssertTrue(cameras.allSatisfy { $0.twin == nil })
        XCTAssertFalse(cameras[0].allowsDirectionGate, "без пары на разделённой — глушить по направлению нельзя")
    }

    func testFarOrHiddenPartnerIsNoProof() {
        let far = TwinCheck.verified([camera(1, dir: 90), camera(2, lat: 41.3120, dir: 270)])   // ~220 м
        XCTAssertEqual(far.dropped, 2)
        // Пару скрыл модератор — в наборе её нет.
        let alone = TwinCheck.verified([camera(1, dir: 90)])
        XCTAssertEqual(alone.dropped, 1)
    }

    func testUnflaggedCamerasAreUntouched() {
        let (cameras, dropped) = TwinCheck.verified([camera(1, dir: 90, twin: nil), camera(2, dir: nil, twin: nil)])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(cameras.map(\.id), [1, 2])
    }

    /// `lanes=1` на магистрали не сужает дорогу камеры уже двух полос.
    func testMajorRoadIsNeverNarrowerThanTwoLanes() {
        XCTAssertEqual(RoadGeometry.halfWidth(lanes: 1, roadClass: .trunk),
                       RoadGeometry.halfWidth(lanes: 2, roadClass: .trunk))
        XCTAssertEqual(RoadGeometry.halfWidth(lanes: 1, roadClass: .primary),
                       RoadGeometry.halfWidth(lanes: 2, roadClass: .primary))
        XCTAssertLessThan(RoadGeometry.halfWidth(lanes: 1, roadClass: .residential),
                          RoadGeometry.halfWidth(lanes: 2, roadClass: .residential), "улица в одну полосу — бывает")
    }
}
