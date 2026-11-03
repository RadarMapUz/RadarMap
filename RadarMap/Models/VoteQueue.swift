//
//  VoteQueue.swift
//  RadarMap
//
//  Голоса водителя («на месте» / «уже нет»), не ушедшие из-за сети.
//
//  «Нет, радара не было» в мёртвой зоне раньше пропадало молча: голос шёл
//  через `try?`, и ни очереди, ни строки в журнале. А голос после проезда —
//  то, что снимает пустышку с карты раньше срока, и уходит он как раз там,
//  где связи нет.
//
//  Чистая логика, покрыта ReportDeliveryTests.
//

import Foundation

/// Голос, ждущий связи.
nonisolated struct PendingVote: Codable, Equatable {
    /// Серверный id отметки (без смещения карты).
    let reportID: Int
    /// 1 — на месте, −1 — уже нет.
    let value: Int
    /// Происхождение («pass», «misplaced» или пусто) — уходит серверу как есть.
    let kind: String
    let at: Date
    /// Курс голосующего при проезде (0…360): «Убрали» от встречного сервер
    /// срок не режет — через разделительную он мог не увидеть. nil — неизвестен.
    var course: Double? = nil
}

nonisolated enum VoteQueue {

    /// Больше десяти ждущих голосов — не мёртвая зона, а что-то сломалось;
    /// храним свежие.
    static let limit = 10

    /// Голос старше этого не отправляется: отметка на испытательном сроке
    /// живёт 75 минут, и голос часовой давности говорит о другой дороге.
    static let maxAge: TimeInterval = 30 * 60

    /// Поставить в очередь. Второй голос о той же отметке заменяет первый:
    /// передумал — это не второй голос (сервер так же заменяет).
    static func enqueued(_ vote: PendingVote, into queue: [PendingVote]) -> [PendingVote] {
        let rest = queue.filter { $0.reportID != vote.reportID }
        return (rest + [vote]).suffix(limit).map { $0 }
    }

    /// Что отправлять сейчас, а что выбросить как протухшее.
    static func split(_ queue: [PendingVote], now: Date)
        -> (send: [PendingVote], expired: [PendingVote]) {
        let expired = queue.filter { now.timeIntervalSince($0.at) > maxAge }
        return (queue.filter { now.timeIntervalSince($0.at) <= maxAge }, expired)
    }
}
