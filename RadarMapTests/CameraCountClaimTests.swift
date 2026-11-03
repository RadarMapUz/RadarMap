//
//  CameraCountClaimTests.swift
//  RadarMapTests
//
//  Цифра в онбординге — правда о встроенной базе: не больше, чем есть, и не
//  отстаёт на сотню (так на витрине висело «3 400+» при 3 698).
//

import XCTest
@testable import RadarMap

final class CameraCountClaimTests: XCTestCase {

    func testClaimIsBundledCountRoundedDown() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cameras", withExtension: "json"))
        let count = try JSONDecoder().decode([Camera].self, from: Data(contentsOf: url)).count
        XCTAssertEqual(AppConfig.cameraCountClaim, count / 100 * 100,
                       "в базе \(count) камер — поправьте AppConfig.cameraCountClaim")
    }
}
