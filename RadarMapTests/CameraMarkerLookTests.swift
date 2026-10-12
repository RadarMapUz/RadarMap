//
//  CameraMarkerLookTests.swift
//  RadarMapTests
//
//  Вариант B: цвет — только у камер на нашем пути, тревога сверху, ни одна
//  камера не пропадает, пометки не спорят с тревогой.
//

import XCTest
@testable import RadarMap

final class CameraMarkerLookTests: XCTestCase {

    private typealias Look = CameraMarkerLook

    func testColourMeansOnOurPath() {
        let path = Look.pathIDs(route: [(id: 1, along: 100), (id: 2, along: 900), (id: 3, along: 2_500)],
                                progress: 1_000, passedTolerance: 30, nearest: nil)
        XCTAssertEqual(path, [3], "позади по маршруту — уже не на пути")
        XCTAssertEqual(Look.tier(id: 3, alert: nil, path: path), .path)
        XCTAssertEqual(Look.tier(id: 1, alert: nil, path: path), .calm)
        XCTAssertEqual(Look.tier(id: 9, alert: nil, path: path), .calm, "соседний квартал — спокойная")
    }

    func testJustPassedCameraStillCountsWithinGPSNoise() {
        let path = Look.pathIDs(route: [(id: 1, along: 990)], progress: 1_000, passedTolerance: 30, nearest: nil)
        XCTAssertEqual(path, [1])
    }

    func testWithoutRouteTheHUDCameraIsOnThePath() {
        // Без маршрута — та же камера, что в HUD «136 м до камеры».
        let path = Look.pathIDs(route: [], progress: nil, passedTolerance: 30, nearest: 7)
        XCTAssertEqual(path, [7])
        XCTAssertEqual(Look.pathIDs(route: [(id: 1, along: 500)], progress: nil, passedTolerance: 30,
                                    nearest: nil), [], "маршрута нет — его камеры не наши")
    }

    func testAlertOutranksEverything() {
        XCTAssertEqual(Look.tier(id: 4, alert: 4, path: []), .alert)
        XCTAssertEqual(Look.tier(id: 4, alert: 4, path: [4]), .alert)
        XCTAssertGreaterThan(Look.sortKey(.alert), Look.sortKey(.path))
        XCTAssertGreaterThan(Look.sortKey(.path), Look.sortKey(.calm))
    }

    func testEveryCameraHasAnIcon() {
        // Спокойная — тот же значок тише, а не пропажа.
        for tier in [Look.Tier.calm, .path, .alert] {
            for daylight in [true, false] {
                XCTAssertFalse(Look.icon(symbol: "camera.fill", tier: tier, daylight: daylight).isEmpty)
            }
        }
        XCTAssertNotEqual(Look.icon(symbol: "camera.fill", tier: .calm, daylight: true),
                          Look.icon(symbol: "camera.fill", tier: .calm, daylight: false),
                          "графит дня и ночи разный")
        XCTAssertEqual(Look.icon(symbol: "camera.fill", tier: .alert, daylight: true), "camera.fill-alert")
    }

    func testBadges() {
        XCTAssertEqual(Look.badge(tier: .calm, unconfirmed: true, familiar: false), Look.ghostBadge)
        XCTAssertEqual(Look.badge(tier: .alert, unconfirmed: true, familiar: false), Look.ghostBadge,
                       "слух остаётся слухом и в тревоге")
        XCTAssertEqual(Look.badge(tier: .path, unconfirmed: false, familiar: true), Look.ownBadge)
        XCTAssertEqual(Look.badge(tier: .alert, unconfirmed: false, familiar: true), "",
                       "идёт предупреждение — «своя» лишняя")
        XCTAssertEqual(Look.badge(tier: .calm, unconfirmed: false, familiar: false), "")
    }

    func testDotsSpeakTheSameLanguage() {
        XCTAssertEqual(Look.dotColor(typeHex: "#D93025", tier: .calm, daylight: true), Look.neutralDay)
        XCTAssertEqual(Look.dotColor(typeHex: "#D93025", tier: .calm, daylight: false), Look.neutralNight)
        XCTAssertEqual(Look.dotColor(typeHex: "#D93025", tier: .path, daylight: true), "#D93025")
        XCTAssertEqual(Look.dotColor(typeHex: "#D93025", tier: .alert, daylight: false), "#D93025")
    }
}
