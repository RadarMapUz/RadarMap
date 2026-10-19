//
//  RemoteSyncRejectTests.swift
//  RadarMapTests
//
//  Отвергнутая база не качается заново (S23), но отказ привязан к самому
//  файлу: перевыпуск под тем же номером, новая сборка или настоящая N+1
//  после чужого манифеста с N+1 — новая попытка (ревью 20.10).
//

import XCTest
@testable import RadarMap

final class RemoteSyncRejectTests: XCTestCase {
    func testRejectionIsBoundToBuildVersionAndSignature() {
        let bad = RemoteSyncService.rejectionKey(version: 12, sig: "AAA", build: "48")
        XCTAssertEqual(bad, RemoteSyncService.rejectionKey(version: 12, sig: "AAA", build: "48"))
        XCTAssertNotEqual(bad, RemoteSyncService.rejectionKey(version: 12, sig: "BBB", build: "48"),
                          "перевыпуск v12 после отката")
        XCTAssertNotEqual(bad, RemoteSyncService.rejectionKey(version: 12, sig: "AAA", build: "49"),
                          "новая сборка разбирает то, что не смогла старая")
        XCTAssertNotEqual(bad, RemoteSyncService.rejectionKey(version: 13, sig: "AAA", build: "48"))
        XCTAssertNotEqual(RemoteSyncService.rejectionKey(version: 12, sig: nil, build: "48"), bad)
    }

    func testOnlyPayloadDefectsAreRemembered() {
        XCTAssertTrue(RemoteDBError.undecodable("x").isPayloadDefect)
        XCTAssertTrue(RemoteDBError.incomplete(count: 3).isPayloadDefect)
        XCTAssertFalse(RemoteDBError.writeFailed("диск полон").isPayloadDefect,
                       "место освободят — подписанная база годна")
    }

    func testFailureNamesTheCause() {
        XCTAssertEqual(RemoteSyncService.failure(for: APIClient.Failure.badStatus(500)), .server)
        XCTAssertEqual(RemoteSyncService.failure(for: APIClient.Failure.transport(URLError(.notConnectedToInternet))),
                       .network)
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        XCTAssertEqual(RemoteSyncService.failure(for: decoding), .server)
        for failure in [RemoteSyncService.Failure.network, .server, .signature, .rejected, .storage] {
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertFalse(failure.message.contains("RadarMap."), "без технического мусора")
        }
    }
}
