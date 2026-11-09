//
//  CarPlaySearchEntryTests.swift
//  RadarMapTests
//
//  Вход в поиск адреса в машине: лупа есть везде, где можно выбрать цель, а
//  запрещённое на ходу отвечает причиной и альтернативой (владелец 09.11:
//  «поиска в карплейе нет, кнопки там нету»).
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CarPlaySearchEntryTests: XCTestCase {

    private typealias E = CarPlaySearchEntry

    private func screens() -> [E.Screen] {
        [false, true].flatMap { trip in [false, true].flatMap { route in
            [false, true].flatMap { panning in [false, true].map { previewing in
                E.Screen(tripActive: trip, routeActive: route, panning: panning, previewing: previewing)
            } }
        } }
    }

    private func contains(_ bar: E.BarLayout, destinations route: Bool) -> Bool {
        (bar.leading + bar.trailing).contains(.destinations(routeActive: route))
    }

    // MARK: - Лупа в любом состоянии

    func testSearchButtonIsInEveryState() {
        for screen in screens() {
            XCTAssertTrue(contains(E.bar(screen), destinations: screen.routeActive), "\(screen)")
        }
    }

    func testBarNeverExceedsTheTemplateLimit() {
        for screen in screens() {
            let bar = E.bar(screen)
            XCTAssertLessThanOrEqual(bar.leading.count, E.barSideLimit, "\(screen)")
            XCTAssertLessThanOrEqual(bar.trailing.count, E.barSideLimit, "\(screen)")
        }
    }

    func testParkedWithoutTripHasTheFullBar() {
        let bar = E.bar(.init(tripActive: false, routeActive: false, panning: false, previewing: false))
        XCTAssertEqual(bar.leading, [.trip(active: false), .sound])
        XCTAssertEqual(bar.trailing, [.destinations(routeActive: false), .report])
    }

    func testTripWithoutRouteKeepsSearch() {
        let bar = E.bar(.init(tripActive: true, routeActive: false, panning: false, previewing: false))
        XCTAssertEqual(bar.leading, [.trip(active: true), .sound])
        XCTAssertEqual(bar.trailing, [.destinations(routeActive: false), .report])
    }

    func testGuidingKeepsSearchAndStop() {
        let bar = E.bar(.init(tripActive: true, routeActive: true, panning: false, previewing: false))
        XCTAssertEqual(bar.leading, [.trip(active: true), .sound])
        XCTAssertEqual(bar.trailing, [.destinations(routeActive: true), .report])
    }

    // MARK: - Осмотр

    func testPanningKeepsDoneAndSearch() {
        let bar = E.bar(.init(tripActive: true, routeActive: false, panning: true, previewing: false))
        XCTAssertEqual(bar.trailing, [.panDone], "выход из осмотра — обязательно в баре")
        XCTAssertEqual(bar.leading, [.destinations(routeActive: false)])
    }

    func testOpeningFromPanningClosesItFirst() {
        XCTAssertEqual(E.open(panning: true), .afterClosingPanning)
        XCTAssertEqual(E.open(panning: false), .now)
    }

    func testLeavingPanningBringsTheFullBarBack() {
        let inPanning = E.bar(.init(tripActive: true, routeActive: true, panning: true, previewing: false))
        let after = E.bar(.init(tripActive: true, routeActive: true, panning: false, previewing: false))
        XCTAssertNotEqual(inPanning, after)
        XCTAssertEqual(after.leading.count + after.trailing.count, 4)
    }

    // MARK: - Выбор маршрута

    func testPreviewKeepsCancelAndSearch() {
        let bar = E.bar(.init(tripActive: false, routeActive: true, panning: false, previewing: true))
        XCTAssertEqual(bar.leading, [.cancelPreview])
        XCTAssertEqual(bar.trailing, [.destinations(routeActive: true)])
    }

    // MARK: - Кэш отправленного бара

    func testUnchangedStateIsNotResentAndClearedCacheIs() {
        let screen = E.Screen(tripActive: true, routeActive: false, panning: false, previewing: false)
        var sent: E.BarLayout?
        XCTAssertNotEqual(E.bar(screen), sent, "первая отправка")
        sent = E.bar(screen)
        XCTAssertEqual(E.bar(screen), sent, "то же состояние не шлём: каждая отправка съедает тап")
        sent = nil   // resendButtons: возврат из другого приложения, показ корня
        XCTAssertNotEqual(E.bar(screen), sent, "после сброса — снова")
    }

    func testSoundIsNotPartOfTheLayoutKey() {
        // Значок звука сравнивается отдельно (sentSound); раскладка от него не зависит.
        let screen = E.Screen(tripActive: false, routeActive: false, panning: false, previewing: false)
        XCTAssertEqual(E.bar(screen).leading.filter { $0 == .sound }.count, 1)
    }

    // MARK: - Сетка «Куда»

    func testSearchTileIsFirstInEveryCase() {
        for route in [false, true] {
            for stops in 0...2 {
                for recents in 0...8 {
                    let tiles = E.grid(routeActive: route, slots: 2, stops: stops, recents: recents, limit: 8)
                    XCTAssertEqual(tiles.first, .search)
                    XCTAssertLessThanOrEqual(tiles.count, 8)
                    XCTAssertEqual(Set(tiles).count, tiles.count)
                }
            }
        }
    }

    func testGuidingGridKeepsHomeWorkAndCancelOnHybrid() {
        let tiles = E.grid(routeActive: true, slots: 2, stops: 2, recents: 8, limit: 8)
        XCTAssertEqual(tiles, [.search, .cancelRoute, .overview, .cameras, .slot(0), .slot(1), .stop(0), .stop(1)])
    }

    func testGridWithoutRouteHasRecentsInTheFreePlaces() {
        let tiles = E.grid(routeActive: false, slots: 2, stops: 1, recents: 8, limit: 8)
        XCTAssertEqual(tiles, [.search, .slot(0), .slot(1), .stop(0), .recent(0), .recent(1), .recent(2), .recent(3)])
    }

    // MARK: - Стоянка и ход

    func testParkedOpensTheKeyboard() {
        XCTAssertEqual(E.searchTap(keyboardLimited: false), .keyboard)
    }

    func testMovingGivesAlternativesInsteadOfADeadTile() {
        XCTAssertEqual(E.searchTap(keyboardLimited: true), .alternatives)
    }

    func testMovingListOffersVoiceSlotsRecentsAndCategories() {
        let rows = E.movingRows(keyboardLimited: true, slots: 2, recents: 2, categories: 2, limit: 12)
        XCTAssertEqual(rows, [.voice, .slot(0), .slot(1), .recent(0), .recent(1), .category(0), .category(1)])
    }

    func testStoppingAddsTheKeyboardRowFirst() {
        let rows = E.movingRows(keyboardLimited: false, slots: 1, recents: 0, categories: 1, limit: 12)
        XCTAssertEqual(rows, [.typeAddress, .voice, .slot(0), .category(0)])
    }

    func testMovingListWithoutHomeOrRecentsStillHasAWayOut() {
        let rows = E.movingRows(keyboardLimited: true, slots: 0, recents: 0, categories: 3, limit: 12)
        XCTAssertEqual(rows.first, .voice)
        XCTAssertEqual(rows.count, 4)
    }

    // MARK: - Дом/Работа

    func testUnsetSlotAssignsParkedAndExplainsMoving() {
        XCTAssertEqual(E.slotTap(hasPlace: false, keyboardLimited: false), .assign)
        XCTAssertEqual(E.slotTap(hasPlace: false, keyboardLimited: true), .explain)
    }

    func testSetSlotRoutesEvenWithoutKeyboard() {
        XCTAssertEqual(E.slotTap(hasPlace: true, keyboardLimited: true), .route)
    }

    // MARK: - Выбор результата

    func testNoRouteGoesStraightToChoice() {
        XCTAssertEqual(E.pick(routeActive: false, previewing: false), .route)
    }

    func testReplacingTheGoalAsksStopOrNew() {
        XCTAssertEqual(E.pick(routeActive: true, previewing: false), .askStopOrReplace)
    }

    func testPhoneRouteDuringSearchIsReplacedWithoutAQuestion() {
        // Телефон построил маршрут, в машине открылся выбор, цель ещё не утверждена.
        XCTAssertEqual(E.pick(routeActive: true, previewing: true), .route)
    }

    // MARK: - Пределы списков

    func testListLimitFollowsTheTemplate() {
        XCTAssertEqual(E.listLimit(own: 10, maximumItemCount: 24), 10)
        XCTAssertEqual(E.listLimit(own: 10, maximumItemCount: 6), 6, "на ходу предел шаблона меньше")
    }

    func testMovingListNeverExceedsTheTemplate() {
        for limit in [0, 1, 3, 6, 12] {
            let rows = E.movingRows(keyboardLimited: false, slots: 2, recents: 8, categories: 6, limit: limit)
            XCTAssertLessThanOrEqual(rows.count, limit)
        }
    }

    func testMovingListKeepsVoiceFirstUnderTheSmallestLimit() {
        XCTAssertEqual(E.movingRows(keyboardLimited: true, slots: 2, recents: 8, categories: 6, limit: 1), [.voice])
    }

    // MARK: - Источники

    private struct P: Equatable { let id: Int }

    private func merge(own: [Int], apple: [Int], limit: Int = 10) -> [Int] {
        E.merged(own: own.map(P.init), apple: apple.map(P.init), limit: limit, appleSlots: 3,
                 isSame: { $0 == $1 }).map(\.id)
    }

    func testOfflineIsOwnOnly() {
        XCTAssertEqual(merge(own: [1, 2, 3], apple: []), [1, 2, 3])
    }

    func testOwnBeforeApple() {
        XCTAssertEqual(merge(own: [1, 2], apple: [3, 4]), [1, 2, 3, 4])
    }

    func testAppleKeepsItsPlacesWhenOwnFillsTheList() {
        XCTAssertEqual(merge(own: Array(1...10), apple: [11, 12, 13, 14]),
                       [1, 2, 3, 4, 5, 6, 7, 11, 12, 13])
    }

    func testOwnFillsWhatAppleDidNotUse() {
        XCTAssertEqual(merge(own: Array(1...10), apple: [11]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 11])
    }

    func testSamePlaceFromAppleIsDropped() {
        XCTAssertEqual(merge(own: [1, 2], apple: [2, 3]), [1, 2, 3])
    }

    func testMergeRespectsAnyLimit() {
        for limit in 0...12 {
            XCTAssertLessThanOrEqual(merge(own: Array(1...10), apple: Array(11...20), limit: limit).count, limit)
        }
    }

    func testEmptyAnswerNamesTheReason() {
        XCTAssertEqual(E.empty(online: true), .retry)
        XCTAssertEqual(E.empty(online: false), .offline)
    }

    func testFindWhileSearchingWaitsInsteadOfSayingNothing() {
        XCTAssertEqual(E.listRequest(searching: true), .whenReady)
        XCTAssertEqual(E.listRequest(searching: false), .now)
    }

    // MARK: - Запрос

    func testQueryIsTrimmedAndCapped() {
        XCTAssertEqual(E.normalized("  Навои 12\n", maxLength: 120), "Навои 12")
        XCTAssertEqual(E.normalized(String(repeating: "ў", count: 500), maxLength: 120).count, 120)
    }

    func testVeryShortQueryIsNotSearched() {
        XCTAssertFalse(E.isSearchable(""))
        XCTAssertFalse(E.isSearchable("н"))
        XCTAssertTrue(E.isSearchable("юн"))
    }

    // MARK: - Ответ шаблону и двойные нажатия

    func testReplyIsDeliveredExactlyOnce() {
        var calls = 0
        let reply = CarPlaySearchReply<Int> { _ in calls += 1 }
        reply([])
        reply([1])
        XCTAssertEqual(calls, 1, "машина отключилась, потом пришёл запоздавший ответ — один вызов")
    }

    func testDoubleTapIsSwallowedWhileThePushIsFlying() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(E.pushAllowed(startedAt: nil, now: start, guardSeconds: 1.5))
        XCTAssertFalse(E.pushAllowed(startedAt: start, now: start.addingTimeInterval(0.4), guardSeconds: 1.5))
        XCTAssertTrue(E.pushAllowed(startedAt: start, now: start.addingTimeInterval(1.5), guardSeconds: 1.5),
                      "ответа системы может и не быть — замок отпускает время")
    }

    func testDoubleTapOnAResultBuildsOneRoute() {
        var taps = CarPlayTapGuard()
        let place = SavedPlace(title: "Навои, 12", lat: 41.3, lon: 69.2)
        XCTAssertTrue(taps.begin(CarPlayTapGuard.routeKey(place)))
        XCTAssertFalse(taps.begin(CarPlayTapGuard.routeKey(place)))
    }
}

/// Свой индекс на запросах из машины: письменности, длина, язык.
final class CarPlaySearchQueryTests: XCTestCase {

    private let near = CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)

    private let addresses = #"""
    {"version":1,"streets":[\#
    {"n":"Amir Temur shoh ko'chasi","h":["5","51"],"p":[4131000,6928000,100,0],"a":["Амира Темура проспект"]},\#
    {"n":"Mirzo Ulug'bek shoh ko'chasi","h":["2"],"p":[4132000,6933000]},\#
    {"n":"O'zbekiston ovozi ko'chasi","h":["14"],"p":[4131500,6927000]}]}
    """#

    private func index() throws -> SearchIndex {
        SearchIndex(book: try XCTUnwrap(AddressBook.decode(Data(addresses.utf8))), venues: nil)
    }

    private func found(_ query: String, line: UInt = #line) throws -> [String] {
        let normal = CarPlaySearchEntry.normalized(query, maxLength: AppConfig.carPlaySearchMaxQueryLength)
        return try index().search(normal, near: near, streetLimit: 5, venueLimit: 5).addresses.map(\.street)
    }

    func testRussianCyrillic() throws {
        XCTAssertEqual(try found("Амира Темура").first, "Amir Temur shoh ko'chasi")
    }

    func testUzbekLatinWithApostrophe() throws {
        XCTAssertEqual(try found("Mirzo Ulug'bek").first, "Mirzo Ulug'bek shoh ko'chasi")
    }

    func testUzbekLatinWithoutApostrophe() throws {
        XCTAssertEqual(try found("Mirzo Ulugbek").first, "Mirzo Ulug'bek shoh ko'chasi")
    }

    func testUzbekCyrillic() throws {
        XCTAssertEqual(try found("Мирзо Улуғбек").first, "Mirzo Ulug'bek shoh ko'chasi")
    }

    func testLongFullUzbekNameAndHouse() throws {
        XCTAssertEqual(try found("O‘zbekiston ovozi ko‘chasi 14").first, "O'zbekiston ovozi ko'chasi")
    }

    func testLongRussianPhrase() throws {
        XCTAssertEqual(try found("город Ташкент проспект Амира Темура 51").first, "Amir Temur shoh ko'chasi")
    }

    func testOverlongQueryIsAnsweredAndDoesNotCrash() throws {
        let long = String(repeating: "Mirzo Ulug'bek shoh ko'chasi ", count: 30)
        XCTAssertNoThrow(try found(long))
    }

    func testUnknownAddressFindsNothing() throws {
        XCTAssertEqual(try found("Қўқонбой гузари"), [])
    }
}
