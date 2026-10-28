//
//  NearestCameraReadoutTests.swift
//  RadarMapTests
//
//  «До камеры» — один облик на стоянке, в поездке и в навигации (33H3).
//  Красный и полоса близости — только в оповещении, по тому же признаку,
//  что красил HUD до объединения: камера в радиусе, позиция не грубая.
//

import XCTest
@testable import RadarMap

final class NearestCameraReadoutTests: XCTestCase {

    func testRedOnlyInsideTheAlertRadius() {
        XCTAssertTrue(NearestCameraReadout.isAlerting(distance: 250, radius: 400, positionCoarse: false))
        XCTAssertTrue(NearestCameraReadout.isAlerting(distance: 400, radius: 400, positionCoarse: false),
                      "на самой границе радиуса оповещение уже идёт")
        XCTAssertFalse(NearestCameraReadout.isAlerting(distance: 401, radius: 400, positionCoarse: false))
        XCTAssertFalse(NearestCameraReadout.isAlerting(distance: 3000, radius: 400, positionCoarse: false))
    }

    /// Цифра от грубого фикса (кэш при запуске, Wi-Fi в помещении) на
    /// красный права не имеет — даже «внутри» радиуса.
    func testCoarsePositionNeverPaintsRed() {
        XCTAssertFalse(NearestCameraReadout.isAlerting(distance: 100, radius: 400, positionCoarse: true))
    }
}
