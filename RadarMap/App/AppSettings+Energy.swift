//
//  AppSettings+Energy.swift
//  RadarMap
//
//  Выбор машины (21.10): тип и ответ на «ваш гибрид заряжается от розетки?».
//

import Foundation

extension AppSettings {
    /// Гибрид настроен до 21.10, когда гибрид был один: пока водитель не
    /// ответил, считаем его гибридом с розеткой — так было и раньше.
    var needsHybridQuestion: Bool {
        vehicleEnergy == .hybrid && fuelProfile.hybridPlugConfirmed != true
    }

    /// Тип выбран в новом выборе — вопрос про розетку больше не нужен.
    func chooseVehicle(_ energy: VehicleEnergy) {
        vehicleEnergy = energy
        if fuelProfile.hybridPlugConfirmed != true { fuelProfile.hybridPlugConfirmed = true }
    }

    /// Ответ на вопрос про розетку: да — с розеткой, нет — без.
    func answerHybridPlug(_ plugs: Bool) {
        chooseVehicle(plugs ? .hybrid : .hev)
    }

    /// Правка одного числа профиля (цена — с отметкой времени).
    func update(_ number: EnergyNumber, to value: Double) {
        var profile = fuelProfile
        number.set(value, in: &profile, now: Date())
        if profile != fuelProfile { fuelProfile = profile }
    }
}
