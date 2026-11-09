//
//  CarPlaySearchFlowTests.swift
//  RadarMapTests
//
//  Что происходит после выбора результата поиска: варианты стоя, «Поехали»
//  и «Отмена», цель на ходу, маршрут с телефона во время поиска.
//

import XCTest
@testable import RadarMap

final class CarPlaySearchFlowTests: XCTestCase {

    func testParkedPickShowsTheChoice() {
        XCTAssertTrue(CarPlayTripPreview.shouldPreview(speedKmh: 0))
    }

    func testMovingPickGoesWithoutTheChoice() {
        XCTAssertFalse(CarPlayTripPreview.shouldPreview(speedKmh: 40))
    }

    func testCancelOfADestinationAskedInTheCarDropsTheRoute() {
        XCTAssertFalse(CarPlayTripPreview.cancelKeepsRoute(offered: false, tripActive: false, askedInCar: true))
        XCTAssertFalse(CarPlayTripPreview.cancelKeepsRoute(offered: false, tripActive: true, askedInCar: true))
    }

    func testCancelOfAPhoneRouteDuringATripKeepsIt() {
        XCTAssertTrue(CarPlayTripPreview.cancelKeepsRoute(offered: false, tripActive: true, askedInCar: false))
    }

    func testPhoneRouteBuiltDuringSearchOpensTheChoiceParked() {
        XCTAssertEqual(NavigationFlow.carChoice(from: .free, to: .choosing, showing: false,
                                                building: false, moving: false), .show)
    }

    func testPhoneRouteBuiltDuringSearchStaysSilentMoving() {
        XCTAssertNotEqual(NavigationFlow.carChoice(from: .free, to: .choosing, showing: false,
                                                   building: false, moving: true), .show)
    }
}
