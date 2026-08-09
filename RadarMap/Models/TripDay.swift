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
    /// Пришедшие штрафы дня. Опционал не от неуверенности, а ради Codable:
    /// синтезированный декодер требует все ключи, а файлы дней уже на дисках.
    var finePaid: Double? = nil
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
                // Деньги — только по достоверному лимиту: сумма в сумах,
                // названная по догадке о классе дороги, — это ложь про деньги.
                // Судьба штрафа делит деньги («ожидается» — риск, «пришёл» —
                // факт, «не пришёл» — никуда); условия обязаны совпадать с
                // unfolded — иначе починка дня «снять старую запись, положить
                // новую» разъедется на суммах.
                if pass.limitIsCertain, pass.countsTowardFines { day.fineRisk += fine }
                if pass.limitIsCertain, pass.finePaid == true {
                    day.finePaid = (day.finePaid ?? 0) + fine
                }
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
                // Зеркально folded: вычитаем ровно то, что туда попало.
                if pass.limitIsCertain, pass.countsTowardFines {
                    day.fineRisk = max(0, day.fineRisk - fine)
                }
                if pass.limitIsCertain, pass.finePaid == true {
                    day.finePaid = max(0, (day.finePaid ?? 0) - fine)
                }
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

    /// Взвешенная сумма баллов окна и её вес — знаменатель самого рейтинга.
    /// Нужен там, где рейтинг пересчитывают «а если бы»: подменить один
    /// слагаемый можно только зная всю сумму (см. RatingBreakdown.ratingIfClean).
    static func weightedScore(_ days: [TripDay], in interval: DateInterval)
        -> (sum: Double, weight: Double) {
        self.days(days, in: interval).reduce((sum: 0.0, weight: 0.0)) {
            ($0.sum + $1.scoreSum, $0.weight + $1.scoreWeight)
        }
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
            result.finesPaid += day.finePaid ?? 0
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

/// Динамика рейтинга по календарным неделям — ответ на «я расту или падаю?»,
/// которого нет внутри одного периода. Считается из дневных агрегатов, поэтому
/// показывает и месяцы, чьи полные записи давно вычищены. Время — параметром,
/// как везде в статистике (воспроизводимо в тестах).
nonisolated enum RatingTrend {
    struct Week: Identifiable, Equatable {
        /// Начало календарной недели.
        let start: Date
        /// nil — на неделе не ездили; такую колонку график показывает пустой,
        /// а не нулём: ноль был бы враньём про худшую езду в жизни.
        let rating: Int?
        let distanceMeters: Double
        var id: Date { start }
    }

    /// Последние `count` календарных недель, старые → новые (порядок оси).
    ///
    /// Границы недель — полуинтервалы [start, end): `DateInterval.contains`
    /// включает конец, и день, равный началу следующей недели, посчитался бы
    /// в обеих. Для сводок периода это редкий пограничный шум, для графика
    /// из 12 колонок — заметное враньё, поэтому здесь фильтр свой.
    static func weekly(days: [TripDay], count: Int,
                       calendar: Calendar = .current, now: Date = Date()) -> [Week] {
        guard count > 0,
              var interval = calendar.dateInterval(of: .weekOfYear, for: now)
        else { return [] }
        var result: [Week] = []
        for _ in 0..<count {
            let window = days.filter { $0.day >= interval.start && $0.day < interval.end }
            let score = window.reduce((sum: 0.0, weight: 0.0)) {
                ($0.sum + $1.scoreSum, $0.weight + $1.scoreWeight)
            }
            result.append(Week(
                start: interval.start,
                rating: score.weight > 0 ? Int((score.sum / score.weight).rounded()) : nil,
                distanceMeters: window.reduce(0) { $0 + $1.distanceMeters }))
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1,
                                               to: interval.start),
                  let previousInterval = calendar.dateInterval(of: .weekOfYear,
                                                               for: previous)
            else { break }
            interval = previousInterval
        }
        return result.reversed()
    }
}

/// Сетка календаря месяца: строки-недели по 7 клеток, nil — дни соседних
/// месяцев (клетка рисуется пустой). Чистая раскладка для карточки «Месяц»
/// в Итогах; выравнивание — по первому дню недели календаря пользователя.
nonisolated enum MonthGrid {
    static func weeks(containing anchor: Date,
                      calendar: Calendar = .current) -> [[Date?]] {
        guard let month = calendar.dateInterval(of: .month, for: anchor) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: month.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var weeks: [[Date?]] = []
        var row: [Date?] = Array(repeating: nil, count: leading)
        var cursor = month.start
        while cursor < month.end {
            row.append(cursor)
            if row.count == 7 {
                weeks.append(row)
                row = []
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        if !row.isEmpty {
            row.append(contentsOf: Array(repeating: nil, count: 7 - row.count))
            weeks.append(row)
        }
        return weeks
    }
}
