//
//  Maneuver.swift
//  RadarMap
//
//  Манёвр маршрута как ДАННЫЕ, а не как фраза с картинкой.
//
//  Раньше разбор OSRM превращал `maneuver.type` + `modifier` сразу в текст и
//  SF-символ и выбрасывал сам факт «это поворот направо». Для баннера этого
//  хватало, а для схемы — нет: символ баннера нельзя ни положить на полотно
//  стрелкой, ни сопоставить с полосами. Тип манёвра живёт здесь, отдельно от
//  его озвучки.
//
//  Полосы — из того же ответа OSRM. Запрос давно идёт со `steps=true`, то есть
//  `intersections[].lanes` уже приезжает и уже разбирается JSON'ом; их просто
//  не декодировали. Ни одного лишнего байта по сети они не стоят.
//

import CoreLocation

/// Куда сворачивает манёвр. Описывает ГЕОМЕТРИЮ поворота, а не его озвучку:
/// фраза («держитесь правее» против «поверните направо») зависит ещё и от типа
/// развязки, и живёт в RouteService рядом с разбором.
nonisolated enum ManeuverKind: String, Equatable, Sendable, CaseIterable {
    case straight
    case slightLeft, left, sharpLeft, uturn
    case slightRight, right, sharpRight
    case roundabout
    case arrive

    /// Сторона манёвра — по ней полоса считается «нашей».
    enum Side: Equatable, Sendable { case left, right }

    var side: Side? {
        switch self {
        case .slightLeft, .left, .sharpLeft, .uturn: return .left
        case .slightRight, .right, .sharpRight:      return .right
        case .straight, .roundabout, .arrive:        return nil
        }
    }

    /// Рисуем ли манёвр стрелкой на полотне. Прибытие — не поворот: там флаг,
    /// а не стрелка, и рисовать «поверните» на финише было бы ложью.
    var isDrawable: Bool { self != .arrive }

    /// Разбор модификатора OSRM. Неизвестный модификатор — `straight`, а не
    /// падение: чужой сервер вправе прислать то, чего мы не знаем, и маршрут
    /// от этого ломаться не должен.
    static func fromOSRM(modifier: String?) -> ManeuverKind {
        switch modifier {
        case "slight left":  return .slightLeft
        case "left":         return .left
        case "sharp left":   return .sharpLeft
        case "uturn":        return .uturn
        case "slight right": return .slightRight
        case "right":        return .right
        case "sharp right":  return .sharpRight
        default:             return .straight
        }
    }
}

/// Пиктограмма одной стрелки на полосе. Набор — тот же, что у OSRM
/// `lanes[].indications`; на одной полосе их может быть несколько
/// («прямо и направо»).
nonisolated enum LaneArrow: String, Equatable, Sendable {
    case straight
    case slightLeft, left, sharpLeft, uturn
    case slightRight, right, sharpRight
    case mergeToLeft, mergeToRight

    var side: ManeuverKind.Side? {
        switch self {
        case .slightLeft, .left, .sharpLeft, .uturn, .mergeToLeft: return .left
        case .slightRight, .right, .sharpRight, .mergeToRight:     return .right
        case .straight:                                            return nil
        }
    }

    /// Пиктограмма полосы. Крутой поворот берёт тот же глиф, что обычный:
    /// на полосе водитель читает СТОРОНУ, а острота угла — дело стрелки на
    /// полотне, где она видна геометрией, а не намёком в пятнадцать пунктов.
    var symbolName: String {
        switch self {
        case .straight:                 return "arrow.up"
        case .slightLeft:               return "arrow.up.left"
        case .left, .sharpLeft:         return "arrow.turn.up.left"
        case .uturn:                    return "arrow.uturn.left"
        case .slightRight:              return "arrow.up.right"
        case .right, .sharpRight:       return "arrow.turn.up.right"
        case .mergeToLeft, .mergeToRight: return "arrow.merge"
        }
    }

    /// `none` OSRM (полоса без разметки) осмысленно читать как «прямо»:
    /// пустая клетка в ряду полос выглядит поломкой рендера.
    static func fromOSRM(_ indication: String) -> LaneArrow? {
        switch indication {
        case "none", "straight":   return .straight
        case "slight left":        return .slightLeft
        case "left":               return .left
        case "sharp left":         return .sharpLeft
        case "uturn":              return .uturn
        case "slight right":       return .slightRight
        case "right":              return .right
        case "sharp right":        return .sharpRight
        case "merge to left":      return .mergeToLeft
        case "merge to right":     return .mergeToRight
        default:                   return nil
        }
    }
}

/// Одна полоса на подходе к манёвру.
nonisolated struct LaneHint: Equatable, Sendable {
    /// Куда с этой полосы можно уехать. Пусто не бывает: полосу без единой
    /// стрелки мы не создаём.
    let arrows: [LaneArrow]
    /// Полоса ведёт туда, куда нам нужно (OSRM `valid`). Ровно эта полоса
    /// подсвечивается белым, остальные — серые.
    let isValid: Bool

    /// Главная стрелка полосы: если полоса подходит нам, показываем ту, что
    /// совпала со стороной манёвра, — иначе водитель на «прямо и направо»
    /// увидит «прямо» и поедет прямо.
    func primaryArrow(for kind: ManeuverKind?) -> LaneArrow {
        guard isValid, let side = kind?.side,
              let matching = arrows.first(where: { $0.side == side })
        else { return arrows.first ?? .straight }
        return matching
    }
}

/// Манёвр на маршруте («через 300 м — направо»).
nonisolated struct RouteStep: Equatable, Sendable {
    /// Где манёвр, метры от старта.
    let distanceAlong: CLLocationDistance
    /// «Поверните направо на Амира Темура» — то, что произносит голос.
    let text: String
    /// SF-символ для баннера.
    let icon: String
    /// Тип манёвра. nil — движок его не сообщил (MKDirections отдаёт только
    /// готовую фразу): стрелку тогда чертим по самой геометрии маршрута, а
    /// голову подбираем нейтральную.
    var kind: ManeuverKind?
    /// Полосы на подходе. Пусто — данных нет, и пузырь полос не показывается
    /// вовсе: нарисовать три полосы по догадке нельзя.
    var lanes: [LaneHint] = []
}
