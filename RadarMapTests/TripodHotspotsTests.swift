//
//  TripodHotspotsTests.swift
//  RadarMapTests
//
//  Подсказка «здесь часто ставят треногу» — единственное место в приложении,
//  где неизвестность означает МОЛЧАНИЕ, а не предупреждение: это догадка о
//  прошлом, а не камера. Поэтому тесты в основном проверяют, когда движок
//  обязан промолчать.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class TripodHotspotsTests: XCTestCase {

    // Опорная точка — перекрёсток в Ташкенте; курс 0° (строго на север).
    private let me = CLLocationCoordinate2D(latitude: 41.3100, longitude: 69.2800)

    /// Точка в `metersAhead` метрах на север и `metersSide` метрах вбок.
    private func spot(ahead metersAhead: Double, side metersSide: Double = 0,
                      n: Int = 5, days: Int = 4, peak: Int = -1) -> TripodHotspots.Spot {
        let dLat = metersAhead / 111_320.0
        let dLon = metersSide / (111_320.0 * cos(me.latitude * .pi / 180))
        return TripodHotspots.Spot(lat: me.latitude + dLat, lon: me.longitude + dLon,
                                   n: n, days: days, peak: peak)
    }

    private func situation(course: CLLocationDegrees = 0,
                           trip: Bool = true,
                           over: Bool = true,
                           hints: Bool = true) -> HotspotAlert.Situation {
        HotspotAlert.Situation(coordinate: me, course: course, isTripActive: trip,
                               isOverspeeding: over, hintsEnabled: hints)
    }

    // MARK: - Когда говорим

    func testSpeaksAboutSpotAhead() {
        let target = spot(ahead: 200)
        XCTAssertEqual(HotspotAlert.spotToAnnounce(in: [target], situation: situation(),
                                                   alreadyVoiced: []), target)
    }

    func testPicksNearestOfSeveralAhead() {
        let near = spot(ahead: 120)
        let far = spot(ahead: 300)
        XCTAssertEqual(HotspotAlert.spotToAnnounce(in: [far, near], situation: situation(),
                                                   alreadyVoiced: []), near)
    }

    // MARK: - Когда молчим

    func testSilentWhenNotOverspeeding() {
        // Главное правило тона: на ежедневном маршруте подсказка при каждом
        // проезде — это шум, от которого она сама перестаёт работать.
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: 200)],
                                                 situation: situation(over: false),
                                                 alreadyVoiced: []))
    }

    func testSilentWhenCourseIsUntrusted() {
        // Курса нет — неизвестно, едем мы к участку или от него. У камеры это
        // повод предупредить, здесь — повод промолчать.
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: 200)],
                                                 situation: situation(course: -1),
                                                 alreadyVoiced: []))
    }

    func testSilentOutsideTrip() {
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: 200)],
                                                 situation: situation(trip: false),
                                                 alreadyVoiced: []))
    }

    func testSilentWhenHintsDisabled() {
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: 200)],
                                                 situation: situation(hints: false),
                                                 alreadyVoiced: []))
    }

    func testSilentAboutSpotBehind() {
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: -150)],
                                                 situation: situation(), alreadyVoiced: []))
    }

    func testSilentAboutSpotTooFarAhead() {
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: 900)],
                                                 situation: situation(), alreadyVoiced: []))
    }

    func testSilentAboutSpotOnParallelStreet() {
        // 120 м вбок на удалении 150 м — это соседняя улица, а не наша.
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [spot(ahead: 150, side: 120)],
                                                 situation: situation(), alreadyVoiced: []))
    }

    func testDoesNotRepeatSpotAlreadyVoiced() {
        let target = spot(ahead: 200)
        XCTAssertNil(HotspotAlert.spotToAnnounce(in: [target], situation: situation(),
                                                 alreadyVoiced: [target.key]))
    }

    // MARK: - Ключ и подписи

    func testKeyIsStableForSameCoordinateAndDiffersForOthers() {
        let a = spot(ahead: 200)
        let again = TripodHotspots.Spot(lat: a.lat, lon: a.lon, n: 9, days: 9, peak: 2)
        XCTAssertEqual(a.key, again.key, "ключ обязан зависеть только от места")
        XCTAssertNotEqual(a.key, spot(ahead: 800).key)
    }

    func testPeakTitleIsNilWhenThereIsNoPeak() {
        XCTAssertNil(spot(ahead: 100, peak: -1).peakTitle)
        XCTAssertNotNil(spot(ahead: 100, peak: 1).peakTitle)
    }

    func testPhraseCarriesNoDistance() {
        // Это свойство участка, а не «камера через 300 метров»: точность здесь
        // была бы обещанием, которого у нас нет.
        let phrase = HotspotAlert.phrase(for: spot(ahead: 200, peak: -1))
        XCTAssertFalse(phrase.contains("300"))
        XCTAssertFalse(phrase.contains("метр"))
    }

    func testCaptionMentionsCountAndDays() {
        let caption = spot(ahead: 100, n: 7, days: 5).caption
        XCTAssertTrue(caption.contains("7"))
        XCTAssertTrue(caption.contains("5"))
    }

    // MARK: - Контракт с сервером

    func testDecodesServerPayload() throws {
        // Ровно тот JSON, который печатает server/build_hotspots.py.
        let json = """
        {"version":1,"generated":"2026-08-10","window_days":90,\
        "spots":[{"lat":41.31,"lon":69.28,"n":7,"days":5,"peak":1}]}
        """
        let decoded = try JSONDecoder().decode(TripodHotspots.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isUsable)
        XCTAssertEqual(decoded.spots.count, 1)
        XCTAssertEqual(decoded.spots[0].n, 7)
        XCTAssertEqual(decoded.spots[0].peak, 1)
    }

    func testForeignContractVersionIsNotUsable() {
        let payload = TripodHotspots(version: 2, spots: [spot(ahead: 100)])
        XCTAssertFalse(payload.isUsable, "чужой формат честнее счесть пустым")
        XCTAssertTrue(TripodHotspots.empty.spots.isEmpty)
    }
}
