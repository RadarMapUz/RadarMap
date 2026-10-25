//
//  StopViewTests.swift
//  RadarMapTests
//
//  «Стоим» с гистерезисом: светофор в 2 с ничего не меняет, пробка «ползком»
//  не качает вид, развилка, взятая в кадр стоя, держится до неё самой;
//  конец пробки на пути вперёд; значки заведений стоя.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class StopViewTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    // MARK: - Гистерезис

    func testStandsOnlyAfterFourSlowSeconds() {
        var t = StopView.Tracker()
        t.update(speedKmh: 40, maneuverDistance: nil, active: true, at: t0)
        XCTAssertFalse(t.update(speedKmh: 0, maneuverDistance: nil, active: true, at: t0 + 1).standing)
        XCTAssertFalse(t.update(speedKmh: 0, maneuverDistance: nil, active: true, at: t0 + 3).standing,
                       "2 с на перекрёстке — ещё не остановка")
        XCTAssertTrue(t.update(speedKmh: 0, maneuverDistance: nil, active: true,
                               at: t0 + 1 + AppConfig.stopViewEnterSeconds).standing)
    }

    func testLeavesAtExitSpeedNotBefore() {
        var t = standing()
        XCTAssertTrue(t.update(speedKmh: 8, maneuverDistance: nil, active: true, at: t0 + 20).standing,
                      "ползком — всё ещё стоим")
        XCTAssertTrue(t.update(speedKmh: 20, maneuverDistance: nil, active: true, at: t0 + 20.5).standing,
                      "рывок на пару метров — тоже")
        XCTAssertFalse(t.update(speedKmh: AppConfig.stopViewExitKmh, maneuverDistance: nil, active: true,
                                at: t0 + 21).standing)
    }

    func testOffTripResets() {
        var t = standing()
        XCTAssertEqual(t.update(speedKmh: 0, maneuverDistance: 100, active: false, at: t0 + 20), .moving)
        XCTAssertFalse(t.update(speedKmh: 0, maneuverDistance: nil, active: true, at: t0 + 21).standing,
                       "после сброса гистерезис заново")
    }

    func testCrawlInJamDoesNotToggle() {
        // Пробка: стоим 12 с, ползём 3–9 км/ч 6 с — по кругу три минуты.
        var t = StopView.Tracker()
        var flips = 0, last = false
        var noise: UInt64 = 0x2545_F491_4F6C_DD1D
        for second in 0..<180 {
            let phase = second % 18
            noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
            let speed = phase < 12 ? 0 : 3 + Double(noise % 600) / 100
            let s = t.update(speedKmh: speed, maneuverDistance: nil, active: true,
                             at: t0 + TimeInterval(second)).standing
            if s != last { flips += 1; last = s }
        }
        XCTAssertEqual(flips, 1, "встали один раз — и стоим, пока ползём")
    }

    func testStopAndGoDoesNotPump() {
        // Рывками: 6 с стоим, 4 с едем 20 км/ч (~22 м) — вид не входит и не
        // выходит на каждом рывке.
        var t = StopView.Tracker()
        var flips = 0, last = false
        for second in 0..<120 {
            let speed = second % 10 < 6 ? 0.0 : 20
            let s = t.update(speedKmh: speed, maneuverDistance: nil, active: true,
                             at: t0 + TimeInterval(second)).standing
            if s != last { flips += 1; last = s }
        }
        XCTAssertEqual(flips, 1, "встали один раз")
    }

    func testStartFromLightLeavesWithinSeconds() {
        // Зелёный: разгон 1,5 м/с² — вид снят на 4–6-й секунде.
        var t = standing()
        var left: Int?
        for second in 1...10 {
            let kmh = 1.5 * Double(second) * 3.6
            if !t.update(speedKmh: kmh, maneuverDistance: nil, active: true,
                         at: t0 + 20 + TimeInterval(second)).standing {
                left = second
                break
            }
        }
        XCTAssertNotNil(left)
        XCTAssertLessThanOrEqual(left ?? 99, 6)
    }

    func testSteadyCrawlEventuallyCountsAsMoving() {
        // 6 км/ч без остановок — это уже езда: через 40 м вид снят.
        var t = standing()
        var left = false
        for second in 1...40 where !left {
            left = !t.update(speedKmh: 6, maneuverDistance: nil, active: true,
                             at: t0 + 20 + TimeInterval(second)).standing
        }
        XCTAssertTrue(left)
    }

    func testReentryWaitsAfterStart() {
        var t = standing()
        XCTAssertFalse(t.update(speedKmh: 30, maneuverDistance: nil, active: true, at: t0 + 20).standing)
        for second in 21...28 {
            XCTAssertFalse(t.update(speedKmh: 0, maneuverDistance: nil, active: true,
                                    at: t0 + TimeInterval(second)).standing,
                           "снова встать — не раньше чем через \(AppConfig.stopViewReenterSeconds) с")
        }
        XCTAssertTrue(t.update(speedKmh: 0, maneuverDistance: nil, active: true,
                               at: t0 + 20 + AppConfig.stopViewReenterSeconds).standing)
    }

    // MARK: - Развилка

    func testWindowOnlyWhileStandingOrHeld() {
        var t = StopView.Tracker()
        XCTAssertNil(t.update(speedKmh: 40, maneuverDistance: 200, active: true, at: t0).maneuverWindow,
                     "на ходу окно — обычное, по скорости")
        let s = standing(turn: 200)
        XCTAssertEqual(s.1.maneuverWindow, AppConfig.stopViewManeuverMeters)
    }

    func testHeldManeuverSurvivesTheStart() {
        var (t, _) = standing(turn: 210)
        // Тронулись к той же развилке — окно держится, пока расстояние убывает.
        var at = t0 + 30
        for d in stride(from: 200.0, through: 60, by: -20) {
            at += 1
            let s = t.update(speedKmh: 30, maneuverDistance: d, active: true, at: at)
            XCTAssertFalse(s.standing)
            XCTAssertEqual(s.maneuverWindow, AppConfig.stopViewManeuverMeters, "к развилке в \(d) м")
        }
        // Проехали: до следующей развилки 900 м — удержание снято.
        XCTAssertNil(t.update(speedKmh: 30, maneuverDistance: 900, active: true, at: at + 1).maneuverWindow)
    }

    func testPositionNoiseKeepsTheHold() {
        var (t, _) = standing(turn: 200)
        XCTAssertNotNil(t.update(speedKmh: 12, maneuverDistance: 205, active: true, at: t0 + 30).maneuverWindow,
                        "+5 м шума — та же развилка")
    }

    func testFarManeuverIsNotHeld() {
        var (t, _) = standing(turn: 400)
        XCTAssertNil(t.update(speedKmh: 30, maneuverDistance: 395, active: true, at: t0 + 30).maneuverWindow)
    }

    // MARK: - Пробка

    private let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)

    /// Путь на север длиной `meters`, уровень по расстоянию от начала.
    private func jam(_ meters: Double, levels: (Double) -> Int?) -> Double? {
        let end = CLLocationCoordinate2D(latitude: start.latitude + meters / 111_320, longitude: start.longitude)
        return StopView.jamEnd(path: [start, end]) { point, _ in
            levels((point.latitude - self.start.latitude) * 111_320)
        }
    }

    func testJamEndWhenWeAreInIt() throws {
        let end = try XCTUnwrap(jam(450) { $0 < 300 ? 3 : 1 })
        XCTAssertEqual(end, 300, accuracy: 26)
    }

    func testJamStartingFarAheadIsNotOurs() {
        XCTAssertNil(jam(450) { $0 > 150 ? 3 : nil }, "пробка в 150 м — не та, в которой стоим")
    }

    func testShortSlowPatchIsNotAJam() {
        XCTAssertNil(jam(450) { $0 < 60 ? 2 : 1 })
    }

    func testShortGapDoesNotSplitTheJam() throws {
        let end = try XCTUnwrap(jam(450) { ($0 > 100 && $0 < 130) ? 1 : ($0 < 300 ? 2 : nil) })
        XCTAssertEqual(end, 300, accuracy: 26, "одно свободное ребро на перекрёстке — та же пробка")
    }

    func testJamToThePathEnd() throws {
        let end = try XCTUnwrap(jam(450) { _ in 3 })
        XCTAssertEqual(end, 450, accuracy: 1)
    }

    func testNoTrafficDataNoJam() {
        XCTAssertNil(jam(450) { _ in nil })
    }

    // MARK: - Детали

    func testDetailOnlyStandingInTripAndCalm() {
        let stand = StopView.State(standing: true, maneuverWindow: nil)
        XCTAssertTrue(StopView.showsDetail(state: stand, tripActive: true, places: true, covered: false,
                                           performance: .full))
        XCTAssertFalse(StopView.showsDetail(state: .moving, tripActive: true, places: true, covered: false,
                                            performance: .full), "на ходу — только дорога")
        XCTAssertFalse(StopView.showsDetail(state: stand, tripActive: true, places: true, covered: true,
                                            performance: .full), "под тревогой камеры — нет")
        XCTAssertFalse(StopView.showsDetail(state: stand, tripActive: true, places: true, covered: false,
                                            performance: .reduced), "горячий телефон — нет")
        XCTAssertFalse(StopView.showsDetail(state: stand, tripActive: true, places: false, covered: false,
                                            performance: .full), "слой «Места» выключен — нет")
    }

    func testShownLayersIsOneDecision() {
        let stand = StopView.State(standing: true, maneuverWindow: nil)
        XCTAssertEqual(StopView.shownLayers(state: stand, tripActive: true, places: true, covered: false,
                                            performance: .full, viewHeight: 667), ["poi-level-1"])
        XCTAssertEqual(StopView.shownLayers(state: stand, tripActive: false, places: true, covered: false,
                                            performance: .full, viewHeight: 852), [], "вне поездки — как было")
    }

    func testSmallScreenGetsOneRowOfPlaces() {
        XCTAssertEqual(StopView.detailLayers(viewHeight: 667), ["poi-level-1"], "SE — не тесно")
        XCTAssertEqual(StopView.detailLayers(viewHeight: 852), ["poi-level-1", "poi-level-2"])
        XCTAssertFalse(StopView.detailLayers(viewHeight: 852).contains("housenumber"))
    }

    // MARK: -

    private func standing(turn: Double? = nil) -> (StopView.Tracker, StopView.State) {
        var t = StopView.Tracker()
        t.update(speedKmh: 40, maneuverDistance: turn, active: true, at: t0)
        var s = StopView.State.moving
        for second in 1...10 {
            s = t.update(speedKmh: 0, maneuverDistance: turn, active: true, at: t0 + TimeInterval(second))
        }
        XCTAssertTrue(s.standing)
        return (t, s)
    }

    private func standing() -> StopView.Tracker { standing(turn: nil).0 }
}
