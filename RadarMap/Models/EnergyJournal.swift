//
//  EnergyJournal.swift
//  RadarMap
//
//  Журнал заправок и зарядок (21.6, план 21.10 §1.8): «Заправился: 30 л ·
//  375 000 сум», «Зарядился: 18 кВт·ч · 18 000 сум», по желанию — пробег с
//  панели и «до полного». Это самое точное, что приложение может знать о
//  расходах: когда за период есть записи, «Итоги» показывают реальные
//  деньги, а оценка EnergySplit уходит второй строкой.
//
//  Только телефон: Documents/energy_journal.json (EnergyJournalStore), в
//  сеть не уходит ничего. Новое поле записи — только опциональное
//  (правило 18): файл лежит у людей на диске.
//
//  Честность — в трёх местах:
//  · реальный расход «по факту» — только между двумя «до полного» с
//    пробегом с панели (метод «бак к баку»); иначе его нет вовсе, ни
//    оценкой, ни приблизительно;
//  · цена за единицу выводится из записи и может обновить цену профиля —
//    только по ответу водителя (`priceUpdate`), молча — никогда;
//  · «30 л за 3 000 сум» — не сохраняем, не переспросив (`doubts`).
//
//  Окна периодов — полуинтервал [начало, конец), как у TripDayBook.days
//  и RatingTrend: заправка ровно в полночь понедельника — в новой неделе.
//
//  Чистая логика — EnergyJournalTests.
//

import Foundation

/// Что залили или зарядили. Сырые значения лежат на диске — не переименовывать.
nonisolated enum JournalKind: String, Codable, CaseIterable, Sendable {
    case petrol, methane, propane
    case homeCharge, stationCharge

    var fuel: Fuel {
        switch self {
        case .petrol: return .petrol
        case .methane: return .methane
        case .propane: return .propane
        case .homeCharge, .stationCharge: return .electricity
        }
    }

    var isCharge: Bool { fuel == .electricity }

    /// Число профиля, чью цену может обновить запись.
    var priceNumber: EnergyNumber {
        switch self {
        case .petrol: return .price(.petrol)
        case .methane: return .price(.methane)
        case .propane: return .price(.propane)
        case .homeCharge: return .homePrice
        case .stationCharge: return .stationPrice
        }
    }

    /// Больше этого за одну заправку не бывает — лишний ноль, а не бак.
    var maxQuantity: Double {
        switch self {
        case .petrol, .propane: return AppConfig.journalMaxLitres
        case .methane: return AppConfig.journalMaxCubicMetres
        case .homeCharge, .stationCharge: return AppConfig.journalMaxKWh
        }
    }

    /// Заправки машины этого типа — в порядке выбора (основное топливо первым).
    static func fills(for energy: VehicleEnergy) -> [JournalKind] {
        switch energy {
        case .fuel, .hev, .hybrid: return [.petrol]
        case .cng: return [.methane, .petrol]
        case .lpg: return [.propane, .petrol]
        case .electric: return []
        }
    }

    /// Зарядки — только у машины с розеткой.
    static func charges(for energy: VehicleEnergy) -> [JournalKind] {
        energy.plugs ? [.homeCharge, .stationCharge] : []
    }
}

/// Одна запись журнала.
nonisolated struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var kind: JournalKind
    /// Литры, кубометры или кВт·ч — в единице `kind.fuel.unit`.
    var quantity: Double
    /// Заплачено, сум.
    var amount: Double
    /// Пробег с панели машины, км; nil — не вписан.
    var odometerKm: Double?
    /// «До полного» (бак или 100 % батареи). nil — нет: только такие пары
    /// с пробегом дают реальный расход.
    var full: Bool?

    init(id: UUID = UUID(), date: Date, kind: JournalKind, quantity: Double, amount: Double,
         odometerKm: Double? = nil, full: Bool? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.quantity = quantity
        self.amount = amount
        self.odometerKm = odometerKm
        self.full = full
    }

    /// Сумов за литр (кубометр, кВт·ч); nil — делить не на что.
    var unitPrice: Double? {
        guard quantity > 0, amount > 0 else { return nil }
        return amount / quantity
    }

    var isFull: Bool { full == true }
}

nonisolated enum EnergyJournal {

    // MARK: - Период

    /// Записи окна — полуинтервал [начало, конец), один ответ на «в каком окне».
    static func entries(_ entries: [JournalEntry], in interval: DateInterval) -> [JournalEntry] {
        entries.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// Потрачено за окно: деньги, число заправок и зарядок, количество по топливу.
    struct Spending: Equatable, Sendable {
        var amount: Double = 0
        var fills = 0
        var charges = 0
        var quantity: [Fuel: Double] = [:]

        var isEmpty: Bool { fills + charges == 0 }
    }

    static func spending(_ all: [JournalEntry], in interval: DateInterval) -> Spending {
        var result = Spending()
        for entry in entries(all, in: interval) {
            result.amount += entry.amount
            if entry.kind.isCharge { result.charges += 1 } else { result.fills += 1 }
            result.quantity[entry.kind.fuel, default: 0] += entry.quantity
        }
        return result
    }

    // MARK: - Реальный расход («бак к баку»)

    /// Отрезок между двумя «до полного» с пробегом: всё, что залито после
    /// первой и до второй включительно, ушло на эти километры.
    struct Measured: Equatable, Sendable {
        let fuel: Fuel
        var quantity: Double
        var km: Double
        /// Конец отрезка — вторая полная заправка (по ней отрезок попадает в окно).
        var end: Date

        var per100: Double { km > 0 ? quantity / km * 100 : 0 }
    }

    /// Все отрезки топлива по порядку. Цепь рвётся, где правды нет:
    /// «до полного» без пробега (сколько проехали — неизвестно) и пробег,
    /// пошедший назад (опечатка или другая машина).
    static func segments(_ all: [JournalEntry], fuel: Fuel) -> [Measured] {
        let ordered = all.filter { $0.kind.fuel == fuel }
            .sorted { ($0.date, $0.odometerKm ?? 0) < ($1.date, $1.odometerKm ?? 0) }
        var result: [Measured] = []
        var anchorKm: Double?
        var poured = 0.0
        for entry in ordered {
            if let anchor = anchorKm, let odometer = entry.odometerKm, odometer < anchor {
                // Назад — отрезок до этой точки не считается.
                anchorKm = nil
                poured = 0
            }
            guard let anchor = anchorKm else {
                if entry.isFull, let odometer = entry.odometerKm { anchorKm = odometer }
                poured = 0
                continue
            }
            poured += entry.quantity
            guard entry.isFull else { continue }
            guard let odometer = entry.odometerKm else {
                anchorKm = nil
                poured = 0
                continue
            }
            let km = odometer - anchor
            if km >= AppConfig.journalMinMeasuredKm {
                let segment = Measured(fuel: fuel, quantity: poured, km: km, end: entry.date)
                if segment.per100 > 0, segment.per100 <= maxPer100(fuel) { result.append(segment) }
            }
            anchorKm = odometer
            poured = 0
        }
        return result
    }

    /// Расход по факту за окно: отрезки, закончившиеся в нём, — сумма на сумму.
    /// nil — ни одного: показывать нечего, и ничего не показываем.
    static func measured(_ all: [JournalEntry], fuel: Fuel, in interval: DateInterval) -> Measured? {
        let inside = segments(all, fuel: fuel).filter { $0.end >= interval.start && $0.end < interval.end }
        guard let last = inside.last else { return nil }
        return Measured(fuel: fuel, quantity: inside.reduce(0) { $0 + $1.quantity },
                        km: inside.reduce(0) { $0 + $1.km }, end: last.end)
    }

    /// Последний отрезок топлива — «по факту» в самом журнале.
    static func latest(_ all: [JournalEntry], fuel: Fuel) -> Measured? {
        segments(all, fuel: fuel).last
    }

    /// Больше — пробег вписан с ошибкой (или заправка пропущена в журнале):
    /// такой «расход» не показываем вовсе.
    private static func maxPer100(_ fuel: Fuel) -> Double {
        fuel == .electricity ? AppConfig.journalMaxMeasuredKWhPer100 : AppConfig.journalMaxMeasuredPer100
    }

    /// Всё, что «Итоги» говорят о периоде по журналу: деньги и расход по факту.
    struct Period: Equatable, Sendable {
        var spending: Spending
        /// По топливу — в порядке Fuel.allCases; только те, где есть отрезок.
        var measured: [Measured]

        var isEmpty: Bool { spending.isEmpty }
    }

    static func period(_ all: [JournalEntry], in interval: DateInterval) -> Period {
        Period(spending: spending(all, in: interval),
               measured: Fuel.allCases.compactMap { measured(all, fuel: $0, in: interval) })
    }

    // MARK: - Цена профиля

    /// Предложение обновить цену в расчёте ценой из записи.
    struct PriceUpdate: Equatable, Sendable {
        let number: EnergyNumber
        /// Нынешняя цена профиля; 0 — не задана.
        let old: Double
        let new: Double
    }

    /// Спросить ли «обновить цену?». Только про свежую запись (старая,
    /// вписанная задним числом, говорит о прошлой цене), только про
    /// правдоподобную цену и только когда она заметно другая.
    static func priceUpdate(for entry: JournalEntry, profile: FuelProfile, now: Date) -> PriceUpdate? {
        guard let price = entry.unitPrice?.rounded(), price > 0 else { return nil }
        guard entry.date <= now,
              now.timeIntervalSince(entry.date) <= AppConfig.journalPriceRecentDays * 86_400 else { return nil }
        guard EnergyHints.check(price, .price(entry.kind.fuel)) == .ok else { return nil }
        let number = entry.kind.priceNumber
        let old = number.value(in: profile)
        if old > 0, abs(price - old) / old < AppConfig.journalPriceChangeShare { return nil }
        return PriceUpdate(number: number, old: old, new: price)
    }

    // MARK: - Правдоподобие

    /// Что переспросить перед сохранением.
    enum Doubt: Equatable, Sendable {
        /// Цена за единицу не похожа на правду — опечатка в сумме или в количестве.
        case price(perUnit: Double)
        /// Больше, чем помещается в машину.
        case quantity
        /// Пробег меньше, чем в записи раньше, или больше, чем в записи позже.
        case odometer(neighbour: Double)
    }

    static func doubts(_ entry: JournalEntry, among all: [JournalEntry]) -> [Doubt] {
        var result: [Doubt] = []
        if let price = entry.unitPrice, EnergyHints.check(price, .price(entry.kind.fuel)) != .ok {
            result.append(.price(perUnit: price))
        }
        if entry.quantity > entry.kind.maxQuantity { result.append(.quantity) }
        if let odometer = entry.odometerKm {
            let others = all.filter { $0.id != entry.id }
            let before = others.filter { $0.date < entry.date }.compactMap(\.odometerKm).max()
            let after = others.filter { $0.date > entry.date }.compactMap(\.odometerKm).min()
            if let before, odometer < before {
                result.append(.odometer(neighbour: before))
            } else if let after, odometer > after {
                result.append(.odometer(neighbour: after))
            }
        }
        return result
    }

    // MARK: - Порядок

    /// Новые сверху — так журнал читают.
    static func newestFirst(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.sorted { $0.date > $1.date }
    }
}
