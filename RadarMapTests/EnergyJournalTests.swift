//
//  EnergyJournalTests.swift
//  RadarMapTests
//
//  Журнал заправок и зарядок (21.6): суммы за период — полуинтервал, как у
//  RatingTrend; реальный расход — только «бак к баку» с пробегом; цена
//  профиля — только свежая, правдоподобная и заметно другая; «30 л за
//  3 000 сум» — переспросить; нет файла — пустой журнал.
//

import XCTest
import os
@testable import RadarMap

final class EnergyJournalTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func fill(_ day: Int, _ litres: Double, _ sum: Double, km: Double? = nil, full: Bool = false,
                      kind: JournalKind = .petrol, hour: Int = 12) -> JournalEntry {
        JournalEntry(date: date(day, hour), kind: kind, quantity: litres, amount: sum,
                     odometerKm: km, full: full ? true : nil)
    }

    // MARK: - Модель

    func testUnitPriceAndKinds() {
        let entry = fill(1, 30, 375_000)
        XCTAssertEqual(entry.unitPrice, 12_500)
        XCTAssertNil(fill(1, 0, 10_000).unitPrice)
        XCTAssertEqual(JournalKind.homeCharge.fuel, .electricity)
        XCTAssertTrue(JournalKind.stationCharge.isCharge)
        XCTAssertFalse(JournalKind.methane.isCharge)
        XCTAssertEqual(JournalKind.fills(for: .cng), [.methane, .petrol])
        XCTAssertEqual(JournalKind.fills(for: .hybrid), [.petrol])
        XCTAssertEqual(JournalKind.charges(for: .hybrid), [.homeCharge, .stationCharge])
        XCTAssertEqual(JournalKind.fills(for: .electric), [])
        XCTAssertEqual(JournalKind.charges(for: .hev), [], "гибрид без розетки не заряжают")
        XCTAssertEqual(JournalKind.homeCharge.priceNumber, .homePrice)
        XCTAssertEqual(JournalKind.stationCharge.priceNumber, .stationPrice)
    }

    /// Сырые значения лежат на диске: переименовать — потерять записи.
    func testRawValuesAreStable() {
        XCTAssertEqual(JournalKind.allCases.map(\.rawValue),
                       ["petrol", "methane", "propane", "homeCharge", "stationCharge"])
    }

    // MARK: - Форма

    func testFormMakesEntryAndInventsNothing() {
        var form = JournalForm(kind: .petrol, now: date(5))
        XCTAssertFalse(form.canSave)
        form.quantity = "30,5"
        XCTAssertFalse(form.canSave, "без суммы записи нет")
        form.amount = FineForm.groupedDigits("381250")
        XCTAssertTrue(form.canSave)
        XCTAssertEqual(form.unitPrice, 12_500)
        let entry = try! XCTUnwrap(form.entry(id: UUID()))
        XCTAssertEqual(entry.quantity, 30.5)
        XCTAssertEqual(entry.amount, 381_250)
        XCTAssertNil(entry.odometerKm, "пробег не вписан — его нет")
        XCTAssertNil(entry.full)
        form.odometer = "87 240"
        form.full = true
        let full = try! XCTUnwrap(form.entry(id: entry.id))
        XCTAssertEqual(full.odometerKm, 87_240)
        XCTAssertEqual(full.full, true)
        XCTAssertEqual(full.id, entry.id)
    }

    func testFormRoundTripsEntry() {
        let entry = JournalEntry(date: date(3), kind: .homeCharge, quantity: 18.3, amount: 18_000,
                                 odometerKm: 12_000, full: true)
        let form = JournalForm(entry: entry)
        XCTAssertEqual(form.kind, .homeCharge)
        XCTAssertEqual(form.entry(id: entry.id), entry)
        XCTAssertEqual(JournalForm.decimal("1 2,5"), 12.5)
        XCTAssertEqual(JournalForm.decimal("12.5"), 12.5)
        XCTAssertNil(JournalForm.decimal(""))
        XCTAssertNil(JournalForm.decimal("abc"))
    }

    // MARK: - Период: полуинтервал

    func testSpendingUsesHalfOpenWindow() {
        // Неделя 12–19 октября: заправка ровно в полночь 19-го — уже следующая.
        let week = DateInterval(start: date(12, 0), end: date(19, 0))
        let entries = [
            fill(11, 30, 375_000, hour: 23),
            fill(12, 20, 250_000, hour: 0),
            JournalEntry(date: date(14), kind: .homeCharge, quantity: 18, amount: 18_000),
            JournalEntry(date: date(15), kind: .stationCharge, quantity: 20, amount: 50_000),
            fill(19, 40, 500_000, hour: 0),
        ]
        let spent = EnergyJournal.spending(entries, in: week)
        XCTAssertEqual(spent.amount, 318_000)
        XCTAssertEqual(spent.fills, 1)
        XCTAssertEqual(spent.charges, 2)
        XCTAssertEqual(spent.quantity[.electricity], 38)
        XCTAssertEqual(spent.quantity[.petrol], 20)
        // Соседние окна не пересекаются и вместе дают всё.
        let next = DateInterval(start: date(19, 0), end: date(26, 0))
        let previous = DateInterval(start: date(5, 0), end: date(12, 0))
        let total = [previous, week, next].map { EnergyJournal.spending(entries, in: $0).amount }.reduce(0, +)
        XCTAssertEqual(total, entries.map(\.amount).reduce(0, +))
    }

    /// Без записей — ничего: пустой период, «Итоги» остаются как были.
    func testEmptyJournalIsEmptyPeriod() {
        let period = EnergyJournal.period([], in: DateInterval(start: date(1), end: date(31)))
        XCTAssertTrue(period.isEmpty)
        XCTAssertEqual(period.measured, [])
    }

    // MARK: - Реальный расход

    /// «Бак к баку»: залитое после первой полной до второй включительно — на пробег между ними.
    func testMeasuredBetweenTwoFullFills() {
        let entries = [
            fill(1, 40, 500_000, km: 10_000, full: true),
            fill(4, 15, 190_000),                              // долив без пробега — считается
            fill(8, 29, 360_000, km: 10_620, full: true),
        ]
        let segments = EnergyJournal.segments(entries, fuel: .petrol)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].quantity, 44)
        XCTAssertEqual(segments[0].km, 620)
        XCTAssertEqual(segments[0].per100, 44.0 / 620 * 100, accuracy: 1e-9)
    }

    /// Нет второй полной, нет пробега, полная без пробега — расхода нет вовсе.
    func testNoMeasurementWithoutProof() {
        XCTAssertEqual(EnergyJournal.segments([fill(1, 40, 500_000, km: 10_000, full: true),
                                               fill(5, 30, 375_000, km: 10_500)], fuel: .petrol), [],
                       "вторая не до полного")
        XCTAssertEqual(EnergyJournal.segments([fill(1, 40, 500_000, full: true),
                                               fill(5, 30, 375_000, full: true)], fuel: .petrol), [],
                       "без пробега")
        // Полная без пробега посередине рвёт цепь: сколько проехали до неё — неизвестно.
        XCTAssertEqual(EnergyJournal.segments([fill(1, 40, 500_000, km: 10_000, full: true),
                                               fill(3, 20, 250_000, full: true),
                                               fill(6, 30, 375_000, km: 10_700, full: true)], fuel: .petrol), [])
    }

    /// Короткий отрезок, пробег назад и неправдоподобный расход — не показываем.
    func testMeasurementRejectsNoise() {
        XCTAssertEqual(EnergyJournal.segments([fill(1, 40, 500_000, km: 10_000, full: true),
                                               fill(2, 3, 37_500, km: 10_030, full: true)], fuel: .petrol), [],
                       "30 км — шум пистолета")
        XCTAssertEqual(EnergyJournal.segments([fill(1, 40, 500_000, km: 10_000, full: true),
                                               fill(5, 30, 375_000, km: 9_500, full: true)], fuel: .petrol), [],
                       "пробег назад")
        XCTAssertEqual(EnergyJournal.segments([fill(1, 40, 500_000, km: 10_000, full: true),
                                               fill(5, 60, 750_000, km: 10_100, full: true)], fuel: .petrol), [],
                       "60 л/100 — пропущена запись или ошибка в пробеге")
    }

    /// Топлива не смешиваются: бензин гибрида и его зарядки — свои отрезки.
    func testFuelsAreSeparate() {
        let entries = [
            fill(1, 30, 375_000, km: 10_000, full: true),
            JournalEntry(date: date(2), kind: .homeCharge, quantity: 16, amount: 16_000,
                         odometerKm: 10_050, full: true),
            JournalEntry(date: date(3), kind: .stationCharge, quantity: 15, amount: 37_500,
                         odometerKm: 10_150, full: true),
            fill(9, 20, 250_000, km: 10_900, full: true),
        ]
        let petrol = EnergyJournal.segments(entries, fuel: .petrol)
        XCTAssertEqual(petrol.map(\.km), [900])
        XCTAssertEqual(petrol.map(\.quantity), [20])
        let electricity = EnergyJournal.segments(entries, fuel: .electricity)
        XCTAssertEqual(electricity.map(\.km), [100])
        XCTAssertEqual(electricity.map(\.quantity), [15], "дом и станция — одно электричество")
    }

    /// Расход за окно — отрезки, закончившиеся в нём, сумма на сумму.
    func testMeasuredInPeriodAggregatesSegments() {
        let entries = [
            fill(1, 40, 500_000, km: 10_000, full: true),
            fill(8, 30, 375_000, km: 10_500, full: true),   // 30 / 500
            fill(15, 36, 450_000, km: 11_100, full: true),  // 36 / 600
            fill(29, 33, 410_000, km: 11_600, full: true, hour: 23),
        ]
        let middle = DateInterval(start: date(5, 0), end: date(20, 0))
        let measured = try! XCTUnwrap(EnergyJournal.measured(entries, fuel: .petrol, in: middle))
        XCTAssertEqual(measured.quantity, 66)
        XCTAssertEqual(measured.km, 1_100)
        XCTAssertEqual(measured.per100, 6, accuracy: 1e-9)
        XCTAssertNil(EnergyJournal.measured(entries, fuel: .petrol,
                                            in: DateInterval(start: date(20, 0), end: date(29, 0))),
                     "в окне ни одного конца отрезка")
        XCTAssertEqual(EnergyJournal.latest(entries, fuel: .petrol)?.km, 500)
        let period = EnergyJournal.period(entries, in: middle)
        XCTAssertEqual(period.measured.map(\.fuel), [.petrol])
        XCTAssertEqual(period.spending.fills, 2)
    }

    // MARK: - Цена профиля

    func testPriceUpdateOnlyWhenFreshPlausibleAndDifferent() {
        var profile = FuelProfile()
        profile.rates[.petrol] = FuelRate(per100Km: 8, price: 12_000)
        let now = date(10)
        let entry = JournalEntry(date: date(10, 9), kind: .petrol, quantity: 30, amount: 375_000)
        XCTAssertEqual(EnergyJournal.priceUpdate(for: entry, profile: profile, now: now),
                       .init(number: .price(.petrol), old: 12_000, new: 12_500))
        // Почти та же цена — не спрашиваем.
        profile.rates[.petrol]?.price = 12_400
        XCTAssertNil(EnergyJournal.priceUpdate(for: entry, profile: profile, now: now))
        // Цены не было — предлагаем поставить.
        profile.rates[.petrol] = nil
        XCTAssertEqual(EnergyJournal.priceUpdate(for: entry, profile: profile, now: now)?.old, 0)
        // Вписанная задним числом — о прошлой цене.
        let old = JournalEntry(date: date(1), kind: .petrol, quantity: 30, amount: 375_000)
        XCTAssertNil(EnergyJournal.priceUpdate(for: old, profile: profile, now: now))
        // Опечатка в сумме цену не меняет.
        let typo = JournalEntry(date: date(10, 9), kind: .petrol, quantity: 30, amount: 3_000)
        XCTAssertNil(EnergyJournal.priceUpdate(for: typo, profile: profile, now: now))
        // Зарядка на станции — своя цена, дома — своя.
        let station = JournalEntry(date: date(10, 9), kind: .stationCharge, quantity: 20, amount: 50_000)
        XCTAssertEqual(EnergyJournal.priceUpdate(for: station, profile: profile, now: now)?.number, .stationPrice)
    }

    func testPriceUpdateAppliesThroughProfileNumber() {
        var profile = FuelProfile()
        let update = EnergyJournal.PriceUpdate(number: .homePrice, old: 0, new: 1_000)
        update.number.set(update.new, in: &profile, now: date(10))
        XCTAssertEqual(profile.rate(.electricity).price, 1_000)
        XCTAssertEqual(profile.pricesUpdatedAt, date(10), "обновлённая цена отмечает дату")
    }

    // MARK: - Правдоподобие

    func testDoubts() {
        // 30 л за 3 000 сум — 100 сум за литр: переспросить.
        let typo = fill(10, 30, 3_000)
        XCTAssertEqual(EnergyJournal.doubts(typo, among: []), [.price(perUnit: 100)])
        XCTAssertEqual(EnergyJournal.doubts(fill(10, 30, 375_000), among: []), [])
        XCTAssertEqual(EnergyJournal.doubts(fill(10, 300, 3_750_000), among: []), [.quantity])
        let charge = JournalEntry(date: date(10), kind: .homeCharge, quantity: 18, amount: 18_000)
        XCTAssertEqual(EnergyJournal.doubts(charge, among: []), [])
        // Пробег меньше, чем неделю назад, — опечатка.
        let earlier = fill(3, 40, 500_000, km: 10_000)
        let later = fill(20, 40, 500_000, km: 11_000)
        XCTAssertEqual(EnergyJournal.doubts(fill(10, 30, 375_000, km: 9_000), among: [earlier, later]),
                       [.odometer(neighbour: 10_000)])
        XCTAssertEqual(EnergyJournal.doubts(fill(10, 30, 375_000, km: 12_000), among: [earlier, later]),
                       [.odometer(neighbour: 11_000)])
        XCTAssertEqual(EnergyJournal.doubts(fill(10, 30, 375_000, km: 10_400), among: [earlier, later]), [])
        // Правка самой записи не спорит сама с собой.
        XCTAssertEqual(EnergyJournal.doubts(earlier, among: [earlier, later]), [])
    }

    // MARK: - Диск: миграция

    /// До 21.6 файла нет ни у кого — это пустой журнал, а не ошибка.
    func testMissingFileIsEmptyJournal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let log = Logger(subsystem: "tests", category: "journal")
        let result = JSONFile.loadChecked(LossyArray<JournalEntry>.self, from: url, log: log)
        XCTAssertEqual(EnergyJournalStore.disk(from: result, url: url, log: log), [])
    }

    /// Запись без необязательных полей и запись из будущей сборки с
    /// незнакомым видом: первая читается, вторая выпадает поштучно.
    func testDecodingIsLossyAndOptional() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("energy_journal.json")
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","date":800000000,"kind":"petrol","quantity":30,"amount":375000},
         {"id":"\(UUID().uuidString)","date":800000100,"kind":"hydrogen","quantity":5,"amount":100000}]
        """
        try Data(json.utf8).write(to: url)
        let log = Logger(subsystem: "tests", category: "journal")
        let result = JSONFile.loadChecked(LossyArray<JournalEntry>.self, from: url, log: log)
        let entries = try XCTUnwrap(EnergyJournalStore.disk(from: result, url: url, log: log))
        XCTAssertEqual(entries.map(\.id), [id])
        XCTAssertNil(entries[0].odometerKm)
        XCTAssertNil(entries[0].full)
        // Файл с выброшенной записью отложен копией — её ещё можно вернуть руками.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertGreaterThan(names.count, 1)
    }

    // MARK: - Строка «Итогов»

    /// Без записей строка та же, что без журнала; с записями — сверху
    /// реальные деньги, расчёт вторым планом, «вышло бы» не сравнивает оценки.
    @MainActor
    func testItogiRowHonesty() {
        var profile = FuelProfile()
        profile.rates[.petrol] = FuelRate(per100Km: 6, price: 13_000)
        let model = EnergySplit.model(profile: profile, energy: .fuel)
        var use = EnergySplit.Use()
        use.meters[.petrol] = 100_000
        use.amount[.petrol] = 6
        use.money = 78_000
        let plain = PeriodEnergyRow.lines(use, model: model, current: false)
        let empty = EnergyJournal.period([], in: DateInterval(start: date(1), end: date(31)))
        XCTAssertEqual(PeriodEnergyRow.lines(use, model: model, current: false, journal: empty), plain)
        XCTAssertEqual(PeriodEnergyRow.isWorthShowing(use, model: model, journal: empty),
                       PeriodEnergyRow.isWorthShowing(use, model: model))

        let entries = [fill(3, 30, 390_000, km: 10_000, full: true), fill(17, 40, 520_000, km: 10_600, full: true)]
        let journal = EnergyJournal.period(entries, in: DateInterval(start: date(1, 0), end: date(1, 0, month: 11)))
        let lines = PeriodEnergyRow.lines(use, model: model, current: false, journal: journal)
        XCTAssertEqual(lines.title, JournalText.spent(journal.spending))
        XCTAssertEqual(lines.detail, JournalText.counts(journal.spending))
        XCTAssertEqual(lines.estimate, JournalText.estimate(78_000))
        XCTAssertNil(lines.allPetrol)
        XCTAssertEqual(lines.measured, JournalText.measured(journal.measured))
        XCTAssertNotNil(lines.measured)
        // Записи есть, а поездок с ценой нет — строка всё равно нужна.
        XCTAssertTrue(PeriodEnergyRow.isWorthShowing(EnergySplit.Use(), model: model, journal: journal))
    }

    /// Гибрид с розеткой: бензин по факту — на весь путь вместе с
    /// электрическими км, и подпись говорит это словами, а не «л/100 км»,
    /// который читается как расход двигателя (ревью 21.6).
    @MainActor
    func testHybridPetrolIsPerWholeTrip() {
        let entries = [fill(3, 30, 390_000, km: 10_000, full: true), fill(17, 27, 351_000, km: 10_600, full: true),
                       JournalEntry(date: date(5), kind: .homeCharge, quantity: 16, amount: 16_000,
                                    odometerKm: 10_100, full: true),
                       JournalEntry(date: date(9), kind: .homeCharge, quantity: 17, amount: 17_000,
                                    odometerKm: 10_220, full: true)]
        let journal = EnergyJournal.period(entries, in: DateInterval(start: date(1, 0), end: date(1, 0, month: 11)))
        var profile = FuelProfile()
        profile.evPassportKm = 120
        let hybrid = EnergySplit.model(profile: profile, energy: .hybrid)
        let petrolOnly = EnergySplit.model(profile: profile, energy: .fuel)
        let mixed = try! XCTUnwrap(PeriodEnergyRow.lines(EnergySplit.Use(), model: hybrid, current: false,
                                                         journal: journal).measured)
        XCTAssertTrue(mixed.contains(JournalText.perTrip100(4.5)), mixed)
        XCTAssertFalse(mixed.contains(EnergyText.per100Short(4.5, .petrol)), mixed)
        XCTAssertTrue(mixed.contains(EnergyText.per100Short(17.0 / 120 * 100, .electricity)),
                      "электричество — как было")
        // Гибрид с розеткой без запаса хода — тот же бензин на весь путь.
        let noRange = EnergySplit.model(profile: FuelProfile(), energy: .hybrid)
        XCTAssertTrue(PeriodEnergyRow.lines(EnergySplit.Use(), model: noRange, current: false, journal: journal)
            .measured?.contains(JournalText.perTrip100(4.5)) == true)
        let plain = try! XCTUnwrap(PeriodEnergyRow.lines(EnergySplit.Use(), model: petrolOnly, current: false,
                                                         journal: journal).measured)
        XCTAssertTrue(plain.contains(EnergyText.per100Short(4.5, .petrol)), plain)
    }

    // MARK: - Месяцы журнала

    /// Полночь первого числа — уже новый месяц; новые сверху.
    func testMonthsGroupNewestFirst() {
        let entries = [
            fill(30, 30, 375_000, hour: 23),
            fill(1, 20, 250_000, hour: 0),
            JournalEntry(date: date(1, 0, month: 11), kind: .homeCharge, quantity: 18, amount: 18_000),
            fill(15, 10, 125_000),
        ]
        let months = EnergyJournal.months(entries, calendar: calendar)
        XCTAssertEqual(months.map(\.start), [date(1, 0, month: 11), date(1, 0)])
        XCTAssertEqual(months[0].entries.count, 1)
        XCTAssertEqual(months[1].entries.map(\.quantity), [30, 10, 20])
        XCTAssertEqual(months[1].amount, 750_000)
    }

    // MARK: - Экспорт

    func testJournalCSV() {
        let tashkent = TimeZone(identifier: "Asia/Tashkent")!
        let csv = TripExport.journalCSV([
            JournalEntry(date: date(14, 20), kind: .homeCharge, quantity: 18.3, amount: 18_000,
                         odometerKm: 12_000, full: true),
            fill(2, 30, 375_000),
        ], timeZone: tashkent)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "date,kind,quantity,unit,amount_uzs,price_per_unit_uzs,odometer_km,full")
        XCTAssertEqual(lines[1], "2026-10-02 12:00,petrol,30.00,l,375000,12500,,0")
        XCTAssertEqual(lines[2], "2026-10-14 20:00,homeCharge,18.30,kWh,18000,984,12000,1")
        XCTAssertEqual(lines.count, 4, "две записи и пустой хвост после последнего перевода строки")
    }
}
