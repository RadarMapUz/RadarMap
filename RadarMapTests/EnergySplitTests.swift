//
//  EnergySplitTests.swift
//  RadarMapTests
//
//  Электричество и бензин по дням (21.10, 21.2) — на профиле владельца:
//  гибрид с розеткой, CLTC 120 км (реально ≈ 90), заряд каждую ночь дома.
//  Город до 90 км в день — всё на электричестве; Самарканд — 90 + 210;
//  «через день» — второй день наполовину на бензине; трасса тратит заряд
//  быстрее; без цен — километры без суммы; гибрид без розетки — только бензин.
//

import XCTest
@testable import RadarMap

final class EnergySplitTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }()

    /// Полночь N-го дня от опорной даты.
    private func day(_ index: Int) -> Date {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        return calendar.date(byAdding: .day, value: index, to: base)!
    }

    /// Гибрид владельца: 120 км по CLTC, 18,3 кВт·ч, 5,5 л в гибридном режиме.
    private func owner(schedule: ChargeSchedule = .nightly, prices: Bool = true) -> FuelProfile {
        var profile = FuelProfile()
        profile.evPassportKm = 120
        profile.evCycle = .cltc
        profile.batteryKWh = 18.3
        profile.chargeSchedule = schedule
        profile.chargePlace = .home
        profile.rates = [.petrol: FuelRate(per100Km: 5.5, price: prices ? 13_000 : 0),
                         .electricity: FuelRate(per100Km: 0, price: prices ? 1_000 : 0)]
        return profile
    }

    private func trip(_ dayIndex: Int, hour: Double = 9, km: Double, highwayKm: Double? = nil,
                      work: Bool = false) -> EnergySplit.Trip {
        let start = day(dayIndex).addingTimeInterval(hour * 3_600)
        return EnergySplit.Trip(id: start.timeIntervalSince1970, start: start, meters: km * 1_000,
                                highwayMeters: highwayKm.map { $0 * 1_000 }, work: work)
    }

    private func split(_ days: [EnergySplit.Day], _ profile: FuelProfile,
                       _ energy: VehicleEnergy = .hybrid) -> EnergySplit.Ledger {
        EnergySplit.split(days, model: EnergySplit.model(profile: profile, energy: energy), calendar: calendar)
    }

    // MARK: - Профиль

    func testRealRangeAndConsumptionFromPassport() {
        let profile = owner()
        XCTAssertEqual(profile.realRangeKm!, 90, accuracy: 0.001, "CLTC 120 × 0,75")
        // 18,3 кВт·ч × 0,9 ÷ 90 км × 100 = 18,3 кВт·ч на 100 км.
        XCTAssertEqual(profile.kWhPer100.value, 18.3, accuracy: 0.001)
        XCTAssertFalse(profile.kWhPer100.isEstimate)

        var nedc = profile
        nedc.evCycle = .nedc
        XCTAssertEqual(nedc.realRangeKm!, 96, accuracy: 0.001)
        var wltp = profile
        wltp.evCycle = .wltp
        XCTAssertEqual(wltp.realRangeKm!, 108, accuracy: 0.001)
        var own = profile
        own.evRealKm = 80
        XCTAssertEqual(own.realRangeKm, 80, "свой реальный запас выше паспорта")

        var unknown = FuelProfile()
        unknown.evPassportKm = 120
        XCTAssertEqual(unknown.kWhPer100.value, 16, "без ёмкости и панели — типичный расход")
        XCTAssertTrue(unknown.kWhPer100.isEstimate, "и он подписан «оценка»")
        unknown.rates[.electricity] = FuelRate(per100Km: 15.8, price: 0)
        XCTAssertEqual(unknown.kWhPer100.value, 15.8, "цифра с панели — первая")
    }

    func testElectricityPriceByPlace() {
        var profile = owner()
        profile.stationPrice = 3_000
        XCTAssertEqual(profile.electricityPrice, 1_000, "дома — домашний тариф")
        profile.chargePlace = .station
        XCTAssertEqual(profile.electricityPrice, 3_000)
        profile.chargePlace = .both
        profile.homeChargeShare = 0.7
        XCTAssertEqual(profile.electricityPrice!, 1_600, accuracy: 0.001, "0,7 × 1 000 + 0,3 × 3 000")
        profile.stationPrice = nil
        XCTAssertNil(profile.electricityPrice, "и там и там — нужны обе цены, иначе суммы нет")
    }

    // MARK: - Владелец

    /// Город до 90 км в день при зарядке каждую ночь — всё на электричестве.
    func testCityDaysAreAllElectric() {
        let days = (0..<5).map { index in
            EnergySplit.Day(day: day(index), trips: [trip(index, hour: 8, km: 22), trip(index, hour: 18, km: 24),
                                                     trip(index, hour: 20, km: 40)])
        }
        let ledger = split(days, owner())
        let total = ledger.days.values.reduce(EnergySplit.Use(), +)
        XCTAssertEqual(total.electricShare!, 1, accuracy: 0.0001, "86 км в день — заряд не кончается")
        XCTAssertEqual(total.meters(.petrol), 0)
        // 430 км × 18,3 кВт·ч на 100 км = 78,69 кВт·ч × 1 000 сум.
        XCTAssertEqual(total.amount[.electricity]!, 78.69, accuracy: 0.01)
        XCTAssertEqual(total.cost!, 78_690, accuracy: 1)
    }

    /// Самарканд: 300 км за день — 90 км на электричестве, 210 на бензине.
    func testLongDayIsElectricThenPetrol() {
        let ledger = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 300)])], owner())
        let use = ledger.days[day(0)]!
        XCTAssertEqual(use.meters(.electricity), 90_000, accuracy: 0.5)
        XCTAssertEqual(use.meters(.petrol), 210_000, accuracy: 0.5)
        // 90 км × 18,3 = 16,47 кВт·ч × 1 000 + 210 км × 5,5 л = 11,55 л × 13 000.
        XCTAssertEqual(use.amount[.electricity]!, 16.47, accuracy: 0.01)
        XCTAssertEqual(use.amount[.petrol]!, 11.55, accuracy: 0.01)
        XCTAssertEqual(use.cost!, 16_470 + 150_150, accuracy: 1)
        XCTAssertEqual(use.noSpeedProfileMeters, 300_000, "профиля скорости нет — трасса не учтена, и это видно")
    }

    /// Поездки дня — по порядку: утренняя на электричестве, вечерняя добирает бензин.
    func testTripsOfTheDaySpendChargeInOrder() {
        let morning = trip(0, hour: 8, km: 70)
        let evening = trip(0, hour: 19, km: 40)
        let ledger = split([EnergySplit.Day(day: day(0), trips: [evening, morning])], owner())
        let first = ledger.trips[morning.id!]!.use
        let second = ledger.trips[evening.id!]!.use
        XCTAssertEqual(first.meters(.electricity), 70_000, accuracy: 0.5)
        XCTAssertEqual(first.meters(.petrol), 0)
        XCTAssertEqual(second.meters(.electricity), 20_000, accuracy: 0.5, "заряда осталось на 20 км")
        XCTAssertEqual(second.meters(.petrol), 20_000, accuracy: 0.5)
    }

    /// «Через день»: два дня по 60 км — первый на электричестве, второй
    /// 30 км на остатке заряда и 30 на бензине; третий — снова полный.
    func testEveryOtherDaySchedule() {
        let days = (0..<3).map { EnergySplit.Day(day: day($0), trips: [trip($0, km: 60)]) }
        let ledger = split(days, owner(schedule: .everyOtherDay))
        XCTAssertEqual(ledger.days[day(0)]!.meters(.electricity), 60_000, accuracy: 0.5)
        XCTAssertEqual(ledger.days[day(0)]!.meters(.petrol), 0)
        XCTAssertEqual(ledger.days[day(1)]!.meters(.electricity), 30_000, accuracy: 0.5)
        XCTAssertEqual(ledger.days[day(1)]!.meters(.petrol), 30_000, accuracy: 0.5)
        XCTAssertEqual(ledger.days[day(2)]!.meters(.electricity), 60_000, accuracy: 0.5, "день 3 — снова заряжен")
    }

    /// После недели стоянки «через день» — снова полный заряд: отсчёт от
    /// последней зарядки, а не от календаря.
    func testChargeAfterAGap() {
        let days = [EnergySplit.Day(day: day(0), trips: [trip(0, km: 80)]),
                    EnergySplit.Day(day: day(5), trips: [trip(5, km: 80)])]
        let ledger = split(days, owner(schedule: .everyOtherDay))
        XCTAssertEqual(ledger.days[day(5)]!.meters(.electricity), 80_000, accuracy: 0.5)
    }

    func testWeeklySchedule() {
        let days = (0..<8).map { EnergySplit.Day(day: day($0), trips: [trip($0, km: 30)]) }
        let ledger = split(days, owner(schedule: .weekly))
        // 90 км заряда на неделю: три дня по 30 — электричество, дальше бензин до 7-го дня.
        XCTAssertEqual(ledger.days[day(2)]!.meters(.electricity), 30_000, accuracy: 0.5)
        XCTAssertEqual(ledger.days[day(3)]!.meters(.electricity), 0, accuracy: 0.5)
        XCTAssertEqual(ledger.days[day(6)]!.meters(.petrol), 30_000, accuracy: 0.5)
        XCTAssertEqual(ledger.days[day(7)]!.meters(.electricity), 30_000, accuracy: 0.5, "через неделю — снова полный")
    }

    /// «Почти никогда» — постоянная доля (прежний ползунок), а не заряд дня.
    func testRarelyUsesTheShare() {
        var profile = owner(schedule: .rarely)
        profile.secondShare = 0.1
        let use = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 50)])], profile).days[day(0)]!
        XCTAssertEqual(use.meters(.electricity), 5_000, accuracy: 0.5)
        XCTAssertEqual(use.meters(.petrol), 45_000, accuracy: 0.5)
    }

    /// Трасса тратит заряд в 1,3 раза быстрее: на 100 км трассы заряда
    /// хватает на 90 ÷ 1,3 ≈ 69 км, кВт·ч — вся батарея.
    func testHighwayDrainsTheBatteryFaster() {
        let ledger = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 100, highwayKm: 100)])], owner())
        let use = ledger.days[day(0)]!
        XCTAssertEqual(use.meters(.electricity), 90_000 / 1.3, accuracy: 1)
        XCTAssertEqual(use.meters(.petrol), 100_000 - 90_000 / 1.3, accuracy: 1)
        XCTAssertEqual(use.amount[.electricity]!, 90 * 0.183, accuracy: 0.01, "потрачена вся батарея — 16,47 кВт·ч")
        XCTAssertEqual(use.highwayMeters, 100_000)
        XCTAssertEqual(use.noSpeedProfileMeters, 0)
        // Город той же длины — запас по городу.
        let city = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 100, highwayKm: 0)])], owner())
        XCTAssertEqual(city.days[day(0)]!.meters(.electricity), 90_000, accuracy: 0.5)
    }

    /// Нет цен — нет суммы, но километры и кВт·ч видны.
    func testMissingPricesKeepKilometres() {
        let use = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 120)])], owner(prices: false)).days[day(0)]!
        XCTAssertNil(use.cost)
        XCTAssertEqual(use.meters(.electricity), 90_000, accuracy: 0.5)
        XCTAssertEqual(use.meters(.petrol), 30_000, accuracy: 0.5)
        XCTAssertEqual(use.electricShare!, 0.75, accuracy: 0.0001)
        XCTAssertEqual(use.missingPrice, [.electricity, .petrol])
        XCTAssertNotNil(use.amount[.electricity])
    }

    /// Только электричество без цены бензина — день в городе всё равно с суммой.
    func testElectricOnlyDayNeedsOnlyItsPrice() {
        var profile = owner()
        profile.rates[.petrol] = FuelRate(per100Km: 5.5, price: 0)
        let use = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 30)])], profile).days[day(0)]!
        XCTAssertNotNil(use.cost, "бензин не тратили — его цена не нужна")
    }

    /// Гибрид без розетки — только бензин, и про зарядку ни слова.
    func testHybridWithoutPlugIsPetrolOnly() {
        let use = split([EnergySplit.Day(day: day(0), trips: [trip(0, km: 50)])], owner(), .hev).days[day(0)]!
        XCTAssertEqual(use.meters(.electricity), 0)
        XCTAssertEqual(use.meters(.petrol), 50_000)
        XCTAssertEqual(use.cost!, 50 * 0.055 * 13_000, accuracy: 0.5)
        XCTAssertEqual(use.noSpeedProfileMeters, 0, "трасса бензиновой машине не важна")
    }

    /// Гибрид с розеткой без запаса хода — не выдумываем долю.
    func testPlugInWithoutRangeIsNotSplit() {
        var profile = FuelProfile()
        profile.rates = [.petrol: FuelRate(per100Km: 5.5, price: 13_000)]
        let model = EnergySplit.model(profile: profile, energy: .hybrid)
        XCTAssertEqual(model.kind, .needsRange)
        let use = EnergySplit.example(meters: 30_000, model: model)
        XCTAssertNil(use.cost)
        XCTAssertNil(use.electricShare)
        XCTAssertEqual(use.unsplitMeters, 30_000)
    }

    /// Электромобиль: всё на электричестве; поездка длиннее запаса — пометка.
    func testElectricCarRangeWarning() {
        var profile = FuelProfile()
        profile.evPassportKm = 400
        profile.evCycle = .wltp
        profile.rates = [.electricity: FuelRate(per100Km: 17, price: 1_000)]
        let days = [EnergySplit.Day(day: day(0), trips: [trip(0, km: 300)]),
                    EnergySplit.Day(day: day(1), trips: [trip(1, km: 400)])]
        let ledger = split(days, profile, .electric)
        XCTAssertEqual(ledger.days[day(0)]!.beyondRangeTrips, 0, "300 км при реальных 360 — доезжает")
        XCTAssertEqual(ledger.days[day(1)]!.beyondRangeTrips, 1, "400 км — нужна зарядка в пути")
        XCTAssertEqual(ledger.days[day(1)]!.meters(.electricity), 400_000)
        XCTAssertEqual(ledger.days[day(1)]!.cost!, 400 * 0.17 * 1_000, accuracy: 0.5)
    }

    // MARK: - Дни из истории

    private func record(_ dayIndex: Int, hour: Double, km: Double, track: [Double]? = nil,
                        work: Bool? = nil) -> TripRecord {
        let start = day(dayIndex).addingTimeInterval(hour * 3_600)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start, endedAt: start.addingTimeInterval(1_800),
                          distanceMeters: km * 1_000, maxSpeedKmh: 60, passed: [], track: track, work: work)
    }

    private func row(_ dayIndex: Int, km: Double) -> TripDay {
        var row = TripDay(day: day(dayIndex))
        row.distanceMeters = km * 1_000
        return row
    }

    /// Запись вычищена — день остаётся по агрегату; часть дня без записи —
    /// одной «поездкой» в начале дня, без двойного счёта.
    func testDaysFromAggregatesAndRecords() {
        let records = [record(1, hour: 18, km: 30)]
        let rows = [row(0, km: 40), row(1, km: 100)]
        let days = EnergySplit.days(tripDays: rows, records: records, calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].trips.map(\.meters), [40_000], "вычищенный день — одним куском")
        XCTAssertNil(days[0].trips[0].id)
        XCTAssertEqual(days[1].trips.map(\.meters), [70_000, 30_000], "остаток дня — до записи")
        XCTAssertEqual(days[1].trips[1].id, records[0].id)
        let ledger = split(days, owner())
        // День 1: утренний остаток 70 км — электричество, вечерние 30 — 20 + 10 бензина.
        XCTAssertEqual(ledger.trips[records[0].id]!.use.meters(.electricity), 20_000, accuracy: 0.5)
        XCTAssertEqual(ledger.use(of: rows).totalMeters, 140_000, accuracy: 0.5, "сумма — как в агрегатах")
    }

    /// Запись без строки дня (данные разошлись) — свой день, а не потеря.
    func testRecordWithoutRowIsKept() {
        let days = EnergySplit.days(tripDays: [], records: [record(3, hour: 9, km: 12)], calendar: calendar)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].trips.first?.meters, 12_000)
    }

    /// Доля трассы — по профилю скорости трека, в доле от длины записи.
    func testHighwayShareFromTrack() {
        // Четыре равных отрезка: 60, 60→100 (80 — не трасса), 100, 100.
        let track: [Double] = [41.0, 69.0, 60, 41.01, 69.0, 60, 41.02, 69.0, 100, 41.03, 69.0, 100, 41.04, 69.0, 100]
        let highway = EnergySplit.highwayMeters(of: record(0, hour: 9, km: 4, track: track))
        XCTAssertEqual(highway!, 2_000, accuracy: 1, "два отрезка из четырёх быстрее 80 км/ч")
        XCTAssertNil(EnergySplit.highwayMeters(of: record(0, hour: 9, km: 4)), "трека нет — профиля нет")
    }

    func testWorkShiftAndRangeQueries() {
        let a = trip(0, hour: 8, km: 20, work: true)
        let b = trip(0, hour: 12, km: 20, work: false)
        let c = trip(0, hour: 15, km: 20, work: true)
        let ledger = split([EnergySplit.Day(day: day(0), trips: [a, b, c])], owner())
        let shift = ledger.use(from: a.start, through: c.start, workOnly: true)
        XCTAssertEqual(shift.totalMeters, 40_000, accuracy: 0.5, "в смене — только рейсы")
        XCTAssertEqual(ledger.use(from: a.start, through: c.start, workOnly: false).totalMeters, 60_000, accuracy: 0.5)
    }

    // MARK: - Сводка

    func testUsualDayIsAMedianOfOwnDays() {
        let now = day(30)
        let rows = [row(29, km: 10), row(28, km: 34), row(27, km: 200), row(20, km: 30), row(10, km: 40),
                    row(-90, km: 500)]
        XCTAssertEqual(EnergySplit.usualDayMeters(tripDays: rows, now: now, calendar: calendar)!, 34_000,
                       "медиана 10, 30, 34, 40, 200 — 34 км; день вне окна не в счёт")
        XCTAssertNil(EnergySplit.usualDayMeters(tripDays: [row(29, km: 10), row(28, km: 20)], now: now,
                                                calendar: calendar), "два дня — мало, будет пример")
    }

    func testLongTripOwnOrExample() {
        let model = EnergySplit.model(profile: owner(), energy: .hybrid)
        let now = day(10)
        let short = EnergySplit.longTrip(records: [record(9, hour: 9, km: 60)], model: model, now: now)
        XCTAssertFalse(short.isOwn, "своя короче запаса — ничего не покажет, берём пример")
        XCTAssertEqual(short.meters, 300_000)
        XCTAssertEqual(short.highwayMeters, 300_000, "пример — по трассе")
        let own = EnergySplit.longTrip(records: [record(9, hour: 9, km: 60), record(8, hour: 9, km: 312)],
                                       model: model, now: now)
        XCTAssertTrue(own.isOwn)
        XCTAssertEqual(own.meters, 312_000)
        // Пример по трассе: заряда хватает на ≈ 69 км, остальное — бензин.
        let use = EnergySplit.example(meters: short.meters, highwayMeters: short.highwayMeters, model: model)
        XCTAssertEqual(use.meters(.electricity), 90_000 / 1.3, accuracy: 1)
    }

    func testAllPetrolComparison() {
        let model = EnergySplit.model(profile: owner(), energy: .hybrid)
        XCTAssertEqual(EnergySplit.allPetrolCost(meters: 100_000, model: model)!, 5.5 * 13_000, accuracy: 0.5)
        let unpriced = EnergySplit.model(profile: owner(prices: false), energy: .hybrid)
        XCTAssertNil(EnergySplit.allPetrolCost(meters: 100_000, model: unpriced), "цены бензина нет — строки нет")
    }

    // MARK: - Числа профиля

    func testNumbersReadAndWrite() {
        var profile = FuelProfile()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        EnergyNumber.passport.set(120, in: &profile, now: now)
        EnergyNumber.homePrice.set(1_000, in: &profile, now: now)
        EnergyNumber.stationPrice.set(2_500, in: &profile, now: now)
        EnergyNumber.per100(.petrol).set(5.5, in: &profile, now: now)
        XCTAssertEqual(profile.evPassportKm, 120)
        XCTAssertEqual(profile.rate(.electricity).price, 1_000, "свет дома — прежняя цена электричества")
        XCTAssertEqual(profile.stationPrice, 2_500)
        XCTAssertEqual(profile.pricesUpdatedAt, now)
        let later = now.addingTimeInterval(86_400)
        EnergyNumber.homePrice.set(1_000, in: &profile, now: later)
        XCTAssertEqual(profile.pricesUpdatedAt, now, "та же цена — не правка цены")
        EnergyNumber.per100(.petrol).set(6, in: &profile, now: later)
        XCTAssertEqual(profile.pricesUpdatedAt, now, "расход — не цена")
        EnergyNumber.passport.set(0, in: &profile, now: later)
        XCTAssertNil(profile.evPassportKm, "пусто — не указано")
        XCTAssertEqual(EnergyNumber.prices(for: .hybrid, profile: profile), [.homePrice, .price(.petrol)])
        profile.chargePlace = .both
        XCTAssertEqual(EnergyNumber.prices(for: .electric, profile: profile), [.homePrice, .stationPrice])
        XCTAssertEqual(EnergyNumber.prices(for: .hev, profile: profile), [.price(.petrol)])
    }

    func testPlausibilityHints() {
        XCTAssertEqual(EnergyHints.check(5.5, .petrol(.hybrid)), .ok)
        XCTAssertEqual(EnergyHints.check(40, .petrol(.hybrid)), .wrongScale, "40 л — это на 100 км?")
        XCTAssertEqual(EnergyHints.check(40, .petrol(.fuel)), .wrongScale)
        XCTAssertEqual(EnergyHints.check(14, .petrol(.hybrid)), .unusual, "гибриду 14 л — необычно")
        XCTAssertEqual(EnergyHints.check(14, .petrol(.fuel)), .ok)
        XCTAssertEqual(EnergyHints.check(16, .kWh), .ok)
        XCTAssertEqual(EnergyHints.check(160, .kWh), .wrongScale)
        XCTAssertEqual(EnergyHints.check(13, .price(.petrol)), .wrongScale, "13 вместо 13 000 — тысячи")
        XCTAssertEqual(EnergyHints.check(13_000, .price(.petrol)), .ok)
        XCTAssertEqual(EnergyHints.check(0, .kWh), .ok, "пусто — не ошибка")
    }

    // MARK: - Бюджет

    /// Расчёт идёт синхронно при смене данных: три года дней и пятьдесят
    /// записей с треками — пять пересчётов меньше 250 мс на симуляторе с запасом.
    func testLedgerBudget() {
        let rows = (0..<1_100).map { row(-$0, km: Double(20 + $0 % 60)) }
        var track: [Double] = []
        for step in 0..<400 {
            let lat: Double = 41.3 + Double(step) * 0.001
            let speed: Double = Double(40 + step % 70)
            track += [lat, 69.2, speed]
        }
        let records = (0..<50).map { record(-$0, hour: 9, km: 15, track: track) }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<5 {
            _ = EnergySplit.ledger(tripDays: rows, records: records, profile: owner(), energy: .hybrid,
                                   calendar: calendar)
        }
        XCTAssertLessThan(clock.now - start, .milliseconds(250), "пять пересчётов всей истории")
    }
}
