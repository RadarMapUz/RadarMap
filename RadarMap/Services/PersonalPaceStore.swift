//
//  PersonalPaceStore.swift
//  RadarMap
//
//  Наблюдения личного темпа (33E, PersonalPace) — на телефоне, в Storage, окно
//  30 дней. Ничего не уходит на сервер. Выключатели: «Учитывать мою манеру
//  езды» (выключение стирает наблюдения) и пульт `features.traffic` —
//  `isEnabled`.
//

import Foundation
import os

@MainActor
final class PersonalPaceStore {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private(set) var samples: [PersonalPace.Sample]
    private(set) var coefficients: PersonalPace.Coefficients

    /// Настройка включена и пробки не погашены пультом; ставит AppEnvironment.
    var isEnabled: () -> Bool = { true }

    init(now: Date = Date()) {
        let stored = Storage.decoded([PersonalPace.Sample].self, for: .personalPaceSamples) ?? []
        samples = stored
        coefficients = PersonalPace.coefficients(stored, now: now)
        #if DEBUG
        // `-demoPace 1.12` — демо-история личного темпа (симуляция пробок,
        // docs/traffic_simulation_2026-10-27.md): шесть городских проездов по
        // 10 км за прошлую неделю с этим отношением своё/граф. Только в памяти.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-demoPace"), index + 1 < args.count, let k = Double(args[index + 1]) {
            samples = (1...6).map { day in
                PersonalPace.Sample(date: now.addingTimeInterval(-Double(day) * 86400), roadClass: .city,
                                    meters: 10_000, ownSeconds: 1200 * k, flowSeconds: 1200, jam: false)
            }
            coefficients = PersonalPace.coefficients(samples, now: now)
            Log.app.info("личный темп: демо k \(self.coefficients.overall, privacy: .public)")
        }
        #endif
    }

    func add(_ sample: PersonalPace.Sample, now: Date = Date()) {
        guard isEnabled() else { return }
        samples = PersonalPace.appending(sample, to: samples, now: now)
        Storage.encode(samples, for: .personalPaceSamples)
        coefficients = PersonalPace.coefficients(samples, now: now)
        Log.app.info("личный темп: наблюдение \(Int(sample.meters), privacy: .public) м, k \(self.coefficients.overall, privacy: .public)")
    }

    /// Поправка к времени прибытия по классу дороги; выключено — 1.
    func factor(for roadClass: PersonalPace.RoadClass) -> Double {
        isEnabled() ? coefficients.factor(for: roadClass) : 1
    }

    /// Стереть расчёт (настройка выключена).
    func erase() {
        samples = []
        coefficients = .neutral
        Storage.remove(.personalPaceSamples)
    }
}
