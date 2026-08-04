//
//  Log.swift
//  RadarMap
//
//  Единая точка логирования: os.Logger по подсистемам. В проде записи видны
//  в Console.app / sysdiagnose — ошибки не исчезают бесследно, как с try?.
//

import os

// nonisolated: Logger потокобезопасен, логировать нужно и из @concurrent-кода
// (декодирование базы) без прыжка на главный актор.
nonisolated enum Log {
    private static let subsystem = "uz.radarmap.ios"

    /// GPS, поездки, проезды камер.
    static let location = Logger(subsystem: subsystem, category: "location")
    /// База камер: загрузка, декодирование, OTA-синк.
    static let cameras = Logger(subsystem: subsystem, category: "cameras")
    /// История поездок: персистентность, чистка, миграции.
    static let trips = Logger(subsystem: subsystem, category: "trips")
    /// Маршруты и лимиты скорости.
    static let route = Logger(subsystem: subsystem, category: "route")
    /// Сеть: запросы к серверу RadarMap.
    static let network = Logger(subsystem: subsystem, category: "network")
    /// Звук, голос, уведомления, Live Activity.
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
    /// Общее: настройки, виджеты, прочее.
    static let app = Logger(subsystem: subsystem, category: "app")
}
