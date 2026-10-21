//
//  ArrivalTail.swift
//  RadarMap
//
//  Прибытие на последних километрах — не оптимистичнее того, как мы едем.
//
//  Остаток времени маршрута — линейная доля времени OSRM (RouteService.
//  engineRemaining): граф считает последние 1–2 км по скоростям свободной
//  дороги, а в городе там светофоры, разворот, поиск въезда. Снимок 63
//  (21.10): 0,7 км на 10 км/ч, а карточка CarPlay пишет «19:40 прибытие» —
//  то есть сейчас. На последних километрах время берётся не меньше, чем
//  остаток, делённый на нашу среднюю скорость за последние ~2 минуты.
//
//  Только для маршрута движка: личный остаток дороги на работу (призрак,
//  RouteService.personalRemaining) считается по своим поездкам отдельно и
//  здесь не трогается. Чистая логика; ArrivalTailTests.
//

import Foundation

nonisolated enum ArrivalTail {

    /// Средняя скорость за последние `window` секунд по фиксам.
    ///
    /// Средняя по ВРЕМЕНИ, а не по фиксам: на стоянке у светофора фиксы
    /// приходят реже (или не приходят вовсе), и среднее по фиксам забыло бы
    /// стоянку. Каждый отрезок между фиксами взвешен своей длительностью и
    /// скоростью начала отрезка; последний — до «сейчас».
    struct Pace: Equatable, Sendable {
        private(set) var samples: [Sample] = []

        struct Sample: Equatable, Sendable {
            let time: Date
            /// м/с
            let speed: Double
        }

        /// Отметить фикс. Старше окна — выбрасываются (одна точка до окна
        /// остаётся: она задаёт скорость начала окна).
        mutating func add(speedKmh: Double, at time: Date,
                          window: TimeInterval = AppConfig.arrivalTailPaceWindowSeconds) {
            guard speedKmh.isFinite else { return }
            if let last = samples.last, time < last.time { samples.removeAll() }
            samples.append(Sample(time: time, speed: max(0, speedKmh) / 3.6))
            let start = time.addingTimeInterval(-window)
            while samples.count > 1, samples[1].time <= start { samples.removeFirst() }
        }

        mutating func reset() { samples.removeAll() }

        /// м/с за окно; nil — наблюдали меньше `minimum` секунд (только что
        /// тронулись, перестроение): по 10 секундам о темпе квартала не судят.
        func average(now: Date,
                     window: TimeInterval = AppConfig.arrivalTailPaceWindowSeconds,
                     minimum: TimeInterval = AppConfig.arrivalTailPaceMinSeconds) -> Double? {
            guard let first = samples.first else { return nil }
            let start = max(first.time, now.addingTimeInterval(-window))
            let span = now.timeIntervalSince(start)
            guard span >= minimum else { return nil }
            var distance = 0.0
            for (index, sample) in samples.enumerated() {
                let from = max(sample.time, start)
                let to = index + 1 < samples.count ? samples[index + 1].time : now
                guard to > from else { continue }
                distance += sample.speed * to.timeIntervalSince(from)
            }
            return distance / span
        }
    }

    /// Остаток времени с поправкой на последние километры.
    ///
    /// Дальше `fromMeters` — время движка как есть. Ближе — не меньше, чем
    /// остаток по нашей средней скорости (снизу ограниченной `floorKmh`:
    /// две минуты в пробке не превращают 1,5 км в час пути). Вес поправки
    /// растёт от 0 на `fromMeters` до 1 на `fullMeters` — прибытие не
    /// прыгает на границе. Только в сторону «позже»: быстрее движка не
    /// обещаем никогда.
    static func remaining(engine: TimeInterval, remainingMeters: Double, paceMps: Double?,
                          fromMeters: Double = AppConfig.arrivalTailFromMeters,
                          fullMeters: Double = AppConfig.arrivalTailFullMeters,
                          floorKmh: Double = AppConfig.arrivalTailPaceFloorKmh) -> TimeInterval {
        guard let paceMps, paceMps.isFinite, remainingMeters > 0, remainingMeters < fromMeters
        else { return engine }
        let pace = max(paceMps, floorKmh / 3.6)
        let honest = remainingMeters / pace
        guard honest > engine else { return engine }
        let weight = min(1, max(0, (fromMeters - remainingMeters) / max(1, fromMeters - fullMeters)))
        return engine + (honest - engine) * weight
    }
}
