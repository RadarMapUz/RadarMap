//
//  MapStatusPick.swift
//  RadarMap
//
//  Какой баннер «почему не в полную силу» показать над картой — и какой
//  подождать до остановки (план 19.10, 5.2).
//
//  За рулём баннер — это взгляд с дороги. Объявление сервера, перегрев и
//  незагруженные лимиты ничего не просят сделать прямо сейчас и подождут
//  остановки. Остаётся одно: «нет сети — камеры предупреждают» — без него
//  серая карта на трассе читается как «приложение сломалось», а это ровно
//  тот момент, когда водитель решает, верить ли предупреждениям. И его в
//  поездке — одной строкой, без пояснения и кнопки «Скачать область».
//  Потеря GPS и запрет геопозиции живут своими путями (чип камеры и баннер
//  доступа) и сюда не входят.
//

import Foundation

nonisolated enum MapStatusPick: Equatable, Sendable {
    case server
    case offline
    case overheated
    case noSpeedLimits

    /// Порядок прежний: сервер > сеть > перегрев > лимиты. В поездке — только
    /// сеть.
    static func pick(hasServerMessage: Bool, isOffline: Bool, isOverheated: Bool,
                     limitsReady: Bool, inTrip: Bool) -> MapStatusPick? {
        if inTrip { return isOffline ? .offline : nil }
        if hasServerMessage { return .server }
        if isOffline { return .offline }
        if isOverheated { return .overheated }
        if !limitsReady { return .noSpeedLimits }
        return nil
    }

    /// В поездке баннер — одна строка: пояснение и кнопка ждут остановки.
    static func isCompact(inTrip: Bool) -> Bool { inTrip }
}
