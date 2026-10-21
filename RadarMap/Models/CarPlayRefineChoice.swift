//
//  CarPlayRefineChoice.swift
//  RadarMap
//
//  Уточнение отметки после «Радар!» в машине — кнопками прямо в баннере
//  (25.H1, iOS 27).
//
//  До iOS 27 у баннера навигатора две кнопки, и уточнение шло так: «Тренога»
//  одним касанием, «Другое» — сетка с постом, ДТП и «Отменить» (второй экран
//  и второй взгляд). С iOS 27 у CPNavigationAlert массив `actions` до
//  `maximumActionsCount` (CPNavigationAlert.h) — все типы встают в один
//  баннер, как плашка уточнения на телефоне (`ReportRefineBar`): тренога,
//  пост, ДТП; молчание и крестик честно оставляют «радар».
//
//  Число кнопок система сообщает только во время работы. Типов меньше, чем
//  влезает, не обрезаем — тогда прежний путь с сеткой: пропавший «ДТП» хуже
//  второго касания. «Отменить» (своя свежая отметка) — последней и только
//  если хватает места: тип важнее отзыва.
//
//  Чистая логика; CarPlayRefineChoiceTests.
//

enum CarPlayRefineChoice {

    enum Action: Equatable {
        /// Переписать тип той же точки (amend).
        case kind(ReportKind)
        /// Отозвать свою свежую, никем не подтверждённую отметку.
        case cancelOwn
    }

    /// Типы для уточнения — те же, что предлагает телефон, кроме самого
    /// радара (он уже стоит). События дороги (перекрытие, ремонт) — в сетке
    /// прежнего пути: в баннер они не помещаются и к засаде не относятся.
    static var kinds: [ReportKind] { ReportKind.offered.filter { $0 != .radar } }

    /// Кнопки баннера; nil — кнопок не хватает на все типы, и уточнение идёт
    /// прежним путём (баннер «Тренога / Другое» и сетка).
    static func actions(maximum: Int, cancellable: Bool) -> [Action]? {
        let kinds = kinds.map(Action.kind)
        guard !kinds.isEmpty, maximum >= kinds.count else { return nil }
        return cancellable && maximum > kinds.count ? kinds + [.cancelOwn] : kinds
    }
}
