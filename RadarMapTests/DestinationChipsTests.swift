//
//  DestinationChipsTests.swift
//  RadarMapTests
//
//  Чипы «Домой» / «На работу» главного экрана (этап 45): оба на своих
//  местах всегда, синим — только уверенная догадка, ручной адрес старше
//  выученного.
//

import XCTest
@testable import RadarMap

final class DestinationChipsTests: XCTestCase {

    private let learnedHome = FrequentPlaces.Place(kind: .home, lat: 41.30, lon: 69.20, days: 9)
    private let learnedWork = FrequentPlaces.Place(kind: .work, lat: 41.35, lon: 69.30, days: 6)

    /// Порядок постоянный: «Домой», затем «На работу» — даже без мест.
    func testBothChipsAlwaysInPlace() {
        let empty = DestinationChips.make(manual: [:], learned: [], guess: nil)
        XCTAssertEqual(empty.map(\.kind), [.home, .work])
        XCTAssertTrue(empty.allSatisfy { $0.place == nil && !$0.guessed && $0.minutes == nil })
    }

    /// Синим и с минутами — только догадка; соседний чип — простой.
    func testGuessHighlightsOneChipWithMinutes() {
        let chips = DestinationChips.make(manual: [:], learned: [learnedHome, learnedWork],
                                          guess: (.work, 25 * 60 + 20))
        XCTAssertFalse(chips[0].guessed)
        XCTAssertNil(chips[0].minutes)
        XCTAssertTrue(chips[1].guessed)
        XCTAssertEqual(chips[1].minutes, 25)
    }

    /// Догадка без времени — синим, но без «· N мин».
    func testGuessWithoutTime() {
        let chips = DestinationChips.make(manual: [:], learned: [learnedHome], guess: (.home, nil))
        XCTAssertTrue(chips[0].guessed)
        XCTAssertNil(chips[0].minutes)
    }

    /// Стоим у дома — чип «Домой» бледный, без догадки и минут: маршрут из
    /// дома в дом не предлагаем.
    func testChipAtThePlaceIsNotOffered() {
        let chips = DestinationChips.make(manual: [:], learned: [learnedHome, learnedWork],
                                          guess: (.home, 600), here: (41.3001, 69.2001), atRadius: 150)
        XCTAssertTrue(chips[0].isHere)
        XCTAssertFalse(chips[0].guessed)
        XCTAssertNil(chips[0].minutes)
        XCTAssertFalse(chips[1].isHere)
        XCTAssertFalse(DestinationChips.make(manual: [:], learned: [learnedHome], guess: nil)[0].isHere,
                       "без своей точки «у места» не бывает")
    }

    /// Адрес, заданный рукой, старше выученного.
    func testManualOutranksLearned() {
        let manual = DestinationChips.Place(lat: 41.0, lon: 69.0, title: "ул. Нурафшон, 5")
        let chips = DestinationChips.make(manual: [.home: manual], learned: [learnedHome], guess: nil)
        XCTAssertEqual(chips[0].place, manual)
        XCTAssertNil(chips[1].place)
    }
}
