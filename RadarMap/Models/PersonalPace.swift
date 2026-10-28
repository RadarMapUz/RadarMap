//
//  PersonalPace.swift
//  RadarMap
//
//  Личный темп (33E, docs/spec_traffic_33.md): как быстро ездите вы сами
//  относительно потока — по своим поездкам по маршруту, только на телефоне.
//
//  Наблюдение — проезд по выбранному варианту маршрута (не короче
//  `personalPaceMinSampleMeters`): метры, своё время, время потока на эти
//  метры (время варианта по графу — `travelTime` OSRM, ту же основу ETA мы и
//  поправляем) и класс дороги. Класс — «город» или «трасса» по средней
//  скорости графа варианта: у телефона нет класса каждого ребра маршрута, а
//  городская и трассовая манера езды различаются сильнее всего остального.
//  Проезд с пробкой (задержка пробками больше `personalPaceJamShare` времени
//  графа) — не наблюдение: спецификация берёт только свободный поток.
//
//  Коэффициент — во сколько раз своё время больше времени потока (меньше 1 —
//  вы быстрее): медиана отношений за `personalPaceWindowDays`, годна при
//  `personalPaceMinKm` км выборки; класс без своих 50 км — общий
//  коэффициент; мало данных — 1. Итог в пределах 0,85…1,15. Отношение вне
//  0,5…2 — не манера езды, а стоянка по пути или сбой трека: такое
//  наблюдение не берётся (сверх спецификации, чтобы заезд в магазин не
//  делал «медленным водителем»).
//
//  Применяется ко всем показанным временам варианта (решение 28.10: крупная
//  цифра, флажок прибытия, остаток в пути, машина, «Поделиться прибытием» —
//  `RouteService.Variant.paceFactor`/`shownTime`, `remainingTime`), но не к
//  выбору пути и не к мерке объезда: темп одинаков для всех вариантов. Ничего не уходит на сервер; «Учитывать мою манеру езды» —
//  выключение стирает наблюдения.
//
//  Чистая логика, время — параметром; покрыто PersonalPaceTests.
//

import Foundation

nonisolated enum PersonalPace {

    enum RoadClass: String, Codable, Sendable, CaseIterable {
        case city, highway
    }

    struct Sample: Codable, Equatable, Sendable {
        let date: Date
        let roadClass: RoadClass
        let meters: Double
        let ownSeconds: Double
        let flowSeconds: Double
        /// На проезде была пробка — не свободный поток.
        let jam: Bool

        var ratio: Double { flowSeconds > 0 ? ownSeconds / flowSeconds : 1 }
    }

    struct Coefficients: Equatable, Sendable {
        var overall: Double = 1
        var byClass: [RoadClass: Double] = [:]

        static let neutral = Coefficients()

        /// Коэффициент класса; класса нет или у него нет своих данных — общий.
        func factor(for roadClass: RoadClass?) -> Double {
            roadClass.flatMap { byClass[$0] } ?? overall
        }
    }

    /// Класс дороги варианта по средней скорости графа.
    static func roadClass(distance: Double, travelTime: TimeInterval) -> RoadClass {
        guard travelTime > 0 else { return .city }
        return distance / travelTime * 3.6 >= AppConfig.personalPaceHighwayKmh ? .highway : .city
    }

    static func clipped(_ value: Double) -> Double {
        min(AppConfig.personalPaceMax, max(AppConfig.personalPaceMin, value))
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Наблюдения, которые идут в расчёт: свежие, без пробки, разумные.
    static func usable(_ samples: [Sample], now: Date) -> [Sample] {
        let since = now.addingTimeInterval(-AppConfig.personalPaceWindowDays * 86400)
        return samples.filter {
            $0.date >= since && $0.date <= now.addingTimeInterval(3600) && !$0.jam && $0.flowSeconds > 0
                && $0.meters > 0 && (0.5...2.0).contains($0.ratio)
        }
    }

    static func coefficients(_ samples: [Sample], now: Date) -> Coefficients {
        let good = usable(samples, now: now)
        let minMeters = AppConfig.personalPaceMinKm * 1000
        guard good.reduce(0, { $0 + $1.meters }) >= minMeters,
              let overall = median(good.map(\.ratio)) else { return .neutral }
        var out = Coefficients(overall: clipped(overall))
        for roadClass in RoadClass.allCases {
            let own = good.filter { $0.roadClass == roadClass }
            if own.reduce(0, { $0 + $1.meters }) >= minMeters, let value = median(own.map(\.ratio)) {
                out.byClass[roadClass] = clipped(value)
            }
        }
        return out
    }

    /// Хранимые наблюдения после нового: окно и потолок числа.
    static func appending(_ sample: Sample, to samples: [Sample], now: Date) -> [Sample] {
        let since = now.addingTimeInterval(-AppConfig.personalPaceWindowDays * 86400)
        return Array((samples + [sample]).filter { $0.date >= since }.suffix(AppConfig.personalPaceMaxSamples))
    }

    // MARK: - Проезд по варианту

    /// Копит проезд по одному варианту маршрута: с какого места и момента
    /// начали, докуда и когда доехали. Один вариант — одно наблюдение; смена
    /// варианта (перестроение, выбор другого) закрывает прежнее.
    struct Tracker: Sendable {
        /// Описание варианта для закрытия наблюдения.
        struct Variant: Equatable, Sendable {
            let id: Int
            let distance: Double
            let travelTime: TimeInterval
            let trafficDelay: TimeInterval?
        }

        private(set) var current: Variant?
        private var startAlong = 0.0
        private var startTime = Date.distantPast
        private var lastAlong = 0.0
        private var lastTime = Date.distantPast

        /// Отметить прогресс по варианту. Вариант сменился — вернёт наблюдение
        /// прежнего (или nil, если оно не годится).
        mutating func note(_ variant: Variant, along: Double, at time: Date) -> Sample? {
            var closed: Sample?
            if current?.id != variant.id {
                closed = finish()
                current = variant
                startAlong = along
                startTime = time
                lastAlong = along
                lastTime = time
            } else if along >= lastAlong {
                lastAlong = along
                lastTime = time
            }
            return closed
        }

        /// Закрыть наблюдение (прибытие, снятие маршрута, смена варианта).
        mutating func finish() -> Sample? {
            defer { reset() }
            guard let variant = current, variant.distance > 0, variant.travelTime > 0 else { return nil }
            let meters = lastAlong - startAlong
            let own = lastTime.timeIntervalSince(startTime)
            guard meters >= AppConfig.personalPaceMinSampleMeters, own > 0 else { return nil }
            let flow = variant.travelTime * meters / variant.distance
            let jam = (variant.trafficDelay ?? 0) > variant.travelTime * AppConfig.personalPaceJamShare
            return Sample(date: lastTime, roadClass: PersonalPace.roadClass(distance: variant.distance,
                                                                          travelTime: variant.travelTime),
                          meters: meters, ownSeconds: own, flowSeconds: flow, jam: jam)
        }

        mutating func reset() {
            current = nil
            startAlong = 0
            lastAlong = 0
            startTime = .distantPast
            lastTime = .distantPast
        }
    }
}
