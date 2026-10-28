//
//  JournalText.swift
//  RadarMap
//
//  Слова журнала заправок и зарядок (21.6): как назвать запись, значок,
//  строки «Итогов» («Потрачено 412 000 сум · 3 заправки, 9 зарядок»).
//  Числа — по языку приложения (EnergyText, Formatting).
//

import Foundation

enum JournalText {

    // MARK: - Вид записи

    /// В списке: «Бензин», «Зарядка дома».
    static func title(_ kind: JournalKind) -> String {
        switch kind {
        case .petrol, .methane, .propane: return kind.fuel.title
        case .homeCharge: return String(localized: "Зарядка дома")
        case .stationCharge: return String(localized: "Зарядка на станции")
        }
    }

    /// В переключателе формы — коротко.
    static func choice(_ kind: JournalKind) -> String {
        switch kind {
        case .petrol, .methane, .propane: return kind.fuel.title
        case .homeCharge: return EnergyText.place(.home)
        case .stationCharge: return String(localized: "На станции")
        }
    }

    static func symbol(_ kind: JournalKind) -> String {
        switch kind {
        case .petrol: return "fuelpump.fill"
        case .methane: return "flame.fill"
        case .propane: return "flame"
        case .homeCharge: return "house.fill"
        case .stationCharge: return "bolt.car.fill"
        }
    }

    // MARK: - Кнопки

    /// «Заправился» / «Зарядился» — то, что водитель только что сделал.
    static func action(_ mode: JournalEntryRequest.Mode) -> String {
        switch mode {
        case .fill: return String(localized: "Заправился")
        case .charge: return String(localized: "Зарядился")
        }
    }

    static func actionSymbol(_ mode: JournalEntryRequest.Mode) -> String {
        switch mode {
        case .fill: return "fuelpump.fill"
        case .charge: return "bolt.fill"
        }
    }

    /// Заголовок листа.
    static func sheetTitle(_ mode: JournalEntryRequest.Mode) -> String {
        switch mode {
        case .fill: return String(localized: "Заправка")
        case .charge: return String(localized: "Зарядка")
        }
    }

    static func fullTitle(_ mode: JournalEntryRequest.Mode) -> String {
        switch mode {
        case .fill: return String(localized: "До полного бака")
        case .charge: return String(localized: "Зарядил до 100 %")
        }
    }

    // MARK: - Числа

    /// «12 500 сум за л».
    static func unitPrice(_ price: Double, _ fuel: Fuel) -> String {
        String(format: String(localized: "%1$@ за %2$@"), Formatting.money(price.rounded()), fuel.unit)
    }

    /// «3 заправки, 9 зарядок»; без зарядок — только заправки.
    static func counts(_ spending: EnergyJournal.Spending) -> String {
        var parts: [String] = []
        if spending.fills > 0 { parts.append(Formatting.unbreakable(String(localized: "\(spending.fills) заправок"))) }
        if spending.charges > 0 { parts.append(Formatting.unbreakable(String(localized: "\(spending.charges) зарядок"))) }
        return parts.joined(separator: ", ")
    }

    /// «Куплено на 412 000 сум» — заправки и зарядки по журналу. Не
    /// «потрачено»: рядом стоит расчёт поездок, и два «расхода» разной
    /// природы читались одним числом с ошибкой (Н8 плана 34).
    static func spent(_ spending: EnergyJournal.Spending) -> String {
        String(format: String(localized: "Куплено на %@"), Formatting.money(spending.amount))
    }

    /// «5,8 л/100 км · 16 кВт·ч/100 км» — расход по факту, топливо за топливом.
    /// `mixedPetrol` — машина с батареей и бензином: литры делятся на весь
    /// пробег вместе с электрическими км, и «4,5 л/100 км» читалось бы как
    /// расход двигателя. Тогда — «4,5 л на 100 км пути» (ревью 21.6).
    static func measured(_ measured: [EnergyJournal.Measured], mixedPetrol: Bool = false) -> String? {
        guard !measured.isEmpty else { return nil }
        let values = measured.map { item -> String in
            guard mixedPetrol, item.fuel == .petrol else { return EnergyText.per100Short(item.per100, item.fuel) }
            return perTrip100(item.per100)
        }.joined(separator: " · ")
        // «по журналу», а не «по факту» (34): в поездке рядом расход по
        // паспорту, и источник обязан быть назван.
        return String(format: String(localized: "по журналу %@"), values)
    }

    /// «4,5 л на 100 км пути» — бензин гибрида с розеткой на весь пробег.
    static func perTrip100(_ litres: Double) -> String {
        Formatting.unbreakable(String(format: String(localized: "%@ на 100 км пути"),
                                      EnergyText.amount(litres, .petrol)))
    }

    /// Подпись под бензином в журнале у машины с батареей.
    static var wholeTripNote: String { String(localized: "на весь пробег, вместе с электричеством") }

    /// «на поездки ≈ 380 000 сум» — оценка вторым планом: во что обошлись
    /// километры периода, а не сколько купили.
    static func estimate(_ cost: Double) -> String {
        String(format: String(localized: "на поездки ≈ %@"), Formatting.money(FuelCost.rounded(cost)))
    }

    /// Строка записи: «30 л · 12 500 сум за л · 87 240 км · до полного».
    static func detail(_ entry: JournalEntry) -> String {
        var parts = [EnergyText.amount(entry.quantity, entry.kind.fuel)]
        if let price = entry.unitPrice { parts.append(unitPrice(price, entry.kind.fuel)) }
        if let odometer = entry.odometerKm { parts.append(EnergyText.km(odometer)) }
        if entry.isFull { parts.append(String(localized: "до полного")) }
        return parts.joined(separator: " · ")
    }

    /// «14 окт., 20:15».
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Formatting.numberLocale))
    }

    /// «Октябрь 2026» — заголовок месяца в журнале.
    static func month(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(Formatting.numberLocale)).capitalized(with: Formatting.numberLocale)
    }

    // MARK: - Правдоподобие

    static func doubt(_ doubt: EnergyJournal.Doubt, kind: JournalKind) -> String {
        switch doubt {
        case .price(let perUnit):
            return String(format: String(localized: "Выходит %@ — похоже на опечатку в сумме или количестве."),
                          unitPrice(perUnit, kind.fuel))
        case .quantity:
            return String(localized: "Столько в машину не помещается — проверьте количество.")
        case .odometer(let neighbour):
            return String(format: String(localized: "Пробег не сходится с соседней записью: там %@."),
                          EnergyText.km(neighbour))
        }
    }
}
