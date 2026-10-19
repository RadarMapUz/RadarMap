//
//  ApproachAlertLayoutTests.swift
//  RadarMapTests
//
//  Предупреждение о камере в навигации не закрывает манёвр (аудит 19.10).
//

import XCTest
@testable import RadarMap

final class ApproachAlertLayoutTests: XCTestCase {
    func testNavigationKeepsTheManeuverVisible() {
        XCTAssertEqual(ApproachAlertView.Layout.choose(navigating: true), .bottomCard)
    }

    func testFreeDriveGetsTheFullScreen() {
        XCTAssertEqual(ApproachAlertView.Layout.choose(navigating: false), .fullScreen)
    }
}
