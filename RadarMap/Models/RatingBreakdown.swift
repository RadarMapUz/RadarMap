//
//  RatingBreakdown.swift
//  RadarMap
//
//  Разложение чисел отчёта: из чего сложился рейтинг периода и из каких камер
//  сложилась сумма возможных штрафов.
//
//  Расшифровки объясняли методику («рейтинг — среднее баллов, взвешенное по
//  дистанции») и не отвечали на вопрос водителя «почему у МЕНЯ 87 и что съело
//  13 баллов». Здесь это считается точно: рейтинг взвешен по дистанции,
//  R = Σ(sᵢ·wᵢ)/Σwᵢ, поэтому вклад каждой поездки в недобор равен
//  wᵢ·(100 − sᵢ)/Σwᵢ, а сумма вкладов ровно равна 100 − R. Разложение можно
//  проверить сложением — и оно проверяется тестом.
//
//  Форматирование (даты, километры, суммы) — в вью: здесь только числа.
//

import Foundation

/// Вклад одной поездки (или целого дня) в недобор рейтинга.
nonisolated struct RatingContribution: Identifiable, Equatable {
    /// id записи поездки либо время начала дня — по нему вью открывает деталку.
    let id: Double
    let date: Date
    let distanceMeters: Double
    let score: Int
    /// Сколько баллов эта строка отняла у рейтинга периода.
    let points: Double
    /// true — строка про конкретную поездку (её можно открыть),
    /// false — про день целиком (записи уже вычищены, остались агрегаты).
    let isTrip: Bool
}

/// Камера, на которой набрался риск штрафа.
nonisolated struct FineSource: Identifiable, Equatable {
    let id: Int
    let location: String
    /// Сколько штрафуемых проездов этой камеры за период.
    let times: Int
    /// Сумма по ступеням, сум.
    let sum: Double
    let lat: Double?
    let lon: Double?
}

nonisolated enum RatingBreakdown {

    /// Вклады в недобор рейтинга за окно, от большего к меньшему.
    ///
    /// Веса берём у дневных агрегатов — рейтинг считается по ним же, поэтому
    /// сумма вкладов сходится с показанной цифрой. Пока записи поездок за окно
    /// целы, строки делаем по поездкам (их можно открыть); после чистки истории
    /// — по дням: экран не пустеет на старых периодах, просто становится грубее.
    static func contributions(records: [TripRecord], days: [TripDay],
                              in interval: DateInterval,
                              calendar: Calendar = .current) -> [RatingContribution] {
        let daysInside = TripDayBook.days(days, in: interval)
        let totalWeight = daysInside.reduce(0) { $0 + $1.scoreWeight }
        guard totalWeight > 0 else { return [] }

        let scored = records.filter { interval.contains($0.startedAt) && $0.score != nil }
        let recordWeight = scored.reduce(0.0) { $0 + weight(of: $1) }
        // Записи покрывают почти весь вес дней — значит история за окно цела.
        let recordsAreComplete = recordWeight >= totalWeight * 0.99

        if recordsAreComplete {
            // Делим на вес ПОКАЗАННЫХ строк, а не дней: блок обязан сходиться
            // сам с собой, даже если источники разошлись (в проде они всегда
            // согласованы — день складывается из тех же записей при финише).
            return scored.map { record in
                let w = weight(of: record)
                let score = record.score ?? 100
                return RatingContribution(
                    id: record.id, date: record.startedAt,
                    distanceMeters: record.distanceMeters, score: Int(score.rounded()),
                    points: w * (100 - score) / recordWeight, isTrip: true)
            }
            .sorted { $0.points > $1.points }
        }

        return daysInside.compactMap { day in
            guard day.scoreWeight > 0, let rating = day.rating else { return nil }
            return RatingContribution(
                id: day.day.timeIntervalSince1970, date: day.day,
                distanceMeters: day.distanceMeters, score: rating,
                points: day.scoreWeight * (100 - Double(rating)) / totalWeight,
                isTrip: false)
        }
        .sorted { $0.points > $1.points }
    }

    /// Тот же вес, что в weightedRating и в дневном агрегате: длинная трасса
    /// весит больше поездки до магазина, минимум 500 м.
    private static func weight(of record: TripRecord) -> Double {
        max(record.distanceMeters, 500)
    }

    /// Поездки окна, которые в рейтинг не вошли: нет ни лимитных камер, ни
    /// трека — балла у них нет. Без этой оговорки «почему рейтинг не изменился»
    /// остаётся загадкой.
    static func unratedTrips(records: [TripRecord], in interval: DateInterval) -> Int {
        records.filter { interval.contains($0.startedAt) && $0.score == nil }.count
    }

    /// Динамика рейтинга по дням окна — данные спарклайна.
    static func dailyRatings(days: [TripDay], in interval: DateInterval) -> [(day: Date, rating: Int)] {
        TripDayBook.days(days, in: interval)
            .compactMap { day in day.rating.map { (day.day, $0) } }
            .sorted { $0.0 < $1.0 }
    }

    /// Камеры, на которых набрался риск, от дорогих к дешёвым. Сумма всех строк
    /// равна `PeriodSummary.fineRisk` за то же окно.
    static func fineSources(records: [TripRecord], in interval: DateInterval) -> [FineSource] {
        var byCamera: [Int: FineSource] = [:]
        for record in records where interval.contains(record.startedAt) {
            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                guard fine > 0 else { continue }
                if let existing = byCamera[pass.cameraID] {
                    byCamera[pass.cameraID] = FineSource(
                        id: existing.id, location: existing.location,
                        times: existing.times + 1, sum: existing.sum + fine,
                        lat: existing.lat ?? pass.lat, lon: existing.lon ?? pass.lon)
                } else {
                    byCamera[pass.cameraID] = FineSource(
                        id: pass.cameraID,
                        location: pass.location.isEmpty ? pass.kind.displayName : pass.location,
                        times: 1, sum: fine, lat: pass.lat, lon: pass.lon)
                }
            }
        }
        return byCamera.values.sorted { $0.sum > $1.sum }
    }
}

extension DrivingScore {
    /// Следующий уровень и сколько до него баллов; nil — уже верхний.
    nonisolated static func nextLevel(for rating: Int) -> (threshold: Int, name: String)? {
        for threshold in [60, 75, 90] where rating < threshold {
            return (threshold, level(for: threshold))
        }
        return nil
    }
}
