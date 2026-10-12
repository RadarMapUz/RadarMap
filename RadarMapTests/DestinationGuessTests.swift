//
//  DestinationGuessTests.swift
//  RadarMapTests
//
//  «Куда едем?»: ручной адрес старше выученного, «обычно» — из своих
//  поездок, стоя в месте его не предлагаем, без истории и адресов — молчим.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class DestinationGuessTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return c
    }()

    /// Понедельник, 12.10.2026, в `hour` по Ташкенту.
    private func monday(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: hour, minute: 10))!
    }

    private let home = FrequentPlaces.Place(kind: .home, lat: 41.300, lon: 69.240, days: 20)
    private let work = FrequentPlaces.Place(kind: .work, lat: 41.340, lon: 69.290, days: 15)
    private let atHome = CLLocationCoordinate2D(latitude: 41.3001, longitude: 69.2401)

    func testMorningAtHomeGoesToWorkWithUsualTime() throws {
        let guess = try XCTUnwrap(DestinationGuess.make(
            learned: [home, work], manual: { _ in nil },
            usual: { $0 == .toWork ? 39 * 60 : nil },
            from: atHome, now: monday(8), calendar: calendar))
        XCTAssertEqual(guess.kind, .work)
        XCTAssertEqual(guess.usual, 39 * 60)
        XCTAssertNil(guess.placeTitle, "у выученного места адреса нет")
        XCTAssertTrue(guess.subtitle.contains(Formatting.unbreakable(Formatting.duration(39 * 60))), guess.subtitle)
    }

    func testManualAddressOutranksLearned() throws {
        let office = SavedPlace(title: "Офис, Мустакиллик 5", lat: 41.350, lon: 69.300)
        let guess = try XCTUnwrap(DestinationGuess.make(
            learned: [home, work], manual: { $0 == .work ? office : nil },
            usual: { _ in nil }, from: atHome, now: monday(8), calendar: calendar))
        XCTAssertEqual(guess.coordinate.latitude, office.lat)
        XCTAssertEqual(guess.placeTitle, office.title)
        XCTAssertEqual(guess.subtitle, office.title)
    }

    func testManualHomeMakesTheFirstDayWork() {
        // Истории нет совсем, но дом задан — вечером из города «Домой».
        let flat = SavedPlace(title: "Дом", lat: 41.300, lon: 69.240)
        let downtown = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.279)
        let guess = DestinationGuess.make(learned: [], manual: { $0 == .home ? flat : nil },
                                          usual: { _ in nil }, from: downtown,
                                          now: monday(19), calendar: calendar)
        XCTAssertEqual(guess?.kind, .home)
        XCTAssertEqual(guess?.subtitle, "Дом")
    }

    func testNothingWithoutPlacesOrPosition() {
        XCTAssertNil(DestinationGuess.make(learned: [], manual: { _ in nil }, usual: { _ in nil },
                                           from: atHome, now: monday(8), calendar: calendar))
        XCTAssertNil(DestinationGuess.make(learned: [home, work], manual: { _ in nil }, usual: { _ in nil },
                                           from: nil, now: monday(8), calendar: calendar))
    }

    func testNeverSuggestsWhereWeStand() {
        // Вечером дома — не «Домой».
        XCTAssertNil(DestinationGuess.make(learned: [home, work], manual: { _ in nil }, usual: { _ in nil },
                                           from: atHome, now: monday(20), calendar: calendar))
    }

    func testSubtitleWithoutAnythingIsHonest() {
        let guess = DestinationGuess(kind: .home, coordinate: atHome, placeTitle: nil, usual: nil)
        XCTAssertEqual(guess.subtitle, String(localized: "Ваш обычный маршрут"))
    }
}
