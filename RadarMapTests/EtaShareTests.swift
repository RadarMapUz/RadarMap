//
//  EtaShareTests.swift
//  RadarMapTests
//
//  «Поделиться прибытием»: ссылку не угадать, на сервер уходят только ключ
//  записи, адрес и четыре поля — ни точки, ни цели, ни устройства; в ссылке —
//  только хэш ключа (14.12).
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

    func testPayloadCarriesOnlyTheKeyAddressAndFourFields() throws {
        let key = EtaShare.makeToken()
        let body = EtaShare.payload(write: .secret(key), arrival: Date(timeIntervalSince1970: 1_760_000_000.4),
                                    remainingMeters: 12_400.6, status: .driving)
        XCTAssertEqual(Set(body.keys), ["key", "token", "eta", "left_m", "status"])
        XCTAssertEqual(body["key"] as? String, key, "пишет ключ")
        XCTAssertEqual(body["token"] as? String, EtaShare.address(forKey: key),
                       "рядом — адрес, для сервера до 14.12; ключом он не служит")
        XCTAssertEqual(body["left_m"] as? Int, 12_401)
        XCTAssertEqual(body["status"] as? String, "driving")
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        for leak in ["lat", "lon", "device", "dest", "name"] {
            XCTAssertFalse(raw.contains(leak), leak)
        }
    }

    // MARK: - Ключ записи отдельно от ссылки (14.12)

    /// Тот же вектор — в server/test_api.py (EtaWriteKeyTest): телефон и
    /// сервер обязаны получать из ключа один и тот же адрес, иначе ссылка
    /// у близкого и запись разойдутся.
    func testAddressMatchesTheServer() {
        XCTAssertEqual(EtaShare.address(forKey: "Zq3xV7kP2mN8rT4wY6bH1c"),
                       "823EP9H7rh1PuBrW-GnHMvJAZH189cTt_vOc6Giih3A")
    }

    /// Адрес — 43 знака base64url: проходит в путь страницы и на старом
    /// сервере (22…64), а длиннее любой ссылки до 14.12 (22) — по этой длине
    /// сервер и отказывает голому token на адрес с ключом.
    func testAddressIsStableUrlSafeAndLongerThanOldLinks() {
        let key = EtaShare.makeToken()
        let address = EtaShare.address(forKey: key)
        XCTAssertEqual(address, EtaShare.address(forKey: key), "один ключ — один адрес")
        XCTAssertEqual(address.count, 43)
        XCTAssertTrue(address.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        XCTAssertNotEqual(address, EtaShare.address(forKey: EtaShare.makeToken()))
        XCTAssertFalse(address.contains(key), "по адресу ключ не прочесть")
    }

    /// В ссылке, которую водитель отправляет, — адрес, а не ключ.
    func testSharedLinkCarriesTheAddressNotTheKey() {
        let key = EtaShare.makeToken()
        let write = EtaShare.WriteKey.secret(key)
        let url = EtaShare.link(base: URL(string: "https://soulmed.uz/radarmap")!, token: write.address)
        XCTAssertEqual(url.lastPathComponent, EtaShare.address(forKey: key))
        XCTAssertFalse(url.absoluteString.contains(key))
    }

    /// Ссылка до 14.12 (только семейная, до своей смены): адрес и есть ключ,
    /// уходит один token — как от старой сборки, и сервер его примет.
    func testLegacyLinkSendsOnlyItsToken() {
        let token = EtaShare.makeToken()
        let write = EtaShare.WriteKey.legacy(token)
        XCTAssertEqual(write.address, token)
        let body = EtaShare.payload(write: write, arrival: Date(timeIntervalSince1970: 1_760_000_000),
                                    remainingMeters: 0, status: .arrived)
        XCTAssertEqual(Set(body.keys), ["token", "eta", "left_m", "status"])
        XCTAssertEqual(body["token"] as? String, token)
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

    // MARK: - Сервер показывает ссылки?

    /// 20.10: на сервере был старый api.py — ссылка ушла знакомому и
    /// открылась `{"error": "not found"}`. Такой ответ — «не умеет».
    func testOldServerWithoutRouteIsUnsupported() {
        XCTAssertEqual(EtaShare.linkSupport(status: 404, contentType: "application/json"), false)
    }

    /// Новый сервер на чужой токен отвечает страницей «ссылка устарела» —
    /// тоже 404, но HTML: адрес есть.
    func testExpiredPageOnNewServerIsSupported() {
        XCTAssertEqual(EtaShare.linkSupport(status: 404, contentType: "text/html; charset=utf-8"), true)
        XCTAssertEqual(EtaShare.linkSupport(status: 200, contentType: "text/html; charset=utf-8"), true)
    }

    /// Сбой сервера — не повод ни отдать мёртвую ссылку, ни запомнить «не умеет».
    func testServerErrorIsUnknown() {
        XCTAssertNil(EtaShare.linkSupport(status: 502, contentType: "text/plain"))
    }

    func testProbeTokenHasValidShape() {
        XCTAssertEqual(EtaShare.probeToken.count, 22)
        XCTAssertTrue(EtaShare.probeToken.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    /// «Умеет» спрашиваем раз в сутки, «не умеет» — снова через 10 мин:
    /// владелец мог выложить сервер, и ссылка должна вернуться без перезапуска.
    func testProbeCadence() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(EtaShare.probeDue(support: nil, lastProbe: nil, now: t0))
        XCTAssertFalse(EtaShare.probeDue(support: false, lastProbe: t0, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(EtaShare.probeDue(support: false, lastProbe: t0,
                                        now: t0.addingTimeInterval(AppConfig.etaShareProbeRetrySeconds)))
        XCTAssertFalse(EtaShare.probeDue(support: true, lastProbe: t0,
                                         now: t0.addingTimeInterval(AppConfig.etaShareProbeRetrySeconds)))
        XCTAssertTrue(EtaShare.probeDue(support: true, lastProbe: t0,
                                        now: t0.addingTimeInterval(AppConfig.etaShareProbeOKSeconds)))
    }
}
