//
//  ManeuverThen.swift
//  RadarMap
//
//  «Затем …» под карточкой манёвра (29.G): второй манёвр сразу за первым.
//  Поворот направо и через 80 м налево — водителю нужно знать об обоих до
//  первого, иначе он встанет в правый ряд и не успеет в левый. Так делают
//  Яндекс и Apple Maps; голос второй манёвр называет только после первого.
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
