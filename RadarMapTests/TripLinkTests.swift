//
//  TripLinkTests.swift
//  RadarMapTests
//
//  radarmap://start-trip включает постоянный GPS. Без вопроса — только по
//  ключу своих кнопок; всё остальное спрашивает или не трогает идущую поездку.
//

import XCTest
@testable import RadarMap

final class TripLinkTests: XCTestCase {

    private let key = "8C1F0A5E-0000-4000-8000-000000000001"

    func testOwnButtonStartsAtOnce() {
        let url = TripLink.startURL(key: key)
        XCTAssertEqual(TripLink.decide(url, expectedKey: key, tripActive: false), .start)
    }

    func testForeignLinkAsks() {
        let bare = URL(string: "radarmap://start-trip")!
        XCTAssertEqual(TripLink.decide(bare, expectedKey: key, tripActive: false), .confirm,
                       "страница или чужое приложение не знают ключа")
        let guessed = URL(string: "radarmap://start-trip?k=0000")!
        XCTAssertEqual(TripLink.decide(guessed, expectedKey: key, tripActive: false), .confirm)
        let empty = URL(string: "radarmap://start-trip?k=")!
        XCTAssertEqual(TripLink.decide(empty, expectedKey: key, tripActive: false), .confirm)
    }

    func testNoKeyYetMeansAsking() {
        // Ключа нет (App Group не выдан, приложение не открывали) — даже «своя»
        // ссылка без ключа спрашивает: пустое не равно пустому.
        XCTAssertEqual(TripLink.decide(TripLink.startURL(key: nil), expectedKey: nil, tripActive: false), .confirm)
        XCTAssertEqual(TripLink.decide(TripLink.startURL(key: ""), expectedKey: "", tripActive: false), .confirm)
        XCTAssertEqual(TripLink.decide(TripLink.startURL(key: key), expectedKey: nil, tripActive: false), .confirm)
    }

    func testRunningTripIsNeverTouched() {
        XCTAssertEqual(TripLink.decide(TripLink.startURL(key: key), expectedKey: key, tripActive: true), .ignore)
        XCTAssertEqual(TripLink.decide(URL(string: "radarmap://start-trip")!, expectedKey: key, tripActive: true), .ignore)
    }

    func testOtherLinksAreNotOurs() {
        for link in ["radarmap://stats", "radarmap://trip/12", "radarmap://fines", "https://start-trip",
                     "other://start-trip?k=\(key)"] {
            XCTAssertNil(TripLink.decide(URL(string: link)!, expectedKey: key, tripActive: false), link)
        }
    }

    func testKeyIsMadeOnceAndKept() throws {
        let suite = "TripLinkTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let first = TripLink.prepareKey(in: store, make: { "первый" })
        XCTAssertEqual(first.key, "первый")
        XCTAssertTrue(first.created, "заведён — виджеты надо перерисовать")
        let second = TripLink.prepareKey(in: store, make: { "второй" })
        XCTAssertEqual(second.key, "первый", "ключ не меняется: виджет со старой ссылкой стартует по-прежнему")
        XCTAssertFalse(second.created)
        XCTAssertNil(TripLink.prepareKey(in: nil).key)
    }

    // MARK: - Маршрут с виджета и конец поездки

    func testOwnWidgetBuildsARoute() {
        let url = TripLink.goURL(.home, key: key)
        XCTAssertEqual(url.absoluteString, "radarmap://go/home?k=\(key)")
        XCTAssertEqual(TripLink.decideGo(url, expectedKey: key), .route(.home))
        XCTAssertEqual(TripLink.decideGo(TripLink.goURL(.work, key: key), expectedKey: key), .route(.work))
    }

    /// Без ключа чужая страница заставила бы отправить адрес дома на сервер маршрутов.
    func testForeignRouteLinkAsks() {
        XCTAssertEqual(TripLink.decideGo(URL(string: "radarmap://go/home")!, expectedKey: key), .confirm(.home))
        XCTAssertEqual(TripLink.decideGo(URL(string: "radarmap://go/work?k=0000")!, expectedKey: key), .confirm(.work))
        XCTAssertEqual(TripLink.decideGo(TripLink.goURL(.home, key: key), expectedKey: nil), .confirm(.home))
    }

    func testOtherLinksAreNotRouteLinks() {
        XCTAssertNil(TripLink.decideGo(URL(string: "radarmap://go/school")!, expectedKey: key))
        XCTAssertNil(TripLink.decideGo(URL(string: "radarmap://go")!, expectedKey: key))
        XCTAssertNil(TripLink.decideGo(URL(string: "radarmap://start-trip")!, expectedKey: key))
    }

    func testEndLinkNeedsTheKeyAndARunningTrip() {
        let url = TripLink.endURL(key: key)
        XCTAssertTrue(TripLink.decideEnd(url, expectedKey: key, tripActive: true))
        XCTAssertFalse(TripLink.decideEnd(url, expectedKey: key, tripActive: false))
        XCTAssertFalse(TripLink.decideEnd(URL(string: "radarmap://end-trip")!, expectedKey: key, tripActive: true))
    }
}
