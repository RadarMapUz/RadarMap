//
//  TripodFreshness.swift
//  RadarMap
//
//  Свежесть отметки водителей (пункт 82): «Сообщили 5 мин назад»,
//  «Подтвердили 3 мин назад», «Не подтверждали 50 мин». С 30.10.2026 знак
//  перед треногой не обязателен, и главный вопрос водителя — не «сколько
//  голосов», а «когда её последний раз видели».
//
//  Данные — с сервера (/api/mobile: last_confirmed, trust, doubted). Старый
//  сервер их не шлёт (trust == nil) — тогда прежние строки ReportAge.
//
//  Чистая логика, покрыто TripodFreshnessTests.
//

import Foundation

nonisolated enum TripodFreshness {

    /// Что сервер знает о свежести одной отметки.
    struct Info: Equatable, Hashable, Codable, Sendable {
        /// Момент отметки (с поправкой часов); nil — неизвестен.
        var created: Date?
        /// Последнее независимое свежее «Стоит»; nil — не было.
        var lastConfirmed: Date?
        /// 0 — сообщили, 1 — подтвердил другой водитель, 2 — двое за час;
        /// nil — сервер до пункта 82.
        var trust: Int?
        /// Независимых «Уже нет» после последнего «Стоит».
        var doubted = 0
        /// Флаг старого контракта: подтверждал ли кто-то независимый.
        var confirmed: Bool
    }

    enum State: Equatable {
        /// Никто не подтверждал, отметке столько минут.
        case reported(minutes: Int)
        /// Подтвердили столько минут назад.
        case confirmed(minutes: Int)
        /// Без подтверждения столько минут — доверие заметно ниже.
        case unconfirmed(minutes: Int)
    }

    /// Хвост голосовой фразы — только когда он меняет доверие.
    typealias VoiceTail = VoiceEvent.CameraCall.Freshness

    static func state(_ info: Info, now: Date) -> State? {
        guard info.trust != nil else { return nil }
        let stale = AppConfig.tripodStaleMinutes
        if let last = info.lastConfirmed, last.timeIntervalSince1970 > 0 {
            let minutes = max(0, Int(now.timeIntervalSince(last) / 60))
            return minutes >= stale ? .unconfirmed(minutes: minutes) : .confirmed(minutes: minutes)
        }
        guard let minutes = ReportAge.minutes(since: info.created, now: now) else { return nil }
        return minutes >= stale ? .unconfirmed(minutes: minutes) : .reported(minutes: minutes)
    }

    static func text(_ state: State) -> String {
        switch state {
        case .reported(let minutes):
            return minutes < 1 ? String(localized: "Сообщили только что")
                : String(format: String(localized: "Сообщили %lld мин назад"), minutes)
        case .confirmed(let minutes):
            return minutes < 1 ? String(localized: "Подтвердили только что")
                : String(format: String(localized: "Подтвердили %lld мин назад"), minutes)
        case .unconfirmed(let minutes):
            return minutes >= 60 ? String(localized: "Не подтверждали больше часа")
                : String(format: String(localized: "Не подтверждали %lld мин"), minutes)
        }
    }

    /// Строка карточки; без полей свежести — прежняя ReportAge.
    static func card(_ info: Info, now: Date) -> String? {
        guard let state = state(info, now: now) else {
            return ReportAge.card(created: info.created, confirmed: info.confirmed, now: now)
        }
        return text(state)
    }

    /// «Водитель сообщил, что уже нет» — когда после «Стоит» сказали «Уже нет».
    static func doubt(_ info: Info) -> String? {
        guard info.doubted > 0 else { return nil }
        return info.doubted == 1 ? String(localized: "Водитель сообщил, что уже нет")
            : String(localized: "Водители сообщили, что уже нет")
    }

    /// Подзаголовок баннера машины — от длинного к короткому.
    static func banner(_ info: Info, now: Date) -> [String]? {
        guard let state = state(info, now: now) else {
            return ReportAge.banner(created: info.created, confirmed: info.confirmed, now: now)
        }
        let long = text(state)
        let short: String
        switch state {
        case .reported(let minutes), .confirmed(let minutes):
            short = minutes < 1 ? String(localized: "только что")
                : String(format: String(localized: "%lld мин назад"), minutes)
        case .unconfirmed(let minutes):
            short = minutes >= 60 ? String(localized: "больше часа")
                : String(format: String(localized: "%lld мин"), minutes)
        }
        guard let doubt = doubt(info) else { return [long, short] }
        return [long + " · " + doubt, long, short]
    }

    static func voiceTail(_ info: Info?, now: Date) -> VoiceTail {
        guard let info, let state = state(info, now: now) else { return .none }
        switch state {
        case .confirmed(let minutes) where minutes < AppConfig.tripodJustConfirmedMinutes && info.doubted == 0:
            return .justConfirmed
        case .unconfirmed(let minutes):
            return .unconfirmed(minutes: min(60, minutes / 10 * 10))
        default:
            return .none
        }
    }

    /// Метка рисуется приглушённой: никто не подтверждал или сказали «Уже нет».
    static func isFaded(_ info: Info) -> Bool {
        guard let trust = info.trust else { return !info.confirmed }
        return trust == 0 || info.doubted > 0
    }

    /// Подпись у значка на крупном масштабе: «✓ 14:05» — последнее «Стоит»,
    /// «14:05?» — только сообщили. Время, а не «N мин»: подпись живёт в
    /// источнике карты и не устаревает между обновлениями списка.
    static func mapLabel(_ info: Info) -> String {
        if let last = info.lastConfirmed, last.timeIntervalSince1970 > 0 {
            return "✓ " + NumberFormat.clock(last)
        }
        guard let created = info.created, created.timeIntervalSince1970 > 0 else { return "" }
        return NumberFormat.clock(created) + "?"
    }
}
