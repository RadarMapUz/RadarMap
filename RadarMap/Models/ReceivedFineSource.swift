//
//  ReceivedFineSource.swift
//  RadarMap
//
//  Откуда берутся пришедшие штрафы (этап 17) и черновик, который источник
//  отдаёт форме.
//
//  Сейчас источник один — сам водитель: вставленный текст СМС или
//  уведомления (PastedTextFineSource → FineTextParser) и ручная форма. 17.4 —
//  источник по госномеру (my.gov.uz, Click, Payme) — появится только после
//  соглашения 👤: запрос пойдёт с телефона прямо к источнику, не через наш
//  сервер, и номер уйдёт только туда — об этом скажет экран. Протокол здесь
//  ровно ради этой подмены (ARCHITECTURE.md, правило 2): форма и сверка
//  работают с черновиками и не знают, откуда они. Имя — ReceivedFineSource:
//  `FineSource` уже занято разбором рейтинга («откуда штрафы» по камерам).
//

import Foundation

/// Что источнику дали на вход. 17.4 добавит свой случай (номер машины) —
/// и только для источника по номеру; у вставки текста номера нет.
nonisolated enum FineSourceInput: Sendable {
    case text(String)
}

nonisolated protocol ReceivedFineSource: Sendable {
    var kind: FineSourceKind { get }
    /// Черновики штрафов. Пусто — источник ничего не нашёл (честное «не
    /// распознали», а не пустой штраф).
    func drafts(from input: FineSourceInput) async throws -> [FineDraft]
}

/// Вставленный текст: разбор на телефоне, сеть не нужна.
nonisolated struct PastedTextFineSource: ReceivedFineSource {
    var kind: FineSourceKind { .pasted }

    func drafts(from input: FineSourceInput) async throws -> [FineDraft] {
        switch input {
        case .text(let text):
            let draft = FineTextParser.parse(text)
            return draft.looksLikeFine && !draft.isEmpty ? [draft] : []
        }
    }
}

/// Что удалось достать из текста. Каждое поле — со своей уверенностью.
nonisolated struct FineDraft: Equatable, Sendable {
    struct Field<Value: Equatable & Sendable>: Equatable, Sendable {
        var value: Value
        /// Поле подписано в тексте или единственное в своём роде. false — форма
        /// просит проверить.
        var sure: Bool
    }

    struct Day: Equatable, Sendable {
        var year: Int
        var month: Int
        var day: Int
    }

    struct Clock: Equatable, Sendable {
        var hour: Int
        var minute: Int
    }

    enum Name: String, CaseIterable, Sendable {
        case date, time, issued, due, amount, speed, limit, resolution, place
    }

    /// Текст вообще про штраф. false — «не распознали», полей нет.
    var looksLikeFine = false
    /// Дата и время нарушения.
    var date: Field<Day>?
    var time: Field<Clock>?
    /// Дата постановления и срок оплаты из текста.
    var issued: Field<Day>?
    var due: Field<Day>?
    var amount: Field<Double>?
    var speedKmh: Field<Int>?
    var limitKmh: Field<Int>?
    var resolution: Field<String>?
    var place: Field<String>?

    var foundFields: [Name] {
        Name.allCases.filter { sureness(of: $0) != nil }
    }

    var unsureFields: [Name] {
        Name.allCases.filter { sureness(of: $0) == false }
    }

    var isEmpty: Bool { foundFields.isEmpty }

    /// nil — поля нет; иначе уверенность.
    func sureness(of name: Name) -> Bool? {
        switch name {
        case .date: date?.sure
        case .time: time?.sure
        case .issued: issued?.sure
        case .due: due?.sure
        case .amount: amount?.sure
        case .speed: speedKmh?.sure
        case .limit: limitKmh?.sure
        case .resolution: resolution?.sure
        case .place: place?.sure
        }
    }

    static func date(_ day: Day, clock: Clock? = nil, calendar: Calendar = .current) -> Date? {
        var parts = DateComponents(year: day.year, month: day.month, day: day.day)
        parts.hour = clock?.hour ?? 0
        parts.minute = clock?.minute ?? 0
        return calendar.date(from: parts)
    }
}
