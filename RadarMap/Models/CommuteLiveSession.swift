//
//  CommuteLiveSession.swift
//  RadarMap
//
//  Одна поездка дом↔работа на ходу (этап 8.8.2): куда мы на линии варианта,
//  сколько сегодня шли участки и когда пересчитать призрак. Чистая структура
//  без GPS и таймеров — её кормит CommuteLiveService фиксами, которые и так
//  приходят в поездке (ни одного нового запроса геопозиции).
//
//  Каждый вариант пути (их ≤ 3) ведётся отдельно: своя точка входа на линию,
//  свои пересечения границ и свой темп ρ. Общего состояния нет — иначе
//  пересечения по чужой линии портили темп, а выбранный однажды вариант
//  держал призрак немым, когда водитель уходил на другой знакомый путь
//  (ревью 19.10). Ведущий — ближайший к машине из тех, что на линии и
//  прошли 1,5 км; смена — только когда другой ближе заметно.
//
//  Отклонение Δ считается от точки входа на линию: поездка, начатая
//  автоматикой на 800-м метре или продолженная после магазина, сравнивается
//  с обычным временем от той же точки, а не от дома.
//
//  Бюджет на фикс: проекция только в окне линии вокруг прошлой точки; полный
//  проход — когда окно потеряло машину, не чаще раза в 200 м пути; далёкая
//  линия (едем другим путём) не сканируется вовсе, пока до неё заведомо
//  дальше порога; пересчёт прогноза — на границе участка или раз в 30 с.
//

import CoreLocation
import Foundation
import simd

nonisolated struct CommuteLiveSession: Sendable {

    /// Что увидеть и услышать после фикса.
    struct Output: Equatable, Sendable {
        let forecast: CommuteGhost.Forecast?
        let isOff: Bool
        /// Осталось по линии ведущего варианта, м (для правила голоса «≥ 2 км»).
        var remainingMeters: Double = 0
        /// Есть ведущий вариант. Нет — прогноз прятать: ведущий сошёл, а
        /// другой ещё не прошёл своих 1,5 км.
        var hasLead = false
    }

    /// Вариант пути с базой, индексом линии и сегодняшним проездом по ней.
    private struct Candidate: Sendable {
        let base: CommuteGhost.Baseline
        let xy: [SIMD2<Double>]
        let cumulative: [Double]
        // Проекция.
        var cursor = 0
        var floor = 0.0
        /// Метров пути с прошлого полного прохода по линии.
        var sinceRescan = Double.infinity
        /// Отклонение на прошлом полном проходе, если линия была далеко: машина
        /// не приближается к линии быстрее, чем едет, поэтому пока
        /// `farOffset − sinceRescan` больше порога, линию можно не сканировать.
        var farOffset: Double?
        var offsetEMA: Double?
        // Сегодня по этой линии.
        var track = CommuteGhost.Track()
        /// Где и когда сегодня вошли на линию — от этой точки считается Δ.
        var joined: (along: Double, at: Date)?
        var lastAlong: Double?
        var lastTime: Date?
        var crossTimes: [Int: Date] = [:]
        var live: [(seconds: Double, median: Double, length: Double)] = []
        var rho = 1.0
    }

    private let frame: CommuteProfile.Frame
    private var candidates: [Candidate]
    /// Ведущий вариант — его прогноз виден и слышен.
    private(set) var active: Int?
    private var lastPoint: SIMD2<Double>?
    private var lastForecastAt: Date?

    /// nil — призрака нет: ни у одного варианта направления нет трёх
    /// подходящих поездок (выходной, непривычный час, мало истории).
    init?(variants: [CommuteProfile.Variant], weekend: Bool, departure: Date,
          calendar: Calendar = .current) {
        let minute = CommuteProfile.minuteOfDay(departure, calendar: calendar)
        var built: [Candidate] = []
        var lat0: Double?
        for variant in variants {
            guard let rows = CommuteGhost.selectRows(variant.rows, weekend: weekend,
                                                     departureMinute: minute, calendar: calendar),
                  let base = CommuteGhost.baseline(ends: variant.ends, limitKmh: variant.limitKmh,
                                                   rows: rows),
                  let first = variant.coordinates.first else { continue }
            if lat0 == nil { lat0 = first.latitude }
            let frame = CommuteProfile.Frame(latitude: lat0!)
            let xy = variant.coordinates.map { frame.xy($0.latitude, $0.longitude) }
            guard xy.count >= 2 else { continue }
            var cumulative: [Double] = [0]
            for (a, b) in zip(xy, xy.dropFirst()) { cumulative.append(cumulative.last! + simd_distance(a, b)) }
            built.append(Candidate(base: base, xy: xy, cumulative: cumulative))
        }
        guard let lat0, !built.isEmpty else { return nil }
        frame = CommuteProfile.Frame(latitude: lat0)
        candidates = built
    }

    mutating func note(lat: Double, lon: Double, accuracy: Double, at now: Date) -> Output {
        let p = frame.xy(lat, lon)
        let step = lastPoint.map { simd_distance($0, p) } ?? 0
        lastPoint = p
        let accuracy = max(accuracy, 0)

        var crossed = Set<Int>()
        for i in candidates.indices where Self.advance(&candidates[i], p, step: step,
                                                       accuracy: accuracy, now: now) {
            crossed.insert(i)
        }
        let previous = active
        active = Self.lead(candidates, previous: previous)

        guard let index = active else {
            return Output(forecast: nil, isOff: candidates.allSatisfy { $0.track.isOff })
        }
        let c = candidates[index]
        let remainingMeters = max(0, c.base.length - c.floor)
        let due = index != previous || crossed.contains(index) || lastForecastAt.map {
            now.timeIntervalSince($0) >= AppConfig.commuteGhostRecomputeSeconds
        } ?? true
        guard due, let joined = c.joined else {
            return Output(forecast: nil, isOff: false, remainingMeters: remainingMeters, hasLead: true)
        }
        lastForecastAt = now
        // «В пути» — как если бы ехали от начала линии: сегодня с точки входа
        // плюс обычное время до неё.
        let elapsed = now.timeIntervalSince(joined.at) + c.base.total - c.base.usualRemaining(at: joined.along)
        let forecast = CommuteGhost.forecast(c.base, along: c.floor, elapsed: elapsed, rho: c.rho, now: now)
        return Output(forecast: forecast, isOff: false, remainingMeters: remainingMeters, hasLead: true)
    }

    /// Фикс по одной линии: проекция, сход/возврат, пересечения границ и
    /// темп. true — пересекли границу участка (повод пересчитать).
    private static func advance(_ c: inout Candidate, _ p: SIMD2<Double>, step: Double,
                                accuracy: Double, now: Date) -> Bool {
        let (along, offset) = project(p, &c, step: step)
        c.offsetEMA = c.offsetEMA.map { $0 + (offset - $0) * 0.3 } ?? offset
        guard c.track.update(offset: offset, accuracy: accuracy, stepMeters: step) else {
            // Сошли: участок, растянутый через сход, — не темп. Вход до
            // подтверждения забываем — это могло быть пересечение линии на
            // перекрёстке, а не въезд на неё.
            c.lastAlong = nil
            c.lastTime = nil
            c.crossTimes.removeAll()
            if !CommuteGhost.isConfirmed(along: c.floor) { c.joined = nil }
            return false
        }
        if c.joined == nil {
            guard offset <= max(AppConfig.commuteGhostOffMeters, accuracy + 30) else { return false }
            c.joined = (along, now)
        }
        var crossed = false
        if let lastAlong = c.lastAlong, let lastTime = c.lastTime, along > lastAlong, now > lastTime {
            // Только границы между прошлой и новой точкой — не все участки.
            let base = c.base
            var j = base.locate(lastAlong).segment
            while j < base.ends.count, base.ends[j] <= along {
                defer { j += 1 }
                guard base.ends[j] > lastAlong else { continue }
                let share = (base.ends[j] - lastAlong) / (along - lastAlong)
                let t = lastTime.addingTimeInterval(share * now.timeIntervalSince(lastTime))
                c.crossTimes[j] = t
                if j > 0, let previous = c.crossTimes[j - 1] {
                    c.live.append((t.timeIntervalSince(previous), base.median[j], base.length(of: j)))
                    // Темпу нужны последние ~2 км — хвост дальше не храним.
                    if c.live.count > 64 { c.live.removeFirst(c.live.count - 64) }
                }
                crossed = true
            }
        }
        c.lastAlong = along
        c.lastTime = now
        if crossed { c.rho = CommuteGhost.pace(live: c.live, previous: c.rho) }
        return crossed
    }

    /// Ведущий: на линии и прошёл 1,5 км по ней. Прежний остаётся, пока другой
    /// не ближе к машине на `commuteGhostSwitchMeters`; при равенстве — тот,
    /// где больше поездок (обычнее).
    private static func lead(_ candidates: [Candidate], previous: Int?) -> Int? {
        let eligible = candidates.indices.filter {
            !candidates[$0].track.isOff && candidates[$0].joined != nil
                && CommuteGhost.isConfirmed(along: candidates[$0].floor)
        }
        guard let best = eligible.min(by: { a, b in
            let (ea, eb) = (candidates[a].offsetEMA ?? .infinity, candidates[b].offsetEMA ?? .infinity)
            return ea != eb ? ea < eb : candidates[a].base.rows > candidates[b].base.rows
        }) else { return nil }
        if let previous, eligible.contains(previous),
           (candidates[previous].offsetEMA ?? .infinity) - (candidates[best].offsetEMA ?? .infinity)
               < AppConfig.commuteGhostSwitchMeters {
            return previous
        }
        return best
    }

    /// Проекция в окне линии вокруг прошлой точки; потеряли — полный проход
    /// (для далёкой линии — не чаще раза в `commuteGhostRescanStepMeters`).
    /// Пройденное не откатывается назад дальше допуска (как в свёртке профиля).
    private static func project(_ p: SIMD2<Double>, _ c: inout Candidate,
                                step: Double) -> (along: Double, offset: Double) {
        func scan(_ range: ClosedRange<Int>) -> (along: Double, offset: Double, segment: Int) {
            var best = (along: c.floor, offset: Double.infinity, segment: c.cursor)
            for i in range {
                let (q, f) = CommuteProfile.Geometry.nearest(p, c.xy[i], c.xy[i + 1])
                let along = c.cumulative[i] + f * (c.cumulative[i + 1] - c.cumulative[i])
                if along + AppConfig.commuteProfileNearMeters < c.floor { continue }
                let offset = simd_distance(p, q)
                if offset < best.offset { best = (along, offset, i) }
            }
            return best
        }
        c.sinceRescan += step
        if let far = c.farOffset, far - c.sinceRescan > AppConfig.commuteGhostRescanMeters {
            return (c.floor, far - c.sinceRescan)
        }
        let last = c.xy.count - 2
        let lo = max(0, c.cursor - 2), hi = min(last, c.cursor + AppConfig.commuteGhostWindowSegments)
        var best = scan(lo...hi)
        if best.offset <= AppConfig.commuteGhostRescanMeters {
            c.farOffset = nil
        } else if last >= 0, c.sinceRescan >= AppConfig.commuteGhostRescanStepMeters {
            c.sinceRescan = 0
            let full = scan(0...last)
            if full.offset < best.offset { best = full }
            c.farOffset = best.offset > AppConfig.commuteGhostRescanMeters ? best.offset : nil
        }
        if best.offset.isFinite {
            c.cursor = best.segment
            c.floor = max(c.floor, best.along)
        }
        return (c.floor, best.offset)
    }
}
