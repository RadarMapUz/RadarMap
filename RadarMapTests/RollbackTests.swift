//
//  RollbackTests.swift
//  RadarMapTests
//
//  Подпись без защиты от отката (S18): версия базы камер не была подписана
//  — старая подписанная база с версией 999999 запирала обновления навсегда;
//  правки и лимиты принимали прошлую подписанную выкладку.
//

import XCTest
@testable import RadarMap

final class RollbackTests: XCTestCase {
    private typealias Sync = RemoteSyncService

    func testSignedVersionDecides() {
        let release = Sync.DBRelease(version: 12, sha256: "ab", count: 3500)
        XCTAssertEqual(Sync.versionDecision(manifestVersion: 999_999, manifestSHA: nil, releasePresent: true,
                                            release: release, signedSeen: false, current: 11),
                       .download(version: 12, sha256: "ab"), "версия — подписанная, а не из манифеста")
        XCTAssertEqual(Sync.versionDecision(manifestVersion: 12, manifestSHA: nil, releasePresent: true,
                                            release: nil, signedSeen: false, current: 11),
                       .refuse("подписанная версия не прошла проверку"))
        XCTAssertEqual(Sync.versionDecision(manifestVersion: 13, manifestSHA: nil, releasePresent: true,
                                            release: Sync.DBRelease(version: 10, sha256: "x", count: 1),
                                            signedSeen: true, current: 11), .upToDate,
                       "подписанная, но старая — откат не принимается")
    }

    func testUnsignedVersionOnlyDuringTransitionAndWithoutAJump() {
        XCTAssertEqual(Sync.versionDecision(manifestVersion: 12, manifestSHA: "s", releasePresent: false,
                                            release: nil, signedSeen: false, current: 11),
                       .download(version: 12, sha256: "s"))
        if case .refuse = Sync.versionDecision(manifestVersion: 999_999, manifestSHA: nil, releasePresent: false,
                                                release: nil, signedSeen: false, current: 11) {} else {
            XCTFail("скачок без подписи запер бы обновления навсегда")
        }
        if case .refuse = Sync.versionDecision(manifestVersion: 12, manifestSHA: nil, releasePresent: false,
                                                release: nil, signedSeen: true, current: 11) {} else {
            XCTFail("после подписанной версии неподписанная не берётся")
        }
        if case .refuse = Sync.versionDecision(manifestVersion: 12, manifestSHA: nil, releasePresent: false,
                                                release: nil, signedSeen: false, current: 11,
                                                acceptUnsigned: false) {} else {
            XCTFail("переход закрыт флагом")
        }
    }

    func testOlderSignedLimitsAreARollback() {
        let old = LimitsManifest(format: 1, version: 100, files: [])
        XCTAssertEqual(LimitsTrust.decide(signedIndex: .valid(old), ratchetSet: true, lastSignedVersion: 200),
                       .keepVerified)
        XCTAssertEqual(LimitsTrust.decide(signedIndex: .valid(old), ratchetSet: true, lastSignedVersion: 100),
                       .useSigned(old), "та же выкладка — не откат")
    }

    func testOlderOverridesAreARollback() {
        let current = CameraOverrides(version: 7, updatedAt: nil, items: [])
        XCTAssertFalse(CameraOverrideEngine.isNotOlder(CameraOverrides(version: 6, updatedAt: nil, items: []), than: current))
        XCTAssertTrue(CameraOverrideEngine.isNotOlder(CameraOverrides(version: 7, updatedAt: nil, items: []), than: current))
        XCTAssertTrue(CameraOverrideEngine.isNotOlder(CameraOverrides(version: 8, updatedAt: nil, items: []), than: current))
    }
}
