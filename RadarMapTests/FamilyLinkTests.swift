//
//  FamilyLinkTests.swift
//  RadarMapTests
//
//  Семейная ссылка (12б.6): живая только по дороге домой, пауза и
//  выключатель гасят её, токен меняется раз в 30 дней, страница постоянная.
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
        XCTAssertTrue(rotated.needsResend, "новую ссылку надо переслать")
        XCTAssertEqual(rotated.name, "Мама")
    }

    func testPermanentPageAndEndStatus() {
        let link = FamilyLink.make(name: "Мама", now: now)
        let url = link.url(base: URL(string: "https://example.uz/radarmap")!)
        XCTAssertEqual(url.absoluteString, "https://example.uz/radarmap/api/eta/f/\(link.token)")
        XCTAssertEqual(link.token.count, 22, "128 бит, base64url")
        XCTAssertEqual(FamilyShare.endStatus(nearHome: true), .arrived)
        XCTAssertEqual(FamilyShare.endStatus(nearHome: false), .ended)
    }

    func testOnlyFourFieldsLeave() {
        let payload = EtaShare.payload(token: "t", arrival: arrival, remainingMeters: 0, status: .driving)
        XCTAssertEqual(Set(payload.keys), ["token", "eta", "left_m", "status"], "ни точки, ни имени, ни устройства")
    }
}
