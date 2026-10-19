//
//  CommuteLiveSession.swift
//  RadarMap
//
//  Одна поездка дом↔работа на ходу (этап 8.8.2): куда мы на линии варианта,
//  сколько сегодня шли участки и когда пересчитать призрак. Чистая структура
//  без GPS и таймеров — её кормит CommuteLiveService фиксами, которые и так
//  приходят в поездке (ни одного нового запроса геопозиции).
//
//  Бюджет на фикс: проекция только в окне линии вокруг прошлой точки (полный
//  проход — лишь когда окно потеряло машину), пересчёт прогноза — на границе
//  участка или раз в 30 с, не на каждом фиксе.
//

import CoreLocation
import Foundation
import simd

nonisolated struct CommuteLiveSession: Sendable {

    /// Что увидеть и услышать после фикса.
    struct Output: Equatable, Sendable {
        let forecast: CommuteGhost.Forecast?
        let isOff: Bool
    }

    /// Вариант пути с базой и индексом линии для проекции.
    private struct Candidate: Sendable {
        let base: CommuteGhost.Baseline
        let xy: [SIMD2<Double>]
        let cumulative: [Double]
        var cursor = 0
        var floor = 0.0
    }

    private let frame: CommuteProfile.Frame
    private var candidates: [Candidate]
    /// Выбранный вариант — после подтверждения (1,5 км по его линии).
    private var locked: Int?
    private let startedAt: Date

    private var lastAlong: Double?
    private var lastTime: Date?
    private var lastPoint: SIMD2<Double>?
    private var crossTimes: [Int: Date] = [:]
    private var live: [(seconds: Double, median: Double, length: Double)] = []
    private var rho = 1.0
    private var lastForecastAt: Date?
    private var track = CommuteGhost.Track()

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
        startedAt = departure
        if built.count == 1 { locked = 0 }
    }

    /// Обычное время пути по выбранному (или первому) варианту, с.
    var usualSeconds: Double { candidates[locked ?? 0].base.total }

    mutating func note(lat: Double, lon: Double, accuracy: Double, at now: Date) -> Output {
        let p = frame.xy(lat, lon)
        let step = lastPoint.map { simd_distance($0, p) } ?? 0
        lastPoint = p

        // Пока вариант не выбран — проецируем на все (их ≤ 3) и ведём тот,
        // что ближе; подтверждение — 1,5 км по его линии.
        var projections: [(along: Double, offset: Double)] = []
        for i in candidates.indices { projections.append(Self.project(p, &candidates[i])) }
        let index = locked ?? projections.indices.min { projections[$0].offset < projections[$1].offset }!
        let (along, offset) = projections[index]
        if locked == nil, CommuteGhost.isConfirmed(along: along),
           offset <= AppConfig.commuteGhostOffMeters {
            locked = index
            // Участки, пройденные до выбора, считались по другой линии.
            crossTimes.removeAll()
            live.removeAll()
        }
        let onLine = track.update(offset: offset, accuracy: max(accuracy, 0), stepMeters: step)
        let base = candidates[index].base
        var crossed = false
        if let lastAlong, let lastTime, along > lastAlong, now > lastTime {
            // Только границы между прошлой и новой точкой — не все участки.
            var j = base.locate(lastAlong).segment
            while j < base.ends.count, base.ends[j] <= along {
                defer { j += 1 }
                guard base.ends[j] > lastAlong else { continue }
                let share = (base.ends[j] - lastAlong) / (along - lastAlong)
                let t = lastTime.addingTimeInterval(share * now.timeIntervalSince(lastTime))
                crossTimes[j] = t
                if j > 0, let previous = crossTimes[j - 1] {
                    live.append((t.timeIntervalSince(previous), base.median[j], base.length(of: j)))
                    // Темпу нужны последние ~2 км — хвост дальше не храним.
                    if live.count > 64 { live.removeFirst(live.count - 64) }
                }
                crossed = true
            }
        }
        lastAlong = along
        lastTime = now
        if crossed { rho = CommuteGhost.pace(live: live, previous: rho) }

        guard locked != nil, onLine, CommuteGhost.isConfirmed(along: along) else {
            return Output(forecast: nil, isOff: !onLine)
        }
        let due = crossed || lastForecastAt.map {
            now.timeIntervalSince($0) >= AppConfig.commuteGhostRecomputeSeconds
        } ?? true
        guard due else { return Output(forecast: nil, isOff: false) }
        lastForecastAt = now
        let forecast = CommuteGhost.forecast(base, along: along,
                                             elapsed: now.timeIntervalSince(startedAt),
                                             rho: rho, now: now)
        return Output(forecast: forecast, isOff: false)
    }

    /// Проекция в окне линии вокруг прошлой точки; потеряли — полный проход.
    /// Пройденное не откатывается назад дальше допуска (как в свёртке профиля).
    private static func project(_ p: SIMD2<Double>, _ c: inout Candidate) -> (along: Double, offset: Double) {
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
        let last = c.xy.count - 2
        let lo = max(0, c.cursor - 2), hi = min(last, c.cursor + AppConfig.commuteGhostWindowSegments)
        var best = scan(lo...hi)
        if best.offset > AppConfig.commuteGhostRescanMeters, last >= 0 {
            best = scan(0...last)
        }
        if best.offset.isFinite {
            c.cursor = best.segment
            c.floor = max(c.floor, best.along)
        }
        return (c.floor, best.offset)
    }
}
