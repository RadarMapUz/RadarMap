//
//  FamilyLinkTests.swift
//  RadarMapTests
//
//  Семейная ссылка (12б.6): живая только по дороге домой, пауза и
//  выключатель гасят её, токен меняется раз в 30 дней, страница постоянная.
//  С 14.12 в ссылке — хэш ключа записи, ключ — только на телефоне; ссылка,
//  созданная раньше, пишет старым токеном до своей смены.
//

import XCTest
@testable import RadarMap

final class FamilyLinkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var arrival: Date { now.addingTimeInterval(1500) }

    func testLiveOnlyOnTheWayHome() {
        let link = FamilyLink.make(name: "Мама", now: now)
        XCTAssertEqual(FamilyShare.phase(link: link, pausedThisTrip: false, isTripActive: true,
                                         ghost: (true, arrival)), .driving(arrival: arrival))
        XCTAssertEqual(FamilyShare.phase(link: link, pausedThisTrip: false, isTripActive: true,
                                         ghost: (false, arrival)), .idle, "на работу — не повод")
        XCTAssertEqual(FamilyShare.phase(link: link, pausedThisTrip: false, isTripActive: true, ghost: nil),
                       .idle, "не узнали дорогу (магазин, друзья) — молчим")
        XCTAssertEqual(FamilyShare.phase(link: link, pausedThisTrip: true, isTripActive: true,
                                         ghost: (true, arrival)), .idle, "пауза на поездку")
        XCTAssertEqual(FamilyShare.phase(link: link, pausedThisTrip: false, isTripActive: false,
                                         ghost: (true, arrival)), .idle)
        var off = link
        off.enabled = false
        XCTAssertEqual(FamilyShare.phase(link: off, pausedThisTrip: false, isTripActive: true,
                                         ghost: (true, arrival)), .idle, "выключатель в настройках")
        XCTAssertEqual(FamilyShare.phase(link: nil, pausedThisTrip: false, isTripActive: true,
                                         ghost: (true, arrival)), .idle)
    }

    func testTokenRotatesEveryThirtyDays() {
        let link = FamilyLink.make(name: "Мама", now: now)
        XCTAssertFalse(link.needsRotation(now: now.addingTimeInterval(29 * 86_400)))
        XCTAssertTrue(link.needsRotation(now: now.addingTimeInterval(30 * 86_400)))
        let rotated = link.rotated(now: now.addingTimeInterval(30 * 86_400))
        XCTAssertNotEqual(rotated.token, link.token)
        XCTAssertNotEqual(rotated.key, link.key, "новый ключ записи — старый у сервера больше не пишет")
        XCTAssertEqual(rotated.token, rotated.key.map(EtaShare.address(forKey:)))
        XCTAssertTrue(rotated.needsResend, "новую ссылку надо переслать")
        XCTAssertEqual(rotated.name, "Мама")
    }

    func testPermanentPageAndEndStatus() throws {
        let link = FamilyLink.make(name: "Мама", now: now)
        let key = try XCTUnwrap(link.key, "новая ссылка — с ключом записи")
        XCTAssertEqual(key.count, 22, "128 бит, base64url")
        let url = link.url(base: URL(string: "https://example.uz/radarmap")!)
        XCTAssertEqual(url.absoluteString,
                       "https://example.uz/radarmap/api/eta/f/\(EtaShare.address(forKey: key))")
        XCTAssertFalse(url.absoluteString.contains(key), "в ссылке у близкого — не ключ, а его хэш")
        XCTAssertEqual(link.token, EtaShare.address(forKey: key), "копия адреса — для сборки до 14.12")
        XCTAssertEqual(link.write, .secret(key))
        XCTAssertEqual(FamilyShare.endStatus(nearHome: true), .arrived)
        XCTAssertEqual(FamilyShare.endStatus(nearHome: false), .ended)
    }

    func testOnlyTheKeyAddressAndFourFieldsLeave() throws {
        let link = FamilyLink.make(name: "Мама", now: now)
        let payload = EtaShare.payload(write: link.write, arrival: arrival, remainingMeters: 0, status: .driving)
        XCTAssertEqual(Set(payload.keys), ["key", "token", "eta", "left_m", "status"],
                       "ни точки, ни имени, ни устройства")
        let raw = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("Мама"))
    }

    /// Ссылка, сохранённая сборкой до 14.12 (без ключа), читается и остаётся
    /// какой была — адрес у близкого тот же, пишет старый токен — до своей
    /// смены через 30 дней; смена даёт ей ключ и просит переслать.
    func testLinkFromBeforeTheKeyKeepsWorkingUntilRotation() throws {
        let old = #"{"token":"Ab3_xY-9qqqqqqqqqqqqqq","createdAt":800000000,"name":"Мама","enabled":true,"needsResend":false}"#
        let link = try JSONDecoder().decode(FamilyLink.self, from: Data(old.utf8))
        XCTAssertNil(link.key)
        XCTAssertEqual(link.write, .legacy("Ab3_xY-9qqqqqqqqqqqqqq"))
        XCTAssertEqual(link.url(base: URL(string: "https://example.uz/radarmap")!).lastPathComponent,
                       "Ab3_xY-9qqqqqqqqqqqqqq", "ссылка у близкого не сменилась сама")
        XCTAssertFalse(link.needsResend, "обновление приложения не просит пересылать")
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertFalse(link.needsRotation(now: created.addingTimeInterval(29 * 86_400)))
        let rotated = link.rotated(now: created.addingTimeInterval(30 * 86_400))
        let key = try XCTUnwrap(rotated.key, "смена даёт ключ записи")
        XCTAssertEqual(rotated.write, .secret(key))
        XCTAssertEqual(rotated.token, EtaShare.address(forKey: key))
        XCTAssertTrue(rotated.needsResend)
    }

    /// Ключ записи переживает перезапуск: ссылка у близкого остаётся живой.
    func testKeySurvivesStorage() throws {
        let link = FamilyLink.make(name: "Мама", now: now)
        let decoded = try JSONDecoder().decode(FamilyLink.self, from: JSONEncoder().encode(link))
        XCTAssertEqual(decoded, link)
        XCTAssertEqual(decoded.write, link.write)
    }
}
