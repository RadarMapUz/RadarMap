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
//  Второй уровень — `sources`: тот же недобор, но разложенный по КАМЕРАМ
//  периода. Двенадцать строк «поездка такая-то» не говорят, что делать;
//  «Юнусабад, 4 проезда, −18» говорит.
//
//  Третий — `ratingIfClean`: каким был бы рейтинг, проедь водитель конкретную
//  камеру в лимите. Считается по той же лестнице баллов, а не «на глазок».
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
    /// Доля веса строки в периоде, 0…1. Вторая половина объяснения «откуда
    /// −12,6»: недобор 45 × доля 28 %. Без неё число выглядит взятым с потолка.
    let weightShare: Double
    /// true — строка про конкретную поездку (её можно открыть),
    /// false — про день целиком (записи уже вычищены, остались агрегаты).
    let isTrip: Bool
    /// Был ли хоть один штрафуемый проезд — по этому фильтруется полный список.
    let hasViolation: Bool

    /// Сколько баллов эта поездка не добрала до сотни.
    var deficit: Int { max(0, 100 - score) }
}

/// Точка спарклайна «рейтинг по дням».
nonisolated struct RatingDayPoint: Identifiable, Equatable {
    let day: Date
    let rating: Int

    var id: Date { day }
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

/// Камера, которая съела баллы рейтинга ЗА ПЕРИОД.
nonisolated struct RatingHotspot: Identifiable, Equatable {
    /// cameraID — по нему строка открывает камеру на карте проездов.
    let id: Int
    let location: String
    /// Проездов этой камеры, снявших баллы.
    let times: Int
    /// Сколько баллов рейтинга периода съела эта камера.
    let points: Double
    /// Худший проезд — его и стоит показать в примере.
    let worstSpeedKmh: Double
    /// Когда он был. Улица с несколькими камерами даёт одинаковые названия —
    /// без даты две строки «Юнусабад» неотличимы друг от друга.
    let worstDate: Date
    let limitKmh: Int?
    let lat: Double?
    let lon: Double?
}

/// Куда ушли баллы периода: камеры плюс рваная езда.
/// `cameras.points` + `smoothness` = сумма вкладов поездок = 100 − рейтинг.
nonisolated struct RatingSources: Equatable {
    var cameras: [RatingHotspot] = []
    /// Сколько баллов периода съели резкие разгоны и торможения — всеми
    /// поездками вместе.
    var smoothness: Double = 0

    var isEmpty: Bool { cameras.isEmpty && smoothness < 0.05 }
    var total: Double { cameras.reduce(smoothness) { $0 + $1.points } }
}

/// «Ваша норма»: каким рейтинг бывает у этого водителя обычно.
/// Один и тот же балл 73 для одного рекорд, для другого — провал; без нормы
/// цифра ничего не говорит.
nonisolated struct RatingBaseline: Equatable {
    /// Медиана рейтингов предыдущих таких же окон.
    let median: Int
    /// Обычный диапазон — между четвертью худших и четвертью лучших окон.
    let low: Int
    let high: Int
    /// По скольким окнам посчитано (для честной подписи).
    let periods: Int

    /// Насколько текущий рейтинг выше/ниже нормы.
    func delta(from rating: Int) -> Int { rating - median }
    /// Внутри обычного диапазона — значит «как обычно», без вердикта.
    func contains(_ rating: Int) -> Bool { rating >= low && rating <= high }
}

/// Всё, что показывает экран рейтинга периода.
nonisolated struct RatingScreen: Equatable {
    var contributions: [RatingContribution] = []
    var sources = RatingSources()
    var daily: [RatingDayPoint] = []
    var baseline: RatingBaseline?
    /// Динамика по неделям — всегда последние недели ОТ СЕГОДНЯ, а не от
    /// листаемого периода: график отвечает «я расту или падаю», и он не должен
    /// уезжать в прошлое вместе со стрелкой «назад».
    var trend: [RatingTrend.Week] = []
    /// Поездок окна, не вошедших в рейтинг (нет ни лимитных камер, ни трека).
    var unrated = 0

    /// Сколько вкладов не поместилось в превью — столько показывает кнопка.
    var isEmpty: Bool { contributions.isEmpty }
}

nonisolated enum RatingBreakdown {

    // MARK: - Окно периода

    /// Общая база разложений: сколько веса в периоде дают дневные агрегаты
    /// (по ним считается сам рейтинг) и сколько — уцелевшие записи поездок.
    private struct Window {
        let scored: [TripRecord]
        /// Вес показанных записей.
        let recordWeight: Double
        /// Вес всех дней окна — знаменатель самого рейтинга.
        let totalWeight: Double

        /// Записи покрывают почти весь вес дней — значит история за окно цела
        /// и разложение можно делать по поездкам, а не по дням.
        var recordsAreComplete: Bool { recordWeight >= totalWeight * 0.99 }
    }

    private static func window(records: [TripRecord], days: [TripDay],
                               in interval: DateInterval) -> Window? {
        let totalWeight = TripDayBook.days(days, in: interval)
            .reduce(0) { $0 + $1.scoreWeight }
        guard totalWeight > 0 else { return nil }
        let scored = records.filter { interval.contains($0.startedAt) && $0.score != nil }
        return Window(scored: scored,
                      recordWeight: scored.reduce(0.0) { $0 + weight(of: $1) },
                      totalWeight: totalWeight)
    }

    /// Тот же вес, что в weightedRating и в дневном агрегате: длинная трасса
    /// весит больше поездки до магазина, минимум 500 м.
    private static func weight(of record: TripRecord) -> Double {
        max(record.distanceMeters, 500)
    }

    // MARK: - Вклады поездок

    /// Вклады в недобор рейтинга за окно, от большего к меньшему.
    ///
    /// Веса берём у дневных агрегатов — рейтинг считается по ним же, поэтому
    /// сумма вкладов сходится с показанной цифрой. Пока записи поездок за окно
    /// целы, строки делаем по поездкам (их можно открыть); после чистки истории
    /// — по дням: экран не пустеет на старых периодах, просто становится грубее.
    static func contributions(records: [TripRecord], days: [TripDay],
                              in interval: DateInterval,
                              calendar: Calendar = .current) -> [RatingContribution] {
        guard let window = window(records: records, days: days, in: interval) else { return [] }

        if window.recordsAreComplete {
            // Делим на вес ПОКАЗАННЫХ строк, а не дней: блок обязан сходиться
            // сам с собой, даже если источники разошлись (в проде они всегда
            // согласованы — день складывается из тех же записей при финише).
            return window.scored.map { record in
                let share = weight(of: record) / window.recordWeight
                let score = record.score ?? 100
                return RatingContribution(
                    id: record.id, date: record.startedAt,
                    distanceMeters: record.distanceMeters, score: Int(score.rounded()),
                    points: share * (100 - score), weightShare: share, isTrip: true,
                    hasViolation: !record.isClean)
            }
            .sorted { $0.points > $1.points }
        }

        return TripDayBook.days(days, in: interval).compactMap { day in
            guard day.scoreWeight > 0, let rating = day.rating else { return nil }
            let share = day.scoreWeight / window.totalWeight
            return RatingContribution(
                id: day.day.timeIntervalSince1970, date: day.day,
                distanceMeters: day.distanceMeters, score: rating,
                points: share * Double(100 - rating), weightShare: share, isTrip: false,
                hasViolation: day.overPasses > 0)
        }
        .sorted { $0.points > $1.points }
    }

    /// Поездки окна, которые в рейтинг не вошли: нет ни лимитных камер, ни
    /// трека — балла у них нет. Без этой оговорки «почему рейтинг не изменился»
    /// остаётся загадкой.
    static func unratedTrips(records: [TripRecord], in interval: DateInterval) -> Int {
        records.filter { interval.contains($0.startedAt) && $0.score == nil }.count
    }

    /// Динамика рейтинга по дням окна — данные спарклайна.
    static func dailyRatings(days: [TripDay], in interval: DateInterval) -> [RatingDayPoint] {
        TripDayBook.days(days, in: interval)
            .compactMap { day in day.rating.map { RatingDayPoint(day: day.day, rating: $0) } }
            .sorted { $0.day < $1.day }
    }

    // MARK: - Куда ушли баллы: камеры и плавность

    /// Тот же недобор, разложенный по камерам периода.
    ///
    /// Внутри поездки её вклад делится ровно так же, как делится сам балл:
    /// доля камеры = её ступень / общий недобор поездки. Потолок за камеры
    /// (70 баллов) срезает все камеры пропорционально, остаток недобора —
    /// плавность. Поэтому сумма всех строк равна сумме вкладов поездок.
    ///
    /// Опорой служит СОХРАНЁННЫЙ балл поездки, а не пересчитанный: трек живёт
    /// неделю, и после чистки пересчёт потерял бы штраф за рваную езду и
    /// приписал бы его камерам.
    ///
    /// Пусто, когда записи за окно уже вычищены: названий камер в дневной
    /// строке нет, и выдумывать их мы не станем.
    static func sources(records: [TripRecord], days: [TripDay],
                        in interval: DateInterval) -> RatingSources {
        guard let window = window(records: records, days: days, in: interval),
              window.recordsAreComplete else { return RatingSources() }

        var byCamera: [Int: RatingHotspot] = [:]
        var smoothness = 0.0

        for record in window.scored {
            guard let score = record.score else { continue }
            let deficit = 100 - score
            guard deficit > 0.005 else { continue }
            let contribution = weight(of: record) / window.recordWeight * deficit

            var cameraPenalty = 0.0
            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                cameraPenalty += DrivingScore.penaltyPoints(overKmh: pass.speedKmh - Double(limit))
            }
            // Сколько недобора приходится на камеры: не больше потолка и не
            // больше самого недобора (страховка от записей старых версий).
            let cameraShare = min(cameraPenalty, min(DrivingScore.cameraPenaltyCap, deficit))
            let scale = cameraPenalty > 0 ? cameraShare / cameraPenalty : 0
            smoothness += contribution * (deficit - cameraShare) / deficit

            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                let points = DrivingScore.penaltyPoints(overKmh: pass.speedKmh - Double(limit)) * scale
                guard points > 0 else { continue }
                let taken = contribution * points / deficit
                if let existing = byCamera[pass.cameraID] {
                    let worse = pass.speedKmh > existing.worstSpeedKmh
                    byCamera[pass.cameraID] = RatingHotspot(
                        id: existing.id, location: existing.location,
                        times: existing.times + 1, points: existing.points + taken,
                        worstSpeedKmh: worse ? pass.speedKmh : existing.worstSpeedKmh,
                        worstDate: worse ? pass.date : existing.worstDate,
                        limitKmh: existing.limitKmh ?? pass.limitKmh,
                        lat: existing.lat ?? pass.lat, lon: existing.lon ?? pass.lon)
                } else {
                    byCamera[pass.cameraID] = RatingHotspot(
                        id: pass.cameraID,
                        location: pass.location.isEmpty ? pass.kind.displayName : pass.location,
                        times: 1, points: taken, worstSpeedKmh: pass.speedKmh,
                        worstDate: pass.date, limitKmh: pass.limitKmh,
                        lat: pass.lat, lon: pass.lon)
                }
            }
        }

        return RatingSources(cameras: byCamera.values.sorted { $0.points > $1.points },
                             smoothness: smoothness)
    }

    // MARK: - «А если бы в лимите»

    /// Сколько баллов вернул бы этот проезд, пройди он ровно по лимиту.
    /// Считаем по лестнице баллов и с учётом потолка за камеры: если поездка
    /// и так упёрлась в потолок, один исправленный проезд ничего не вернёт.
    /// nil — лимит неизвестен, проезд и так чистый или у поездки нет балла.
    private static func relief(pass: PassedCamera, record: TripRecord) -> Double? {
        guard pass.limitKmh != nil, record.score != nil else { return nil }
        var before = 0.0
        var after = 0.0
        for item in record.passed {
            guard let limit = item.limitKmh else { continue }
            let points = DrivingScore.penaltyPoints(overKmh: item.speedKmh - Double(limit))
            before += points
            // Тот самый проезд — как будто прошёл ровно по лимиту.
            after += item.id == pass.id ? 0 : points
        }
        let gain = min(before, DrivingScore.cameraPenaltyCap)
            - min(after, DrivingScore.cameraPenaltyCap)
        return gain > 0 ? gain : nil
    }

    /// Каким был бы балл ПОЕЗДКИ, пройди этот проезд в лимите.
    ///
    /// Разницу прибавляем к СОХРАНЁННОМУ баллу, а не пересчитываем всё заново:
    /// трек живёт неделю, и после чистки полный пересчёт потерял бы штраф за
    /// рваную езду и завысил бы результат.
    static func tripScoreIfClean(pass: PassedCamera, record: TripRecord) -> Int? {
        guard let score = record.score, let gain = relief(pass: pass, record: record) else {
            return nil
        }
        return Int(min(100, score + gain).rounded())
    }

    /// Каким стал бы рейтинг периода, проедь водитель эту камеру в лимите.
    /// nil — считать нечего или окно пустое.
    static func ratingIfClean(pass: PassedCamera, record: TripRecord,
                              days: [TripDay], in interval: DateInterval) -> Int? {
        guard let score = record.score, let gain = relief(pass: pass, record: record) else {
            return nil
        }
        let totals = TripDayBook.weightedScore(days, in: interval)
        guard totals.weight > 0 else { return nil }
        let w = weight(of: record)
        let newSum = totals.sum - score * w + min(100, score + gain) * w
        return Int((newSum / totals.weight).rounded())
    }

    // MARK: - Ваша норма

    /// Медиана и обычный диапазон рейтинга по предыдущим таким же окнам.
    /// Текущее окно не участвует — иначе норма подстраивается под то, что
    /// мы ею же и объясняем. nil — истории пока мало.
    static func baseline(days: [TripDay], period: StatsPeriod, anchor: Date,
                         count: Int = AppConfig.ratingBaselinePeriods,
                         calendar: Calendar = .current) -> RatingBaseline? {
        var ratings: [Int] = []
        for step in 1...max(1, count) {
            let interval = period.interval(containing: period.shifted(anchor, by: -step,
                                                                      calendar: calendar),
                                           calendar: calendar)
            if let rating = TripDayBook.summary(days, in: interval).rating {
                ratings.append(rating)
            }
        }
        guard ratings.count >= AppConfig.ratingBaselineMinPeriods else { return nil }

        let sorted = ratings.sorted()
        let last = Double(sorted.count - 1)
        return RatingBaseline(median: sorted[sorted.count / 2],
                              low: sorted[Int((last * 0.25).rounded())],
                              high: sorted[Int((last * 0.75).rounded())],
                              periods: sorted.count)
    }

    // MARK: - Всё разложение одним расчётом

    /// Готовые данные экрана рейтинга. Собираются одним заходом вне main:
    /// на месяце это полсотни записей со всеми проездами, и считать это в
    /// `body` значило бы пересчитывать всё на каждый кадр прокрутки.
    @concurrent static func screen(records: [TripRecord], days: [TripDay],
                                   period: StatsPeriod, anchor: Date,
                                   calendar: Calendar = .current) async -> RatingScreen {
        let token = Perf.begin(Perf.Name.ratingScreen)
        defer { token.end() }
        let interval = period.interval(containing: anchor, calendar: calendar)
        return RatingScreen(
            contributions: contributions(records: records, days: days, in: interval,
                                         calendar: calendar),
            sources: sources(records: records, days: days, in: interval),
            daily: dailyRatings(days: days, in: interval),
            baseline: baseline(days: days, period: period, anchor: anchor, calendar: calendar),
            trend: RatingTrend.weekly(days: days, count: AppConfig.ratingTrendWeeks,
                                      calendar: calendar),
            unrated: unratedTrips(records: records, in: interval))
    }

    // MARK: - Штрафы

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
