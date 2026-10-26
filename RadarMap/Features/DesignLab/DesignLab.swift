//
//  DesignLab.swift
//  RadarMap
//
//  Этап 31 (дизайн-аудит 26.10): варианты A/B/C самых слабых экранов — в
//  настоящем SwiftUI, чтобы владелец выбирал по снимкам, а не по описаниям.
//
//  Вариант включается DEBUG-ключом запуска, по экрану:
//    -designTripEnd A|B|C    карточка «Поездка сохранена»
//    -designRoute A|B        панель маршрута до старта
//    -designOnboarding A|B   онбординг на малом экране
//  Без ключа и в релизе — `.base`, то есть приложение как есть. После выбора
//  владельца выбранный вариант переносится в основной код, а эта папка
//  удаляется целиком.
//

import Foundation

nonisolated enum DesignLab {
    enum Variant: String {
        case base, a = "A", b = "B", c = "C"
    }

    static let tripEnd = variant("-designTripEnd")
    static let route = variant("-designRoute")
    static let onboarding = variant("-designOnboarding")

    private static func variant(_ key: String) -> Variant {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return .base }
        return Variant(rawValue: args[index + 1].uppercased()) ?? .base
        #else
        return .base
        #endif
    }
}
