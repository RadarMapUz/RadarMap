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

    /// Срок живёт в самой отметке — по нему она гаснет и в тихом фоне, где
    /// опроса нет (геозоны, уведомление); у базы срока нет вовсе.
    func testExpiryLivesInTheMarker() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func marker(_ expires: Date?) -> Camera {
            Camera(id: 2_000_001, region: "", city: "", location: "", lat: 41.3, lon: 69.2,
                   type: "Тренога", violations: [], needsReview: nil, mobileConfirmed: true,
                   mobileExpires: expires)
        }
        XCTAssertTrue(marker(now.addingTimeInterval(-1)).isExpiredMobile(at: now))
        XCTAssertFalse(marker(now.addingTimeInterval(60)).isExpiredMobile(at: now))
        XCTAssertFalse(marker(nil).isExpiredMobile(at: now), "у камеры базы срока нет")
    }
}
