//
//  TouchFeedback.swift
//  RadarMap
//
//  Отклик касания: чем кнопка отвечает пальцу. Чистое правило — покрыто
//  TouchFeedbackTests; облик и вибрацию по нему делает `PressableStyle`.
//
//  До задачи 41 отклик был россыпью: сжатие 0,95 у части кнопок и около
//  шестидесяти `UIImpactFeedbackGenerator` в действиях — где лёгкий, где
//  средний, где «rigid», а где ничего, — и одинаково важные кнопки отвечали
//  по-разному. Теперь сила вибрации — по РОЛИ кнопки, одна таблица на всё
//  приложение.
//
//  Вибрация звучит на срабатывании кнопки (касание отпущено внутри), а не на
//  нажатии: в прокручиваемом списке палец, задержавшийся перед прокруткой,
//  «нажимал» строку, и вибрация без действия читалась бы как сбой.
//

import Foundation

/// Роль касаемого элемента — от неё сила вибрации и форма отклика.
nonisolated enum TouchRole: CaseIterable, Sendable {
    /// Обычная кнопка: круг над картой, кнопка дока, плашка, второе действие.
    case regular
    /// Главное действие экрана: «Поехали», «Отметить», выбор типа отметки.
    case primary
    /// Отказ: «✕», «Не отмечать», «Отменить».
    case cancel
    /// Выбор из нескольких: чип варианта, режим голоса, тумблер в карточке.
    case choice
    /// Карточка с переходом («Итоги» → подробности).
    case card
    /// Строка списка: без сжатия — строка во всю ширину, качающаяся под
    /// пальцем, выглядит как дрожащий экран.
    case row
    /// Действие само решает, чем ответить (взвод «Стопа», экран оповещения о
    /// камере, подтверждение с «успехом»): стиль только сжимает.
    case ownFeedback

    /// Кнопка с системной ролью отмены отвечает как отказ, если ей не
    /// назначено иное.
    static func resolve(_ role: TouchRole, isCancelButton: Bool) -> TouchRole {
        isCancelButton && role == .regular ? .cancel : role
    }
}

/// Сила вибрации касания. Системные вибрации выключены в настройках iOS —
/// система промолчит сама: отклик идёт через `sensoryFeedback`.
nonisolated enum TouchHaptic: Equatable, Sendable {
    case none
    /// Самый тихий щелчок — смена выбора.
    case selection
    case light
    case medium
    /// Мягкий, «глухой» удар — отказ звучит иначе, чем согласие.
    case soft
}

nonisolated struct TouchResponse: Equatable, Sendable {
    let haptic: TouchHaptic
    /// Масштаб под пальцем; 1 — без сжатия.
    let pressedScale: Double
    /// Непрозрачность под пальцем; 1 — без затемнения.
    let pressedOpacity: Double

    /// «Уменьшение движения»: без масштаба, только затемнение. Сила вибрации
    /// от этой настройки не зависит — она про движение, а не про осязание.
    static func of(_ role: TouchRole, reduceMotion: Bool) -> TouchResponse {
        let haptic: TouchHaptic
        let scale: Double
        switch role {
        case .regular:     haptic = .light;     scale = 0.95
        case .primary:     haptic = .medium;    scale = 0.97
        case .cancel:      haptic = .soft;      scale = 0.95
        case .choice:      haptic = .selection; scale = 0.95
        case .card:        haptic = .light;     scale = 0.98
        case .row:         haptic = .selection; scale = 1
        case .ownFeedback: haptic = .none;      scale = 0.95
        }
        if role == .row {
            return TouchResponse(haptic: haptic, pressedScale: 1, pressedOpacity: 0.6)
        }
        if reduceMotion {
            return TouchResponse(haptic: haptic, pressedScale: 1, pressedOpacity: 0.7)
        }
        return TouchResponse(haptic: haptic, pressedScale: scale, pressedOpacity: 1)
    }
}
