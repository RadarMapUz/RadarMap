//
//  ManeuverThen.swift
//  RadarMap
//
//  «Затем …» под карточкой манёвра (29.G): второй манёвр сразу за первым.
//  Поворот направо и через 80 м налево — водителю нужно знать об обоих до
//  первого, иначе он встанет в правый ряд и не успеет в левый. Так делают
//  Яндекс и Apple Maps. С 76 и голос: «…направо. Затем налево» — один раз
//  на манёвр, в ближней фразе или в команде, не пока камера держит голос.
//
//  Показываем, только когда второй ближе `maneuverThenMeters` за первым:
//  дальше «затем» — шум, у водителя будет время прочитать карточку снова.
//  После прибытия манёвров нет; «прямо» (продолжение улицы под другим
//  именем) — не манёвр для «затем». Чистая логика, ManeuverThenTests.
//

import Foundation

nonisolated enum ManeuverThen {

    /// Следующий за `index` манёвр, если он близко; nil — «затем» не нужно.
    static func following(_ index: Int, in steps: [RouteStep],
                          within meters: Double = AppConfig.maneuverThenMeters) -> RouteStep? {
        guard steps.indices.contains(index), steps.indices.contains(index + 1) else { return nil }
        let first = steps[index], second = steps[index + 1]
        guard first.kind != .arrive, second.kind != .straight,
              second.distanceAlong - first.distanceAlong <= meters,
              second.distanceAlong > first.distanceAlong else { return nil }
        return second
    }

    /// Добавить ли «затем» к ступени голоса `stage` (2 — далеко, 1 — близко,
    /// 0 — команда): далеко — рано, сказанное — не повторяем, камера впереди
    /// держит голос — короткая фраза.
    static func voiced(stage: Int, alreadySaid: Bool, cameraHolds: Bool) -> Bool {
        stage <= 1 && !alreadySaid && !cameraHolds
    }

    /// Фраза с хвостом «Затем …»: второй манёвр без улицы — коротко.
    static func spoken(_ phrase: String, then second: RouteStep) -> String {
        String(format: String(localized: "%1$@. Затем %2$@"), phrase, second.shortText ?? second.text)
    }
}

extension RouteService {
    /// «Затем …» к ближайшему манёвру выбранного маршрута; nil — не нужно.
    /// Дешёвый: поиск по списку шагов одного маршрута, меняется с манёвром.
    var thenStep: RouteStep? {
        guard let next = nextStep, let steps = selected?.steps,
              let index = steps.firstIndex(where: { $0.distanceAlong == next.distanceAlong }) else { return nil }
        return ManeuverThen.following(index, in: steps)
    }
}
