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
//  поездке — одной строкой, без пояснения.
//  Потеря GPS и запрет геопозиции живут своими путями (чип камеры и баннер
//  доступа) и сюда не входят.
//

import Foundation

nonisolated enum MapStatusPick: Equatable, Sendable {
    case server
    case offline
    case overheated
    /// Автоэконом (12.3): мало заряда — карта плоская и без декора.
    case savingBattery
    case noSpeedLimits

    /// Порядок прежний: сервер > сеть > перегрев > батарея > лимиты. В
    /// поездке — сеть, затем батарея.
    ///
    /// Почему батарея говорит и за рулём, а перегрев нет. Автоэконом
    /// включается сам на 19 %, то есть посреди поездки: карта на глазах
    /// становится плоской и реже обновляется. Без строки «Экономим батарею»
    /// это та самая молчаливая деградация, которая читается как поломка.
    /// Перегрев за рулём ждёт по-прежнему (его баннер с пояснением), а
    /// батарея — одна строка без кнопок, как «нет сети».
    static func pick(hasServerMessage: Bool, isOffline: Bool, isOverheated: Bool,
                     savingBattery: Bool = false,
                     limitsReady: Bool, inTrip: Bool) -> MapStatusPick? {
        if inTrip {
            if isOffline { return .offline }
            return savingBattery ? .savingBattery : nil
        }
        if hasServerMessage { return .server }
        if isOffline { return .offline }
        if isOverheated { return .overheated }
        if savingBattery { return .savingBattery }
        if !limitsReady { return .noSpeedLimits }
        return nil
    }

    /// В поездке баннер — одна строка: пояснение и кнопка ждут остановки.
    static func isCompact(inTrip: Bool) -> Bool { inTrip }
}
