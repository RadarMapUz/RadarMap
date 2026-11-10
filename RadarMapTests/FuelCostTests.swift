//
//  FuelCostTests.swift
//  RadarMapTests
//
//  Стоимость дороги (12б.3, с 21.10 — через EnergySplit): единицы,
//  смешанное топливо, округление в сумах, «нет расхода или цены — нет
//  суммы», напоминание о цене и «по нынешней цене», хранение профиля —
//  в том числе чтение профилей, записанных до 21.10.
//

import XCTest
@testable import RadarMap

final class FuelCostTests: XCTestCase {
    private func profile(_ rates: [Fuel: FuelRate], share: Double = 0, updated: Date? = nil) -> FuelProfile {
        FuelProfile(rates: rates, secondShare: share, pricesUpdatedAt: updated)
    }

    /// Стоимость пути одним днём, округлённая для глаз; nil — суммы нет.
    private func cost(_ meters: Double, _ profile: FuelProfile, _ energy: VehicleEnergy) -> Double? {
        EnergySplit.example(meters: meters, model: EnergySplit.model(profile: profile, energy: energy))
            .cost.map(FuelCost.rounded)
    }

    func testSingleFuel() {
        // 8 л на 100 км × 12 000 сум/л = 960 сум/км → 25 км = 24 000.
        let petrol = profile([.petrol: FuelRate(per100Km: 8, price: 12_000)])
        XCTAssertEqual(cost(25_000, petrol, .fuel), 24_000)
        XCTAssertEqual(cost(1_234, petrol, .fuel), 1_200,
                       "малая сумма — до сотни: 1 184,6 → 1 200")
    }

    func testNoPriceNoCost() {
        XCTAssertNil(cost(10_000, FuelProfile(), .fuel), "цен по умолчанию нет")
        XCTAssertNil(cost(10_000, profile([.petrol: FuelRate(per100Km: 8, price: 0)]), .fuel),
                     "расход без цены — суммы нет")
        XCTAssertNil(cost(10_000, profile([.petrol: FuelRate(per100Km: 8, price: 12_000)]), .cng),
                     "у машины на метане основное топливо — метан, его цены нет")
    }

    func testMixedFuel() {
        // Метан 9 м³ × 5 000 = 450 сум/км, бензин 9 л × 12 000 = 1 080 сум/км.
        let rates: [Fuel: FuelRate] = [.methane: FuelRate(per100Km: 9, price: 5_000),
                                       .petrol: FuelRate(per100Km: 9, price: 12_000)]
        let cng = profile(rates, share: 0.2)
        // 0,8 × 450 + 0,2 × 1 080 = 576 сум/км → 100 км = 57 600 → 58 000.
        XCTAssertEqual(cost(100_000, cng, .cng), 58_000)
        let noShare = profile(rates, share: 0)
        XCTAssertEqual(cost(100_000, noShare, .cng), 45_000,
                       "доля 0 — второе топливо не учитывается")
        let noPetrolPrice = profile([.methane: FuelRate(per100Km: 9, price: 5_000)], share: 0.2)
        XCTAssertNil(cost(100_000, noPetrolPrice, .cng),
                     "есть доля бензина, а его цены нет — сумма неполная, лучше без неё")
    }

    func testFuelsByEnergy() {
        XCTAssertEqual(VehicleEnergy.cng.fuels.primary, .methane)
        XCTAssertEqual(VehicleEnergy.lpg.fuels.second, .petrol)
        XCTAssertEqual(VehicleEnergy.electric.fuels.primary, .electricity)
        XCTAssertNil(VehicleEnergy.fuel.fuels.second)
        XCTAssertNil(VehicleEnergy.hev.fuels.second, "гибрид без розетки — только бензин")
        XCTAssertEqual(VehicleEnergy.hybrid.fuels.second, .electricity)
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
            return Commute.Trip(id: departure.timeIntervalSince1970, direction: .toWork, departure: departure,
                                arrival: departure.addingTimeInterval(1_800), duration: 1_800,
                                distanceMeters: km * 1_000)
        }
        let trips = [trip(1, km: 20), trip(10, km: 20), trip(40, km: 20)]
        let petrol = profile([.petrol: FuelRate(per100Km: 8, price: 12_000)])
        let days = trips.map { EnergySplit.Day(day: $0.departure, trips: [
            EnergySplit.Trip(id: $0.id, start: $0.departure, meters: $0.distanceMeters)]) }
        let ledger = EnergySplit.split(days, model: EnergySplit.model(profile: petrol, energy: .fuel))
        let month = ledger.commuteMonth(trips, now: now)
        XCTAssertEqual(month?.cost, 38_000, "две поездки за 30 дней × 20 км × 960 сум/км = 38 400 → 38 000")
        XCTAssertEqual(month?.trips, 2)
        XCTAssertEqual(month?.meters, 40_000)
        let unpriced = EnergySplit.split(days, model: EnergySplit.model(profile: FuelProfile(), energy: .fuel))
        XCTAssertNil(unpriced.commuteMonth(trips, now: now))
        XCTAssertNil(ledger.commuteMonth([trip(40, km: 20)], now: now))
    }

    /// Поездка из журнала дороги, которой уже нет в истории (и в расчёте),
    /// не выпадает из суммы: её путь — по цене километра посчитанных поездок
    /// той же дороги (разбор 10.11: сумма молча занижалась).
    func testCommuteMonthCountsTripsMissingFromTheLedger() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func trip(_ daysAgo: Double) -> Commute.Trip {
            let departure = now.addingTimeInterval(-daysAgo * 86_400)
            return Commute.Trip(id: departure.timeIntervalSince1970, direction: .toHome, departure: departure,
                                arrival: departure.addingTimeInterval(1_800), duration: 1_800,
                                distanceMeters: 20_000)
        }
        let known = trip(1), pruned = trip(20)
        let petrol = profile([.petrol: FuelRate(per100Km: 8, price: 12_000)])
        let days = [EnergySplit.Day(day: known.departure, trips: [
            EnergySplit.Trip(id: known.id, start: known.departure, meters: known.distanceMeters)])]
        let ledger = EnergySplit.split(days, model: EnergySplit.model(profile: petrol, energy: .fuel))
        let month = try XCTUnwrap(ledger.commuteMonth([known, pruned], now: now))
        XCTAssertEqual(month.trips, 2)
        XCTAssertEqual(month.cost, 38_000, "две поездки по 19 200 сум, а не одна")
    }

    func testProfileSurvivesStorage() throws {
        var original = profile([.methane: FuelRate(per100Km: 9, price: 5_000)], share: 0.25,
                               updated: Date(timeIntervalSince1970: 1_800_000_000))
        original.evPassportKm = 120
        original.evCycle = .nedc
        original.chargeSchedule = .everyOtherDay
        original.chargePlace = .both
        original.homeChargeShare = 0.6
        original.stationPrice = 2_500
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(FuelProfile.self, from: data), original)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"methane\""),
                      "ключи словаря — именами, а не массивом пар")
    }

    /// Профиль, записанный до 21.10 (три поля), читается: новые поля пустые,
    /// старая цена электричества — цена ДОМА, старый расход — «с панели».
    func testProfileWrittenBefore21_10Decodes() throws {
        let json = """
        {"rates":{"petrol":{"per100Km":6,"price":13000},"electricity":{"per100Km":15,"price":1000}},
         "secondShare":0.6,"pricesUpdatedAt":800000000}
        """
        let old = try JSONDecoder().decode(FuelProfile.self, from: Data(json.utf8))
        XCTAssertEqual(old.secondShare, 0.6)
        XCTAssertNil(old.evPassportKm)
        XCTAssertNil(old.chargeSchedule)
        XCTAssertNil(old.hybridPlugConfirmed)
        XCTAssertNil(old.setupDone)
        XCTAssertEqual(old.electricityPrice, 1_000, "старая цена электричества — цена дома")
        XCTAssertEqual(old.kWhPer100.value, 15)
        XCTAssertFalse(old.kWhPer100.isEstimate, "введённый расход — не оценка")
        XCTAssertFalse(old.isBlank, "старый профиль — сразу сводка, не мастер")
        // Гибрид до 21.10 без запаса хода считается, как считался: долей.
        let model = EnergySplit.model(profile: old, energy: .hybrid)
        XCTAssertEqual(model.kind, .mixed(primary: .petrol, second: .electricity, secondShare: 0.6))
        // 100 км: 40 км бензина × 6 л × 13 000 + 60 км × 15 кВт·ч × 1 000 = 31 200 + 9 000.
        XCTAssertEqual(EnergySplit.example(meters: 100_000, model: model).cost.map(FuelCost.rounded), 40_000)
    }

    /// Ещё более старый вид: без даты цены — тоже читается.
    func testMinimalOldProfileDecodes() throws {
        let json = #"{"rates":{},"secondShare":0}"#
        let old = try JSONDecoder().decode(FuelProfile.self, from: Data(json.utf8))
        XCTAssertTrue(old.isBlank)
        XCTAssertNil(old.pricesUpdatedAt)
    }

    /// Сырое значение «hybrid» прежних настроек — гибрид с розеткой: так
    /// он и считался; «hev» — новый тип.
    func testVehicleRawValuesStayStable() {
        XCTAssertEqual(VehicleEnergy(rawValue: "hybrid"), .hybrid)
        XCTAssertTrue(VehicleEnergy.hybrid.plugs)
        XCTAssertFalse(VehicleEnergy.hev.plugs)
        XCTAssertEqual(VehicleEnergy(rawValue: "hev"), .hev)
        XCTAssertEqual(VehicleEnergy.hev.stops, [.fuel], "гибриду без розетки плитка «Зарядка» — шум")
        XCTAssertEqual(VehicleEnergy.hybrid.stops, [.charging, .fuel])
        XCTAssertEqual(VehicleEnergy.electric.stops, [.charging])
    }

    /// Гибрид без розетки — обычная машина для обслуживания (масло, свечи);
    /// у электромобиля их нет.
    func testMaintenanceForHybrids() {
        XCTAssertTrue(MaintenanceKind.oil.applies(to: .hev))
        XCTAssertTrue(MaintenanceKind.oil.applies(to: .hybrid))
        XCTAssertFalse(MaintenanceKind.oil.applies(to: .electric))
        XCTAssertFalse(MaintenanceKind.gasCylinder.applies(to: .hev))
    }
}
