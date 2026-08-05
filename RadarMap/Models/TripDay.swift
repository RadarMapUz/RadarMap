//
//  TripDay.swift
//  RadarMap
//
//  Дневной агрегат поездок — фундамент честной статистики за месяц и дальше.
//
//  Полные записи поездок жить вечно не могут: трек весит до 400 точек, поэтому
//  TripHistory.pruned вырезает треки старше недели и удаляет записи старше
//  30 дней (потолок — 50 штук). Пока статистика считалась только по записям,
//  «Месяц» был точен ровно до первой чистки, а «Всё время» показывало
//  «последние 50 поездок» под именем «всё время».
//
//  Дневная строка весит десятки байт и хранится НАВСЕГДА. Политика хранения
//  становится осознанной и объяснимой:
//    треки — 7 дней · полные записи — 30 дней / 50 шт · дни и lifetime — вечно.
//
//  Всё здесь — чистые nonisolated-функции (покрыты TripDayTests).
//

import Foundation

/// Итог одного календарного дня. Складывается из завершённых поездок и
/// больше не пересчитывается: запись поездки может быть удалена чисткой,
/// день останется.
nonisolated struct TripDay: Codable, Identifiable, Equatable {
    /// Начало дня в календаре пользователя — ключ и идентификатор.
    let day: Date
    var trips = 0
    var distanceMeters: Double = 0
    var movingDuration: TimeInterval = 0
    /// Проезды камер (не уникальные камеры): одна камера дважды — это два.
    var cameraPasses = 0
    var cleanPasses = 0
    var overPasses = 0
    var fineRisk: Double = 0
    var maxSpeedKmh: Double = 0
    /// Взвешенная по дистанции сумма баллов и её вес — чтобы средний балл за
    /// период считался так же, как weightedRating по записям.
    var scoreSum: Double = 0
    var scoreWeight: Double = 0
    /// Штрафуемые превышения по часам суток (24 корзины) — «когда рискую».
    var overByHour = [Int](repeating: 0, count: 24)

    var id: Date { day }

    var rating: Int? {
        scoreWeight > 0 ? Int((scoreSum / scoreWeight).rounded()) : nil
    }
}

nonisolated enum TripDayBook {

    /// Добавить завершённую поездку в дневные агрегаты. Идемпотентности здесь
    /// нет и быть не может: вызывается ровно один раз — из finish() и из
    /// восстановления слепка, то есть в тот же момент, что и запись в историю.
    static func folded(_ record: TripRecord, into days: [TripDay],
                       calendar: Calendar = .current) -> [TripDay] {
        let key = calendar.startOfDay(for: record.startedAt)
        var result = days
        var day = result.first { $0.day == key } ?? TripDay(day: key)

        day.trips += 1
        day.distanceMeters += record.distanceMeters
        day.movingDuration += record.movingDuration
        day.cameraPasses += record.camerasPassed
        day.maxSpeedKmh = max(day.maxSpeedKmh, record.maxSpeedKmh)
        if let score = record.score {
            // Тот же вес, что в weightedRating: длинная трасса весит больше
            // поездки до магазина, минимум 500 м, чтобы короткая не обнулялась.
            let weight = max(record.distanceMeters, 500)
            day.scoreSum += score * weight
            day.scoreWeight += weight
        }
        for pass in record.passed {
            // Без известного лимита нарушения не выдумываем — как везде.
            guard let limit = pass.limitKmh else { continue }
            let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
            if fine > 0 {
                day.overPasses += 1
                day.fineRisk += fine
                day.overByHour[calendar.component(.hour, from: pass.date)] += 1
            } else {
                day.cleanPasses += 1
            }
        }

        result.removeAll { $0.day == key }
        result.append(day)
        // Новые сверху — как в истории.
        result.sort { $0.day > $1.day }
        return result
    }

    /// Вычесть поездку из агрегатов. Нужно там, где запись уходит из истории
    /// не «в прошлое», а обратно в оборот: `resume` поднимает её в живую сессию
    /// (иначе после склейки она посчиталась бы дважды), удаление записи убирает
    /// её и из цифр — иначе «удалил поездку, а километры остались».
    ///
    /// Максимальная скорость дня не восстанавливается: из суммы её не вычесть.
    /// На практике это безвредно — резюмированная поездка возвращается в тот же
    /// день со своим максимумом, а при удалении завышенный максимум честнее
    /// заниженного (он БЫЛ в этот день).
    static func unfolded(_ record: TripRecord, from days: [TripDay],
                         calendar: Calendar = .current) -> [TripDay] {
        let key = calendar.startOfDay(for: record.startedAt)
        guard var day = days.first(where: { $0.day == key }) else { return days }

        day.trips = max(0, day.trips - 1)
        day.distanceMeters = max(0, day.distanceMeters - record.distanceMeters)
        day.movingDuration = max(0, day.movingDuration - record.movingDuration)
        day.cameraPasses = max(0, day.cameraPasses - record.camerasPassed)
        if let score = record.score {
            let weight = max(record.distanceMeters, 500)
            day.scoreSum = max(0, day.scoreSum - score * weight)
            day.scoreWeight = max(0, day.scoreWeight - weight)
        }
        for pass in record.passed {
            guard let limit = pass.limitKmh else { continue }
            let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
            if fine > 0 {
                day.overPasses = max(0, day.overPasses - 1)
                day.fineRisk = max(0, day.fineRisk - fine)
                let hour = calendar.component(.hour, from: pass.date)
                day.overByHour[hour] = max(0, day.overByHour[hour] - 1)
            } else {
                day.cleanPasses = max(0, day.cleanPasses - 1)
            }
        }

        var result = days
        result.removeAll { $0.day == key }
        // День опустел — строку не держим.
        if day.trips > 0 { result.append(day) }
        result.sort { $0.day > $1.day }
        return result
    }

    /// Пересборка из истории: обновление приложения (агрегатов ещё нет, поездки
    /// уже есть) и починка, если файл дней потерялся. Как LifetimeStats.rebuilt.
    static func rebuilt(from history: [TripRecord],
                        calendar: Calendar = .current) -> [TripDay] {
        var days: [TripDay] = []
        for record in history.reversed() {
            days = folded(record, into: days, calendar: calendar)
        }
        return days
    }

    /// Дни, попадающие в интервал.
    static func days(_ days: [TripDay], in interval: DateInterval) -> [TripDay] {
        days.filter { interval.contains($0.day) }
    }

    /// Сводка за интервал по дневным агрегатам. Числа, которые обязаны пережить
    /// чистку истории, берутся отсюда; всё, что требует самих проездов
    /// (зона риска по названию камеры), досчитывается по записям — см.
    /// TripHistory.summary.
    static func summary(_ days: [TripDay], in interval: DateInterval) -> PeriodSummary {
        var result = PeriodSummary()
        var scoreSum = 0.0
        var scoreWeight = 0.0
        var busiestKm = 0.0
        for day in self.days(days, in: interval) {
            result.trips += day.trips
            result.distance += day.distanceMeters
            result.movingDuration += day.movingDuration
            result.cameras += day.cameraPasses
            result.cleanPasses += day.cleanPasses
            result.overPasses += day.overPasses
            result.fineRisk += day.fineRisk
            result.maxSpeedKmh = max(result.maxSpeedKmh, day.maxSpeedKmh)
            scoreSum += day.scoreSum
            scoreWeight += day.scoreWeight
            for hour in 0..<24 { result.overByHour[hour] += day.overByHour[hour] }
            if day.distanceMeters > busiestKm {
                busiestKm = day.distanceMeters
                result.busiestDay = day.day
            }
            if day.trips > 0 { result.activeDays += 1 }
        }
        result.busiestDayKm = busiestKm / 1000
        if scoreWeight > 0 { result.rating = Int((scoreSum / scoreWeight).rounded()) }
        return result
    }
}
