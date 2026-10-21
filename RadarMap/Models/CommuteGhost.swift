//
//  CommuteGhost.swift
//  RadarMap
//
//  «Призрак» дороги на работу (план 19.10, этап 8): прогноз прибытия по
//  СВОИМ прошлым поездкам этим путём, пересчитываемый на ходу. Участок
//  прошли быстрее или медленнее обычного — остаток сдвигается, как отставание
//  от призрака в гоночном симуляторе. Только это не гонка, и правила здесь
//  строже, чем у гонки:
//
//  - Призрак — МЕДИАНА, не лучшее время, и не быстрее лимита: время участка
//    снизу ограничено проездом на лимите. Ни «вы быстрее на 40 с», ни
//    рекордов — опережение графика говорит только время прибытия.
//  - Без целевого времени — «как обычно / дольше обычного», но никогда
//    «опоздаете». С целью — запас «с запасом / впритык / опаздываю» с
//    гистерезисом, чтобы на границе он не мигал.
//  - Всё считается на телефоне; модуль чистый и не знает ни о GPS, ни о
//    сервере — его входы приходят от CommuteLiveService.
//
//  Модель остатка: R = m_k·(1−f)·ρ + S_{k+1} + (ρ−1)·Σ_{j>k} m_j·e^{−(b_j−a)/D}.
//  Сегодняшний темп ρ действует рядом и затухает с расстоянием D: пробка на
//  первом километре не означает пробку на десятом. Суффиксные суммы считаются
//  один раз на базу — на фикс O(1) после поиска участка.
//

import Foundation

nonisolated enum CommuteGhost {

    // MARK: - База: медиана водителя по участкам

    struct Baseline: Equatable, Sendable {
        /// Границы участков, м от начала линии; `ends.count == median.count`.
        let ends: [Double]
        /// Медиана секунд по участку (с полом лимита).
        let median: [Double]
        let q25: [Double]
        let q75: [Double]
        /// S_k = Σ_{j≥k} m_j; последний элемент — 0.
        let suffix: [Double]
        /// E_k = Σ_{j≥k} m_j·e^{−b_j/D}; последний элемент — 0.
        let decayed: [Double]
        /// V_k = Σ_{j≥k} ((q75_j − q25_j)/1,35)²: разброс остатка за O(1).
        let spreadSquared: [Double]
        /// Сколько поездок легло в базу.
        let rows: Int
        /// Множитель базы (24.2): поправка на светофоры × сдвиг журнала; 1 —
        /// без калибровки (CommuteLoss: участки против участков).
        var scale: Double = 1
        /// Разброс целых поездок, доля обычного времени (σ отношений): вилка
        /// раннего прогноза (24.3).
        var spread: Double = 0

        /// Обычное время всего пути.
        var total: Double { suffix.first ?? 0 }
        var length: Double { ends.last ?? 0 }

        func start(of segment: Int) -> Double { segment == 0 ? 0 : ends[segment - 1] }
        func length(of segment: Int) -> Double { ends[segment] - start(of: segment) }

        /// Участок, в котором точка `along`, и доля пройденного в нём.
        /// Обычное время от точки `along` до конца линии, с (без сегодняшнего темпа).
        func usualRemaining(at along: Double) -> Double {
            let (k, f) = locate(along)
            return median[k] * (1 - f) + suffix[k + 1]
        }

        func locate(_ along: Double) -> (segment: Int, fraction: Double) {
            let a = min(max(0, along), length)
            // Двоичный поиск первой границы ≥ a.
            var lo = 0, hi = ends.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if ends[mid] < a { lo = mid + 1 } else { hi = mid }
            }
            let len = length(of: lo)
            let f = len > 0 ? (a - start(of: lo)) / len : 1
            return (lo, min(max(f, 0), 1))
        }
    }

    /// Строки для призрака: тот же класс дня, выезд ±60 мин от сегодняшнего,
    /// иначе ±120, иначе все этого класса. Меньше `minRows` — призрака нет:
    /// медиана из двух поездок — это не «обычно».
    static func selectRows(_ rows: [CommuteProfile.Row], weekend: Bool, departureMinute: Int,
                           calendar: Calendar = .current,
                           minRows: Int = AppConfig.commuteGhostMinRows) -> [CommuteProfile.Row]? {
        selectRowsTiered(rows, weekend: weekend, departureMinute: departureMinute,
                         calendar: calendar, minRows: minRows)?.rows
    }

    /// Насколько выборка про этот час: окно ±60 мин, ±120 или весь день.
    enum RowTier: Int, Comparable, Sendable {
        case hour, twoHours, allDay
        static func < (a: RowTier, b: RowTier) -> Bool { a.rawValue < b.rawValue }
    }

    /// То же, что `selectRows`, и из какого окна взято: «сейчас ~44 мин» до
    /// выезда (CommuteEstimate) честно только для ±60/±120 — медиана всего
    /// дня в три часа ночи не «сейчас».
    static func selectRowsTiered(_ rows: [CommuteProfile.Row], weekend: Bool, departureMinute: Int,
                                 calendar: Calendar = .current,
                                 minRows: Int = AppConfig.commuteGhostMinRows)
        -> (rows: [CommuteProfile.Row], tier: RowTier)? {
        // Праздник — по дате строки, а не только по флагу свёртки: строки,
        // свёрнутые до списка праздников (или до правки оценки хайитов),
        // иначе ещё 45 дней портили бы будничную медиану.
        let sameClass = rows.filter { ($0.weekend || UzHolidays.isHoliday($0.departure, calendar: calendar)) == weekend }
        func near(_ window: Int) -> [CommuteProfile.Row] {
            sameClass.filter {
                let m = CommuteProfile.minuteOfDay($0.departure, calendar: calendar)
                let d = abs(m - departureMinute)
                return min(d, 1440 - d) <= window
            }
        }
        for (candidate, tier) in [(near(60), RowTier.hour), (near(120), .twoHours), (sameClass, .allDay)]
            where candidate.count >= minRows {
            return (candidate, tier)
        }
        return nil
    }

    /// База по строкам варианта. Участок, который измерен меньше чем в двух
    /// поездках, берёт темп соседей (секунд на метр по всей базе) — дыра в
    /// одной строке не должна делать прогноз невозможным.
    ///
    /// `weights` — веса строк (Selection; nil — все по 1). `calibrate` —
    /// привести сумму медиан к медиане целых поездок (24.2: светофоры), `bias`
    /// — сдвиг из журнала точности; оба до пола лимита, чтобы поправка вниз
    /// не сделала призрака быстрее разрешённого.
    static func baseline(ends rawEnds: [Float], limitKmh: [UInt8], rows: [CommuteProfile.Row],
                         weights: [Double]? = nil, calibrate: Bool = false, bias: Double = 1,
                         decayMeters: Double = AppConfig.commuteGhostDecayMeters) -> Baseline? {
        let ends = rawEnds.map(Double.init)
        guard !ends.isEmpty, !rows.isEmpty else { return nil }
        let n = ends.count
        var median = [Double](repeating: .nan, count: n)
        var q25 = median, q75 = median
        var measuredSeconds = 0.0, measuredMeters = 0.0
        // Равные веса (ступени) — прежний квантиль без весов: точка в точку.
        let w = weights ?? []
        let weighted = w.count == rows.count && Set(w).count > 1
        for j in 0..<n {
            var pairs: [(value: Double, weight: Double)] = []
            for (r, row) in rows.enumerated()
            where j < row.seconds.count && row.seconds[j] != CommuteProfile.Row.noData {
                pairs.append((Double(row.seconds[j]), weighted ? w[r] : 1))
            }
            guard pairs.count >= 2 else { continue }
            if weighted {
                median[j] = weightedQuantile(pairs, 0.5)
                q25[j] = weightedQuantile(pairs, 0.25)
                q75[j] = weightedQuantile(pairs, 0.75)
            } else {
                let values = pairs.map(\.value).sorted()
                median[j] = quantile(values, 0.5)
                q25[j] = quantile(values, 0.25)
                q75[j] = quantile(values, 0.75)
            }
            let len = ends[j] - (j == 0 ? 0 : ends[j - 1])
            measuredSeconds += median[j]
            measuredMeters += len
        }
        guard measuredMeters > 0 else { return nil }
        let pace = measuredSeconds / measuredMeters
        for j in 0..<n where median[j].isNaN {
            let len = ends[j] - (j == 0 ? 0 : ends[j - 1])
            median[j] = len * pace
            q25[j] = median[j]
            q75[j] = median[j]
        }
        var scale = 1.0, spread = 0.0
        if calibrate {
            scale = calibration(rows: rows, weights: w, median: median)
            spread = totalSpread(rows: rows, weights: w, median: median)
        }
        scale *= min(max(bias, AppConfig.commuteAccuracyBiasMin), AppConfig.commuteAccuracyBiasMax)
        for j in 0..<n {
            let len = ends[j] - (j == 0 ? 0 : ends[j - 1])
            if scale != 1 {
                median[j] *= scale
                q25[j] *= scale
                q75[j] *= scale
            }
            // Призрак не быстрее лимита: участок нельзя «обычно» проезжать
            // быстрее, чем разрешено (пол — проезд ровно на лимите).
            if j < limitKmh.count, limitKmh[j] > 0 {
                let floor = len * 3.6 / Double(limitKmh[j])
                median[j] = max(median[j], floor)
                q25[j] = max(q25[j], floor)
                q75[j] = max(q75[j], median[j])
            }
        }
        var suffix = [Double](repeating: 0, count: n + 1)
        var decayed = [Double](repeating: 0, count: n + 1)
        var spreadSquared = [Double](repeating: 0, count: n + 1)
        for j in stride(from: n - 1, through: 0, by: -1) {
            let b = j == 0 ? 0 : ends[j - 1]
            let s = (q75[j] - q25[j]) / 1.35
            suffix[j] = suffix[j + 1] + median[j]
            decayed[j] = decayed[j + 1] + median[j] * exp(-b / decayMeters)
            spreadSquared[j] = spreadSquared[j + 1] + s * s
        }
        return Baseline(ends: ends, median: median, q25: q25, q75: q75,
                        suffix: suffix, decayed: decayed, spreadSquared: spreadSquared, rows: rows.count,
                        scale: scale, spread: spread)
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let position = q * Double(sorted.count - 1)
        let lo = Int(position.rounded(.down)), hi = Int(position.rounded(.up))
        let w = position - Double(lo)
        return sorted[lo] * (1 - w) + sorted[hi] * w
    }

    // MARK: - Темп сегодня

    /// ρ = Σ живых секунд / Σ медиан по последним участкам (≈ 2 км, не меньше
    /// трёх), сглаженный к прежнему и ограниченный [0,7; 2,5]. Меньше трёх
    /// пройденных участков — темп не известен, ρ = 1 (как обычно). Один
    /// участок весит не больше `commuteGhostPaceMax` своих медиан: стоянка у
    /// обочины — это время в пути, а не темп всего остального пути.
    static func pace(live: [(seconds: Double, median: Double, length: Double)],
                     previous: Double = 1,
                     windowMeters: Double = AppConfig.commuteGhostPaceWindowMeters) -> Double {
        var seconds = 0.0, usual = 0.0, meters = 0.0, count = 0
        for entry in live.reversed() {
            seconds += min(entry.seconds, entry.median * AppConfig.commuteGhostPaceMax)
            usual += entry.median
            meters += entry.length
            count += 1
            if meters >= windowMeters && count >= 3 { break }
        }
        guard count >= 3, usual > 0 else { return previous }
        let raw = min(max(seconds / usual, AppConfig.commuteGhostPaceMin), AppConfig.commuteGhostPaceMax)
        return previous + (raw - previous) * AppConfig.commuteGhostPaceSmoothing
    }

    // MARK: - Почему дольше (8.8.12)

    /// Одно слово к «+6 мин»: пробка (на пройденных участках и рёбра
    /// `now.json`, и сам проезд были хуже обычного разброса — `jamSeconds`
    /// сверх медианы), пробка впереди (24.3: рёбра `now.json` дальше по
    /// линии — `jamAhead` сверх своей медианы) или стояли (одна стоянка от
    /// 3 мин). Видно несколько — побеждает та, что стоила больше секунд.
    /// Причины не видно — слова нет: догадка, проданная как факт, хуже молчания.
    enum Reason: String, Equatable, Sendable { case jam, stood, jamAhead }

    static func reason(delta: TimeInterval, jamSeconds: TimeInterval, longestStand: TimeInterval,
                       jamAhead: TimeInterval = 0) -> Reason? {
        guard delta >= 60 else { return nil }
        let floor = AppConfig.commuteJamReasonSeconds
        let candidates: [(Reason, TimeInterval)] = [
            (.jam, jamSeconds >= floor ? jamSeconds : 0),
            (.jamAhead, jamAhead >= floor ? jamAhead : 0),
            (.stood, longestStand >= AppConfig.commuteLongStandSeconds ? longestStand : 0),
        ]
        // При равенстве — порядок списка: пройденная пробка, впереди, стояли.
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return candidates.first { $0.1 == best.1 }?.0
    }

    // MARK: - Прогноз

    struct Forecast: Equatable, Sendable {
        /// Осталось ехать, с.
        let remaining: Double
        /// Отклонение от обычного всего пути: (в пути + остаток) − обычно, с.
        let delta: Double
        /// Разброс остатка по межквартильным размахам участков, с.
        let sigma: Double
        let arrival: Date

        /// Округлённое до минуты отклонение — «+4 мин»; меньше минуты в любую
        /// сторону — 0, «как обычно» (30 с не повод для «на 1 минуту дольше»).
        var deltaMinutes: Int { abs(delta) < 60 ? 0 : Int((delta / 60).rounded()) }
    }

    /// Остаток пути от точки `along` при сегодняшнем темпе `rho`, и прибытие.
    /// `elapsed` — сколько уже в пути (включая стоянки). Стоянка не двигает
    /// `along`, а `elapsed` растёт — так стоянка честно сдвигает прибытие.
    /// `jamAhead` — пробки сверх обычного дальше по линии (8.8.10, по рёбрам
    /// `now.json`, только хуже q75 водителя — обычная пробка уже в медиане).
    static func forecast(_ base: Baseline, along: Double, elapsed: Double, rho: Double,
                         now: Date, jamAhead: Double = 0,
                         decayMeters: Double = AppConfig.commuteGhostDecayMeters) -> Forecast {
        let (k, f) = base.locate(along)
        let a = min(max(0, along), base.length)
        let here = base.median[k] * (1 - f) * rho
        let ahead = base.suffix[k + 1] + (rho - 1) * exp(a / decayMeters) * base.decayed[k + 1]
        let remaining = max(0, here + ahead + max(0, jamAhead))
        let sk = (base.q75[k] - base.q25[k]) / 1.35
        let variance = sk * sk * (1 - f) + base.spreadSquared[k + 1]
        return Forecast(remaining: remaining, delta: elapsed + remaining - base.total,
                        sigma: variance.squareRoot(), arrival: now.addingTimeInterval(remaining))
    }

    /// Прогноз показываем только после `commuteGhostMinAlongMeters` по линии:
    /// заезд в магазин у дома — ещё не дорога на работу.
    static func isConfirmed(along: Double) -> Bool {
        along >= AppConfig.commuteGhostMinAlongMeters
    }

    // MARK: - Сход с дороги

    /// «Сегодня другой дорогой»: сошли, когда отклонение больше max(60 м,
    /// точность + 30) три фикса подряд и уже 250 м пути; вернулись — когда
    /// ближе 40 м на протяжении 300 м. Пока сошли — прогноз и голос молчат.
    struct Track: Equatable, Sendable {
        private(set) var isOff = false
        private var farFixes = 0
        private var farMeters = 0.0
        private var nearMeters = 0.0

        init() {}

        mutating func update(offset: Double, accuracy: Double, stepMeters: Double) -> Bool {
            let far = offset > max(AppConfig.commuteGhostOffMeters, accuracy + 30)
            if isOff {
                if offset <= AppConfig.commuteGhostBackMeters {
                    nearMeters += stepMeters
                    if nearMeters >= AppConfig.commuteGhostBackRunMeters {
                        isOff = false
                        farFixes = 0
                        farMeters = 0
                        nearMeters = 0
                    }
                } else {
                    nearMeters = 0
                }
            } else if far {
                farFixes += 1
                farMeters += stepMeters
                if farFixes >= 3, farMeters >= AppConfig.commuteGhostOffRunMeters { isOff = true }
            } else {
                farFixes = 0
                farMeters = 0
            }
            return !isOff
        }
    }

    // MARK: - Голос

    /// Когда призраку говорить (8.7): первая фраза — сразу после
    /// подтверждения пути; повтор — только если отклонение сдвинулось на
    /// 3+ мин, с прошлой фразы прошло 4+ мин и до финиша больше 2 км; не
    /// больше трёх фраз за поездку. Голос призрака — ниже камеры и манёвра:
    /// это решает вызывающий, и фраза засчитывается только СКАЗАННОЙ —
    /// `wants`, затем `commit`, когда голос был свободен. Иначе первая фраза
    /// терялась под оповещением о камере, а следующая ждала сдвига на 3 мин.
    struct Announcer: Equatable, Sendable {
        private(set) var spoken = 0
        private var lastDelta: Int?
        private var lastAt: Date?

        init() {}

        func wants(deltaMinutes: Int, remainingMeters: Double, now: Date) -> Bool {
            guard spoken < AppConfig.commuteGhostMaxPhrases else { return false }
            guard let lastDelta, let lastAt else { return true }
            return abs(deltaMinutes - lastDelta) >= AppConfig.commuteGhostRepeatDeltaMinutes
                && now.timeIntervalSince(lastAt) >= AppConfig.commuteGhostRepeatSeconds
                && remainingMeters >= AppConfig.commuteGhostRepeatMinRemainingMeters
        }

        /// Фраза об опоздании (у неё своё правило — LateNotice) всё равно
        /// живёт в общем лимите: не больше трёх фраз за поездку, повтор не
        /// чаще раза в 4 мин и не у самого финиша.
        func allowsLate(remainingMeters: Double, now: Date) -> Bool {
            guard spoken < AppConfig.commuteGhostMaxPhrases else { return false }
            guard let lastAt else { return true }
            return now.timeIntervalSince(lastAt) >= AppConfig.commuteGhostRepeatSeconds
                && remainingMeters >= AppConfig.commuteGhostRepeatMinRemainingMeters
        }

        mutating func commit(deltaMinutes: Int, now: Date) {
            spoken += 1
            lastDelta = deltaMinutes
            lastAt = now
        }

        /// `wants` и сразу `commit` — когда голос заведомо свободен.
        mutating func shouldSpeak(deltaMinutes: Int, remainingMeters: Double, now: Date) -> Bool {
            guard wants(deltaMinutes: deltaMinutes, remainingMeters: remainingMeters, now: now)
            else { return false }
            commit(deltaMinutes: deltaMinutes, now: now)
            return true
        }
    }

    /// «На работу к 9:12, как обычно» / «Домой к 18:40, на 4 минуты дольше
    /// обычного». Быстрее обычного — тоже «как обычно»: не гонка. Со сроком
    /// хвост — запас: «с запасом 9 минут», «впритык», «на 12 минут позже
    /// срока». Без «поторопитесь» в любом виде.
    static func phrase(direction: Commute.Direction, arrival: Date, deltaMinutes: Int,
                       slack: TargetSlack? = nil,
                       locale: Locale = NumberFormat.locale) -> String {
        let clock = Self.clock(arrival, locale: locale)
        let head = direction == .toWork ? String(localized: "На работу к \(clock)")
                                        : String(localized: "Домой к \(clock)")
        let tail: String
        if let slack {
            switch slack.shown {
            case .comfortable where slack.minutes >= 60: tail = String(localized: "с запасом больше часа")
            case .comfortable: tail = String(localized: "с запасом \(slack.minutes) минут")
            case .tight: tail = String(localized: "впритык")
            case .late: tail = String(localized: "на \(slack.lateMinutes) минут позже срока")
            }
        } else {
            tail = deltaMinutes >= 1 ? String(localized: "на \(deltaMinutes) минут дольше обычного")
                                     : String(localized: "как обычно")
        }
        return head + ", " + tail
    }

    static func clock(_ date: Date, locale: Locale = NumberFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    /// Запас до срока для строки и голоса: состояние (с гистерезисом) и минуты.
    struct TargetSlack: Equatable, Sendable {
        let state: Slack
        /// Срок минус прибытие, мин, округлено (меньше нуля — позже срока).
        let minutes: Int
        let deadline: Date

        /// Что показать и сказать. Гистерезис держит «позже» до запаса +1,5
        /// мин, но прогноз раньше срока словом «позже» не называется — на
        /// границе это «впритык» (ревью 19.10: зелёные 8:59 и красное «на
        /// 1 мин позже 9:00» рядом).
        var shown: Slack { state == .late && minutes >= 0 ? .tight : state }

        /// «Позже на N» — только когда показано «позже», и не меньше одной.
        var lateMinutes: Int { max(1, -minutes) }
    }

    /// Опоздание голосом — один раз; повтор — только если стало хуже ещё на
    /// `arrivalTargetLateRepeatMinutes` (8.7). Не «поторопитесь» — просто время.
    struct LateNotice: Equatable, Sendable {
        private var lastLate: Int?

        init() {}

        func wants(lateMinutes: Int) -> Bool {
            guard let lastLate else { return true }
            return lateMinutes >= lastLate + AppConfig.arrivalTargetLateRepeatMinutes
        }

        mutating func commit(lateMinutes: Int) { lastLate = lateMinutes }
    }

    // MARK: - Запас до целевого времени

    enum Slack: Equatable, Sendable {
        case comfortable   // ≥ +5 мин
        case tight         // 0…+5
        case late          // < 0

        /// Без гистерезиса: где лежит запас в минутах.
        static func raw(minutes: Double) -> Slack {
            minutes >= 5 ? .comfortable : minutes >= 0 ? .tight : .late
        }
    }

    /// Состояние запаса с гистерезисом: граница сдвигается на 1,5 мин в
    /// сторону текущего состояния, а новое состояние принимается, только
    /// если держится два пересчёта подряд с промежутком ≥ 60 с. Без цели
    /// состояния нет вовсе — «опоздаете» без цели не говорится никогда.
    struct SlackTracker: Equatable, Sendable {
        private(set) var state: Slack?
        private var pending: Slack?
        private var pendingAt: Date?

        init() {}

        mutating func update(slackMinutes: Double?, now: Date) -> Slack? {
            guard let slackMinutes else {
                state = nil
                pending = nil
                return nil
            }
            let candidate = Self.withHysteresis(slackMinutes, current: state)
            guard let current = state else {
                state = candidate
                return state
            }
            if candidate == current {
                pending = nil
                pendingAt = nil
            } else if candidate == pending, let since = pendingAt,
                      now.timeIntervalSince(since) >= AppConfig.commuteGhostSlackHoldSeconds {
                state = candidate
                pending = nil
                pendingAt = nil
            } else if candidate != pending {
                pending = candidate
                pendingAt = now
            }
            return state
        }

        static func withHysteresis(_ minutes: Double, current: Slack?) -> Slack {
            let h = AppConfig.commuteGhostSlackHysteresisMinutes
            switch current {
            case .comfortable?: return Slack.raw(minutes: minutes + h)
            case .late?:        return Slack.raw(minutes: minutes - h)
            case .tight?:
                // Из «впритык» наружу — с запасом h в обе стороны.
                if minutes >= 5 + h { return .comfortable }
                if minutes < -h { return .late }
                return .tight
            case nil:           return Slack.raw(minutes: minutes)
            }
        }
    }
}
