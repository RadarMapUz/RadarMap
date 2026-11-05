//
//  FineLedger.swift
//  RadarMap
//
//  Экран «Штрафы» одним посчитанным объектом (этап 17.3): пришедшие —
//  со сроками и сверкой, ожидаемые — проезды с риском, по которым ещё ничего
//  не пришло, и суммы. Вьюха только показывает (ARCHITECTURE.md: данные в
//  модели); шапка и строки читают ОДИН расчёт (правило 14).
//
//  Чистая логика — FineLedgerTests.
//

import Foundation

nonisolated struct FineLedger {
    /// Проезд с риском штрафа, по которому ещё ничего не пришло.
    struct Expected: Identifiable {
        let pass: PassedCamera
        let tripID: Double
        /// Оценка по ступени (достоверный лимит) — не постановление.
        let estimate: Double
        var id: UUID { pass.id }
    }

    /// С чем сверен пришедший штраф — для строки экрана.
    enum LinkState {
        case pass(PassedCamera, tripID: Double)
        /// Сверен с проездом, но запись поездки уже вычищена.
        case passGone
        /// Сверен с днём по сводке (запись вычищена ещё до сверки).
        case day(Date)
        case none
    }

    struct Received: Identifiable {
        let fine: ReceivedFine
        let link: LinkState
        let status: FineDeadline.Status
        let terms: FineDeadline.Terms?
        var id: UUID { fine.id }
    }

    var received: [Received] = []
    var expected: [Expected] = []
    /// «Пришёл» отмечен кнопкой, а постановление не внесено — предложить внести.
    var marked: [Expected] = []
    /// Не оплачено, сумма известна.
    var toPay: Double = 0
    var toPayCount = 0
    /// Не оплачено, а сумма не указана — сумма «к оплате» без них неполна.
    var unknownAmountCount = 0
    var paidTotal: Double = 0
    var expectedSum: Double = 0

    var isEmpty: Bool { received.isEmpty && expected.isEmpty && marked.isEmpty }

    /// Сколько штрафов пришло — одно правило на шапку и вкладку «Пришли»:
    /// внесённые постановления и отмеченные «пришёл» без постановления. До
    /// 05.11 шапка считала только внесённые («Пришло 2»), а вкладка — оба
    /// («Пришли · 3»), и один экран называл два числа.
    var arrivedCount: Int { received.count + marked.count }

    static func build(fines: [ReceivedFine], history: [TripRecord], now: Date,
                      calendar: Calendar = .current) -> FineLedger {
        var ledger = FineLedger()
        var passes: [UUID: (pass: PassedCamera, tripID: Double)] = [:]
        let horizon = now.addingTimeInterval(-Double(AppConfig.fineExpiresDays) * 86400)
        for record in history {
            for pass in record.passed {
                passes[pass.id] = (pass, record.id)
                // Ожидаемые — только по достоверному лимиту (как вся сумма
                // риска) и не старше срока, после которого штраф обычно не
                // приходит: старые — забота «Ждут ответа», а не этой суммы.
                guard pass.fineReceiptID == nil, pass.limitIsCertain, let limit = pass.limitKmh else { continue }
                let estimate = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                guard estimate > 0 else { continue }
                let item = Expected(pass: pass, tripID: record.id, estimate: estimate)
                switch pass.fineOutcome {
                case .pending where pass.date >= horizon:
                    ledger.expected.append(item)
                    ledger.expectedSum += estimate
                case .paid:
                    ledger.marked.append(item)
                default:
                    break
                }
            }
        }
        ledger.expected.sort { $0.pass.date > $1.pass.date }
        ledger.marked.sort { $0.pass.date > $1.pass.date }

        for fine in fines {
            let link: LinkState
            switch fine.link?.kind {
            case .pass(_, let passID)?:
                if let found = passes[passID] { link = .pass(found.pass, tripID: found.tripID) } else { link = .passGone }
            case .day(let day)?:
                link = .day(day)
            case .unknown?, nil:
                link = .none
            }
            let status = FineDeadline.status(for: fine, now: now, calendar: calendar)
            ledger.received.append(Received(fine: fine, link: link, status: status,
                                            terms: FineDeadline.terms(for: fine, calendar: calendar)))
            if fine.isPaid {
                ledger.paidTotal += fine.amount ?? 0
            } else if let amount = fine.amount {
                ledger.toPay += amount
                ledger.toPayCount += 1
            } else {
                ledger.unknownAmountCount += 1
            }
        }
        ledger.received.sort(by: order)
        return ledger
    }

    /// Строка «Штрафы» в Итогах: только по самим штрафам, без прохода по
    /// истории — Итоги пересобираются часто, а штрафов единицы.
    struct Dues: Equatable {
        var unpaid = 0
        var toPay: Double = 0
        /// Ближайший срок среди неоплаченных (льготный, пока идёт).
        var nextDeadline: Date?
        var overdue = 0
    }

    static func dues(_ fines: [ReceivedFine], now: Date, calendar: Calendar = .current) -> Dues {
        var dues = Dues()
        for fine in fines where !fine.isPaid {
            dues.unpaid += 1
            dues.toPay += fine.amount ?? 0
            switch FineDeadline.status(for: fine, now: now, calendar: calendar) {
            case .discount(let until), .due(let until):
                dues.nextDeadline = min(dues.nextDeadline ?? until, until)
            case .overdue:
                dues.overdue += 1
            case .paid, .unknown:
                break
            }
        }
        return dues
    }

    /// Неоплаченные — сверху, по ближайшему сроку (просроченные первыми,
    /// без сроков — в конце неоплаченных); оплаченные — по дате оплаты.
    private static func order(_ a: Received, _ b: Received) -> Bool {
        switch (a.fine.paidAt, b.fine.paidAt) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)): return left > right
        case (nil, nil):
            let left = urgency(a.status), right = urgency(b.status)
            if left != right { return left < right }
            return (a.fine.violationAt ?? .distantPast) > (b.fine.violationAt ?? .distantPast)
        }
    }

    private static func urgency(_ status: FineDeadline.Status) -> Date {
        switch status {
        case .overdue(let since): return since.addingTimeInterval(-1e9)
        case .discount(let until), .due(let until): return until
        case .unknown, .paid: return .distantFuture
        }
    }
}
