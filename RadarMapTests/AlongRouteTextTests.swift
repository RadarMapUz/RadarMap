//
//  AlongRouteTextTests.swift
//  RadarMapTests
//
//  Подписи «По пути» и карточки карты по пути для VoiceOver (19.3, правила
//  14.6): одна фраза, единицы словами, порядок — сколько ехать, что это,
//  как называется, есть ли газ, далеко ли от дороги.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class AlongRouteTextTests: XCTestCase {

    private func venue(_ kind: Venue.Kind, _ name: String, _ lat: Double, _ lon: Double) -> Venue {
        Venue(kind: kind, name: name, point: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    @MainActor
    func testSpokenRowIsOnePhraseInWords() {
        let item = CorridorVenues.Item(venue: venue(.cng, "Metan Chinoz", 41.2, 69.2), along: 47_000, offset: 300)
        let station = CngStation(lat: 41.2, lon: 69.2, status: .gas, statusAge: 40, queue: nil,
                                 queueAge: nil, confirmed: true)
        let ru = Locale(identifier: "ru")
        let spoken = AlongRouteText.spoken(item, ahead: 47_000, station: station, locale: ru)
        // Порядок: сколько ехать, что это, как называется, есть ли газ, далеко ли от дороги.
        let parts = [SpokenUnits.distance(47_000, locale: ru), AlongRouteText.spokenKind(.cng), "Metan Chinoz",
                     String(localized: "Газ есть").lowercased(with: ru),
                     String(format: String(localized: "%@ от дороги"), SpokenUnits.distance(300, locale: ru))]
        var cursor = spoken.startIndex
        for part in parts {
            guard let range = spoken.range(of: part, range: cursor..<spoken.endIndex) else {
                return XCTFail("нет «\(part)» по порядку в «\(spoken)»")
            }
            cursor = range.upperBound
        }
        XCTAssertFalse(spoken.contains("км"), "единицы голосом — словами, не буквами: \(spoken)")
    }

    @MainActor
    func testRoadsideIsSaidAsSuch() {
        let item = CorridorVenues.Item(venue: venue(.hotel, "", 41.2, 69.2), along: 5_000, offset: 25)
        XCTAssertTrue(AlongRouteText.spoken(item, ahead: 5_000, station: nil)
            .hasSuffix(String(localized: "у дороги")), "25 м от линии — «у дороги», такой точности GPS не даёт")
        XCTAssertFalse(AlongRouteText.detail(item, ahead: 5_000).contains("·"),
                       "без имени вид уже стоит заголовком строки")
    }

    @MainActor
    func testSpokenSizeIsInWords() {
        XCTAssertEqual(CorridorOfferText.spokenSize(96_400_000, locale: Locale(identifier: "ru")), "96 мегабайт")
    }
}
