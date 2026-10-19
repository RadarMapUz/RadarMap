//
//  EnginePlaceIconsTests.swift
//  RadarMapTests
//
//  АЗС и парковка на карте — значками приложения (план 4.7): слои стиля
//  берут свои имена, буква «P» на ореоле уходит.
//

#if canImport(MapLibre)
import XCTest
@testable import RadarMap

final class EnginePlaceIconsTests: XCTestCase {
    func testFuelAndParkingLayersUseOwnIcons() throws {
        let fuel: [String: Any] = ["id": "radar-poi-fuel", "layout": ["icon-image": "fuel_11", "text-field": "x"]]
        let parking: [String: Any] = ["id": "radar-poi-parking",
                                      "layout": ["text-field": "P", "text-font": ["Noto Sans Bold"]],
                                      "paint": ["text-halo-color": "#2563D9"]]
        let other: [String: Any] = ["id": "poi-level-1", "layout": ["icon-image": "cafe_11"]]
        let ownFuel = try XCTUnwrap(EngineModernStyle.ownPlaceIcons(fuel)["layout"] as? [String: Any])
        XCTAssertEqual(ownFuel["icon-image"] as? String, EnginePlaceIcons.fuel)
        XCTAssertEqual(ownFuel["text-field"] as? String, "x", "подпись АЗС остаётся")
        let ownParking = EngineModernStyle.ownPlaceIcons(parking)
        let layout = try XCTUnwrap(ownParking["layout"] as? [String: Any])
        XCTAssertEqual(layout["icon-image"] as? String, EnginePlaceIcons.parking)
        XCTAssertNil(layout["text-field"], "буквы «P» больше нет")
        XCTAssertEqual((ownParking["paint"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((EngineModernStyle.ownPlaceIcons(other)["layout"] as? [String: Any])?["icon-image"] as? String,
                       "cafe_11", "прочие места не трогаем")
    }

    @MainActor
    func testIconsAreDrawn() {
        for place in EnginePlaceIcons.all {
            XCTAssertEqual(place.image.size, CGSize(width: EnginePlaceIcons.side, height: EnginePlaceIcons.side),
                           place.name)
        }
    }
}
#endif
