//
//  FineForm.swift
//  RadarMap
//
//  Поля формы «Штраф пришёл» (этап 17.2) — значение, а не вьюха: что
//  подставить из разобранного текста, из проезда, из уже внесённого штрафа,
//  и какой ReceivedFine из этого получится. Правило то же, что у разбора:
//  пустое поле остаётся пустым — ни нулей, ни «сегодня» по умолчанию, ни
//  лимита из нашего замера вместо лимита из постановления.
//
//  Чистая логика — FineFormTests.
//

import Foundation

nonisolated struct FineForm: Equatable {
    /// День нарушения (начало дня). nil — не указан: без него не сохранить.
    var day: Date?
    var timeKnown = false
    /// Часы и минуты (дата внутри не важна).
    var hour = 12
    var minute = 0
    var place = ""
    var speed = ""
    var limit = ""
    var amount = ""
    var resolution = ""
    var issued: Date?
    var due: Date?
    /// Поля, которые разбор нашёл без уверенности: форма просит их проверить.
    var unsure: Set<FineDraft.Name> = []
    /// Поля подставлены разбором текста (источник штрафа — «вставлен»).
    var fromText = false

    init() {}

    /// Правка внесённого штрафа.
    init(fine: ReceivedFine, calendar: Calendar = .current) {
        if let at = fine.violationAt {
            day = calendar.startOfDay(for: at)
            timeKnown = fine.timeKnown == true
            hour = calendar.component(.hour, from: at)
            minute = calendar.component(.minute, from: at)
        }
        place = fine.place ?? ""
        speed = fine.speedKmh.map(String.init) ?? ""
        limit = fine.limitKmh.map(String.init) ?? ""
        amount = fine.amount.map { Self.grouped(Int($0.rounded())) } ?? ""
        resolution = fine.resolution ?? ""
        issued = fine.issuedAt
        due = fine.dueAt
        fromText = fine.sourceKind == .pasted
    }

    /// «Пришёл» на проезде: когда и где — из проезда (это и есть сверка),
    /// а скорость, лимит и сумма — только из постановления, их не знаем.
    init(pass: PassedCamera, calendar: Calendar = .current) {
        day = calendar.startOfDay(for: pass.date)
        timeKnown = true
        hour = calendar.component(.hour, from: pass.date)
        minute = calendar.component(.minute, from: pass.date)
        place = pass.location
    }

    /// Подставить найденное разбором. Не найденное не трогается: человек мог
    /// уже вписать это руками.
    mutating func apply(_ draft: FineDraft, calendar: Calendar = .current) {
        guard draft.looksLikeFine else { return }
        fromText = true
        if let date = draft.date, let value = FineDraft.date(date.value, calendar: calendar) {
            day = value
        }
        if let time = draft.time {
            timeKnown = true
            hour = time.value.hour
            minute = time.value.minute
        }
        if let place = draft.place { self.place = place.value }
        if let speed = draft.speedKmh { self.speed = String(speed.value) }
        if let limit = draft.limitKmh { self.limit = String(limit.value) }
        if let amount = draft.amount { self.amount = Self.grouped(Int(amount.value.rounded())) }
        if let resolution = draft.resolution { self.resolution = resolution.value }
        if let issued = draft.issued { self.issued = FineDraft.date(issued.value, calendar: calendar) }
        if let due = draft.due { self.due = FineDraft.date(due.value, calendar: calendar) }
        unsure = Set(draft.unsureFields)
    }

    /// Момент нарушения: день + время, если оно известно.
    func violationAt(calendar: Calendar = .current) -> Date? {
        guard let day else { return nil }
        guard timeKnown else { return day }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// Запрос сверки — без дня сверять не с чем.
    func query(calendar: Calendar = .current) -> FineMatch.Query? {
        guard let at = violationAt(calendar: calendar) else { return nil }
        return FineMatch.Query(at: at, timeKnown: timeKnown, place: Self.text(place),
                               lat: nil, lon: nil, speedKmh: Self.integer(speed))
    }

    var canSave: Bool { day != nil }

    /// Штраф из полей поверх `base` (новый — пустой, правка — прежний: его
    /// id, дата внесения, оплата, напоминание и координата сохраняются).
    func fine(updating base: ReceivedFine, calendar: Calendar = .current) -> ReceivedFine {
        var fine = base
        fine.violationAt = violationAt(calendar: calendar)
        fine.timeKnown = day == nil ? nil : timeKnown
        fine.place = Self.text(place)
        fine.speedKmh = Self.integer(speed)
        fine.limitKmh = Self.integer(limit)
        fine.amount = Self.integer(amount).map(Double.init).flatMap { $0 > 0 ? $0 : nil }
        fine.resolution = Self.text(resolution)
        fine.issuedAt = issued
        fine.dueAt = due
        if base.source == nil || fromText {
            fine.source = (fromText ? FineSourceKind.pasted : .manual).rawValue
        }
        return fine
    }

    /// Целое из поля: только цифры («1 650 000» и «1.650.000» — одно число).
    /// Сумма с разделителями разрядов по языку приложения: «2 200 000», а не
    /// «2200000» — сверять с постановлением глазами. `integer` берёт только
    /// цифры, поэтому пробелы разбору не мешают.
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Formatting.numberLocale))
    }

    /// То же для ввода: цифры из набранного → с разделителями; пусто — пусто.
    static func groupedDigits(_ text: String) -> String {
        integer(text).map(grouped) ?? ""
    }

    static func integer(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 10 else { return nil }
        return Int(digits)
    }

    static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
