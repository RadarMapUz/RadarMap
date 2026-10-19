//
//  OfflineOfferTests.swift
//  RadarMapTests
//
//  Предложение скачать карту: спрашиваем один раз и только в спокойный
//  момент. Тесты держат то, чего быть НЕ должно: вопроса за рулём, по
//  сотовой сети, повторно после ответа.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class OfflineOfferTests: XCTestCase {

    private let calm = OfflineOffer.Situation(
        onboarded: true, answered: false, ownMap: true, driving: false,
        online: true, expensiveNetwork: false, regionAvailable: true)

    func testCalmMomentOffers() {
        XCTAssertTrue(OfflineOffer.shouldOffer(calm))
    }

    func testAnyAnswerClosesTheQuestion() {
        var s = calm
        s.answered = true
        XCTAssertFalse(OfflineOffer.shouldOffer(s), "«Не сейчас» — значит больше не спрашивать")
    }

    /// «Домой» внизу — мегабайты ждут: больше двух карточек внизу нет (5.9).
    func testWaitsWhileADestinationIsSuggested() {
        var situation = calm
        situation.suggestionShown = true
        XCTAssertFalse(OfflineOffer.shouldOffer(situation))
    }

    func testNeverWhileDriving() {
        var s = calm
        s.driving = true
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
    }

    func testNeverOverCellular() {
        var s = calm
        s.expensiveNetwork = true
        XCTAssertFalse(OfflineOffer.shouldOffer(s), "сотни мегабайт по мобильной сети не предлагаем")
        s = calm
        s.online = false
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
    }

    func testNotBeforeOnboardingOrOnAppleMap() {
        var s = calm
        s.onboarded = false
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
        s = calm
        s.ownMap = false
        XCTAssertFalse(OfflineOffer.shouldOffer(s), "на карте Apple офлайн-файлы ничего не дают")
    }

    func testNothingToOfferWhenRegionReadyOrUnknown() {
        var s = calm
        s.regionAvailable = false
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
    }

    func testHomeOutranksCurrentPlace() {
        let home = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
        let learned = CLLocationCoordinate2D(latitude: 41.0, longitude: 69.0)
        let here = CLLocationCoordinate2D(latitude: 39.65, longitude: 66.96)
        XCTAssertEqual(OfflineOffer.anchor(home: home, learnedHome: learned, current: here)?.latitude, 41.31)
        XCTAssertEqual(OfflineOffer.anchor(home: nil, learnedHome: learned, current: here)?.latitude, 41.0)
        XCTAssertEqual(OfflineOffer.anchor(home: nil, learnedHome: nil, current: here)?.latitude, 39.65)
        XCTAssertNil(OfflineOffer.anchor(home: nil, learnedHome: nil, current: nil))
    }
}
