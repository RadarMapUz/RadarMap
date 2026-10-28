//
//  RouteShownTimeTests.swift
//  RadarMapTests
//
//  Решения 28.10 по времени варианта: личный темп — во ВСЕХ показанных
//  временах (крупная цифра и флажок прибытия согласованы), а подпись
//  задержки говорит, живые это пробки или «обычно в это время».
//

import MapKit
import XCTest
@testable import RadarMap

@MainActor
final class RouteShownTimeTests: XCTestCase {

    private func variant(minutes: Double, km: Double = 15, delay: TimeInterval? = nil,
                         source: TrafficForecast.Source? = nil, live: TimeInterval? = nil,
                         pace: Double = 1) -> RouteService.Variant {
        let points = [MKMapPoint(CLLocationCoordinate2D(latitude: 41.28, longitude: 69.20)),
                      MKMapPoint(CLLocationCoordinate2D(latitude: 41.36, longitude: 69.29))]
        var v = RouteService.Variant(id: 0, points: points, polyline: MKPolyline(points: points, count: 2),
                                     distance: km * 1000, travelTime: minutes * 60, cameras: [], steps: [])
        v.trafficDelay = delay
        v.trafficSource = source
        v.trafficLiveDelay = live
        v.paceFactor = pace
        return v
    }

    // MARK: - Личный темп (наблюдение 4)

    /// Симуляция 27.10: «24 мин · 🏁 16:25» при темпе 1,12 — цифра по
    /// варианту, флажок по темпу. Теперь оба — 26,9 мин.
    func testPaceMakesTheBigNumberAndTheFlagOneTime() {
        let v = variant(minutes: 24, delay: 0, source: .live, live: 0, pace: 1.12)
        XCTAssertEqual(v.shownTime, 24 * 60 * 1.12, accuracy: 0.001)
        XCTAssertEqual(v.etaText, Formatting.duration(24 * 60 * 1.12))
        XCTAssertEqual(v.expectedTime, 24 * 60, "выбор и порядок вариантов — без темпа")
        // Флажок: остаток на старте (весь путь, задержки варианта) — то же время.
        let initial = RouteService.initialRemainingDelays(v.trafficDelay, source: v.trafficSource)
        let flag = RouteService.remainingEstimate(v, remainingDistance: v.distance,
                                                  liveDelay: initial.live, typicalDelay: initial.typical)
        XCTAssertEqual(flag, v.shownTime, accuracy: 0.001)
    }

    func testPaceAppliesToGraphTimeNotToTheJam() {
        // 24 мин графа + 5 мин пробок по профилю, темп 1,12: пробка — не манера езды.
        let v = variant(minutes: 24, delay: 300, source: .mixed, live: 0, pace: 1.12)
        XCTAssertEqual(v.shownTime, 24 * 60 * 1.12 + 300, accuracy: 0.001)
        let initial = RouteService.initialRemainingDelays(v.trafficDelay, source: v.trafficSource)
        XCTAssertEqual(RouteService.remainingEstimate(v, remainingDistance: v.distance, liveDelay: initial.live,
                                                      typicalDelay: initial.typical),
                       v.shownTime, accuracy: 0.001)
        // Полпути — половина времени графа с темпом.
        XCTAssertEqual(RouteService.remainingEstimate(v, remainingDistance: v.distance / 2, liveDelay: 0,
                                                      typicalDelay: 0),
                       12 * 60 * 1.12, accuracy: 0.001)
    }

    func testOwnRoadTimeIsNotPacedTwice() {
        var v = variant(minutes: 24, delay: 300, source: .live, pace: 1.12)
        v.assessment.myRoad = RouteChoice.Personal(direction: .toWork, trips: 12, seconds: 31 * 60)
        XCTAssertEqual(v.shownTime, 31 * 60, "своя дорога — уже по своим поездкам")
    }

    // MARK: - Подпись причины (наблюдение 3)

    func testCaptionSaysUsualWhenTheDelayIsMostlyTheProfile() {
        // Свежий now.json пуст на нашем пути, 10 мин — из профиля.
        let usual = variant(minutes: 24, delay: 600, source: .mixed, live: 0)
        XCTAssertEqual(usual.trafficNote,
                       String(format: String(localized: "обычно +%@ в это время"),
                              Formatting.unbreakable(Formatting.duration(600))))
        let typical = variant(minutes: 24, delay: 600, source: .typical, live: 0)
        XCTAssertEqual(typical.trafficNote, usual.trafficNote)
    }

    func testCaptionSaysJamsWhenLiveIsAtLeastHalf() {
        let jams = String(format: String(localized: "+%@ из-за пробок"),
                          Formatting.unbreakable(Formatting.duration(600)))
        XCTAssertEqual(variant(minutes: 24, delay: 600, source: .mixed, live: 300).trafficNote, jams)
        XCTAssertEqual(variant(minutes: 24, delay: 600, source: .live, live: 600).trafficNote, jams)
        XCTAssertEqual(variant(minutes: 24, delay: 600, source: .live).trafficNote, jams,
                       "без разбивки живой источник — живые пробки")
        XCTAssertNotEqual(variant(minutes: 24, delay: 600, source: .mixed, live: 299).trafficNote, jams)
    }

    func testFreeAndNoDataCaptionsUnchanged() {
        XCTAssertEqual(variant(minutes: 24, delay: 20, source: .live, live: 20).trafficNote,
                       String(localized: "без пробок"))
        XCTAssertNil(variant(minutes: 24).trafficNote, "нет данных — ни слова")
        XCTAssertNil(variant(minutes: 24, delay: 20, source: .typical, live: 0).trafficNote,
                     "«обычно» без задержки — не «без пробок»")
    }
}
