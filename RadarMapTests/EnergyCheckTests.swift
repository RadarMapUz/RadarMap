//
//  EnergyCheckTests.swift
//  RadarMapTests
//
//  «Сверить с машиной» (21.10, 21.5): панель показывает долю на
//  электричестве и расход — приложение подбирает реальный запас тем же
//  расчётом по тем же дням и предлагает поправку одним касанием; сошлось —
//  поправок нет; чего панель не показала — не трогаем.
//

import XCTest
@testable import RadarMap

final class EnergyCheckTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }()

    private func day(_ index: Int) -> Date {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        return calendar.date(byAdding: .day, value: index, to: base)!
    }

    private func owner() -> FuelProfile {
        var profile = FuelProfile()
        profile.evPassportKm = 120
        profile.evCycle = .cltc
        profile.chargeSchedule = .nightly
        profile.rates = [.petrol: FuelRate(per100Km: 5.5, price: 13_000)]
        return profile
    }

    /// Месяц: 20 дней по 100 км — при запасе 90 км на электричестве 90 %.
    private func month(km: Double = 100) -> [EnergySplit.Day] {
        (0..<20).map { index in
            let start = day(index).addingTimeInterval(9 * 3_600)
            return EnergySplit.Day(day: day(index), trips: [
                EnergySplit.Trip(id: start.timeIntervalSince1970, start: start, meters: km * 1_000)])
        }
    }

    func testShareFromThePanelAdjustsTheRange() {
        // Панель: 95 % — значит, реальный запас ≈ 95 км, а не 90.
        let result = EnergyCheck.compare(panel: .init(electricShare: 0.95), days: month(), profile: owner(),
                                         energy: .hybrid, calendar: calendar)
        XCTAssertEqual(result.estimate.electricShare!, 0.9, accuracy: 0.001)
        XCTAssertEqual(result.suggestions, [.realRange(from: 90, to: 95)])
        XCTAssertFalse(result.allMatch)
        // Поправка принимается одним касанием — и расчёт сходится.
        let fixed = EnergyCheck.apply(result.suggestions[0], to: owner())
        XCTAssertEqual(fixed.realRangeKm, 95)
        let again = EnergyCheck.compare(panel: .init(electricShare: 0.95), days: month(), profile: fixed,
                                        energy: .hybrid, calendar: calendar)
        XCTAssertTrue(again.allMatch)
    }

    func testMatchingShareNeedsNoChange() {
        let result = EnergyCheck.compare(panel: .init(electricShare: 0.91), days: month(), profile: owner(),
                                         energy: .hybrid, calendar: calendar)
        XCTAssertTrue(result.suggestions.isEmpty, "1 п.п. — в пределах точности")
        XCTAssertTrue(result.allMatch)
    }

    /// 100 % на панели при городских днях — запас не меньше самого длинного дня.
    func testFullyElectricMonth() {
        let range = EnergyCheck.rangeMatching(share: 1, days: month(km: 60), profile: owner(), calendar: calendar)
        XCTAssertEqual(range!, 60, accuracy: 1, "хватает и 60 км — меньший запас не дал бы 100 %")
    }

    /// Доля, которую не получить ни при каком запасе (0 % при зарядке каждую
    /// ночь), — поправки запаса нет: не тот график, а не не тот запас.
    func testUnreachableShareSuggestsNothing() {
        XCTAssertNil(EnergyCheck.rangeMatching(share: 0, days: month(), profile: owner(), calendar: calendar))
    }

    func testConsumptionFromThePanel() {
        let result = EnergyCheck.compare(panel: .init(kWhPer100: 15.8, litresPer100: 5.6), days: month(),
                                         profile: owner(), energy: .hybrid, calendar: calendar)
        XCTAssertEqual(result.suggestions, [.kWhPer100(from: 16, to: 15.8)],
                       "оценка 16 сменяется цифрой панели; 5,6 против 5,5 — меньше 5 %, бензин не трогаем")
        let fixed = EnergyCheck.apply(result.suggestions[0], to: owner())
        XCTAssertEqual(fixed.kWhPer100.value, 15.8)
        XCTAssertFalse(fixed.kWhPer100.isEstimate)
    }

    func testPetrolCarChecksOnlyLitres() {
        var profile = FuelProfile()
        profile.rates = [.petrol: FuelRate(per100Km: 8, price: 13_000)]
        let result = EnergyCheck.compare(panel: .init(electricShare: 0.5, kWhPer100: 15, litresPer100: 9.2),
                                         days: month(), profile: profile, energy: .fuel, calendar: calendar)
        XCTAssertEqual(result.suggestions, [.litresPer100(from: 8, to: 9.2)],
                       "у бензиновой машины доли и кВт·ч нет — сверяем только литры")
        XCTAssertEqual(EnergyCheck.apply(result.suggestions[0], to: profile).rate(.petrol).per100Km, 9.2)
    }

    func testEmptyPanelComparesNothing() {
        let result = EnergyCheck.compare(panel: .init(), days: month(), profile: owner(), energy: .hybrid,
                                         calendar: calendar)
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertFalse(result.allMatch, "не сверяли — не «сходится»")
    }
}
