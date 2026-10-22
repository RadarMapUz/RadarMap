//
//  BatteryProbe.swift
//  RadarMap
//
//  Единственный владелец `isBatteryMonitoringEnabled` — флаг в UIDevice один
//  на процесс, а желающих его включить в приложении несколько.
//
//  Держать мониторинг постоянно ради двух чисел за поездку — значит будить
//  процесс системными уведомлениями впустую, поэтому он включается только на
//  время разового замера и возвращается как был. Постоянных держателей
//  (счётчик ссылок retain/release для чипов заряда) больше нет — чипы ушли,
//  вызовов не осталось (27.G, 22.10).
//

import UIKit

enum BatteryProbe {

    /// Заряд в процентах или nil, когда система его не отдаёт (симулятор).
    /// Разовое чтение: включает мониторинг, только если его никто не держит,
    /// и возвращает флаг как было.
    static func percent() -> Int? { snapshot().percent }

    /// Заряд и «стоит на зарядке» одним замером. Раздельно их читать нельзя:
    /// вне мониторинга `batteryState` отвечает `.unknown`, и проверка «не на
    /// зарядке» молча становится всегда истинной.
    static func snapshot() -> (percent: Int?, isCharging: Bool) {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        let level = device.batteryLevel
        let state = device.batteryState
        return (level >= 0 ? Int((level * 100).rounded()) : nil,
                state == .charging || state == .full)
    }
}
