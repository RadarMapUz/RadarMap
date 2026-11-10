//
//  RouteTimeline.swift
//  RadarMap
//
//  Время вдоль маршрута (76). Остаток времени считался долей расстояния:
//  «осталось 10 % пути — осталось 10 % времени». На маршруте трасса + город
//  это враньё в обе стороны: на трассе прибытие позже настоящего, а в
//  городском хвосте 10 км при 30 км/ч показывались как 10 км трассы.
//
//  OSRM отдаёт длительность каждого шага — из них кумулятив времени по
//  линии: узел на начале каждого шага, внутри шага — по расстоянию. Наружу —
//  ДОЛЯ времени графа на остатке пути: на старте ровно 1, так что остаток на
//  старте — по-прежнему время варианта. Нет длительностей (Apple, свой граф
//  трасс) — линейная доля, как раньше. Чистая логика, RouteTimelineTests.
//

import Foundation

nonisolated struct RouteTimeline: Equatable, Sendable {
    /// Узлы: метры от старта по линии и секунды графа до них; не убывают.
    let along: [Double]
    let time: [Double]

    /// `starts` — начала шагов по линии, `durations` — их длительности,
    /// `length` — длина линии. nil — длительностей нет или они негодны.
    init?(starts: [Double], durations: [Double?], length: Double) {
        guard !starts.isEmpty, starts.count == durations.count, length > 0, length.isFinite else { return nil }
        var along: [Double] = [], time: [Double] = []
        var elapsed = 0.0, last = 0.0
        for (start, duration) in zip(starts, durations) {
            guard let duration, duration.isFinite, duration >= 0, start.isFinite else { return nil }
            last = min(max(start, last), length)
            along.append(last)
            time.append(elapsed)
            elapsed += duration
        }
        guard elapsed > 0 else { return nil }
        along.append(length)
        time.append(elapsed)
        self.along = along
        self.time = time
    }

    /// Доля времени графа после `traveled` метров: 1 на старте, 0 в конце.
    func remainingShare(after traveled: Double) -> Double {
        guard let total = time.last, total > 0, along.count == time.count, along.count >= 2 else { return 0 }
        let at = min(max(0, traveled), along[along.count - 1])
        // Последний узел не дальше `at`.
        var lo = 0, hi = along.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if along[mid] <= at { lo = mid } else { hi = mid }
        }
        let span = along[hi] - along[lo]
        let passed = span > 0 ? time[lo] + (at - along[lo]) / span * (time[hi] - time[lo])
                              : (at >= along[hi] ? time[hi] : time[lo])
        return min(1, max(0, 1 - passed / total))
    }

    /// Доля времени графа на остатке пути: по кумулятиву, без него — доля
    /// расстояния.
    static func remainingShare(_ timeline: RouteTimeline?, distance: Double, remainingDistance: Double) -> Double {
        guard distance > 0 else { return 0 }
        guard let timeline else { return min(1, max(0, remainingDistance / distance)) }
        return timeline.remainingShare(after: distance - remainingDistance)
    }
}
