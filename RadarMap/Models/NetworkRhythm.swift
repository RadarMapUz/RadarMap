//
//  NetworkRhythm.swift
//  RadarMap
//
//  Ритм сети в поездке. До 19.10 жили три независимых таймера: опрос
//  отметок (40/70/150 с), отправка пробок (120 с) и приём пробок (120 с) —
//  каждый будил радио в своё время, а LTE после каждого обмена ещё 5–10 с
//  держит высокое потребление (аудит энергии). Теперь пробки ходят одним
//  тактом (отправка + приём) и примыкают к уже разбуженному радио, когда
//  опрашиваются отметки.
//
//  Чистая логика — NetworkRhythmTests.
//

import Foundation

nonisolated enum NetworkRhythm {

    /// Как часто нужны пробки. На экран смотрят или ведёт маршрут — 2 мин
    /// (карта и время в пути). Экран погашен и маршрута нет — пробки нужны
    /// только фразе «впереди пробка», и 5 мин ей хватает.
    static func trafficInterval(screenOn: Bool, hasRoute: Bool) -> TimeInterval {
        screenOn || hasRoute ? AppConfig.trafficRefreshInterval : AppConfig.trafficQuietInterval
    }

    /// Радио уже разбудил другой запрос — сходить и за пробками, если их
    /// срок почти подошёл: одно пробуждение вместо двух.
    static func joinsAwakeRadio(sinceLast: TimeInterval, interval: TimeInterval) -> Bool {
        sinceLast >= interval - AppConfig.radioJoinSlackSeconds
    }
}
