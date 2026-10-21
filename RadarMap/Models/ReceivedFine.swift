//
//  ReceivedFine.swift
//  RadarMap
//
//  Пришедший штраф (этап 17) — то, что водитель внёс сам: вставил текст СМС
//  или уведомления, заполнил форму. Живёт ТОЛЬКО на телефоне (FineStore,
//  Documents/received_fines.json). Госномера здесь нет и не будет: он не
//  нужен ни сверке, ни экрану, а значит не должен лежать рядом со штрафами.
//
//  Все поля, кроме id и даты внесения, опциональные. И потому, что
//  уведомление бывает неполным (разбор текста поле не выдумывает), и по
//  правилу 18: новое поле в файле на диске — только Optional. По той же
//  причине связь с проездом — структура с опциональными полями, а не enum:
//  незнакомый случай из будущей сборки не должен ронять разбор всего штрафа.
//
//  Сроки оплаты и напоминание — чистые FineDeadline / FineReminder (тесты
//  FineLedgerTests): правила 👤 не подтверждены, поэтому всё — константами
//  AppConfig, а экран говорит о сроках нейтрально.
//

import Foundation
import CoreLocation

/// Откуда штраф. 17.4 (источник по номеру) добавит сюда свой случай — после
/// соглашения; до него в приложении нет ничего, что ходит за штрафами в сеть.
nonisolated enum FineSourceKind: String, Sendable {
    /// Форма, заполненная руками.
    case manual
    /// Вставленный текст СМС или уведомления (FineTextParser).
    case pasted
}

nonisolated struct ReceivedFine: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Когда внесли в приложение.
    let addedAt: Date
    /// Когда зафиксировано нарушение. Без времени суток (timeKnown != true) —
    /// полночь дня: сверка тогда ищет по всему дню.
    var violationAt: Date?
    var timeKnown: Bool?
    /// Место как в уведомлении или выбранное из проездов дня — свободный текст.
    var place: String?
    var lat: Double?
    var lon: Double?
    /// Скорость и лимит из постановления, км/ч.
    var speedKmh: Int?
    var limitKmh: Int?
    /// Сумма постановления, сум. nil — не указана (не выдумываем).
    var amount: Double?
    /// Номер постановления.
    var resolution: String?
    /// Дата постановления — от неё считается срок оплаты.
    var issuedAt: Date?
    /// Срок оплаты, если указан в самом постановлении: он главнее нашего.
    var dueAt: Date?
    /// Оплачен (пометка владельца).
    var paidAt: Date?
    /// FineSourceKind.rawValue — строкой: незнакомое значение из будущей
    /// сборки читается как «вручную», а не роняет штраф.
    var source: String?
    /// С чем сверен (FineMatch). nil — «без поездки в истории».
    var link: FineLink?
    /// На когда поставлено напоминание об оплате. Прошло — напоминание уже
    /// пришло, второго не будет (FineReminder).
    var reminderAt: Date?

    init(id: UUID = UUID(), addedAt: Date = Date()) {
        self.id = id
        self.addedAt = addedAt
    }

    var sourceKind: FineSourceKind { source.flatMap(FineSourceKind.init(rawValue:)) ?? .manual }
    var isPaid: Bool { paidAt != nil }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Запрос сверки (FineMatch) — без даты сверять не с чем.
    var matchQuery: FineMatch.Query? {
        guard let violationAt else { return nil }
        return FineMatch.Query(at: violationAt, timeKnown: timeKnown == true, place: place,
                               lat: lat, lon: lon, speedKmh: speedKmh)
    }
}

/// С чем сверен пришедший штраф.
///
/// Проезд — `tripID` + `passID`: проезд получил «штраф пришёл» с суммой
/// постановления. День — `day`: запись поездки уже вычищена, проезда нет,
/// но дневная сводка помнит превышение; деньги дня перенесены хирургически
/// (`riskMoved` снято с «возможных», `paidAdded` положено в «пришло») —
/// ровно эти числа и возвращаются при отвязке.
nonisolated struct FineLink: Codable, Equatable, Sendable {
    var tripID: Double?
    var passID: UUID?
    var day: Date?
    var riskMoved: Double?
    var paidAdded: Double?

    static func pass(tripID: Double, passID: UUID) -> FineLink {
        FineLink(tripID: tripID, passID: passID)
    }

    static func day(_ day: Date, riskMoved: Double, paidAdded: Double) -> FineLink {
        FineLink(day: day, riskMoved: riskMoved, paidAdded: paidAdded)
    }

    enum Kind: Equatable {
        case pass(tripID: Double, passID: UUID)
        case day(Date)
        /// Связь из будущей сборки или битая — считаем «без поездки».
        case unknown
    }

    var kind: Kind {
        if let tripID, let passID { return .pass(tripID: tripID, passID: passID) }
        if let day { return .day(day) }
        return .unknown
    }
}

// MARK: - Сроки оплаты

/// Срок оплаты и льготный срок штрафа. 👤 Правила не подтверждены (AppConfig,
/// «ПОДТВЕРДИТЬ»): срок из самого постановления главнее, наш — ориентир.
nonisolated enum FineDeadline {
    struct Terms: Equatable {
        /// Последний день оплаты (начало дня — срок «до … включительно»).
        let due: Date
        /// Срок взят из постановления, а не посчитан нами.
        let dueIsOfficial: Bool
        /// Последний день льготной оплаты; nil — льготы нет или срок прошёл бы
        /// позже основного.
        let discountUntil: Date?
        /// Сумма в льготный срок; nil — суммы нет.
        let discounted: Double?
    }

    enum Status: Equatable {
        case paid
        /// Идёт льготный срок — до этого дня включительно.
        case discount(until: Date)
        /// Идёт обычный срок — до этого дня включительно.
        case due(until: Date)
        case overdue(since: Date)
        /// Ни даты постановления, ни даты нарушения — считать не от чего.
        case unknown
    }

    static func terms(for fine: ReceivedFine, calendar: Calendar = .current) -> Terms? {
        let base = (fine.issuedAt ?? fine.violationAt).map { calendar.startOfDay(for: $0) }
        let official = fine.dueAt.map { calendar.startOfDay(for: $0) }
        guard let due = official ?? base.flatMap({
            calendar.date(byAdding: .day, value: AppConfig.finePaymentDays, to: $0)
        }) else { return nil }
        var discountUntil: Date?
        if let base, AppConfig.fineDiscountDays > 0, AppConfig.fineDiscountShare > 0,
           let until = calendar.date(byAdding: .day, value: AppConfig.fineDiscountDays, to: base),
           until < due {
            discountUntil = until
        }
        let discounted = discountUntil == nil ? nil
            : fine.amount.map { ($0 * (1 - AppConfig.fineDiscountShare)).rounded() }
        return Terms(due: due, dueIsOfficial: official != nil,
                     discountUntil: discountUntil, discounted: discounted)
    }

    static func status(for fine: ReceivedFine, now: Date,
                       calendar: Calendar = .current) -> Status {
        if fine.isPaid { return .paid }
        guard let terms = terms(for: fine, calendar: calendar) else { return .unknown }
        let today = calendar.startOfDay(for: now)
        if let until = terms.discountUntil, today <= until { return .discount(until: until) }
        if today <= terms.due { return .due(until: terms.due) }
        return .overdue(since: terms.due)
    }
}

// MARK: - Напоминание об оплате

/// Одно напоминание на штраф — и ровно одно: пришедшее не повторяется.
/// Ставится за `fineReminderLeadDays` до ближайшего срока (льготного, пока он
/// впереди с запасом, иначе основного), в `fineReminderHour`.
nonisolated enum FineReminder {
    struct Plan: Equatable {
        /// Когда напомнить.
        let fire: Date
        /// О каком сроке: льготном или основном.
        let deadline: Date
        let isDiscount: Bool
    }

    enum Action: Equatable {
        case none
        case schedule(Plan)
        case cancel
    }

    /// Когда напомнить, без оглядки на уже поставленное. nil — некогда:
    /// оплачен, сроков нет или до срока меньше запаса (человек как раз
    /// смотрит на штраф — напоминать поздно и незачем).
    static func plan(for fine: ReceivedFine, now: Date,
                     calendar: Calendar = .current) -> Plan? {
        guard !fine.isPaid, let terms = FineDeadline.terms(for: fine, calendar: calendar) else { return nil }
        func fire(before deadline: Date) -> Date? {
            guard let day = calendar.date(byAdding: .day, value: -AppConfig.fineReminderLeadDays, to: deadline)
            else { return nil }
            return calendar.date(bySettingHour: AppConfig.fineReminderHour, minute: 0, second: 0, of: day)
        }
        if let until = terms.discountUntil, let date = fire(before: until), date > now {
            return Plan(fire: date, deadline: until, isDiscount: true)
        }
        if let date = fire(before: terms.due), date > now {
            return Plan(fire: date, deadline: terms.due, isDiscount: false)
        }
        return nil
    }

    /// Что сделать с напоминанием сейчас. Поставленное и уже наступившее —
    /// пришло: больше ничего (одно напоминание на штраф). Поставленное и ещё
    /// не наступившее можно переставить (сменили срок) или снять (оплатил).
    static func action(for fine: ReceivedFine, now: Date,
                       calendar: Calendar = .current) -> Action {
        if let set = fine.reminderAt, set <= now { return .none }
        guard let plan = plan(for: fine, now: now, calendar: calendar) else {
            return fine.reminderAt == nil ? .none : .cancel
        }
        return plan.fire == fine.reminderAt ? .none : .schedule(plan)
    }
}
