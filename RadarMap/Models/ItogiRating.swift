//
//  ItogiRating.swift
//  RadarMap
//
//  Как «Итоги» говорят о рейтинге периода (аудит 05.11, вариант A): уровень
//  словом, сдвиг словами, «за что сняли» по двум причинам и правило «мало
//  данных». Движок рейтинга (DrivingScore, RatingBreakdown) не трогается —
//  здесь только то, как его числа назвать водителю.
//
//  Почему отдельно от DrivingScore: уровни там — «Уверенный, но с риском»,
//  «Идеальный стиль» — фразы о стиле, длинные и на SE переносились в две
//  строки рядом с кольцом. Водитель спрашивает «хорошо или плохо», ответ —
//  одно слово того же цвета, что кольцо.
//
//  Чистая логика — ItogiRatingTests.
//

import Foundation

nonisolated enum ItogiRating {

    // MARK: - Уровень

    /// Четыре уровня на тех же порогах, что DrivingScore.level (90 / 75 / 60).
    enum Level: Int, CaseIterable, Sendable {
        case risky, risk, careful, excellent

        init(rating: Int) {
            switch rating {
            case 90...:   self = .excellent
            case 75..<90: self = .careful
            case 60..<75: self = .risk
            default:      self = .risky
            }
        }

        var title: String {
            switch self {
            case .excellent: return String(localized: "Отлично")
            case .careful:   return String(localized: "Аккуратно")
            case .risk:      return String(localized: "Есть риск")
            case .risky:     return String(localized: "Рискованно")
            }
        }

        /// Диапазон уровня — шкала в «Как считаем».
        var range: ClosedRange<Int> {
            switch self {
            case .excellent: return 90...100
            case .careful:   return 75...89
            case .risk:      return 60...74
            case .risky:     return 0...59
            }
        }

        /// Следующий уровень и сколько до него баллов; nil — уже верхний.
        func next(from rating: Int) -> (level: Level, points: Int)? {
            guard let up = Level(rawValue: rawValue + 1) else { return nil }
            return (up, max(0, up.range.lowerBound - rating))
        }
    }

    // MARK: - Сдвиг словами

    /// «на 8 ниже прошлой недели» — меньше шага `insightRatingStep` это
    /// колебание, о нём не говорим (nil).
    static func deltaWords(_ delta: Int?, period: StatsPeriod,
                           step: Int = AppConfig.insightRatingStep) -> String? {
        guard let delta, abs(delta) >= step else { return nil }
        let points = abs(delta)
        switch (period, delta > 0) {
        case (.week, true):   return String(localized: "на \(points) выше прошлой недели")
        case (.week, false):  return String(localized: "на \(points) ниже прошлой недели")
        case (.month, true):  return String(localized: "на \(points) выше прошлого месяца")
        case (.month, false): return String(localized: "на \(points) ниже прошлого месяца")
        case (.day, true):    return String(localized: "на \(points) выше прошлого дня")
        case (.day, false):   return String(localized: "на \(points) ниже прошлого дня")
        }
    }

    // MARK: - Есть ли рейтинг

    /// Показывать ли рейтинг периода.
    enum Availability: Equatable, Sendable {
        case shown(Int)
        /// Поездок или километров мало — кольцо из одной поездки до магазина
        /// читалось бы оценкой недели (как `few` у виджета).
        case tooFew
        /// Рейтинг — у недели и месяца. У дня — баллы поездок (аудит, п. 4):
        /// «рейтинг дня» из одной поездки — тот же балл поездки под другим именем.
        case notForPeriod
        /// Поездок нет или балла нет ни у одной.
        case none
    }

    static func availability(_ summary: PeriodSummary, period: StatsPeriod,
                             minTrips: Int = AppConfig.itogiRatingMinTrips,
                             minMeters: Double = AppConfig.itogiRatingMinMeters) -> Availability {
        guard !summary.isEmpty else { return .none }
        guard period != .day else { return .notForPeriod }
        guard let rating = summary.rating else { return .none }
        guard summary.trips >= minTrips, summary.distance >= minMeters else { return .tooFew }
        return .shown(rating)
    }

    // MARK: - За что сняли

    /// «Сняли 35: камеры −15, резкая езда −20» — недобор рейтинга по двум
    /// причинам, в целых и с суммой ровно `100 − рейтинг` (RatingBreakdown
    /// раскладывает его по камерам и плавности точно, здесь — округление
    /// наибольшими остатками, как в самом разборе).
    struct Taken: Equatable, Sendable {
        let total: Int
        let cameras: Int
        let smoothness: Int
        /// Камер, на которых снято, и самая дорогая из них.
        let cameraCount: Int
        let topCamera: String?
    }

    /// nil — снимать нечего (100) или записи окна уже вычищены и раскладывать
    /// не по чему: выдумывать причины не станем.
    static func taken(rating: Int, sources: RatingSources) -> Taken? {
        let total = max(0, 100 - rating)
        guard total > 0, !sources.isEmpty else { return nil }
        let camerasExact = sources.cameras.reduce(0) { $0 + $1.points }
        let whole = RatingBreakdown.wholePoints([camerasExact, sources.smoothness], total: total)
        return Taken(total: total, cameras: whole[0], smoothness: whole[1],
                     cameraCount: sources.cameras.count, topCamera: sources.cameras.first?.location)
    }

    // MARK: - Как вернуть баллы

    /// Совет со своим «что было бы».
    enum Tip: Equatable, Sendable {
        /// Держать лимит у камеры — рейтинг был бы `rating`.
        case camera(location: String, limitKmh: Int?, rating: Int)
        /// Плавнее разгоняться и тормозить — без резкой езды был бы `rating`.
        case smoothness(rating: Int, beatsCameras: Bool)
    }

    /// До двух советов, сначала тот, что возвращает больше. Камера — самая
    /// дорогая; её «что было бы» — пересчёт окна, будто все её проезды были в
    /// лимите (`ratingIfCameraClean`). Плавность — весь её недобор: он и есть
    /// остаток балла сверх камер.
    static func tips(rating: Int, sources: RatingSources, cameraRating: Int?,
                     maxCount: Int = 2) -> [Tip] {
        var tips: [(gain: Double, tip: Tip)] = []
        if let top = sources.cameras.first, let improved = cameraRating, improved > rating {
            tips.append((Double(improved - rating),
                         .camera(location: top.location, limitKmh: top.limitKmh, rating: improved)))
        }
        let smooth = Int(sources.smoothness.rounded())
        if smooth > 0 {
            let cameras = sources.cameras.reduce(0) { $0 + $1.points }
            tips.append((sources.smoothness,
                         .smoothness(rating: min(100, rating + smooth),
                                     beatsCameras: sources.smoothness > cameras)))
        }
        return tips.sorted { $0.gain > $1.gain }.prefix(maxCount).map(\.tip)
    }

    /// Поездка окна, где резкая езда сняла больше всего: остаток недобора
    /// балла сверх камер (с потолком), как в RatingBreakdown.sources. nil —
    /// резкой езды не было ни в одной.
    static func roughestTrip(records: [TripRecord], in interval: DateInterval) -> TripRecord? {
        var best: (record: TripRecord, points: Double)?
        for record in records where interval.contains(record.startedAt) {
            guard let score = record.score else { continue }
            let deficit = 100 - score
            var cameras = 0.0
            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                cameras += DrivingScore.penaltyPoints(overKmh: pass.speedKmh - Double(limit))
            }
            let smooth = deficit - min(cameras, min(DrivingScore.cameraPenaltyCap, deficit))
            guard smooth >= 0.5, smooth > (best?.points ?? 0) else { continue }
            best = (record, smooth)
        }
        return best?.record
    }

    // MARK: - Как обычно

    /// «Обычно у вас 66–76 — эта неделя ниже обычного». nil — нормы ещё нет.
    static func baselineWords(_ baseline: RatingBaseline?, rating: Int, period: StatsPeriod) -> String? {
        guard let baseline else { return nil }
        let range = "\(baseline.low)–\(baseline.high)"
        let position = baseline.contains(rating) ? 0 : (rating > baseline.high ? 1 : -1)
        switch (period, position) {
        case (.month, 0):  return String(format: String(localized: "Обычно у вас %@ — этот месяц как обычно"), range)
        case (.month, 1):  return String(format: String(localized: "Обычно у вас %@ — этот месяц выше обычного"), range)
        case (.month, _):  return String(format: String(localized: "Обычно у вас %@ — этот месяц ниже обычного"), range)
        case (_, 0):       return String(format: String(localized: "Обычно у вас %@ — эта неделя как обычно"), range)
        case (_, 1):       return String(format: String(localized: "Обычно у вас %@ — эта неделя выше обычного"), range)
        default:           return String(format: String(localized: "Обычно у вас %@ — эта неделя ниже обычного"), range)
        }
    }

    /// Рейтинг окна, будто все проезды камеры `cameraID` были не выше лимита.
    /// Как RatingBreakdown.ratingIfClean, только для всех проездов камеры
    /// сразу: прибавка — к СОХРАНЁННОМУ баллу поездки (трек живёт неделю) и с
    /// учётом потолка за камеры. nil — прибавки нет или окно пустое.
    static func ratingIfCameraClean(cameraID: Int, records: [TripRecord], days: [TripDay],
                                    in interval: DateInterval) -> Int? {
        let totals = TripDayBook.weightedScore(days, in: interval)
        guard totals.weight > 0 else { return nil }
        var sum = totals.sum
        var changed = false
        for record in records where interval.contains(record.startedAt) {
            guard let score = record.score else { continue }
            var before = 0.0
            var after = 0.0
            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                let points = DrivingScore.penaltyPoints(overKmh: pass.speedKmh - Double(limit))
                before += points
                after += pass.cameraID == cameraID ? 0 : points
            }
            let gain = min(before, DrivingScore.cameraPenaltyCap) - min(after, DrivingScore.cameraPenaltyCap)
            guard gain > 0 else { continue }
            let weight = max(record.distanceMeters, 500)
            sum += (min(100, score + gain) - score) * weight
            changed = true
        }
        guard changed else { return nil }
        return Int((sum / totals.weight).rounded())
    }
}

// MARK: - Окно «Итогов»

/// Какое окно показать при открытии и как об этом сказать.
nonisolated enum ItogiWindow {

    /// Ближайший к окну `anchor` день с поездками вне этого окна — по дневным
    /// агрегатам (они переживают чистку истории). Начало дня; nil — поездок
    /// нигде больше нет.
    static func nearestAnchor(days: [TripDay], period: StatsPeriod, anchor: Date,
                              calendar: Calendar = .current) -> Date? {
        let current = period.interval(containing: anchor, calendar: calendar)
        return days
            .filter { $0.trips > 0 && ($0.day < current.start || $0.day >= current.end) }
            .min { abs($0.day.timeIntervalSince(current.start)) < abs($1.day.timeIntervalSince(current.start)) }
            .map { calendar.startOfDay(for: $0.day) }
    }

    /// Куда открыть «Итоги»: идущее окно пусто (понедельник утром) — в
    /// ближайшее с поездками. nil — открыть идущее.
    static func openingAnchor(days: [TripDay], period: StatsPeriod, now: Date,
                              calendar: Calendar = .current) -> Date? {
        let current = period.interval(containing: now, calendar: calendar)
        guard TripDayBook.days(days, in: current).allSatisfy({ $0.trips == 0 }) else { return nil }
        return nearestAnchor(days: days, period: period, anchor: now, calendar: calendar)
    }

    /// Строка над карточкой, когда показано не идущее окно, потому что в нём
    /// пусто: «На этой неделе поездок ещё нет — показана прошлая». Молча
    /// подменённая неделя читалась как «эта» — с чужими километрами.
    static func notice(period: StatsPeriod, shown: Date, now: Date,
                       calendar: Calendar = .current) -> String? {
        let current = period.interval(containing: now, calendar: calendar)
        let window = period.interval(containing: shown, calendar: calendar)
        guard window.start < current.start else { return nil }
        let previous = period.previousInterval(containing: now, calendar: calendar)
        let isPrevious = previous?.start == window.start
        switch period {
        case .week:
            return isPrevious
                ? String(localized: "На этой неделе поездок ещё нет — показана прошлая")
                : String(localized: "На этой неделе поездок ещё нет — показана последняя с поездками")
        case .month:
            return isPrevious
                ? String(localized: "В этом месяце поездок ещё нет — показан прошлый")
                : String(localized: "В этом месяце поездок ещё нет — показан последний с поездками")
        case .day:
            return isPrevious
                ? String(localized: "Сегодня поездок ещё нет — показан вчерашний день")
                : String(localized: "Сегодня поездок ещё нет — показан последний день с поездками")
        }
    }
}
