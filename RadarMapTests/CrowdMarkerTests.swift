//
//  CrowdMarkerTests.swift
//  RadarMapTests
//
//  Отметки водителей (сценарии S5, S6, 20.10): срок соблюдается и без
//  сервера; проезд мимо «Поста ДПС» и «ДТП» — не проезд камеры.
//

import XCTest
@testable import RadarMap

final class CrowdMarkerTests: XCTestCase {
    func testExpiredMarkersAreFoundWithoutTheServer() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiries: [Int: Date] = [1: now.addingTimeInterval(-1), 2: now.addingTimeInterval(600), 3: now]
        XCTAssertEqual(MobileCameraService.expired(expiries, now: now), [1, 3])
        XCTAssertTrue(MobileCameraService.expired([:], now: now).isEmpty)
    }

    func testOnlySpeedEnforcementRecordsPasses() {
        XCTAssertFalse(CameraType.dpsPost.recordsPasses, "пост скорость не меряет")
        XCTAssertFalse(CameraType.accident.recordsPasses, "ДТП — тем более")
        for kind: CameraType in [.stationaryCamera, .stationaryRadar, .intelligentRadar, .mobileRadar, .tripod] {
            XCTAssertTrue(kind.recordsPasses, "\(kind)")
        }
    }
}
