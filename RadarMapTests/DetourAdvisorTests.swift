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

    // MARK: - Синтетический затор в формате now.json (27.E)

    /// now.json, как его пишет traffic_build.py (`[ulat, ulon, vlat, vlon,
    /// level, kmh, model_kmh]`): на нашей улице (69.240) к северу 41.305 →
    /// 41.335 — пробка 8 км/ч против 50 по графу, ребро по ~111 м. Рядом —
    /// шум, который объезд звать не должен: та же пробка на встречной полосе и
    /// свободное ребро на соседней улице.
    private func nowJSON(generated: Date, jamLevel: Int = 3, southbound: Bool = false) -> Data {
        var edges: [String] = []
        var lat = 41.305
        while lat < 41.3349 {
            let (a, b) = southbound ? (lat + 0.001, lat) : (lat, lat + 0.001)
            edges.append(String(format: "[%.5f,69.24000,%.5f,69.24000,%d,8,50]", a, b, jamLevel))
            lat += 0.001
        }
        if !southbound {
            edges.append("[41.33500,69.24000,41.30500,69.24000,3,4,50]")   // встречная полоса
        }
        edges.append("[41.31000,69.25000,41.31100,69.25000,1,48,50]")      // объезд свободен
        let body = "{\"v\":1,\"generated\":\(Int(generated.timeIntervalSince1970)),\"edges\":[\(edges.joined(separator: ","))]}"
        return Data(body.utf8)
    }

    /// Вариант, который уходит с затора на 41.302 и возвращается на него с
    /// 41.310 по 41.330: «объезд» через ту же пробку.
    private var throughTheJam: [CLLocationCoordinate2D] {
        [c(41.300, 69.240), c(41.302, 69.240), c(41.302, 69.250), c(41.310, 69.250), c(41.310, 69.240),
         c(41.330, 69.240), c(41.330, 69.250), c(41.338, 69.250), c(41.338, 69.240), c(41.340, 69.240)]
    }

    func testSyntheticJamFromNowJSONOffersTheRealDetour() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try XCTUnwrap(TrafficSnapshot.decode(nowJSON(generated: now.addingTimeInterval(-90))))
        XCTAssertTrue(snapshot.isFresh(now: now))
        // Задержка на нашем пути — только от нашей полосы: ~3,3 км по 8 км/ч
        // против 50 — около 21 минуты.
        let delayAhead = snapshot.delay(along: current)
        XCTAssertEqual(delayAhead, 3_340 / (8 / 3.6) - 3_340 / (50 / 3.6), accuracy: 60)
        XCTAssertTrue(Advisor.shouldSearch(remainingDistance: 4_400, delayAhead: delayAhead, crawl: 0,
                                           sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0))
        // Варианты оценены той же меркой, что в RouteService.considerDetour:
        // время OSRM + пробки по тому же снимку.
        let currentRemaining = 6 * 60 + delayAhead
        let candidates = [(throughTheJam, 10.0 * 60), (around, 8.0 * 60)].map { points, osrm in
            Advisor.Candidate(points: points, expectedTime: osrm + snapshot.delay(along: points), steps: [])
        }
        XCTAssertGreaterThan(candidates[0].expectedTime, 10 * 60 + 600, "через ту же пробку — с её задержкой")
        XCTAssertEqual(candidates[1].expectedTime, 8 * 60, accuracy: 1, "объезд свободен: свободное ребро ETA не трогает")
        let offer = try XCTUnwrap(Advisor.decide(currentRemaining: currentRemaining, current: current,
                                                 candidates: candidates))
        XCTAssertEqual(offer.index, 1, "предложен объезд, а не вариант через ту же пробку")
        XCTAssertEqual(offer.saving, currentRemaining - 8 * 60 - AppConfig.detourSwitchCostSeconds, accuracy: 1)
    }

    func testOncomingOrStaleOrSlowOnlyJamDoesNotTrigger() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Пробка только на встречной полосе — не наша.
        let oncoming = try XCTUnwrap(TrafficSnapshot.decode(nowJSON(generated: now, southbound: true)))
        XCTAssertEqual(oncoming.delay(along: current), 0)
        XCTAssertFalse(Advisor.shouldSearch(remainingDistance: 4_400, delayAhead: oncoming.delay(along: current),
                                            crawl: 0, sinceLastSearch: nil, sinceDecline: nil, offersOnRoute: 0))
        // Снимок старше 10 минут — RouteService.considerDetour объезд не ищет.
        let stale = try XCTUnwrap(TrafficSnapshot.decode(nowJSON(generated: now.addingTimeInterval(-11 * 60))))
        XCTAssertFalse(stale.isFresh(now: now))
        // «Медленно» на 8 из 50 — уровень 2 тоже задержка (сервер так не
        // пишет, но формат допускает): поиск зовёт задержка, а не цвет.
        let slow = try XCTUnwrap(TrafficSnapshot.decode(nowJSON(generated: now, jamLevel: 2)))
        XCTAssertEqual(slow.delay(along: current), stale.delay(along: current), accuracy: 1)
        // Свободный уровень с той же скоростью — не задержка (данные сервера
        // главнее арифметики телефона).
        let free = try XCTUnwrap(TrafficSnapshot.decode(nowJSON(generated: now, jamLevel: 1)))
        XCTAssertEqual(free.delay(along: current), 0)
    }

    // MARK: - Время на ответ (сценарий D1, 20.10)

    /// Предложение, которого никто не видел (баннер в машине ждёт за камерой
    /// весь её подъезд), не истекает за 20 с от создания; показанное — через
    /// 20 с от показа; вытесненное камерой — снова ждёт экрана с начала.
    @MainActor
    func testOfferTimesFromWhenItIsSeen() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        var offer = RouteService.DetourOffer(id: 1, saving: 480, via: nil, waitingSince: created)
        XCTAssertEqual(offer.expires, created.addingTimeInterval(AppConfig.detourOfferUnseenSeconds))
        offer.shownAt = created.addingTimeInterval(45)
        XCTAssertEqual(offer.expires, created.addingTimeInterval(45 + AppConfig.detourOfferSeconds))
        // Вытеснен баннером камеры через 5 с показа — ждёт экрана заново.
        offer.shownAt = nil
        offer.waitingSince = created.addingTimeInterval(50)
        XCTAssertEqual(offer.expires, created.addingTimeInterval(50 + AppConfig.detourOfferUnseenSeconds))
    }
}
