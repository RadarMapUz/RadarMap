//
//  CarPlayTripSummary.swift
//  RadarMap
//
//  «Поездка сохранена · 25 мин · 12,4 км · камер: 3 · рейтинг 96» — итог в
//  машине.
//
//  На телефоне итог поездки появляется сразу после стопа (TripEndCard): в
//  этот момент цифры интереснее всего, и это петля привычки с «Итогами». В
//  машине его не было — поездка заканчивалась молча. Здесь — одна строка
//  варианта для алерта CarPlay (от длинной к короткой), без кнопок
//  «подробнее»: подробности — на телефоне, в машине их не читают.
//

import Foundation

enum CarPlayTripSummary {

    /// Варианты строки, от длинной к короткой.
    static func lines(for record: TripRecord) -> [String] {
        let duration = Formatting.duration(max(0, record.endedAt.timeIntervalSince(record.startedAt)))
        let distance = Formatting.distance(record.distanceMeters)
        let cameras = String(format: String(localized: "камер: %lld"), record.passed.count)
        let rating = record.score.map { String(format: String(localized: "рейтинг %lld"), Int($0.rounded())) }
        let head = String(localized: "Поездка сохранена")
        let full = [head, duration, distance, cameras, rating].compactMap { $0 }.joined(separator: " · ")
        let medium = [head, duration, distance].joined(separator: " · ")
        return [full, medium, head]
    }
}
