//
//  DetourAdvisorTests.swift
//  RadarMapTests
//
//  Объезд пробки: ищем только при подтверждённой задержке на своём пути,
//  предлагаем только настоящий выигрыш по другому пути, не надоедаем.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class DetourAdvisorTests: XCTestCase {

    private typealias Advisor = DetourAdvisor

    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Текущий путь — прямо на север по 69.240.
    private var current: [CLLocationCoordinate2D] { [c(41.300, 69.240), c(41.320, 69.240), c(41.340, 69.240)] }
    /// Объезд — восточнее на ~840 м и обратно.
    private var around: [CLLocationCoordinate2D] {
        [c(41.300, 69.240), c(41.302, 69.240), c(41.302, 69.250), c(41.338, 69.250), c(41.338, 69.240), c(41.340, 69.240)]
    }

    private func step(at along: Double, _ text: String, short: String?) -> RouteStep {
        RouteStep(distanceAlong: along, text: text, icon: "arrow.turn.up.right", kind: .right, shortText: short)
    }

    // MARK: - Когда искать

    func testSearchesOnlyOnConfirmedDelay() {
        XCTAssertTrue(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 420, crawl: 0,
                                           sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0))
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 0, crawl: 900,
                                            sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0),
                       "ползём без данных — длина пробки неизвестна, объезд не посчитать")
        XCTAssertTrue(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 150, crawl: 200,
                                           sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0),
                       "ползём и данные подтверждают — ищем раньше")
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 150, crawl: 60,
                                            sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0))
    }

    func testDoesNotNag() {
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 1_500, delayAhead: 900, crawl: 0,
                                            sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0),
                       "почти приехали")
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 900, crawl: 0,
                                            sinceLastSearch: 60, sinceDecline: nil, offersOnRoute: 0))
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 900, crawl: 0,
                                            sinceLastSearch: nil, sinceDecline: 300, offersOnRoute: 0),
                       "отказался — 10 минут тишины")
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 8_000, delayAhead: 900, crawl: 0,
                                            sinceLastSearch: nil, sinceDecline: nil,
                                            offersOnRoute: AppConfig.detourMaxOffersPerRoute))
    }

    // MARK: - Что предлагать

    func testOffersARealSavingAroundTheJam() throws {
        let detour = Advisor.Candidate(points: around, expectedTime: 20 * 60,
                                       steps: [step(at: 220, "Поверните направо на Шота Руставели",
                                                    short: "Поверните направо")])
        let offer = try XCTUnwrap(Advisor.decide(currentRemaining: 30 * 60, current: current, candidates: [detour]))
        XCTAssertEqual(offer.index, 0)
        XCTAssertEqual(offer.saving, 30 * 60 - 20 * 60 - AppConfig.detourSwitchCostSeconds)
        XCTAssertEqual(offer.via, "Шота Руставели")
    }

    func testSmallSavingIsNotWorthTheSwitch() {
        let detour = Advisor.Candidate(points: around, expectedTime: 26 * 60, steps: [])
        XCTAssertNil(Advisor.decide(currentRemaining: 30 * 60, current: current, candidates: [detour]),
                     "4 мин минус цена перестроения — меньше порога")
    }

    func testSamePathIsNotADetour() {
        // OSRM часто отдаёт первым вариантом тот же путь — «быстрее» он лишь
        // потому, что его время посчитано иначе. Это не объезд.
        let same = Advisor.Candidate(points: current, expectedTime: 10 * 60, steps: [])
        XCTAssertNil(Advisor.decide(currentRemaining: 30 * 60, current: current, candidates: [same]))
    }

    func testPicksTheBiggestSaving() throws {
        let slow = Advisor.Candidate(points: around, expectedTime: 22 * 60, steps: [])
        let fast = Advisor.Candidate(points: around.map { c($0.latitude, $0.longitude + 0.003) },
                                     expectedTime: 18 * 60, steps: [])
        XCTAssertEqual(try XCTUnwrap(Advisor.decide(currentRemaining: 30 * 60, current: current,
                                                    candidates: [slow, fast])).index, 1)
    }

    func testOverlapMeasuresSharedPath() {
        XCTAssertEqual(Advisor.overlap(current, with: current), 1, accuracy: 1e-9)
        let parallel = current.map { c($0.latitude, $0.longitude + 0.01) }   // ~840 м восточнее
        XCTAssertEqual(Advisor.overlap(parallel, with: current), 0, accuracy: 1e-9)
    }

    func testStreetNameFromTheManeuverPhrase() {
        XCTAssertEqual(Advisor.streetName(of: step(at: 0, "Поверните налево на Амира Темура",
                                                   short: "Поверните налево")), "Амира Темура")
        XCTAssertNil(Advisor.streetName(of: step(at: 0, "Поверните налево", short: nil)))
    }

    // MARK: - Пробка

    func testCrawlSurvivesShortBurstsAndEndsOnRealMovement() {
        var watch = Advisor.CrawlWatch()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(watch.update(speedKmh: 4, at: t0), 0)
        XCTAssertEqual(watch.update(speedKmh: 6, at: t0 + 60), 60)
        XCTAssertEqual(watch.update(speedKmh: 30, at: t0 + 70), 70, "рывок до следующей стоянки")
        XCTAssertEqual(watch.update(speedKmh: 3, at: t0 + 80), 80)
        _ = watch.update(speedKmh: 40, at: t0 + 100)
        XCTAssertEqual(watch.update(speedKmh: 45, at: t0 + 125), 0, "поехали по-настоящему")
    }
}
