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
//  только если оно заметно хуже его медианы (на четверть, 24.3; прежний q75
//  при широком своём разбросе пропускал настоящие пробки); иначе остаётся
//  медиана. Свободные рёбра ничего не
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

    /// Оценка при выезде в `now`: вариант, чья выборка ближе к этому часу
    /// (окно ±60 лучше ±120), при равенстве — богаче, затем недавний; его
    /// медиана плюс пробки заметно хуже неё. nil — у этого часа нет трёх поездок в
    /// окне ±120 мин: медиана всего дня — не «сейчас», и строка остаётся при
    /// «обычно» за месяц. Округлено до минут: пересчёт по новым пробкам не
    /// трогает строку, пока цифра на ней та же.
    /// Выборка и база — те же, что у призрака в пути (24.2): веса по близости
    /// выезда, поправка на светофоры и сдвиг журнала `bias`; иначе «сейчас
    /// ~44 мин» до выезда и прибытие через минуту после него расходились бы.
    static func beforeDeparture(variants: [CommuteProfile.Variant], now: Date,
                                snapshot: TrafficSnapshot?, bias: Double = 1,
                                calendar: Calendar = .current) -> Estimate? {
        let weekend = UzHolidays.isDayOff(now, calendar: calendar)
        var best: (variant: CommuteProfile.Variant, base: CommuteGhost.Baseline, tier: CommuteGhost.RowTier)?
        for variant in variants {
            guard let selected = CommuteGhost.select(variant.rows, weekend: weekend, departure: now,
                                                     calendar: calendar),
                  selected.tier < .allDay,
                  let base = CommuteGhost.calibratedBaseline(variant, selection: selected, bias: bias)
            else { continue }
            if let current = best {
                let better: Bool
                if selected.tier != current.tier {
                    better = selected.tier < current.tier
                } else if base.rows != current.base.rows {
                    better = base.rows > current.base.rows
                } else {
                    better = variant.lastUsed > current.variant.lastUsed
                }
                guard better else { continue }
            }
            best = (variant, base, selected.tier)
        }
        guard let best else { return nil }
        var jam = 0.0
        if let snapshot, snapshot.isFresh(now: now) {
            jam = jamExtra(best.base, crowd: crowdSeconds(line: best.variant.coordinates, base: best.base,
                                                          snapshot: snapshot))
        }
        // Обе части — в целых минутах, и сумма сходится с тем, что видно:
        // «сейчас ~52 мин, пробки +8 мин» = обычные 44 + 8.
        let jamMinutes = (jam / 60).rounded() * 60
        return Estimate(seconds: (best.base.total / 60).rounded() * 60 + jamMinutes, jamSeconds: jamMinutes)
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
                guard let edge = snapshot.matchingEdge(at: point, course: course), edge.level >= 2,
                      Self.liesAlong(point, edge) else { continue }
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

    /// Шаг засчитывается пробке, только если его точка проецируется ВНУТРЬ
    /// ребра: допуск в 18 м по месту продлевал бы каждое ребро на 18 м за
    /// концы, и 50 м пробки на углу считались бы как 75 (ревью 19.10).
    static func liesAlong(_ p: CLLocationCoordinate2D, _ edge: TrafficEdge) -> Bool {
        let k = cos(p.latitude * .pi / 180) * 111_320
        let ax = (edge.a.longitude - p.longitude) * k, ay = (edge.a.latitude - p.latitude) * 111_320
        let dx = (edge.b.longitude - edge.a.longitude) * k, dy = (edge.b.latitude - edge.a.latitude) * 111_320
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return false }
        let t = -(ax * dx + ay * dy) / len2
        return t >= 0 && t <= 1
    }

    /// Пробки сверх обычного с участка `segment` до конца: участок, где по
    /// пробкам выходит хуже своей медианы на `commuteCrowdOverMedian` (24.3 —
    /// тот же порог, что у призрака в пути), добавляет разницу с медианой;
    /// остальные — 0.
    static func jamExtra(_ base: CommuteGhost.Baseline, crowd: [Double?], from segment: Int = 0) -> Double {
        var extra = 0.0
        for j in max(0, segment)..<min(crowd.count, base.median.count) {
            guard let time = crowd[j], time > base.median[j] * AppConfig.commuteCrowdOverMedian else { continue }
            extra += time - base.median[j]
        }
        return extra
    }
}
