//
//  SketchArea.swift
//  RadarMap
//
//  Местность под дорогами: вода, зелень, рельсы.
//
//  Зачем отдельный тип, а не ещё один класс дороги. Дорога отвечает на вопрос
//  «где я еду», местность — «что здесь ещё есть». У них разная геометрия
//  (полигон против ленты), разный порядок отрисовки (местность всегда ПОД
//  дорогами) и разная судьба в перегреве. Смешать их в RoadLine значило бы
//  таскать через весь конвейер поле, которое для половины значений не имеет
//  смысла.
//
//  Данные для этого слоя приезжали на сервер всё это время внутри того же
//  .pbf, который качается ради дорог, и выбрасывались фильтром по highway.
//  На тёмной схеме вода — единственный не-серый цвет, и именно она отличает
//  местность от чертежа.
//

import CoreLocation
import Foundation

nonisolated struct SketchArea: Sendable {

    /// Коды — контракт с build_roads.py (AREA_WATER и соседние).
    enum Kind: Int, Sendable, CaseIterable {
        case water = 1
        case green = 2
        case rail = 3
        /// Квартал — грань дорожного графа. Не из OSM: его контур СЛЕДУЕТ из
        /// измеренных дорог, поэтому он честен ровно настолько, насколько
        /// честна сеть.
        case block = 4

        /// До какого охвата слой имеет смысл. Вода, зелень и рельсы — крупные
        /// ориентиры и нужны на любом; кварталы вблизи, где они и читаются.
        var maxSpanMeters: Double {
            switch self {
            case .water, .green, .rail: return .greatestFiniteMagnitude
            case .block:                return RoadSketch.farNetworkSpan
            }
        }
    }

    var points: [CLLocationCoordinate2D]
    var kind: Kind
    /// Полигон (заливается) против ленты (штрихуется). Река бывает и той, и
    /// другой, рельсы — всегда лента.
    var isClosed: Bool
}

// CLLocationCoordinate2D не Equatable — сравниваем по координатам сами, как и
// весь остальной геометрический код проекта.
extension SketchArea: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.isClosed == rhs.isClosed
            && lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }
}
