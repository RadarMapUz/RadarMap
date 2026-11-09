//
//  OnboardingPermissionsTests.swift
//  RadarMapTests
//
//  Главная кнопка разрешений: не уводит дальше, пока есть что спросить, и не
//  бывает мёртвой, когда окон iOS больше не будет.
//

import XCTest
@testable import RadarMap

final class OnboardingPermissionsTests: XCTestCase {

    private func primary(_ location: LocationAccessStep, asked: Bool = true, motion: Bool = false)
        -> OnboardingPermissions.Primary {
        OnboardingPermissions.primary(location: location, notificationsAsked: asked, motionPending: motion)
    }

    func testAsksWhileLocationWindowsRemain() {
        XCTAssertEqual(primary(.askWhenInUse), .ask)
        XCTAssertEqual(primary(.askAlways), .ask)
    }

    func testAsksForTheRestEvenWhenLocationIsRefused() {
        XCTAssertEqual(primary(.openSettings, asked: false), .ask)
        XCTAssertEqual(primary(.deviceLimited, motion: true), .ask)
        XCTAssertEqual(primary(.done, asked: false), .ask)
        XCTAssertEqual(primary(.done, motion: true), .ask)
    }

    func testRefusedLocationLeadsToSettings() {
        XCTAssertEqual(primary(.openSettings), .openSettings)
        XCTAssertEqual(primary(.deviceLimited), .openSettings)
    }

    func testEverythingDecidedMovesOn() {
        XCTAssertEqual(primary(.done), .next)
    }
}
