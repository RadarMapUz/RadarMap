//
//  BatteryProbe.swift
//  RadarMap
//
//  Разовое чтение заряда: включить мониторинг, прочитать, вернуть как было.
//
//  Держать мониторинг постоянно ради двух чисел за поездку — значит будить
//  процесс системными уведомлениями впустую (та же политика у BatteryChip:
//  мониторинг живёт только пока чип на экране). «Вернуть как было», а не
//  «выключить»: если чип приборки уже держит мониторинг, зонд не должен
//  вырубать его из-под живого интерфейса.
//

import UIKit

enum BatteryProbe {
    /// Заряд в процентах или nil, когда система его не отдаёт (симулятор).
    static func percent() -> Int? {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }
}
