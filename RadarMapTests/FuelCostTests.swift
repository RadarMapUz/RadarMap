//
//  FuelCostTests.swift
//  RadarMapTests
//
//  Стоимость дороги (12б.3): единицы, смешанное топливо, округление в сумах,
//  «нет расхода или цены — нет суммы», напоминание о цене и «по нынешней цене».
//

import XCTest
@testable import RadarMap

final class FuelCostTests: XCTestCase {
    private func profile(_ rates: [Fuel: FuelRate], share: Double = 0, updated: Date? = nil) -> FuelProfile {
        FuelProfile(rates: rates, secondShare: share, pricesUpdatedAt: updated)
    }

    func testSingleFuel() {
        // 8 л на 100 км × 12 000 сум/л = 960 сум/км → 25 км = 24 000.
        let petrol = profile([.petrol: FuelRate(per100Km: 8, price: 12_000)])
        XCTAssertEqual(FuelCost.cost(meters: 25_000, profile: petrol, energy: .fuel), 24_000)
        XCTAssertEqual(FuelCost.cost(meters: 1_234, profile: petrol, energy: .fuel), 1_200,
                       "1 184,6 сума → до сотни")
    }

    func testMissingRateGivesNoSum() {
        XCTAssertNil(FuelCost.cost(meters: 10_000, profile: FuelProfile(), energy: .fuel), "цен по умолчанию нет")
        XCTAssertNil(FuelCost.cost(meters: 10_000, profile: profile([.petrol: FuelRate(per100Km: 8, price: 0)]),
                                   energy: .fuel), "без цены — без суммы")
        XCTAssertNil(FuelCost.cost(meters: 10_000, profile: profile([.petrol: FuelRate(per100Km: 8, price: 12_000)]),
                                   energy: .cng), "машина на метане: нужен расход метана")
    }

    func testMixedFuelByShare() {
        // Метан 9 м³ × 5 000 = 450 сум/км, бензин 10 л × 12 000 = 1 200 сум/км;
        // 20 % пробега на бензине: 0,8 × 450 + 0,2 × 1 200 = 600 сум/км.
        let cng = profile([.methane: FuelRate(per100Km: 9, price: 5_000),
                           .petrol: FuelRate(per100Km: 10, price: 12_000)], share: 0.2)
        XCTAssertEqual(FuelCost.cost(meters: 100_000, profile: cng, energy: .cng), 60_000)
        var noShare = cng
        noShare.secondShare = 0
        XCTAssertEqual(FuelCost.cost(meters: 100_000, profile: noShare, energy: .cng), 45_000,
                       "доля ноль — второе топливо не учитывается")
        var noPetrolPrice = cng
        noPetrolPrice.rates[.petrol] = FuelRate(per100Km: 10, price: 0)
        XCTAssertNil(FuelCost.cost(meters: 100_000, profile: noPetrolPrice, energy: .cng),
                     "есть доля, но нет цены второго — суммы нет, а не заниженная")
    }

    func testUnits() {
        XCTAssertEqual(VehicleEnergy.cng.fuels.primary, .methane)
        XCTAssertEqual(VehicleEnergy.lpg.fuels.second, .petrol)
        XCTAssertEqual(VehicleEnergy.electric.fuels.primary, .electricity)
        XCTAssertNil(VehicleEnergy.fuel.fuels.second)
        XCTAssertNotEqual(Fuel.methane.unit, Fuel.petrol.unit, "метан — кубометры, не литры")
    }

    func testRounding() {
        XCTAssertEqual(FuelCost.rounded(9_949), 9_900)
        XCTAssertEqual(FuelCost.rounded(418_600), 419_000)
    }

    func testPriceReminderAndCurrentPriceMark() {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = profile([.petrol: FuelRate(per100Km: 8, price: 12_000)], updated: updated)
        XCTAssertFalse(FuelCost.needsPriceUpdate(profile: fresh, now: updated.addingTimeInterval(59 * 86_400)))
        XCTAssertTrue(FuelCost.needsPriceUpdate(profile: fresh, now: updated.addingTimeInterval(60 * 86_400)))
        XCTAssertFalse(FuelCost.needsPriceUpdate(profile: FuelProfile(), now: updated), "цены нет — напоминать не о чем")
        XCTAssertTrue(FuelCost.isAtCurrentPrice(endedAt: updated.addingTimeInterval(-60), profile: fresh),
                      "поездка до правки цены — посчитана по нынешней")
        XCTAssertFalse(FuelCost.isAtCurrentPrice(endedAt: updated.addingTimeInterval(60), profile: fresh))
    }

    func testCommuteMonth() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func trip(_ daysAgo: Double, km: Double) -> Commute.Trip {
            let departure = now.addingTimeInterval(-daysAgo * 86_400)
            return Commute.Trip(id: daysAgo, direction: .toWork, departure: departure,
                                arrival: departure.addingTimeInterval(1_800), duration: 1_800,
                                distanceMeters: km * 1_000)
        }
        let trips = [trip(1, km: 20), trip(10, km: 20), trip(40, km: 20)]
        XCTAssertEqual(FuelCost.monthly(trips: trips, costPerMeter: 0.96, now: now), 38_000,
                       "две поездки за 30 дней × 20 км × 960 сум/км = 38 400 → 38 000")
        XCTAssertNil(FuelCost.monthly(trips: trips, costPerMeter: nil, now: now))
        XCTAssertNil(FuelCost.monthly(trips: [trip(40, km: 20)], costPerMeter: 0.96, now: now))
    }

    func testProfileSurvivesStorage() throws {
        let original = profile([.methane: FuelRate(per100Km: 9, price: 5_000)], share: 0.25,
                               updated: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(FuelProfile.self, from: data), original)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"methane\""),
                      "ключи словаря — именами, а не массивом пар")
    }
}
