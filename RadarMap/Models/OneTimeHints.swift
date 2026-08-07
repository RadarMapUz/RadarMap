//
//  OneTimeHints.swift
//  RadarMap
//
//  Три жеста главного экрана, о которых можно не узнать никогда: тап по HUD —
//  спидометр, долгий тап — быстрые переключатели, жёлтая кнопка — отметить
//  радар. Туториал-простыня — худший способ это рассказать: её пролистывают.
//  Вместо неё три однострочные подсказки, каждая показывается ОДИН раз за
//  жизнь приложения и не больше ОДНОЙ за запуск — чтобы новичка не заваливало.
//
//  Здесь только чистое решение «какую показать»; хранение — в Storage,
//  показ — в MapScreen. Покрыто OneTimeHintsTests.
//

import Foundation

nonisolated enum OneTimeHints {

    /// Порядок объявления = порядок показа: сперва самое ценное (экономный
    /// спидометр — ради него всё и делалось), потом переключатели, потом
    /// радар — он и так требует поездки.
    enum Hint: CaseIterable, Equatable {
        case dashboard
        case toggles
        case radar

        var text: String {
            switch self {
            case .dashboard:
                return String(localized: "Тап по скорости — спидометр во весь экран")
            case .toggles:
                return String(localized: "Долгий тап по скорости — быстрые переключатели")
            case .radar:
                return String(localized: "Жёлтая кнопка — отметить радар для других")
            }
        }
    }

    /// Какую подсказку показать сейчас. `radarVisible` — жёлтая кнопка на
    /// экране (режим карты её прячет вне поездки): подсказывать про кнопку,
    /// которой не видно, значит путать, а не помогать.
    static func next(shown: Set<Hint>, radarVisible: Bool) -> Hint? {
        for hint in Hint.allCases where !shown.contains(hint) {
            if hint == .radar, !radarVisible { continue }
            return hint
        }
        return nil
    }
}
