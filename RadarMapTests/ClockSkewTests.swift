//
//  ClockSkewTests.swift
//  RadarMapTests
//
//  Сроки отметок водителей — по часам сервера, сверяются по часам
//  телефона (S31): разница берётся из заголовка Date ответа.
//

import XCTest
@testable import RadarMap

final class ClockSkewTests: XCTestCase {
    func testHTTPDateParses() throws {
        let date = try XCTUnwrap(APIClient.httpDate("Tue, 20 Oct 2026 10:15:30 GMT"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_792_491_330, accuracy: 0.5)
        XCTAssertNil(APIClient.httpDate("вчера"))
    }

    /// Телефон спешит на 10 минут: срок «через 30 мин по серверу» — через
    /// 30 мин и по телефону, а не через 20.
    func testSkewMovesTheExpiryToThePhoneClock() {
        let server = Date(timeIntervalSince1970: 1_800_000_000)
        let phone = server.addingTimeInterval(600)
        let skew = MobileCameraService.clockSkew(serverDate: server, localNow: phone)
        XCTAssertEqual(skew, 600)
        let expiresOnServer = server.timeIntervalSince1970 + 1800
        let local = Date(timeIntervalSince1970: expiresOnServer + skew)
        XCTAssertEqual(local.timeIntervalSince(phone), 1800, accuracy: 0.001)
    }

    func testNoiseAndAbsurdSkewAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(MobileCameraService.clockSkew(serverDate: now.addingTimeInterval(-2), localNow: now), 0)
        XCTAssertEqual(MobileCameraService.clockSkew(serverDate: now.addingTimeInterval(-3 * 86_400), localNow: now), 0)
        XCTAssertEqual(MobileCameraService.clockSkew(serverDate: nil, localNow: now), 0)
    }
}
