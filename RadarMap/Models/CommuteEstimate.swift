//
//  CommuteEstimate.swift
//  RadarMap
//
//  «Сейчас на работу ~44 мин» до выезда (план 19.10, 8.8.6) и пробки на
//  своём пути (8.8.10): медиана водителя на ЭТОТ час и день недели плюс
//  сегодняшние пробки из now.json, наложенные на линию варианта.
//
//  Всё на телефоне: now.json скачан целиком, линия пути и время выезда
//  наружу не уходят (8.0).
//
//  Пробки без двойного счёта: медиана водителя в восемь утра уже содержит
//  обычную восьмичасовую пробку. Поэтому участок берёт время по пробкам,
//  только если оно хуже его q75 — то есть сегодня хуже, чем бывает в трёх
//  случаях из четырёх; иначе остаётся медиана. Свободные рёбра ничего не
//  убавляют: «сегодня пусто» по нескольким кускам — не повод обещать
//  приезд раньше обычного.
//

import CoreLocation
import Foundation
import simd

nonisolated enum CommuteEstimate {

    struct Estimate: Equatable, Sendable {
        /// Ожидаемое время в пути при выезде сейчас, с.
        let seconds: Double
        /// Сколько из них — сегодняшние пробки сверх обычного, с.
        let jamSeconds: Double
    }

    /// Оценка при выезде в `now`: вариант с самой богатой выборкой на этот час
    /// (при равенстве — недавний), его медиана, плюс пробки сверх q75.
    /// nil — профиль на этот час не набран (меньше трёх поездок).
    static func beforeDeparture(variants: [CommuteProfile.Variant], now: Date,
                                snapshot: TrafficSnapshot?, calendar: Calendar = .current) -> Estimate? {
        let weekend = calendar.isDateInWeekend(now)
        let minute = CommuteProfile.minuteOfDay(now, calendar: calendar)
        var best: (variant: CommuteProfile.Variant, base: CommuteGhost.Baseline)?
        for variant in variants {
            guard let rows = CommuteGhost.selectRows(variant.rows, weekend: weekend,
                                                     departureMinute: minute, calendar: calendar),
                  let base = CommuteGhost.baseline(ends: variant.ends, limitKmh: variant.limitKmh, rows: rows)
            else { continue }
            if let current = best {
                let richer = base.rows != current.base.rows ? base.rows > current.base.rows
                                                            : variant.lastUsed > current.variant.lastUsed
                guard richer else { continue }
            }
            best = (variant, base)
        }
        guard let best else { return nil }
        let variant = best.variant, base = best.base
        var jam = 0.0
        if let snapshot, snapshot.isFresh(now: now) {
            jam = jamExtra(base, crowd: crowdSeconds(line: variant.coordinates, base: base, snapshot: snapshot))
        }
        return Estimate(seconds: base.total + jam, jamSeconds: jam)
    }

    /// Время по пробкам на каждом участке линии; nil — пробки на участке не
    /// видно (меньше трети его длины легло на медленные рёбра). Линия идёт
    /// шагами ~25 м, шаг ловит ребро по месту и направлению — то же правило,
    /// что у пробок на маршруте (TrafficSnapshot.matchingEdge).
    static func crowdSeconds(line: [CLLocationCoordinate2D], base: CommuteGhost.Baseline,
                             snapshot: TrafficSnapshot) -> [Double?] {
        let n = base.ends.count
        guard line.count >= 2, n > 0, !snapshot.edges.isEmpty else { return [Double?](repeating: nil, count: n) }
        let frame = CommuteProfile.Frame(latitude: line[0].latitude)
        var jamTime = [Double](repeating: 0, count: n)
        var matched = [Double](repeating: 0, count: n)
        var along = 0.0
        for (p, q) in zip(line, line.dropFirst()) {
            let length = simd_distance(frame.xy(p.latitude, p.longitude), frame.xy(q.latitude, q.longitude))
            guard length > 0.5 else { continue }
            let course = GeoMath.bearing(from: p, to: q)
            let steps = max(1, Int((length / AppConfig.commuteJamStepMeters).rounded(.up)))
            let step = length / Double(steps)
            for s in 0..<steps {
                let t = (Double(s) + 0.5) / Double(steps)
                guard along + t * length <= base.length else { break }
                let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                   longitude: p.longitude + (q.longitude - p.longitude) * t)
                guard let edge = snapshot.matchingEdge(at: point, course: course), edge.level >= 2 else { continue }
                let j = base.locate(along + t * length).segment
                jamTime[j] += step / (max(3, edge.kmh) / 3.6)
                matched[j] += step
            }
            along += length
        }
        return (0..<n).map { j in
            let len = base.length(of: j)
            guard len > 0, matched[j] >= len * AppConfig.commuteJamMinShare else { return nil }
            let rest = max(0, len - matched[j]) / len
            return jamTime[j] + rest * base.median[j]
        }
    }

    /// Пробки сверх обычного с участка `segment` до конца: участок, где по
    /// пробкам выходит хуже q75, добавляет разницу с медианой; остальные — 0.
    static func jamExtra(_ base: CommuteGhost.Baseline, crowd: [Double?], from segment: Int = 0) -> Double {
        var extra = 0.0
        for j in max(0, segment)..<min(crowd.count, base.median.count) {
            guard let time = crowd[j], time > base.q75[j] else { continue }
            extra += time - base.median[j]
        }
        return extra
    }
}
