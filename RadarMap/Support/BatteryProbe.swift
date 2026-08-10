//
//  BatteryProbe.swift
//  RadarMap
//
//  Единственный владелец `isBatteryMonitoringEnabled` — флаг в UIDevice один
//  на процесс, а желающих его включить в приложении несколько.
//
//  Держать мониторинг постоянно ради двух чисел за поездку — значит будить
//  процесс системными уведомлениями впустую, поэтому он живёт только пока
//  кому-то действительно нужен. Но «выключить у себя в onDisappear» здесь не
//  работает: чипов заряда на экране бывает два (приборка и HUD карты), и
//  уходящий гасит мониторинг под живым соседом — тот застывает на последнем
//  прочитанном проценте. Отсюда счётчик ссылок: гасим на нуле, а не на первом
//  ушедшем.
//

import UIKit

enum BatteryProbe {

    private static var holders = 0

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

    /// Взять мониторинг под живой интерфейс (чип на экране). Парная `release`
    /// обязательна — иначе флаг останется висеть на весь запуск.
    static func retain() {
        holders += 1
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    static func release() {
        holders = max(0, holders - 1)
        if holders == 0 { UIDevice.current.isBatteryMonitoringEnabled = false }
    }
}
