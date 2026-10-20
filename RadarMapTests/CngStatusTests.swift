//
//  CngStatusTests.swift
//  RadarMapTests
//
//  Метан на АГНКС (12б.4): привязка к станции, когда спрашивать и когда
//  снимать вопрос, порядок в поиске, разбор ответа сервера.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class CngStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let station = CLLocationCoordinate2D(latitude: 41.3123, longitude: 69.2567)

    private func venue(_ kind: Venue.Kind = .cng, at point: CLLocationCoordinate2D? = nil,
                       name: String = "АГНКС") -> Venue {
        Venue(kind: kind, name: name, point: point ?? station)
    }

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(from: station, bearing: 0, distanceMeters: meters)
    }

    func testAskOnlyStandingNearCngStation() {
        XCTAssertNotNil(CngRules.stationToAsk(here: north(40), speedKmh: 0, venues: [venue()], askedAt: [:], now: now))
        XCTAssertNil(CngRules.stationToAsk(here: north(40), speedKmh: 25, venues: [venue()], askedAt: [:], now: now),
                     "за рулём — никогда")
        XCTAssertNil(CngRules.stationToAsk(here: north(120), speedKmh: 0, venues: [venue()], askedAt: [:], now: now),
                     "120 м — проезжая часть перед станцией, а не колонки")
        XCTAssertNil(CngRules.stationToAsk(here: north(30), speedKmh: 0, venues: [venue(.fuel)], askedAt: [:], now: now),
                     "бензиновая АЗС — не метан")
        XCTAssertNil(CngRules.stationToAsk(here: north(30), speedKmh: -1, venues: [venue()], askedAt: [:], now: now),
                     "скорость неизвестна — не «стоим»")
    }

    func testOneQuestionPerStationPerThreeHours() {
        let key = CngRules.stationKey(station)
        XCTAssertNil(CngRules.stationToAsk(here: north(20), speedKmh: 0, venues: [venue()],
                                           askedAt: [key: now.addingTimeInterval(-3600)], now: now))
        XCTAssertNotNil(CngRules.stationToAsk(here: north(20), speedKmh: 0, venues: [venue()],
                                              askedAt: [key: now.addingTimeInterval(-4 * 3600)], now: now))
    }

    func testDrivingOffCancelsTheQuestion() {
        XCTAssertFalse(CngRules.shouldCancel(here: north(40), speedKmh: 4, station: station), "переставил машину к колонке")
        XCTAssertTrue(CngRules.shouldCancel(here: north(40), speedKmh: 25, station: station), "поехал")
        XCTAssertTrue(CngRules.shouldCancel(here: north(300), speedKmh: 0, station: station), "уже не здесь")
    }

    func testSearchOrderGasFirstNoGasLast() throws {
        let a = venue(at: north(100), name: "A"), b = venue(at: north(200), name: "B"), c = venue(at: north(300), name: "C")
        func status(_ point: CLLocationCoordinate2D, _ value: String?) throws -> CngStation {
            let json = """
            {"lat": \(point.latitude), "lon": \(point.longitude), "status": \(value.map { "\"\($0)\"" } ?? "null"),
             "status_age": 5, "queue": null, "queue_age": null, "confirmed": true}
            """
            return try JSONDecoder().decode(CngStation.self, from: Data(json.utf8))
        }
        let stations = [try status(a.point, "nogas"), try status(c.point, "gas")]
        XCTAssertEqual(CngRules.ranked([a, b, c], stations: stations).map(\.name), ["C", "B", "A"])
    }

    func testStationMatchAndCaption() throws {
        let json = """
        {"stations": [{"lat": 41.3123, "lon": 69.2567, "status": "gas", "status_age": 15,
                       "queue": 30, "queue_age": 5, "confirmed": false}]}
        """
        struct Response: Decodable { let stations: [CngStation] }
        let stations = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).stations
        let matched = try XCTUnwrap(CngRules.station(for: north(40), in: stations), "заведение и точка сервера — рядом")
        XCTAssertNil(CngRules.station(for: north(150), in: stations), "соседняя станция — не эта")
        let caption = try XCTUnwrap(CngRules.caption(matched))
        XCTAssertTrue(caption.contains("30"))
        XCTAssertTrue(caption.contains("15"))
        XCTAssertTrue(caption.contains("по словам водителя"), "неподтверждённое так и названо")
    }

    func testStationKeyMatchesServer() {
        // server/api.py: cng_station_key — "%.4f,%.4f".
        XCTAssertEqual(CngRules.stationKey(CLLocationCoordinate2D(latitude: 41.31234, longitude: 69.25678)),
                       "41.3123,69.2568")
    }

    private func decode(_ json: String) throws -> CngStation {
        try JSONDecoder().decode(CngStation.self, from: Data(json.utf8))
    }

    /// Без сети статус стареет сам и снимается: «газ есть, 5 мин назад»
    /// вчерашним утром — хуже, чем ничего.
    func testStatusesAgeOfflineAndExpire() throws {
        let station = try decode("""
        {"lat": 41.3, "lon": 69.2, "status": "gas", "status_age": 10, "queue": 15, "queue_age": 10, "confirmed": true}
        """)
        let fetchedAt = now
        let soon = CngRules.live([station], fetchedAt: fetchedAt, now: now.addingTimeInterval(20 * 60))
        XCTAssertEqual(soon.first?.statusAge, 30)
        let later = CngRules.live([station], fetchedAt: fetchedAt, now: now.addingTimeInterval(60 * 60))
        XCTAssertNil(later.first?.queue, "очередь старше 45 мин — снята")
        XCTAssertEqual(later.first?.status, .gas)
        XCTAssertTrue(CngRules.live([station], fetchedAt: fetchedAt, now: now.addingTimeInterval(4 * 3600)).isEmpty,
                      "статус старше 3 ч — станции нечего сказать")
    }

    /// Один слух «газа нет» не прячет ближайшую АГНКС вниз списка.
    func testUnconfirmedNoGasIsNotDemoted() throws {
        let near = venue(at: north(100), name: "near"), far = venue(at: north(900), name: "far")
        let rumor = try decode("""
        {"lat": \(near.point.latitude), "lon": \(near.point.longitude), "status": "nogas", "status_age": 5,
         "queue": null, "queue_age": null, "confirmed": false}
        """)
        XCTAssertEqual(CngRules.ranked([near, far], stations: [rumor]).map(\.name), ["near", "far"])
    }

    func testThirtyPlusIsNotThirty() {
        XCTAssertTrue(CngRules.queueText(60).contains("30+"), "кнопка «30+» — это «больше 30», а не «~30»")
        XCTAssertTrue(CngRules.ago(130).contains("2"), "больше часа — часами")
    }
}
