//
//  MapStatusPickTests.swift
//  RadarMapTests
//
//  Баннеры над картой (5.2): в поездке — только «нет сети, камеры
//  предупреждают»; остальное ждёт остановки, порядок на стоянке прежний.
//

import XCTest
@testable import RadarMap

final class MapStatusPickTests: XCTestCase {
    private func pick(server: Bool = false, offline: Bool = false, hot: Bool = false,
                      limits: Bool = true, trip: Bool) -> MapStatusPick? {
        MapStatusPick.pick(hasServerMessage: server, isOffline: offline, isOverheated: hot,
                           limitsReady: limits, inTrip: trip)
    }

    func testParkedOrderIsServerNetworkHeatLimits() {
        XCTAssertEqual(pick(server: true, offline: true, hot: true, limits: false, trip: false), .server)
        XCTAssertEqual(pick(offline: true, hot: true, limits: false, trip: false), .offline)
        XCTAssertEqual(pick(hot: true, limits: false, trip: false), .overheated)
        XCTAssertEqual(pick(limits: false, trip: false), .noSpeedLimits)
        XCTAssertNil(pick(trip: false))
    }

    /// За рулём объявление, перегрев и лимиты ждут остановки.
    func testWhileDrivingOnlyTheNetworkSpeaks() {
        XCTAssertNil(pick(server: true, hot: true, limits: false, trip: true))
        XCTAssertEqual(pick(server: true, offline: true, trip: true), .offline,
                       "серая карта без объяснения читается как поломка — сеть важнее объявления")
    }

    func testDrivingBannerIsOneLine() {
        XCTAssertTrue(MapStatusPick.isCompact(inTrip: true))
        XCTAssertFalse(MapStatusPick.isCompact(inTrip: false))
    }
}
