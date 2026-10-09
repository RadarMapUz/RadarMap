//
//  LaneAdvice.swift
//  RadarMap
//
//  «Из двух левых рядов» — ряд полос словами.
//
//  Ряд стрелок отвечает на вопрос «куда можно с каждой полосы», но водителю
//  нужен ответ «в какой ряд встать», и считать стрелки на ходу — лишний
//  взгляд. Китайские навигаторы (Amap, Baidu) пишут это словами над рядом;
//  здесь то же, и только там, где ответ однозначен: подходящие полосы идут
//  подряд от края или посередине. Разрозненные подходящие полосы словами не
//  описать коротко — тогда говорит только ряд стрелок.
//
//  Чистая логика — LaneAdviceTests.
//

import Foundation

nonisolated enum LaneAdvice {

    /// Подсказка словами или nil (подходят все, не подходит ни одна, или
    /// подходящие разрознены).
    static func phrase(_ lanes: [LaneHint]) -> String? {
        let count = lanes.count
        let valid = lanes.indices.filter { lanes[$0].isValid }
        guard count >= 2, !valid.isEmpty, valid.count < count,
              let first = valid.first, let last = valid.last,
              last - first + 1 == valid.count else { return nil }
        let run = valid.count
        if first == 0 {
            // Все, кроме крайнего правого, — короче сказать «кроме правого».
            if run == count - 1, count >= 3 { return String(localized: "Из любого ряда, кроме правого") }
            switch run {
            case 1:  return String(localized: "Из левого ряда")
            case 2:  return String(localized: "Из двух левых рядов")
            case 3:  return String(localized: "Из трёх левых рядов")
            default: return String(localized: "Из левых рядов")
            }
        }
        if last == count - 1 {
            if run == count - 1, count >= 3 { return String(localized: "Из любого ряда, кроме левого") }
            switch run {
            case 1:  return String(localized: "Из правого ряда")
            case 2:  return String(localized: "Из двух правых рядов")
            case 3:  return String(localized: "Из трёх правых рядов")
            default: return String(localized: "Из правых рядов")
            }
        }
        return run == 1 ? String(localized: "Из среднего ряда") : String(localized: "Из средних рядов")
    }

    /// С какого расстояния показывать ряд полос. На трассе — раньше: на
    /// 90 км/ч шестьсот метров — это 24 секунды, а перестроиться через три
    /// полосы в потоке за них успевает не каждый.
    static func showDistance(speedKmh: Double) -> Double {
        speedKmh >= AppConfig.laneHighwaySpeedKmh ? AppConfig.laneRowHighwayMeters
                                                   : AppConfig.engineManeuverApproachMeters
    }
}
