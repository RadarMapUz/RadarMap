//
//  OfflineOfferTests.swift
//  RadarMapTests
//
//  Предложение скачать карту: спрашиваем один раз и только в спокойный
//  момент. Тесты держат то, чего быть НЕ должно: вопроса за рулём, в
//  «Экономии данных», повторно после ответа об этой области.
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
        XCTAssertFalse(OfflineOffer.shouldOffer(s), "размер неизвестен — по сотовой не предлагаем")
        s = calm
        s.online = false
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
    }

    /// Хорезм — 12 МБ, и человек там чаще всего на сотовой.
    func testSmallRegionIsOfferedOverCellular() {
        var s = calm
        s.expensiveNetwork = true
        s.regionBytes = 12_300_000
        XCTAssertTrue(OfflineOffer.shouldOffer(s))
        s.regionBytes = AppConfig.offlineOfferCellularMaxBytes + 1
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
    }

    func testNeverInLowDataMode() {
        var s = calm
        s.expensiveNetwork = true
        s.constrainedNetwork = true
        s.regionBytes = 1_000
        XCTAssertFalse(OfflineOffer.shouldOffer(s))
    }

    func testOfferFollowsWhereThePersonIs() {
        let home = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
        let khorezm = CLLocationCoordinate2D(latitude: 41.55, longitude: 60.63)
        XCTAssertEqual(OfflineOffer.offerPoint(current: khorezm, home: home, learnedHome: nil)?.longitude, 60.63)
        XCTAssertEqual(OfflineOffer.offerPoint(current: nil, home: home, learnedHome: nil)?.longitude, 69.28)
        XCTAssertNil(OfflineOffer.offerPoint(current: nil, home: nil, learnedHome: nil))
    }

    func testAnswerClosesOnlyThatRegion() {
        let answered: Set<String> = ["UZ-XO"]
        XCTAssertTrue(OfflineOffer.wasAnswered(regionID: "UZ-XO", answeredRegions: answered,
                                               legacyAnswered: false, homeRegionID: "UZ-TK"))
        XCTAssertFalse(OfflineOffer.wasAnswered(regionID: "UZ-BU", answeredRegions: answered,
                                                legacyAnswered: false, homeRegionID: "UZ-TK"))
    }

    /// Старый общий флаг: родную область не спрашиваем снова, чужую — один раз.
    func testLegacyAnswerCoversHomeNotTravel() {
        XCTAssertTrue(OfflineOffer.wasAnswered(regionID: "UZ-TK", answeredRegions: [],
                                               legacyAnswered: true, homeRegionID: "UZ-TK"))
        XCTAssertFalse(OfflineOffer.wasAnswered(regionID: "UZ-XO", answeredRegions: [],
                                                legacyAnswered: true, homeRegionID: "UZ-TK"))
        XCTAssertTrue(OfflineOffer.wasAnswered(regionID: "UZ-XO", answeredRegions: [],
                                               legacyAnswered: true, homeRegionID: nil),
                      "дом неизвестен — про какую область был ответ, не знаем: не переспрашиваем")
    }

    func testRegionsRoundTrip() {
        let regions: Set<String> = ["UZ-XO", "UZ-TK"]
        XCTAssertEqual(OfflineOffer.decodeRegions(OfflineOffer.encodeRegions(regions)), regions)
        XCTAssertEqual(OfflineOffer.decodeRegions(nil), [])
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
}
