//
//  SketchPoint.swift
//  RadarMap
//
//  Точечные объекты схемы: светофор, лежачий полицейский, стоп-линия, разворот.
//
//  Это ПЕРВЫЙ слой, который приходит не из OSM, а нарисован руками в панели.
//  Отсюда два правила, которых нет у остального:
//
//  • Такие данные не с чем сверить. Дорогу можно сравнить с чужой картой, а
//    светофор, поставленный человеком, подтверждается только этим человеком.
//    Поэтому вид объекта, которого приложение не знает, НЕ рисуется — но и не
//    роняет тайл: сервер вправе завести новый вид раньше, чем выйдет сборка.
//
//  • Виден такой объект только вблизи. На охвате района светофор — точка в
//    один пиксель среди сотни таких же, то есть шум; на ближнем плане это
//    ориентир, по которому водитель понимает, где он.
//

import CoreLocation

nonisolated struct SketchPoint: Sendable {

    /// Коды — контракт с build_roads.py (POINT_TRAFFIC_LIGHT и соседние).
    enum Kind: Int, Sendable, CaseIterable {
        case trafficLight = 1
        case speedBump = 2
        case stopLine = 3
        case uTurn = 4

        /// До какого охвата объект имеет смысл.
        var maxSpanMeters: Double {
            switch self {
            // Разворот — решение, а не украшение: его ищут заранее, поэтому
            // он живёт дальше остальных.
            case .uTurn: return RoadSketch.farNetworkSpan
            case .trafficLight, .speedBump, .stopLine: return 260
            }
        }

        var symbolName: String {
            switch self {
            case .trafficLight: return "trafficlight"
            case .speedBump:    return "arrow.up.and.down.and.arrow.left.and.right"
            case .stopLine:     return "minus"
            case .uTurn:        return "arrow.uturn.left"
            }
        }
    }

    var coordinate: CLLocationCoordinate2D
    var kind: Kind
}

extension SketchPoint: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}
