//
//  DrivingScore.swift
//  RadarMap
//
//  Ядро удержания: рейтинг вождения 0–100, «сэкономлено на штрафах»,
//  пожизненные счётчики и достижения. Все расчёты — чистые nonisolated-функции
//  (покрыты тестами), состояние хранит TripStats.
//

import Foundation

// MARK: - Штрафная арифметика (ст. 128-3 КоАО РУз)

/// Ступени штрафов за превышение скорости. Первая фиксация (повторность нам неизвестна),
/// поэтому все суммы в UI подписываются как «оценка».
nonisolated enum FineSchedule {
    /// БРВ (базовая расчётная величина) с 01.07.2026. Меняется раз в год — обновлять здесь.
    static let brv: Double = 440_000
    /// Камеры на практике не штрафуют за первые ~5 км/ч сверх лимита.
    static let toleranceKmh: Double = 5

    /// Штраф первой фиксации для данного превышения (сум); 0 — в допуске.
    /// до +20 → 1 БРВ, +20…40 → 5 БРВ, свыше 40 → 9 БРВ.
    nonisolated static func fine(overKmh: Double) -> Double {
        if overKmh <= toleranceKmh { return 0 }
        if overKmh <= 20 { return brv }
        if overKmh <= 40 { return 5 * brv }
        return 9 * brv
    }

    /// Минимальный штраф — столько «экономит» каждый чистый проезд камеры с лимитом.
    nonisolated static var minimumFine: Double { brv }
}

// MARK: - Рейтинг поездки

enum DrivingScore {
    /// Проезд камеры для расчёта: скорость и лимит дороги (если известен).
    nonisolated struct Pass: Codable, Sendable {
        let speedKmh: Double
        let limitKmh: Int?
    }

    // MARK: Лестница снятия баллов
    //
    // Одно место на всё приложение. Раньше ступени были выписаны дважды —
    // в tripScore и в breakdown, — и разложение балла могло разойтись с самим
    // баллом от одной опечатки. Разбор рейтинга периода (RatingBreakdown)
    // считает по ним же.

    /// Больше этого за камеры не снимаем: одна ужасная поездка не должна
    /// обнулять балл целиком.
    nonisolated static let cameraPenaltyCap: Double = 70
    /// Потолок штрафа за рваную езду.
    nonisolated static let smoothPenaltyCap: Double = 20
    /// Спокойная езда — 2–4 км/ч перепада на шаг трека; дёрганая — 8+.
    nonisolated static let smoothBaselineKmh: Double = 3.5
    nonisolated static let smoothFactor: Double = 5
    /// Меньше этого числа точек трека — судить о плавности не по чему.
    nonisolated static let smoothMinPoints = 10

    /// Сколько баллов снимает один проезд камеры при таком превышении.
    nonisolated static func penaltyPoints(overKmh: Double) -> Double {
        switch overKmh {
        case ..<2:    return 0    // идеально
        case 2..<5:   return 2    // на грани
        case 5..<12:  return 8    // штрафная ступень близко
        case 12..<20: return 14
        case 20..<40: return 25   // 5 БРВ
        default:      return 40   // 9 БРВ
        }
    }

    /// Средняя перемена скорости между соседними точками трека, км/ч. Это и
    /// есть измеряемая «рваность» — то самое число, которое показывается
    /// пользователю в разборе балла.
    nonisolated static func meanSpeedChange(trackSpeeds: [Double]) -> Double {
        guard trackSpeeds.count >= 2 else { return 0 }
        var delta = 0.0
        for index in 1..<trackSpeeds.count {
            delta += abs(trackSpeeds[index] - trackSpeeds[index - 1])
        }
        return delta / Double(trackSpeeds.count - 1)
    }

    /// Штраф за рваную езду по треку. nil — трека мало, судить не по чему.
    nonisolated static func smoothPenalty(trackSpeeds: [Double]) -> Double? {
        guard trackSpeeds.count >= smoothMinPoints else { return nil }
        let mean = meanSpeedChange(trackSpeeds: trackSpeeds)
        return min(max((mean - smoothBaselineKmh) * smoothFactor, 0), smoothPenaltyCap)
    }

    /// Балл поездки 0–100. nil — данных мало (ни лимитных проездов, ни трека).
    /// Камеры — главный компонент (штрафные ступени), плавность по треку — второй.
    nonisolated static func tripScore(passes: [Pass], trackSpeeds: [Double]) -> Double? {
        var cameras = 0.0
        var limitedPasses = 0
        for pass in passes {
            guard let limit = pass.limitKmh else { continue }
            limitedPasses += 1
            cameras += penaltyPoints(overKmh: pass.speedKmh - Double(limit))
        }
        cameras = min(cameras, cameraPenaltyCap)

        let smooth = smoothPenalty(trackSpeeds: trackSpeeds)
        guard limitedPasses > 0 || smooth != nil else { return nil }
        return max(0, 100 - cameras - (smooth ?? 0))
    }

    /// Одна строка разложения балла: за что и сколько снято.
    struct Penalty: Identifiable, Equatable {
        let id: String
        let icon: String
        let title: String
        let detail: String?
        let points: Int      // снято баллов (положительное число)
        /// Проезд, из-за которого снято: по нему открывается карта проезда.
        /// nil — строка не про камеру (потолок, плавность).
        var passID: UUID? = nil
    }

    /// Из чего сложился балл поездки — та же арифметика, что в tripScore,
    /// но по строкам: «почему 68?» — самый частый вопрос к деталке.
    /// Пустой список — балл не считался (нет ни лимитных проездов, ни трека).
    /// `score` — балл, сохранённый в записи. Если он есть, штраф за плавность
    /// берётся как остаток от него: балл считался в конце поездки по СЫРОМУ
    /// треку, а в записи лежит упрощённый (до 400 точек), где скачки между
    /// точками крупнее. По нему штраф выходил до двух раз больше — деталка
    /// показывала «90» и единственную строку «−20». Плавность — единственная
    /// часть балла сверх камер, поэтому остаток равен ей точно, и строки
    /// разбора складываются в показанный балл.
    nonisolated static func breakdown(passed: [PassedCamera],
                                      trackSpeeds: [Double],
                                      score: Double? = nil) -> [Penalty] {
        var items: [Penalty] = []
        var cameraPenalty = 0.0
        var limitedPasses = 0
        for pass in passed {
            guard let limit = pass.limitKmh else { continue }
            limitedPasses += 1
            let points = penaltyPoints(overKmh: pass.speedKmh - Double(limit))
            cameraPenalty += points
            guard points > 0 else { continue }
            let place = pass.location.isEmpty ? pass.kind.displayName : pass.location
            items.append(Penalty(
                id: pass.id.uuidString, icon: pass.kind.symbolName, title: place,
                // Округление, а не усечение: та же скорость печатается на
                // экране проезда, и расхождение в километр читается как ошибка.
                detail: String(format: String(localized: "%1$lld км/ч при лимите %2$lld"),
                               Int(pass.speedKmh.rounded()), limit),
                points: Int(points), passID: pass.id))
        }
        // Штраф за камеры ограничен потолком: одна ужасная поездка не должна
        // обнулять балл (см. tripScore). Показываем это честной строкой.
        if cameraPenalty > cameraPenaltyCap {
            items.append(Penalty(
                id: "cap", icon: "arrow.down.to.line",
                title: String(localized: "Потолок штрафа за камеры"),
                detail: String(format: String(localized: "больше %lld баллов за камеры не снимаем"),
                               Int(cameraPenaltyCap)),
                points: -Int(cameraPenalty - cameraPenaltyCap)))
        }

        let smooth: Double?
        let meanChange: Double
        if let score, score > 0 {
            // Показанный балл — целая часть (так он печатается везде), и
            // остаток считаем от неё же: иначе 89,6 → «89» и «−10» снова
            // не сошлись бы на единицу.
            let cameras = min(cameraPenalty, cameraPenaltyCap)
            let rest = max(0, 100 - cameras - Double(Int(score)))
            smooth = rest
            // Средний перепад восстанавливается из того же штрафа: штраф —
            // это (перепад − порог) × множитель, пока не упёрся в потолок.
            meanChange = smoothBaselineKmh + min(rest, smoothPenaltyCap) / smoothFactor
        } else {
            smooth = smoothPenalty(trackSpeeds: trackSpeeds)
            meanChange = meanSpeedChange(trackSpeeds: trackSpeeds)
        }

        if let smooth {
            let points = Int(smooth.rounded())
            if points > 0 {
                // «по треку поездки» не объясняло НИЧЕГО: человек видел −20 и
                // не мог ни проверить, ни исправить. Показываем измеренное
                // число и порог, с которого начинается штраф, — тогда строка
                // становится проверяемой, как и все остальные.
                let capped = smooth >= smoothPenaltyCap - 0.5
                let format = capped
                    ? String(localized: "скорость менялась в среднем больше чем на %1$lld км/ч между точками трека, спокойная езда — до %2$lld")
                    : String(localized: "скорость менялась в среднем на %1$lld км/ч между точками трека, спокойная езда — до %2$lld")
                items.append(Penalty(
                    id: "smooth", icon: "waveform.path.ecg",
                    title: String(localized: "Резкие разгоны и торможения"),
                    detail: String(format: format, Int(meanChange.rounded()),
                                   Int(smoothBaselineKmh)),
                    points: points))
            }
        } else if limitedPasses == 0 {
            return []   // балла нет — раскладывать нечего
        }
        return items
    }

    /// Уровень по баллу — для шапки Итогов.
    nonisolated static func level(for rating: Int) -> String {
        switch rating {
        case 90...: return String(localized: "Идеальный стиль")
        case 75..<90: return String(localized: "Аккуратный водитель")
        case 60..<75: return String(localized: "Уверенный, но с риском")
        default: return String(localized: "Рискованный стиль")
        }
    }

    /// Цветовая зона рейтинга (используется для кольца и цифры).
    nonisolated static func tier(for rating: Int) -> Int {
        rating >= 75 ? 2 : rating >= 60 ? 1 : 0   // 2 зелёный, 1 жёлтый, 0 красный
    }
}

// MARK: - Пожизненные счётчики

/// Аккумулируются при каждом finish() и живут отдельно от истории
/// (история обрезается до 50 поездок, эти цифры — навсегда).
nonisolated struct LifetimeStats: Codable, Equatable {
    var trips = 0
    var distanceMeters = 0.0
    var camerasPassed = 0
    var camerasInLimit = 0        // проезды лимитных камер без штрафной ступени
    var savedFinesSum = 0.0       // сум: чистые проезды × минимальный штраф
    var riskFinesSum = 0.0        // сум: сумма «возможных штрафов» за превышения
    var cleanStreak = 0           // подряд чистых поездок (текущая серия)
    var bestStreak = 0
    /// Последняя поездка подняла рекорд серии. Нужно склейке: штраф второй
    /// ноги отменяет шаг первой, и рекорд — только если его поднял этот шаг
    /// («равен серии» не доказывает: рекорд мог быть таким и раньше). Старые
    /// файлы и копии без поля — nil: рекорд тогда не трогаем.
    var lastTripRaisedBest: Bool?

    /// Ни одной поездки за всё время — пожизненный блок Итогов скрыт целиком.
    var isEmpty: Bool { trips == 0 }

    /// Обновление после поездки — чистая функция, покрыта тестами.
    /// Чистая поездка = есть лимитные проезды и ни один не попал на штраф.
    /// Поездка без лимитных камер серию не трогает (нет данных — нет вердикта).
    nonisolated static func updated(_ stats: LifetimeStats,
                                    passes: [DrivingScore.Pass],
                                    distanceMeters: Double) -> LifetimeStats {
        var s = stats
        s.trips += 1
        s.distanceMeters += distanceMeters
        s.camerasPassed += passes.count

        var limited = 0
        var fined = 0
        for pass in passes {
            guard let limit = pass.limitKmh else { continue }
            limited += 1
            let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
            if fine > 0 {
                fined += 1
                s.riskFinesSum += fine
            } else {
                s.camerasInLimit += 1
                s.savedFinesSum += FineSchedule.minimumFine
            }
        }

        if limited > 0 {
            s.cleanStreak = fined == 0 ? s.cleanStreak + 1 : 0
            s.bestStreak = max(s.bestStreak, s.cleanStreak)
        }
        s.lastTripRaisedBest = s.bestStreak > stats.bestStreak
        return s
    }

    /// Финиш ПРОДОЛЖЕННОЙ поездки (склейка, TripMerge): первая нога уже
    /// внесена своим финишем — добавляем только то, что прибавилось, иначе
    /// «за всё время» считало её дважды: 10 км до магазина + 3 после давали
    /// 23 км и две поездки (сценарий S11, 20.10). Поездка та же — `trips` не
    /// растёт; серия: новый штраф её обрывает, а чистые лимитные проезды
    /// продлевают, только если у первой ноги лимитных не было (иначе шаг
    /// серии уже сделан).
    nonisolated static func updatedResumed(_ stats: LifetimeStats,
                                           basePasses: [DrivingScore.Pass],
                                           allPasses: [DrivingScore.Pass],
                                           distanceDelta: Double) -> LifetimeStats {
        var s = stats
        s.distanceMeters += max(0, distanceDelta)
        let added = Array(allPasses.dropFirst(min(basePasses.count, allPasses.count)))
        s.camerasPassed += added.count
        var limited = 0, fined = 0
        for pass in added {
            guard let limit = pass.limitKmh else { continue }
            limited += 1
            let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
            if fine > 0 {
                fined += 1
                s.riskFinesSum += fine
            } else {
                s.camerasInLimit += 1
                s.savedFinesSum += FineSchedule.minimumFine
            }
        }
        // Серия — для склеенной поездки как ОДНОЙ. Первая нога своим финишем
        // уже сделала шаг, если была чистой лимитной; штраф второй ноги делает
        // поездку нечистой — шаг отменяется, и рекорд, поднятый этим шагом,
        // тоже (ревью S11: «20 чистых подряд» за поездку со штрафом).
        let baseLimited = basePasses.contains { $0.limitKmh != nil }
        let baseFined = basePasses.contains { pass in
            pass.limitKmh.map { FineSchedule.fine(overKmh: pass.speedKmh - Double($0)) > 0 } ?? false
        }
        if baseLimited && !baseFined {
            if fined > 0 {
                if s.lastTripRaisedBest == true, s.bestStreak > 0 { s.bestStreak -= 1 }
                s.lastTripRaisedBest = false
                s.cleanStreak = 0
            }
        } else if !baseLimited, limited > 0 {
            if fined > 0 {
                s.cleanStreak = 0
            } else {
                s.cleanStreak += 1
                s.lastTripRaisedBest = s.cleanStreak > s.bestStreak
                s.bestStreak = max(s.bestStreak, s.cleanStreak)
            }
        }
        return s
    }

    /// Хирургический откат вычищенных проездов из пожизненных счётчиков.
    ///
    /// Ретро-чистка ложных проездов НЕ имеет права пересобирать lifetime из
    /// истории (`rebuilt`): история обрезана до 50 записей / 30 дней, и такой
    /// «пересчёт» обнулял бы годовые километры, экономию и достижения — ровно
    /// то, ради чего lifetime хранится отдельно. Вычитаем только то, что
    /// внесли сами удалённые проезды. Поездки и километры не трогаем (поездка
    /// была), серии тоже: ложное НАРУШЕНИЕ могло только оборвать серию, так
    /// что оставить её как есть — консервативно в пользу пользователя.
    nonisolated static func subtractingPasses(_ removed: [DrivingScore.Pass],
                                              from stats: LifetimeStats) -> LifetimeStats {
        var s = stats
        for pass in removed {
            s.camerasPassed = max(0, s.camerasPassed - 1)
            guard let limit = pass.limitKmh else { continue }
            let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
            if fine > 0 {
                s.riskFinesSum = max(0, s.riskFinesSum - fine)
            } else {
                s.camerasInLimit = max(0, s.camerasInLimit - 1)
                s.savedFinesSum = max(0, s.savedFinesSum - FineSchedule.minimumFine)
            }
        }
        return s
    }

    /// Хирургическая правка счётчиков, когда у проезда сменился ЛИМИТ, а сам
    /// проезд остался.
    ///
    /// Это случай ретро-подъёма лимита до пола фиксации: проезд был и остаётся,
    /// поэтому `camerasPassed`, `trips` и километры не трогаются вовсе — меняется
    /// только вердикт «штраф или в лимите» и деньги. Серии не трогаем по той же
    /// причине, что и в `subtractingPasses`: ложное нарушение могло серию лишь
    /// оборвать, и оставить её как есть — консервативно в пользу пользователя.
    nonisolated static func replacingPass(_ old: DrivingScore.Pass,
                                          with new: DrivingScore.Pass,
                                          in stats: LifetimeStats) -> LifetimeStats {
        var s = stats
        if let limit = old.limitKmh {
            let fine = FineSchedule.fine(overKmh: old.speedKmh - Double(limit))
            if fine > 0 {
                s.riskFinesSum = max(0, s.riskFinesSum - fine)
            } else {
                s.camerasInLimit = max(0, s.camerasInLimit - 1)
                s.savedFinesSum = max(0, s.savedFinesSum - FineSchedule.minimumFine)
            }
        }
        if let limit = new.limitKmh {
            let fine = FineSchedule.fine(overKmh: new.speedKmh - Double(limit))
            if fine > 0 {
                s.riskFinesSum += fine
            } else {
                s.camerasInLimit += 1
                s.savedFinesSum += FineSchedule.minimumFine
            }
        }
        return s
    }

    /// Восстановление счётчиков из уже накопленной истории (обновление приложения:
    /// у пользователя есть поездки, а lifetime ещё пуст) — от старых к новым.
    nonisolated static func rebuilt(from historyNewestFirst: [TripRecord]) -> LifetimeStats {
        var stats = LifetimeStats()
        for record in historyNewestFirst.reversed() {
            let passes = record.passed.map {
                DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh)
            }
            stats = updated(stats, passes: passes, distanceMeters: record.distanceMeters)
        }
        return stats
    }
}

// MARK: - Достижения

nonisolated struct Achievement: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let target: Double
    let progress: Double

    var earned: Bool { progress >= target }
    var fraction: Double { min(1, progress / max(target, 1)) }
    /// «830 / 1 000» — прогресс без единиц: у бейджей они разные (км, камеры,
    /// поездки), а понятно и так.
    var progressText: String {
        "\(Int(progress.rounded(.down))) / \(Int(target))"
    }
}

nonisolated enum Achievements {
    /// Девять бейджей: дистанция, чистые камеры, лучшая серия.
    nonisolated static func all(for stats: LifetimeStats) -> [Achievement] {
        let km = stats.distanceMeters / 1000
        let clean = Double(stats.camerasInLimit)
        let streak = Double(stats.bestStreak)
        let kmDetail = String(localized: "Проехать столько километров с включённым RadarMap.")
        let cleanDetail = String(localized: "Проехать столько камер с известным лимитом — без штрафной скорости.")
        let streakDetail = String(localized: "Серия поездок подряд, где ни одна камера не поймала бы на штраф.")
        return [
            Achievement(id: "km100", icon: "point.topleft.down.to.point.bottomright.curvepath",
                        title: String(localized: "100 км"), detail: kmDetail, target: 100, progress: km),
            Achievement(id: "km1000", icon: "road.lanes",
                        title: String(localized: "1 000 км"), detail: kmDetail, target: 1000, progress: km),
            Achievement(id: "km10000", icon: "globe.asia.australia.fill",
                        title: String(localized: "10 000 км"), detail: kmDetail, target: 10000, progress: km),
            Achievement(id: "clean50", icon: "camera.metering.center.weighted",
                        title: String(localized: "50 камер в лимите"), detail: cleanDetail, target: 50, progress: clean),
            Achievement(id: "clean500", icon: "checkmark.seal.fill",
                        title: String(localized: "500 камер в лимите"), detail: cleanDetail, target: 500, progress: clean),
            Achievement(id: "clean5000", icon: "crown.fill",
                        title: String(localized: "5 000 камер в лимите"), detail: cleanDetail, target: 5000, progress: clean),
            Achievement(id: "streak5", icon: "flame",
                        title: String(localized: "5 чистых подряд"), detail: streakDetail, target: 5, progress: streak),
            Achievement(id: "streak20", icon: "flame.fill",
                        title: String(localized: "20 чистых подряд"), detail: streakDetail, target: 20, progress: streak),
            Achievement(id: "streak50", icon: "trophy.fill",
                        title: String(localized: "50 чистых подряд"), detail: streakDetail, target: 50, progress: streak),
        ]
    }

    /// Ближайшее незакрытое достижение — то, до которого меньше всего осталось.
    /// Лента бейджей показывает всё сразу и не отвечает на вопрос «а что дальше»;
    /// одна цель с прогрессом отвечает.
    nonisolated static func next(for stats: LifetimeStats) -> Achievement? {
        all(for: stats).filter { !$0.earned }.max { $0.fraction < $1.fraction }
    }
}

extension LifetimeStats {
    /// Поле, добавленное позже, не делает старый файл «битым» (ревью S9):
    /// синтезированный разбор требует все ключи, даже у полей по умолчанию.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        trips = try c.decodeIfPresent(Int.self, forKey: .trips) ?? 0
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        camerasPassed = try c.decodeIfPresent(Int.self, forKey: .camerasPassed) ?? 0
        camerasInLimit = try c.decodeIfPresent(Int.self, forKey: .camerasInLimit) ?? 0
        savedFinesSum = try c.decodeIfPresent(Double.self, forKey: .savedFinesSum) ?? 0
        riskFinesSum = try c.decodeIfPresent(Double.self, forKey: .riskFinesSum) ?? 0
        cleanStreak = try c.decodeIfPresent(Int.self, forKey: .cleanStreak) ?? 0
        bestStreak = try c.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        lastTripRaisedBest = try c.decodeIfPresent(Bool.self, forKey: .lastTripRaisedBest)
    }
}
