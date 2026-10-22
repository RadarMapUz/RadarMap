//
//  CarPlayDestinationRouteTests.swift
//  RadarMapTests
//
//  Маршрут к месту из машины — общий для «Куда» и плитки главного экрана:
//  один выбор «ручное → выученное», одно «обычно N мин» и защита от
//  двойного касания (два тапа «Дом» — один запрос OSRM, отчёт качества 22.10).
//

import XCTest
@testable import RadarMap

@MainActor
final class CarPlayDestinationRouteTests: XCTestCase {
    private let manualHome = SavedPlace(title: "ул. Нурафшон, 5", lat: 41.30, lon: 69.25)
    private let learnedHome = FrequentPlaces.Place(kind: .home, lat: 41.31, lon: 69.26, days: 9)
    private let learnedWork = FrequentPlaces.Place(kind: .work, lat: 41.33, lon: 69.28, days: 7)

    func testManualAddressOutranksLearnedPlace() {
        let target = CarPlaySlotTarget.resolve(.home, manual: manualHome, learned: [learnedHome])
        XCTAssertEqual(target, .manual(manualHome))
        XCTAssertEqual(target?.remembers, true, "ручной адрес пишется в «недавние»")
    }

    func testLearnedPlaceForItsOwnSlotOnly() {
        let home = CarPlaySlotTarget.resolve(.home, manual: nil, learned: [learnedWork, learnedHome])
        XCTAssertEqual(home?.saved.lat, learnedHome.lat)
        XCTAssertEqual(home?.saved.title, PlaceSlot.home.name)
        XCTAssertEqual(home?.remembers, false, "выученное в «недавние» не пишем")
        XCTAssertNil(CarPlaySlotTarget.resolve(.work, manual: nil, learned: [learnedHome]),
                     "работы нет ни руками, ни по поездкам — слот «не задан»")
    }

    func testUsualTimeComesFromTheSlotsDirection() {
        let trip = Commute.Trip(id: 1, direction: .toHome, departure: Date(), arrival: Date(),
                                duration: 39 * 60, distanceMeters: 12_000)
        let toHome = Commute.Summary(direction: .toHome, last: trip, usual: 39 * 60,
                                     usualDepartureMinute: nil, lastDelay: nil, best: nil, trips: [trip])
        XCTAssertEqual(CarPlaySlotTarget.usual(.home, commute: [toHome]),
                       String(format: String(localized: "обычно %@"), Formatting.duration(39 * 60)))
        XCTAssertNil(CarPlaySlotTarget.usual(.work, commute: [toHome]), "на работу поездок нет — молчим")
    }

    func testSecondTapWhileBuildingIsRefused() {
        var taps = CarPlayTapGuard()
        let key = CarPlayTapGuard.routeKey(manualHome)
        XCTAssertTrue(taps.begin(key))
        XCTAssertFalse(taps.begin(key), "второй тап «Дом» — не второй запрос OSRM")
        XCTAssertTrue(taps.begin(CarPlayTapGuard.routeKey(SavedPlace(title: "Работа", lat: 41.33, lon: 69.28))),
                      "другая цель — своё построение")
        taps.end(key)
        XCTAssertTrue(taps.begin(key), "построили — следующий тап снова строит")
    }
}
