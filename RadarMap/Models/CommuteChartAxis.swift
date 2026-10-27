//
//  CommuteChartAxis.swift
//  RadarMap
//
//  Ось «Когда выезжали и сколько ехали» в «Дороге домой/на работу» (34,
//  снимок владельца 27.10): два выезда в 11:30 растягивали ось до 11:30–18:30,
//  сорок точек прижимались к правому краю, а подписи через каждые полчаса
//  налезали друг на друга («11:3012:0012:30…»).
//
//  Правила:
//    * ось — по основной массе выездов: всё, что дальше
//      `commuteChartCoreSpanMinutes` от медианы выезда, — отдельный случай
//      (обед, забрать ребёнка), и он называется подписью под графиком, а не
//      растягивает ось для остальных;
//    * если основной массы нет (выезды и правда разбросаны), ось — по всем;
//    * окно-совет всегда на оси — ради него график и смотрят;
//    * шаг подписей — по ширине оси: не больше `commuteChartMaxLabels`
//      подписей, шаги от 30 минут до 6 часов.
//
//  Чистая логика — CommuteChartAxisTests.
//

import Foundation

nonisolated enum CommuteChartAxis {

    struct Layout: Equatable, Sendable {
        /// Минуты от полуночи: края оси, кратные шагу.
        let domain: ClosedRange<Int>
        /// Шаг подписей оси, минуты.
        let stride: Int
        /// Индексы выездов, которые на ось не попали (по возрастанию).
        let outside: [Int]
    }

    static let strides = [30, 60, 120, 180, 240, 360]

    /// `departures` — минуты от полуночи каждого выезда, в любом порядке;
    /// `window` — окно-совет (начало и конец, минуты), если есть.
    static func layout(departures: [Int], window: ClosedRange<Int>? = nil,
                       coreSpan: Int = AppConfig.commuteChartCoreSpanMinutes,
                       maxLabels: Int = AppConfig.commuteChartMaxLabels) -> Layout {
        guard !departures.isEmpty else {
            let base = window ?? 0...60
            let low = base.lowerBound / 30 * 30
            return Layout(domain: low...max(low + 60, roundUp(base.upperBound, to: 30)),
                          stride: 30, outside: [])
        }
        let sorted = departures.sorted()
        let median = sorted[sorted.count / 2]
        var core = departures.indices.filter { abs(departures[$0] - median) <= coreSpan }
        // Основная масса — это больше половины выездов. Иначе «выброс» —
        // вовсе не выброс, а разброс, и прятать его с оси нельзя.
        if core.count * 2 <= departures.count { core = Array(departures.indices) }
        var minutes = core.map { departures[$0] }
        if let window { minutes += [window.lowerBound, window.upperBound] }
        let low = minutes.min()!, high = minutes.max()!
        // Шаг подбирается по ширине; края оси — кратны шагу, чтобы первая и
        // последняя подписи были ровными часами, а не «18:12».
        var step = strides.last!
        var domain = 0...0
        for candidate in strides {
            let start = low / candidate * candidate
            let end = max(roundUp(high, to: candidate), start + candidate)
            if (end - start) / candidate + 1 <= maxLabels {
                step = candidate
                domain = start...end
                break
            }
        }
        if domain == 0...0 {
            let start = low / step * step
            domain = start...max(roundUp(high, to: step), start + step)
        }
        let outside = departures.indices.filter { !domain.contains(departures[$0]) }
        return Layout(domain: domain, stride: step, outside: outside)
    }

    private static func roundUp(_ value: Int, to step: Int) -> Int {
        (value + step - 1) / step * step
    }
}
