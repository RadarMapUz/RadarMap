//
//  TrafficArrivalGate.swift
//  RadarMap
//
//  Пробки, пришедшие во время сборки маршрута, не теряются.
//
//  Профиль часа недели (33C, traffic/profile.json) и файлы «обычно» (27.E)
//  маршрут просит сам, в начале сборки (`prefetchProfile`/`prefetchTypical`),
//  и они приходят, пока сборка считает камеры по коридору. Пересчёт времени
//  вариантов в этот момент делать нельзя — варианты ещё старые или пустые, — и
//  до 27.10 он просто пропускался: первый маршрут после запуска показывал
//  «24 мин, без пробок», а в пути по тому же профилю было 33 мин (симуляция
//  пробок, docs/traffic_simulation_2026-10-27.md). Теперь пришедшее во время
//  сборки откладывается и досчитывается один раз, когда варианты записаны.
//
//  Чистая логика; покрыто TrafficArrivalGateTests.
//

import Foundation

nonisolated struct TrafficArrivalGate: Equatable, Sendable {
    private(set) var pending = false

    /// Пришли данные пробок. true — пересчитать время вариантов сейчас;
    /// false — идёт сборка, пересчёт отложен до её конца.
    mutating func arrived(whileBuilding building: Bool) -> Bool {
        guard building else { return true }
        pending = true
        return false
    }

    /// Варианты новой сборки записаны. true — за время сборки что-то пришло:
    /// пересчитать один раз (сколько бы раз ни пришло).
    mutating func buildFinished() -> Bool {
        defer { pending = false }
        return pending
    }
}
