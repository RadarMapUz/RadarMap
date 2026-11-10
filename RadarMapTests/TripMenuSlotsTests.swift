//
//  TripMenuSlotsTests.swift
//  RadarMapTests
//
//  Меню «…» плитками (этап 45): места постоянные, неприменимое бледнеет,
//  а не исчезает, третий ряд — только на стоянке.
//

import XCTest
@testable import RadarMap

final class TripMenuSlotsTests: XCTestCase {

    private typealias Slots = TripMenuSlots

    /// На ходу — шесть плиток в одном и том же порядке при любом состоянии.
    func testSixFixedSlotsOnTheMove() {
        let situations = [Slots.Situation(),
                          Slots.Situation(hasRoute: true, canShareArrival: true),
                          Slots.Situation(hasRoute: true, isSharingArrival: true),
                          Slots.Situation(offersGoingHome: true)]
        for situation in situations {
            XCTAssertEqual(Slots.tiles(situation).map(\.slot),
                           [.search, .myPlaces, .along, .cameras, .share, .map], "\(situation)")
        }
    }

    /// Стоим — третий ряд снизу, первые два не сдвигаются.
    func testParkedAddsThirdRowBelow() {
        let moving = Slots.tiles(Slots.Situation(hasRoute: true))
        let parked = Slots.tiles(Slots.Situation(hasRoute: true, parked: true))
        XCTAssertEqual(parked.count, 9)
        XCTAssertEqual(Array(parked.prefix(6)), moving)
        XCTAssertEqual(parked.suffix(3).map(\.action), [.stats, .addCamera, .settings])
    }

    /// Поиск уже в доке — первая плитка «Настройки», и в третьем ряду их нет.
    func testSettingsReplaceSearchWhenDockIsOnScreen() {
        let idle = Slots.tiles(Slots.Situation(parked: true, searchOnScreen: true))
        XCTAssertEqual(idle.first?.slot, .search)
        XCTAssertEqual(idle.first?.action, .settings)
        XCTAssertEqual(idle.map(\.action).filter { $0 == .settings }.count, 1)
        XCTAssertEqual(idle.suffix(2).map(\.action), [.stats, .addCamera])
        XCTAssertFalse(idle.contains { $0.action == .search })

        let moving = Slots.tiles(Slots.Situation(searchOnScreen: true))
        XCTAssertEqual(moving.map(\.slot), [.search, .myPlaces, .along, .cameras, .share, .map])
        XCTAssertEqual(moving.first?.action, .settings)

        // В поездке дока нет — поиск остаётся на своём месте.
        XCTAssertEqual(Slots.tiles(Slots.Situation(hasRoute: true)).first?.action, .search)
    }

    /// Без маршрута «По пути» — заправки рядом, «Камеры впереди» — ближайшие.
    func testRouteDependentActions() {
        let route = Slots.tiles(Slots.Situation(hasRoute: true))
        XCTAssertEqual(route[2].action, .alongRoute)
        XCTAssertEqual(route[3].action, .routeCameras)
        let free = Slots.tiles(Slots.Situation())
        XCTAssertEqual(free[2].action, .nearbyStops)
        XCTAssertEqual(free[3].action, .nearbyCameras)
        XCTAssertTrue(free.allSatisfy { $0.slot == .share || $0.enabled })
    }

    /// «Поделиться»: прибытием с маршрутом, «Еду домой» без него, иначе
    /// бледная — но на своём месте.
    func testShareTileNeverDisappears() {
        let pale = Slots.tiles(Slots.Situation())[4]
        XCTAssertEqual(pale.slot, .share)
        XCTAssertFalse(pale.enabled)

        let home = Slots.tiles(Slots.Situation(offersGoingHome: true))[4]
        XCTAssertEqual(home.action, .goingHome)
        XCTAssertTrue(home.enabled)

        let arrival = Slots.tiles(Slots.Situation(hasRoute: true, canShareArrival: true))[4]
        XCTAssertEqual(arrival.action, .shareArrival)
        XCTAssertTrue(arrival.enabled)

        let noServer = Slots.tiles(Slots.Situation(hasRoute: true, canShareArrival: false))[4]
        XCTAssertEqual(noServer.action, .shareArrival)
        XCTAssertFalse(noServer.enabled)

        let live = Slots.tiles(Slots.Situation(hasRoute: true, isSharingArrival: true))[4]
        XCTAssertEqual(live.action, .stopSharing)
        XCTAssertTrue(live.enabled)
    }

    /// С маршрутом и уместным «Еду домой» — выбор из двух: прежнее меню
    /// давало оба пункта, и ни один не теряется.
    func testShareChoiceKeepsGoingHomeWithRoute() {
        let both = Slots.tiles(Slots.Situation(hasRoute: true, canShareArrival: true, offersGoingHome: true))[4]
        XCTAssertEqual(both.action, .shareChoice(arrivalEnabled: true, sharing: false))
        XCTAssertTrue(both.enabled)
        let noServer = Slots.tiles(Slots.Situation(hasRoute: true, offersGoingHome: true))[4]
        XCTAssertEqual(noServer.action, .shareChoice(arrivalEnabled: false, sharing: false))
        let live = Slots.tiles(Slots.Situation(hasRoute: true, isSharingArrival: true, offersGoingHome: true))[4]
        XCTAssertEqual(live.action, .shareChoice(arrivalEnabled: true, sharing: true))
    }

    /// Третий ряд не мигает у 20 км/ч: встаёт ниже 15, уходит от 20.
    func testParkedRowHysteresis() {
        XCTAssertFalse(Slots.parked(speedKmh: 17, wasParked: false, enter: 15, leave: 20))
        XCTAssertTrue(Slots.parked(speedKmh: 14, wasParked: false, enter: 15, leave: 20))
        XCTAssertTrue(Slots.parked(speedKmh: 19, wasParked: true, enter: 15, leave: 20))
        XCTAssertFalse(Slots.parked(speedKmh: 21, wasParked: true, enter: 15, leave: 20))
    }
}
