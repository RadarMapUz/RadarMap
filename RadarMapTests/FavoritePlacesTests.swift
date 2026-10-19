//
//  FavoritePlacesTests.swift
//  RadarMapTests
//
//  «Избранное» (7.2): то же место не дублируется (имя обновляется, место
//  встаёт первым), список не растёт бесконечно.
//

import XCTest
@testable import RadarMap

final class FavoritePlacesTests: XCTestCase {
    func testSamePlaceIsRenamedNotDuplicated() {
        let dacha = SavedPlace(title: "Дача", lat: 41.30, lon: 69.20)
        let school = SavedPlace(title: "Школа", lat: 41.35, lon: 69.30)
        var list = AppSettings.favorites(adding: dacha, to: [])
        list = AppSettings.favorites(adding: school, to: list)
        let renamed = SavedPlace(title: "Дача у реки", lat: 41.3003, lon: 69.2002)
        list = AppSettings.favorites(adding: renamed, to: list)
        XCTAssertEqual(list.map(\.title), ["Дача у реки", "Школа"])
    }

    func testListIsCapped() {
        var list: [SavedPlace] = []
        for i in 0..<(AppConfig.favoritePlacesMax + 5) {
            list = AppSettings.favorites(adding: SavedPlace(title: "\(i)", lat: 41 + Double(i) * 0.01, lon: 69),
                                         to: list)
        }
        XCTAssertEqual(list.count, AppConfig.favoritePlacesMax)
        XCTAssertEqual(list.first?.title, "\(AppConfig.favoritePlacesMax + 4)", "новые первыми")
    }
}
