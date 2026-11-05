//
//  CarPlayTripToggle.swift
//  RadarMap
//
//  Кнопка ▶/■ «Поездка» в баре машины и второе нажатие сразу после первого.
//
//  Журнал 12.10 (carplay12): старт и через 0,6–0,9 с конец «0 м, не
//  сохранена», дважды подряд — смена значка доходит до машины не сразу,
//  водитель не видел ответа и жал ещё раз, а стоя второе нажатие завершает
//  без вопроса. Второе нажатие в пределах `carPlayTripToggleGuard` — это
//  вопрос «нажалось ли?»: поездку оно не переключает, а отвечает баннером
//  о том, что уже случилось (QA 05.11: до 48 оно только писало в журнал).
//  Баннер — подтверждение в общей очереди CarPlayBanners (`.info`).
//
//  Чистая логика; CarPlayTripToggleTests.
//

import Foundation

nonisolated enum CarPlayTripToggle {

    enum Tap: Equatable, Sendable {
        /// Переключить поездку.
        case toggle
        /// Повторное нажатие: не переключать, сказать баннером, что уже сделано.
        case repeated(message: String)
    }

    static func decide(lastToggle: Date?, now: Date, tripActive: Bool,
                       guardSeconds: TimeInterval = AppConfig.carPlayTripToggleGuard) -> Tap {
        guard let lastToggle, now.timeIntervalSince(lastToggle) < guardSeconds else { return .toggle }
        return .repeated(message: tripActive
            ? String(localized: "Поездка уже идёт — слежу за камерами")
            : String(localized: "Поездка уже завершена"))
    }
}
