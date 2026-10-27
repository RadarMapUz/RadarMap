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
                      battery: Bool = false,
                      limits: Bool = true, trip: Bool) -> MapStatusPick? {
        MapStatusPick.pick(hasServerMessage: server, isOffline: offline, isOverheated: hot,
                           savingBattery: battery, limitsReady: limits, inTrip: trip)
    }

    /// Автоэконом (12.3): на стоянке — после перегрева, до лимитов.
    func testParkedBatteryGoesAfterHeatBeforeLimits() {
        XCTAssertEqual(pick(hot: true, battery: true, trip: false), .overheated)
        XCTAssertEqual(pick(battery: true, limits: false, trip: false), .savingBattery)
    }

    /// За рулём «Экономим батарею» — одной строкой после сети: карта на
    /// глазах становится плоской, и молчать об этом значит «сломалось».
    func testDrivingBatteryLineYieldsOnlyToNetwork() {
        XCTAssertEqual(pick(battery: true, trip: true), .savingBattery)
        XCTAssertEqual(pick(offline: true, battery: true, trip: true), .offline)
        XCTAssertEqual(pick(server: true, hot: true, battery: true, trip: true), .savingBattery)
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
