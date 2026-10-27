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
