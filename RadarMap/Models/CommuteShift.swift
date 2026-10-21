//
//  CommuteShift.swift
//  RadarMap
//
//  «Прибытие сдвинулось: около 8:38, пробка впереди» (этап 24.3). Жалоба
//  владельца: «если встал в пробке — прибытие должно меняться». Строка на
//  панели меняется и так, но за рулём на неё не смотрят: сказанное в начале
//  «на работу к 8:25» остаётся в голове, пока голос его не поправит.
//
//  Правила: одна такая фраза за поездку; только когда прибытие ушло от
//  ПОСЛЕДНЕГО СКАЗАННОГО на `commuteShiftAnnounceMinutes` и больше (в любую
//  сторону — раньше тоже честно, но без «быстрее»); причина — одним словом,
//  только если она видна. Голос — ниже камеры: решает вызывающий, фраза
//  засчитывается только сказанной (как у Announcer).
//
//  Чистая логика — CommuteLiveSessionTests.
//

import Foundation

nonisolated extension CommuteGhost {

    struct ShiftNotice: Equatable, Sendable {
        /// Прибытие, сказанное голосом последним; nil — ещё ничего не сказали.
        private(set) var reference: Date?
        private(set) var spoken = false

        init() {}

        /// Пора сказать: что-то уже было сказано, и прибытие ушло от него
        /// на 5+ мин. Одна фраза за поездку.
        func wants(arrival: Date) -> Bool {
            guard !spoken, let reference else { return false }
            let minutes = abs(arrival.timeIntervalSince(reference)) / 60
            return minutes >= Double(AppConfig.commuteShiftAnnounceMinutes)
        }

        /// Сказана любая фраза призрака: от неё и меряем сдвиг.
        mutating func said(arrival: Date) { reference = arrival }

        mutating func commit(arrival: Date) {
            spoken = true
            reference = arrival
        }
    }

    /// «Прибытие сдвинулось: около 8:38, пробка впереди». Раньше прежнего —
    /// без причины: «быстрее обычного» призрак не говорит.
    static func shiftPhrase(arrival: Date, later: Bool, reason: Reason?,
                            locale: Locale = NumberFormat.locale) -> String {
        let head = String(localized: "Прибытие сдвинулось: около \(clock(arrival, locale: locale))")
        guard later, let reason else { return head }
        switch reason {
        case .jamAhead: return head + ", " + String(localized: "пробка впереди")
        case .jam: return head + ", " + String(localized: "пробка")
        case .stood: return head + ", " + String(localized: "стояли")
        }
    }
}
