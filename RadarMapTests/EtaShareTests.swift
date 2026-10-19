//
//  EtaShareTests.swift
//  RadarMapTests
//
//  «Поделиться прибытием»: ссылку не угадать, на сервер уходят только
//  четыре поля — ни точки, ни цели, ни устройства.
//

import XCTest
@testable import RadarMap

final class EtaShareTests: XCTestCase {

    func testTokenIsUnguessableAndUrlSafe() {
        let a = EtaShare.makeToken(), b = EtaShare.makeToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 22, "128 бит в base64url без заполнения")
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testLinkPointsAtThePage() {
        let url = EtaShare.link(base: URL(string: "https://soulmed.uz/radarmap")!, token: "abc")
        XCTAssertEqual(url.absoluteString, "https://soulmed.uz/radarmap/api/eta/abc")
    }

    func testPayloadCarriesOnlyFourFields() throws {
        let body = EtaShare.payload(token: "t", arrival: Date(timeIntervalSince1970: 1_760_000_000.4),
                                    remainingMeters: 12_400.6, status: .driving)
        XCTAssertEqual(Set(body.keys), ["token", "eta", "left_m", "status"])
        XCTAssertEqual(body["left_m"] as? Int, 12_401)
        XCTAssertEqual(body["status"] as? String, "driving")
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        for leak in ["lat", "lon", "device", "dest", "name"] {
            XCTAssertFalse(raw.contains(leak), leak)
        }
    }

    /// В пробке с тем же прибытием ссылка не дёргает радио каждую минуту;
    /// сдвиг прибытия, остатка или долгая тишина — шлём (аудит энергии 19.10).
    func testUpdateIsSentOnlyWhenSomethingChanged() {
        let t0 = Date(timeIntervalSince1970: 1_760_900_000)
        let eta = t0.addingTimeInterval(1800)
        XCTAssertTrue(EtaShare.shouldSend(lastArrival: nil, lastRemaining: nil, lastSentAt: nil,
                                          arrival: eta, remaining: 9000, now: t0), "первое — всегда")
        XCTAssertFalse(EtaShare.shouldSend(lastArrival: eta, lastRemaining: 9000, lastSentAt: t0,
                                           arrival: eta.addingTimeInterval(20), remaining: 8800,
                                           now: t0.addingTimeInterval(60)))
        XCTAssertTrue(EtaShare.shouldSend(lastArrival: eta, lastRemaining: 9000, lastSentAt: t0,
                                          arrival: eta.addingTimeInterval(150), remaining: 8800,
                                          now: t0.addingTimeInterval(60)), "прибытие сдвинулось")
        XCTAssertTrue(EtaShare.shouldSend(lastArrival: eta, lastRemaining: 9000, lastSentAt: t0,
                                          arrival: eta, remaining: 8400,
                                          now: t0.addingTimeInterval(60)), "проехали полкилометра")
        XCTAssertTrue(EtaShare.shouldSend(lastArrival: eta, lastRemaining: 9000, lastSentAt: t0,
                                          arrival: eta, remaining: 9000,
                                          now: t0.addingTimeInterval(AppConfig.etaShareKeepAliveSeconds)),
                      "ссылка не должна погаснуть")
    }
}
