//
//  ChoiceRelabelGate.swift
//  RadarMap
//
//  Ярлыки вариантов на поздних данных (решение 28.10, наблюдение 5 симуляции
//  пробок 27.10).
//
//  Профиль часа недели (3 МБ) или свежий now.json может прийти уже после
//  того, как варианты показаны. Время вариантов тогда пересчитывается всегда,
//  а ярлыки («Быстрый», «Меньше камер»…) и выбранный нами вариант — только
//  пока водитель не коснулся панели выбора: ни выбора варианта (карточкой,
//  линией на карте, в машине), ни жеста по карточкам, ни «Поехали». До
//  касания выбор — наш, и честнее подвинуть «Быстрый» вслед за данными, чем
//  оставить его на варианте, который уже не быстрее. После касания ярлыки
//  заморожены (давнее правило «Быстрый не прыгает под пальцем»), а вариант,
//  выбранный водителем, сам не меняется никогда.
//
//  Чистая логика; покрыто ChoiceRelabelGateTests.
//

import Foundation

nonisolated struct ChoiceRelabelGate: Equatable, Sendable {
    /// Водитель коснулся панели выбора (или поехал) с показа этого набора.
    private(set) var touched = false

    /// Показан новый набор вариантов — касаний по нему ещё не было.
    mutating func shown() { touched = false }

    /// Касание панели выбора, выбор варианта или начало поездки.
    mutating func touch() { touched = true }

    /// Что применить после пересчёта по поздним данным: новые ярлыки и
    /// вариант, который выбрать. nil — ярлыки заморожены (было касание),
    /// или выбирать не из чего (один вариант, перестроение — без ярлыков).
    func relabel(_ verdict: RouteChoice.Verdict, variantCount: Int)
        -> (assessments: [RouteChoice.Assessment], selected: Int)? {
        guard !touched, variantCount > 1, verdict.assessments.count == variantCount,
              verdict.assessments.indices.contains(verdict.recommended) else { return nil }
        return (verdict.assessments, verdict.recommended)
    }
}
