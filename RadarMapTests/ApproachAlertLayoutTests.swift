//
//  ApproachAlertLayoutTests.swift
//  RadarMapTests
//
//  Предупреждение о камере в навигации не закрывает манёвр (аудит 19.10).
//

import XCTest
@testable import RadarMap

final class ApproachAlertLayoutTests: XCTestCase {
    func testNavigationKeepsTheManeuverVisible() {
        XCTAssertEqual(ApproachAlertView.Layout.choose(navigating: true), .bottomCard)
    }

    func testFreeDriveGetsTheFullScreen() {
        XCTAssertEqual(ApproachAlertView.Layout.choose(navigating: false), .fullScreen)
    }

    // MARK: 28.K — камера у старта, маршрут строится медленно

    /// Маршрут построен, поездки нет: «Поехали» внизу обязан остаться виден —
    /// окно уходит наверх карточкой, а не исчезает.
    func testBuiltRouteKeepsGoButtonVisible() {
        let layout = ApproachAlertView.Layout.current(isTripActive: false, hasRoute: true,
                                                      isBuildingRoute: false)
        XCTAssertEqual(layout, .topCard)
        XCTAssertFalse(layout.coversMap, "под карточкой карта рисуется в полную силу")
    }

    /// Маршрут ещё строится — то же место: окно не прыгает с полного экрана
    /// на карточку в момент, когда маршрут приходит.
    func testRouteBeingBuiltAlreadyUsesTheTopCard() {
        XCTAssertEqual(ApproachAlertView.Layout.current(isTripActive: false, hasRoute: false,
                                                        isBuildingRoute: true), .topCard)
    }

    /// Без маршрута — прежний полный экран: смягчение только там, где
    /// под окном есть что нажать.
    func testNoRouteStandingKeepsFullScreen() {
        let layout = ApproachAlertView.Layout.current(isTripActive: false, hasRoute: false,
                                                      isBuildingRoute: false)
        XCTAssertEqual(layout, .fullScreen)
        XCTAssertTrue(layout.coversMap)
    }

    /// Ведение старше выбора: в поездке по маршруту — карточка снизу, даже
    /// если в этот момент идёт перестроение.
    func testNavigationBeatsChoosing() {
        XCTAssertEqual(ApproachAlertView.Layout.current(isTripActive: true, hasRoute: true,
                                                        isBuildingRoute: true), .bottomCard)
    }

    /// Поездка без маршрута, перестроение не в счёт: выбора нет — полный экран.
    func testDrivingWithoutRouteIsFullScreenEvenWhileBuilding() {
        XCTAssertEqual(ApproachAlertView.Layout.current(isTripActive: true, hasRoute: false,
                                                        isBuildingRoute: true), .fullScreen)
    }

    /// Каждая раскладка показывает окно: «не подавлять» — это не флаг, а
    /// отсутствие раскладки «ничего». Перечень исчерпывающий.
    func testEveryCombinationShowsSomething() {
        for trip in [false, true] {
            for route in [false, true] {
                for building in [false, true] {
                    let layout = ApproachAlertView.Layout.current(isTripActive: trip, hasRoute: route,
                                                                  isBuildingRoute: building)
                    XCTAssertTrue([.fullScreen, .bottomCard, .topCard].contains(layout))
                }
            }
        }
    }
}
