//
//  OneTimeHints.swift
//  RadarMap
//
//  Жесты главного экрана, о которых можно не узнать никогда: тап по HUD —
//  быстрые переключатели, жёлтая кнопка — отметить радар.
//  Туториал-простыня — худший способ это рассказать: её пролистывают.
//
//  Подсказки про спидометр здесь нет: сначала он переехал в нижний бар
//  кнопкой с подписью, а потом был убран совсем. Тап по HUD, который раньше
//  открывал его, теперь открывает переключатели — поэтому и подсказка про
//  них говорит о тапе, а не о долгом тапе (он тоже работает).
//  Три однострочные подсказки, каждая показывается ОДИН раз за
//  жизнь приложения и не больше ОДНОЙ за запуск — чтобы новичка не заваливало.
//
//  Здесь только чистое решение «какую показать»; хранение — в Storage,
//  показ — в MapScreen. Покрыто OneTimeHintsTests.
//

import Foundation

nonisolated enum OneTimeHints {

    /// Порядок объявления = порядок показа: сперва переключатели, потом
    /// радар — он и так требует поездки.
    enum Hint: CaseIterable, Equatable {
        case toggles
        case radar
        /// Появляется, только когда первая камера уже стала «своей»: объяснять
        /// тишину заранее нечего, а вот когда голос впервые пропал — нужно.
        case smartSilence

        var text: String {
            switch self {
            case .toggles:
                return String(localized: "Тап по скорости — быстрые переключатели")
            case .radar:
                return String(localized: "Жёлтая кнопка — отметить радар для других")
            case .smartSilence:
                return String(localized: "Знакомые камеры больше не называю вслух — вы их знаете")
            }
        }
    }

    /// Какую подсказку показать сейчас. `radarVisible` — жёлтая кнопка на
    /// экране (режим карты её прячет вне поездки): подсказывать про кнопку,
    /// которой не видно, значит путать, а не помогать. `hasFamiliarCameras` —
    /// то же правило для умной тишины: пока своих камер нет, объяснять нечего.
    static func next(shown: Set<Hint>, radarVisible: Bool,
                     hasFamiliarCameras: Bool = false) -> Hint? {
        for hint in Hint.allCases where !shown.contains(hint) {
            if hint == .radar, !radarVisible { continue }
            if hint == .smartSilence, !hasFamiliarCameras { continue }
            return hint
        }
        return nil
    }
}
