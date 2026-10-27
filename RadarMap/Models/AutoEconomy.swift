//
//  AutoEconomy.swift
//  RadarMap
//
//  Автоэконом (12.3): заряд меньше 20 % без зарядки — карта сама переходит
//  на ту же ступень, что у телефона, который греется: плоско, 20 к/с, без
//  деревьев, теней и прочего декора.
//
//  Зачем. Водитель без провода в машине — ровно тот, кому нужно доехать с
//  включёнными оповещениями. Наклонная карта на 30 кадрах с 3D-деревьями —
//  самое дорогое, что делает приложение, и самое ненужное на последних
//  процентах. Механизм не новый: ступень `PerformanceMode.reduced` уже знает,
//  что урезать при перегреве, и камер не трогает ни на одной ступени
//  (ThermalService). Здесь — только решение «когда», с гистерезисом: на
//  пороге 19/20 % карта не должна мигать между двумя видами.
//
//  Что НЕ трогается: оповещения о камерах (база в памяти, голос и звук те
//  же), частота опроса отметок водителей (тренога, отмеченная минуту назад,
//  нужна и на 15 %) — поэтому опрос смотрит на нагрев, а не на эту ступень.
//
//  Чистая логика — покрыта AutoEconomyTests.
//

import Foundation

nonisolated enum AutoEconomy {

    /// Почему карта урезана — от этого зависит, что сказать водителю.
    enum Reason: Equatable, Sendable {
        /// Телефон греется (ProcessInfo.thermalState).
        case heat
        /// Мало заряда, зарядки нет.
        case battery
    }

    /// Экономим ли батарею. `percent` nil — система заряд не отдаёт
    /// (симулятор): не знаем — не урезаем. На зарядке — никогда: провод
    /// воткнули, и карта возвращается сразу, без ожидания порога выхода.
    /// Порог выхода выше порога входа — гистерезис.
    static func savesBattery(percent: Int?, isCharging: Bool, wasSaving: Bool) -> Bool {
        guard let percent, !isCharging else { return false }
        let threshold = wasSaving ? AppConfig.autoEconomyExitPercent : AppConfig.autoEconomyEnterPercent
        return percent < threshold
    }

    /// Итоговая ступень карты: нагрев как есть, батарея — не выше `.reduced`.
    /// Горячий телефон (`.minimal`) батарея не «улучшает».
    static func mode(thermal: PerformanceMode, savingBattery: Bool) -> PerformanceMode {
        savingBattery ? max(thermal, .reduced) : thermal
    }

    /// Что объяснять плашкой. Перегрев старше: он урезает сильнее и требует
    /// другого действия (убрать телефон с солнца, а не искать провод).
    static func reason(thermal: PerformanceMode, savingBattery: Bool) -> Reason? {
        if thermal != .full { return .heat }
        return savingBattery ? .battery : nil
    }
}
