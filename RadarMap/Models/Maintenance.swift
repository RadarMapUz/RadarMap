//
//  Maintenance.swift
//  RadarMap
//
//  Обслуживание машины (план 20.10, этап 18.1). Пробег приложение и так
//  считает по поездкам — значит, может напомнить о масле, фильтрах, ГРМ, а
//  по датам — об ОСАГО, техосмотре, газовом баллоне, тонировке, доверенности
//  и КАСКО. Всё на телефоне.
//
//  Одометр = пробег, который ввёл водитель (с моментом ввода), плюс километры
//  поездок ПОСЛЕ ввода. Источник километров — дневные агрегаты (`TripDay`):
//  записи поездок чистятся через 30 дней, а день живёт вечно — через полгода
//  одометр по записям потерял бы всё, что старше месяца. День ввода считается
//  разницей: сколько в его строке набралось сверх того, что там уже лежало в
//  момент ввода. Поездки до ввода в пробег не входят — они уже на приборке.
//
//  Срок пункта — первый из двух: по пробегу (сделано при N км + интервал) и
//  по дате (сделано тогда-то + месяцы, или «действует до» у документов).
//  Состояние — худшее из двух: «скоро» за 500 км / 14 дней, «пора» с самого
//  срока, «просрочено» — когда срок прошёл на 1 000 км / 30 дней (документ —
//  на следующий день после последнего дня действия).
//
//  Нет данных — нет срока («не задано»), а не выдуманный срок: «масло меняли
//  при вводе пробега» было бы враньём, которое молча сдвигает замену.
//
//  Чистая логика — MaintenanceTests.
//

import Foundation

/// Пункт обслуживания. Порядок `allCases` — порядок на экране.
nonisolated enum MaintenanceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case oil, airFilter, cabinFilter, brakeFluid, timingBelt, sparkPlugs
    case osago, inspection, gasCylinder, tintPermit, proxy, kasko

    var id: String { rawValue }

    /// Документ или проверка: только дата «действует до», без пробега.
    var isDocument: Bool {
        switch self {
        case .oil, .airFilter, .cabinFilter, .brakeFluid, .timingBelt, .sparkPlugs: return false
        case .osago, .inspection, .gasCylinder, .tintPermit, .proxy, .kasko: return true
        }
    }

    /// Интервал по пробегу по умолчанию, км; nil — пункт не по пробегу.
    var defaultIntervalKm: Double? {
        switch self {
        case .oil: return AppConfig.maintenanceOilKm
        case .airFilter: return AppConfig.maintenanceAirFilterKm
        case .cabinFilter: return AppConfig.maintenanceCabinFilterKm
        case .timingBelt: return AppConfig.maintenanceTimingBeltKm
        case .sparkPlugs: return AppConfig.maintenanceSparkPlugsKm
        case .brakeFluid, .osago, .inspection, .gasCylinder, .tintPermit, .proxy, .kasko: return nil
        }
    }

    /// Интервал по времени по умолчанию, месяцев; nil — срок вводится датой
    /// (доверенность: у каждой свой).
    var defaultIntervalMonths: Int? {
        switch self {
        case .oil: return AppConfig.maintenanceOilMonths
        case .airFilter: return AppConfig.maintenanceAirFilterMonths
        case .cabinFilter: return AppConfig.maintenanceCabinFilterMonths
        case .brakeFluid: return AppConfig.maintenanceBrakeFluidMonths
        case .gasCylinder: return AppConfig.maintenanceGasCylinderMonths
        case .inspection: return AppConfig.maintenanceInspectionMonths
        case .osago: return AppConfig.maintenanceOsagoMonths
        case .kasko: return AppConfig.maintenanceKaskoMonths
        case .tintPermit: return AppConfig.maintenanceTintMonths
        case .timingBelt, .sparkPlugs, .proxy: return nil
        }
    }

    /// Включён, пока водитель не сказал иначе. Тонировка, доверенность и
    /// КАСКО есть не у всех — их включают сами; список не должен начинаться
    /// с чужих забот.
    var enabledByDefault: Bool {
        switch self {
        case .tintPermit, .proxy, .kasko: return false
        default: return true
        }
    }

    /// Бывает ли пункт у такой машины: у электромобиля нет масла, фильтра
    /// мотора, ГРМ и свечей; газовый баллон — только у метана и пропана.
    func applies(to energy: VehicleEnergy) -> Bool {
        // Сопоставление с образцом, а не `==`: VehicleEnergy живёт на главном
        // акторе, а это решение зовут и чистые движки.
        switch (self, energy) {
        case (.oil, .electric), (.airFilter, .electric), (.timingBelt, .electric), (.sparkPlugs, .electric):
            return false
        case (.gasCylinder, .cng), (.gasCylinder, .lpg): return true
        case (.gasCylinder, _): return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .oil: return String(localized: "Масло двигателя")
        case .airFilter: return String(localized: "Воздушный фильтр")
        case .cabinFilter: return String(localized: "Салонный фильтр")
        case .brakeFluid: return String(localized: "Тормозная жидкость")
        case .timingBelt: return String(localized: "Ремень ГРМ")
        case .sparkPlugs: return String(localized: "Свечи зажигания")
        case .osago: return String(localized: "ОСАГО")
        case .inspection: return String(localized: "Техосмотр")
        case .gasCylinder: return String(localized: "Проверка газового баллона")
        case .tintPermit: return String(localized: "Разрешение на тонировку")
        case .proxy: return String(localized: "Доверенность")
        case .kasko: return String(localized: "КАСКО")
        }
    }

    var symbol: String {
        switch self {
        case .oil: return "oilcan.fill"
        case .airFilter: return "wind"
        case .cabinFilter: return "air.purifier.fill"
        case .brakeFluid: return "drop.fill"
        case .timingBelt: return "gearshape.2.fill"
        case .sparkPlugs: return "bolt.fill"
        case .osago: return "checkmark.shield.fill"
        case .inspection: return "wrench.and.screwdriver.fill"
        case .gasCylinder: return "cylinder.fill"
        case .tintPermit: return "sunglasses.fill"
        case .proxy: return "person.text.rectangle.fill"
        case .kasko: return "shield.lefthalf.filled"
        }
    }
}

/// Что водитель сказал об одном пункте. Всё опционально: файл лежит у людей
/// на диске, и новое поле не должно ронять разбор старого (ARCHITECTURE, 18).
nonisolated struct MaintenanceRecord: Codable, Equatable, Sendable {
    /// nil — как по умолчанию у пункта.
    var enabled: Bool?
    /// Свой интервал, км: nil — по умолчанию, 0 — «не по пробегу».
    var intervalKm: Double?
    /// Свой интервал, месяцев: nil — по умолчанию, 0 — «не по времени».
    var intervalMonths: Int?
    /// Одометр, при котором делали в последний раз.
    var doneKm: Double?
    /// Когда делали (продлевали) в последний раз.
    var doneAt: Date?
    /// «Действует до» — последний день действия документа. Если задан, срок
    /// по дате — он, а не «сделано + месяцы».
    var dueDate: Date?
}

/// Всё обслуживание машины: введённый пробег и пункты.
nonisolated struct MaintenanceBook: Codable, Equatable, Sendable {
    /// Пробег с приборки на момент ввода, км.
    var odometerKm: Double?
    /// Когда ввели пробег.
    var odometerAt: Date?
    /// Сколько метров уже лежало в дневной строке дня ввода в момент ввода:
    /// поездки этого дня ДО ввода в пробег не входят.
    var odometerDayBaseMeters: Double?
    /// Пункты по `rawValue`: словарь со строковыми ключами, а не с enum —
    /// пункт, добавленный будущей версией, не должен валить разбор у этой.
    var records: [String: MaintenanceRecord]?

    func record(_ kind: MaintenanceKind) -> MaintenanceRecord {
        records?[kind.rawValue] ?? MaintenanceRecord()
    }

    mutating func set(_ record: MaintenanceRecord, for kind: MaintenanceKind) {
        var all = records ?? [:]
        all[kind.rawValue] = record
        records = all
    }

    func isEnabled(_ kind: MaintenanceKind) -> Bool {
        record(kind).enabled ?? kind.enabledByDefault
    }
}

nonisolated enum Maintenance {

    enum Status: Int, Comparable, Sendable {
        /// Нет данных, чтобы назвать срок.
        case unknown
        case ok
        case soon
        /// Срок наступил.
        case due
        /// Срок прошёл давно (документ — истёк).
        case overdue

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Есть о чём сказать водителю: карточка в «Итогах», уведомление.
        var needsAttention: Bool { self >= .soon }
    }

    /// Состояние пункта на сейчас — всё, что показывают экран и напоминания.
    struct State: Equatable, Identifiable, Sendable {
        let kind: MaintenanceKind
        let status: Status
        /// Действующие интервалы (свои или по умолчанию).
        let intervalKm: Double?
        let intervalMonths: Int?
        /// До срока по пробегу, км; отрицательное — пробег за сроком.
        let remainingKm: Double?
        /// Срок по дате — начало последнего дня.
        let dueDate: Date?
        /// Календарных дней до срока; 0 — срок сегодня, отрицательное — прошёл.
        let daysLeft: Int?
        /// Израсходованная доля интервала, 0…1 (худшая из двух); nil — не из чего.
        let progress: Double?
        /// Цикл обслуживания: меняется, когда пункт сделали заново или
        /// поменяли дату. Одно напоминание на порог — на цикл.
        let cycle: String

        var id: MaintenanceKind { kind }
    }

    // MARK: - Одометр

    /// Пробег сейчас, км; nil — пробег не вводили.
    static func odometer(_ book: MaintenanceBook, days: [TripDay],
                         calendar: Calendar = .current) -> Double? {
        guard let entered = book.odometerKm, let at = book.odometerAt else { return nil }
        var meters = 0.0
        for day in days {
            if calendar.isDate(day.day, inSameDayAs: at) {
                // Строка дня ввода: только прибавка после ввода. Строка могла
                // и уменьшиться (удалили поездку до ввода) — тогда ноль.
                meters += max(0, day.distanceMeters - (book.odometerDayBaseMeters ?? 0))
            } else if day.day > at {
                meters += day.distanceMeters
            }
        }
        return entered + meters / 1000
    }

    /// Новый пробег с приборки: запоминаем и момент, и то, что уже лежит в
    /// строке сегодняшнего дня, — сегодняшние поездки до ввода уже на приборке.
    static func settingOdometer(_ book: MaintenanceBook, km: Double, now: Date, days: [TripDay],
                                calendar: Calendar = .current) -> MaintenanceBook {
        var book = book
        book.odometerKm = max(0, km)
        book.odometerAt = now
        book.odometerDayBaseMeters = days.first { calendar.isDate($0.day, inSameDayAs: now) }?.distanceMeters ?? 0
        return book
    }

    // MARK: - Правки пункта

    /// «Сделано сегодня»: цикл заново от нынешнего пробега и сегодняшней даты.
    /// «Действует до» снимается — следующий срок считается от сегодня.
    static func markedDone(_ book: MaintenanceBook, kind: MaintenanceKind, odometerKm: Double?,
                           now: Date) -> MaintenanceBook {
        var book = book
        var record = book.record(kind)
        record.doneKm = kind.isDocument ? nil : odometerKm
        record.doneAt = now
        record.dueDate = nil
        record.enabled = true
        book.set(record, for: kind)
        return book
    }

    /// Можно ли «сделано сегодня» одной кнопкой: у документа без интервала
    /// (доверенность) следующий срок неизвестен — его вводят датой.
    static func canMarkDone(_ kind: MaintenanceKind, record: MaintenanceRecord) -> Bool {
        !kind.isDocument || effectiveMonths(kind, record) != nil
    }

    static func effectiveKm(_ kind: MaintenanceKind, _ record: MaintenanceRecord) -> Double? {
        guard !kind.isDocument else { return nil }
        let value = record.intervalKm ?? kind.defaultIntervalKm
        guard let value, value > 0 else { return nil }
        return value
    }

    static func effectiveMonths(_ kind: MaintenanceKind, _ record: MaintenanceRecord) -> Int? {
        let value = record.intervalMonths ?? kind.defaultIntervalMonths
        guard let value, value > 0 else { return nil }
        return value
    }

    // MARK: - Состояние

    static func state(_ kind: MaintenanceKind, record: MaintenanceRecord, odometerKm: Double?,
                      now: Date, calendar: Calendar = .current) -> State {
        let intervalKm = effectiveKm(kind, record)
        let months = effectiveMonths(kind, record)
        var statuses: [Status] = []
        var progress: [Double] = []

        // По пробегу.
        var remainingKm: Double?
        if let intervalKm, let done = record.doneKm, let odometerKm {
            // Сделано «при пробеге больше нынешнего» — опечатка или правка
            // одометра вниз: считаем, что только что сделали, а не уходим в минус.
            let used = max(0, odometerKm - done)
            let remaining = intervalKm - used
            remainingKm = remaining
            progress.append(used / intervalKm)
            statuses.append(kmStatus(remaining))
        }

        // По дате.
        let today = calendar.startOfDay(for: now)
        let start = record.doneAt.map { calendar.startOfDay(for: $0) }
        var due: Date?
        if let explicit = record.dueDate {
            due = calendar.startOfDay(for: explicit)
        } else if let start, let months {
            due = calendar.date(byAdding: .month, value: months, to: start)
        }
        var daysLeft: Int?
        if let due {
            let left = days(from: today, to: due, calendar: calendar)
            daysLeft = left
            statuses.append(dateStatus(left, document: kind.isDocument))
            // Полоса: от «сделано» (или от срока минус интервал) до срока.
            let from = start.flatMap { $0 < due ? $0 : nil }
                ?? months.flatMap { calendar.date(byAdding: .month, value: -$0, to: due) }
            if let from {
                let total = days(from: from, to: due, calendar: calendar)
                if total > 0 {
                    progress.append(Double(days(from: from, to: today, calendar: calendar)) / Double(total))
                }
            }
        }

        let cycle = [record.doneKm.map { String(Int($0.rounded())) } ?? "-",
                     record.doneAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-",
                     record.dueDate.map { String(Int($0.timeIntervalSince1970)) } ?? "-"]
            .joined(separator: "_")

        return State(kind: kind, status: statuses.max() ?? .unknown,
                     intervalKm: intervalKm, intervalMonths: months,
                     remainingKm: remainingKm, dueDate: due, daysLeft: daysLeft,
                     progress: progress.max().map { min(1, max(0, $0)) },
                     cycle: cycle)
    }

    /// Пункты, которые бывают у этой машины и включены, — по порядку экрана.
    static func states(_ book: MaintenanceBook, energy: VehicleEnergy, odometerKm: Double?,
                       now: Date, calendar: Calendar = .current) -> [State] {
        MaintenanceKind.allCases
            .filter { $0.applies(to: energy) && book.isEnabled($0) }
            .map { state($0, record: book.record($0), odometerKm: odometerKm, now: now, calendar: calendar) }
    }

    /// Что требует внимания — самое срочное первым, при равенстве — порядок экрана.
    static func attention(_ states: [State]) -> [State] {
        let order = Dictionary(uniqueKeysWithValues: MaintenanceKind.allCases.enumerated().map { ($1, $0) })
        return states.filter { $0.status.needsAttention }
            .sorted { lhs, rhs in
                lhs.status != rhs.status ? lhs.status > rhs.status
                    : (order[lhs.kind] ?? 0) < (order[rhs.kind] ?? 0)
            }
    }

    static func kmStatus(_ remaining: Double) -> Status {
        if remaining <= -AppConfig.maintenanceOverdueKm { return .overdue }
        if remaining <= 0 { return .due }
        if remaining <= AppConfig.maintenanceSoonKm { return .soon }
        return .ok
    }

    static func dateStatus(_ daysLeft: Int, document: Bool) -> Status {
        if document {
            if daysLeft < 0 { return .overdue }
        } else if daysLeft <= -AppConfig.maintenanceOverdueDays {
            return .overdue
        }
        if daysLeft <= 0 { return .due }
        if daysLeft <= AppConfig.maintenanceSoonDays { return .soon }
        return .ok
    }

    static func days(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                to: calendar.startOfDay(for: to)).day ?? 0
    }
}
