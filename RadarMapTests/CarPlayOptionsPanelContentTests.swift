//
//  CarPlayOptionsPanelContentTests.swift
//  RadarMapTests
//
//  Панель «…» плашки прибытия (25.H1, iOS 27): ближайшие камеры по
//  маршруту, звук одной строкой; обновление — не на каждом фиксе.
//

import XCTest
@testable import RadarMap

final class CarPlayOptionsPanelContentTests: XCTestCase {

    private func camera(_ id: Int, type: String = "Стационар радар") -> Camera {
        Camera(id: id, region: "Т", city: "Ташкент", location: "ул. \(id)",
               lat: 41.3, lon: 69.2, type: type, violations: [], needsReview: nil)
    }

    private func ahead(_ meters: [Double]) -> [RouteCamerasAhead.Item] {
        meters.enumerated().map { RouteCamerasAhead.Item(camera: camera($0.offset + 1), meters: $0.element) }
    }

    func testRowsAreTheNearestWithDistanceAndAddress() {
        let content = CarPlayOptionsPanelContent.content(ahead: ahead([300, 1200, 2500, 4000, 6000, 9000, 12000]),
                                                         sound: .smart, limit: 5,
                                                         distance: { "\(Int($0)) м" })
        XCTAssertEqual(content.cameras.count, 5)
        XCTAssertEqual(content.cameras.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertTrue(content.cameras[0].title.hasPrefix("300 м · "))
        XCTAssertEqual(content.cameras[0].detail, "ул. 1")
    }

    func testNoCamerasAheadMeansAnEmptyList() {
        XCTAssertTrue(CarPlayOptionsPanelContent.content(ahead: [], sound: .smart).cameras.isEmpty)
    }

    func testRefreshOnlyWhenSomethingChanged() {
        let distance: (Double) -> String = { "\(Int($0)) м" }
        let first = CarPlayOptionsPanelContent.content(ahead: ahead([300, 900]), sound: .smart, distance: distance)
        let closer = CarPlayOptionsPanelContent.content(ahead: ahead([280, 880]), sound: .smart, distance: distance)
        let passed = CarPlayOptionsPanelContent.content(ahead: Array(ahead([300, 900]).dropFirst()),
                                                        sound: .smart, distance: distance)
        let muted = CarPlayOptionsPanelContent.content(ahead: ahead([300, 900]), sound: .silent, distance: distance)

        XCTAssertTrue(CarPlayOptionsPanelContent.shouldRefresh(shown: nil, new: first, sinceLast: 0, visible: false))
        XCTAssertFalse(CarPlayOptionsPanelContent.shouldRefresh(shown: first, new: first, sinceLast: 60, visible: true))
        // Цифры: открыта — не чаще интервала; закрыта — не трогаем.
        XCTAssertFalse(CarPlayOptionsPanelContent.shouldRefresh(shown: first, new: closer, sinceLast: 1, visible: true))
        XCTAssertTrue(CarPlayOptionsPanelContent.shouldRefresh(shown: first, new: closer,
                                                               sinceLast: AppConfig.carPlayOptionsPanelRefreshSeconds,
                                                               visible: true))
        XCTAssertFalse(CarPlayOptionsPanelContent.shouldRefresh(shown: first, new: closer, sinceLast: 600, visible: false))
        // Состав: проехали камеру, выключили звук — сразу, открыта или нет.
        XCTAssertTrue(CarPlayOptionsPanelContent.shouldRefresh(shown: first, new: passed, sinceLast: 0, visible: false))
        XCTAssertTrue(CarPlayOptionsPanelContent.shouldRefresh(shown: first, new: muted, sinceLast: 0, visible: true))
    }

    func testSoundToggle() {
        XCTAssertEqual(CarPlayOptionsPanelContent.soundToggle(current: .all, before: nil), .silent)
        XCTAssertEqual(CarPlayOptionsPanelContent.soundToggle(current: .beepOnly, before: nil), .silent)
        // Из тишины — то, что было до неё в машине.
        XCTAssertEqual(CarPlayOptionsPanelContent.soundToggle(current: .silent, before: .all), .all)
        XCTAssertEqual(CarPlayOptionsPanelContent.soundToggle(current: .silent, before: .beepOnly), .beepOnly)
        XCTAssertEqual(CarPlayOptionsPanelContent.soundToggle(current: .silent, before: nil), .smart)
        XCTAssertEqual(CarPlayOptionsPanelContent.soundToggle(current: .silent, before: .silent), .smart)
    }
}
