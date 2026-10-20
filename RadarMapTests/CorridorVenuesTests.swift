//
//  CorridorVenuesTests.swift
//  RadarMapTests
//
//  «По пути» (19.3): заведения вдоль маршрута — по порядку ВДОЛЬ пути, а не
//  по прямой; только впереди; не дальше полосы; без дублей одной колонки.
//
//  Главный случай — маршрут-подкова: 10 км на север, 3 км на восток и 10 км
//  обратно на юг. Заправка у конца обратной ветки по прямой от старта в
//  трёх километрах, а ехать до неё двадцать два — в списке она обязана
//  стоять после той, что у начала обратной ветки.
//

import CoreLocation
import MapKit
import XCTest
@testable import RadarMap

final class CorridorVenuesTests: XCTestCase {

    private let start = CLLocationCoordinate2D(latitude: 41.000, longitude: 69.000)

    /// Подкова: север 10 км → восток ~3 км → юг 10 км.
    private var horseshoe: [MKMapPoint] {
        [start,
         CLLocationCoordinate2D(latitude: 41.090, longitude: 69.000),
         CLLocationCoordinate2D(latitude: 41.090, longitude: 69.036),
         CLLocationCoordinate2D(latitude: 41.000, longitude: 69.036)].map(MKMapPoint.init)
    }

    private func venue(_ kind: Venue.Kind, _ name: String, _ lat: Double, _ lon: Double) -> Venue {
        Venue(kind: kind, name: name, point: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private func find(_ venues: [Venue], progress: Double = 0,
                      kinds: Set<Venue.Kind> = [.fuel, .cng, .lpg, .charging, .hotel, .food],
                      limit: Int = 300) -> [CorridorVenues.Item] {
        CorridorVenues.find(venues, route: horseshoe, progress: progress, kinds: kinds, limit: limit)
    }

    private func straight(_ venue: Venue) -> Double {
        GeoMath.fastDistance(start.latitude, start.longitude, venue.point.latitude, venue.point.longitude)
    }

    // MARK: - Порядок вдоль пути

    func testHorseshoeOrderFollowsTheRoadNotTheCrowFlight() {
        // Обе — в ~340 м восточнее обратной ветки.
        let top = venue(.fuel, "Верх подковы", 41.085, 69.040)
        let bottom = venue(.fuel, "Низ подковы", 41.005, 69.040)
        // По прямой от старта нижняя ближе — ровно та ловушка, от которой список защищён.
        XCTAssertLessThan(straight(bottom), straight(top))

        let found = find([bottom, top])
        XCTAssertEqual(found.map(\.venue.name), ["Верх подковы", "Низ подковы"])
        XCTAssertEqual(found[0].along, 13_600, accuracy: 300, "10 км на север + 3 км + полкилометра на юг")
        XCTAssertEqual(found[1].along, 22_500, accuracy: 300)
        XCTAssertEqual(found[0].offset, 336, accuracy: 30, "отступ от своей, обратной ветки")
    }

    func testOnlyAheadOfTheCar() {
        let top = venue(.fuel, "Верх подковы", 41.085, 69.040)
        let bottom = venue(.fuel, "Низ подковы", 41.005, 69.040)
        let found = find([top, bottom], progress: 15_000)
        XCTAssertEqual(found.map(\.venue.name), ["Низ подковы"], "проеханная заправка в списке «впереди» не нужна")
        XCTAssertEqual(found[0].ahead(of: 15_000), 7_500, accuracy: 300)
    }

    func testVenueBesideTheCarIsAlreadyPassed() {
        // Машина в 5 км от старта; заправка в 100 м сбоку — её проезжают сейчас.
        let progress = 5_000.0
        let beside = venue(.fuel, "Рядом", 41.0 + progress / 111_320, 69.0012)
        let ahead = venue(.fuel, "Впереди", 41.0 + (progress + 300) / 111_320, 69.0012)
        XCTAssertEqual(find([beside, ahead], progress: progress).map(\.venue.name), ["Впереди"])
    }

    func testCorridorWidth() {
        // Западнее подковы: 1,5 км — заезд, 2,5 км — уже не «по пути».
        let near = venue(.hotel, "Близко", 41.05, 68.982)
        let far = venue(.hotel, "Далеко", 41.05, 68.970)
        let found = find([near, far])
        XCTAssertEqual(found.map(\.venue.name), ["Близко"])
        XCTAssertEqual(found[0].offset, 1_510, accuracy: 40)
    }

    func testBetweenTheLegsIsListedOnce() {
        // Посередине подковы — в 1,5 км от обеих веток: одна строка, а не две.
        let middle = venue(.food, "Посередине", 41.05, 69.018)
        XCTAssertEqual(find([middle]).count, 1)
    }

    func testRouteBehindTheCarFindsNothing() {
        XCTAssertTrue(find([venue(.fuel, "Верх", 41.085, 69.040)], progress: 40_000).isEmpty,
                      "маршрут пройден — впереди ничего")
        XCTAssertTrue(CorridorVenues.find([venue(.fuel, "x", 41, 69)], route: [MKMapPoint(start)],
                                          progress: 0, kinds: [.fuel]).isEmpty)
    }

    // MARK: - Виды

    func testOnlyTheCarsFuelHotelsAndCafes() {
        XCTAssertEqual(CorridorVenues.kinds(fuel: [.cng, .fuel]), [.cng, .fuel, .hotel, .food],
                       "метановой машине — сначала метан, бензин запасом")
        XCTAssertEqual(CorridorVenues.kinds(fuel: [.charging]), [.charging, .hotel, .food])
        let found = find([venue(.charging, "Зарядка", 41.02, 69.001),
                          venue(.fuel, "АЗС", 41.03, 69.001),
                          venue(.pharmacy, "Аптека", 41.04, 69.001)],
                         kinds: Set(CorridorVenues.kinds(fuel: [.fuel])))
        XCTAssertEqual(found.map(\.venue.name), ["АЗС"], "бензиновой машине зарядка и аптека — шум")
    }

    func testGroups() {
        XCTAssertEqual(CorridorVenues.group(of: .cng), .fuel)
        XCTAssertEqual(CorridorVenues.group(of: .lpg), .fuel)
        XCTAssertEqual(CorridorVenues.group(of: .charging), .fuel)
        XCTAssertEqual(CorridorVenues.group(of: .hotel), .hotel)
        XCTAssertEqual(CorridorVenues.group(of: .food), .food)
        XCTAssertNil(CorridorVenues.group(of: .parking))
    }

    // MARK: - Дубли

    func testSameStationTwiceIsOneRowAndKeepsTheName() {
        let unnamed = venue(.fuel, "", 41.030, 69.003)
        let named = venue(.fuel, "Mustang", 41.03018, 69.003)        // 20 м севернее
        let gas = venue(.cng, "Mustang metan", 41.03009, 69.003)     // та же колонка, другой вид
        let neighbour = venue(.fuel, "Сосед", 41.0306, 69.003)       // 60 м — другая АЗС
        let found = find([named, unnamed, gas, neighbour])
        XCTAssertEqual(found.filter { $0.venue.kind == .fuel }.map(\.venue.name), ["Mustang", "Сосед"],
                       "узел и контур одной АЗС — одна строка, и с именем, а не «АЗС»")
        XCTAssertEqual(found.filter { $0.venue.kind == .cng }.count, 1, "метан у той же колонки — свой вид, остаётся")
        XCTAssertEqual(found.first?.along ?? 0, 3_340, accuracy: 30, "место в списке — первой по ходу")
    }

    func testLimitKeepsTheNearestAlongTheRoad() {
        let venues = (0..<10).map { venue(.fuel, "АЗС \($0)", 41.005 + Double($0) * 0.008, 69.001) }
        let found = find(venues.reversed(), limit: 3)
        XCTAssertEqual(found.map(\.venue.name), ["АЗС 0", "АЗС 1", "АЗС 2"])
    }
}
