//
//  DetourTriggerTests.swift
//  RadarMapTests
//
//  «Есть путь быстрее» при открытии приложения или экрана машины и при новом
//  файле пробок: проверка раньше, но по тем же порогам и с той же тишиной.
//

import XCTest
@testable import RadarMap

final class DetourTriggerTests: XCTestCase {
    private typealias Advisor = DetourAdvisor

    /// 5 мин подтверждённой задержки при 20-минутном остатке: предложение достижимо.
    private func search(delay: Double = 300, remaining: Double = 8_000, lastSearch: Double? = nil,
                        decline: Double? = nil, unseen: Double? = nil, offers: Int = 0,
                        trigger: Advisor.Trigger) -> Bool {
        Advisor.shouldSearch(remainingDistance: remaining, delayAhead: delay, currentRemaining: 20 * 60,
                             sinceLastSearch: lastSearch, sinceDecline: decline, offersOnRoute: offers,
                             sinceUnseen: unseen, trigger: trigger)
    }

    func testOpeningChecksSoonerThanAFix() {
        XCTAssertFalse(search(lastSearch: 90, trigger: .fix), "на фиксе — раз в 3 минуты")
        XCTAssertFalse(search(lastSearch: 90, trigger: .traffic), "и на файле пробок — так же")
        XCTAssertTrue(search(lastSearch: 90, trigger: .opened), "водитель открыл приложение — посмотреть можно")
        XCTAssertFalse(search(lastSearch: 30, trigger: .opened), "но не на каждое открытие подряд")
    }

    func testOpeningNeverOverridesStay() {
        XCTAssertFalse(search(decline: 120, trigger: .opened), "«Остаться» — 10 минут тишины и при открытии")
        XCTAssertTrue(search(decline: 601, trigger: .opened))
    }

    func testUnseenOfferQuietensVoiceButNotOpening() {
        XCTAssertFalse(search(unseen: 120, trigger: .fix), "голос не повторяется всю пробку")
        XCTAssertFalse(search(unseen: 120, trigger: .traffic))
        XCTAssertTrue(search(unseen: 120, trigger: .opened), "не видел — открыл: показать можно")
    }

    func testNoConfirmedJamMeansNoPromiseEvenOnOpening() {
        XCTAssertFalse(search(delay: 0, trigger: .opened), "нет данных о пробках — экономию не обещаем")
        XCTAssertFalse(search(delay: 200, trigger: .opened), "ниже порога: 3 мин 20 − 1 мин < 3 мин")
    }

    func testLimitsHoldOnOpening() {
        XCTAssertFalse(search(offers: AppConfig.detourMaxOffersPerRoute, trigger: .opened))
        XCTAssertFalse(search(remaining: 1_000, trigger: .opened), "до цели рукой подать")
    }

    func testTrafficRightAfterOpeningCountsAsOpening() {
        XCTAssertEqual(Advisor.effective(.traffic, sinceOpened: 5), .opened)
        XCTAssertEqual(Advisor.effective(.traffic, sinceOpened: AppConfig.detourOpenedWindowSeconds), .traffic)
        XCTAssertEqual(Advisor.effective(.traffic, sinceOpened: nil), .traffic)
        XCTAssertEqual(Advisor.effective(.fix, sinceOpened: 5), .fix, "фикс остаётся фиксом")
    }
}
