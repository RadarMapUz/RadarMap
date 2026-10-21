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
        run(lanes).map(text(for:))
    }

    /// Какой ряд назвать — типом: записанный голос (этап 16) говорит его
    /// отрывком, а не текстом.
    static func run(_ lanes: [LaneHint]) -> VoiceEvent.LaneRun? {
        let count = lanes.count
        let valid = lanes.indices.filter { lanes[$0].isValid }
        guard count >= 2, !valid.isEmpty, valid.count < count,
              let first = valid.first, let last = valid.last,
              last - first + 1 == valid.count else { return nil }
        let run = valid.count
        if first == 0 {
            // Все, кроме крайнего правого, — короче сказать «кроме правого».
            if run == count - 1, count >= 3 { return .allButRight }
            switch run {
            case 1:  return .leftOne
            case 2:  return .leftTwo
            case 3:  return .leftThree
            default: return .leftMany
            }
        }
        if last == count - 1 {
            if run == count - 1, count >= 3 { return .allButLeft }
            switch run {
            case 1:  return .rightOne
            case 2:  return .rightTwo
            case 3:  return .rightThree
            default: return .rightMany
            }
        }
        return run == 1 ? .middleOne : .middleMany
    }

    static func text(for run: VoiceEvent.LaneRun) -> String {
        switch run {
        case .leftOne:     return String(localized: "Из левого ряда")
        case .leftTwo:     return String(localized: "Из двух левых рядов")
        case .leftThree:   return String(localized: "Из трёх левых рядов")
        case .leftMany:    return String(localized: "Из левых рядов")
        case .rightOne:    return String(localized: "Из правого ряда")
        case .rightTwo:    return String(localized: "Из двух правых рядов")
        case .rightThree:  return String(localized: "Из трёх правых рядов")
        case .rightMany:   return String(localized: "Из правых рядов")
        case .allButRight: return String(localized: "Из любого ряда, кроме правого")
        case .allButLeft:  return String(localized: "Из любого ряда, кроме левого")
        case .middleOne:   return String(localized: "Из среднего ряда")
        case .middleMany:  return String(localized: "Из средних рядов")
        }
    }

    /// С какого расстояния показывать ряд полос. На трассе — раньше: на
    /// 90 км/ч шестьсот метров — это 24 секунды, а перестроиться через три
    /// полосы в потоке за них успевает не каждый.
    static func showDistance(speedKmh: Double) -> Double {
        speedKmh >= AppConfig.laneHighwaySpeedKmh ? AppConfig.laneRowHighwayMeters
                                                   : AppConfig.engineManeuverApproachMeters
    }
}
