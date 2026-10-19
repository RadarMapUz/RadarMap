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

    /// Есть профиль на этот час — «сейчас ~44 мин» вместо месячной медианы;
    /// пробки — словом, только от 3 минут.
    func testEstimateForNowOutranksTheMonthlyMedian() throws {
        func subtitle(_ seconds: Double, jam: Double) throws -> String {
            try XCTUnwrap(DestinationGuess.make(
                learned: [home, work], manual: { _ in nil }, usual: { _ in 39 * 60 },
                estimate: { $0 == .toWork ? .init(seconds: seconds, jamSeconds: jam) : nil },
                from: atHome, now: monday(8), calendar: calendar)).subtitle
        }
        let calm = try subtitle(44 * 60, jam: 60)
        XCTAssertTrue(calm.contains(Formatting.unbreakable(Formatting.duration(44 * 60))), calm)
        XCTAssertFalse(calm.contains(Formatting.unbreakable(Formatting.duration(39 * 60))), calm)
        XCTAssertFalse(calm.contains("+"), "минута пробок — шум: \(calm)")
        let jammed = try subtitle(52 * 60, jam: 8 * 60)
        XCTAssertTrue(jammed.contains("+8"), jammed)
    }

    /// Не у начала дороги (у работы вечером — да; в ресторане за 15 км — нет)
    /// «сейчас» не показывается: профиль «работа → дом» про ресторан не знает.
    func testEstimateOnlyAtTheStartOfThatRoad() throws {
        let restaurant = CLLocationCoordinate2D(latitude: 41.25, longitude: 69.15)
        let atWork = CLLocationCoordinate2D(latitude: 41.3401, longitude: 69.2901)
        func guess(from: CLLocationCoordinate2D) -> DestinationGuess? {
            DestinationGuess.make(learned: [home, work], manual: { _ in nil }, usual: { _ in 39 * 60 },
                                  estimate: { _ in .init(seconds: 52 * 60, jamSeconds: 8 * 60) },
                                  from: from, now: monday(19), calendar: calendar)
        }
        let far = try XCTUnwrap(guess(from: restaurant))
        XCTAssertEqual(far.kind, .home)
        XCTAssertNil(far.estimate)
        XCTAssertTrue(far.subtitle.contains(Formatting.unbreakable(Formatting.duration(39 * 60))), far.subtitle)
        XCTAssertNotNil(try XCTUnwrap(guess(from: atWork)).estimate)
    }

    /// Время — первым: на узком экране обрезается адрес, а не «пробки +8».
    func testTimeComesBeforeTheAddress() throws {
        let office = SavedPlace(title: "Офис, Мустакиллик 5", lat: 41.350, lon: 69.300)
        let g = try XCTUnwrap(DestinationGuess.make(
            learned: [home, work], manual: { $0 == .work ? office : nil }, usual: { _ in 39 * 60 },
            from: atHome, now: monday(8), calendar: calendar))
        XCTAssertTrue(g.subtitle.hasSuffix(office.title), g.subtitle)
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
