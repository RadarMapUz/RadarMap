//
//  TileServerHealthTests.swift
//  RadarMapTests
//
//  Сервер карты лёг при живой связи (S22): несколько отказов подряд за окно —
//  «недоступен», первый успех — снова на месте; плашка не врёт «нет связи».
//

import XCTest
@testable import RadarMap

final class TileServerHealthTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSeveralFailuresInAWindowMeanDown() {
        var health = TileServerHealth()
        for i in 0..<(AppConfig.tileServerFailureThreshold - 1) {
            XCTAssertFalse(health.noteFailure(at: t0.addingTimeInterval(Double(i))))
        }
        XCTAssertFalse(health.isDown)
        XCTAssertTrue(health.noteFailure(at: t0.addingTimeInterval(5)), "порог — смена состояния")
        XCTAssertTrue(health.isDown)
        XCTAssertFalse(health.noteFailure(at: t0.addingTimeInterval(6)), "уже недоступен — не сообщать снова")
        XCTAssertTrue(health.noteSuccess())
        XCTAssertFalse(health.isDown)
    }

    func testScatteredFailuresAreNotAnOutage() {
        var health = TileServerHealth()
        for i in 0..<10 {
            _ = health.noteFailure(at: t0.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertFalse(health.isDown, "по одному в минуту — сеть шумит, сервер на месте")
        var mixed = TileServerHealth()
        for i in 0..<8 {
            _ = i % 2 == 0 ? mixed.noteFailure(at: t0.addingTimeInterval(Double(i))) : mixed.noteSuccess()
        }
        XCTAssertFalse(mixed.isDown, "тайлы приходят — сервер жив")
    }

    func testNoticeSaysServerNotNetwork() {
        XCTAssertNil(OfflineNotice.resolve(online: true, modernMap: true, hasRegionFiles: false))
        XCTAssertEqual(OfflineNotice.resolve(online: true, modernMap: true, hasRegionFiles: false, serverDown: true),
                       .serverDown)
        XCTAssertEqual(OfflineNotice.resolve(online: true, modernMap: true, hasRegionFiles: true, serverDown: true),
                       .serverDownRegion)
        XCTAssertEqual(OfflineNotice.resolve(online: false, modernMap: true, hasRegionFiles: true, serverDown: true),
                       .downloadedRegion, "сети нет — главное «нет связи»")
    }
}
